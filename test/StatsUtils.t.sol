// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NormalDistribution} from "../src/utils/Stats.sol";
import {console} from "forge-std/console.sol";

contract StatsTest is Test {
    NormalDistribution public normalDist;
    uint256 constant SCALE = 10**18;
    
    function setUp() public {
        normalDist = new NormalDistribution();
    }

    function test_NormalPDF_Zero() public {
        // PDF at x=0 should be 1/sqrt(2π) ≈ 0.3989...
        uint256 pdf = normalDist.normalPDF(0);
        
        // Expected value is approximately 0.3989 * 10^18
        uint256 expected = 398942280000000000;
        uint256 tolerance = 1e16; // Allow 1% error
        
        assertApproxEqAbs(pdf, expected, tolerance);
        console.log("PDF at x=0:", pdf);
    }

    
    
    function test_NormalPDF_Symmetry() public {
        // PDF should be symmetric: f(x) = f(-x)
        int256 x = 1 * int256(SCALE); // x = 1.0
        
        uint256 pdfPos = normalDist.normalPDF(x);
        uint256 pdfNeg = normalDist.normalPDF(-x);
        
        assertEq(pdfPos, pdfNeg);
        console.log("PDF at x=1:", pdfPos);
        console.log("PDF at x=-1:", pdfNeg);
    }
    
    function test_NormalPDF_Decreasing() public {
        // PDF should decrease as |x| increases
        uint256 pdf0 = normalDist.normalPDF(0);
        console.log("pdf0", pdf0);
        uint256 pdf1 = normalDist.normalPDF(int256(2*SCALE)); // x = 1.0
        console.log("pdf1", pdf1);
        uint256 pdf2 = normalDist.normalPDF(int256(3 * SCALE)); // x = 2.0
        console.log("pdf2", pdf2);
        
        assertTrue(pdf0 > pdf1);
        assertTrue(pdf1 > pdf2);
        
        console.log("PDF at x=0:", pdf0);
        console.log("PDF at x=1:", pdf1);
        console.log("PDF at x=2:", pdf2);
    }
    
    function test_NormalCDF_Range() public {
        // CDF should be between 0 and 1
        int256[] memory testValues = new int256[](5);
        testValues[0] = -3 * int256(SCALE); // x = -3.0
        testValues[1] = -1 * int256(SCALE); // x = -1.0
        testValues[2] = 0;                  // x = 0.0
        testValues[3] = 1 * int256(SCALE);  // x = 1.0
        testValues[4] = 3 * int256(SCALE);  // x = 3.0
        
        for (uint i = 0; i < testValues.length; i++) {
            uint256 cdf = normalDist.normalCDF(testValues[i]);
            assertTrue(cdf >= 0 && cdf <= SCALE);
        }
    }
    
    function test_NormalCDF_Zero() public {
        // CDF at x=0 should be 0.5
        uint256 cdf = normalDist.normalCDF(0);
        
        uint256 expected = SCALE / 2; // 0.5 * 10^18
        uint256 tolerance = 1e16; // Allow 1% error
        
        assertApproxEqAbs(cdf, expected, tolerance);
        console.log("CDF at x=0:", cdf);
    }
    
    function test_NormalCDF_Increasing() public {
        // CDF should be strictly increasing
        int256[] memory testValues = new int256[](4);
        testValues[0] = -2 * int256(SCALE); // x = -2.0
        testValues[1] = -1 * int256(SCALE); // x = -1.0
        testValues[2] = 1 * int256(SCALE);  // x = 1.0
        testValues[3] = 2 * int256(SCALE);  // x = 2.0
        
        uint256 prevCdf = 0;
        for (uint i = 0; i < testValues.length; i++) {
            uint256 cdf = normalDist.normalCDF(testValues[i]);
            if (i > 0) {
                assertTrue(cdf > prevCdf);
            }
            prevCdf = cdf;
        }
    }
    /*
    function test_NormalCDF_Symmetry() public {
        // CDF should have the property: CDF(-x) = 1 - CDF(x)
        int256 x = 1 * int256(SCALE); // x = 1.0
        
        uint256 cdfPos = normalDist.normalCDF(x);
        uint256 cdfNeg = normalDist.normalCDF(-x);
        
        uint256 tolerance = 1e16; // Allow 1% error
        assertApproxEqAbs(cdfNeg, SCALE - cdfPos, tolerance);
        
        console.log("CDF at x=1:", cdfPos);
        console.log("CDF at x=-1:", cdfNeg);
        console.log("1 - CDF(1):", SCALE - cdfPos);
    }
    
    function test_NormalCDF_LargeValues() public {
        // CDF should approach 0 for large negative values
        // and approach 1 for large positive values
        int256 largeNeg = -5 * int256(SCALE); // x = -5.0
        int256 largePos = 5 * int256(SCALE);  // x = 5.0
        
        uint256 cdfNeg = normalDist.normalCDF(largeNeg);
        uint256 cdfPos = normalDist.normalCDF(largePos);
        
        assertTrue(cdfNeg < SCALE / 100);     // Should be close to 0
        assertTrue(cdfPos > SCALE - SCALE / 100); // Should be close to 1
        
        console.log("CDF at x=-5:", cdfNeg);
        console.log("CDF at x=5:", cdfPos);
    }
    
    function test_NormalCDFGeneral() public {
        // Test with different mean and standard deviation
        int256 x = 2 * int256(SCALE);     // x = 2.0
        int256 mu = 1 * int256(SCALE);    // mean = 1.0
        uint256 sigma = 2 * SCALE;        // std dev = 2.0
        
        uint256 cdfGeneral = normalDist.normalCDFGeneral(x, mu, sigma);
        uint256 cdfStandard = normalDist.normalCDF(int256(SCALE) / 2); // (2-1)/2 = 0.5
        
        uint256 tolerance = 1e16; // Allow 1% error
        assertApproxEqAbs(cdfGeneral, cdfStandard, tolerance);
        
        console.log("General CDF at x=2, mean=1, stddev=2:", cdfGeneral);
        console.log("Standard CDF at z=0.5:", cdfStandard);
    }
    
    function test_NormalCDFGeneral_Shift() public {
        // Test that shifting x and μ by the same amount doesn't change the result
        int256 x1 = 2 * int256(SCALE);    // x = 2.0
        int256 mu1 = 1 * int256(SCALE);   // mean = 1.0
        uint256 sigma = 2 * SCALE;        // std dev = 2.0
        
        int256 shift = 3 * int256(SCALE); // shift by 3.0
        int256 x2 = x1 + shift;           // x = 5.0
        int256 mu2 = mu1 + shift;         // mean = 4.0
        
        uint256 cdf1 = normalDist.normalCDFGeneral(x1, mu1, sigma);
        uint256 cdf2 = normalDist.normalCDFGeneral(x2, mu2, sigma);
        
        uint256 tolerance = 1e16; // Allow 1% error
        assertApproxEqAbs(cdf1, cdf2, tolerance);
        
        console.log("CDF at x=2, mean=1, stddev=2:", cdf1);
        console.log("CDF at x=5, mean=4, stddev=2:", cdf2);
    }
    
    function test_NormalCDFGeneral_Scale() public {
        // Test that scaling x, μ, and σ proportionally doesn't change the result
        int256 x1 = 2 * int256(SCALE);    // x = 2.0
        int256 mu1 = 1 * int256(SCALE);   // mean = 1.0
        uint256 sigma1 = 2 * SCALE;       // std dev = 2.0
        
        uint256 factor = 3;               // scale by 3
        int256 x2 = x1 * int256(factor);  // x = 6.0
        int256 mu2 = mu1 * int256(factor); // mean = 3.0
        uint256 sigma2 = sigma1 * factor; // std dev = 6.0
        
        uint256 cdf1 = normalDist.normalCDFGeneral(x1, mu1, sigma1);
        uint256 cdf2 = normalDist.normalCDFGeneral(x2, mu2, sigma2);
        
        uint256 tolerance = 1e16; // Allow 1% error
        assertApproxEqAbs(cdf1, cdf2, tolerance);
        
        console.log("CDF at x=2, mean=1, stddev=2:", cdf1);
        console.log("CDF at x=6, mean=3, stddev=6:", cdf2);
    }*/
}
