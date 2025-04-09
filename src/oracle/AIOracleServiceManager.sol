// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IAIOracleServiceManager} from "../interfaces/IAIOracleServiceManager.sol";
import {IAIAgentRegistry} from "../interfaces/IAIAgentRegistry.sol";
import {IPredictionMarketHook} from "../interfaces/IPredictionMarketHook.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title AIOracleServiceManager
 * @notice Manages AI-driven tasks, consensus mechanisms among registered agents,
 *         and optional integration with prediction markets.
 * @dev Inherits OwnableUpgradeable for ownership control and implements IAIOracleServiceManager.
 *      Uses IAIAgentRegistry to authorize responding agents.
 *      Includes an optional link to a PredictionMarketHook for resolving markets based on task outcomes.
 *      This contract is intended to be deployed behind a proxy (upgradeable).
 */
contract AIOracleServiceManager is OwnableUpgradeable, IAIOracleServiceManager {
    // --- State Variables ---

    /**
     * @dev Counter for the next task index. Increments each time a task is created.
     */
    uint32 public latestTaskNum;

    // --- Consensus Configuration ---
    /**
     * @dev Minimum number of responses required before attempting to finalize consensus.
     */
    uint256 public minimumResponses;
    /**
     * @dev Percentage of agreeing responses (out of total responses received) needed to reach consensus.
     *      Stored in basis points (e.g., 7000 for 70%).
     */
    uint256 public consensusThreshold;

    // --- Task Data Mappings ---
    /**
     * @dev Tracks the current status (Created, InProgress, Resolved) of each task.
     */
    mapping(uint32 => TaskStatus) internal _taskStatus;
    /**
     * @dev Stores the list of agent addresses that have responded to each task.
     */
    mapping(uint32 => address[]) internal _taskRespondents;
    /**
     * @dev Counts the occurrences of each unique response *hash* for a given task.
     *      Used to determine the winning response during consensus.
     */
    mapping(uint32 => mapping(bytes32 => uint256)) public responseVotes;
    /**
     * @dev Stores the hash of the final consensus result once a task is resolved.
     */
    mapping(uint32 => bytes32) public taskConsensusResultHash;
    /**
     * @dev Efficient lookup to check if a specific agent has already responded to a task.
     */
    mapping(uint32 => mapping(address => bool)) public hasResponded;
    /**
     * @dev Stores the keccak256 hash of the initial Task struct data for verification or reference.
     */
    mapping(uint32 => bytes32) public allTaskHashes;
    /**
     * @dev Stores the full Task struct (name, creation block) for retrieval via getTask.
     * @notice Increases gas cost for task creation compared to storing only the hash.
     */
    mapping(uint32 => Task) public allTasks;
    /**
     * @dev Stores the hash of the response submitted by each agent for each task.
     *      Used for reward distribution based on matching the consensus hash.
     */
    mapping(address => mapping(uint32 => bytes32)) public allTaskResponseHashes;
    /**
     * @dev Temporarily stores the full signature/response bytes for event emission in respondToTask.
     *      Cleared after the event is emitted.
     */
    mapping(address => mapping(uint32 => bytes)) private _tempSignatures;

    // --- Agent Authorization & Testing ---
    /**
     * @dev Mapping of operator addresses explicitly added for testing purposes.
     *      Operators in this mapping can bypass the agent registry check.
     */
    mapping(address => bool) public testOperators;
    /**
     * @dev Immutable reference to the AIAgentRegistry contract used to verify agent registration.
     */
    IAIAgentRegistry public immutable agentRegistry;

    // --- Prediction Market Integration (Optional) ---
    /**
     * @dev Maps an oracle task index to the ID of the prediction market it's intended to resolve.
     */
    mapping(uint32 => bytes32) public taskToMarketId;
    /**
     * @dev Maps an oracle task index to the address of the specific PredictionMarketHook that created the task.
     */
    mapping(uint32 => address) public taskToHookAddress;
    /**
     * @dev Precomputed hash for the "YES" response in market resolution tasks.
     */
    bytes32 public constant YES_HASH = keccak256(bytes("YES"));
    /**
     * @dev Precomputed hash for the "NO" response in market resolution tasks.
     */
    bytes32 public constant NO_HASH = keccak256(bytes("NO"));
    /**
     * @dev Address of the primary PredictionMarketHook contract (can be updated by owner).
     *      Used as a fallback or default if needed, though createMarketResolutionTask uses the specific hook address.
     */
    address public predictionMarketHook;

    // --- Constructor & Initializer ---

    /**
     * @dev Sets the immutable agent registry address during contract construction.
     * @param _agentRegistry The address of the deployed AIAgentRegistry contract.
     */
    constructor(address _agentRegistry) {
        require(_agentRegistry != address(0), "Invalid agent registry address");
        agentRegistry = IAIAgentRegistry(_agentRegistry);
    }

    /**
     * @dev Initializes the upgradeable contract, setting the owner, consensus parameters, and prediction market hook address.
     * @param initialOwner The address that will initially own the contract.
     * @param _minimumResponses The initial minimum number of responses required for consensus.
     * @param _consensusThreshold The initial consensus threshold percentage (basis points).
     * @param _predictionMarketHook The address of the associated PredictionMarketHook contract.
     */
    function initialize(
        address initialOwner,
        uint256 _minimumResponses,
        uint256 _consensusThreshold,
        address _predictionMarketHook
    ) external initializer {
        __Ownable_init(initialOwner);
        minimumResponses = _minimumResponses;
        consensusThreshold = _consensusThreshold;
        require(_consensusThreshold <= 10000, "Threshold cannot exceed 100%");
        require(_predictionMarketHook != address(0), "Invalid hook address");
        predictionMarketHook = _predictionMarketHook;
    }

    // --- Owner Functions ---

    /**
     * @notice Updates the consensus parameters.
     * @dev Can only be called by the owner.
     * @param _minimumResponses New minimum responses required (must be > 0).
     * @param _consensusThreshold New consensus threshold (in basis points, 0-10000).
     */
    function updateConsensusParameters(uint256 _minimumResponses, uint256 _consensusThreshold) external onlyOwner {
        require(_minimumResponses > 0, "Minimum responses must be positive");
        require(_consensusThreshold <= 10000, "Threshold cannot exceed 100%");
        minimumResponses = _minimumResponses;
        consensusThreshold = _consensusThreshold;
    }

    /**
     * @notice Adds an operator address to the list of test operators.
     * @dev Test operators bypass the agent registry check in `respondToTask`.
     *      Can only be called by the owner.
     * @param operator The address to add as a test operator.
     */
    function addTestOperator(address operator) external override onlyOwner {
        testOperators[operator] = true;
    }

    // --- Task Creation Functions ---

    /**
     * @notice Creates a task specifically intended to resolve a prediction market.
     * @dev Stores mappings between the task index and the market details for later resolution.
     *      Stores the full Task struct in `allTasks` mapping.
     * @param name A descriptive name for the task (e.g., "Resolve market: [Market Title]").
     * @param marketId The unique ID of the prediction market to resolve.
     * @param hookAddress The address of the specific PredictionMarketHook instance requesting resolution.
     * @return taskIndex The unique index assigned to this new oracle task.
     */
    function createMarketResolutionTask(
        string memory name,
        bytes32 marketId,
        address hookAddress // Address of the calling hook
    ) external override returns (uint32 taskIndex) {
        // Basic validation
        require(marketId != bytes32(0), "Invalid marketId");
        require(hookAddress != address(0), "Invalid hookAddress");
        // Consider adding require(msg.sender == hookAddress || msg.sender == owner(), "Unauthorized caller");

        // Assign next task index
        taskIndex = latestTaskNum;

        // Create and store task details
        Task memory newTask = Task(name, uint32(block.number));
        allTaskHashes[taskIndex] = keccak256(abi.encode(newTask));
        allTasks[taskIndex] = newTask; // Store full task
        _taskStatus[taskIndex] = TaskStatus.Created;

        // Store market resolution linkage
        taskToMarketId[taskIndex] = marketId;
        taskToHookAddress[taskIndex] = hookAddress;

        // Emit event and increment counter
        emit NewTaskCreated(taskIndex, newTask);
        latestTaskNum++; // Safe incrementation as uint32 is large
    }

    /**
     * @notice Creates a generic task not necessarily linked to a market.
     * @dev Stores the full Task struct in `allTasks` mapping.
     * @param name The descriptive name or prompt for the task.
     * @return newTask The details of the created task.
     */
    function createNewTask(string memory name) external override returns (Task memory newTask) {
        // Assign task index *before* creating struct to use latestTaskNum
        uint32 taskIndex = latestTaskNum;

        // Create and store task details
        newTask = Task(name, uint32(block.number));
        allTaskHashes[taskIndex] = keccak256(abi.encode(newTask));
        allTasks[taskIndex] = newTask; // Store full task
        _taskStatus[taskIndex] = TaskStatus.Created;

        // Emit event and increment counter
        emit NewTaskCreated(taskIndex, newTask);
        latestTaskNum++;
    }

    // --- Task Interaction Functions ---

    /**
     * @notice Allows a registered agent (or test operator) to submit a response to a task.
     * @dev Checks agent registration, task existence, status, and prevents double voting.
     *      Stores the response hash, updates vote counts, and potentially triggers consensus finalization.
     * @param referenceTaskIndex The index of the task to respond to.
     * @param signature The agent's response data (e.g., signed message hash or direct response like "YES"/"NO").
     */
    function respondToTask(uint32 referenceTaskIndex, bytes calldata signature) external override {
        // 1. Authorization Check: Ensure sender is a registered agent or a test operator
        // Bypass check if in test mode (min responses = 1) or sender is explicitly a test operator
        if (!isTestMode() && !testOperators[msg.sender]) {
            require(agentRegistry.isRegistered(msg.sender), "Agent contract not registered");
        }

        // 2. Task Validity Checks:
        require(allTaskHashes[referenceTaskIndex] != bytes32(0), "Task does not exist"); // Check if task was ever created using the hash mapping
        require(!hasResponded[referenceTaskIndex][msg.sender], "Already responded to task");
        require(_taskStatus[referenceTaskIndex] != TaskStatus.Resolved, "Task has already been resolved");

        // 3. Response Processing:
        bytes32 signatureHash = keccak256(signature);

        // Special validation for market resolution tasks
        if (taskToMarketId[referenceTaskIndex] != bytes32(0)) {
            require(signatureHash == YES_HASH || signatureHash == NO_HASH, "Invalid response for market resolution");
        }

        // 4. Update State:
        hasResponded[referenceTaskIndex][msg.sender] = true;
        allTaskResponseHashes[msg.sender][referenceTaskIndex] = signatureHash; // Store hash for reward check
        _tempSignatures[msg.sender][referenceTaskIndex] = signature; // Store full signature temporarily for event
        _taskRespondents[referenceTaskIndex].push(msg.sender);

        // Update task status if it was the first response
        if (_taskStatus[referenceTaskIndex] == TaskStatus.Created) {
            _taskStatus[referenceTaskIndex] = TaskStatus.InProgress;
        }

        // Increment vote count for this specific response hash
        responseVotes[referenceTaskIndex][signatureHash]++;

        // 5. Check for Consensus:
        uint256 totalResponses = _taskRespondents[referenceTaskIndex].length;
        if (totalResponses >= minimumResponses) {
            uint256 votesForThisResponse = responseVotes[referenceTaskIndex][signatureHash];
            // Check if the threshold is met (using basis points)
            if (votesForThisResponse * 10000 / totalResponses >= consensusThreshold) {
                _finalizeConsensus(referenceTaskIndex, signatureHash);
            }
        }

        // 6. Emit Event & Cleanup:
        // Create a minimal task struct for the event (original name not needed here)
        Task memory eventTask = Task("", uint32(block.number)); // Name is empty, block number is current
        emit TaskResponded(referenceTaskIndex, eventTask, msg.sender);
        delete _tempSignatures[msg.sender][referenceTaskIndex]; // Clean up temporary storage
    }

    /**
     * @notice Internal function to finalize consensus once the threshold is met.
     * @dev Sets task status to Resolved, stores the consensus hash, emits event,
     *      and attempts to resolve any linked prediction market.
     * @param taskIndex Index of the task being finalized.
     * @param consensusHash The hash of the response that achieved consensus.
     */
    function _finalizeConsensus(uint32 taskIndex, bytes32 consensusHash) internal {
        // Prevent finalizing multiple times
        if (_taskStatus[taskIndex] == TaskStatus.Resolved) {
            return;
        }

        // Update task status and store result hash
        _taskStatus[taskIndex] = TaskStatus.Resolved;
        taskConsensusResultHash[taskIndex] = consensusHash;

        // Emit consensus event (result bytes are empty as we only store the hash)
        emit ConsensusReached(taskIndex, "");

        // Attempt to resolve linked prediction market, if applicable
        bytes32 marketId = taskToMarketId[taskIndex];
        address hookAddress = taskToHookAddress[taskIndex];

        if (marketId != bytes32(0) && hookAddress != address(0)) {
            // Determine outcome based on the consensus hash
            bool outcome;
            if (consensusHash == YES_HASH) {
                outcome = true;
            } else if (consensusHash == NO_HASH) {
                outcome = false;
            } else {
                // Should not happen if respondToTask validation is correct, but handle defensively
                emit MarketResolutionFailed(taskIndex, marketId, "Invalid consensus hash");
                return;
            }

            // Call resolveMarket on the specific hook that created the task
            try IPredictionMarketHook(hookAddress).resolveMarket(marketId, outcome) {
                emit MarketResolvedByOracle(taskIndex, marketId, outcome);
            } catch (bytes memory reason) {
                // Handle potential errors during the external call (e.g., market not in correct state)
                emit MarketResolutionFailed(taskIndex, marketId, string(reason));
            }
        }
    }

    /**
     * @notice Distributes rewards to agents who participated correctly in a resolved task.
     * @dev Iterates through respondents, checks if their response hash matches the consensus,
     *      calculates the reward (placeholder), and emits an event.
     *      Actual token transfer logic needs to be implemented based on the reward mechanism.
     * @param taskIndex Index of the resolved task for which to distribute rewards.
     */
    function distributeRewards(uint32 taskIndex) external override {
        require(_taskStatus[taskIndex] == TaskStatus.Resolved, "Task not resolved");
        bytes32 winningHash = taskConsensusResultHash[taskIndex];
        require(winningHash != bytes32(0), "No consensus result");

        // Placeholder: Define who initiates rewards or how they are funded.
        // address rewardsInitiator = owner();

        uint256 totalResponses = _taskRespondents[taskIndex].length;
        address[] memory respondents = _taskRespondents[taskIndex]; // Cache storage array to local memory

        for (uint256 i = 0; i < totalResponses; i++) {
            address agent = respondents[i];
            // Check if the agent's response hash matches the final consensus hash
            if (allTaskResponseHashes[agent][taskIndex] == winningHash) {
                // This agent contributed to the winning consensus
                uint256 rewardAmount = calculateReward(agent, taskIndex); // Calculate reward (currently placeholder)

                // !!! Placeholder for actual reward distribution !!!
                // Example: IERC20(rewardTokenAddress).transfer(agent, rewardAmount);
                // Requires defining rewardTokenAddress and funding mechanism.

                emit AgentRewarded(agent, taskIndex, rewardAmount);
            }
        }
    }

    // --- Helper & View Functions ---

    /**
     * @notice Checks if the contract is operating in a simplified test mode.
     * @dev Test mode is currently defined as requiring only 1 response for consensus.
     * @return True if minimumResponses is 1, false otherwise.
     */
    function isTestMode() internal view returns (bool) {
        // Simple check based on minimumResponses
        return (minimumResponses == 1);
    }

    /**
     * @notice Placeholder function for calculating agent rewards.
     * @dev Needs to be implemented with actual reward logic (e.g., based on stake, reputation, gas used).
     * @param agent The address of the agent being rewarded.
     * @param taskIndex The index of the task.
     * @return rewardAmount The calculated reward amount.
     */
    function calculateReward(address agent, uint32 taskIndex) internal pure returns (uint256 rewardAmount) {
        // Prevent unused variable warnings
        agent;
        taskIndex;
        // Placeholder - return a fixed amount for now
        return 1 ether; // Example: 1 unit of the native token (e.g., ETH)
    }

    /**
     * @notice Gets the consensus result (if resolved) for a task.
     * @dev In this implementation, only stores the hash, so `result` bytes will be empty.
     * @param taskIndex Index of the task.
     * @return result Empty bytes (as only the hash is stored).
     * @return isResolved True if the task status is Resolved, false otherwise.
     */
    function getConsensusResult(uint32 taskIndex)
        external
        view
        override
        returns (bytes memory result, bool isResolved)
    {
        isResolved = (_taskStatus[taskIndex] == TaskStatus.Resolved);
        // Return empty bytes as the full result bytes are not stored
        result = "";
    }

    /**
     * @notice Returns the current status (Created, InProgress, Resolved) of a task.
     * @param taskIndex The index of the task.
     * @return The current TaskStatus enum value.
     */
    function taskStatus(uint32 taskIndex) external view override returns (TaskStatus) {
        return _taskStatus[taskIndex];
    }

    /**
     * @notice Returns the list of addresses of agents who have responded to a specific task.
     * @param taskIndex The index of the task.
     * @return An array containing the addresses of the respondents.
     */
    function taskRespondents(uint32 taskIndex) external view override returns (address[] memory) {
        return _taskRespondents[taskIndex];
    }

    /**
     * @notice Returns the hash of the final consensus result for a resolved task.
     * @param taskIndex The index of the task.
     * @return The keccak256 hash of the consensus result (or zero bytes32 if not resolved).
     */
    function consensusResultHash(uint32 taskIndex) external view override returns (bytes32) {
        return taskConsensusResultHash[taskIndex];
    }

    /**
     * @notice Gets the response bytes submitted by a specific operator for a task.
     * @dev May return empty bytes if the response was only stored temporarily.
     * @param operator The address of the operator.
     * @param taskIndex The index of the task.
     * @return The response bytes submitted.
     */
    function allTaskResponses(address operator, uint32 taskIndex) external view override returns (bytes memory) {
        // Returns the temporarily stored signature, might be empty if already processed
        return _tempSignatures[operator][taskIndex];
    }

    /**
     * @notice Gets the market ID associated with a specific oracle task index, if any.
     * @param taskIndex The index of the oracle task.
     * @return marketId The associated market ID (bytes32), or zero if not a market resolution task.
     */
    function getMarketIdForTask(uint32 taskIndex) external view override returns (bytes32 marketId) {
        return taskToMarketId[taskIndex];
    }

    /**
     * @notice Gets the address of the Prediction Market Hook associated with a specific oracle task index.
     * @param taskIndex The index of the oracle task.
     * @return hookAddress The address of the hook that created the task, or zero address if not a market resolution task.
     */
    function getHookAddressForTask(uint32 taskIndex) external view override returns (address hookAddress) {
        return taskToHookAddress[taskIndex];
    }

    /**
     * @notice Gets the full Task struct (name and creation block) for a given task index.
     * @dev Relies on the `allTasks` mapping being populated during task creation.
     * @param taskIndex The index of the task to retrieve.
     * @return Task memory The stored Task struct.
     */
    function getTask(uint32 taskIndex) external view override returns (Task memory) {
        // Check if the task exists by looking at its creation block (should be non-zero if created)
        require(allTasks[taskIndex].taskCreatedBlock != 0, "Task does not exist");
        return allTasks[taskIndex];
    }
}
