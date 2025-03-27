// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import {IAIOracleServiceManager} from "../interfaces/IAIOracleServiceManager.sol";
import {AIAgent} from "./AIAgent.sol";

/**
 * @title AIAgentRegistry
 * @dev Registry for AI agents participating in the oracle's consensus mechanism
 */
contract AIAgentRegistry is Ownable {
    // The AI Oracle service manager
    IAIOracleServiceManager public serviceManager;
    
    // Registered agents
    address[] public registeredAgents;
    mapping(address => bool) public isRegistered;
    
    // Agent metadata
    mapping(address => string) public agentModelTypes;
    mapping(address => string) public agentModelVersions;
    
    // Agent performance metrics
    mapping(address => uint256) public agentTasksCompleted;
    mapping(address => uint256) public agentConsensusParticipations;
    mapping(address => uint256) public agentRewardsEarned;
    
    // Events
    event AgentRegistered(address indexed agentAddress, string modelType, string modelVersion);
    event AgentUnregistered(address indexed agentAddress);
    event AgentStatusUpdated(address indexed agentAddress, AIAgent.AgentStatus status);
    
    /**
     * @dev Constructor
     * @param _serviceManager Address of the oracle service manager
     */
    constructor(address _serviceManager) Ownable(msg.sender) {
        serviceManager = IAIOracleServiceManager(_serviceManager);
    }
    
    /**
     * @dev Register a new AI agent
     * @param agent Address of the agent contract
     */
    function registerAgent(address agent) external onlyOwner {
        require(!isRegistered[agent], "Agent already registered");
        require(agent != address(0), "Invalid agent address");
        
        AIAgent aiAgent = AIAgent(agent);
        
        // Verify the agent is properly configured with the same service manager
        require(
            address(aiAgent.serviceManager()) == address(serviceManager),
            "Agent has incorrect service manager"
        );
        
        // Register the agent
        registeredAgents.push(agent);
        isRegistered[agent] = true;
        
        // Store agent metadata
        agentModelTypes[agent] = aiAgent.modelType();
        agentModelVersions[agent] = aiAgent.modelVersion();
        
        emit AgentRegistered(agent, aiAgent.modelType(), aiAgent.modelVersion());
    }
    
    /**
     * @dev Unregister an AI agent
     * @param agent Address of the agent contract to unregister
     */
    function unregisterAgent(address agent) external onlyOwner {
        require(isRegistered[agent], "Agent not registered");
        
        // Remove from registry
        isRegistered[agent] = false;
        
        // Remove from array (find and replace with last element, then pop)
        for (uint256 i = 0; i < registeredAgents.length; i++) {
            if (registeredAgents[i] == agent) {
                registeredAgents[i] = registeredAgents[registeredAgents.length - 1];
                registeredAgents.pop();
                break;
            }
        }
        
        emit AgentUnregistered(agent);
    }
    
    /**
     * @dev Update an agent's status
     * @param agent Address of the agent
     * @param status New status for the agent
     */
    function updateAgentStatus(address agent, AIAgent.AgentStatus status) external onlyOwner {
        require(isRegistered[agent], "Agent not registered");
        
        AIAgent(agent).setStatus(status);
        
        emit AgentStatusUpdated(agent, status);
    }
    
    /**
     * @dev Get all registered agents
     * @return Array of agent addresses
     */
    function getAllAgents() external view returns (address[] memory) {
        return registeredAgents;
    }
    
    /**
     * @dev Get count of registered agents
     * @return Number of registered agents
     */
    function getAgentCount() external view returns (uint256) {
        return registeredAgents.length;
    }
    
    /**
     * @dev Update agent statistics based on their contract data
     * @param agent Address of the agent to update
     */
    function updateAgentStats(address agent) external {
        require(isRegistered[agent], "Agent not registered");
        
        AIAgent aiAgent = AIAgent(agent);
        
        // Get updated stats from the agent
        (
            uint256 tasksCompleted,
            uint256 consensusParticipations,
            uint256 totalRewards,
        ) = aiAgent.getAgentStats();
        
        // Update registry records
        agentTasksCompleted[agent] = tasksCompleted;
        agentConsensusParticipations[agent] = consensusParticipations;
        agentRewardsEarned[agent] = totalRewards;
    }
    
    /**
     * @dev Get agent details
     * @param agent Address of the agent
     * @return modelType The agent's model type
     * @return modelVersion The agent's model version
     * @return tasksCompleted Number of tasks the agent has completed
     * @return consensusParticipations Number of times the agent participated in consensus
     * @return rewardsEarned Total rewards earned by the agent
     */
    function getAgentDetails(address agent) external view returns (
        string memory modelType,
        string memory modelVersion,
        uint256 tasksCompleted,
        uint256 consensusParticipations,
        uint256 rewardsEarned
    ) {
        require(isRegistered[agent], "Agent not registered");
        
        return (
            agentModelTypes[agent],
            agentModelVersions[agent],
            agentTasksCompleted[agent],
            agentConsensusParticipations[agent],
            agentRewardsEarned[agent]
        );
    }
} 