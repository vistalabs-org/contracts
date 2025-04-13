// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AIAgentRegistry} from "../../src/oracle/AIAgentRegistry.sol";
import {AIAgent} from "../../src/oracle/AIAgent.sol";
import {IAIOracleServiceManager} from "../../src/interfaces/IAIOracleServiceManager.sol"; // Added for Agent interface
import {AIOracleServiceManager} from "../../src/oracle/AIOracleServiceManager.sol"; // Import real oracle
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol"; // Import Ownable for error selector
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol"; // For agent owner checks

contract AIAgentRegistryTest is Test {
    AIAgentRegistry public registry;
    AIAgent public agent;
    AIOracleServiceManager public oracle; // Use real oracle
    address public owner;
    address public otherUser;
    address public agentAddress;
    address public agentOwner;

    function setUp() public {
        owner = address(this); // Deployer is owner
        otherUser = address(0x123);
        agentOwner = address(0x456); // Assign a distinct owner for the agent

        registry = new AIAgentRegistry(); // Owner is msg.sender (this)

        // Deploy Real Oracle
        oracle = new AIOracleServiceManager(address(registry));
        // Initialize Oracle (owner = this, test params, dummy hook)
        oracle.initialize(owner, 1, 10000, address(0xbeef));

        // Deploy the real agent
        agent = new AIAgent();
        // Initialize the real agent (Agent Owner = agentOwner)
        agent.initialize(
            owner, // Agent Owner = Registry Owner for test simplicity
            address(oracle), // Use real oracle address
            "RealModel",
            "v1.0",
            "RealAgentNFT",
            "RAGENT"
        );
        agentAddress = address(agent);
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
        (string memory modelType, string memory modelVersion, uint256 tasks, uint256 consensus, uint256 rewards) =
            registry.getAgentDetails(agentAddress);
        assertEq(modelType, "RealModel", "Model type mismatch");
        assertEq(modelVersion, "v1.0", "Model version mismatch");
        assertEq(tasks, 0, "Initial tasks should be 0");
        assertEq(consensus, 0, "Initial consensus should be 0");
        assertEq(rewards, 0, "Initial rewards should be 0");
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
        // Deploy a new real agent but don't initialize it correctly (or pass address(0))
        AIAgent newAgent = new AIAgent();
        // Expect the initialize call itself to revert
        vm.expectRevert(bytes("Invalid service manager address"));
        // Initialize with address(0) for service manager - THIS call should revert
        newAgent.initialize(owner, address(0), "", "", "", "");

        // The registry.registerAgent call is not needed/reached for this test case
        // vm.prank(owner);
        // registry.registerAgent(address(newAgent));
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

        // Check initial status via agent directly
        (,,, AIAgent.AgentStatus initialStatus) = agent.getAgentStats();
        assertEq(uint8(initialStatus), uint8(AIAgent.AgentStatus.Active), "Initial status should be Active");

        // Call registry function (Registry owner calls)
        vm.prank(owner);
        registry.updateAgentStatus(agentAddress, AIAgent.AgentStatus.Suspended);

        // Check updated status via agent directly
        (,,, AIAgent.AgentStatus updatedStatus) = agent.getAgentStats();
        assertEq(uint8(updatedStatus), uint8(AIAgent.AgentStatus.Suspended), "Updated status should be Suspended");
    }

    function test_UpdateAgentStatus_Fail_NotOwner() public {
        vm.prank(owner);
        registry.registerAgent(agentAddress); // Register first

        // Expect revert from registry call (Ownable check)
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, otherUser));
        vm.prank(otherUser);
        registry.updateAgentStatus(agentAddress, AIAgent.AgentStatus.Inactive);
    }

    function test_UpdateAgentStatus_Fail_NotRegistered() public {
        // Expect revert from registry call (isRegistered check)
        vm.expectRevert(bytes("Agent not registered"));
        vm.prank(owner);
        registry.updateAgentStatus(agentAddress, AIAgent.AgentStatus.Suspended);
    }

    // --- Stats Update Tests ---

    function test_UpdateAgentStats_Success() public {
        vm.prank(owner);
        registry.registerAgent(agentAddress);

        // Check initial stats from registry (should be 0)
        (,, uint256 initialTasks, uint256 initialConsensus, uint256 initialRewards) =
            registry.getAgentDetails(agentAddress);
        assertEq(initialTasks, 0, "Initial tasks completed should be 0");
        assertEq(initialConsensus, 0, "Initial consensus participations should be 0");
        assertEq(initialRewards, 0, "Initial rewards earned should be 0");

        // Update stats (anyone can call this)
        vm.prank(otherUser); // Call from another user to test access
        registry.updateAgentStats(agentAddress);

        // Check updated stats (should still be 0 as agent hasn't done anything)
        (,, uint256 updatedTasks, uint256 updatedConsensus, uint256 updatedRewards) =
            registry.getAgentDetails(agentAddress);
        assertEq(updatedTasks, 0, "Updated tasks completed mismatch (should be 0)");
        assertEq(updatedConsensus, 0, "Updated consensus participations mismatch (should be 0)");
        assertEq(updatedRewards, 0, "Updated rewards earned mismatch (should be 0)");
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
        AIAgent agent2 = new AIAgent();
        agent2.initialize(owner, address(oracle), "Model2", "v0.2", "NFT2", "N2");
        AIAgent agent3 = new AIAgent();
        agent3.initialize(owner, address(oracle), "Model3", "v0.3", "NFT3", "N3");

        vm.prank(owner);
        registry.registerAgent(agentAddress);
        vm.prank(owner);
        registry.registerAgent(address(agent2));
        vm.prank(owner);
        registry.registerAgent(address(agent3));

        address[] memory agents = registry.getAllAgents();
        assertEq(agents.length, 3, "Should return 3 agents");
        // Check if addresses exist (order might vary, check presence)
        bool found1 = false;
        bool found2 = false;
        bool found3 = false;
        for (uint256 i = 0; i < agents.length; i++) {
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
        bool found1_after = false;
        bool found3_after = false;
        bool found2_after_gone = true;
        for (uint256 i = 0; i < agents.length; i++) {
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
