// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Gaussian} from "lib/solstat/src/Gaussian.sol";
import "forge-std/console.sol";

contract NormalQuoter {
    // Given reserve0 (x) and liquidity L, compute reserve1 (y)
    // Solves: (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y = 0 for y
    function computeReserve1FromReserve0(uint256 reserve0, uint256 liquidity, uint256 scaling)
        public
        view
        returns (uint256)
    {
        require(liquidity > 0, "Invalid liquidity");

        console.log("Computing reserve1 from reserve0:", reserve0);
        console.log("Liquidity:", liquidity);

        // Initial guesses for secant method
        uint256 y0 = reserve0 / 2; // First guess
        uint256 y1 = reserve0 * 2; // Second guess

        // Calculate function value for first guess
        int256 f0 = calculateFunction(y0, reserve0, liquidity, scaling);

        // Secant method iterations
        for (uint256 i = 0; i < 10; i++) {
            // Calculate function value for second guess
            int256 f1 = calculateFunction(y1, reserve0, liquidity, scaling);

            // Check if we're close enough to a solution
            if (abs(f1) < 1e12) {
                console.log("Converged at iteration", i);
                break;
            }

            // Calculate next guess using secant formula: y2 = y1 - f1 * (y1 - y0) / (f1 - f0)
            int256 denominator = f1 - f0;
            if (denominator == 0) {
                // Avoid division by zero
                break;
            }

            int256 y2 = int256(y1) - (f1 * (int256(y1) - int256(y0))) / denominator;

            // Ensure y2 is positive
            if (y2 <= 0) {
                y1 = 1;
                break;
            }

            // Update values for next iteration
            y0 = y1;
            y1 = uint256(y2);
            f0 = f1;

            console.log("Iteration", i);
            console.log("y:", y1);
            console.log("f:", f1);
        }

        return y1;
    }

    // Given reserve1 (y) and liquidity L, compute reserve0 (x)
    function computeReserve0FromReserve1(uint256 reserve1, uint256 liquidity, uint256 scaling)
        public
        view
        returns (uint256)
    {
        require(liquidity > 0, "Invalid liquidity");

        console.log("Computing reserve0 from reserve1:", reserve1);
        console.log("Liquidity:", liquidity);

        // Initial guesses for secant method. TODO: Make these better
        uint256 x0 = reserve1 / 2; // First guess
        uint256 x1 = reserve1 * 2; // Second guess

        // Calculate function value for first guess
        int256 f0 = calculateFunctionReverse(x0, reserve1, liquidity, scaling);

        // Secant method iterations
        for (uint256 i = 0; i < 10; i++) {
            // Calculate function value for second guess
            int256 f1 = calculateFunctionReverse(x1, reserve1, liquidity, scaling);

            // Check if we're close enough to a solution
            if (abs(f1) < 1e12) {
                console.log("Converged at iteration", i);
                break;
            }

            // Calculate next guess using secant formula: x2 = x1 - f1 * (x1 - x0) / (f1 - f0)
            int256 denominator = f1 - f0;
            if (denominator == 0) {
                // Avoid division by zero
                break;
            }

            int256 x2 = int256(x1) - (f1 * (int256(x1) - int256(x0))) / denominator;

            // Ensure x2 is positive
            if (x2 <= 0) {
                x1 = 1;
                break;
            }

            // Update values for next iteration
            x0 = x1;
            x1 = uint256(x2);
            f0 = f1;

            console.log("Iteration", i);
            console.log("x:", x1);
            console.log("f:", f1);
        }

        return x1;
    }

    // Helper function to calculate (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y
    function calculateFunction(uint256 y, uint256 x, uint256 liquidity, uint256 scaling)
        internal
        view
        returns (int256)
    {
        int256 diff = int256(y) - int256(x);
        // scaled liquidity
        int256 scaledLiquidity = int256(liquidity) * int256(scaling) / 1e18;

        int256 normalized = (diff * 1e18) / scaledLiquidity;

        int256 cdf = Gaussian.cdf(normalized);
        int256 pdf = Gaussian.pdf(normalized);

        // Calculate (y-x)Φ((y-x)/L)
        int256 term1 = (diff * cdf) / 1e18;

        // Calculate Lφ((y-x)/L)
        int256 term2 = (scaledLiquidity * pdf) / 1e18;

        // Calculate (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y
        return term1 + term2 - int256(y);
    }

    // Helper function to calculate (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y for reverse case
    function calculateFunctionReverse(uint256 x, uint256 y, uint256 liquidity, uint256 scaling)
        internal
        view
        returns (int256)
    {
        int256 diff = int256(y) - int256(x);
        int256 scaledLiquidity = int256(liquidity) * int256(scaling) / 1e18;
        int256 normalized = (diff * 1e18) / scaledLiquidity;

        int256 cdf = Gaussian.cdf(normalized);
        int256 pdf = Gaussian.pdf(normalized);

        // Calculate (y-x)Φ((y-x)/L)
        int256 term1 = (diff * cdf) / 1e18;

        // Calculate Lφ((y-x)/L)
        int256 term2 = (scaledLiquidity * pdf) / 1e18;

        // Calculate (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y
        return term1 + term2 - int256(y);
    }

    // Calculate absolute value of an int256
    function abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }
}
