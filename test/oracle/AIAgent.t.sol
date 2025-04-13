// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AIAgent} from "../../src/oracle/AIAgent.sol";
import {IAIOracleServiceManager} from "../../src/interfaces/IAIOracleServiceManager.sol";
import {AIAgentRegistry} from "../../src/oracle/AIAgentRegistry.sol"; // Needed for status enum
import {ERC20Mock} from "../utils/ERC20Mock.sol"; // Example, might not be needed directly
import {IAIAgentRegistry} from "../../src/interfaces/IAIAgentRegistry.sol"; // For mock
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol"; // Import Ownable for error selector

// Mock for Oracle Service Manager Interface
contract MockOracleServiceManager is IAIOracleServiceManager {
    mapping(uint32 => bytes32) public allTaskHashes;
    mapping(uint32 => mapping(address => bool)) public hasResponded;
    mapping(uint32 => TaskStatus) private _taskStatus;
    bytes public lastResponseData;
    uint32 public lastTaskIndexResponded;
    address public lastRespondent;
    uint32 public latestTaskNum = 0;


    function createMarketResolutionTask(string memory, bytes32, address) external returns (uint32) { return 0; }
    function createNewTask(string memory) external returns (Task memory) { Task memory t; return t;}
    function respondToTask(uint32 referenceTaskIndex, bytes calldata signature) external {
        lastResponseData = signature;
        lastTaskIndexResponded = referenceTaskIndex;
        lastRespondent = msg.sender;
        hasResponded[referenceTaskIndex][msg.sender] = true;
    }
    function distributeRewards(uint32) external {}
    function addTestOperator(address) external {}
    function getConsensusResult(uint32) external view returns (bytes memory, bool) { return ("", false); }
    function taskStatus(uint32 taskIndex) external view returns (TaskStatus) { return _taskStatus[taskIndex]; }
    function taskRespondents(uint32) external view returns (address[] memory) { address[] memory a; return a; }
    function consensusResultHash(uint32) external view returns (bytes32) { return bytes32(0); }
    function allTaskResponses(address, uint32) external view returns (bytes memory) { return ""; }
    function getMarketIdForTask(uint32) external view returns (bytes32) { return bytes32(0); }
    function getHookAddressForTask(uint32) external view returns (address) { return address(0); }
    function getTask(uint32) external view returns (Task memory) { Task memory t; return t; }

    // --- Mock Specific Helpers ---
    function setTaskExists(uint32 taskIndex) public {
        allTaskHashes[taskIndex] = keccak256(abi.encodePacked("mock_task", taskIndex));
        _taskStatus[taskIndex] = TaskStatus.Created; // Or InProgress? Let's assume Created for now
    }
    function setTaskStatus(uint32 taskIndex, TaskStatus status) public {
         _taskStatus[taskIndex] = status;
    }
     function setAgentResponded(uint32 taskIndex, address agent) public {
         hasResponded[taskIndex][agent] = true;
    }
    function owner() external view returns (address) { return address(this); } // Required by OwnableUpgradeable if used
    function minimumResponses() external view returns (uint256) { return 1; } // Required by OwnableUpgradeable if used
    function consensusThreshold() external view returns (uint256) { return 10000; } // Required by OwnableUpgradeable if used
    function testOperators(address) external view returns (bool) { return false; }
    function agentRegistry() external view returns (IAIAgentRegistry) { return IAIAgentRegistry(address(0)); } // Required by OwnableUpgradeable if used
    function taskToMarketId(uint32) external view returns (bytes32) { return bytes32(0); } // Required by OwnableUpgradeable if used
    function taskToHookAddress(uint32) external view returns (address) { return address(0); } // Required by OwnableUpgradeable if used
    function predictionMarketHook() external view returns (address) { return address(0); } // Required by OwnableUpgradeable if used
    function allTaskResponseHashes(address, uint32) external view returns (bytes32) { return bytes32(0); } // Required by OwnableUpgradeable if used

    // Add missing function from interface
    function updateConsensusParameters(uint256 /*_minimumResponses*/, uint256 /*_consensusThreshold*/) external { 
        // Mock implementation - does nothing
    }
}


contract AIAgentTest is Test {
    AIAgent public agent;
    MockOracleServiceManager public oracleMock;
    address public owner;
    address public otherUser;

    function setUp() public {
        owner = address(this);
        otherUser = address(0x123); // Example other user address
        oracleMock = new MockOracleServiceManager();

        agent = new AIAgent();
        // Initialize using the Initializable pattern within the test
        agent.initialize(
            owner,
            address(oracleMock),
            "TestModel",
            "v1.0",
            "TestAgentNFT",
            "TAGENT"
        );
         // Transfer ownership to the test contract for owner-based tests AFTER initialization
        // Note: OwnableUpgradeable uses msg.sender in initializer as initial owner
        // So we need to transfer from the deployer (this) to the intended owner if different,
        // but here the deployer IS the intended owner.
        // If owner were different: vm.prank(agent.owner()); agent.transferOwnership(owner);
    }

    // --- Test Functions Will Go Here ---

    // --- Initialization Tests ---

    function test_Initialize_SetsCorrectValues() public {
        assertEq(address(agent.serviceManager()), address(oracleMock), "Service manager mismatch");
        assertEq(agent.modelType(), "TestModel", "Model type mismatch");
        assertEq(agent.modelVersion(), "v1.0", "Model version mismatch");
        assertEq(uint8(agent.status()), uint8(AIAgent.AgentStatus.Active), "Initial status should be Active");
        assertEq(agent.owner(), owner, "Owner should be the deployer (this contract)"); // OwnableUpgradeable sets owner in init
    }

    // --- Access Control Tests (Owner Functions) ---

    function test_SetStatus_Success_Owner() public {
        vm.prank(owner);
        agent.setStatus(AIAgent.AgentStatus.Suspended);
        assertEq(uint8(agent.status()), uint8(AIAgent.AgentStatus.Suspended), "Status not updated correctly");
    }

    function test_SetStatus_Fail_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, otherUser));
        vm.prank(otherUser);
        agent.setStatus(AIAgent.AgentStatus.Suspended);
    }

    function test_UpdateModelInfo_Success_Owner() public {
        vm.prank(owner);
        agent.updateModelInfo("UpdatedModel", "v2.0");
        assertEq(agent.modelType(), "UpdatedModel", "Model type not updated");
        assertEq(agent.modelVersion(), "v2.0", "Model version not updated");
    }

    function test_UpdateModelInfo_Fail_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, otherUser));
        vm.prank(otherUser);
        agent.updateModelInfo("UpdatedModel", "v2.0");
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

    function test_RecordReward_Fail_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, otherUser));
        vm.prank(otherUser);
        agent.recordReward(1 ether, 123);
    }

    // --- processTask Tests ---

    function test_ProcessTask_Success_Yes() public {
        uint32 taskIndex = 1;
        oracleMock.setTaskExists(taskIndex);
        uint256 initialTasksCompleted = agent.tasksCompleted();

        vm.prank(owner); // Assume owner operates the agent for this call
        agent.processTask(taskIndex, true); // YES decision

        // Verify interaction with Oracle Mock
        assertEq(oracleMock.lastTaskIndexResponded(), taskIndex, "Oracle mock: Task index mismatch");
        assertEq(oracleMock.lastRespondent(), address(agent), "Oracle mock: Respondent mismatch");
        assertEq(oracleMock.lastResponseData(), bytes("YES"), "Oracle mock: Response data mismatch (YES)");

        // Verify agent state
        assertEq(agent.tasksCompleted(), initialTasksCompleted + 1, "Tasks completed not incremented");
    }

    function test_ProcessTask_Success_No() public {
        uint32 taskIndex = 2;
        oracleMock.setTaskExists(taskIndex);
        uint256 initialTasksCompleted = agent.tasksCompleted();

        vm.prank(owner);
        agent.processTask(taskIndex, false); // NO decision

        // Verify interaction with Oracle Mock
        assertEq(oracleMock.lastTaskIndexResponded(), taskIndex, "Oracle mock: Task index mismatch");
        assertEq(oracleMock.lastRespondent(), address(agent), "Oracle mock: Respondent mismatch");
        assertEq(oracleMock.lastResponseData(), bytes("NO"), "Oracle mock: Response data mismatch (NO)");

        // Verify agent state
        assertEq(agent.tasksCompleted(), initialTasksCompleted + 1, "Tasks completed not incremented");
    }

    function test_ProcessTask_Fail_NotActive() public {
        uint32 taskIndex = 3;
        oracleMock.setTaskExists(taskIndex);

        // Set agent to Inactive
        vm.prank(owner);
        agent.setStatus(AIAgent.AgentStatus.Inactive);

        vm.expectRevert(bytes("Agent is not active"));
        vm.prank(owner);
        agent.processTask(taskIndex, true);
    }

     function test_ProcessTask_Fail_Suspended() public {
        uint32 taskIndex = 4;
        oracleMock.setTaskExists(taskIndex);

        // Set agent to Suspended
        vm.prank(owner);
        agent.setStatus(AIAgent.AgentStatus.Suspended);

        vm.expectRevert(bytes("Agent is not active"));
        vm.prank(owner);
        agent.processTask(taskIndex, true);
    }

    function test_ProcessTask_Fail_TaskDoesNotExist() public {
        uint32 nonExistentTaskIndex = 99;
        // Do not call oracleMock.setTaskExists(nonExistentTaskIndex);

        vm.expectRevert(bytes("Task does not exist"));
        vm.prank(owner);
        agent.processTask(nonExistentTaskIndex, true);
    }

    // Note: The check for double-voting is handled by the Oracle Service Manager,
    // so it's not tested directly here unless the Agent adds its own check.

    // --- getAgentStats Test ---

    function test_GetAgentStats_ReturnsCorrectValues() public {
        // Update some stats first
        uint32 taskIndexForStats = 1;
        oracleMock.setTaskExists(taskIndexForStats); // Ensure task exists before agent processes it

        vm.prank(owner);
        agent.processTask(taskIndexForStats, true); // tasksCompleted = 1
        vm.prank(owner);
        agent.recordReward(1 ether, taskIndexForStats); // consensusParticipations = 1, totalRewardsEarned = 1 ether
        vm.prank(owner);
        agent.setStatus(AIAgent.AgentStatus.Suspended); // status = Suspended

        (uint256 tasks, uint256 participations, uint256 rewards, AIAgent.AgentStatus status) = agent.getAgentStats();

        assertEq(tasks, 1, "Stat: Tasks completed mismatch");
        assertEq(participations, 1, "Stat: Consensus participations mismatch");
        assertEq(rewards, 1 ether, "Stat: Total rewards earned mismatch");
        assertEq(uint8(status), uint8(AIAgent.AgentStatus.Suspended), "Stat: Status mismatch");
    }
} 