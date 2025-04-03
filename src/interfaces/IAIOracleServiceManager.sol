// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IAIOracleServiceManager {
    event NewTaskCreated(uint32 indexed taskIndex, Task task);

    event TaskResponded(uint32 indexed taskIndex, Task task, address operator);
    
    event ConsensusReached(uint32 indexed taskIndex, bytes consensusResult);
    
    event AgentRewarded(address indexed agent, uint32 indexed taskIndex, uint256 rewardAmount);

    event MarketResolvedByOracle(uint32 indexed taskIndex, bytes32 indexed marketId, bool outcome);
    event MarketResolutionFailed(uint32 indexed taskIndex, bytes32 indexed marketId, string reason);

    struct Task {
        string name;
        uint32 taskCreatedBlock;
    }

    enum TaskStatus { Created, InProgress, Resolved }

    function latestTaskNum() external view returns (uint32);
    
    function minimumResponses() external view returns (uint256);
    
    function consensusThreshold() external view returns (uint256);
    
    function taskStatus(uint32 taskIndex) external view returns (TaskStatus);

    function allTaskHashes(
        uint32 taskIndex
    ) external view returns (bytes32);

    function allTaskResponses(
        address operator,
        uint32 taskIndex
    ) external view returns (bytes memory);
    
    function taskRespondents(uint32 taskIndex) external view returns (address[] memory);
    
    function consensusResultHash(uint32 taskIndex) external view returns (bytes32);

    function predictionMarketHook() external view returns (address);

    function getMarketIdForTask(uint32 taskIndex) external view returns (bytes32);
    function getHookAddressForTask(uint32 taskIndex) external view returns (address);

    function createNewTask(
        string memory name
    ) external returns (Task memory);

    function respondToTask(
        uint32 referenceTaskIndex,
        bytes calldata signature
    ) external;
    
    function getConsensusResult(uint32 taskIndex) external view returns (bytes memory result, bool isResolved);
    
    function updateConsensusParameters(
        uint256 _minimumResponses,
        uint256 _consensusThreshold
    ) external;
    
    function distributeRewards(uint32 taskIndex) external;

    function addTestOperator(address operator) external;

    function createMarketResolutionTask(
        string memory name,
        bytes32 marketId,
        address hookAddress
    ) external returns (uint32 taskIndex);
}