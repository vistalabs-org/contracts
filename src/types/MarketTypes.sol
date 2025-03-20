// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import "../OutcomeToken.sol";

enum MarketState {
    Active,
    Resolved,
    Cancelled
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
}

struct CreateMarketParams {
    address oracle;
    address creator;
    address collateralAddress;
    uint256 collateralAmount;
    string title;
    string description;
    uint256 duration;
}
