// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {ECDSAServiceManagerBase} from "@eigenlayer-middleware/src/unaudited/ECDSAServiceManagerBase.sol";
import {ECDSAStakeRegistry} from "@eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
import {IServiceManager} from "@eigenlayer-middleware/src/interfaces/IServiceManager.sol";
import {ECDSAUpgradeable} from "@openzeppelin-upgrades/contracts/utils/cryptography/ECDSAUpgradeable.sol";
import {IERC1271Upgradeable} from "@openzeppelin-upgrades/contracts/interfaces/IERC1271Upgradeable.sol";
import {IAIOracleServiceManager} from "../interfaces/IAIOracleServiceManager.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title Primary entrypoint for procuring services from AI Oracle with multi-agent consensus.
 *
 */
contract AIOracleServiceManager is ECDSAServiceManagerBase, IAIOracleServiceManager {
    using ECDSAUpgradeable for bytes32;

    uint32 public latestTaskNum;
    
    // Consensus configuration
    uint256 public minimumResponses; // Minimum responses needed to reach consensus
    uint256 public consensusThreshold; // Percentage of agreeing responses required (in basis points, e.g. 7000 = 70%)
    
    // Task status tracking
    // Using the TaskStatus enum from the interface
    mapping(uint32 => TaskStatus) internal _taskStatus;
    
    // Consensus data structures
    mapping(uint32 => address[]) internal _taskRespondents; // Operators who responded to a task
    mapping(uint32 => mapping(bytes => uint256)) public responseVotes; // Count of each unique response
    mapping(uint32 => bytes) public consensusResult; // The final consensus result for resolved tasks

    // mapping of task indices to all tasks hashes
    // when a task is created, task hash is stored here,
    // and responses need to pass the actual task,
    // which is hashed onchain and checked against this mapping
    mapping(uint32 => bytes32) public allTaskHashes;

    // mapping of task indices to hash of abi.encode(taskResponse, taskResponseMetadata)
    mapping(address => mapping(uint32 => bytes)) public allTaskResponses;

    // We're using the events from the interface

    modifier onlyOperator() {
        require(
            ECDSAStakeRegistry(stakeRegistry).operatorRegistered(msg.sender),
            "Operator must be the caller"
        );
        _;
    }

    constructor(
        address _avsDirectory,
        address _stakeRegistry,
        address _rewardsCoordinator,
        address _delegationManager,
        address _allocationManager
    )
        ECDSAServiceManagerBase(
            _avsDirectory,
            _stakeRegistry,
            _rewardsCoordinator,
            _delegationManager,
            _allocationManager
        )
    {}

    function initialize(
        address initialOwner, 
        address _rewardsInitiator, 
        uint256 _minimumResponses, 
        uint256 _consensusThreshold
    ) external initializer {
        __ServiceManagerBase_init(initialOwner, _rewardsInitiator);
        
        // Configure consensus parameters
        minimumResponses = _minimumResponses;
        consensusThreshold = _consensusThreshold;
    }

    // These are just to comply with IServiceManager interface
    function addPendingAdmin(
        address admin
    ) external onlyOwner {}

    function removePendingAdmin(
        address pendingAdmin
    ) external onlyOwner {}

    function removeAdmin(
        address admin
    ) external onlyOwner {}

    function setAppointee(address appointee, address target, bytes4 selector) external onlyOwner {}

    function removeAppointee(
        address appointee,
        address target,
        bytes4 selector
    ) external onlyOwner {}

    function deregisterOperatorFromOperatorSets(
        address operator,
        uint32[] memory operatorSetIds
    ) external {
        // unused
    }

    /**
     * @notice Update consensus parameters
     * @param _minimumResponses New minimum responses required
     * @param _consensusThreshold New consensus threshold (in basis points)
     */
    function updateConsensusParameters(
        uint256 _minimumResponses,
        uint256 _consensusThreshold
    ) external onlyOwner {
        require(_consensusThreshold <= 10000, "Threshold cannot exceed 100%");
        minimumResponses = _minimumResponses;
        consensusThreshold = _consensusThreshold;
    }

    /* FUNCTIONS */
    // NOTE: this function creates new task, assigns it a taskId
    // NOTE: at market creation we need to create a task and store the taskId in the market
    function createNewTask(
        string memory name
    ) external returns (Task memory) {
        // create a new task struct
        Task memory newTask;
        newTask.name = name;
        newTask.taskCreatedBlock = uint32(block.number);

        // store hash of task onchain, emit event, and increase taskNum
        allTaskHashes[latestTaskNum] = keccak256(abi.encode(newTask));
        
        // Set initial task status
        _taskStatus[latestTaskNum] = TaskStatus.Created;
        
        emit NewTaskCreated(latestTaskNum, newTask);
        latestTaskNum = latestTaskNum + 1;

        return newTask;
    }

    function respondToTask(
        Task calldata task,
        uint32 referenceTaskIndex,
        bytes memory signature
    ) external onlyOperator {
        // check that the task is valid, hasn't been responsed yet, and is being responded in time
        require(
            keccak256(abi.encode(task)) == allTaskHashes[referenceTaskIndex],
            "supplied task does not match the one recorded in the contract"
        );
        require(
            allTaskResponses[msg.sender][referenceTaskIndex].length == 0,
            "Operator has already responded to the task"
        );
        require(
            _taskStatus[referenceTaskIndex] != TaskStatus.Resolved,
            "Task has already been resolved"
        );

        // The message that was signed
        bytes32 messageHash = keccak256(abi.encodePacked("Hello, ", task.name));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        bytes4 magicValue = IERC1271Upgradeable.isValidSignature.selector;
        bytes4 isValidSignatureResult =
            ECDSAStakeRegistry(stakeRegistry).isValidSignature(ethSignedMessageHash, signature);

        require(magicValue == isValidSignatureResult, "Invalid signature");

        // updating the storage with task responses
        allTaskResponses[msg.sender][referenceTaskIndex] = signature;
        
        // Add respondent to the task
        _taskRespondents[referenceTaskIndex].push(msg.sender);
        
        // Update task status
        if (_taskStatus[referenceTaskIndex] == TaskStatus.Created) {
            _taskStatus[referenceTaskIndex] = TaskStatus.InProgress;
        }
        
        // Track response for consensus calculations
        responseVotes[referenceTaskIndex][signature]++;
        
        // Check if consensus can be reached
        checkAndFinalizeConsensus(referenceTaskIndex);

        // emitting event
        emit TaskResponded(referenceTaskIndex, task, msg.sender);
    }
    
    /**
     * @notice Check if consensus has been reached and finalize the task if it has
     * @param taskIndex Index of the task to check
     */
    function checkAndFinalizeConsensus(uint32 taskIndex) internal {
        // Get total responses
        uint256 totalResponses = _taskRespondents[taskIndex].length;
        
        // Only proceed if we have enough responses
        if (totalResponses < minimumResponses) {
            return;
        }
        
        // Find the most common response
        bytes memory mostCommonResponse;
        uint256 highestVotes = 0;
        
        // Iterate through all respondents
        for (uint256 i = 0; i < totalResponses; i++) {
            address respondent = _taskRespondents[taskIndex][i];
            bytes memory response = allTaskResponses[respondent][taskIndex];
            
            uint256 votes = responseVotes[taskIndex][response];
            if (votes > highestVotes) {
                highestVotes = votes;
                mostCommonResponse = response;
            }
        }
        
        // Check if consensus threshold is met
        if (highestVotes * 10000 / totalResponses >= consensusThreshold) {
            // Consensus reached
            _taskStatus[taskIndex] = TaskStatus.Resolved;
            consensusResult[taskIndex] = mostCommonResponse;
            
            // Reward agents who provided the consensus answer
            rewardConsensusAgents(taskIndex, mostCommonResponse);
            
            emit ConsensusReached(taskIndex, mostCommonResponse);
        }
    }
    
    /**
     * @notice Reward agents who contributed to consensus
     * @param taskIndex Index of the task
     * @param consensusResponse The consensus response
     */
    function rewardConsensusAgents(uint32 taskIndex, bytes memory consensusResponse) internal {
        uint256 totalResponses = _taskRespondents[taskIndex].length;
        
        for (uint256 i = 0; i < totalResponses; i++) {
            address agent = _taskRespondents[taskIndex][i];
            bytes memory agentResponse = allTaskResponses[agent][taskIndex];
            
            // Compare responses (they are signatures in this case)
            if (keccak256(agentResponse) == keccak256(consensusResponse)) {
                // This agent contributed to consensus
                uint256 rewardAmount = calculateReward(agent, taskIndex);
                
                // Here you would distribute rewards using your reward system
                // This could involve minting tokens or transferring ETH
                
                emit AgentRewarded(agent, taskIndex, rewardAmount);
            }
        }
    }
    
    /**
     * @notice Calculate reward for an agent based on their stake and contribution
     * @dev Parameters are currently unused in this placeholder implementation
     * @return Reward amount
     */
    function calculateReward(address /* agent */, uint32 /* taskIndex */) internal pure returns (uint256) {
        // This is a placeholder implementation
        // In a real system, you might base this on stake amount, response time, etc.
        return 1 ether;
    }
    
    /**
     * @notice Get the current consensus result for a task
     * @param taskIndex Index of the task
     * @return result The consensus result
     * @return isResolved Whether consensus has been reached
     */
    function getConsensusResult(uint32 taskIndex) external view returns (bytes memory result, bool isResolved) {
        isResolved = (_taskStatus[taskIndex] == TaskStatus.Resolved);
        result = consensusResult[taskIndex];
    }
    
    /**
     * @notice Returns the current status of a task
     * @param taskIndex The index of the task
     * @return The task status
     */
    function taskStatus(uint32 taskIndex) external view returns (TaskStatus) {
        return _taskStatus[taskIndex];
    }
    
    /**
     * @notice Returns the addresses of all operators who have responded to a task
     * @param taskIndex The index of the task
     * @return Array of respondent addresses
     */
    function taskRespondents(uint32 taskIndex) external view returns (address[] memory) {
        return _taskRespondents[taskIndex];
    }
}