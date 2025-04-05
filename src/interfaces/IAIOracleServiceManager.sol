// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/**
 * @title IAIOracleServiceManager Interface
 * @dev Defines the external functions and events for the AI Oracle Service Manager contract.
 *      This contract manages AI-driven tasks, consensus among agents, and integration with other systems like prediction markets.
 */
interface IAIOracleServiceManager {
    // --- Events ---

    /**
     * @dev Emitted when a new task is created.
     * @param taskIndex The unique index assigned to the new task.
     * @param task The details of the created task.
     */
    event NewTaskCreated(uint32 indexed taskIndex, Task task);

    /**
     * @dev Emitted when an operator (agent) responds to a task.
     * @param taskIndex The index of the task being responded to.
     * @param task Task details (may only contain block number in current implementation).
     * @param operator The address of the operator who responded.
     */
    event TaskResponded(uint32 indexed taskIndex, Task task, address operator);

    /**
     * @dev Emitted when consensus is reached for a task.
     * @param taskIndex The index of the task for which consensus was reached.
     * @param consensusResult The resulting consensus data (empty in optimized hash-only implementation).
     */
    event ConsensusReached(uint32 indexed taskIndex, bytes consensusResult);

    /**
     * @dev Emitted when a reward is distributed to an agent for participating in consensus.
     * @param agent The address of the agent receiving the reward.
     * @param taskIndex The index of the task for which the reward is given.
     * @param rewardAmount The amount of the reward.
     */
    event AgentRewarded(address indexed agent, uint32 indexed taskIndex, uint256 rewardAmount);

    /**
     * @dev Emitted when the oracle successfully resolves a linked prediction market.
     * @param taskIndex The index of the oracle task that triggered the resolution.
     * @param marketId The ID of the prediction market being resolved.
     * @param outcome The resolution outcome (true for YES, false for NO).
     */
    event MarketResolvedByOracle(uint32 indexed taskIndex, bytes32 indexed marketId, bool outcome);

    /**
     * @dev Emitted when the oracle fails to resolve a linked prediction market.
     * @param taskIndex The index of the oracle task that triggered the resolution attempt.
     * @param marketId The ID of the prediction market that failed to resolve.
     * @param reason A string describing the reason for failure.
     */
    event MarketResolutionFailed(uint32 indexed taskIndex, bytes32 indexed marketId, string reason);

    // --- Structs ---

    /**
     * @dev Represents a task within the oracle system.
     * @param name A descriptive name or prompt for the task.
     * @param taskCreatedBlock The block number when the task was created.
     */
    struct Task {
        string name;
        uint32 taskCreatedBlock;
    }

    // --- Enums ---

    /**
     * @dev Represents the possible states of a task.
     */
    enum TaskStatus {
        Created, // Task has been created but no responses yet.
        InProgress, // Task has received at least one response but consensus not yet reached.
        Resolved // Consensus has been reached for the task.

    }

    // --- View Functions ---

    /**
     * @notice Gets the index of the latest task created.
     * @return The index of the most recently created task.
     */
    function latestTaskNum() external view returns (uint32);

    /**
     * @notice Gets the minimum number of responses required to attempt consensus.
     * @return The minimum number of responses.
     */
    function minimumResponses() external view returns (uint256);

    /**
     * @notice Gets the consensus threshold percentage (in basis points).
     * @return The threshold (e.g., 7000 means 70%).
     */
    function consensusThreshold() external view returns (uint256);

    /**
     * @notice Gets the current status of a specific task.
     * @param taskIndex The index of the task.
     * @return The status of the task (Created, InProgress, Resolved).
     */
    function taskStatus(uint32 taskIndex) external view returns (TaskStatus);

    /**
     * @notice Gets the keccak256 hash of the details of a specific task.
     * @param taskIndex The index of the task.
     * @return The hash of the task details.
     */
    function allTaskHashes(uint32 taskIndex) external view returns (bytes32);

    /**
     * @notice Gets the response (signature) submitted by a specific operator for a task.
     * @dev Note: This might return empty bytes if the signature was temporary.
     * @param operator The address of the operator.
     * @param taskIndex The index of the task.
     * @return The response bytes submitted by the operator.
     */
    function allTaskResponses(address operator, uint32 taskIndex) external view returns (bytes memory);

    /**
     * @notice Gets the list of addresses of operators who have responded to a task.
     * @param taskIndex The index of the task.
     * @return An array of operator addresses.
     */
    function taskRespondents(uint32 taskIndex) external view returns (address[] memory);

    /**
     * @notice Gets the hash of the final consensus result for a resolved task.
     * @param taskIndex The index of the task.
     * @return The keccak256 hash of the consensus result (or zero if not resolved).
     */
    function consensusResultHash(uint32 taskIndex) external view returns (bytes32);

    /**
     * @notice Gets the address of the Prediction Market Hook contract integrated with this oracle.
     * @return The address of the hook contract.
     */
    function predictionMarketHook() external view returns (address);

    /**
     * @notice Gets the market ID associated with a specific oracle task (if any).
     * @param taskIndex The index of the oracle task.
     * @return The associated market ID (or zero bytes32 if none).
     */
    function getMarketIdForTask(uint32 taskIndex) external view returns (bytes32);

    /**
     * @notice Gets the specific hook address associated with a market resolution task.
     * @param taskIndex The index of the oracle task.
     * @return The address of the hook that initiated the task (or zero address if not a market task).
     */
    function getHookAddressForTask(uint32 taskIndex) external view returns (address);

    // --- State Changing Functions ---

    /**
     * @notice Creates a new generic task.
     * @param name The descriptive name or prompt for the task.
     * @return The details of the created task.
     */
    function createNewTask(string memory name) external returns (Task memory);

    /**
     * @notice Submits a response (signature) from an agent for a specific task.
     * @param referenceTaskIndex The index of the task to respond to.
     * @param signature The agent's response data (e.g., signed message or direct response bytes).
     */
    function respondToTask(uint32 referenceTaskIndex, bytes calldata signature) external;

    /**
     * @notice Gets the final consensus result and resolution status for a task.
     * @param taskIndex The index of the task.
     * @return result The consensus result bytes (empty in hash-only implementation).
     * @return isResolved True if consensus has been reached, false otherwise.
     */
    function getConsensusResult(uint32 taskIndex) external view returns (bytes memory result, bool isResolved);

    /**
     * @notice Updates the consensus parameters (minimum responses and threshold).
     * @dev Can only be called by the contract owner.
     * @param _minimumResponses The new minimum number of responses required.
     * @param _consensusThreshold The new consensus threshold in basis points (0-10000).
     */
    function updateConsensusParameters(uint256 _minimumResponses, uint256 _consensusThreshold) external;

    /**
     * @notice Triggers the distribution of rewards for a completed task.
     * @dev Implementation details of reward calculation and distribution are within the contract.
     * @param taskIndex The index of the resolved task for which to distribute rewards.
     */
    function distributeRewards(uint32 taskIndex) external;

    /**
     * @notice Adds an address to the list of test operators (for bypassing registry checks in test environments).
     * @dev Can only be called by the contract owner.
     * @param operator The address of the operator to add.
     */
    function addTestOperator(address operator) external;

    /**
     * @notice Creates a specialized task specifically for resolving a prediction market.
     * @param name The descriptive name for the resolution task.
     * @param marketId The ID of the market to be resolved.
     * @param hookAddress The address of the Prediction Market Hook contract requesting resolution.
     * @return taskIndex The index of the created oracle task.
     */
    function createMarketResolutionTask(string memory name, bytes32 marketId, address hookAddress)
        external
        returns (uint32 taskIndex);

    /**
     * @notice Gets the full task details (name and creation block) for a given index.
     * @dev Relies on the task details being stored on-chain.
     * @param taskIndex The index of the task.
     * @return Task struct containing task details.
     */
    function getTask(uint32 taskIndex) external view returns (Task memory);
}
