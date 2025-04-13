// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import "../OutcomeToken.sol";

enum MarketState {
    Created, // Market created, not yet active
    Active, // Market is open for trading
    Closed, // Market is closed
    InResolution, // Resolution process has started (e.g., waiting for oracle)
    Resolved, // Final outcome determined, winnings can be claimed
    Cancelled, // Market cancelled, collateral can be redeemed
    Disputed // Market resolution is disputed

}

struct MarketSetting {
    uint24 fee; // Uniswap pool fee tier (e.g., 500 for 0.05%)
    int24 tickSpacing; // Tick spacing corresponding to the fee tier
    int24 startingTick; // The initial tick for the pool (optional, might not be used directly at pool creation)
    int24 maxTick; // Maximum allowable tick for liquidity in this market
    int24 minTick; // Minimum allowable tick for liquidity in this market
}

struct Market {
    PoolKey yesPoolKey; // Pool key for collateral-YES pair
    PoolKey noPoolKey; // Pool key for collateral-NO pair
    address oracle;
    address creator;
    OutcomeToken yesToken;
    OutcomeToken noToken;
    MarketState state;
    bool outcome;
    uint256 totalCollateral;
    address collateralAddress;
    string title; // Market title
    string description; // Market description
    uint256 endTimestamp; // Market end time
    MarketSetting settings;
}

struct CreateMarketParams {
    address oracle;
    address creator;
    address collateralAddress;
    uint256 collateralAmount;
    string title;
    string description;
    uint256 duration;
    MarketSetting settings;
}
