// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import {IAIOracleServiceManager} from "../interfaces/IAIOracleServiceManager.sol";
import {ECDSAUpgradeable} from "@openzeppelin-upgrades/contracts/utils/cryptography/ECDSAUpgradeable.sol";

/**
 * @title AIAgent
 * @dev Contract representing an AI agent that can participate in the oracle's consensus mechanism
 */
contract AIAgent is Ownable {
    using ECDSAUpgradeable for bytes32;
    
    // The AI Oracle service manager this agent works with
    IAIOracleServiceManager public serviceManager;
    
    // The agent's model type and version
    string public modelType;
    string public modelVersion;
    
    // The agent's status
    enum AgentStatus { Inactive, Active, Suspended }
    AgentStatus public status;
    
    // Agent stats
    uint256 public tasksCompleted;
    uint256 public consensusParticipations;
    uint256 public totalRewardsEarned;
    
    // Events
    event TaskProcessed(uint32 indexed taskIndex, bytes signature);
    event StatusChanged(AgentStatus oldStatus, AgentStatus newStatus);
    event RewardReceived(uint256 amount, uint32 taskIndex);
    
    /**
     * @dev Constructor
     * @param _serviceManager Address of the oracle service manager
     * @param _modelType The type of AI model used by this agent
     * @param _modelVersion The version of the AI model
     */
    constructor(
        address _serviceManager,
        string memory _modelType,
        string memory _modelVersion
    ) Ownable(msg.sender) {
        serviceManager = IAIOracleServiceManager(_serviceManager);
        modelType = _modelType;
        modelVersion = _modelVersion;
        status = AgentStatus.Active;
    }
    
    /**
     * @dev Set the agent's status
     * @param _status New status for the agent
     */
    function setStatus(AgentStatus _status) external onlyOwner {
        AgentStatus oldStatus = status;
        status = _status;
        emit StatusChanged(oldStatus, _status);
    }
    
    /**
     * @dev Update the agent's model information
     * @param _modelType New model type
     * @param _modelVersion New model version
     */
    function updateModelInfo(
        string memory _modelType,
        string memory _modelVersion
    ) external onlyOwner {
        modelType = _modelType;
        modelVersion = _modelVersion;
    }
    
    /**
     * @dev Process a task and submit the agent's response
     * @param task The task to process
     * @param taskIndex The task index in the service manager
     * @param signature The signature representing the agent's response
     */
    function processTask(
        IAIOracleServiceManager.Task calldata task,
        uint32 taskIndex,
        bytes memory signature
    ) external onlyOwner {
        require(status == AgentStatus.Active, "Agent is not active");
        
        // Submit the agent's response to the service manager
        serviceManager.respondToTask(task, taskIndex, signature);
        
        // Update agent stats
        tasksCompleted++;
        
        emit TaskProcessed(taskIndex, signature);
    }
    
    /**
     * @dev Record a reward received for consensus participation
     * @param amount The reward amount
     * @param taskIndex The task index this reward is for
     */
    function recordReward(uint256 amount, uint32 taskIndex) external onlyOwner {
        totalRewardsEarned += amount;
        consensusParticipations++;
        
        emit RewardReceived(amount, taskIndex);
    }
    
    /**
     * @dev Get statistics about this agent
     * @return _tasksCompleted Number of tasks completed
     * @return _consensusParticipations Number of times the agent participated in consensus
     * @return _totalRewards Total rewards earned
     * @return _currentStatus Current status of the agent
     */
    function getAgentStats() external view returns (
        uint256 _tasksCompleted,
        uint256 _consensusParticipations,
        uint256 _totalRewards,
        AgentStatus _currentStatus
    ) {
        return (
            tasksCompleted,
            consensusParticipations,
            totalRewardsEarned,
            status
        );
    }
} 