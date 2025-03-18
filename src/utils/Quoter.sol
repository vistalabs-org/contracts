// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Stats.sol";

contract NormalQuoter {
    uint256 constant SCALE = 10**18;
    NormalDistribution public normalDist;

    constructor() {
        normalDist = new NormalDistribution();
    }

    // Given input amount x and liquidity L, compute output amount y
    function computeOutputAmount(
        uint256 inputAmount,
        uint256 liquidity
    ) public view returns (uint256) {
        // We need to solve (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y = 0
        // Using binary search since the equation is monotonic
        
        uint256 low = 0;
        uint256 high = inputAmount * 2; // Initial guess for upper bound
        uint256 y;
        
        // Binary search for 64 iterations
        for (uint256 i = 0; i < 64; i++) {
            y = (low + high) / 2;
            
            // Compute f(y) = (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y
            int256 diff = int256(y - inputAmount);
            int256 normalized = (diff * int256(SCALE)) / int256(liquidity);
            
            uint256 cdf = normalDist.normalCDF(normalized);
            uint256 pdf = normalDist.normalPDF(normalized);
            
            uint256 term1 = (uint256(diff) * cdf) / SCALE;
            uint256 term2 = (liquidity * pdf) / SCALE;
            
            if (term1 + term2 > y) {
                low = y;
            } else {
                high = y;
            }
        }
        
        return y;
    }

    // Given desired output amount y and liquidity L, compute required input amount x
    function computeInputAmount(
        uint256 outputAmount,
        uint256 liquidity
    ) public view returns (uint256) {
        // Similar to computeOutputAmount but solving for x
        uint256 low = 0;
        uint256 high = outputAmount * 2;
        uint256 x;
        
        for (uint256 i = 0; i < 64; i++) {
            x = (low + high) / 2;
            
            int256 diff = int256(outputAmount - x);
            int256 normalized = (diff * int256(SCALE)) / int256(liquidity);
            
            uint256 cdf = normalDist.normalCDF(normalized);
            uint256 pdf = normalDist.normalPDF(normalized);
            
            uint256 term1 = (uint256(diff) * cdf) / SCALE;
            uint256 term2 = (liquidity * pdf) / SCALE;
            
            if (term1 + term2 > outputAmount) {
                high = x;
            } else {
                low = x;
            }
        }
        
        return x;
    }

    // Compute price impact as a percentage (scaled by SCALE)
    function computePriceImpact(
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 liquidity
    ) public pure returns (uint256) {
        // Price impact = |1 - (dy/dx)|
        uint256 spotPrice = SCALE; // Assuming 1:1 spot price
        uint256 executionPrice = (outputAmount * SCALE) / inputAmount;
        
        if (executionPrice > spotPrice) {
            return ((executionPrice - spotPrice) * SCALE) / spotPrice;
        } else {
            return ((spotPrice - executionPrice) * SCALE) / spotPrice;
        }
    }
}
