// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NormalQuoter} from "../src/utils/Quoter.sol";
import {console} from "forge-std/console.sol";

contract NormalQuoterTest is Test {
    NormalQuoter public quoter;
    uint256 constant LIQUIDITY = 1000 * 1e18; // 1.0 liquidity parameter
    uint256 constant INITIAL_RESERVE0 = 39893939394 * 1e10; // approx x = y point is the starting point
    uint256 constant INITIAL_RESERVE1 = 398945166875987801370; // approx x = y point is the starting point

    function setUp() public {
        quoter = new NormalQuoter();
    }

    function test_ComputeReserve1FromReserve0() public {
        //398.93939394 398.9393939
        uint256 reserve0 = INITIAL_RESERVE0; 
        
        // Compute reserve1 from reserve0
        uint256 reserve1 = quoter.computeReserve1FromReserve0(reserve0, LIQUIDITY);
        
        console.log("Reserve0:", reserve0 );
        console.log("Computed Reserve1:", reserve1 );
        
        // Reserve1 should be close to reserve0 for our model
        uint256 difference = reserve0 > reserve1 ? reserve0 - reserve1 : reserve1 - reserve0;
        assertTrue(difference < reserve0 / 10, "Reserves should be within 10% of each other");
        
        // Now compute reserve0 from reserve1
        uint256 computedReserve0 = quoter.computeReserve0FromReserve1(reserve1, LIQUIDITY);
        
        console.log("Reserve1:", reserve1 );
        console.log("Computed Reserve0:", computedReserve0 );
        
        // The computed reserve0 should be close to the original reserve0
        difference = reserve0 > computedReserve0 ? reserve0 - computedReserve0 : computedReserve0 - reserve0;
        console.log("Difference:", difference);
        assertTrue(difference < reserve0 / 100, "Round trip computation should be accurate within 1%");
    }

    function test_negativeRelationBetweenReserve0AndReserve1() public {
        uint256 reserve0 = INITIAL_RESERVE0;
        uint256 reserve1 = quoter.computeReserve1FromReserve0(reserve0, LIQUIDITY);

        // add 10 to reserve0, reserve1 should decrease
        reserve0 += 10 * 1e18;
        reserve1 = quoter.computeReserve1FromReserve0(reserve0, LIQUIDITY);
        assertTrue(reserve1 < INITIAL_RESERVE1, "Reserve1 should decrease when reserve0 increases");
    }

    function test_ComputeOutputAmount() public {
        uint256 reserve0 = INITIAL_RESERVE0; // 100 tokens of reserve0
        uint256 reserve1 = quoter.computeReserve1FromReserve0(reserve0, LIQUIDITY); // Compute matching reserve1
        uint256 inputAmount = 10 * 1e18; // 10 tokens input
        
        // Compute output amount for swapping token0 for token1
        int256 outputAmount = int256(quoter.computeOutputAmount(reserve0, reserve1, inputAmount, LIQUIDITY, true));
        
        console.log("Input amount:", inputAmount );
        console.log("Output amount:", uint256(outputAmount));
        
        // Output should be less than input due to slippage
        assertTrue(outputAmount < int256(inputAmount), "Output should be less than input");
        // Output shouldn't be zero
        assertTrue(outputAmount > 0, "Output shouldn't be zero");
    
    }

    function test_ComputeOutputAmountReverse() public {
        uint256 reserve1 = INITIAL_RESERVE1; // 1000 tokens of reserve0
        uint256 reserve0 = quoter.computeReserve0FromReserve1(reserve1, LIQUIDITY); // Compute matching reserve1
        uint256 inputAmount = 10 * 1e18; // 10 tokens input
        int256 outputAmount = int256(quoter.computeOutputAmount(reserve0, reserve1, inputAmount, LIQUIDITY, false));
        console.log("Input amount:", inputAmount );
        console.log("Output amount:", outputAmount);
    }

    function test_SmallAmounts() public {
        uint256 reserve0 = INITIAL_RESERVE0; // 1000 tokens of reserve0
        uint256 reserve1 = quoter.computeReserve1FromReserve0(reserve0, LIQUIDITY); // Compute matching reserve1
        uint256 inputAmount = 1 * 1e18; // 1 token input
        
        // For very small amounts relative to reserves, output should be close to input
        int256 outputAmount = int256(quoter.computeOutputAmount(reserve0, reserve1, inputAmount, LIQUIDITY, true));
        
        console.log("Small input amount:", inputAmount);
        console.log("Small output amount:", uint256(outputAmount));
        
        uint256 difference;
        if (int256(inputAmount) > outputAmount) {
            difference = inputAmount - uint256(outputAmount);
        } else {
            difference = uint256(outputAmount) - inputAmount;
        }
        assertTrue(difference < inputAmount / 10, "Small amounts should have less than 10% slippage");
    }
    /*
    function test_LargeAmounts() public {
        uint256 reserve0 = INITIAL_RESERVE0; // 100 tokens of reserve0
        uint256 reserve1 = quoter.computeReserve1FromReserve0(reserve0, LIQUIDITY); // Compute matching reserve1
        uint256 inputAmount = 200 * 1e18; // 50 tokens input (50% of reserve)
        
        // For large amounts, slippage should be significant
        int256 outputAmount = int256(quoter.computeOutputAmount(reserve0, reserve1, inputAmount, LIQUIDITY, true));
        
        console.log("Large input amount:", inputAmount);
        console.log("Large output amount:", uint256(outputAmount));
        
        // Slippage should be significant for large amounts
        assertTrue(uint256(outputAmount) < inputAmount * 95 / 100, "Large amounts should have more than 10% slippage");
    }*/

    function test_ZeroInput() public {
        uint256 reserve0 = INITIAL_RESERVE0;
        uint256 reserve1 = quoter.computeReserve1FromReserve0(reserve0, LIQUIDITY);
        
        int256 outputAmount = int256(quoter.computeOutputAmount(reserve0, reserve1, 0, LIQUIDITY, true));
        assertTrue(outputAmount == 0, "Zero input should give zero output");
    }

    function test_ZeroLiquidity() public {
        uint256 reserve0 = 100 * 10**6;
        uint256 reserve1 = 100 * 10**6;
        
        vm.expectRevert(); // Should revert when liquidity is 0
        quoter.computeOutputAmount(reserve0, reserve1, 10 * 10**6, 0, true);
    }

}
