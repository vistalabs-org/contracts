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
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Market, MarketState} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {ERC20Mock} from "./utils/ERC20Mock.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";

contract PredictionMarketHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    PredictionMarketHook public hook;
    PoolCreationHelper public poolCreationHelper;
    ERC20Mock public collateralToken;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6;
    PoolSwapTest public poolSwapTest;

    function setUp() public {
        // Deploy Uniswap v4 infrastructure
        console.log("Deploying Uniswap v4 infrastructure from ", address(this));
        deployFreshManagerAndRouters();

        // Deploy PoolSwapTest
        poolSwapTest = new PoolSwapTest(manager);

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
            abi.encode(manager, poolSwapTest, poolCreationHelper), 
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
        address oracle = address(0x123);
        address creator = address(this);
        address collateralAddress = address(collateralToken);
        uint256 collateralAmount = COLLATERAL_AMOUNT;
        string memory title = "Will ETH reach $10k in 2024?";
        string memory description = "Market resolves to YES if ETH price reaches $10,000 before Dec 31, 2024";
        uint256 duration = 30 days;
        
        // Call the function to create market and deposit collateral
        bytes32 marketId = hook.createMarketAndDepositCollateral(
            oracle,
            creator,
            collateralAddress,
            collateralAmount,
            title,
            description,
            duration
        );
        
        // Verify market was created successfully
        assertTrue(marketId != bytes32(0), "Market ID should not be zero");
        
        // Get market details
        Market memory market = hook.getMarketById(marketId);

        // Verify market details
        assertEq(market.oracle, oracle, "Oracle address mismatch");
        assertEq(market.creator, creator, "Creator address mismatch");
        assertEq(uint8(market.state), uint8(MarketState.Active), "Market should be active");
        assertEq(market.totalCollateral, collateralAmount, "Collateral amount mismatch");
        assertEq(market.collateralAddress, collateralAddress, "Collateral address mismatch");
        assertEq(market.title, title, "Title mismatch");
        assertEq(market.description, description, "Description mismatch");
        assertTrue(market.endTimestamp > block.timestamp, "End timestamp should be in the future");

        // Verify tokens were created
        assertTrue(address(market.yesToken) != address(0), "YES token not created");
        assertTrue(address(market.noToken) != address(0), "NO token not created");
    }
}