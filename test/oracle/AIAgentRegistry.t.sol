// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AIAgentRegistry} from "../../src/oracle/AIAgentRegistry.sol";
import {AIAgent} from "../../src/oracle/AIAgent.sol";
import {IAIOracleServiceManager} from "../../src/interfaces/IAIOracleServiceManager.sol"; // Added for Agent interface
import {MockOracleServiceManager} from "./AIAgent.t.sol"; // Reuse mock
import {IAIAgentRegistry} from "../../src/interfaces/IAIAgentRegistry.sol"; // Added for Agent interface
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol"; // Import Ownable for error selector


// Minimal Mock Agent for Registry Tests - Plain contract, not inheriting AIAgent
contract MockAgent { 
    IAIOracleServiceManager public serviceManager;
    string public modelType;
    string public modelVersion;
    AIAgent.AgentStatus public status;
    address public owner;

    // Simple constructor/initializer for the mock
    constructor(address _serviceManager, string memory _modelType, string memory _modelVersion) {
        serviceManager = IAIOracleServiceManager(_serviceManager);
        modelType = _modelType;
        modelVersion = _modelVersion;
        status = AIAgent.AgentStatus.Active;
        owner = msg.sender; // Store deployer as owner for potential checks
    }

    // Function required by registry: setStatus
    function setStatus(AIAgent.AgentStatus _status) public { // No longer override
        status = _status;
    }

    // Function required by registry: getAgentStats
    function getAgentStats()
        public
        view
        // No longer override
        returns (
            uint256 _tasksCompleted,
            uint256 _consensusParticipations,
            uint256 _totalRewards,
            AIAgent.AgentStatus _currentStatus
        )
    {
        // Return fixed values for testing updateAgentStats
        return (10, 5, 500 ether, status);
    }
    
    // Function required by registry during registration: serviceManager()
    // We made it public state variable above, so getter is implicit
    // function serviceManager() external view returns (IAIOracleServiceManager) { return _serviceManager; }
    
    // Function required by registry during registration: modelType()
    // We made it public state variable above, so getter is implicit
    // function modelType() external view returns (string memory) { return _modelType; }

    // Function required by registry during registration: modelVersion()
    // We made it public state variable above, so getter is implicit
    // function modelVersion() external view returns (string memory) { return _modelVersion; }
}


contract AIAgentRegistryTest is Test {
    AIAgentRegistry public registry;
    MockAgent public mockAgent;
    MockOracleServiceManager public oracleMock; // Need an address for agent's service manager
    address public owner;
    address public otherUser;
    address public agentAddress;

    function setUp() public {
        owner = address(this); // Deployer is owner
        otherUser = address(0x123);
        oracleMock = new MockOracleServiceManager(); // Create a mock oracle

        registry = new AIAgentRegistry(); // Owner is msg.sender (this)

        // Deploy the simplified mock agent
        mockAgent = new MockAgent(address(oracleMock), "MockModel", "v0.1");
        agentAddress = address(mockAgent);

        // No need to initialize separately or call mockInitialize

    }

    // --- Test Functions Will Go Here ---

    // --- Registration Tests ---

    function test_RegisterAgent_Success() public {
        assertTrue(!registry.isRegistered(agentAddress), "Agent should not be registered initially");
        vm.prank(owner);
        registry.registerAgent(agentAddress);
        assertTrue(registry.isRegistered(agentAddress), "Agent should be registered");
        assertEq(registry.getAgentCount(), 1, "Agent count should be 1");
        address[] memory agents = registry.getAllAgents();
        assertEq(agents.length, 1, "Agents array length should be 1");
        assertEq(agents[0], agentAddress, "Agent address mismatch in array");

        // Check metadata storage (expecting 5 values)
        (string memory modelType, string memory modelVersion, uint256 tasks, uint256 consensus, uint256 rewards) = registry.getAgentDetails(agentAddress);
        assertEq(modelType, "MockModel", "Model type mismatch");
        assertEq(modelVersion, "v0.1", "Model version mismatch");
    }

    function test_RegisterAgent_Fail_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, otherUser));
        vm.prank(otherUser);
        registry.registerAgent(agentAddress);
    }

    function test_RegisterAgent_Fail_AlreadyRegistered() public {
        vm.prank(owner);
        registry.registerAgent(agentAddress); // First registration

        vm.expectRevert(bytes("Agent already registered"));
        vm.prank(owner);
        registry.registerAgent(agentAddress); // Second registration attempt
    }

    function test_RegisterAgent_Fail_ZeroAddress() public {
        vm.expectRevert(bytes("Invalid agent address"));
        vm.prank(owner);
        registry.registerAgent(address(0));
    }

    function test_RegisterAgent_Fail_NoServiceManagerSet() public {
        // Deploy a new mock agent that hasn't been initialized
        MockAgent newAgent = new MockAgent(address(0), "", "");
        // Skip newAgent.mockInitialize(...)

        vm.expectRevert(bytes("Agent service manager not set"));
        vm.prank(owner);
        registry.registerAgent(address(newAgent));
    }

    // --- Unregistration Tests ---

    function test_UnregisterAgent_Success() public {
        vm.prank(owner);
        registry.registerAgent(agentAddress); // Register first
        assertTrue(registry.isRegistered(agentAddress), "Agent should be registered before unregister");
        assertEq(registry.getAgentCount(), 1, "Count should be 1 before unregister");

        vm.prank(owner);
        registry.unregisterAgent(agentAddress);
        assertTrue(!registry.isRegistered(agentAddress), "Agent should not be registered after unregister");
        assertEq(registry.getAgentCount(), 0, "Agent count should be 0 after unregister");
        address[] memory agents = registry.getAllAgents();
        assertEq(agents.length, 0, "Agents array length should be 0 after unregister");
    }

    function test_UnregisterAgent_Fail_NotOwner() public {
        vm.prank(owner);
        registry.registerAgent(agentAddress); // Register first

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, otherUser));
        vm.prank(otherUser);
        registry.unregisterAgent(agentAddress);
    }

    function test_UnregisterAgent_Fail_NotRegistered() public {
        // Agent is not registered in setUp for this test
        vm.expectRevert(bytes("Agent not registered"));
        vm.prank(owner);
        registry.unregisterAgent(agentAddress);
    }

    // --- Status Update Tests ---

    function test_UpdateAgentStatus_Success() public {
        vm.prank(owner);
        registry.registerAgent(agentAddress); // Register first

        vm.prank(owner);
        registry.updateAgentStatus(agentAddress, AIAgent.AgentStatus.Suspended);

        assertEq(uint8(mockAgent.status()), uint8(AIAgent.AgentStatus.Suspended), "Updated status should be Suspended");
    }

    function test_UpdateAgentStatus_Fail_NotOwner() public {
        vm.prank(owner);
        registry.registerAgent(agentAddress); // Register first

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, otherUser));
        vm.prank(otherUser);
        registry.updateAgentStatus(agentAddress, AIAgent.AgentStatus.Inactive);
    }

    function test_UpdateAgentStatus_Fail_NotRegistered() public {
        vm.expectRevert(bytes("Agent not registered"));
        vm.prank(owner);
        registry.updateAgentStatus(agentAddress, AIAgent.AgentStatus.Suspended);
    }

    // --- Stats Update Tests ---

    function test_UpdateAgentStats_Success() public {
        vm.prank(owner);
        registry.registerAgent(agentAddress);

        // Check initial stats (should be 0) (expecting 5 values)
        (,, uint256 initialTasks, uint256 initialConsensus, uint256 initialRewards) = registry.getAgentDetails(agentAddress);
        assertEq(initialTasks, 0, "Initial tasks completed should be 0");
        assertEq(initialConsensus, 0, "Initial consensus participations should be 0");
        assertEq(initialRewards, 0, "Initial rewards earned should be 0");

        // Update stats (anyone can call this)
        vm.prank(otherUser); // Call from another user to test access
        registry.updateAgentStats(agentAddress);

        // Check updated stats (should match MockAgent return values) (expecting 5 values)
        (,, uint256 updatedTasks, uint256 updatedConsensus, uint256 updatedRewards) = registry.getAgentDetails(agentAddress);
        assertEq(updatedTasks, 10, "Updated tasks completed mismatch");
        assertEq(updatedConsensus, 5, "Updated consensus participations mismatch");
        assertEq(updatedRewards, 500 ether, "Updated rewards earned mismatch");
    }

    function test_UpdateAgentStats_Fail_NotRegistered() public {
        vm.expectRevert(bytes("Agent not registered"));
        registry.updateAgentStats(agentAddress);
    }

    // --- View Function Tests ---

    function test_GetAllAgents_Empty() public {
        address[] memory agents = registry.getAllAgents();
        assertEq(agents.length, 0, "Should return empty array initially");
    }

     function test_GetAllAgents_Multiple() public {
        MockAgent agent2 = new MockAgent(address(oracleMock), "Model2", "v0.2");
        MockAgent agent3 = new MockAgent(address(oracleMock), "Model3", "v0.3");

        vm.prank(owner);
        registry.registerAgent(agentAddress);
        vm.prank(owner);
        registry.registerAgent(address(agent2));
        vm.prank(owner);
        registry.registerAgent(address(agent3));

        address[] memory agents = registry.getAllAgents();
        assertEq(agents.length, 3, "Should return 3 agents");
        // Check if addresses exist (order might vary, check presence)
        bool found1 = false; bool found2 = false; bool found3 = false;
        for (uint i = 0; i < agents.length; i++) {
            if (agents[i] == agentAddress) found1 = true;
            if (agents[i] == address(agent2)) found2 = true;
            if (agents[i] == address(agent3)) found3 = true;
        }
        assertTrue(found1 && found2 && found3, "All registered agents should be in the list");

        // Test unregister affects the list
        vm.prank(owner);
        registry.unregisterAgent(address(agent2));
        agents = registry.getAllAgents();
        assertEq(agents.length, 2, "Should return 2 agents after unregister");
         bool found1_after = false; bool found3_after = false; bool found2_after_gone = true;
         for (uint i = 0; i < agents.length; i++) {
            if (agents[i] == agentAddress) found1_after = true;
            if (agents[i] == address(agent3)) found3_after = true;
            if (agents[i] == address(agent2)) found2_after_gone = false; // Should not find agent2
        }
        assertTrue(found1_after && found3_after && found2_after_gone, "Agent list incorrect after unregister");
    }

    function test_GetAgentCount() public {
        assertEq(registry.getAgentCount(), 0, "Initial count should be 0");
        vm.prank(owner);
        registry.registerAgent(agentAddress);
        assertEq(registry.getAgentCount(), 1, "Count should be 1 after register");
        vm.prank(owner);
        registry.unregisterAgent(agentAddress);
        assertEq(registry.getAgentCount(), 0, "Count should be 0 after unregister");
    }

    function test_GetAgentDetails_Fail_NotRegistered() public {
        vm.expectRevert(bytes("Agent not registered"));
        registry.getAgentDetails(agentAddress);
    }

    function test_IsRegistered() public {
        assertFalse(registry.isRegistered(agentAddress), "Should not be registered initially");
        vm.prank(owner);
        registry.registerAgent(agentAddress);
        assertTrue(registry.isRegistered(agentAddress), "Should be registered after register");
        vm.prank(owner);
        registry.unregisterAgent(agentAddress);
        assertFalse(registry.isRegistered(agentAddress), "Should not be registered after unregister");
    }
} 