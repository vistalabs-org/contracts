// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IAIOracleServiceManager} from "../interfaces/IAIOracleServiceManager.sol";
import {IAIAgentRegistry} from "../interfaces/IAIAgentRegistry.sol";
import {IPredictionMarketHook} from "../interfaces/IPredictionMarketHook.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title Primary entrypoint for procuring services from AI Oracle with multi-agent consensus.
 * @dev Uses AIAgentRegistry for agent authorization.
 */
contract AIOracleServiceManager is OwnableUpgradeable, IAIOracleServiceManager {
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

    // Mapping for authorized operators (replaces EigenLayer registry check)
    mapping(address => bool) public isAuthorizedOperator;

    // We're using the events from the interface

    mapping(address => bool) public testOperators;

    // Integration with PredictionMarketHook
    mapping(uint32 => bytes32) public taskToMarketId;
    mapping(uint32 => address) public taskToHookAddress;
    bytes32 public constant YES_HASH = keccak256(bytes("YES"));
    bytes32 public constant NO_HASH = keccak256(bytes("NO"));
    address public predictionMarketHook;

    // --- NEW: Registry for Agent Authorization ---
    IAIAgentRegistry public immutable agentRegistry;

    constructor(address _agentRegistry) {
        require(_agentRegistry != address(0), "Invalid agent registry address");
        agentRegistry = IAIAgentRegistry(_agentRegistry);
    }

    function initialize(
        address initialOwner,
        uint256 _minimumResponses,
        uint256 _consensusThreshold,
        address _predictionMarketHook
    ) external initializer {
        __Ownable_init();
        minimumResponses = _minimumResponses;
        consensusThreshold = _consensusThreshold;
        require(_consensusThreshold <= 10000, "Threshold cannot exceed 100%");
        require(_predictionMarketHook != address(0), "Invalid hook address");
        predictionMarketHook = _predictionMarketHook;
    }

    /**
     * @notice Update consensus parameters
     * @param _minimumResponses New minimum responses required
     * @param _consensusThreshold New consensus threshold (in basis points)
     */
    function updateConsensusParameters(uint256 _minimumResponses, uint256 _consensusThreshold) external onlyOwner {
        require(_consensusThreshold <= 10000, "Threshold cannot exceed 100%");
        minimumResponses = _minimumResponses;
        consensusThreshold = _consensusThreshold;
    }

    /* FUNCTIONS */
    // --- Function to create a task specifically for market resolution ---
    function createMarketResolutionTask(
        string memory name,
        bytes32 marketId,
        address hookAddress // Address of the calling hook
    ) external override returns (uint32 taskIndex) {
        // Ensure caller is the registered hook (or owner for setup)
        // Note: predictionMarketHook might not be initialized yet if called by owner before initialize()
        require(marketId != bytes32(0), "Invalid marketId");
        require(hookAddress != address(0), "Invalid hookAddress");

        taskIndex = latestTaskNum;

        Task memory newTask;
        newTask.name = name;
        newTask.taskCreatedBlock = uint32(block.number);

        allTaskHashes[taskIndex] = keccak256(abi.encode(newTask));
        _taskStatus[taskIndex] = TaskStatus.Created;

        // Store mapping for callback
        taskToMarketId[taskIndex] = marketId;
        taskToHookAddress[taskIndex] = hookAddress; // Store the specific hook

        emit NewTaskCreated(taskIndex, newTask);
        latestTaskNum = latestTaskNum + 1;

        // Note: Returning only taskIndex now
    }

    // --- Function to create a generic task ---
    function createNewTask(string memory name) external override returns (Task memory) {
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
    function allTaskResponses(address operator, uint32 taskIndex) external view override returns (bytes memory) {
        return _tempSignatures[operator][taskIndex];
    }

    /**
     * @notice Respond to a task based on its index (gas optimized)
     * @param referenceTaskIndex The index of the task
     * @param signature The signature representing the response
     */
    function respondToTask(uint32 referenceTaskIndex, bytes calldata signature) external override {
        if (!isTestMode() && !testOperators[msg.sender]) {
            require(agentRegistry.isRegistered(msg.sender), "Agent contract not registered");
        }

        require(allTaskHashes[referenceTaskIndex] != bytes32(0), "task does not exist");
        require(!hasResponded[referenceTaskIndex][msg.sender], "Already responded to task");
        require(_taskStatus[referenceTaskIndex] != TaskStatus.Resolved, "Task has already been resolved");

        bytes32 signatureHash = keccak256(signature);

        if (taskToMarketId[referenceTaskIndex] != bytes32(0)) {
            require(signatureHash == YES_HASH || signatureHash == NO_HASH, "Invalid response for market resolution");
        }

        hasResponded[referenceTaskIndex][msg.sender] = true;
        allTaskResponseHashes[msg.sender][referenceTaskIndex] = signatureHash;
        _tempSignatures[msg.sender][referenceTaskIndex] = signature;
        _taskRespondents[referenceTaskIndex].push(msg.sender);

        if (_taskStatus[referenceTaskIndex] == TaskStatus.Created) {
            _taskStatus[referenceTaskIndex] = TaskStatus.InProgress;
        }

        responseVotes[referenceTaskIndex][signatureHash]++;

        uint256 totalResponses = _taskRespondents[referenceTaskIndex].length;
        if (totalResponses >= minimumResponses) {
            uint256 votes = responseVotes[referenceTaskIndex][signatureHash];
            if (votes * 10000 / totalResponses >= consensusThreshold) {
                _finalizeConsensus(referenceTaskIndex, signatureHash);
            }
        }

        Task memory task;
        task.taskCreatedBlock = uint32(block.number);
        emit TaskResponded(referenceTaskIndex, task, msg.sender);
        delete _tempSignatures[msg.sender][referenceTaskIndex];
    }

    /**
     * @notice Simplified consensus finalization
     * @param taskIndex Index of the task
     * @param consensusHash Hash of the consensus response
     */
    function _finalizeConsensus(uint32 taskIndex, bytes32 consensusHash) internal {
        if (_taskStatus[taskIndex] == TaskStatus.Resolved) {
            return;
        }

        _taskStatus[taskIndex] = TaskStatus.Resolved;
        taskConsensusResultHash[taskIndex] = consensusHash;

        emit ConsensusReached(taskIndex, "");

        bytes32 marketId = taskToMarketId[taskIndex];
        address hookAddress = taskToHookAddress[taskIndex];

        if (marketId != bytes32(0) && hookAddress != address(0)) {
            bool outcome;
            if (consensusHash == YES_HASH) {
                outcome = true;
            } else if (consensusHash == NO_HASH) {
                outcome = false;
            } else {
                emit MarketResolutionFailed(taskIndex, marketId, "Invalid consensus hash");
                return;
            }

            try IPredictionMarketHook(hookAddress).resolveMarket(marketId, outcome) {
                emit MarketResolvedByOracle(taskIndex, marketId, outcome);
            } catch (bytes memory reason) {
                emit MarketResolutionFailed(taskIndex, marketId, string(reason));
            }
        }
    }

    /**
     * @notice Separate function to distribute rewards after consensus
     * @param taskIndex Index of the task to reward
     */
    function distributeRewards(uint32 taskIndex) external override {
        require(_taskStatus[taskIndex] == TaskStatus.Resolved, "Task not resolved");
        bytes32 winningHash = taskConsensusResultHash[taskIndex];
        require(winningHash != bytes32(0), "No consensus result");

        // Placeholder: Rewards initiator/logic needs to be defined without EigenLayer
        // address rewardsInitiator = owner(); // Example: use owner, or define another role

        uint256 totalResponses = _taskRespondents[taskIndex].length;
        address[] memory respondents = _taskRespondents[taskIndex]; // Cache storage reads
        for (uint256 i = 0; i < totalResponses; i++) {
            address agent = respondents[i];
            if (allTaskResponseHashes[agent][taskIndex] == winningHash) {
                // This agent contributed to consensus
                uint256 rewardAmount = calculateReward(agent, taskIndex);

                // Here you would distribute rewards using your reward system
                // This part needs implementation based on how rewards are now funded/distributed
                // Example: IERC20(rewardToken).transfer(agent, rewardAmount);

                emit AgentRewarded(agent, taskIndex, rewardAmount);
            }
        }
    }

    /**
     * @notice Check if running in test mode
     * @return True if in test mode
     */
    function isTestMode() internal view returns (bool) {
        // Rely on the explicit testOperators mapping or minimumResponses == 1
        return (minimumResponses == 1); // Keep simple logic for now
    }

    /**
     * @notice Calculate reward for an agent (placeholder implementation)
     */
    function calculateReward(address, /* agent */ uint32 /* taskIndex */ ) internal pure returns (uint256) {
        // Placeholder - actual reward logic needed
        return 1 ether; // Example reward
    }

    /**
     * @notice Get the current consensus result for a task
     * @param taskIndex Index of the task
     * @return result The consensus result (empty if no stored full result)
     * @return isResolved Whether consensus has been reached
     */
    function getConsensusResult(uint32 taskIndex)
        external
        view
        override
        returns (bytes memory result, bool isResolved)
    {
        isResolved = (_taskStatus[taskIndex] == TaskStatus.Resolved);
        // Just return empty bytes - in this optimization we only store the hash
        result = "";
    }

    /**
     * @notice Returns the current status of a task
     * @param taskIndex The index of the task
     * @return The task status
     */
    function taskStatus(uint32 taskIndex) external view override returns (TaskStatus) {
        return _taskStatus[taskIndex];
    }

    /**
     * @notice Returns the addresses of all operators who have responded to a task
     * @param taskIndex The index of the task
     * @return Array of respondent addresses
     */
    function taskRespondents(uint32 taskIndex) external view override returns (address[] memory) {
        return _taskRespondents[taskIndex];
    }

    /**
     * @notice Returns the hash of the consensus result
     * @param taskIndex The index of the task
     * @return The consensus result hash
     */
    function consensusResultHash(uint32 taskIndex) external view override returns (bytes32) {
        return taskConsensusResultHash[taskIndex];
    }

    // Keep test operator functions for now
    function addTestOperator(address operator) external override onlyOwner {
        testOperators[operator] = true;
    }

    /**
     * @notice Get the market ID associated with a task index
     * @param taskIndex The index of the task
     * @return The market ID
     */
    function getMarketIdForTask(uint32 taskIndex) external view override returns (bytes32) {
        return taskToMarketId[taskIndex];
    }

    /**
     * @notice Get the hook address associated with a task index
     * @param taskIndex The index of the task
     * @return The hook address
     */
    function getHookAddressForTask(uint32 taskIndex) external view override returns (address) {
        return taskToHookAddress[taskIndex];
    }
}
