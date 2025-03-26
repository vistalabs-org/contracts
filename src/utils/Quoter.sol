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
        require(liquidity > 0, "Invalid liquidity");
        if (inputAmount == 0) return 0;
        
        // We need to solve (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y = 0
        // Using binary search since the equation is monotonic
        
        uint256 low = 0;
        uint256 high = inputAmount; // Upper bound should be input amount (can't get more out than in)
        uint256 y;
        
        // Binary search for 64 iterations
        for (uint256 i = 0; i < 64; i++) {
            y = (low + high) / 2;
            
            console.log("computing cdf");
            // Compute f(y) = (y-x)Φ((y-x)/L) + Lφ((y-x)/L) - y
            int256 diff = int256(y) - int256(inputAmount);
            int256 normalized = (diff * int256(SCALE)) / int256(liquidity);
            
            uint256 cdf = normalDist.normalCDF(normalized);
            
            console.log("computing pdf");
            uint256 pdf = normalDist.normalPDF(normalized);
            
            // Handle negative diff properly
            uint256 term1;
            if (diff < 0) {
                // If diff is negative, we need to subtract
                term1 = (uint256(-diff) * cdf) / SCALE;
                if (term1 > y) {
                    // If term1 > y, we'd get an underflow, so set high = y
                    high = y;
                    continue;
                }
                term1 = y - term1;
            } else {
                // If diff is positive or zero
                term1 = (uint256(diff) * cdf) / SCALE;
            }
            
            uint256 term2 = (liquidity * pdf) / SCALE;
            
            // Check if term1 + term2 > y, being careful about overflow
            if (term1 > y || term2 > type(uint256).max - term1 || term1 + term2 > y) {
                low = y;
            } else {
                high = y;
            }
        }
        
        // Ensure output is less than input due to slippage
        return y < inputAmount ? y : inputAmount - 1;
    }

    // Given desired output amount y and liquidity L, compute required input amount x
    function computeInputAmount(
        uint256 outputAmount,
        uint256 liquidity
    ) public view returns (uint256) {
        require(liquidity > 0, "Invalid liquidity");
        if (outputAmount == 0) return 0;
        
        // For input amount, we need to ensure it's greater than output amount
        uint256 low = outputAmount; // Input must be at least equal to output
        uint256 high = outputAmount * 2; // Initial upper bound
        uint256 x = outputAmount; // Default to equal (no slippage case)
        
        // Binary search for 64 iterations
        for (uint256 i = 0; i < 64; i++) {
            x = (low + high) / 2;
            
            // Compute output for this input
            uint256 y = computeOutputAmount(x, liquidity);
            
            // If output is too small, decrease input (move high down)
            // If output is too large, increase input (move low up)
            if (y < outputAmount) {
                low = x;
            } else if (y > outputAmount) {
                high = x;
            } else {
                // Exact match found
                break;
            }
        }
        
        // Ensure input is greater than output (due to slippage)
        return x > outputAmount ? x : outputAmount + 1;
    }

    // Compute price impact as a percentage (scaled by SCALE)
    function computePriceImpact(
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 liquidity
    ) public pure returns (uint256) {
        require(inputAmount > 0, "Invalid input amount");
        
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
