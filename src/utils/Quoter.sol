// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Gaussian} from "lib/solstat/src/Gaussian.sol";
import "forge-std/console.sol";

contract NormalQuoter {
    // Given reserve0 (x) and liquidity L, compute reserve1 (y)
    // Solves: (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y = 0 for y
    function computeReserve1FromReserve0(uint256 reserve0, uint256 liquidity) public view returns (uint256) {
        require(liquidity > 0, "Invalid liquidity");
        
        console.log("Computing reserve1 from reserve0:", reserve0);
        console.log("Liquidity:", liquidity);
        
        // For our initial implementation, we want reserve1 to be close to reserve0
        // Start with a reasonable range
        uint256 low = 0;
        uint256 high = reserve0 * 2;
        uint256 y = reserve0; // Initial guess
        
        // Track the best result so far
        uint256 bestY = 0;
        int256 bestResult = type(int256).max;
        
        // Binary search for 64 iterations
        for (uint256 i = 0; i < 64; i++) {
            y = (low + high) / 2;
            
            // Prevent y from becoming too small
            if (y < liquidity / 100) {
                y = liquidity / 100;
                break;
            }
            
            // Compute left side of equation: (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y
            int256 diff = int256(y) - int256(reserve0);
            int256 normalized = (diff * 1e18) / int256(liquidity);
            
            int256 cdf = Gaussian.cdf(normalized);
            int256 pdf = Gaussian.pdf(normalized);
            
            // Calculate (y-x)Φ((y-x)/L)
            int256 term1 = (diff * cdf) / 1e18;
            
            // Calculate Lφ((y-x)/L)
            int256 term2 = (int256(liquidity) * pdf) / 1e18;
            
            // Calculate (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y
            int256 result = term1 + term2 - int256(y);
            
            // Log some iterations for debugging
            if (i == 0 || i == 1 || i == 2 || i == 63) {
                console.log("Iteration", i);
                console.log("y:", y);
                console.log("result:", result);
            }
            
            // Track the best result (closest to zero)
            if (result < 0) result = -result; // Take absolute value
            if (result < bestResult) {
                bestResult = result;
                bestY = y;
            }
            
            // Check if we're close enough to a solution
            if (result < 1e15) { // Small enough threshold
                break;
            }
            
            // If the high-low range gets too small, stop to prevent converging to zero
            if (high - low < liquidity / 1000) {
                break;
            }
            
            // Update search range
            if (term1 + term2 > int256(y)) {
                high = y;
            } else {
                low = y;
            }
        }
        
        // Use the best result we found
        console.log("Best y found:", bestY);
    
        
        return bestY;
    }
    
    
    // Given reserve1 (y) and liquidity L, compute reserve0 (x)
    function computeReserve0FromReserve1(uint256 reserve1, uint256 liquidity) public view returns (uint256) {
        require(liquidity > 0, "Invalid liquidity");
        
        console.log("Computing reserve0 from reserve1:", reserve1);
        console.log("Liquidity:", liquidity);
        
        // For our initial implementation, we want reserve0 to be close to reserve1
        // Start with a reasonable range
        uint256 low = 0;
        uint256 high = reserve1 * 2;
        uint256 x = reserve1; // Initial guess
        
        // Track the best result so far
        uint256 bestX = reserve1;
        int256 bestResult = type(int256).max;
        
        // Binary search for 64 iterations
        for (uint256 i = 0; i < 64; i++) {
            x = (low + high) / 2;
            
            // Prevent x from becoming too small
            if (x < liquidity / 100) {
                x = liquidity / 100;
                break;
            }
            
            // Compute left side of equation: (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y
            int256 diff = int256(reserve1) - int256(x);
            int256 normalized = (diff * 1e18) / int256(liquidity);
            
            int256 cdf = Gaussian.cdf(normalized);
            int256 pdf = Gaussian.pdf(normalized);
            
            // Calculate (y-x)Φ((y-x)/L)
            int256 term1 = (diff * cdf) / 1e18;
            
            // Calculate Lφ((y-x)/L)
            int256 term2 = (int256(liquidity) * pdf) / 1e18;
            
            // Calculate (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y
            int256 result = term1 + term2 - int256(reserve1);
            
            // Log some iterations for debugging
            if (i == 0 || i == 1 || i == 2 || i == 63) {
                console.log("Iteration", i);
                console.log("x:", x);
                console.log("result:", result);
            }
            
            // Track the best result (closest to zero)
            if (result < 0) result = -result; // Take absolute value
            if (result < bestResult) {
                bestResult = result;
                bestX = x;
            }
            
            // Check if we're close enough to a solution
            if (result < 1e15) { // Small enough threshold
                break;
            }
            
            // If the high-low range gets too small, stop to prevent converging to zero
            if (high - low < liquidity / 1000) {
                break;
            }
            
            // Update search range
            if (term1 + term2 > int256(reserve1)) {
                low = x;
            } else {
                high = x;
            }
        }
        
        // Use the best result we found
        console.log("Best x found:", bestX);

        return bestX;
    }
    
    // Calculate the output amount for a swap
    function computeOutputAmount(uint256 inputReserve, uint256 outputReserve, uint256 inputAmount, uint256 liquidity, bool zeroForOne) public view returns (int256) {
        if (inputAmount == 0) return 0;
        
        // Calculate new input reserve after swap
        uint256 newInputReserve = inputReserve + inputAmount;
        
        // Calculate new output reserve based on the invariant
        uint256 newOutputReserve;
        if (zeroForOne) {
            // If swapping token0 for token1, calculate new reserve1 from new reserve0
            newOutputReserve = computeReserve1FromReserve0(newInputReserve, liquidity);
        } else {
            // If swapping token1 for token0, calculate new reserve0 from new reserve1
            newOutputReserve = computeReserve0FromReserve1(newInputReserve, liquidity);
        }
        
        // Output amount is the difference in output reserves
        /*
        if (newOutputReserve >= outputReserve) {
            return 0;
        }*/
        console.log("outputReserve:", outputReserve);
        console.log("newOutputReserve:", newOutputReserve);
        return int256(outputReserve) - int256(newOutputReserve);
    }
}
