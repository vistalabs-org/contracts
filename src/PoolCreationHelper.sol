// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Market} from "./types/MarketTypes.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";

contract PoolCreationHelper {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }
    // for only YES/NO tokens
    function createUniswapPoolWithoutCollateral(PoolKey memory pool) external returns (PoolKey memory) {
        // yes no at same price

        uint160 pricePoolQ = TickMath.getSqrtPriceAtTick(0);

        console.log("Pool price SQRTX96: %d", pricePoolQ);

        poolManager.initialize(pool, pricePoolQ);

        console.log("Pool created");

        return pool;
    }
    // for collateral token as token0 or token1
    function createUniswapPoolWithCollateral(PoolKey memory pool, bool isCollateralToken0) external returns (PoolKey memory) {

        uint160 pricePoolQ = TickMath.getSqrtPriceAtTick(6900);

        console.log("Pool price SQRTX96: %d", pricePoolQ);

        poolManager.initialize(pool, pricePoolQ);

        console.log("Pool created");

        return pool;
    }
}
