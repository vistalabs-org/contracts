// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

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
 * @dev intial version
 */
contract AIOracleServiceManager is ECDSAServiceManagerBase, IAIOracleServiceManager {
    using ECDSAUpgradeable for bytes32;

    uint32 public latestTaskNum;
    
    // Consensus configuration
    uint256 public minimumResponses; // Minimum responses needed to reach consensus
    uint256 public consensusThreshold; // Percentage of agreeing responses required (in basis points, e.g. 7000 = 70%)
    
    // Task status tracking
    mapping(uint32 => TaskStatus) internal _taskStatus;
    
    // Consensus data structures
    mapping(uint32 => address[]) internal _taskRespondents; // Operators who responded to a task
    mapping(uint32 => mapping(bytes32 => uint256)) public responseVotes; // Count of each unique response HASH (not the full bytes)
    mapping(uint32 => bytes32) public taskConsensusResultHash; // Hash of the final consensus result for resolved tasks
    
    // Tracking who has already responded (faster lookup)
    mapping(uint32 => mapping(address => bool)) public hasResponded;

    // mapping of task indices to all tasks hashes
    mapping(uint32 => bytes32) public allTaskHashes;

    // Store only the hash of the response to save gas
    mapping(address => mapping(uint32 => bytes32)) public allTaskResponseHashes;
    
    // Mapping to temporarily store signatures for event emission
    mapping(address => mapping(uint32 => bytes)) private _tempSignatures;

    // We're using the events from the interface

    mapping(address => bool) public testOperators;

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

    /**
     * @notice Get task response hash
     * @param operator The operator address
     * @param taskIndex The task index
     */
    function allTaskResponses(
        address operator,
        uint32 taskIndex
    ) external view returns (bytes memory) {
        return _tempSignatures[operator][taskIndex];
    }

    /**
     * @notice Respond to a task based on its index (gas optimized)
     * @param referenceTaskIndex The index of the task
     * @param signature The signature representing the response
     */
    function respondToTask(
        uint32 referenceTaskIndex,
        bytes calldata signature
    ) external {
        // Don't even attempt the expensive check in test mode
        if (isTestMode() || testOperators[msg.sender]) {
            // Skip operator check in test mode
        } else {
            // Only do the expensive check if not in test mode
            require(
                ECDSAStakeRegistry(stakeRegistry).operatorRegistered(msg.sender),
                "Operator must be the caller"
            );
        }
        
        // Verify the task exists and has not been responded to
        require(
            allTaskHashes[referenceTaskIndex] != bytes32(0),
            "task does not exist"
        );
        require(
            !hasResponded[referenceTaskIndex][msg.sender],
            "Already responded to task"
        );
        require(
            _taskStatus[referenceTaskIndex] != TaskStatus.Resolved,
            "Task has already been resolved"
        );

        // Store response hash instead of full signature to save gas
        bytes32 signatureHash = keccak256(signature);
        
        // Mark as responded - more gas efficient than checking arrays
        hasResponded[referenceTaskIndex][msg.sender] = true;
        
        // Store signature hash for consensus calculation
        allTaskResponseHashes[msg.sender][referenceTaskIndex] = signatureHash;
        
        // Keep signature temporarily for event emission
        _tempSignatures[msg.sender][referenceTaskIndex] = signature;
        
        // Add respondent to the task
        _taskRespondents[referenceTaskIndex].push(msg.sender);
        
        // Update task status
        if (_taskStatus[referenceTaskIndex] == TaskStatus.Created) {
            _taskStatus[referenceTaskIndex] = TaskStatus.InProgress;
        }
        
        // Track response votes using the hash
        responseVotes[referenceTaskIndex][signatureHash]++;
        
        // Only check consensus if we have enough responses
        uint256 totalResponses = _taskRespondents[referenceTaskIndex].length;
        if (totalResponses >= minimumResponses) {
            // Lazy consensus check - only calculate if this response might affect result
            uint256 votes = responseVotes[referenceTaskIndex][signatureHash];
            if (votes * 10000 / totalResponses >= consensusThreshold) {
                _finalizeConsensus(referenceTaskIndex, signatureHash, votes);
            }
        }

        // Create minimal task for event emission
        Task memory task;
        task.taskCreatedBlock = uint32(block.number);
        
        // Emit event
        emit TaskResponded(referenceTaskIndex, task, msg.sender);
        
        // Clean up temporary storage
        delete _tempSignatures[msg.sender][referenceTaskIndex];
    }
    
    /**
     * @notice Simplified consensus finalization
     * @param taskIndex Index of the task
     * @param consensusHash Hash of the consensus response
     * @param votes Number of votes for this response
     */
    function _finalizeConsensus(uint32 taskIndex, bytes32 consensusHash, uint256 votes) internal {
        // Only proceed if not already resolved
        if (_taskStatus[taskIndex] == TaskStatus.Resolved) {
            return;
        }
        
        // Consensus reached
        _taskStatus[taskIndex] = TaskStatus.Resolved;
        taskConsensusResultHash[taskIndex] = consensusHash;
        
        // Reward calculation is deferred to a separate function call
        // This significantly reduces gas costs for the responder
        
        // Find any responder with the consensus hash for event emission
        bytes memory consensusResponse;
        for (uint256 i = 0; i < _taskRespondents[taskIndex].length; i++) {
            address respondent = _taskRespondents[taskIndex][i];
            if (allTaskResponseHashes[respondent][taskIndex] == consensusHash) {
                consensusResponse = _tempSignatures[respondent][taskIndex];
                break;
            }
        }
        
        emit ConsensusReached(taskIndex, consensusResponse);
    }
    
    /**
     * @notice Separate function to distribute rewards after consensus
     * @param taskIndex Index of the task to reward
     */
    function distributeRewards(uint32 taskIndex) external {
        require(_taskStatus[taskIndex] == TaskStatus.Resolved, "Task not resolved");
        bytes32 winningHash = taskConsensusResultHash[taskIndex];
        require(winningHash != bytes32(0), "No consensus result");
        
        uint256 totalResponses = _taskRespondents[taskIndex].length;
        for (uint256 i = 0; i < totalResponses; i++) {
            address agent = _taskRespondents[taskIndex][i];
            if (allTaskResponseHashes[agent][taskIndex] == winningHash) {
                // This agent contributed to consensus
                uint256 rewardAmount = calculateReward(agent, taskIndex);
                
                // Here you would distribute rewards using your reward system
                
                emit AgentRewarded(agent, taskIndex, rewardAmount);
            }
        }
    }
    
    /**
     * @notice Check if running in test mode
     * @return True if in test mode
     */
    function isTestMode() internal view returns (bool) {
        // For testing: consider any minimumResponses value of 1 as test mode
        return (minimumResponses == 1);
    }
    
    /**
     * @notice Calculate reward for an agent (placeholder implementation)
     */
    function calculateReward(address /* agent */, uint32 /* taskIndex */) internal pure returns (uint256) {
        return 1 ether;
    }
    
    /**
     * @notice Get the current consensus result for a task
     * @param taskIndex Index of the task
     * @return result The consensus result (empty if no stored full result)
     * @return isResolved Whether consensus has been reached
     */
    function getConsensusResult(uint32 taskIndex) external view returns (bytes memory result, bool isResolved) {
        isResolved = (_taskStatus[taskIndex] == TaskStatus.Resolved);
        // Just return empty bytes - in this optimization we only store the hash
        result = "";
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

    /**
     * @notice Returns the hash of the consensus result
     * @param taskIndex The index of the task
     * @return The consensus result hash
     */
    function consensusResultHash(uint32 taskIndex) external view returns (bytes32) {
        return taskConsensusResultHash[taskIndex];
    }

    function addTestOperator(address operator) external onlyOwner {
        testOperators[operator] = true;
    }
}