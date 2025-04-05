// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {CreateMarketParams} from "../src/types/MarketTypes.sol";
import "forge-std/console.sol";

// Uniswap V4 Core libraries & interfaces
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

// Local project contracts & types
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";
import {MarketState} from "../src/types/MarketTypes.sol"; // Keep MarketState if needed for checks

/**
 * @title DeployTestMarkets
 * @notice This script loads existing core contracts (Hook, PoolManager, PoolCreationHelper)
 *         from addresses.json, creates two new prediction markets using the loaded hook.
 * @dev Assumes addresses.json exists and is populated by DeployUnichainSepolia.s.sol.
 */
contract DeployTestMarkets is Script {
    // --- Core Contracts (Loaded) ---
    PredictionMarketHook public hook;
    PoolManager public manager;
    PoolCreationHelper public poolCreationHelper;

    // --- Test Contracts (Loaded) ---
    ERC20Mock public collateralToken; // Loaded collateral token.

    // --- Configuration ---
    uint256 public constant INITIAL_MARKET_COLLATERAL = 100 * 1e6; // 100 USDC (assuming 6 decimals) collateral for market creation.

    // --- Script State ---
    address private deployer; // Address executing the script.

    /// @notice Main script execution function.
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_SEPOLIA_PK");
        deployer = vm.addr(deployerPrivateKey);
        console.log("Script runner (Deployer):", deployer);

        // Load addresses of already deployed core contracts.
        _loadCoreAddresses();

        // Load the collateral token address deployed by the main script.
        _loadCollateralToken();

        // Start broadcasting transactions to the network.
        vm.startBroadcast(deployerPrivateKey);

        // Create new markets using the loaded hook and collateral.
        _createMarkets();

        // Stop broadcasting transactions.
        vm.stopBroadcast();

        console.log("\nScript complete! Test markets created.");
    }

    /// @notice Loads required core contract addresses from the `script/config/addresses.json` file.
    function _loadCoreAddresses() internal {
        console.log("\n--- Loading Core Contract Addresses ---");
        string memory json = vm.readFile("script/config/addresses.json");

        address hookAddress = json.readAddress(".predictionMarketHook");
        address managerAddress = json.readAddress(".poolManager");
        address helperAddress = json.readAddress(".poolCreationHelper");
        require(hookAddress != address(0), "Failed to read hook address");
        require(managerAddress != address(0), "Failed to read manager address");
        require(helperAddress != address(0), "Failed to read helper address");

        hook = PredictionMarketHook(hookAddress);
        manager = PoolManager(managerAddress);
        poolCreationHelper = PoolCreationHelper(helperAddress);

        console.log("  Loaded Hook:", hookAddress);
        console.log("  Loaded PoolManager:", managerAddress);
        console.log("  Loaded PoolCreationHelper:", helperAddress);
    }

    /// @notice Loads the collateral token address from `script/config/addresses.json`.
    function _loadCollateralToken() internal {
        console.log("\n--- Loading Collateral Token Address ---");
        string memory addressesFile = "script/config/addresses.json";
        string memory json = vm.readFile(addressesFile);

        address collateralAddr = json.readAddress(".collateralToken");
        require(collateralAddr != address(0), "Failed to read collateral token address from addresses.json");

        collateralToken = ERC20Mock(collateralAddr);
        console.log("Loaded Collateral Token (from addresses.json) at:", address(collateralToken));
    }

    /// @notice Creates two new test prediction markets.
    function _createMarkets() internal {
        console.log("\n--- Creating Test Markets ---");

        // *** Mint mock collateral to deployer ***
        uint256 collateralToMint = INITIAL_MARKET_COLLATERAL * 2 * 5; // Mint enough for 2 markets + buffer
        collateralToken.mint(deployer, collateralToMint);
        console.log("Minted", collateralToMint / (10 ** 6), "tUSDC to deployer");
        // *** End mint ***

        // Grant the hook unlimited allowance for the loaded collateral token.
        collateralToken.approve(address(hook), type(uint256).max);
        console.log("Approved hook to spend test USDC for market creation");

        // --- Market 1 ---
        CreateMarketParams memory params1 = CreateMarketParams({
            oracle: deployer,
            creator: deployer,
            collateralAddress: address(collateralToken),
            collateralAmount: INITIAL_MARKET_COLLATERAL,
            title: "SCRIPT: Will DoE be dismantled by Dec 31, 2025?", // Added prefix
            description: "Test Market 1 created by DeployTestMarkets script.",
            duration: 1 hours,
            curveId: 0
        });
        console.log("Creating Market 1 ('DoE Dismantled')...");
        bytes32 marketId1 = hook.createMarketAndDepositCollateral(params1);
        console.log("  Market 1 created with ID:", vm.toString(marketId1));

        // *** Add immediate state check ***
        MarketState state1 = hook.getMarketById(marketId1).state;
        console.log("  Market 1 immediate state check:", uint8(state1));
        require(state1 == MarketState.Active, "Market 1 not immediately active after creation!");
        // *** End check ***

        // --- Market 2 ---
        CreateMarketParams memory params2 = CreateMarketParams({
            oracle: deployer,
            creator: deployer,
            collateralAddress: address(collateralToken),
            collateralAmount: INITIAL_MARKET_COLLATERAL,
            title: "SCRIPT: Will U.S. acquire Greenland by Dec 31, 2025?", // Added prefix
            description: "Test Market 2 created by DeployTestMarkets script.",
            duration: 1 hours,
            curveId: 0
        });
        console.log("Creating Market 2 ('Greenland Acquired')...");
        bytes32 marketId2 = hook.createMarketAndDepositCollateral(params2);
        console.log("  Market 2 created with ID:", vm.toString(marketId2));

        // *** Add immediate state check ***
        MarketState state2 = hook.getMarketById(marketId2).state;
        console.log("  Market 2 immediate state check:", uint8(state2));
        require(state2 == MarketState.Active, "Market 2 not immediately active after creation!");
        // *** End check ***
    }
}
