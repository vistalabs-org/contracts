// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AIAgent} from "../../src/oracle/AIAgent.sol";
import {IAIOracleServiceManager} from "../../src/interfaces/IAIOracleServiceManager.sol";
import {AIAgentRegistry} from "../../src/oracle/AIAgentRegistry.sol"; // Needed for status enum and deployment
import {AIOracleServiceManager} from "../../src/oracle/AIOracleServiceManager.sol"; // Import real contract
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol"; // Import OwnableUpgradeable

contract AIAgentTest is Test {
    AIAgent public agent;
    // MockOracleServiceManager public oracleMock; // Removed
    AIOracleServiceManager public oracle; // Use real contract
    AIAgentRegistry public registry; // Need registry
    address public owner;
    address public otherUser;

    function setUp() public {
        owner = address(this);
        otherUser = address(0x123); // Example other user address
        // oracleMock = new MockOracleServiceManager(); // Removed

        // Deploy Real Oracle Components
        registry = new AIAgentRegistry();
        oracle = new AIOracleServiceManager(address(registry));
        // Initialize Oracle (use dummy hook address, test mode params)
        oracle.initialize(owner, 1, 10000, address(0xbeef));

        // Deploy Agent
        agent = new AIAgent();
        // Initialize Agent with Real Oracle
        agent.initialize(
            owner, // Agent owner
            address(oracle), // Real oracle address
            "TestModel",
            "v1.0",
            "TestAgentNFT",
            "TAGENT"
        );

        // Register Agent with Registry (Registry owner is deployer = this = owner)
        registry.registerAgent(address(agent));

        // Add agent as test operator for easier testing (Oracle owner is deployer = this = owner)
        oracle.addTestOperator(address(agent));
    }

    // --- Test Functions Will Go Here (Need Adaptation) ---

    // --- Initialization Tests ---

    function test_Initialize_SetsCorrectValues() public {
        assertEq(address(agent.serviceManager()), address(oracle), "Service manager mismatch"); // Check against real oracle
        assertEq(agent.modelType(), "TestModel", "Model type mismatch");
        assertEq(agent.modelVersion(), "v1.0", "Model version mismatch");
        assertEq(uint8(agent.status()), uint8(AIAgent.AgentStatus.Active), "Initial status should be Active");
        assertEq(agent.owner(), owner, "Owner should be the deployer (this contract)");
    }

    // --- Access Control Tests (Owner Functions) ---

    function test_SetStatus_Success_Owner() public {
        vm.prank(owner);
        agent.setStatus(AIAgent.AgentStatus.Suspended);
        assertEq(uint8(agent.status()), uint8(AIAgent.AgentStatus.Suspended), "Status not updated correctly");
    }

    function test_UpdateModelInfo_Success_Owner() public {
        vm.prank(owner);
        agent.updateModelInfo("UpdatedModel", "v2.0");
        assertEq(agent.modelType(), "UpdatedModel", "Model type not updated");
        assertEq(agent.modelVersion(), "v2.0", "Model version not updated");
    }

    function test_RecordReward_Success_Owner() public {
        uint256 initialRewards = agent.totalRewardsEarned();
        uint256 initialParticipations = agent.consensusParticipations();
        uint256 rewardAmount = 1 ether;

        vm.prank(owner);
        agent.recordReward(rewardAmount, 123);

        assertEq(agent.totalRewardsEarned(), initialRewards + rewardAmount, "Rewards not updated");
        assertEq(agent.consensusParticipations(), initialParticipations + 1, "Participations not updated");
    }

    // --- processTask Tests --- (ADAPTED)

    function test_ProcessTask_Success_Yes() public {
        // 1. Create task on real oracle
        uint32 taskIndex = oracle.latestTaskNum();
        oracle.createNewTask("Real Task YES");

        uint256 initialTasksCompleted = agent.tasksCompleted();

        // 2. Agent processes task (owner calls processTask, agent calls respondToTask)
        vm.prank(owner);
        agent.processTask(taskIndex, true); // YES decision

        // 3. Verify oracle state
        assertTrue(oracle.hasResponded(taskIndex, address(agent)), "Oracle should record agent response");
        address[] memory respondents = oracle.taskRespondents(taskIndex);
        assertEq(respondents.length, 1, "Respondents array length mismatch");
        assertEq(respondents[0], address(agent), "Respondent mismatch");
        // Check response hash if needed (oracle stores hash)
        bytes32 expectedHash = keccak256(bytes("YES"));
        assertEq(oracle.allTaskResponseHashes(address(agent), taskIndex), expectedHash, "Oracle response hash mismatch");

        // 4. Verify agent state
        assertEq(agent.tasksCompleted(), initialTasksCompleted + 1, "Tasks completed not incremented");
    }

    function test_ProcessTask_Success_No() public {
        // 1. Create task on real oracle
        uint32 taskIndex = oracle.latestTaskNum();
        oracle.createNewTask("Real Task NO");

        uint256 initialTasksCompleted = agent.tasksCompleted();

        // 2. Agent processes task
        vm.prank(owner);
        agent.processTask(taskIndex, false); // NO decision

        // 3. Verify oracle state
        assertTrue(oracle.hasResponded(taskIndex, address(agent)), "Oracle should record agent response");
        bytes32 expectedHash = keccak256(bytes("NO"));
        assertEq(oracle.allTaskResponseHashes(address(agent), taskIndex), expectedHash, "Oracle response hash mismatch");

        // 4. Verify agent state
        assertEq(agent.tasksCompleted(), initialTasksCompleted + 1, "Tasks completed not incremented");
    }

    function test_ProcessTask_Fail_NotActive() public {
        // 1. Create task on real oracle
        uint32 taskIndex = oracle.latestTaskNum();
        oracle.createNewTask("Real Task Not Active");

        // 2. Set agent to Inactive
        vm.prank(owner);
        agent.setStatus(AIAgent.AgentStatus.Inactive);

        // 3. Expect revert from agent's check
        vm.expectRevert(bytes("Agent is not active"));
        vm.prank(owner);
        agent.processTask(taskIndex, true);
    }

    function test_ProcessTask_Fail_Suspended() public {
        // 1. Create task on real oracle
        uint32 taskIndex = oracle.latestTaskNum();
        oracle.createNewTask("Real Task Suspended");

        // 2. Set agent to Suspended
        vm.prank(owner);
        agent.setStatus(AIAgent.AgentStatus.Suspended);

        // 3. Expect revert from agent's check
        vm.expectRevert(bytes("Agent is not active"));
        vm.prank(owner);
        agent.processTask(taskIndex, true);
    }

    function test_ProcessTask_Fail_TaskDoesNotExist() public {
        uint32 nonExistentTaskIndex = 99;
        // Do not create the task on the oracle

        // Expect revert from agent's check (querying oracle)
        vm.expectRevert(bytes("Task does not exist"));
        vm.prank(owner);
        agent.processTask(nonExistentTaskIndex, true);
    }

    // --- getAgentStats Test --- (ADAPTED)

    function test_GetAgentStats_ReturnsCorrectValues() public {
        // 1. Create task on real oracle
        uint32 taskIndexForStats = oracle.latestTaskNum();
        oracle.createNewTask("Real Task Stats");

        // 2. Update agent stats via interactions
        vm.prank(owner);
        agent.processTask(taskIndexForStats, true); // tasksCompleted = 1
        vm.prank(owner);
        agent.recordReward(1 ether, taskIndexForStats); // consensusParticipations = 1, totalRewardsEarned = 1 ether
        vm.prank(owner);
        agent.setStatus(AIAgent.AgentStatus.Suspended); // status = Suspended

        // 3. Call getAgentStats and assert
        (uint256 tasks, uint256 participations, uint256 rewards, AIAgent.AgentStatus status) = agent.getAgentStats();

        assertEq(tasks, 1, "Stat: Tasks completed mismatch");
        assertEq(participations, 1, "Stat: Consensus participations mismatch");
        assertEq(rewards, 1 ether, "Stat: Total rewards earned mismatch");
        assertEq(uint8(status), uint8(AIAgent.AgentStatus.Suspended), "Stat: Status mismatch");
    }
}
