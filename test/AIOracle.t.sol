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
import {Market, MarketState, MarketSetting, CreateMarketParams} from "../src/types/MarketTypes.sol";
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
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol"; // Import Ownable for error selector
import {IPredictionMarketHook} from "../src/interfaces/IPredictionMarketHook.sol"; // For mock hook
import {MinimalRevertingHook} from "./utils/MinimalRevertingHook.sol"; // Import the mock hook

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
    uint24 public constant TEST_FEE = 3000; // 0.3% fee tier
    int24 public constant TEST_TICK_SPACING = 60; // Corresponding to 0.3% fee tier
    int24 public constant TEST_STARTING_TICK = 6900; // ~0.5 USDC or 1 USDC = 2 YES
    int24 public constant TEST_MIN_TICK = 0; // Minimum tick (adjusted by tickSpacing in hook)
    int24 public constant TEST_MAX_TICK = 207300; // Maximum tick (adjusted by tickSpacing in hook)

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
            address(this), // Pass owner as initialOwner
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

        // Create a MarketSetting struct
        MarketSetting memory settings = MarketSetting({
            fee: TEST_FEE,
            tickSpacing: TEST_TICK_SPACING,
            startingTick: TEST_STARTING_TICK,
            minTick: TEST_MIN_TICK,
            maxTick: TEST_MAX_TICK
        });

        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(oracle), // Use the connected oracle address
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Test Market: Resolve YES",
            description: "This market should resolve to YES",
            duration: 1 days,
            settings: settings // Add the settings field
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

    // --- Mock Contracts for Specific Tests ---

    // --- Oracle Manager Specific Tests ---

    function test_Oracle_FinalizeConsensus_CatchMarketResolutionFailure() public {
        // Setup oracle with minResponses = 1, threshold = 10000
        AIAgentRegistry registry7 = new AIAgentRegistry();
        AIOracleServiceManager oracle7 = new AIOracleServiceManager(address(registry7));
        MinimalRevertingHook revertingHook = new MinimalRevertingHook(); // Instantiate the new concrete mock
        oracle7.initialize(address(this), 1, 10000, address(revertingHook)); // Use reverting hook address

        // Setup agent
        AIAgent agentX = new AIAgent();
        agentX.initialize(address(this), address(oracle7), "X", "1", "X", "X");
        registry7.registerAgent(address(agentX));
        oracle7.addTestOperator(address(agentX));

        // Create a market resolution task linked to the reverting hook
        bytes32 marketId = keccak256("market123");
        uint32 taskIndex = oracle7.latestTaskNum();
        // Note: We call createMarketResolutionTask directly on the oracle for this test,
        // bypassing the hook's own creation logic.
        oracle7.createMarketResolutionTask("Resolve Reverting Market", marketId, address(revertingHook));

        // Agent responds YES - should trigger finalize and call hook
        vm.prank(address(agentX));

        // Expect ONLY the MarketResolutionFailed event, as it confirms the catch block ran.
        // The other events (ConsensusReached, TaskResponded) are less critical for THIS specific test.
        vm.expectEmit(true, false, false, false); // Check only the event signature (topic1)
        emit IAIOracleServiceManager.MarketResolutionFailed(taskIndex, marketId, ""); // Still needed for sig generation
        // 3. TaskResponded (from respondToTask after _finalizeConsensus)
        vm.expectEmit(true, false, false, false); // Check only the event signature (topic1)
        emit IAIOracleServiceManager.TaskResponded(
            taskIndex, IAIOracleServiceManager.Task("", uint32(block.number)), address(agentX)
        ); // Still needed for sig generation

        // Call the function that should trigger the internal revert and emission
        oracle7.respondToTask(taskIndex, bytes("YES"));

        // Verify task is still marked as Resolved despite hook failure
        assertEq(
            uint8(oracle7.taskStatus(taskIndex)),
            uint8(IAIOracleServiceManager.TaskStatus.Resolved),
            "Task should still resolve"
        );
        assertEq(oracle7.consensusResultHash(taskIndex), oracle7.YES_HASH(), "Consensus hash should be YES_HASH");
    }

    function test_Oracle_CreateMarketResolutionTask_Fail_InvalidInputs() public {
        // Use the main oracle instance from setUp
        bytes32 validMarketId = keccak256("validMarket");
        address validHookAddress = address(hook); // Use the hook from setUp

        // Test invalid marketId
        vm.expectRevert(bytes("Invalid marketId"));
        oracle.createMarketResolutionTask("Invalid Market ID Task", bytes32(0), validHookAddress);

        // Test invalid hookAddress
        vm.expectRevert(bytes("Invalid hookAddress"));
        oracle.createMarketResolutionTask("Invalid Hook Address Task", validMarketId, address(0));
    }

    function test_Oracle_UpdateConsensusParameters_Success_Owner() public {
        uint256 initialMin = oracle.minimumResponses();
        uint256 initialThreshold = oracle.consensusThreshold();

        vm.prank(address(this)); // Owner is 'this'
        oracle.updateConsensusParameters(initialMin + 1, initialThreshold - 100);

        assertEq(oracle.minimumResponses(), initialMin + 1, "Minimum responses not updated");
        assertEq(oracle.consensusThreshold(), initialThreshold - 100, "Consensus threshold not updated");
    }

    function test_Oracle_UpdateConsensusParameters_Fail_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0x123)));
        vm.prank(address(0x123)); // Not owner
        oracle.updateConsensusParameters(5, 7500);
    }

    function test_Oracle_UpdateConsensusParameters_Fail_InvalidThreshold() public {
        vm.expectRevert(bytes("Threshold cannot exceed 100%"));
        vm.prank(address(this));
        oracle.updateConsensusParameters(2, 10001);
    }

    function test_Oracle_UpdateConsensusParameters_Fail_ZeroMinResponses() public {
        vm.expectRevert(bytes("Minimum responses must be positive"));
        vm.prank(address(this));
        oracle.updateConsensusParameters(0, 7500);
    }

    function test_Oracle_AddTestOperator_Success_Owner() public {
        address testOp = address(0x456);
        assertFalse(oracle.testOperators(testOp), "Operator should not be test operator initially");
        vm.prank(address(this));
        oracle.addTestOperator(testOp);
        assertTrue(oracle.testOperators(testOp), "Operator should be test operator after adding");
    }

    function test_Oracle_AddTestOperator_Fail_NotOwner() public {
        address testOp = address(0x456);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0x123)));
        vm.prank(address(0x123)); // Not owner
        oracle.addTestOperator(testOp);
    }

    function test_Oracle_CreateGenericTask_StoresCorrectly() public {
        uint32 taskIndex = oracle.latestTaskNum();
        string memory taskName = "My Generic Task";

        vm.expectEmit(true, true, true, true); // Check for event
        emit IAIOracleServiceManager.NewTaskCreated(
            taskIndex, IAIOracleServiceManager.Task(taskName, uint32(block.number))
        );
        oracle.createNewTask(taskName);

        assertEq(oracle.latestTaskNum(), taskIndex + 1, "latestTaskNum did not increment");
        IAIOracleServiceManager.Task memory createdTask = oracle.getTask(taskIndex);
        assertEq(createdTask.name, taskName, "Task name mismatch");
        assertEq(
            uint8(oracle.taskStatus(taskIndex)),
            uint8(IAIOracleServiceManager.TaskStatus.Created),
            "Task status mismatch"
        );
        assertTrue(oracle.allTaskHashes(taskIndex) != bytes32(0), "Task hash not set");
    }

    function test_Oracle_RespondToTask_Fail_TaskDoesNotExist() public {
        uint32 nonExistentTask = 9999;
        vm.prank(address(agent)); // Use registered agent
        vm.expectRevert(bytes("Task does not exist"));
        oracle.respondToTask(nonExistentTask, bytes("YES"));
    }

    function test_Oracle_RespondToTask_Fail_AlreadyResponded() public {
        // Use a generic task for simplicity
        uint32 taskIndex = createGenericAIOracleTask("Respond Twice Task");

        // First response (should succeed)
        vm.prank(address(agent));
        oracle.respondToTask(taskIndex, bytes("YES"));

        // Second response (should fail)
        vm.prank(address(agent));
        vm.expectRevert(bytes("Already responded to task"));
        oracle.respondToTask(taskIndex, bytes("NO"));
    }

    function test_Oracle_RespondToTask_Fail_AlreadyResolved() public {
        // Use a market task that resolves on first response (minResponses=1, threshold=10000)
        bytes32 mId = createTestMarket();
        hook.closeMarket(mId);
        uint32 taskIndex = oracle.latestTaskNum();
        hook.enterResolution(mId);

        // First response (resolves the task)
        // NOTE: Order matters! Consensus -> Hook Resolution -> Task Response
        vm.expectEmit(true, true, true, true); // Expect ConsensusReached (emitted first in _finalize)
        emit IAIOracleServiceManager.ConsensusReached(taskIndex, ""); // Still need the emit statement for signature generation
        vm.expectEmit(true, true, true, true); // Expect MarketResolvedByOracle (emitted second in _finalize if hook call succeeds)
        emit IAIOracleServiceManager.MarketResolvedByOracle(taskIndex, mId, true); // Outcome is true (YES)
        vm.expectEmit(true, true, true, true); // Expect TaskResponded (emitted last in respondToTask)
        emit IAIOracleServiceManager.TaskResponded(
            taskIndex, IAIOracleServiceManager.Task("", uint32(block.number)), address(agent)
        );

        vm.prank(address(agent));
        oracle.respondToTask(taskIndex, bytes("YES"));
        assertEq(
            uint8(oracle.taskStatus(taskIndex)),
            uint8(IAIOracleServiceManager.TaskStatus.Resolved),
            "Task should be resolved"
        );

        // Try to respond again
        // Need another agent/operator for this test
        AIAgent agent2 = new AIAgent();
        agent2.initialize(
            address(this), // Owner
            address(oracle),
            "AGENT2",
            "v1",
            "Agent2",
            "AG2"
        );
        vm.prank(address(this));
        registry.registerAgent(address(agent2));
        vm.prank(address(this));
        oracle.addTestOperator(address(agent2));

        vm.prank(address(agent2));
        vm.expectRevert(bytes("Task has already been resolved"));
        oracle.respondToTask(taskIndex, bytes("NO"));
    }

    function test_Oracle_RespondToTask_Fail_MarketTaskInvalidResponse() public {
        bytes32 mId = createTestMarket();
        hook.closeMarket(mId);
        uint32 taskIndex = oracle.latestTaskNum();
        hook.enterResolution(mId);

        vm.prank(address(agent));
        vm.expectRevert(bytes("Invalid response for market resolution"));
        oracle.respondToTask(taskIndex, bytes("MAYBE"));
    }

    function test_Oracle_RespondToTask_Fail_NotRegisteredAgent_NotInTestMode() public {
        // Need to set up oracle with minResponses > 1 to disable test mode bypass
        AIAgentRegistry registry2 = new AIAgentRegistry();
        AIOracleServiceManager oracle2 = new AIOracleServiceManager(address(registry2));
        AIAgent unregisteredAgent = new AIAgent();
        // Don't register unregisteredAgent

        // Initialize oracle2 with minResponses = 2 (not test mode)
        oracle2.initialize(address(this), 2, 7000, address(hook)); // Hook address doesn't really matter here
        uint32 taskIndex = oracle2.latestTaskNum();
        oracle2.createNewTask("Require Registration Task");

        vm.prank(address(unregisteredAgent));
        vm.expectRevert(bytes("Agent contract not registered"));
        oracle2.respondToTask(taskIndex, bytes("Some Data"));
    }

    // --- Consensus Tests ---
    function test_Oracle_Consensus_NotReached_BelowMinimumResponses() public {
        // Setup oracle with minResponses = 3
        AIAgentRegistry registry3 = new AIAgentRegistry();
        AIOracleServiceManager oracle3 = new AIOracleServiceManager(address(registry3));
        oracle3.initialize(address(this), 3, 7000, address(hook));

        // Setup 2 agents
        AIAgent agentA = new AIAgent();
        agentA.initialize(
            address(this), // Owner
            address(oracle3),
            "A",
            "1",
            "A",
            "A"
        );
        registry3.registerAgent(address(agentA));
        oracle3.addTestOperator(address(agentA));
        AIAgent agentB = new AIAgent();
        agentB.initialize(
            address(this), // Owner
            address(oracle3),
            "B",
            "1",
            "B",
            "B"
        );
        registry3.registerAgent(address(agentB));
        oracle3.addTestOperator(address(agentB));

        uint32 taskIndex = oracle3.latestTaskNum();
        oracle3.createNewTask("Consensus Test Task");

        // Agent A responds
        vm.prank(address(agentA));
        oracle3.respondToTask(taskIndex, bytes("Response1"));
        assertEq(
            uint8(oracle3.taskStatus(taskIndex)),
            uint8(IAIOracleServiceManager.TaskStatus.InProgress),
            "Task status after 1st response"
        );

        // Agent B responds (different response)
        vm.prank(address(agentB));
        oracle3.respondToTask(taskIndex, bytes("Response2"));
        assertEq(
            uint8(oracle3.taskStatus(taskIndex)),
            uint8(IAIOracleServiceManager.TaskStatus.InProgress),
            "Task status after 2nd response - should still be InProgress"
        );
        assertEq(oracle3.consensusResultHash(taskIndex), bytes32(0), "Consensus hash should be zero");
    }

    function test_Oracle_Consensus_NotReached_BelowThreshold() public {
        // Setup oracle with minResponses = 2, threshold = 70% (7000)
        AIAgentRegistry registry4 = new AIAgentRegistry();
        AIOracleServiceManager oracle4 = new AIOracleServiceManager(address(registry4));
        oracle4.initialize(address(this), 2, 7000, address(hook));

        // Setup 3 agents
        AIAgent agentC = new AIAgent();
        agentC.initialize(
            address(this), // Owner
            address(oracle4),
            "C",
            "1",
            "C",
            "C"
        );
        registry4.registerAgent(address(agentC));
        oracle4.addTestOperator(address(agentC));
        AIAgent agentD = new AIAgent();
        agentD.initialize(
            address(this), // Owner
            address(oracle4),
            "D",
            "1",
            "D",
            "D"
        );
        registry4.registerAgent(address(agentD));
        oracle4.addTestOperator(address(agentD));
        AIAgent agentE = new AIAgent();
        agentE.initialize(
            address(this), // Owner
            address(oracle4),
            "E",
            "1",
            "E",
            "E"
        );
        registry4.registerAgent(address(agentE));
        oracle4.addTestOperator(address(agentE));

        uint32 taskIndex = oracle4.latestTaskNum();
        oracle4.createNewTask("Threshold Test Task");

        bytes memory resp1 = bytes("Agree");
        bytes memory resp2 = bytes("Disagree1");
        bytes memory resp3 = bytes("Disagree2");

        // Agent C responds (Agree)
        vm.prank(address(agentC));
        oracle4.respondToTask(taskIndex, resp1);
        assertEq(uint8(oracle4.taskStatus(taskIndex)), uint8(IAIOracleServiceManager.TaskStatus.InProgress));

        // Agent D responds (Disagree1)
        vm.prank(address(agentD));
        oracle4.respondToTask(taskIndex, resp2);
        assertEq(uint8(oracle4.taskStatus(taskIndex)), uint8(IAIOracleServiceManager.TaskStatus.InProgress)); // 2 responses, but 1/2 = 50% < 70%

        // Agent E responds (Disagree2)
        vm.prank(address(agentE));
        oracle4.respondToTask(taskIndex, resp3);
        assertEq(uint8(oracle4.taskStatus(taskIndex)), uint8(IAIOracleServiceManager.TaskStatus.InProgress)); // 3 responses, but max votes is 1/3 = 33% < 70%
        assertEq(oracle4.consensusResultHash(taskIndex), bytes32(0), "Consensus hash should be zero");
    }

    function test_Oracle_Consensus_Reached_ExactThreshold() public {
        // Setup oracle with minResponses = 2, threshold = 70% (7000)
        AIAgentRegistry registry5 = new AIAgentRegistry();
        AIOracleServiceManager oracle5 = new AIOracleServiceManager(address(registry5));
        oracle5.initialize(address(this), 7, 7000, address(hook));

        // Setup 10 agents
        AIAgent[10] memory agents;
        for (uint256 i = 0; i < 10; i++) {
            agents[i] = new AIAgent();
            agents[i].initialize(
                address(this), // Owner
                address(oracle5),
                "X",
                "1",
                "X",
                "X"
            );
            registry5.registerAgent(address(agents[i]));
            oracle5.addTestOperator(address(agents[i]));
        }

        uint32 taskIndex = oracle5.latestTaskNum();
        oracle5.createNewTask("Threshold Exact Test Task");

        bytes memory winningResponse = bytes("WINNER");
        bytes memory losingResponse = bytes("LOSER");
        bytes32 winningHash = keccak256(winningResponse);

        // 7 agents respond WINNER (7/10 = 70%)
        for (uint256 i = 0; i < 7; i++) {
            vm.prank(address(agents[i]));
            oracle5.respondToTask(taskIndex, winningResponse);
            // Check *before* the 7th response that it's still InProgress
            if (i == 5) {
                // After 6 responses (6/10 = 60%)
                assertEq(
                    uint8(oracle5.taskStatus(taskIndex)),
                    uint8(IAIOracleServiceManager.TaskStatus.InProgress),
                    "Should not resolve before 7th WINNER response"
                );
            }
        }
        // 7th response should trigger resolution - check after the loop
        assertEq(
            uint8(oracle5.taskStatus(taskIndex)),
            uint8(IAIOracleServiceManager.TaskStatus.Resolved),
            "Should be resolved after 7th WINNER response"
        );
        assertEq(oracle5.consensusResultHash(taskIndex), winningHash, "Consensus hash mismatch");
    }

    // --- distributeRewards Test ---
    function test_Oracle_DistributeRewards_Fail_TaskNotResolved() public {
        uint32 taskIndex = createGenericAIOracleTask("Reward Test Task");
        // Task is only Created, not Resolved
        vm.expectRevert(bytes("Task not resolved"));
        oracle.distributeRewards(taskIndex);
    }

    function test_Oracle_DistributeRewards_Success_Events() public {
        // Setup oracle with minResponses = 1, threshold = 10000 (simplest resolution)
        AIAgentRegistry registry6 = new AIAgentRegistry();
        AIOracleServiceManager oracle6 = new AIOracleServiceManager(address(registry6));
        oracle6.initialize(address(this), 1, 10000, address(hook));

        // Setup 3 agents
        AIAgent agentW1 = new AIAgent();
        agentW1.initialize(address(this), address(oracle6), "W1", "1", "W1", "W1");
        registry6.registerAgent(address(agentW1));
        oracle6.addTestOperator(address(agentW1));
        AIAgent agentW2 = new AIAgent();
        agentW2.initialize(address(this), address(oracle6), "W2", "1", "W2", "W2");
        registry6.registerAgent(address(agentW2));
        oracle6.addTestOperator(address(agentW2));
        AIAgent agentL1 = new AIAgent();
        agentL1.initialize(address(this), address(oracle6), "L1", "1", "L1", "L1");
        registry6.registerAgent(address(agentL1));
        oracle6.addTestOperator(address(agentL1));

        uint32 taskIndex = oracle6.latestTaskNum();
        oracle6.createNewTask("Reward Distribution Test");

        bytes memory winningResponse = bytes("WIN");
        bytes memory losingResponse = bytes("LOSE");

        // Agent W1 responds (WIN) - Triggers resolution
        vm.prank(address(agentW1));
        oracle6.respondToTask(taskIndex, winningResponse);
        assertEq(
            uint8(oracle6.taskStatus(taskIndex)),
            uint8(IAIOracleServiceManager.TaskStatus.Resolved),
            "Task should be resolved by W1"
        );

        // Agent W2 responds (WIN) - Should fail as already resolved
        vm.prank(address(agentW2));
        vm.expectRevert(bytes("Task has already been resolved"));
        oracle6.respondToTask(taskIndex, winningResponse);
        // Need W2's response hash stored for reward check later, respond before resolution
        // Let's adjust the setup: MinResponses=3, Threshold=6000
        // Re-run with adjusted setup in a new test or modify this one. Sticking with modification for now.

        // --- Reset and Redo Setup for Reward Test ---
        registry6 = new AIAgentRegistry();
        oracle6 = new AIOracleServiceManager(address(registry6));
        oracle6.initialize(address(this), 3, 6000, address(hook)); // Min 3 responses, 60% threshold

        agentW1 = new AIAgent();
        agentW1.initialize(address(this), address(oracle6), "W1", "1", "W1", "W1");
        registry6.registerAgent(address(agentW1));
        oracle6.addTestOperator(address(agentW1));
        agentW2 = new AIAgent();
        agentW2.initialize(address(this), address(oracle6), "W2", "1", "W2", "W2");
        registry6.registerAgent(address(agentW2));
        oracle6.addTestOperator(address(agentW2));
        agentL1 = new AIAgent();
        agentL1.initialize(address(this), address(oracle6), "L1", "1", "L1", "L1");
        registry6.registerAgent(address(agentL1));
        oracle6.addTestOperator(address(agentL1));

        taskIndex = oracle6.latestTaskNum();
        oracle6.createNewTask("Reward Distribution Test V2");

        // Responses
        vm.prank(address(agentW1));
        oracle6.respondToTask(taskIndex, winningResponse); // 1 W / 1 T
        vm.prank(address(agentL1));
        oracle6.respondToTask(taskIndex, losingResponse); // 1 W / 2 T
        vm.prank(address(agentW2));
        oracle6.respondToTask(taskIndex, winningResponse); // 2 W / 3 T -> Resolves (2/3 = 66% >= 60%)

        assertEq(
            uint8(oracle6.taskStatus(taskIndex)),
            uint8(IAIOracleServiceManager.TaskStatus.Resolved),
            "Task should be resolved by W2"
        );
        assertEq(oracle6.consensusResultHash(taskIndex), keccak256(winningResponse), "Winning hash mismatch");

        // --- Distribute Rewards ---
        uint256 expectedReward = 1 ether; // From placeholder calculateReward function

        // Expect reward for W1
        vm.expectEmit(true, true, true, true);
        emit IAIOracleServiceManager.AgentRewarded(address(agentW1), taskIndex, expectedReward);
        // Expect reward for W2
        vm.expectEmit(true, true, true, true);
        emit IAIOracleServiceManager.AgentRewarded(address(agentW2), taskIndex, expectedReward);
        // !!! Crucially, DO NOT expect reward for L1 !!!

        // Call distributeRewards - Check only for the two expected events
        oracle6.distributeRewards(taskIndex);

        // If the test reaches here without reverting and the two events were emitted, it passes.
        // We cannot easily check *lack* of emission for L1 with current Foundry tools.
    }

    // --- View Function Tests ---
    function test_Oracle_GetTask_Success() public {
        uint32 taskIndex = createGenericAIOracleTask("Get Task Test");
        IAIOracleServiceManager.Task memory task = oracle.getTask(taskIndex);
        assertEq(task.name, "Get Task Test");
        assertTrue(task.taskCreatedBlock > 0, "Task creation block not set");
    }

    function test_Oracle_GetTask_Fail_NotFound() public {
        vm.expectRevert(bytes("Task does not exist"));
        oracle.getTask(9999);
    }

    function test_Oracle_GetConsensusResult() public {
        // Use a market task that resolves on first response (minResponses=1, threshold=10000)
        bytes32 mId = createTestMarket();
        hook.closeMarket(mId);
        uint32 taskIndex = oracle.latestTaskNum();
        hook.enterResolution(mId);

        // Before resolution
        (bytes memory resultBefore, bool isResolvedBefore) = oracle.getConsensusResult(taskIndex);
        assertEq(resultBefore, "", "Result bytes should be empty before resolution");
        assertFalse(isResolvedBefore, "Should not be resolved before response");

        // Agent responds YES (resolves the task)
        vm.prank(address(agent));
        oracle.respondToTask(taskIndex, bytes("YES"));

        // After resolution
        (bytes memory resultAfter, bool isResolvedAfter) = oracle.getConsensusResult(taskIndex);
        assertEq(resultAfter, "", "Result bytes should still be empty after resolution (only hash stored)");
        assertTrue(isResolvedAfter, "Should be resolved after response");
    }

    function test_Oracle_TaskRespondents() public {
        // Setup oracle with minResponses = 3
        AIAgentRegistry registry8 = new AIAgentRegistry();
        AIOracleServiceManager oracle8 = new AIOracleServiceManager(address(registry8));
        oracle8.initialize(address(this), 3, 7000, address(hook));

        // Setup 2 agents
        AIAgent agentA = new AIAgent();
        agentA.initialize(address(this), address(oracle8), "A", "1", "A", "A");
        registry8.registerAgent(address(agentA));
        oracle8.addTestOperator(address(agentA));
        AIAgent agentB = new AIAgent();
        agentB.initialize(address(this), address(oracle8), "B", "1", "B", "B");
        registry8.registerAgent(address(agentB));
        oracle8.addTestOperator(address(agentB));

        uint32 taskIndex = oracle8.latestTaskNum();
        oracle8.createNewTask("Respondents Test Task");

        // Before responses
        address[] memory respondents0 = oracle8.taskRespondents(taskIndex);
        assertEq(respondents0.length, 0, "Should be 0 respondents initially");

        // Agent A responds
        vm.prank(address(agentA));
        oracle8.respondToTask(taskIndex, bytes("R1"));
        address[] memory respondents1 = oracle8.taskRespondents(taskIndex);
        assertEq(respondents1.length, 1, "Should be 1 respondent after A");
        assertEq(respondents1[0], address(agentA), "Respondent 1 mismatch");

        // Agent B responds
        vm.prank(address(agentB));
        oracle8.respondToTask(taskIndex, bytes("R2"));
        address[] memory respondents2 = oracle8.taskRespondents(taskIndex);
        assertEq(respondents2.length, 2, "Should be 2 respondents after B");
        // Order is not guaranteed, check presence
        bool foundA = false;
        bool foundB = false;
        for (uint256 i = 0; i < respondents2.length; i++) {
            if (respondents2[i] == address(agentA)) foundA = true;
            if (respondents2[i] == address(agentB)) foundB = true;
        }
        assertTrue(foundA && foundB, "Both agents should be in respondents list");
    }

    function test_Oracle_GetMarketAndHookDetails() public {
        bytes32 marketId = createTestMarket();
        hook.closeMarket(marketId);
        uint32 taskIndex = oracle.latestTaskNum();
        hook.enterResolution(marketId);
        uint32 genericTaskIndex = createGenericAIOracleTask("Generic");

        // Check market task
        bytes32 retrievedMarketId = oracle.getMarketIdForTask(taskIndex);
        address retrievedHookAddress = oracle.getHookAddressForTask(taskIndex);
        assertEq(retrievedMarketId, marketId, "Market ID mismatch for market task");
        assertEq(retrievedHookAddress, address(hook), "Hook address mismatch for market task");

        // Check generic task
        bytes32 retrievedMarketIdGeneric = oracle.getMarketIdForTask(genericTaskIndex);
        address retrievedHookAddressGeneric = oracle.getHookAddressForTask(genericTaskIndex);
        assertEq(retrievedMarketIdGeneric, bytes32(0), "Market ID should be zero for generic task");
        assertEq(retrievedHookAddressGeneric, address(0), "Hook address should be zero for generic task");
    }
}
