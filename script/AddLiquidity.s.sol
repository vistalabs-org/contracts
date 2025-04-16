// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

// Uniswap V4 Core/Periphery libraries & interfaces
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol"; // Import Actions enum
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol"; // Re-add Currency import

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
// Use LiquidityAmounts from periphery
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

// Local project contracts & types
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";
import {Market, MarketState, MarketSetting} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";

/**
 * @title AddLiquidity
 * @notice This script adds liquidity to prediction markets by calling PositionManager.modifyLiquidities,
 *         encoding MINT_POSITION actions.
 * @dev Assumes addresses.json exists and is populated with hook, collateral, and positionManager addresses.
 *      Requires the deployer to have approved the PositionManager (likely via Permit2) for token transfers.
 */
contract AddLiquidity is Script {
    using stdJson for string;

    // --- Core Contracts (Loaded) ---
    PredictionMarketHook public hook;
    PositionManager public positionManager;
    ERC20Mock public collateralToken;

    // Market settings constants
    uint24 public constant MARKET_FEE = 1000; // 0.3% fee tier
    int24 public constant MARKET_TICK_SPACING = 10; // Corresponding to 0.3% fee tier
    int24 public constant MARKET_MIN_TICK = 380000; // Minimum tick
    int24 public constant MARKET_MAX_TICK = 207000; // Maximum tick

    // --- Script State ---
    address private deployer;

    /// @notice Main script execution function.
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        _addLiquidityToMarkets();

        vm.stopBroadcast();

        console.log("\nScript complete! Liquidity addition via PositionManager.modifyLiquidities submitted.");
    }

    /// @notice Fetches market IDs from the hook and adds liquidity to them using PositionManager.modifyLiquidities.
    function _addLiquidityToMarkets() internal {
        console.log("\n--- Adding Liquidity to Markets (via PositionManager.modifyLiquidities) --- ");

        console.log("\n--- Loading Core & Collateral Contract Addresses ---");
        string memory json = vm.readFile("script/config/addresses.json");

        address hookAddress = json.readAddress(".predictionMarketHook");
        address positionManagerAddress = address(0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869);
        address collateralAddr = address(0x5e458eE969e6336A7eF1716601d50b7E3C15499D);

        require(hookAddress != address(0), "Failed to read hook address");
        require(positionManagerAddress != address(0), "Failed to read positionManager address from addresses.json");
        require(collateralAddr != address(0), "Failed to read collateral token address from addresses.json");

        hook = PredictionMarketHook(hookAddress);
        positionManager = PositionManager(payable(positionManagerAddress));
        collateralToken = ERC20Mock(collateralAddr);

        console.log("  Loaded Hook:", hookAddress);
        console.log("  Loaded PositionManager:", positionManagerAddress);
        console.log("  Loaded Collateral Token:", collateralAddr);

        // Fetch Market IDs directly from the hook
        bytes32[] memory fetchedMarketIds = hook.getAllMarketIds();
        uint256 numMarkets = fetchedMarketIds.length;
        console.log("Fetched", numMarkets, "market IDs from the hook.");
        require(numMarkets > 0, "No markets found on the hook contract.");

        IAllowanceTransfer permit2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

        // Approve the hook ONCE for all potential outcome token minting calls.
        collateralToken.approve(address(permit2), type(uint256).max);
        permit2.approve(address(collateralToken), positionManagerAddress, type(uint160).max, type(uint48).max);

        // // --- Process Each Market --- //
        // for (uint256 i = 0; i < numMarkets; i++) {
        bytes32 marketId = fetchedMarketIds[1];
        console.log("\nProcessing Market ID:", vm.toString(marketId));

        Market memory market = hook.getMarketById(marketId);

        ERC20Mock yesToken = ERC20Mock(address(market.yesToken));
        ERC20Mock(yesToken).approve(address(permit2), type(uint256).max);
        permit2.approve(address(yesToken), positionManagerAddress, type(uint160).max, type(uint48).max);

        ERC20Mock noToken = ERC20Mock(address(market.noToken));
        ERC20Mock(noToken).approve(address(permit2), type(uint256).max);
        permit2.approve(address(noToken), positionManagerAddress, type(uint160).max, type(uint48).max);

        // Use the market's actual settings
        _addLiquidity(collateralAddr, address(yesToken), hookAddress, market.settings);
        _addLiquidity(collateralAddr, address(noToken), hookAddress, market.settings);

        // }
    }

    function _addLiquidity(
        address collateralAddress,
        address tokenAddress,
        address hookAddress,
        MarketSetting memory settings
    ) internal {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(collateralAddress),
            currency1: Currency.wrap(tokenAddress),
            fee: settings.fee,
            hooks: IHooks(hookAddress),
            tickSpacing: settings.tickSpacing
        });

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(
            poolKey, settings.minTick, settings.maxTick, 0.01 ether, 100000 ether, 100000 ether, deployer, bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        uint256 deadline = block.timestamp + 1800;
        uint256 valueToPass = 0;

        positionManager.modifyLiquidities{value: valueToPass}(abi.encode(actions, params), deadline);
    }

    // add this to be excluded from coverage report
    function test() public {}
}
