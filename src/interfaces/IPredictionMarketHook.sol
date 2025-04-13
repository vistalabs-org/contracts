// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Market, MarketState, MarketSetting, CreateMarketParams} from "../types/MarketTypes.sol";

interface IPredictionMarketHook {
    // --- Events ---
    event PoolCreated(PoolId poolId);
    event WinningsClaimed(bytes32 indexed marketId, address indexed user, uint256 amount);
    event ResolutionStarted(bytes32 indexed marketId, uint32 taskIndex);
    event MarketResolved(bytes32 indexed marketId, bool outcome, address resolver);
    event MarketCancelled(bytes32 indexed marketId);
    event MarketActivated(bytes32 indexed marketId);
    event MarketClosed(bytes32 indexed marketId);
    event MarketDisputed(bytes32 indexed marketId);
    event OracleServiceManagerSet(address indexed newOracleAddress);

    // --- State Changing Functions ---

    /// @notice Creates a new market and deposits collateral
    /// @param params Struct containing all market creation parameters
    /// @return The market ID
    function createMarketAndDepositCollateral(CreateMarketParams calldata params) external returns (bytes32);

    /// @notice Moves the market from Closed to InResolution and triggers the oracle task
    /// @param marketId The ID of the market
    function enterResolution(bytes32 marketId) external;

    /// @notice Resolves the market with the final outcome (called by the Oracle Service Manager)
    /// @param marketId The ID of the market
    /// @param outcome true for YES, false for NO
    function resolveMarket(bytes32 marketId, bool outcome) external;

    /// @notice Cancels an active market
    /// @param marketId The ID of the market
    function cancelMarket(bytes32 marketId) external;

    /// @notice Allows users to claim their winnings after market resolution
    /// @param marketId The ID of the market
    function claimWinnings(bytes32 marketId) external;

    /// @notice Allows users to redeem their collateral if the market is cancelled
    /// @param marketId The ID of the market
    function redeemCollateral(bytes32 marketId) external;

    /// @notice Activates a market, allowing trading and liquidity provision.
    /// @param marketId The ID of the market to activate.
    function activateMarket(bytes32 marketId) external;

    /// @notice Moves the market from Active to Closed
    /// @param marketId The ID of the market
    function closeMarket(bytes32 marketId) external;

    /// @notice Allows a dispute process to be initiated
    /// @param marketId The ID of the market
    function disputeResolution(bytes32 marketId) external;

    /// @notice Allows users to mint YES/NO tokens by providing collateral
    /// @param marketId The ID of the market
    /// @param collateralAmount Amount of collateral to provide
    /// @param collateralAddress The address of the collateral token (added)
    function mintOutcomeTokens(bytes32 marketId, uint256 collateralAmount, address collateralAddress) external;

    // --- View Functions ---

    /// @notice Gets market information from a pool ID used by the market
    /// @param poolId The ID of the pool (either YES/collateral or NO/collateral)
    /// @return Market struct containing market information
    function markets(PoolId poolId) external view returns (Market memory);

    /// @notice Gets the amount of collateral tokens claimed for a specific market
    /// @param marketId The ID of the market
    /// @return The total amount of collateral claimed so far for this market
    function claimedTokens(bytes32 marketId) external view returns (uint256);

    /// @notice Checks if a specific user has already claimed their winnings for a market
    /// @param marketId The ID of the market
    /// @param user The address of the user
    /// @return Boolean indicating whether the user has claimed their winnings
    function hasClaimed(bytes32 marketId, address user) external view returns (bool);

    /// @notice Gets market information by its unique market ID
    /// @param marketId The ID of the market
    /// @return Market struct containing market information
    function getMarketById(bytes32 marketId) external view returns (Market memory);

    /// @notice Gets a paginated list of all markets managed by the hook
    /// @param offset The starting index for pagination
    /// @param limit The maximum number of markets to return in this page
    /// @return An array of Market structs
    function getMarkets(uint256 offset, uint256 limit) external view returns (Market[] memory);

    /// @notice Gets all market IDs managed by the hook
    /// @return Array containing all market IDs
    function getAllMarketIds() external view returns (bytes32[] memory);

    /// @notice Gets all markets with their details
    /// @return Array containing Market structs for all markets
    function getAllMarkets() external view returns (Market[] memory);

    /// @notice Gets the total count of markets created
    /// @return The total number of markets
    function getMarketCount() external view returns (uint256);

    /// @notice Gets the pool ID associated with a specific market index (from the internal array)
    /// @param index The index of the market (order of creation)
    /// @return The PoolId of the market pool at that index
    function marketPoolIds(uint256 index) external view returns (PoolId);

    /// @notice Gets the configured Oracle Service Manager address used by this hook
    /// @return Address of the IAIOracleServiceManager contract
    function aiOracleServiceManager() external view returns (address);
}
