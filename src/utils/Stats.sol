// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
        uint256 xSquared = (xAbs * xAbs) / SCALE; // x^2
        uint256 exponent = (xSquared * SCALE) / 2; // x^2 / 2
        uint256 expResult = expNeg(exponent);
        return (SQRT_2PI * expResult) / SCALE;
    }

    // Approximate erf(x) using Taylor series
    function erf(uint256 x) internal view returns (uint256) {
        uint256 xScaled = (x * SCALE) / 1e18;
        uint256 sum = 0;
        uint256 term = xScaled; // First term: x
        for (uint256 n = 0; n < 5; n++) {
            sum += term / ((2 * n + 1) * FACTORIALS[n]);
            term = (term * xScaled * xScaled) / ((n + 1) * SCALE); // Next term
            if (n % 2 == 1) term = 0 - term; // Alternate signs
        }
        return (2 * sum * SCALE) / 1772453850; // 2/sqrt(π) ≈ 1.128379167 * 10^18
    }

    // CDF of standard normal
    function normalCDF(int256 x) public view returns (uint256) {
        uint256 xAbs = uint256(x < 0 ? -x : x);
        uint256 z = (xAbs * SCALE) / SQRT_2; // x / sqrt(2)
        uint256 erfValue = erf(z);
        uint256 result = (SCALE + erfValue) / 2; // (1 + erf)/2
        return x < 0 ? SCALE - result : result; // Symmetry for negative x
    }

    // General normal CDF with mean (mu) and std dev (sigma)
    function normalCDFGeneral(int256 x, int256 mu, uint256 sigma) public view returns (uint256) {
        int256 z = ((x - mu) * int256(SCALE)) / int256(sigma); // (x - mu) / sigma
        return normalCDF(z);
    }
}