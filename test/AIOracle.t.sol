/**
 * @title PredictionMarketAITest
 * @dev Test for Prediction Market with REAL AI Agent integration
 *
 */

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol"; // Dependency issue FIX
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol"; // Dependency issue FIX
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Market, MarketState, CreateMarketParams} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {ERC20Mock} from "./utils/ERC20Mock.sol"; // USE THIS MOCK
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AIOracleServiceManager} from "../src/oracle/AIOracleServiceManager.sol";
import {AIAgent} from "../src/oracle/AIAgent.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MarketState} from "../src/types/MarketTypes.sol";
import {IAIOracleServiceManager} from "../src/interfaces/IAIOracleServiceManager.sol";
import {AIAgentRegistry} from "../src/oracle/AIAgentRegistry.sol"; // Import AIAgentRegistry
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol"; // Import Deployers

/**
 * @title PredictionMarketAITest
 * @dev Test contract for integration between PredictionMarketHook and AI Oracle
 * Deploys all necessary contracts locally for testing.
 */
contract PredictionMarketAITest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Contracts (Hook/Oracle/Agent assumed deployed, others connected via address)
    PredictionMarketHook public hook;
    PoolCreationHelper public poolCreationHelper;
    PoolModifyLiquidityTest public poolModifyLiquidityTest;
    IPoolManager public poolManager;

    // AI Oracle components (assumed deployed)
    AIOracleServiceManager public oracle;
    AIAgentRegistry public registry; // Declare registry state variable
    AIAgent public agent;

    // Constants
    uint256 public constant COLLATERAL_AMOUNT = 100 * 1e6; // 100 units (assuming 6 decimals)

    // Deployed ERC20 Mock Token
    ERC20Mock public collateralToken;

    function setUp() public {
        console.log("Setting up test: Deploying contracts locally...");

        // --- Deploy Uniswap v4 Core --- Inherited from Deployers
        deployFreshManagerAndRouters(); // Deploys manager, PoolModifyLiquidityTest, PoolSwapTest
        // Make sure the router instance is assigned from the inherited address
        // poolModifyLiquidityTest = PoolModifyLiquidityTest(poolModifyLiquidityRouter); // Use inherited state variable <-- REMOVE THIS LINE

        // --- Deploy Test Helpers & Mocks ---\
        poolCreationHelper = new PoolCreationHelper(address(manager)); // Use inherited manager
        require(address(poolCreationHelper) != address(0), "PoolCreationHelper deployment failed");
        collateralToken = new ERC20Mock("Test Collateral", "tCOL", 6);
        require(address(collateralToken) != address(0), "Collateral token deployment failed");
        collateralToken.mint(address(this), 10_000 * 10 ** 6); // Mint for test contract

        console.log("Deployed Uniswap Core, Helpers, and Mock Collateral.");

        // --- Deploy Oracle Components ---\
        registry = new AIAgentRegistry(); // Use declared variable
        require(address(registry) != address(0), "Registry deployment failed");
        oracle = new AIOracleServiceManager(address(registry));
        require(address(oracle) != address(0), "Oracle implementation deployment failed");
        agent = new AIAgent();
        require(address(agent) != address(0), "Agent implementation deployment failed");
        console.log("Deployed Oracle Registry, Manager Impl, and Agent Impl.");

        // --- Deploy Hook using HookMiner and CREATE2 ---\
        uint160 hookFlags = uint160( // Use uint160 for flags
        Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG); // Simplified flags

        bytes memory hookCreationCode = type(PredictionMarketHook).creationCode;
        // Constructor: IPoolManager _poolManager, PoolCreationHelper _poolCreationHelper, address initialOwner
        bytes memory hookConstructorArgs = abi.encode(manager, poolCreationHelper, address(this)); // owner = this, use inherited manager

        // Predict hook address
        (address calculatedHookAddr, bytes32 salt) = HookMiner.find(
            address(this), // Deployer
            hookFlags, // Hook flags
            hookCreationCode, // Contract creation code
            hookConstructorArgs // Constructor arguments
        );
        require(calculatedHookAddr != address(0), "HookMiner.find returned zero address");
        console.log("Calculated Hook address:", calculatedHookAddr);

        // --- Initialize Oracle Manager (BEFORE deploying Hook) ---\
        // Initialize the deployed implementation directly
        oracle.initialize(
            address(this), // Owner
            1, // Minimum Responses (for testing)
            10000, // Consensus Threshold (100% for testing)
            calculatedHookAddr // The predicted address where the hook WILL be deployed
        );
        console.log("Oracle Manager initialized with predicted Hook address.");
        // Verify initialization worked
        require(
            oracle.predictionMarketHook() == calculatedHookAddr,
            "Oracle did not store predicted hook address after initialize"
        );
        require(oracle.owner() == address(this), "Oracle owner not set correctly");

        // --- Deploy Hook ---
        // Use create2 for deterministic deployment
        bytes memory hookDeploymentCode = abi.encodePacked(hookCreationCode, hookConstructorArgs);
        address deployedHookAddr;
        assembly {
            deployedHookAddr := create2(0, add(hookDeploymentCode, 0x20), mload(hookDeploymentCode), salt)
        }
        require(deployedHookAddr == calculatedHookAddr, "CREATE2 Hook deployment address mismatch");
        require(deployedHookAddr != address(0), "Hook deployment create2 returned zero address");

        // *** Assign to the state variable ***
        hook = PredictionMarketHook(payable(deployedHookAddr));
        // *** Add check immediately after assignment ***
        require(address(hook) != address(0), "Hook state variable is zero after assignment!");
        console.log("Hook deployed via CREATE2 at:", address(hook));

        // --- Post-Deployment Linking & Setup ---

        // *** Set Oracle address ON the Hook ***
        hook.setOracleServiceManager(address(oracle));
        // Verify linking worked
        require(
            hook.aiOracleServiceManager() == address(oracle),
            "Hook did not store oracle address after setOracleServiceManager"
        );
        console.log("Set Oracle address on Hook.");

        // Initialize Agent
        agent.initialize(
            address(oracle), // Service Manager
            "TEST_MODEL", // Model Type
            "v0.1", // Model Version
            "TestAgentNFT", // Name
            "TAGENT" // Symbol
        );
        require(address(agent.serviceManager()) == address(oracle), "Agent service manager not set correctly");
        console.log("Agent Initialized.");

        // Register Agent in Registry
        // Ensure registry owner (deployer = this) can register
        try registry.registerAgent(address(agent)) {
            console.log("Agent registered in Registry.");
            require(registry.isRegistered(address(agent)), "Agent not marked as registered after registration call");
        } catch Error(string memory reason) {
            console.log("WARN: Failed to register agent:", reason);
            // If registration fails, the agent likely cannot interact with the oracle
            revert(string.concat("Agent registration failed: ", reason));
        } catch {
            console.log("WARN: Unknown error registering agent.");
            revert("Unknown error registering agent.");
        }

        // Authorize agent as a test operator in Oracle Manager
        try oracle.addTestOperator(address(agent)) {
            console.log("Agent authorized as test operator.");
            require(
                oracle.testOperators(address(agent)), "Agent not marked as test operator after addTestOperator call"
            );
        } catch Error(string memory reason) {
            try oracle.testOperators(address(agent)) returns (bool isOperator) {
                if (isOperator) {
                    console.log("Agent already authorized as test operator.");
                } else {
                    console.log("Failed to add test operator:", reason);
                    revert(string.concat("Failed to add test operator: ", reason));
                }
            } catch {
                console.log("Failed to check test operator status after add failed:", reason);
                revert("Failed checking test operator status after add failed.");
            }
        } catch {
            console.log("Unknown error calling addTestOperator.");
            revert("Unknown error calling addTestOperator.");
        }

        // Approve hook to spend collateral
        collateralToken.approve(address(hook), type(uint256).max);
        console.log("Approved Hook to spend test contract's collateral tokens.");

        // Final check before setup exits
        require(address(oracle) != address(0), "Oracle is zero at end of setUp!");
        require(address(hook) != address(0), "Hook is zero at end of setUp!");
        require(address(agent) != address(0), "Agent is zero at end of setUp!");

        console.log("Setup complete.");
    }

    // Test creating a market and a *generic* oracle task (not market resolution)
    function test_createNewMarketAndGenericOracleTask() public {
        console.log("\n===== Test: Create Market & Generic Oracle Task ====");

        // Add checks at the beginning of the test
        require(address(oracle) != address(0), "Oracle not initialized at start of test");
        require(address(hook) != address(0), "Hook not initialized at start of test");
        require(address(collateralToken) != address(0), "Collateral token not initialized at start of test");

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

    // --- NEW Split Test Functions ---

    /// @notice Tests that creating a market sets its initial state to Active.
    function test_CreateMarket_SetsActiveState() public {
        console.log("\n===== Test: Create Market Sets Active State ====");
        bytes32 mId = createTestMarket();
        require(mId != bytes32(0), "Market creation failed");

        Market memory market = hook.getMarketById(mId);
        assertEq(uint8(market.state), uint8(MarketState.Active), "Market should be Active after creation");
        console.log("===== Test Completed Successfully ====");
    }

    /// @notice Tests that closing an active market sets its state to Closed.
    function test_CloseMarket_SetsClosedState() public {
        console.log("\n===== Test: Close Market Sets Closed State ====");
        // 1. Create Market
        bytes32 mId = createTestMarket();
        require(hook.getMarketById(mId).state == MarketState.Active, "Market not active initially");

        // 2. Close Market
        try hook.closeMarket(mId) {
            console.log("hook.closeMarket called.");
        } catch Error(string memory reason) {
            revert(string.concat("ERROR closing market: ", reason));
        } catch {
            revert("Unknown error calling hook.closeMarket");
        }

        // 3. Verify State
        Market memory market = hook.getMarketById(mId);
        assertEq(uint8(market.state), uint8(MarketState.Closed), "Market should be Closed after closeMarket call");
        console.log("===== Test Completed Successfully ====");
    }

    /// @notice Tests that entering resolution sets state to InResolution and creates an oracle task.
    function test_EnterResolution_SetsInResolutionState_CreatesOracleTask() public {
        console.log("\n===== Test: Enter Resolution Creates Oracle Task ====");
        // 1. Create Market
        bytes32 mId = createTestMarket();

        // 2. Close Market
        hook.closeMarket(mId);
        require(hook.getMarketById(mId).state == MarketState.Closed, "Market not closed before entering resolution");

        // 3. Enter Resolution
        uint32 taskNumBefore = oracle.latestTaskNum();
        try hook.enterResolution(mId) {
            console.log("hook.enterResolution called.");
        } catch Error(string memory reason) {
            revert(string.concat("ERROR entering resolution: ", reason));
        } catch {
            revert("Unknown error calling hook.enterResolution");
        }

        // 4. Verify Hook State
        Market memory market = hook.getMarketById(mId);
        assertEq(
            uint8(market.state), uint8(MarketState.InResolution), "Market should be InResolution after enterResolution"
        );

        // 5. Verify Oracle Task Creation
        assertEq(oracle.latestTaskNum(), taskNumBefore + 1, "Oracle latestTaskNum should have incremented");
        console.log("===== Test Completed Successfully ====");
    }

    /// @notice Tests that an agent's response resolves the corresponding task in the Oracle.
    function test_AgentResponse_ResolvesOracleTask() public {
        console.log("\n===== Test: Agent Response Resolves Oracle Task ====");
        // 1. Create Market, Close, Enter Resolution
        bytes32 mId = createTestMarket();
        hook.closeMarket(mId);
        uint32 taskNum = oracle.latestTaskNum(); // Task index will be this value
        hook.enterResolution(mId);
        require(hook.getMarketById(mId).state == MarketState.InResolution, "Market not InResolution");
        require(oracle.latestTaskNum() == taskNum + 1, "Oracle task not created");

        // 2. Simulate Agent responding "YES"
        bytes memory agentResponse = bytes("YES");
        bytes32 expectedResponseHash = keccak256(agentResponse);
        vm.prank(address(agent));
        try oracle.respondToTask(taskNum, agentResponse) {
            console.log("Agent response submitted successfully.");
        } catch Error(string memory reason) {
            revert(string.concat("ERROR submitting agent response: ", reason));
        } catch {
            revert("Unknown error submitting agent response");
        }

        // 3. Verify Oracle Task Status and Consensus
        IAIOracleServiceManager.TaskStatus currentTaskStatus = oracle.taskStatus(taskNum);
        bytes32 consensusHash = oracle.consensusResultHash(taskNum);
        assertEq(
            uint8(currentTaskStatus), uint8(IAIOracleServiceManager.TaskStatus.Resolved), "Oracle task status mismatch"
        );
        assertEq(consensusHash, expectedResponseHash, "Oracle consensus hash mismatch");
        console.log("Oracle task resolved successfully.");
        console.log("===== Test Completed Successfully ====");
    }

    /// @notice Tests that an agent's response (via Oracle) resolves the market in the Hook.
    function test_AgentResponse_ResolvesHookMarket() public {
        console.log("\n===== Test: Agent Response Resolves Hook Market ====");
        // 1. Create Market, Close, Enter Resolution
        bytes32 mId = createTestMarket();
        hook.closeMarket(mId);
        uint32 taskNum = oracle.latestTaskNum();
        hook.enterResolution(mId);
        require(hook.getMarketById(mId).state == MarketState.InResolution, "Market not InResolution");
        require(oracle.latestTaskNum() == taskNum + 1, "Oracle task not created");

        // 2. Simulate Agent responding "YES"
        bytes memory agentResponse = bytes("YES");
        vm.prank(address(agent));
        oracle.respondToTask(taskNum, agentResponse);
        // (Oracle state checked in previous test)

        // 3. Verify Hook Market State and Outcome
        Market memory market = hook.getMarketById(mId);
        assertEq(uint8(market.state), uint8(MarketState.Resolved), "Market state in Hook should be Resolved");
        assertTrue(market.outcome, "Market outcome should be YES (true)");
        console.log("Hook market resolved successfully.");
        console.log("===== Test Completed Successfully ====");
    }

    // --- Helper Functions ---

    // Internal helper function to create a test market
    function createTestMarket() internal returns (bytes32) {
        require(address(hook) != address(0), "Hook not initialized");
        require(address(collateralToken) != address(0), "Collateral token not initialized");
        require(address(oracle) != address(0), "Oracle not initialized"); // Add oracle check

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
        uint32 taskIndexBefore = oracle.latestTaskNum();
        console.log("Latest task num BEFORE creating generic task:", taskIndexBefore);
        oracle.createNewTask(name); // Call the function (we don't need its Task struct return value here)
        uint32 taskIndexAfter = oracle.latestTaskNum();
        console.log("Latest task num AFTER creating generic task:", taskIndexAfter);
        require(taskIndexAfter == taskIndexBefore + 1, "Latest task number did not increment after createNewTask");
        // Return the index *of the created task*, which is the number *before* incrementing
        return taskIndexBefore;
    }

    // TODO:
    // - Test agent responding NO
    // - Test multiple agents (requires adjusting Oracle deployment params/logic)
    // - Test claiming winnings
    // - Test cancellation/redemption
    // - Test trading (requires adding liquidity)
}
