// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {CreateMarketParams} from "../src/types/MarketTypes.sol";
import "forge-std/console.sol";
// Uniswap libraries
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";
import {Market, MarketState, CreateMarketParams} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract TestMarketSwap is Script {
    PoolSwapTest public swapRouter;
    PredictionMarketHook public hook;
    PoolManager public manager;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    PoolSwapTest public poolSwapTest;
    PoolCreationHelper public poolCreationHelper;
    ERC20Mock public collateralToken;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC
    PoolKey public poolKey;
    
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_SEPOLIA_PK");
        vm.startBroadcast(deployerPrivateKey);

        address hookAddress = 0xABF6985E92fC0d4A8F7b8ceC535aD0215DbD0a80;
        hook = PredictionMarketHook(hookAddress);
        manager = PoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
        modifyLiquidityRouter = PoolModifyLiquidityTest(0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB);
        swapRouter = PoolSwapTest(0x9140a78c1A137c7fF1c151EC8231272aF78a99A4);

        // Use a specific market ID (this should match an existing market)
        bytes32 marketId = bytes32(uint256(1)); // For market ID 1
        console.log("Using Market ID:", vm.toString(marketId));

        // Get market data using the ID
        Market memory market = hook.getMarketById(marketId);
        PoolKey memory yesPoolKey = market.yesPoolKey;

        // Create the pool key
        poolKey = PoolKey({
            currency0: yesPoolKey.currency0,
            currency1: yesPoolKey.currency1,
            fee: yesPoolKey.fee,
            tickSpacing: yesPoolKey.tickSpacing,
            hooks: hook
        });

        // Create the swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1000000,
            sqrtPriceLimitX96: 0
        });

        // Create the hook params
        bytes memory hookData = "";

        // Execute the swap
        swapRouter.swap(
            poolKey,
            params,
            PoolSwapTest.TestSettings({
                takeClaims: true,
                settleUsingBurn: false
            }),
            hookData
        );

        vm.stopBroadcast();
    }
}
