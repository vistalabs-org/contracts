/**
 * @title PredictionMarketAITest
 * @dev Test for Prediction Market with REAL AI Agent integration
 * 
 * Note: The test is designed to work with the eigenlayer-ai-agent directory structure.
 */

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
// import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol"; // Dependency issue
import "forge-std/console.sol";
// Uniswap libraries (Commented out due to dependency issues, assumed available in test env)
// import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
// import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
// import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
// import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
// import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
// import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Market, MarketState, CreateMarketParams} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {ERC20Mock} from "./utils/ERC20Mock.sol"; // USE THIS MOCK
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
// import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {AIOracleServiceManager} from "../src/oracle/AIOracleServiceManager.sol";
import {AIAgent} from "../src/oracle/AIAgent.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
// import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol"; // Use mock instead
// Import necessary interfaces and types
import {MarketState} from "../src/types/MarketTypes.sol";
import {IAIOracleServiceManager} from "../src/interfaces/IAIOracleServiceManager.sol";

// Removed MockUSDC contract definition
// Removed AIOracleTestHelpers library definition

/**
 * @title PredictionMarketAITest
 * @dev Test contract for integration between PredictionMarketHook and AI Oracle
 * Assumes Oracle, Agent, Hook, PoolManager, Helpers are pre-deployed at known addresses.
 * Deploys its own ERC20Mock collateral token.
 */
contract PredictionMarketAITest is Test /*, Deployers */ { // Commented Deployers due to import issue
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    // Removed 'using AIOracleTestHelpers for *;'

    // Contracts (Hook/Oracle/Agent assumed deployed, others connected via address)
    PredictionMarketHook public hook;
    PoolCreationHelper public poolCreationHelper;
    PoolModifyLiquidityTest public poolModifyLiquidityTest;
    IPoolManager public poolManager;

    // AI Oracle components (assumed deployed)
    AIOracleServiceManager public oracle;
    AIAgent public agent;

    // Constants
    uint256 public constant COLLATERAL_AMOUNT = 100 * 1e6; // 100 units (assuming 6 decimals)

    // Deployed ERC20 Mock Token
    ERC20Mock public collateralToken;

    // Contract addresses from the deployment (Replace with actual deployment addresses)
    address public constant ORACLE_ADDRESS = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    address public constant AGENT_ADDRESS = 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9;
    address public constant HOOK_ADDRESS = payable(0x4444000000000000000000000000000000000a80); // Ensure this is correct/payable
    address public constant POOL_MANAGER_ADDRESS = 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f;
    address public constant POOL_MODIFY_LIQUIDITY_ADDRESS = 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853;
    address public constant POOL_CREATION_HELPER_ADDRESS = 0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6;
    // Removed MOCK_USDC_ADDRESS constant

    function setUp() public {
        console.log("Setting up test: Connecting to deployed contracts & deploying mock token...");

        // --- Connect to pre-deployed contracts ---
        // Use interfaces or direct contract types if code is available
        if (ORACLE_ADDRESS.code.length > 0) oracle = AIOracleServiceManager(ORACLE_ADDRESS);
        else console.log("WARNING: Oracle contract code not found at", ORACLE_ADDRESS);

        if (HOOK_ADDRESS.code.length > 0) hook = PredictionMarketHook(HOOK_ADDRESS);
        else console.log("WARNING: Hook contract code not found at", HOOK_ADDRESS);

        if (AGENT_ADDRESS.code.length > 0) agent = AIAgent(AGENT_ADDRESS);
        else console.log("WARNING: Agent contract code not found at", AGENT_ADDRESS);

        if (POOL_MANAGER_ADDRESS.code.length > 0) poolManager = IPoolManager(POOL_MANAGER_ADDRESS);
        else console.log("WARNING: PoolManager contract code not found at", POOL_MANAGER_ADDRESS);

        if (POOL_MODIFY_LIQUIDITY_ADDRESS.code.length > 0) poolModifyLiquidityTest = PoolModifyLiquidityTest(POOL_MODIFY_LIQUIDITY_ADDRESS);
        else console.log("WARNING: PoolModifyLiquidity contract code not found at", POOL_MODIFY_LIQUIDITY_ADDRESS);

        if (POOL_CREATION_HELPER_ADDRESS.code.length > 0) poolCreationHelper = PoolCreationHelper(POOL_CREATION_HELPER_ADDRESS);
        else console.log("WARNING: PoolCreationHelper contract code not found at", POOL_CREATION_HELPER_ADDRESS);

        // --- Deploy Mock Collateral Token ---
        collateralToken = new ERC20Mock("Test Collateral", "tCOL", 6);
        console.log("Deployed Mock Collateral (tCOL) at:", address(collateralToken));
        collateralToken.mint(address(this), 10_000 * 10**6); // Mint 10,000 tCOL for the test contract
        console.log("Minted initial collateral for test contract.");

        // --- Post-connection Setup ---
        bool hookInitialized = address(hook) != address(0) && HOOK_ADDRESS.code.length > 0;
        bool oracleInitialized = address(oracle) != address(0) && ORACLE_ADDRESS.code.length > 0;
        bool agentInitialized = address(agent) != address(0) && AGENT_ADDRESS.code.length > 0;
        bool collateralInitialized = address(collateralToken) != address(0);

        // ** Add the setOracleServiceManager call if hook and oracle are initialized **
        if (hookInitialized && oracleInitialized) {
            try hook.setOracleServiceManager(ORACLE_ADDRESS) {
                 console.log("Called hook.setOracleServiceManager.");
            } catch Error(string memory reason) {
                 // Check if it was already set (might happen if test env persists state)
                 try hook.aiOracleServiceManager() returns (address currentOracle) {
                     if (currentOracle == ORACLE_ADDRESS) {
                         console.log("Hook Oracle address was already set.");
                     } else {
                         console.log("Failed to set Oracle address on Hook:", reason);
                     }
                 } catch {
                      console.log("Failed to set Oracle address on Hook and failed to read current address:", reason);
                 }
            } catch {
                console.log("Unknown error calling hook.setOracleServiceManager.");
            }
        } else {
             console.log("Skipping setOracleServiceManager call due to uninitialized hook or oracle.");
        }

        // Authorize the agent in the Oracle Service Manager if both exist
        if (oracleInitialized && agentInitialized) {
            // Assuming setUp runs as owner or has permissions
            try oracle.addTestOperator(AGENT_ADDRESS) {
                console.log("Authorized AGENT_ADDRESS as test operator.");
            } catch Error(string memory reason) {
                try oracle.testOperators(AGENT_ADDRESS) returns (bool isOperator) {
                    if (isOperator) {
                        console.log("Agent already authorized as test operator.");
                    } else {
                        console.log("Failed to add test operator:", reason);
                    }
                } catch {
                    console.log("Failed to check test operator status after add failed:", reason);
                }
            } catch {
                console.log("Unknown error calling addTestOperator.");
            }
        }

        // Approve the hook to spend the test contract's collateral tokens
        if (hookInitialized && collateralInitialized) {
            collateralToken.approve(address(hook), type(uint256).max);
            console.log("Approved Hook to spend test contract's collateral tokens.");
        }

        console.log("Setup complete.");
    }

    // Test creating a market and a *generic* oracle task (not market resolution)
    function test_createNewMarketAndGenericOracleTask() public {
        console.log("\n===== Test: Create Market & Generic Oracle Task ====");

        require(address(oracle) != address(0), "Oracle not initialized");
        require(address(hook) != address(0), "Hook not initialized");
        require(address(collateralToken) != address(0), "Collateral token not initialized");

        uint32 initialTaskNum = oracle.latestTaskNum();
        console.log("Initial Oracle Task #: ", initialTaskNum);

        // Create a new market
        bytes32 mId = createTestMarket();
        console.log("Market created with ID (hex): %s", vm.toString(mId));
        assertTrue(mId != bytes32(0), "Market ID is zero");

        // Create a new generic task for AI agents
        string memory taskDescription = "Generic AI task for testing";
        uint32 newTaskNum = createGenericAIOracleTask(taskDescription);
        console.log("New generic task created, #: ", newTaskNum);
        assertEq(newTaskNum, initialTaskNum, "New task number should be the initial latestTaskNum"); // latestTaskNum increments after
        assertEq(oracle.latestTaskNum(), initialTaskNum + 1, "Oracle latestTaskNum should have incremented");

        console.log("===== Test Completed Successfully ====");
    }

    // --- Test: Agent Responds and Market Resolves ---
    function test_agentRespondsAndMarketResolves() public {
        console.log("\n===== Test: Agent Responds & Market Resolves ====");

        // 1. Ensure contracts are available
        require(address(hook) != address(0), "Hook not initialized");
        require(address(oracle) != address(0), "Oracle not initialized");
        require(address(agent) != address(0), "Agent not initialized");
        require(address(collateralToken) != address(0), "Collateral token not initialized");
        console.log("Required contracts initialized.");

        // 2. Create a new market
        console.log("----- Creating Market -----");
        bytes32 testMarketId = createTestMarket();
        console.log("Market created with ID (hex): %s", vm.toString(testMarketId));
        require(testMarketId != bytes32(0), "Market creation failed");

        // 3. Activate the market
        console.log("----- Activating Market -----");
        try hook.activateMarket(testMarketId) {
             console.log("Market activated.");
        } catch Error(string memory reason) {
             revert(string.concat("Market activation failed: ", reason));
        } catch {
             revert("Unknown error activating market.");
        }

        // 4. Create the Market Resolution task via the Oracle
        console.log("----- Creating Oracle Resolution Task -----");
        string memory marketTitle;
        try hook.getMarketById(testMarketId) returns (Market memory m) {
            marketTitle = m.title;
        } catch {
            revert("Failed to get market title");
        }

        uint32 taskNum;
        try oracle.createMarketResolutionTask(marketTitle, testMarketId, address(hook)) returns (uint32 index) {
            taskNum = index;
            console.log("Oracle market resolution task created, #: ", taskNum);
        } catch Error(string memory reason) {
             address oracleHookAddr;
             // try oracleHookAddr = oracle.predictionMarketHook(); catch {} // Ignore error if call fails
             try oracle.predictionMarketHook() returns (address addr) {
                 oracleHookAddr = addr;
             } catch {
                 // Ignore error if call fails
             }
             string memory errorMsg = string.concat("ERROR creating market resolution task: ", reason);
             if (oracleHookAddr != address(0) && oracleHookAddr != address(hook)) {
                 errorMsg = string.concat(errorMsg, ". Oracle Hook Addr: ", vm.toString(oracleHookAddr), "; Deployed Hook Addr: ", vm.toString(address(hook)));
             }
             revert(errorMsg);
        } catch {
             revert("Unknown error creating market resolution task");
        }

        // 5. Simulate Agent responding "YES"
        console.log("----- Simulating Agent Response (YES) -----");
        bytes memory agentResponse = bytes("YES");
        bytes32 expectedResponseHash = keccak256(agentResponse);

        vm.deal(address(this), 1 ether); // Fund test contract for prank gas
        vm.prank(AGENT_ADDRESS);
        try oracle.respondToTask(taskNum, agentResponse) {
             console.log("Agent response submitted successfully.");
        } catch Error(string memory reason) {
            // Log the original reason and agent address
            console.log("ERROR in respondToTask for Agent:", AGENT_ADDRESS);
            console.log("  Reason:", reason);
            revert(reason); // Revert with the original reason only
        } catch {
            console.log("Unknown error in respondToTask call for Agent:", AGENT_ADDRESS);
            { 
                revert("Unknown error submitting agent response"); 
            }
        }

        // 6. Verify Oracle Task Status and Consensus
        console.log("----- Verifying Oracle State -----");
        IAIOracleServiceManager.TaskStatus currentTaskStatus = oracle.taskStatus(taskNum);
        bytes32 consensusHash = oracle.consensusResultHash(taskNum);

        console.log("Oracle Task Status (Enum):", uint8(currentTaskStatus));
        console.log("Oracle Consensus Hash (hex): %s", vm.toString(consensusHash));
        console.log("Expected Response Hash (hex): %s", vm.toString(expectedResponseHash));

        // Assumes minimumResponses=1 and threshold=10000 in the deployed Oracle
        assertEq(uint8(currentTaskStatus), uint8(IAIOracleServiceManager.TaskStatus.Resolved), "Oracle task status mismatch");
        assertEq(consensusHash, expectedResponseHash, "Oracle consensus hash mismatch");
        console.log("Oracle state verified.");

        // 7. Verify Market State in Hook
        console.log("----- Verifying Hook Market State -----");
        Market memory market = hook.getMarketById(testMarketId);
        console.log("Market State in Hook (Enum):", uint8(market.state));
        console.log("Market Outcome in Hook:", market.outcome);

        assertEq(uint8(market.state), uint8(MarketState.Resolved), "Market state in Hook mismatch");
        assertTrue(market.outcome, "Market outcome should be YES (true)");
        console.log("Hook market state verified.");

        console.log("===== Test Completed Successfully ====");
    }

    // --- Helper Functions ---

    // Internal helper function to create a test market
    function createTestMarket() internal returns (bytes32) {
        require(address(hook) != address(0), "Hook not initialized");
        require(address(collateralToken) != address(0), "Collateral token not initialized");
        // Note: Oracle address is now set on the hook during setUp

        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(oracle), // Use the connected oracle address
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Test Market: Resolve YES",
            description: "This market should resolve to YES",
            duration: 1 days,
            curveId: 0
        });

        console.log("Attempting to create market via hook...");
        bytes32 marketId = hook.createMarketAndDepositCollateral(params);
        console.log("createMarketAndDepositCollateral returned market ID (hex):", vm.toString(marketId));
        require(marketId != bytes32(0), "Market creation returned zero ID");
        return marketId;
    }

    // Internal helper function to create a generic task
    function createGenericAIOracleTask(string memory name) internal returns (uint32) {
        require(address(oracle) != address(0), "Oracle not initialized");
        console.log("Attempting to create generic AI task...");
        // Get the task index *before* calling createNewTask, as latestTaskNum increments inside
        uint32 taskIndex = oracle.latestTaskNum();
        oracle.createNewTask(name); // Call the function (we don't need its Task struct return value here)
        return taskIndex; // Return the index
    }

    // Manual resolution placeholder (use Oracle interaction instead for proper tests)
    function resolveMarketManually(bytes32 _marketId, bool outcome) external {
        require(address(hook) != address(0), "Hook not initialized for manual resolve");
        // This bypasses the oracle - for emergency/debug only
        // vm.prank(address(oracle)); // Needs oracle address
        // hook.resolveMarket(_marketId, outcome);
        console.log("WARNING: Manual market resolution called (placeholder) MarketID (hex): %s Outcome: %s", vm.toString(_marketId), vm.toString(outcome));
    }

    // TODO:
    // - Test agent responding NO
    // - Test multiple agents (requires adjusting Oracle deployment params/logic)
    // - Test claiming winnings
    // - Test cancellation/redemption
    // - Test trading (requires adding liquidity)
}
