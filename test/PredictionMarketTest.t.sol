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
import {Market, MarketState, MarketSetting, CreateMarketParams} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {ERC20Mock} from "./utils/ERC20Mock.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {AIOracleServiceManager} from "../src/oracle/AIOracleServiceManager.sol";
import {AIAgentRegistry} from "../src/oracle/AIAgentRegistry.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

contract PredictionMarketHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PredictionMarketHook public hook;
    PoolCreationHelper public poolCreationHelper;
    ERC20Mock public collateralToken;
    AIOracleServiceManager public oracleManager;
    AIAgentRegistry public registry;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC
    PoolSwapTest public poolSwapTest;
    PoolModifyLiquidityTest public poolModifyLiquidityTest;
    StateView public stateView;

    // Add these constants at the top of the test contract after other state variables
    uint24 public constant TEST_FEE = 3000; // 0.3% fee tier
    int24 public constant TEST_TICK_SPACING = 60; // Corresponding to 0.3% fee tier
    int24 public constant TEST_STARTING_TICK = 6900; // ~0.5 USDC or 1 USDC = 2 YES
    int24 public constant TEST_MIN_TICK = 0; // Minimum tick (adjusted by tickSpacing in hook)
    int24 public constant TEST_MAX_TICK = 207300; // Maximum tick (adjusted by tickSpacing in hook)

    function setUp() public {
        // Deploy Uniswap v4 infrastructure
        console.log("Deploying Uniswap v4 infrastructure from ", address(this));
        deployFreshManagerAndRouters();

        // Deploy PoolSwapTest
        poolSwapTest = new PoolSwapTest(manager);

        // create and mint a collateral token
        // Deploy mock token
        collateralToken = new ERC20Mock("Test USDC", "USDC", 6);
        collateralToken.mint(address(this), 1000000 * 10 ** 6);

        // Deploy PoolModifyLiquidityTest
        poolModifyLiquidityTest = new PoolModifyLiquidityTest(manager);

        // Deploy PoolCreationHelper
        poolCreationHelper = new PoolCreationHelper(address(manager));
        console.log("PoolCreationHelper deployed at:", address(poolCreationHelper));

        // --- Deploy Oracle Manager and Registry ---
        // Deploy Registry first (now takes no arguments)
        registry = new AIAgentRegistry(); // Pass address(0) for service manager initially
        console.log("Actual Registry deployed at:", address(registry));

        // Deploy AIOracleServiceManager implementation, passing the actual registry address
        oracleManager = new AIOracleServiceManager(address(registry));
        console.log("Oracle Manager implementation deployed at:", address(oracleManager));
        // NOTE: The registry instance holds address(0) for its serviceManager

        // --- Deploy Hook using HookMiner and CREATE2 ---
        // 1. Define hook flags required by PredictionMarketHook
        uint24 hookFlags = uint24(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

        // 2. Get creation code and *updated* constructor arguments (using actual oracle manager)
        bytes memory hookCreationCode = type(PredictionMarketHook).creationCode;
        // *** Use oracleManager address here ***
        bytes memory hookConstructorArgs = abi.encode(manager, poolCreationHelper, address(this));

        // 3. Calculate the deterministic hook address and salt using HookMiner
        (address calculatedHookAddr, bytes32 salt) = HookMiner.find(
            address(this), // Deployer
            hookFlags, // Required hook flags
            hookCreationCode, // Contract creation code
            hookConstructorArgs // Constructor arguments
        );
        console.log("Calculated Hook address:", calculatedHookAddr);

        // --- Initialize Oracle Manager ---
        // Now that we know the calculated hook address, initialize the oracle manager
        oracleManager.initialize(
            address(this), // Owner
            1, // Minimum Responses
            10000, // Consensus Threshold (100%)
            calculatedHookAddr // The address where the hook WILL be deployed
        );
        console.log("Oracle Manager initialized.");

        // 4. Deploy the hook using CREATE2
        bytes memory hookDeploymentCode = abi.encodePacked(hookCreationCode, hookConstructorArgs);
        address deployedHookAddr;
        assembly {
            deployedHookAddr := create2(0, add(hookDeploymentCode, 0x20), mload(hookDeploymentCode), salt)
        }
        require(deployedHookAddr == calculatedHookAddr, "CREATE2 deployment address mismatch");
        require(deployedHookAddr != address(0), "Hook deployment failed");

        // 5. Initialize hook instance at the deployed address
        hook = PredictionMarketHook(payable(deployedHookAddr)); // Use the actually deployed address
        console.log("Hook address (deployed via CREATE2):", address(hook));

        // *** 6. Set the Oracle address on the Hook ***
        hook.setOracleServiceManager(address(oracleManager));
        console.log("Oracle address set on Hook.");
        // --- End Hook Deployment ---

        // Deploy StateView
        stateView = new StateView(manager);

        // *** Approve hook AFTER it has been deployed and assigned ***
        require(address(hook) != address(0), "Hook address is zero before final approval");
        collateralToken.approve(address(hook), type(uint256).max);
        console.log("Approved Hook to spend collateral.");
    }

    // Modifier to create a market and return its ID
    modifier createMarket(bytes32 marketId) {
        MarketSetting memory settings = MarketSetting({
            fee: TEST_FEE,
            tickSpacing: TEST_TICK_SPACING,
            startingTick: TEST_STARTING_TICK,
            minTick: TEST_MIN_TICK,
            maxTick: TEST_MAX_TICK
        });

        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(oracleManager),
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will ETH reach $10k in 2024?",
            description: "Market resolves to YES if ETH price reaches $10,000 before Dec 31, 2024",
            duration: 30 days,
            settings: settings
        });

        marketId = hook.createMarketAndDepositCollateral(params);
        _;
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
        uint256 mintAmount = 10 * 10 ** 6; // 10 USDC (assuming 6 decimals)

        // Calculate expected token amount (adjusting for decimal differences)
        uint256 collateralDecimals = collateralToken.decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals);
        uint256 expectedTokenAmount = mintAmount * decimalAdjustment;

        // Approve collateral
        // Transfer collateral to the hook *before* calling mintOutcomeTokens.
        bool sent = collateralToken.transfer(address(hook), mintAmount);
        require(sent, "Collateral transfer failed for test_mintOutcomeTokens_correctRatio");

        // Mint outcome tokens, passing the collateral address explicitly
        hook.mintOutcomeTokens(marketId, mintAmount, address(collateralToken));

        // Check balances after minting
        uint256 newYesBalance = OutcomeToken(address(market.yesToken)).balanceOf(address(this));
        uint256 newNoBalance = OutcomeToken(address(market.noToken)).balanceOf(address(this));
        uint256 newCollateralBalance = collateralToken.balanceOf(address(this));

        assertEq(newYesBalance - initialYesBalance, expectedTokenAmount, "Should mint adjusted amount of YES tokens");
        assertEq(newNoBalance - initialNoBalance, expectedTokenAmount, "Should mint adjusted amount of NO tokens");
        assertEq(
            initialCollateralBalance - newCollateralBalance, mintAmount, "Should consume equal amount of collateral"
        );

        console.log("received yes tokens: %s", newYesBalance - initialYesBalance);
        console.log("received no tokens: %s", newNoBalance - initialNoBalance);
        console.log("received collateral: %s", initialCollateralBalance - newCollateralBalance);
    }

    // Modifier to create a market and add liquidity
    modifier createMarketWithLiquidity(bytes32 marketId) {
        // Create the MarketSetting struct first
        MarketSetting memory settings = MarketSetting({
            fee: TEST_FEE,
            tickSpacing: TEST_TICK_SPACING,
            startingTick: TEST_STARTING_TICK,
            minTick: TEST_MIN_TICK,
            maxTick: TEST_MAX_TICK
        });

        // Create market first
        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(oracleManager),
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will ETH reach $10k in 2024?",
            description: "Market resolves to YES if ETH price reaches $10,000 before Dec 31, 2024",
            duration: 30 days,
            settings: settings // Now settings is properly defined
        });

        marketId = hook.createMarketAndDepositCollateral(params);

        // Get market details
        Market memory market = hook.getMarketById(marketId);

        // Get token references
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
        OutcomeToken noToken = OutcomeToken(address(market.noToken));

        // Set up price range for prediction market (0.01-0.99)
        int24 tickSpacing = 100;
        int24 minTick = 0; // ~0.01 USDC
        int24 maxTick = 207000; // ~0.99 USDC
        int24 initialTick = 6900; // ~0.5 USDC or 1 USDC = 2 YES

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
        assertEq(market.oracle, address(oracleManager), "Market.oracle address mismatch");
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

        // Get the decimal adjustment factor
        uint256 collateralDecimals = ERC20Mock(market.collateralAddress).decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals);

        // Calculate expected token amount after minting
        uint256 expectedMintedAmount = COLLATERAL_AMOUNT * decimalAdjustment;

        // Verify creator received outcome tokens
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
        OutcomeToken noToken = OutcomeToken(address(market.noToken));

        // Verify tokens were transferred for liquidity
        // Account for decimal adjustment in assertions
        assertLe(
            yesToken.balanceOf(address(this)), expectedMintedAmount, "Creator should have spent YES tokens on liquidity"
        );

        assertLe(
            noToken.balanceOf(address(this)), expectedMintedAmount, "Creator should have spent NO tokens on liquidity"
        );
    }

    // Instead of trying to modify the parameter, return the value
    function createTestMarket() internal returns (bytes32) {
        MarketSetting memory settings = MarketSetting({
            fee: TEST_FEE,
            tickSpacing: TEST_TICK_SPACING,
            startingTick: TEST_STARTING_TICK,
            minTick: TEST_MIN_TICK,
            maxTick: TEST_MAX_TICK
        });

        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(oracleManager),
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will ETH reach $10k in 2024?",
            description: "Market resolves to YES if ETH price reaches $10,000 before Dec 31, 2024",
            duration: 30 days,
            settings: settings
        });

        return hook.createMarketAndDepositCollateral(params);
    }

    // Function to create a market and add liquidity
    function createTestMarketWithLiquidity() internal returns (bytes32) {
        // Create market first
        bytes32 marketId = createTestMarket();

        require(hook.getMarketById(marketId).state == MarketState.Active, "Market not Active before adding liquidity");

        // Get market details
        Market memory market = hook.getMarketById(marketId);

        // Get token references
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
        OutcomeToken noToken = OutcomeToken(address(market.noToken));

        // Set up price range for prediction market (0.01-0.99)
        int24 tickSpacing = 100;
        int24 minTick = 0; // ~0.01 USDC
        int24 maxTick = 207000; // ~0.99 USDC
        int24 initialTick = 6900; // ~0.5 USDC or 1 USDC = 2 YES

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
        // Create a market with liquidity (this also activates it)
        bytes32 marketId = createTestMarketWithLiquidity();
        console.log("Liquidity created and market activated for test_buyYesSharesFromPool");

        // Get market details
        Market memory market = hook.getMarketById(marketId);
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));

        // Give user some collateral tokens
        collateralToken.mint(address(this), 1e6 * 1e6); // 10 USDC

        // Record balances before swap
        uint256 userCollateralBefore = collateralToken.balanceOf(address(this));
        uint256 userYesTokensBefore = yesToken.balanceOf(address(this));

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

    function test_resolveAndClaim() public {
        // Create a market with liquidity
        bytes32 marketId = createTestMarketWithLiquidity();
        Market memory market = hook.getMarketById(marketId);
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
        uint256 initialCollateralBalance = collateralToken.balanceOf(address(this));
        uint256 initialYesBalance = yesToken.balanceOf(address(this));

        // Resolve the market (simulate Oracle callback)
        // First, close the market and put it in resolution
        vm.warp(market.endTimestamp + 1); // Fast forward time
        hook.closeMarket(marketId);
        hook.enterResolution(marketId); // This should now succeed as oracle address is set

        // Now resolve (caller must be the oracle address set in setUp)
        vm.prank(address(oracleManager));
        hook.resolveMarket(marketId, true); // Resolve as YES

        // Verify market state
        market = hook.getMarketById(marketId); // Refresh market state
        assertEq(uint8(market.state), uint8(MarketState.Resolved), "Market should be resolved");
        assertTrue(market.outcome, "Market outcome should be YES (true)");

        // Claim winnings
        // *** Approve the hook to burn the winning tokens FIRST ***
        uint256 yesBalanceToClaim = yesToken.balanceOf(address(this));
        require(yesBalanceToClaim > 0, "Test requires YES balance to claim"); // Sanity check
        yesToken.approve(address(hook), yesBalanceToClaim);

        hook.claimWinnings(marketId);

        // Verify collateral transfer
        uint256 collateralDecimals = collateralToken.decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals);
        uint256 expectedCollateralClaim = initialYesBalance / decimalAdjustment;
        uint256 finalCollateralBalance = collateralToken.balanceOf(address(this));
        assertEq(
            finalCollateralBalance - initialCollateralBalance, expectedCollateralClaim, "Incorrect collateral claimed"
        );

        // Verify tokens were burned
        assertEq(yesToken.balanceOf(address(this)), 0, "YES tokens should be burned");

        // Verify user is marked as claimed
        assertTrue(hook.hasClaimed(marketId, address(this)), "User should be marked as claimed");
    }

    // Test for getMarkets function
    function test_getMarkets() public {
        // Create multiple markets

        collateralToken.mint(address(this), 1e6 * 1e6);
        collateralToken.approve(address(hook), type(uint256).max); // Approve hook to spend tokens

        bytes32 market1Id = createTestMarket();
        console.log("market1Id: %s", uint256(market1Id));
        bytes32 market2Id = createTestMarket();
        console.log("market2Id: %s", uint256(market2Id));
        bytes32 market3Id = createTestMarket();
        console.log("market3Id: %s", uint256(market3Id));
        bytes32 market4Id = createTestMarket();
        console.log("market4Id: %s", uint256(market4Id));
        bytes32 market5Id = createTestMarket();
        console.log("market5Id: %s", uint256(market5Id));

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
        console.log("YES token price in USDC: ", priceYesInCollateral);
        console.log("NO token price in USDC: ", priceNoInCollateral);

        // Check that prices are close to 0.5 USDC (with some tolerance for rounding)
        assertApproxEqRel(priceYesInCollateral, 0.5 * 1e6, 0.05e18); // 5% tolerance
        assertApproxEqRel(priceNoInCollateral, 0.5 * 1e6, 0.05e18); // 5% tolerance
    }

    // Helper function to calculate price from sqrtPriceX96
    function calculatePrice(uint160 sqrtPriceX96, bool zeroForOne) private pure returns (uint256) {
        uint256 price;
        if (zeroForOne) {
            // If collateral is token0, price = (1/sqrtPrice)^2
            price = (2 ** 192 * 1e6) / uint256(sqrtPriceX96) ** 2;
        } else {
            // If collateral is token1, price = sqrtPrice^2
            price = (uint256(sqrtPriceX96) ** 2 * 1e6) / 2 ** 192;
        }
        return price;
    }

    // Test for getAllMarketIds
    function test_getAllMarketIds() public {
        // Create multiple markets
        bytes32 market1Id = createTestMarket();
        bytes32 market2Id = createTestMarket();
        bytes32 market3Id = createTestMarket();

        // Get all market IDs
        bytes32[] memory allIds = hook.getAllMarketIds();

        // Verify all created markets are included
        assertEq(allIds.length, 3, "Should return 3 market IDs");
        assertEq(allIds[allIds.length - 3], market1Id, "First market ID should match");
        assertEq(allIds[allIds.length - 2], market2Id, "Second market ID should match");
        assertEq(allIds[allIds.length - 1], market3Id, "Third market ID should match");
    }

    // Test for activateMarket
    function test_activateMarket() public {
        // We need to create a market that isn't already active
        // For this test, we'll need to create a custom market creation function
        MarketSetting memory settings = MarketSetting({
            fee: TEST_FEE,
            tickSpacing: TEST_TICK_SPACING,
            startingTick: TEST_STARTING_TICK,
            minTick: TEST_MIN_TICK,
            maxTick: TEST_MAX_TICK
        });

        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(oracleManager),
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Test Market for Activation",
            description: "This market is created in inactive state",
            duration: 30 days,
            settings: settings
        });

        bytes32 marketId = hook.createMarketAndDepositCollateral(params);

        // Verify market is now Active
        Market memory marketAfter = hook.getMarketById(marketId);
        assertEq(uint8(marketAfter.state), uint8(MarketState.Active), "Market should be Active after creation");
    }

    // Test for cancelMarket
    function test_cancelMarket() public {
        bytes32 marketId = createTestMarket();

        // Verify market is active
        Market memory marketBefore = hook.getMarketById(marketId);
        assertEq(uint8(marketBefore.state), uint8(MarketState.Active), "Market should be Active initially");

        // Cancel the market
        hook.cancelMarket(marketId);

        // Verify market is now Cancelled
        Market memory marketAfter = hook.getMarketById(marketId);
        assertEq(uint8(marketAfter.state), uint8(MarketState.Cancelled), "Market should be Cancelled");
    }

    // Test for disputeResolution
    function test_disputeResolution() public {
        bytes32 marketId = createTestMarket();

        // Close the market
        vm.warp(hook.getMarketById(marketId).endTimestamp + 1);
        hook.closeMarket(marketId);

        // Enter resolution
        hook.enterResolution(marketId);

        // Resolve the market as Oracle
        vm.prank(address(oracleManager));
        hook.resolveMarket(marketId, true);

        // Verify market is Resolved
        Market memory marketBefore = hook.getMarketById(marketId);
        assertEq(uint8(marketBefore.state), uint8(MarketState.Resolved), "Market should be Resolved");

        // Dispute the resolution
        hook.disputeResolution(marketId);

        // Verify market is now Disputed
        Market memory marketAfter = hook.getMarketById(marketId);
        assertEq(uint8(marketAfter.state), uint8(MarketState.Disputed), "Market should be Disputed");
    }

    // Test for redeemCollateral
    function test_redeemCollateral() public {
        bytes32 marketId = createTestMarket();
        Market memory market = hook.getMarketById(marketId);

        // Get initial balances
        uint256 initialCollateralBalance = collateralToken.balanceOf(address(this));
        uint256 yesBalance = market.yesToken.balanceOf(address(this));
        uint256 noBalance = market.noToken.balanceOf(address(this));

        // Total tokens to redeem
        uint256 totalTokens = yesBalance + noBalance;

        // Calculate expected redemption amount
        uint256 collateralDecimals = collateralToken.decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals);
        uint256 expectedRedemption = totalTokens / (2 * decimalAdjustment);

        // Cancel the market
        hook.cancelMarket(marketId);

        // Approve tokens for burning
        market.yesToken.approve(address(hook), yesBalance);
        market.noToken.approve(address(hook), noBalance);

        // Redeem collateral
        hook.redeemCollateral(marketId);

        // Verify collateral received
        uint256 finalCollateralBalance = collateralToken.balanceOf(address(this));
        assertEq(
            finalCollateralBalance - initialCollateralBalance,
            expectedRedemption,
            "Should receive correct collateral amount"
        );

        // Verify tokens were burned
        assertEq(market.yesToken.balanceOf(address(this)), 0, "YES tokens should be burned");
        assertEq(market.noToken.balanceOf(address(this)), 0, "NO tokens should be burned");
    }

    // Test for markets() function
    function test_markets() public {
        bytes32 marketId = createTestMarket();
        Market memory market = hook.getMarketById(marketId);

        // Get market via PoolId (this tests the markets() function)
        Market memory marketFromPool = hook.markets(market.yesPoolKey.toId());

        // Verify both market structs are identical
        assertEq(address(marketFromPool.yesToken), address(market.yesToken), "YES token should match");
        assertEq(address(marketFromPool.noToken), address(market.noToken), "NO token should match");
        assertEq(marketFromPool.creator, market.creator, "Creator should match");
        assertEq(uint8(marketFromPool.state), uint8(market.state), "State should match");
        assertEq(marketFromPool.outcome, market.outcome, "Outcome should match");
    }

    // Test for marketCount and marketPoolIds
    function test_marketCountAndPoolIds() public {
        // Get initial market count
        uint256 initialCount = hook.marketCount();

        // Create a market
        bytes32 marketId = createTestMarket();

        // Get new market count
        uint256 newCount = hook.marketCount();

        // Verify count increased
        assertEq(newCount, initialCount + 1, "Market count should increase by 1");
    }

    // Test for claimedTokens
    function test_claimedTokens() public {
        // Create a market with liquidity
        bytes32 marketId = createTestMarketWithLiquidity();
        Market memory market = hook.getMarketById(marketId);

        // Resolve the market (as YES)
        vm.warp(market.endTimestamp + 1);
        hook.closeMarket(marketId);
        hook.enterResolution(marketId);
        vm.prank(address(oracleManager));
        hook.resolveMarket(marketId, true);

        // Check initial claimed tokens
        uint256 initialClaimedTokens = hook.claimedTokens(marketId);
        assertEq(initialClaimedTokens, 0, "No tokens should be claimed initially");

        // Calculate how much we'll claim
        uint256 yesBalance = market.yesToken.balanceOf(address(this));
        uint256 collateralDecimals = collateralToken.decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals);
        uint256 expectedClaimAmount = yesBalance / decimalAdjustment;

        // Approve tokens for burning during claim
        market.yesToken.approve(address(hook), yesBalance);

        // Claim winnings
        hook.claimWinnings(marketId);

        // Check updated claimed tokens
        uint256 updatedClaimedTokens = hook.claimedTokens(marketId);
        assertEq(updatedClaimedTokens, expectedClaimAmount, "Claimed tokens should match expected amount");
    }

    // Test for aiOracleServiceManager
    function test_aiOracleServiceManager() public {
        // Get current oracle manager
        address currentManager = hook.aiOracleServiceManager();
        assertEq(currentManager, address(oracleManager), "Should return the configured oracle manager");

        // Set a new oracle manager
        address newManager = address(0x123);
        hook.setOracleServiceManager(newManager);

        // Verify it was updated
        address updatedManager = hook.aiOracleServiceManager();
        assertEq(updatedManager, newManager, "Should return the new oracle manager");
    }

    // -----------------------------------------------
    //              Error Revert Tests
    // -----------------------------------------------

    function test_revert_MarketNotResolved_claimWinnings() public {
        bytes32 marketId = createTestMarketWithLiquidity();
        // Market is Active, not Resolved
        vm.expectRevert(PredictionMarketHook.MarketNotResolved.selector);
        hook.claimWinnings(marketId);
    }

    function test_revert_MarketNotResolved_disputeResolution() public {
        bytes32 marketId = createTestMarket();
        // Market is Active, not Resolved
        vm.expectRevert(PredictionMarketHook.MarketNotResolved.selector);
        hook.disputeResolution(marketId);
    }

    function test_revert_AlreadyClaimed() public {
        bytes32 marketId = createTestMarketWithLiquidity();
        Market memory market = hook.getMarketById(marketId);
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));

        // Resolve market YES
        vm.warp(market.endTimestamp + 1);
        hook.closeMarket(marketId);
        hook.enterResolution(marketId);
        vm.prank(address(oracleManager));
        hook.resolveMarket(marketId, true);

        // Claim once successfully
        uint256 yesBalance = yesToken.balanceOf(address(this));
        yesToken.approve(address(hook), yesBalance);
        hook.claimWinnings(marketId);

        // Try to claim again
        vm.expectRevert(PredictionMarketHook.AlreadyClaimed.selector);
        hook.claimWinnings(marketId);
    }

    function test_revert_InvalidOracleAddress_setOracleServiceManager() public {
        // Try setting oracle to address(0)
        vm.expectRevert(PredictionMarketHook.InvalidOracleAddress.selector);
        hook.setOracleServiceManager(address(0));
    }

    function test_revert_MarketNotFound_mintOutcomeTokens() public {
        bytes32 nonExistentMarketId = keccak256("non-existent");
        vm.expectRevert(PredictionMarketHook.MarketNotFound.selector);
        hook.mintOutcomeTokens(nonExistentMarketId, 1e6, address(collateralToken));
    }

    function test_revert_MarketNotFound_beforeSwap() public {
        // Create a valid key but don't associate it with a market
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(collateralToken)),
            currency1: Currency.wrap(address(new ERC20Mock("Fake", "FK", 18))),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)) // Point to the hook
        });
        // Swap function is internal, so we test via PoolManager call (swap)
        // We need to setup a swap, but expect the internal hook call to revert
        // This setup might be complex, let's test via a direct hook call if possible,
        // or test via `markets()` which uses the same internal logic
        vm.expectRevert(PredictionMarketHook.MarketNotFound.selector);
        hook.markets(key.toId()); // Test the underlying _getMarketFromPoolId call
    }

    function test_revert_MarketNotFound_beforeAddLiquidity() public {
        // Similar setup to beforeSwap, test via `markets()`
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(collateralToken)),
            currency1: Currency.wrap(address(new ERC20Mock("Fake", "FK", 18))),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(PredictionMarketHook.MarketNotFound.selector);
        hook.markets(key.toId()); // Test the underlying _getMarketFromPoolId call
    }

    function test_revert_MarketNotActive_closeMarket() public {
        bytes32 marketId = createTestMarket();
        // Close market once
        vm.warp(hook.getMarketById(marketId).endTimestamp + 1);
        hook.closeMarket(marketId);
        // Try to close again
        vm.expectRevert(PredictionMarketHook.MarketNotActive.selector);
        hook.closeMarket(marketId);
    }

    function test_revert_MarketNotClosed_enterResolution() public {
        bytes32 marketId = createTestMarket();
        // Market is Active, not Closed
        vm.expectRevert(PredictionMarketHook.MarketNotClosed.selector);
        hook.enterResolution(marketId);
    }

    function test_revert_MarketNotInCreatedState_activateMarket() public {
        bytes32 marketId = createTestMarket();
        // Market is Active, not Created
        vm.expectRevert(PredictionMarketHook.MarketNotInCreatedState.selector);
        hook.activateMarket(marketId); // activateMarket expects Created state
    }

    function test_revert_MarketNotInResolutionOrDisputePhase_resolveMarket() public {
        bytes32 marketId = createTestMarket();
        // Market is Active, not InResolution or Disputed
        vm.prank(address(oracleManager));
        vm.expectRevert(PredictionMarketHook.MarketNotInResolutionOrDisputePhase.selector);
        hook.resolveMarket(marketId, true);
    }

    function test_revert_NotAuthorizedToCancelMarket() public {
        bytes32 marketId = createTestMarket();
        address randomUser = makeAddr("randomUser");
        vm.prank(randomUser);
        vm.expectRevert(PredictionMarketHook.NotAuthorizedToCancelMarket.selector);
        hook.cancelMarket(marketId);
    }

    function test_revert_MarketCannotBeCancelledInCurrentState() public {
        bytes32 marketId = createTestMarket();
        Market memory market = hook.getMarketById(marketId);

        // Resolve market
        vm.warp(market.endTimestamp + 1);
        hook.closeMarket(marketId);
        hook.enterResolution(marketId);
        vm.prank(address(oracleManager));
        hook.resolveMarket(marketId, true);

        // Try to cancel resolved market (as creator)
        vm.expectRevert(PredictionMarketHook.MarketCannotBeCancelledInCurrentState.selector);
        hook.cancelMarket(marketId);
    }

    function test_revert_NoTokensToClaim() public {
        bytes32 marketId = createTestMarketWithLiquidity();
        Market memory market = hook.getMarketById(marketId);

        // Resolve market YES
        vm.warp(market.endTimestamp + 1);
        hook.closeMarket(marketId);
        hook.enterResolution(marketId);
        vm.prank(address(oracleManager));
        hook.resolveMarket(marketId, true);

        // Prank as a user with no tokens
        address userWithNoTokens = makeAddr("userWithNoTokens");
        vm.prank(userWithNoTokens);
        vm.expectRevert(PredictionMarketHook.NoTokensToClaim.selector);
        hook.claimWinnings(marketId);
    }

    function test_revert_NoTokensToRedeem() public {
        bytes32 marketId = createTestMarket();
        // Cancel the market
        hook.cancelMarket(marketId);

        // Prank as user with no tokens
        address userWithNoTokens = makeAddr("userWithNoTokens");
        vm.prank(userWithNoTokens);
        vm.expectRevert(PredictionMarketHook.NoTokensToRedeem.selector);
        hook.redeemCollateral(marketId);
    }

    // Note: InvalidTokenAddressOrdering is hard to test deterministically with CREATE2 salts
    // It relies on deployed addresses which depend on nonce and salts.
    // We skip testing this revert directly.

    function test_revert_TickBelowMinimumValidTick() public {
        bytes32 marketId = createTestMarket();
        Market memory market = hook.getMarketById(marketId);

        // Try adding liquidity below the market's min tick range
        // Market minTick is TEST_MIN_TICK (0), adjusted to nearest tickSpacing (0)
        int24 invalidLowerTick = market.settings.minTick - market.settings.tickSpacing; // One spacing below min
        int24 validUpperTick = market.settings.maxTick;

        // Prepare liquidity params
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: invalidLowerTick,
            tickUpper: validUpperTick,
            liquidityDelta: 1e18, // Example amount
            salt: 0
        });

        // Approve tokens for PoolModifyLiquidityTest
        collateralToken.approve(address(poolModifyLiquidityTest), type(uint256).max);
        market.yesToken.approve(address(poolModifyLiquidityTest), type(uint256).max);

        // Expect revert when adding liquidity
        vm.expectRevert();
        poolModifyLiquidityTest.modifyLiquidity(market.yesPoolKey, params, new bytes(0));
    }

    function test_revert_TickAboveMaximumValidTick() public {
        bytes32 marketId = createTestMarket();
        Market memory market = hook.getMarketById(marketId);

        // Try adding liquidity above the market's max tick range
        int24 validLowerTick = market.settings.minTick;
        int24 invalidUpperTick = market.settings.maxTick + market.settings.tickSpacing; // One spacing above max

        // Prepare liquidity params
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: validLowerTick,
            tickUpper: invalidUpperTick,
            liquidityDelta: 1e18, // Example amount
            salt: 0
        });

        // Approve tokens
        collateralToken.approve(address(poolModifyLiquidityTest), type(uint256).max);
        market.yesToken.approve(address(poolModifyLiquidityTest), type(uint256).max);
        // Trigger the revert by calling modifyLiquidity
        vm.expectRevert();
        poolModifyLiquidityTest.modifyLiquidity(market.yesPoolKey, params, new bytes(0));
    }

    function test_revert_MarketIdCannotBeZero() public {
        vm.expectRevert(PredictionMarketHook.MarketIdCannotBeZero.selector);
        hook.getMarketById(bytes32(0));
    }

    function test_revert_OnlyConfiguredOracleAllowed() public {
        bytes32 marketId = createTestMarket();
        Market memory market = hook.getMarketById(marketId);

        // Resolve market phase
        vm.warp(market.endTimestamp + 1);
        hook.closeMarket(marketId);
        hook.enterResolution(marketId);

        // Try resolving from a non-oracle address (e.g., the creator)
        vm.expectRevert(PredictionMarketHook.OnlyConfiguredOracleAllowed.selector);
        hook.resolveMarket(marketId, true);
    }

    function test_revert_MarketNotCancelled() public {
        bytes32 marketId = createTestMarket();
        // Market is Active, not Cancelled
        vm.expectRevert(PredictionMarketHook.MarketNotCancelled.selector);
        hook.redeemCollateral(marketId);
    }
}
