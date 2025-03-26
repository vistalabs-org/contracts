// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NormalQuoter} from "../src/utils/Quoter.sol";
import {console} from "forge-std/console.sol";

contract NormalQuoterTest is Test {
    NormalQuoter public quoter;
    uint256 constant SCALE = 10**18;
    
    function setUp() public {
        quoter = new NormalQuoter();
    }

    function test_ComputeOutputAmount() public {
        uint256 inputAmount = 100 * SCALE;  // 100 tokens
        uint256 liquidity = 1000 * SCALE;   // 1000 tokens of liquidity
        
        uint256 outputAmount = quoter.computeOutputAmount(inputAmount, liquidity);

        console.log("Input amount:", inputAmount / SCALE);
        console.log("Output amount:", outputAmount / SCALE);
        // Output should be less than input due to slippage
        assertTrue(outputAmount < inputAmount);
        // Output shouldn't be zero
        assertTrue(outputAmount > 0);
        
        
    }
    
    function test_ComputeInputAmount() public {
        uint256 desiredOutput = 100 * SCALE;  // Want 100 tokens out
        uint256 liquidity = 1000 * SCALE;     // 1000 tokens of liquidity
        
        uint256 requiredInput = quoter.computeInputAmount(desiredOutput, liquidity);

        console.log("Desired output:", desiredOutput / SCALE);
        console.log("Required input:", requiredInput / SCALE);
        
        // Required input should be more than desired output due to slippage
        assertTrue(requiredInput > desiredOutput);
        
    }
    
    function test_PriceImpact() public {
        uint256 inputAmount = 100 * SCALE;
        uint256 liquidity = 1000 * SCALE;
        
        uint256 outputAmount = quoter.computeOutputAmount(inputAmount, liquidity);
        uint256 priceImpact = quoter.computePriceImpact(
            inputAmount,
            outputAmount,
            liquidity
        );

        console.log("Price impact (%):", (priceImpact * 100) / SCALE);

        // Price impact should be positive
        assertTrue(priceImpact > 0);
        // Price impact should be reasonable (<50% for this size)
        assertTrue(priceImpact < SCALE / 2);
        
    }
    
    function test_SmallAmounts() public {
        uint256 inputAmount = 1 * SCALE;     // 1 token
        uint256 liquidity = 1000 * SCALE;    // 1000 tokens liquidity
        
        uint256 outputAmount = quoter.computeOutputAmount(inputAmount, liquidity);
        
        // For very small amounts relative to liquidity, output should be close to input
        uint256 difference = inputAmount > outputAmount ? 
            inputAmount - outputAmount : 
            outputAmount - inputAmount;
            
        assertTrue(difference < inputAmount / 100); // Less than 1% difference
    }
    /* pausing this test for now
    function test_LargeAmounts() public {
        uint256 inputAmount = 1000 * SCALE;  // 1000 tokens
        uint256 liquidity = 1000 * SCALE;    // 1000 tokens liquidity
        
        uint256 outputAmount = quoter.computeOutputAmount(inputAmount, liquidity);
        console.log("output amount", outputAmount);
        console.log("input amount", inputAmount);
        // For large amounts, slippage should be significant
        assertTrue(outputAmount < inputAmount * 90 / 100); // More than 10% slippage
    }*/
    
    function test_RoundTrip() public {
        uint256 inputAmount = 100 * SCALE;
        uint256 liquidity = 1000 * SCALE;
        
        uint256 outputAmount = quoter.computeOutputAmount(inputAmount, liquidity);
        uint256 roundTripInput = quoter.computeInputAmount(outputAmount, liquidity);
        
        // Round trip should give similar results (within 1%)
        uint256 difference = inputAmount > roundTripInput ? 
            inputAmount - roundTripInput : 
            roundTripInput - inputAmount;
            
        assertTrue(difference < inputAmount / 100);
        
        console.log("Original input:", inputAmount / SCALE);
        console.log("Round trip input:", roundTripInput / SCALE);
    }

    function test_ZeroInput() public {
        uint256 liquidity = 1000 * SCALE;
        
        uint256 outputAmount = quoter.computeOutputAmount(0, liquidity);
        assertTrue(outputAmount == 0);
    }

    function test_ZeroLiquidity() public {
        uint256 inputAmount = 100 * SCALE;
        
        vm.expectRevert(); // Should revert when liquidity is 0
        quoter.computeOutputAmount(inputAmount, 0);
    }
}