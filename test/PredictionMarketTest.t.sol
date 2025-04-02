// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
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
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";

contract PredictionMarketHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PredictionMarketHook public hook;
    PoolCreationHelper public poolCreationHelper;
    ERC20Mock public collateralToken;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC
    PoolSwapTest public poolSwapTest;
    PoolModifyLiquidityTest public poolModifyLiquidityTest;
    StateView public stateView;

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

        // Calculate hook address with specific flags for swap and liquidity operations
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG)
                ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        // Deploy the hook using foundry cheatcode with specific flags
        deployCodeTo(
            "PredictionMarketHook.sol:PredictionMarketHook",
            abi.encode(manager, poolModifyLiquidityTest, poolCreationHelper),
            flags
        );

        // Initialize hook instance at the deployed address
        hook = PredictionMarketHook(flags);
        console.log("Hook address:", address(hook));

        // create and mint a collateral token
        // Deploy mock token
        collateralToken = new ERC20Mock("Test USDC", "USDC", 6);

        // Mint some tokens for testing
        collateralToken.mint(address(this), 1000000 * 10 ** 6);

        // approve the hook to transfer the tokens
        collateralToken.approve(address(hook), type(uint256).max);

        // Deploy StateView
        stateView = new StateView(manager);
    }

    // Modifier to create a market and return its ID
    modifier createMarket(bytes32 marketId) {
        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(this),
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will ETH reach $10k in 2024?",
            description: "Market resolves to YES if ETH price reaches $10,000 before Dec 31, 2024",
            duration: 30 days,
            curveId: 0
        });

        marketId = hook.createMarketAndDepositCollateral(params);
        _;
    }

    // Modifier to create a market and add liquidity
    modifier createMarketWithLiquidity(bytes32 marketId) {
        // Create market first
        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(this),
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will ETH reach $10k in 2024?",
            description: "Market resolves to YES if ETH price reaches $10,000 before Dec 31, 2024",
            duration: 30 days,
            curveId: 0
        });

        marketId = hook.createMarketAndDepositCollateral(params);

        // Get market details
        Market memory market = hook.getMarketById(marketId);

        // Get token references
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
        OutcomeToken noToken = OutcomeToken(address(market.noToken));

        // Set up price range for prediction market (0.01-0.99)
        int24 tickSpacing = 100;
        int24 minTick = -9200; // ~0.01 USDC
        int24 maxTick = -100; // ~0.99 USDC
        int24 initialTick = -6900; // ~0.5 USDC

        // Ensure ticks are valid with the tick spacing
        minTick = (minTick / tickSpacing) * tickSpacing;
        maxTick = (maxTick / tickSpacing) * tickSpacing;

        // Get the sqrtPriceX96 for the initial tick (0.5 USDC)
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initialTick);

        // Prepare liquidity amounts
        uint256 liquidityCollateral = 50 * 1e6; // 50 USDC
        uint256 liquidityOutcomeTokens = 100 * 1e18; // 100 outcome tokens

        // Approve tokens for liquidity provision
        collateralToken.approve(address(poolModifyLiquidityTest), type(uint256).max);
        yesToken.approve(address(poolModifyLiquidityTest), type(uint256).max);
        noToken.approve(address(poolModifyLiquidityTest), type(uint256).max);

        // Calculate liquidity amount
        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            liquidityCollateral,
            liquidityOutcomeTokens
        );

        // Add liquidity to YES pool
        poolModifyLiquidityTest.modifyLiquidity(
            market.yesPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: 0
            }),
            new bytes(0)
        );

        // Add liquidity to NO pool
        poolModifyLiquidityTest.modifyLiquidity(
            market.noPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: 0
            }),
            new bytes(0)
        );

        _;
    }

    function test_createMarketandDepositCollateral() public {
        // Create a market and get its ID
        bytes32 marketId = createTestMarket();

        // Verify market was created successfully
        assertTrue(marketId != bytes32(0), "Market ID should not be zero");

        // Get market details
        Market memory market = hook.getMarketById(marketId);

        // Verify market details
        assertEq(market.oracle, address(this), "Oracle address mismatch");
        assertEq(market.creator, address(this), "Creator address mismatch");
        assertEq(uint8(market.state), uint8(MarketState.Active), "Market should be active");
        assertEq(market.totalCollateral, COLLATERAL_AMOUNT, "Collateral amount mismatch");
        assertEq(market.collateralAddress, address(collateralToken), "Collateral address mismatch");
        assertTrue(market.endTimestamp > block.timestamp, "End timestamp should be in the future");

        // Verify tokens were created
        assertTrue(address(market.yesToken) != address(0), "YES token not created");
        assertTrue(address(market.noToken) != address(0), "NO token not created");
    }

    function test_createMarketAndAddLiquidity() public {
        // Create a market with liquidity and get its ID
        bytes32 marketId = createTestMarketWithLiquidity();

        // Get market details
        Market memory market = hook.getMarketById(marketId);

        // Verify creator received outcome tokens
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
        OutcomeToken noToken = OutcomeToken(address(market.noToken));

        // Verify tokens were transferred for liquidity
        assertLt(
            yesToken.balanceOf(address(this)), COLLATERAL_AMOUNT, "Creator should have spent YES tokens on liquidity"
        );

        assertLt(
            noToken.balanceOf(address(this)), COLLATERAL_AMOUNT, "Creator should have spent NO tokens on liquidity"
        );
    }

    // Instead of trying to modify the parameter, return the value
    function createTestMarket() internal returns (bytes32) {
        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(this),
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will ETH reach $10k in 2024?",
            description: "Market resolves to YES if ETH price reaches $10,000 before Dec 31, 2024",
            duration: 30 days,
            curveId: 0
        });

        return hook.createMarketAndDepositCollateral(params);
    }

    // Function to create a market and add liquidity
    function createTestMarketWithLiquidity() internal returns (bytes32) {
        // Create market first
        bytes32 marketId = createTestMarket();

        // Get market details
        Market memory market = hook.getMarketById(marketId);

        // Get token references
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
        OutcomeToken noToken = OutcomeToken(address(market.noToken));

        // Set up price range for prediction market (0.01-0.99)
        int24 tickSpacing = 100;
        int24 minTick = -9200; // ~0.01 USDC
        int24 maxTick = -100; // ~0.99 USDC
        int24 initialTick = -6900; // ~0.5 USDC

        // Ensure ticks are valid with the tick spacing
        minTick = (minTick / tickSpacing) * tickSpacing;
        maxTick = (maxTick / tickSpacing) * tickSpacing;

        // Get the sqrtPriceX96 for the initial tick (0.5 USDC)
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initialTick);

        // Prepare liquidity amounts
        uint256 liquidityCollateral = 50 * 1e6; // 50 USDC
        uint256 liquidityOutcomeTokens = 100 * 1e18; // 100 outcome tokens

        // Approve tokens for liquidity provision
        collateralToken.approve(address(poolModifyLiquidityTest), type(uint256).max);
        yesToken.approve(address(poolModifyLiquidityTest), type(uint256).max);
        noToken.approve(address(poolModifyLiquidityTest), type(uint256).max);

        // Calculate liquidity amount
        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            liquidityCollateral,
            liquidityOutcomeTokens
        );

        // Add liquidity to YES pool
        poolModifyLiquidityTest.modifyLiquidity(
            market.yesPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: 0
            }),
            new bytes(0)
        );

        // Add liquidity to NO pool
        poolModifyLiquidityTest.modifyLiquidity(
            market.noPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: 0
            }),
            new bytes(0)
        );

        return marketId;
    }

    function test_buyYesSharesFromPool() public {
        // Create a market with liquidity
        bytes32 marketId = createTestMarketWithLiquidity();
        console.log("liquidity created");

        // Get market details
        Market memory market = hook.getMarketById(marketId);
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
        OutcomeToken noToken = OutcomeToken(address(market.noToken));

        // Create a user who will buy YES tokens
        address user = makeAddr("user");

        // Give user some collateral tokens
        collateralToken.mint(address(this), 1e6 * 1e6); // 10 USDC

        // Record balances before swap
        uint256 userCollateralBefore = collateralToken.balanceOf(address(this));
        uint256 userYesTokensBefore = yesToken.balanceOf(address(this));
        uint256 userNoTokensBefore = noToken.balanceOf(address(this));

        console.log("User collateral before swap:", userCollateralBefore);
        console.log("User YES tokens before swap:", userYesTokensBefore);

        // Approve the pool manager to use the test contract's tokens with a buffer for slippage
        collateralToken.approve(address(poolSwapTest), type(uint256).max);
        ERC20Mock(address(market.yesToken)).approve(address(poolSwapTest), type(uint256).max);
        ERC20Mock(address(market.noToken)).approve(address(poolSwapTest), type(uint256).max);
        console.log("approved");

        // In our pool setup, token0 is collateral and token1 is YES token
        bool zeroForOne = true; // Swapping collateral (token0) for YES tokens (token1)
        int256 amountSpecified = 5 * 1e6; // Swap 5 USDC
        uint160 sqrtPriceLimitX96 = 4295128739 + 1; // Minimum valid sqrtPriceX96 + 1

        // Try executing the swap and assert it doesn't revert
        bool swapSucceeded;
        BalanceDelta delta;

        try poolSwapTest.swap(
            market.yesPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        ) returns (BalanceDelta result) {
            swapSucceeded = true;
            delta = result;
        } catch {
            swapSucceeded = false;
        }

        // Assert swap didn't revert
        assertTrue(swapSucceeded, "Swap should not revert");

    }

    // Helper function to perform a swap and return tokens received
    function _performSwap(bytes32 marketId, address user, uint256 collateralAmount)
        internal
        returns (uint256 tokensReceived)
    {
        // Get market details
        Market memory market = hook.getMarketById(marketId);
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));

        // User transfers collateral to the test contract
        vm.prank(user);
        collateralToken.transfer(address(this), collateralAmount);

        // Record token balance before swap
        uint256 testContractYesTokensBefore = yesToken.balanceOf(address(this));

        // Approve tokens for swap with a buffer for slippage (10% more than requested)
        uint256 approvalAmount = collateralAmount * 110 / 100; // Add 10% buffer
        collateralToken.approve(address(poolSwapTest), approvalAmount);

        // Execute the swap
        poolSwapTest.swap(
            market.yesPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, // Swapping collateral for YES tokens
                amountSpecified: int256(collateralAmount),
                sqrtPriceLimitX96: 4295128739 + 1 // Minimum valid sqrtPriceX96 + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );

        // Calculate tokens received
        tokensReceived = yesToken.balanceOf(address(this)) - testContractYesTokensBefore;

        // Transfer tokens to user
        yesToken.transfer(user, tokensReceived);

        return tokensReceived;
    }

    function test_resolveAndClaim() public {
        // Create market with liquidity
        bytes32 marketId = createTestMarketWithLiquidity();
        Market memory market = hook.getMarketById(marketId);
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));

        // Setup user
        address user = makeAddr("user");
        collateralToken.mint(user, 20 * 1e6); // 20 USDC instead of 10

        // Perform swap and get tokens received
        uint256 yesTokensReceived = _performSwap(marketId, user, 6 * 1e6);
        console.log("YES tokens received by user:", yesTokensReceived);

        // Record balances before claiming
        uint256 userCollateralBefore = collateralToken.balanceOf(user);

        // Oracle resolves the market as YES
        hook.resolveMarket(marketId, true);

        // User claims winnings
        vm.startPrank(user);
        yesToken.approve(address(hook), yesTokensReceived);
        hook.claimWinnings(marketId);

        // Verify claim was successful
        uint256 userCollateralAfter = collateralToken.balanceOf(user);
        uint256 collateralReceived = userCollateralAfter - userCollateralBefore;

        console.log("Collateral received from claim:", collateralReceived);

        // Verify token burning and collateral received
        assertEq(yesToken.balanceOf(user), 0, "All YES tokens should be burned");
        assertEq(collateralReceived, yesTokensReceived / 1e12, "User should receive 1 USDC per YES token");

        // Verify user is marked as claimed
        assertTrue(hook.hasClaimed(marketId, user), "User should be marked as claimed");

        // Try to claim again (should revert)
        vm.expectRevert(PredictionMarketHook.AlreadyClaimed.selector);
        hook.claimWinnings(marketId);

        vm.stopPrank();
    }

    // Test for getMarkets function
    function test_getMarkets() public {
        // Create multiple markets

        collateralToken.mint(address(this), 1e6 * 1e6);
        collateralToken.approve(address(hook), type(uint256).max); // Approve hook to spend tokens

        bytes32 market1Id = createTestMarket();
        bytes32 market2Id = createTestMarket();
        bytes32 market3Id = createTestMarket();
        bytes32 market4Id = createTestMarket();
        bytes32 market5Id = createTestMarket();

        // Test getting all markets
        Market[] memory allMarkets = hook.getAllMarkets();
        assertEq(allMarkets.length, 5, "Should have 5 markets");

        // Test getting market count
        uint256 count = hook.getMarketCount();
        assertEq(count, 5, "Market count should be 5");

        // Test pagination - first page (offset 0, limit 2)
        Market[] memory page1 = hook.getMarkets(0, 2);
        assertEq(page1.length, 2, "First page should have 2 markets");
        assertEq(keccak256(abi.encode(page1[0])), keccak256(abi.encode(allMarkets[0])), "First market should match");
        assertEq(keccak256(abi.encode(page1[1])), keccak256(abi.encode(allMarkets[1])), "Second market should match");
    }

    function test_initialOutcomeTokenPrices() public {
        // Create a market with liquidity
        bytes32 marketId = createTestMarketWithLiquidity();
        
        // Get market details
        Market memory market = hook.getMarketById(marketId);
        
        // Calculate the current price for YES tokens
        (uint160 sqrtPriceX96Yes,,,) = stateView.getSlot0(market.yesPoolKey.toId());
        uint256 priceYesInCollateral = calculatePrice(sqrtPriceX96Yes, true);
        
        // Calculate the current price for NO tokens
        (uint160 sqrtPriceX96No,,,) = stateView.getSlot0(market.noPoolKey.toId());
        uint256 priceNoInCollateral = calculatePrice(sqrtPriceX96No, true);
        
        // Log the prices
        console.log("YES token price in USDC: ", priceYesInCollateral / 1e6);
        console.log("NO token price in USDC: ", priceNoInCollateral / 1e6);
        
        // Check that prices are close to 0.5 USDC (with some tolerance for rounding)
        assertApproxEqRel(priceYesInCollateral, 0.5 * 1e6, 0.05e18); // 5% tolerance
        assertApproxEqRel(priceNoInCollateral, 0.5 * 1e6, 0.05e18);  // 5% tolerance
    }

    // Helper function to calculate price from sqrtPriceX96
    function calculatePrice(uint160 sqrtPriceX96, bool zeroForOne) private pure returns (uint256) {
        uint256 price;
        if (zeroForOne) {
            // If collateral is token0, price = (1/sqrtPrice)^2
            price = (2**192 * 1e6) / uint256(sqrtPriceX96) ** 2;
        } else {
            // If collateral is token1, price = sqrtPrice^2
            price = (uint256(sqrtPriceX96) ** 2 * 1e6) / 2**192;
        }
        return price;
    }


}
