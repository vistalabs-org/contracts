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

contract PredictionMarketHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    
    PredictionMarketHook public hook;
    PoolCreationHelper public poolCreationHelper;
    ERC20Mock public collateralToken;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC
    PoolSwapTest public poolSwapTest;
    PoolModifyLiquidityTest public poolModifyLiquidityTest;

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
            uint160(
                Hooks.BEFORE_SWAP_FLAG | 
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | 
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
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
        collateralToken.mint(address(this), 1000000 * 10**6);

        // approve the hook to transfer the tokens
        collateralToken.approve(address(hook), COLLATERAL_AMOUNT);
    }

    function test_createMarketandDepositCollateral() public {
        // Setup test parameters
        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(0x123),
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will ETH reach $10k in 2024?",
            description: "Market resolves to YES if ETH price reaches $10,000 before Dec 31, 2024",
            duration: 30 days
        });
        
        // Call the function to create market and deposit collateral
        bytes32 marketId = hook.createMarketAndDepositCollateral(params);
        
        // Verify market was created successfully
        assertTrue(marketId != bytes32(0), "Market ID should not be zero");
        
        // Get market details
        Market memory market = hook.getMarketById(marketId);

        // Verify market details
        assertEq(market.oracle, params.oracle, "Oracle address mismatch");
        assertEq(market.creator, params.creator, "Creator address mismatch");
        assertEq(uint8(market.state), uint8(MarketState.Active), "Market should be active");
        assertEq(market.totalCollateral, params.collateralAmount, "Collateral amount mismatch");
        assertEq(market.collateralAddress, params.collateralAddress, "Collateral address mismatch");
        assertEq(market.title, params.title, "Title mismatch");
        assertEq(market.description, params.description, "Description mismatch");
        assertTrue(market.endTimestamp > block.timestamp, "End timestamp should be in the future");

        // Verify tokens were created
        assertTrue(address(market.yesToken) != address(0), "YES token not created");
        assertTrue(address(market.noToken) != address(0), "NO token not created");
    }
    
    function test_createMarketAndAddLiquidity() public {
        // Setup test parameters
        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(0x123),
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will ETH reach $10k in 2024?",
            description: "Market resolves to YES if ETH price reaches $10,000 before Dec 31, 2025",
            duration: 30 days
        });
        
        // Call the function to create market and deposit collateral
        bytes32 marketId = hook.createMarketAndDepositCollateral(params);
        
        // Get market details
        Market memory market = hook.getMarketById(marketId);
        
        // Verify creator received outcome tokens
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
        OutcomeToken noToken = OutcomeToken(address(market.noToken));
        
        assertEq(yesToken.balanceOf(params.creator), params.collateralAmount, "Creator should have YES tokens");
        assertEq(noToken.balanceOf(params.creator), params.collateralAmount, "Creator should have NO tokens");
        
        // For prediction markets, we want to constrain the price between 0 and 1 USDC
        // Calculate the ticks that correspond to these prices
        // Price = 1.0001^tick
        // For price = 0.01 USDC: tick = log(0.01)/log(1.0001) ≈ -9210
        // For price = 0.99 USDC: tick = log(0.99)/log(1.0001) ≈ -100
        // For price = 0.5 USDC: tick = log(0.5)/log(1.0001) ≈ -6932
        
        // We'll round to the nearest valid tick based on tick spacing
        int24 tickSpacing = 100;
        int24 minTick = -9200; // Slightly above 0.01 USDC
        int24 maxTick = -100;  // Slightly below 0.99 USDC
        int24 initialTick = -6900; // 0.5 USDC, rounded to nearest tick spacing
        
        // Ensure ticks are valid with the tick spacing
        minTick = (minTick / tickSpacing) * tickSpacing;
        maxTick = (maxTick / tickSpacing) * tickSpacing;
        
        // Get the sqrtPriceX96 for the initial tick (0.5 USDC)
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initialTick);
        
        // Calculate liquidity amounts for 0.5 USDC price
        // At tick 0, the price is 1:1 in terms of sqrt price
        // For a 0.5 USDC price, we need 2 outcome tokens for each 1 USDC
        uint256 liquidityCollateral = 50 * 1e6;  // 50 USDC
        uint256 liquidityOutcomeTokens = 100 * 1e18;  // 100 outcome tokens (assuming 18 decimals)
        
        // Approve tokens for liquidity provision
        collateralToken.approve(address(poolModifyLiquidityTest), liquidityCollateral);
        yesToken.approve(address(poolModifyLiquidityTest), liquidityOutcomeTokens);
        noToken.approve(address(poolModifyLiquidityTest), liquidityOutcomeTokens);
        
        // Calculate liquidity amount for the 0.01-0.99 range
        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            liquidityCollateral,
            liquidityOutcomeTokens
        );
        
        console.log("Adding liquidity to YES pool");
        console.log("Liquidity amount: %d", liquidityAmount);
        
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
        console.log("Adding liquidity to NO pool");
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
        
        console.log("Initial liquidity added to both pools with price range 0.01-0.99 USDC");
        
        // Verify tokens were transferred for liquidity
        assertLt(
            yesToken.balanceOf(params.creator), 
            params.collateralAmount, 
            "Creator should have spent YES tokens on liquidity"
        );
        
        assertLt(
            noToken.balanceOf(params.creator), 
            params.collateralAmount, 
            "Creator should have spent NO tokens on liquidity"
        );
        
    }
}