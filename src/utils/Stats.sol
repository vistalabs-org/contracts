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
        uint256 xAbs = uint256(x < 0 ? -x : x);
        console.log("xAbs", xAbs);
        
        // Scale down x before dividing by sqrt(2)
        uint256 z = (xAbs * SCALE) / SQRT_2; // x / sqrt(2)
        console.log("z", z);
        
        // Scale down z before passing to erf
        z = z / SCALE;
        
        uint256 erfValue = erf(z);
        console.log("erfValue", erfValue);
        
        uint256 result = (SCALE + erfValue) / 2; // (1 + erf)/2
        console.log("result", result);
        
        return x < 0 ? SCALE - result : result; // Symmetry for negative x
    }

    // Approximate erf(x) using a polynomial approximation
    function erf(uint256 x) internal pure returns (uint256) {
        // Use a polynomial approximation for erf
        // erf(x) ≈ sign(x) * (1 - 1/(1 + p*|x|)^4)
        // where p = 0.47047
        
        uint256 p = 470470000000000000; // 0.47047 * 10^18
        
        // Calculate p*|x|
        uint256 px = (p * x) / SCALE;
        
        // Calculate 1 + p*|x|
        uint256 denominator = SCALE + px;
        
        // Calculate (1 + p*|x|)^4
        uint256 denomPower = denominator;
        for (uint i = 0; i < 3; i++) {
            denomPower = (denomPower * denominator) / SCALE;
        }
        
        // Calculate 1/(1 + p*|x|)^4
        uint256 fraction = (SCALE * SCALE) / denomPower;
        
        // Calculate 1 - 1/(1 + p*|x|)^4
        return SCALE - fraction;
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