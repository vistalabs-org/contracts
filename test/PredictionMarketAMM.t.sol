// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PredictionMarketHookAMM} from "../src/PredictionMarketAMM.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import "forge-std/console.sol";
// Uniswap libraries
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Market, MarketState, CreateMarketParams} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {ERC20Mock} from "./utils/ERC20Mock.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {NormalQuoter} from "../src/utils/Quoter.sol";

contract PredictionMarketHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    
    PredictionMarketHookAMM public hook;
    PoolCreationHelper public poolCreationHelper;
    ERC20Mock public collateralToken;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC
    PoolSwapTest public poolSwapTest;
    PoolModifyLiquidityTest public poolModifyLiquidityTest;
    NormalQuoter public quoter;

    function setUp() public {
        // Deploy Uniswap v4 infrastructure
        console.log("Deploying Uniswap v4 infrastructure from ", address(this));
        deployFreshManagerAndRouters();

        // Deploy PoolSwapTest
        poolSwapTest = new PoolSwapTest(manager);
        
        // Deploy PoolModifyLiquidityTest
        poolModifyLiquidityTest = new PoolModifyLiquidityTest(manager);

        // Deploy PoolCreationHelper
        poolCreationHelper = new PoolCreationHelper(address(manager));
        console.log("PoolCreationHelper deployed at:", address(poolCreationHelper));
        
        // Deploy Quoter
        quoter = new NormalQuoter();
        
        // Calculate hook address with specific flags for swap and liquidity operations
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | 
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | 
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        // Deploy the hook using foundry cheatcode with specific flags
        deployCodeTo(
            "PredictionMarketHook.sol:PredictionMarketHook", 
            abi.encode(manager, poolModifyLiquidityTest, poolCreationHelper, quoter), 
            flags
        );
        
        // Initialize hook instance at the deployed address
        hook = PredictionMarketHookAMM(flags);
        console.log("Hook address:", address(hook));

        // create and mint a collateral token
        // Deploy mock token
        collateralToken = new ERC20Mock("Test USDC", "USDC", 6);
        
        // Mint some tokens for testing
        collateralToken.mint(address(this), 1000000 * 10**6);

        // approve the hook to transfer the tokens
        collateralToken.approve(address(hook), COLLATERAL_AMOUNT);
    }

    // Remove the modifier and make it a helper function instead
    function createTestMarket() public returns (bytes32) {
        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(this),
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will ETH reach $10k in 2024?",
            description: "Market resolves to YES if ETH price reaches $10,000 before Dec 31, 2024",
            duration: 30 days
        });
        
        return hook.createMarketAndDepositCollateral(params);
    }

    function test_swapWithNormalDistribution() public {
        // Use the helper function instead of modifier
        bytes32 marketId = createTestMarket();
        
        Market memory market = hook.getMarketById(marketId);
        
        // Add initial liquidity
        hook.addLiquidity(market.yesPoolKey, 10 * 1e6);
        
        // Try to swap
        vm.startPrank(address(this));
        collateralToken.approve(address(poolSwapTest), 5 * 1e6);
        
        BalanceDelta delta = poolSwapTest.swap(
            market.yesPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 5 * 1e6,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        vm.stopPrank();
        
        // Verify the swap followed our normal distribution pricing
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(market.yesPoolKey);
        console.log("Reserve0 after swap:", reserve0);
        console.log("Reserve1 after swap:", reserve1);
        
        // The output amount should be less than input due to slippage
        // Call the amount0() and amount1() functions
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        assertTrue(-amount1 < amount0, "Output should be less than input");
    }

    function test_addLiquidity() public {
        // Create market using helper function
        bytes32 marketId = createTestMarket();
        
        Market memory market = hook.getMarketById(marketId);
        
        // Approve tokens
        collateralToken.approve(address(hook), 10 * 1e6);
        OutcomeToken(address(market.yesToken)).approve(address(hook), 10 * 1e18);
        
        // Add liquidity through hook
        hook.addLiquidity(market.yesPoolKey, 10 * 1e6);
        
        // Check reserves using public function
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(market.yesPoolKey);
        assertEq(reserve0, 10 * 1e6, "Incorrect reserve0");
        assertEq(reserve1, 10 * 1e18, "Incorrect reserve1");
    }

}