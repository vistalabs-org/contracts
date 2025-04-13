// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPredictionMarketHook} from "../../src/interfaces/IPredictionMarketHook.sol";
import {Market, CreateMarketParams} from "../../src/types/MarketTypes.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

// Concrete Mock Hook implementing all functions (mostly dummies)
contract MinimalRevertingHook is IPredictionMarketHook {
    // The function we care about for the test
    function resolveMarket(bytes32, /*marketId*/ bool /*outcome*/ ) external pure override {
        revert("MockRevert: Cannot resolve market");
    }

    // --- Dummy Implementations for all other IPredictionMarketHook functions ---
    function createMarketAndDepositCollateral(CreateMarketParams calldata) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function closeMarket(bytes32) external pure override {}
    function enterResolution(bytes32) external pure override {}

    function getMarketById(bytes32) external pure override returns (Market memory) {
        Market memory m;
        return m;
    }

    function setOracleServiceManager(address) external pure {}

    function aiOracleServiceManager() external pure override returns (address) {
        return address(0);
    }

    function activateMarket(bytes32 /*marketId*/ ) external pure override {}
    function cancelMarket(bytes32 /*marketId*/ ) external pure override {}
    function claimWinnings(bytes32 /*marketId*/ ) external pure override {}
    function disputeResolution(bytes32 /*marketId*/ ) external pure override {}
    function mintOutcomeTokens(bytes32, /*marketId*/ uint256, /*collateralAmount*/ address /*collateralAddress*/ )
        external
        pure
        override
    {}
    function redeemCollateral(bytes32 /*marketId*/ ) external pure override {}
    // View/Pure functions returning values

    function markets(PoolId /*poolId*/ ) external pure override returns (Market memory) {
        Market memory m;
        return m;
    }

    function claimedTokens(bytes32 /*marketId*/ ) external pure override returns (uint256) {
        return 0;
    }

    function hasClaimed(bytes32, /*marketId*/ address /*user*/ ) external pure override returns (bool) {
        return false;
    }

    function getMarkets(uint256, /*offset*/ uint256 /*limit*/ ) external pure override returns (Market[] memory) {
        Market[] memory m;
        return m;
    }

    function getAllMarketIds() external pure override returns (bytes32[] memory) {
        bytes32[] memory m;
        return m;
    }

    function getAllMarkets() external pure override returns (Market[] memory) {
        Market[] memory m;
        return m;
    }

    function getMarketCount() external pure override returns (uint256) {
        return 0;
    }

    function marketPoolIds(uint256 /*index*/ ) external pure override returns (PoolId) {
        return PoolId.wrap(bytes32(0));
    }

    // add this to be excluded from coverage report
    function test() public {}
}
