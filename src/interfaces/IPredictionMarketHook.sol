// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Market} from "../types/MarketTypes.sol";
import {CreateMarketParams} from "../types/MarketTypes.sol";

interface IPredictionMarketHook {

    /// @notice Creates a new market and deposits collateral
    /// @param params Struct containing all market creation parameters
    /// @return The market ID
    function createMarketAndDepositCollateral(
        CreateMarketParams calldata params
    ) external returns (bytes32);

    /// @notice Resolves the market with the final outcome
    /// @param marketId The ID of the market
    /// @param outcome true for YES, false for NO
    function resolveMarket(bytes32 marketId, bool outcome) external;

    /// @notice Cancels an active market
    /// @param marketId The ID of the market
    function cancelMarket(bytes32 marketId) external;

    /// @notice Allows users to claim their winnings after market resolution
    /// @param marketId The ID of the market
    function claimWinnings(bytes32 marketId) external;

    /// @notice Gets market information
    /// @param poolId The ID of the pool
    /// @return Market struct containing market information
    function markets(PoolId poolId) external view returns (Market memory);

    /// @notice Gets the total number of markets created
    /// @return The count of markets
    function marketCount() external view returns (uint256);

    /// @notice Gets the pool ID for a given market index
    /// @param index The market index
    /// @return The pool ID
    function marketPoolIds(uint256 index) external view returns (PoolId);

    /// @notice Gets the amount of tokens claimed for a market
    /// @param marketId The ID of the market
    /// @return The amount of claimed tokens
    function claimedTokens(bytes32 marketId) external view returns (uint256);

    /// @notice Checks if a user has claimed their winnings
    /// @param marketId The ID of the market
    /// @param user The address of the user
    /// @return Whether the user has claimed their winnings
    function hasClaimed(bytes32 marketId, address user) external view returns (bool);

    /// @notice Gets market information by market ID
    /// @param marketId The ID of the market
    /// @return Market struct containing market information
    function getMarketById(bytes32 marketId) external view returns (Market memory);
} 