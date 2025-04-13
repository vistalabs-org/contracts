// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAIOracleServiceManager} from "../interfaces/IAIOracleServiceManager.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title AIAgent
 * @dev Contract representing an AI agent that can participate in the oracle's consensus mechanism
 *      Is upgradeable and Ownable.
 */
contract AIAgent is Initializable, ERC721Upgradeable, OwnableUpgradeable {
    // The AI Oracle service manager this agent works with
    IAIOracleServiceManager public serviceManager;

    // The agent's model type and version
    string public modelType;
    string public modelVersion;

    // The agent's status
    enum AgentStatus {
        Inactive,
        Active,
        Suspended
    }

    AgentStatus public status;

    // Agent stats
    uint256 public tasksCompleted;
    uint256 public consensusParticipations;
    uint256 public totalRewardsEarned;

    // Events
    event TaskProcessed(uint32 indexed taskIndex, bool decision);
    event StatusChanged(AgentStatus oldStatus, AgentStatus newStatus);
    event RewardReceived(uint256 amount, uint32 taskIndex);

    /**
     * @dev Initializes the contract.
     * @param initialOwner The initial owner of the contract.
     * @param _serviceManager Address of the oracle service manager.
     * @param _modelType The type of AI model used by this agent.
     * @param _modelVersion The version of the AI model.
     * @param _name The name for the ERC721 token.
     * @param _symbol The symbol for the ERC721 token.
     */
    function initialize(
        address initialOwner,
        address _serviceManager,
        string memory _modelType,
        string memory _modelVersion,
        string memory _name,
        string memory _symbol
    ) external initializer {
        __ERC721_init(_name, _symbol);
        __Ownable_init(initialOwner);

        require(_serviceManager != address(0), "Invalid service manager address");
        serviceManager = IAIOracleServiceManager(_serviceManager);
        modelType = _modelType;
        modelVersion = _modelVersion;
        status = AgentStatus.Active;
    }

    /**
     * @dev Set the agent's status
     * @param _status New status for the agent
     */
    function setStatus(AgentStatus _status) external virtual {
        AgentStatus oldStatus = status;
        status = _status;
        emit StatusChanged(oldStatus, _status);
    }

    /**
     * @dev Update the agent's model information
     * @param _modelType New model type
     * @param _modelVersion New model version
     */
    function updateModelInfo(string memory _modelType, string memory _modelVersion) external onlyOwner {
        modelType = _modelType;
        modelVersion = _modelVersion;
    }

    /**
     * @dev Process a task and submit the agent's response
     * @param taskIndex The task index in the service manager
     * @param decision The agent's boolean decision (true for YES, false for NO)
     */
    function processTask(uint32 taskIndex, bool decision) external {
        require(status == AgentStatus.Active, "Agent is not active");

        // Get the task from the manager by index (optional check, Oracle Manager also checks)
        bytes32 taskHash = serviceManager.allTaskHashes(taskIndex);
        require(taskHash != bytes32(0), "Task does not exist");

        // Convert boolean decision to bytes ("YES" or "NO")
        bytes memory responseData;
        if (decision) {
            responseData = bytes("YES");
        } else {
            responseData = bytes("NO");
        }

        // Submit the agent's response data to the service manager
        serviceManager.respondToTask(taskIndex, responseData);

        // Update agent stats
        tasksCompleted++;

        emit TaskProcessed(taskIndex, decision);
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
    function getAgentStats()
        external
        view
        virtual
        returns (
            uint256 _tasksCompleted,
            uint256 _consensusParticipations,
            uint256 _totalRewards,
            AgentStatus _currentStatus
        )
    {
        return (tasksCompleted, consensusParticipations, totalRewardsEarned, status);
    }
}
