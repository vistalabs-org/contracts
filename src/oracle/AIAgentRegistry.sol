// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
// No longer need IAIOracleServiceManager interface here
// import {IAIOracleServiceManager} from "../interfaces/IAIOracleServiceManager.sol";
import {AIAgent} from "./AIAgent.sol";
import "../interfaces/IAIAgentRegistry.sol"; // Import the interface it implements

/**
 * @title AIAgentRegistry
 * @dev Registry for AI agents participating in the oracle's consensus mechanism.
 *      Oracle address is NOT stored here. Caller of registerAgent is responsible
 *      for ensuring the agent is configured for the correct Oracle.
 */
contract AIAgentRegistry is
    Ownable,
    IAIAgentRegistry // Implement the interface
{
    // The AI Oracle service manager address is NOT stored here anymore.
    // IAIOracleServiceManager public serviceManager;

    // Registered agents
    address[] public registeredAgents;
    mapping(address => bool) public override isRegistered; // Add override

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
     * @dev Constructor - No longer takes service manager address
     */
    constructor() Ownable(msg.sender) {
        // No need to set serviceManager here
    }

    // No longer need updateServiceManager
    /*
    function updateServiceManager(address _newServiceManager) external onlyOwner {
        require(_newServiceManager != address(0), "Invalid service manager address");
        serviceManager = IAIOracleServiceManager(_newServiceManager);
    }
    */

    /**
     * @dev Register a new AI agent
     * @param agent Address of the agent contract
     * @notice The check for matching serviceManager has been removed.
     *         The caller (Registry Owner) is responsible for ensuring the agent
     *         is configured correctly before registering.
     */
    function registerAgent(address agent) external onlyOwner {
        require(!isRegistered[agent], "Agent already registered");
        require(agent != address(0), "Invalid agent address");

        AIAgent aiAgent = AIAgent(agent);

        // REMOVED: Verification check against a stored serviceManager
        /*
        require(
            address(aiAgent.serviceManager()) == address(serviceManager),
            "Agent has incorrect service manager"
        );
        */

        // It's still good practice to check if the agent *has* a service manager set,
        // even if we don't know if it's the 'right' one.
        require(address(aiAgent.serviceManager()) != address(0), "Agent service manager not set");

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
        (uint256 tasksCompleted, uint256 consensusParticipations, uint256 totalRewards,) = aiAgent.getAgentStats();

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
    function getAgentDetails(address agent)
        external
        view
        returns (
            string memory modelType,
            string memory modelVersion,
            uint256 tasksCompleted,
            uint256 consensusParticipations,
            uint256 rewardsEarned
        )
    {
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
