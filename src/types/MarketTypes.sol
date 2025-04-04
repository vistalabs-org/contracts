// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import "../OutcomeToken.sol";

enum MarketState {
    Created,         // Market created, not yet active
    Active,          // Market is open for trading
    Closed,          // Market is closed
    InResolution,    // Resolution process has started (e.g., waiting for oracle)
    Resolved,        // Final outcome determined, winnings can be claimed
    Cancelled,       // Market cancelled, collateral can be redeemed
    Disputed         // Market resolution is disputed
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
    uint256 curveId;
}

struct CreateMarketParams {
    address oracle;
    address creator;
    address collateralAddress;
    uint256 collateralAmount;
    string title;
    string description;
    uint256 duration;
    uint256 curveId;
}
