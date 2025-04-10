// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// Use our local interface instead of the external one
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {Market, MarketState} from "../src/types/MarketTypes.sol";

/**
 * @title ApprovePermit2
 * @notice This script approves the Permit2 contract for the first market's tokens
 *         and grants Permit2 allowance to the PositionManager for those tokens.
 * @dev Run this script *before* AddLiquidity.s.sol.
 *      Assumes addresses.json contains permit2, positionManager, collateralToken, and predictionMarketHook addresses.
 */
contract ApprovePermit2 is Script {
    using stdJson for string;

    // --- Configurable Constants ---
    uint160 constant MAX_APPROVAL_AMOUNT = type(uint160).max; // Max amount for Permit2 allowance
    uint48 constant NO_EXPIRATION = type(uint48).max; // No expiration for Permit2 allowance

    // --- Script State ---
    address private deployer;
    IAllowanceTransfer private permit2;
    address private positionManagerAddress;
    IERC20 private collateralToken;
    PredictionMarketHook private hook;

    /// @notice Main script execution function.
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_PK");
        deployer = vm.addr(deployerPrivateKey);
        console.log("Script runner (Deployer):", deployer);

        // Load necessary addresses
        _loadAddresses();

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // --- Approve Collateral Token ---
        console.log("\n--- Approving Collateral Token ---");
        _approveTokenForPermit2(address(collateralToken));
        _setPermit2Allowance(address(collateralToken));

        // --- Approve Outcome Tokens for First Active Market ---
        console.log("\n--- Approving Outcome Tokens for First Market ---");
        bytes32[] memory marketIds = hook.getAllMarketIds();
        
        require(marketIds.length > 0, "No markets found");
        console.log("Found", marketIds.length, "total markets, using the first one.");
        
        bytes32 marketId = marketIds[0];
        Market memory market = hook.getMarketById(marketId);
        
        console.log("Processing approvals for market:", vm.toString(marketId));
        console.log("Market state:", uint8(market.state));
        
        IERC20 yesToken = IERC20(address(market.yesToken));
        IERC20 noToken = IERC20(address(market.noToken));
        
        console.log("YES token:", address(market.yesToken));
        console.log("NO token:", address(market.noToken));
        
        // Approve YES Token
        _approveTokenForPermit2(address(yesToken));
        _setPermit2Allowance(address(yesToken));
        
        // Approve NO Token
        _approveTokenForPermit2(address(noToken));
        _setPermit2Allowance(address(noToken));

        // Stop broadcasting transactions
        vm.stopBroadcast();
        console.log("\nScript complete! Permit2 approvals set for first market.");
    }

    /// @notice Loads required contract addresses from the `script/config/addresses.json` file.
    function _loadAddresses() internal {
        console.log("\n--- Loading Contract Addresses ---");
        string memory json = vm.readFile("script/config/addresses.json");

        address permit2Addr = json.readAddress(".permit2"); // <<< ENSURE THIS KEY EXISTS
        address posMgrAddr = json.readAddress(".positionManager");
        address collateralAddr = json.readAddress(".collateralToken");
        address hookAddress = json.readAddress(".predictionMarketHook");

        require(permit2Addr != address(0), "Failed to read permit2 address");
        require(posMgrAddr != address(0), "Failed to read positionManager address");
        require(collateralAddr != address(0), "Failed to read collateralToken address");
        require(hookAddress != address(0), "Failed to read predictionMarketHook address");

        permit2 = IAllowanceTransfer(permit2Addr);
        positionManagerAddress = posMgrAddr;
        collateralToken = IERC20(collateralAddr);
        hook = PredictionMarketHook(hookAddress);

        console.log("  Loaded Permit2:", permit2Addr);
        console.log("  Loaded PositionManager:", positionManagerAddress);
        console.log("  Loaded Collateral Token:", collateralAddr);
        console.log("  Loaded Hook:", hookAddress);
    }

    /// @notice Approves the main Permit2 contract to spend the deployer's tokens.
    function _approveTokenForPermit2(address tokenAddress) internal {
        // Format string explicitly before logging
        console.log(string.concat(
            "  Approving Permit2 contract (",
            vm.toString(address(permit2)),
            ") on token (",
            vm.toString(tokenAddress),
            ")"
        ));
        IERC20(tokenAddress).approve(address(permit2), type(uint256).max);
    }

    /// @notice Sets the Permit2 allowance, granting the PositionManager permission to spend the deployer's tokens via Permit2.
    function _setPermit2Allowance(address tokenAddress) internal {
         // Format string explicitly before logging
         console.log(string.concat(
            "  Granting Permit2 allowance for PositionManager (",
            vm.toString(positionManagerAddress),
            ") on token (",
            vm.toString(tokenAddress),
            ")"
         ));
         // Approve PositionManager to spend deployer's tokens via Permit2
         permit2.approve(
             tokenAddress,
             positionManagerAddress,
             MAX_APPROVAL_AMOUNT,
             NO_EXPIRATION
         );
    }
}

