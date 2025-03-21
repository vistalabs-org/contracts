// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PredictionMarketAMM} from "../src/PredictionMarketAMM.sol";
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

    PredictionMarketAMM public hook;
    PoolCreationHelper public poolCreationHelper;
    ERC20Mock public collateralToken;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC
    PoolSwapTest public poolSwapTest;
    PoolModifyLiquidityTest public poolModifyLiquidityTest;
    NormalQuoter public quoter;

    // Modifier to create a market and add liquidity
    modifier withMarketAndLiquidity() {
        // Create market
        bytes32 marketId = createTestMarket();
        Market memory market = hook.getMarketById(marketId);
        
        // Mint outcome tokens
        uint256 mintAmount = 1000 * 10**6; // 1000 USDC
        collateralToken.approve(address(hook), type(uint256).max);
        hook.mintOutcomeTokens(marketId, mintAmount);
        
        // Add liquidity to the pool
        uint256 liquidityAmount = 399 * 10**18; // 399 YES tokens
        OutcomeToken(address(market.yesToken)).approve(address(hook), type(uint256).max);
        OutcomeToken(address(market.noToken)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(market.yesPoolKey, liquidityAmount);
        
        // Approve tokens for swapping
        OutcomeToken(address(market.yesToken)).approve(address(poolSwapTest), type(uint256).max);
        OutcomeToken(address(market.noToken)).approve(address(poolSwapTest), type(uint256).max);
        collateralToken.approve(address(poolSwapTest), type(uint256).max);
        
        // Store market in a storage variable for tests to access
        testMarket = market;
        _;
    }

    // Storage variable to hold the market for tests
    Market private testMarket;

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
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        // Deploy the hook using foundry cheatcode with specific flags
        deployCodeTo(
            "PredictionMarketAMM.sol:PredictionMarketAMM",
            abi.encode(manager, poolModifyLiquidityTest, poolCreationHelper, quoter),
            flags
        );

        // Initialize hook instance at the deployed address
        hook = PredictionMarketAMM(flags);
        console.log("Hook address:", address(hook));

        // Create and mint a collateral token with a very low address
        address lowAddress = address(0x1); // Very low address
        vm.startPrank(lowAddress);

        // Deploy mock token from the low address
        collateralToken = new ERC20Mock("Test USDC", "USDC", 6);
        vm.stopPrank();

        console.log("Collateral token address:", address(collateralToken));

        // Now mint tokens
        collateralToken.mint(address(this), 1e50 * 10 ** 6);

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

    // test market creation
    function test_createMarket() public {
        // Create market
        bytes32 marketId = createTestMarket();

        // Get market details
        Market memory market = hook.getMarketById(marketId);

        // Verify market details
        assertEq(market.oracle, address(this), "Incorrect oracle");
        assertEq(market.creator, address(this), "Incorrect creator");
        assertEq(market.collateralAddress, address(collateralToken), "Incorrect collateral token");
        assertEq(market.totalCollateral, COLLATERAL_AMOUNT, "Incorrect collateral amount");

        // Convert enum to uint8 for comparison
        assertEq(uint8(market.state), uint8(MarketState.Active), "Market should be active");

        assertEq(market.title, "Will ETH reach $10k in 2024?", "Incorrect title");
        assertEq(
            market.description,
            "Market resolves to YES if ETH price reaches $10,000 before Dec 31, 2024",
            "Incorrect description"
        );
        assertEq(market.endTimestamp, block.timestamp + 30 days, "Incorrect end timestamp");

        // Verify tokens were created
        assertTrue(address(market.yesToken) != address(0), "YES token not created");
        assertTrue(address(market.noToken) != address(0), "NO token not created");

        // Verify token metadata
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
        OutcomeToken noToken = OutcomeToken(address(market.noToken));

        // Verify pools were created
        (uint256 yesReserve0, uint256 yesReserve1) = hook.getReserves(market.yesPoolKey);
        assertEq(yesReserve0, 0, "Initial YES pool reserve0 should be 0");
        assertEq(yesReserve1, 0, "Initial YES pool reserve1 should be 0");

        (uint256 noReserve0, uint256 noReserve1) = hook.getReserves(market.noPoolKey);
        assertEq(noReserve0, 0, "Initial NO pool reserve0 should be 0");
        assertEq(noReserve1, 0, "Initial NO pool reserve1 should be 0");

        // Verify collateral was transferred
        assertEq(collateralToken.balanceOf(address(hook)), COLLATERAL_AMOUNT, "Collateral not transferred to contract");
    }

    function test_mintOutcomeTokens_correctRatio() public {
        // Create market
        bytes32 marketId = createTestMarket();
        Market memory market = hook.getMarketById(marketId);
        
        // Record initial balances
        uint256 initialYesBalance = OutcomeToken(address(market.yesToken)).balanceOf(address(this));
        uint256 initialNoBalance = OutcomeToken(address(market.noToken)).balanceOf(address(this));
        uint256 initialCollateralBalance = collateralToken.balanceOf(address(this));
        
        // Amount to mint
        uint256 mintAmount = 10 * 10**6; // 10 USDC (assuming 6 decimals)
        
        // Calculate expected token amount (adjusting for decimal differences)
        uint256 collateralDecimals = collateralToken.decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals);
        uint256 expectedTokenAmount = mintAmount * decimalAdjustment;
        
        // Approve collateral
        collateralToken.approve(address(hook), mintAmount);
        
        // Mint outcome tokens
        hook.mintOutcomeTokens(marketId, mintAmount);
        
        // Check balances after minting
        uint256 newYesBalance = OutcomeToken(address(market.yesToken)).balanceOf(address(this));
        uint256 newNoBalance = OutcomeToken(address(market.noToken)).balanceOf(address(this));
        uint256 newCollateralBalance = collateralToken.balanceOf(address(this));
        
        // Verify 1:1:1 ratio with decimal adjustment
        assertEq(newYesBalance - initialYesBalance, expectedTokenAmount, "Should mint adjusted amount of YES tokens");
        assertEq(newNoBalance - initialNoBalance, expectedTokenAmount, "Should mint adjusted amount of NO tokens");
        assertEq(initialCollateralBalance - newCollateralBalance, mintAmount, "Should consume equal amount of collateral");
    }

    // Refactored test using the modifier
    function test_swapWithNormalDistribution() public withMarketAndLiquidity {
        // Try to swap
        vm.startPrank(address(this));

        BalanceDelta delta = poolSwapTest.swap(
            testMarket.yesPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 10 * 1e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // Verify the swap followed our normal distribution pricing
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(testMarket.yesPoolKey);
        console.log("Reserve0 after swap:", reserve0);
        console.log("Reserve1 after swap:", reserve1);

        // The output amount should be less than input due to slippage
        // Call the amount0() and amount1() functions
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        console.log("amount0", amount0);
        console.log("amount1", amount1);
        assertTrue(-amount1 < amount0, "Output should be less than input due to slippage");
    }

    function test_addLiquidity() public {
        // Create market using helper function
        bytes32 marketId = createTestMarket();

        Market memory market = hook.getMarketById(marketId);

        // Approve tokens
        collateralToken.approve(address(hook), 10 * 1e6);
        OutcomeToken(address(market.yesToken)).approve(address(hook), 10 * 1e18);
        OutcomeToken(address(market.noToken)).approve(address(hook), 10 * 1e18);
        // Add liquidity through hook
        hook.addLiquidity(market.yesPoolKey, 10 * 1e6);

        // Check reserves using public function
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(market.yesPoolKey);
        assertEq(reserve0, 10 * 1e6, "Incorrect reserve0");
        assertEq(reserve1, 10 * 1e6, "Incorrect reserve1");
    }
}
