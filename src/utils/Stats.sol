// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
contract NormalDistribution {
    uint256 constant SCALE = 10**18;
    uint256 constant SQRT_2PI = 398942280000000000; // 1/sqrt(2π) * 10^18
    uint256 constant SQRT_2 = 1414213562000000000; // sqrt(2) * 10^18

    // Factorials for Taylor series: 0!, 1!, 2!, 3!, 4!, 5!
    uint256[] FACTORIALS = [1, 1, 2, 6, 24, 120];

    // Approximate e^(-x) using Taylor series (up to 5 terms)
    function expNeg(uint256 x) internal pure returns (uint256) {
        uint256 xScaled = (x * SCALE) / 1e18; // Adjust input scale
        uint256 result = SCALE; // 1.0
        uint256 term = SCALE;   // Current term starts at 1.0
        for (uint256 n = 1; n <= 5; n++) {
            term = (term * xScaled) / (n * SCALE); // Next term: x^n / n!
            if (n % 2 == 0) {
                result += term;
            } else {
                result -= term;
            }
        }
        return result;
    }

    // PDF of standard normal: (1/sqrt(2π)) * e^(-x^2 / 2)
    function normalPDF(int256 x) public pure returns (uint256) {
        uint256 xAbs = uint256(x < 0 ? -x : x); // Handle negative x (symmetric)
        
        // Scale down x first to prevent overflow

        uint256 xScaled = xAbs / SCALE;
        uint256 xSquared = (xScaled * xScaled); // x^2 (already scaled)
        console.log("xSquared", xSquared);
        
        // Now exponent is x^2/2 (already scaled appropriately)
        uint256 exponent = xSquared / 2;
        console.log("exponent", exponent);
        uint256 expResult = expNeg(exponent);
        console.log("expResult", expResult);
        // Final scaling for the result
        return (SQRT_2PI * expResult) / SCALE;
    }

    // CDF of standard normal
    function normalCDF(int256 x) public view returns (uint256) {
        // For simplicity, let's use a direct approximation of the normal CDF
        // Φ(x) ≈ 0.5 * (1 + tanh(√(π/8) * x))
        
        uint256 xAbs = uint256(x < 0 ? -x : x);
        console.log("xAbs", xAbs);
        
        // √(π/8) ≈ 0.626657
        uint256 factor = 626657000000000000;
        
        // Calculate √(π/8) * x
        uint256 t = (factor * xAbs) / SCALE;
        console.log("t", t);
        
        // Better approximation for tanh(t) that saturates for large values
        uint256 tanhValue;
        if (t > 3 * SCALE) {
            // For large t, tanh(t) approaches 1
            tanhValue = SCALE - SCALE/10000; // 0.9999
        } else {
            // For smaller t, use rational approximation
            // tanh(t) ≈ t / (1 + t²/3)
            uint256 tSquared = (t * t) / SCALE;
            uint256 denominator = SCALE + (tSquared / 3);
            tanhValue = (t * SCALE) / denominator;
        }
        console.log("tanhValue", tanhValue);
        
        // Calculate 0.5 * (1 + tanh) or 0.5 * (1 - tanh) depending on sign of x
        uint256 result;
        if (x < 0) {
            // For negative x: 0.5 * (1 - tanh)
            result = (SCALE - tanhValue) / 2;
        } else {
            // For positive x: 0.5 * (1 + tanh)
            result = (SCALE + tanhValue) / 2;
        }
        console.log("result", result);
        
        return result;
    }

    // Approximate erf(x) using a simpler approximation
    function erf(uint256 x) internal pure returns (uint256) {
        // Use Abramowitz and Stegun approximation 7.1.26
        // erf(x) ≈ 1 - 1/((1 + a₁x + a₂x² + a₃x³ + a₄x⁴)⁴)
        // where a₁ = 0.254829592, a₂ = -0.284496736, a₃ = 1.421413741, a₄ = -1.453152027, a₅ = 1.061405429
        
        // We'll use a simpler approximation: erf(x) ≈ tanh(1.2 * x)
        
        // First, scale down x to prevent overflow
        uint256 scaledX = x / 1e12;
        
        // Calculate 1.2 * x
        uint256 t = (12 * scaledX) / 10;
        
        // Simple approximation for tanh(t) that works for small t
        // tanh(t) ≈ t / (1 + t²/3)
        uint256 tSquared = (t * t) / SCALE;
        uint256 denominator = SCALE + (tSquared / 3);
        uint256 result = (t * SCALE) / denominator;
        
        // Scale result back up
        return result;
    }

    // General normal CDF with mean (mu) and std dev (sigma)
    function normalCDFGeneral(int256 x, int256 mu, uint256 sigma) public view returns (uint256) {
        // Prevent division by zero
        require(sigma > 0, "Sigma must be positive");
        
        // Calculate (x - mu) first
        int256 diff = x - mu;
        
        // Then scale and divide by sigma in two steps to prevent overflow
        int256 z = (diff / int256(sigma)) * int256(SCALE);
        
        // Add any remaining precision
        z += ((diff % int256(sigma)) * int256(SCALE)) / int256(sigma);
        
        return normalCDF(z);
    }
}