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
        uint256 reserve1after = quoter.computeReserve1FromReserve0(reserve0, LIQUIDITY);
        assertTrue(reserve1after < reserve1, "Reserve1 should decrease when reserve0 increases");
    }

    function test_ZeroInput() public {
        uint256 reserve0 = INITIAL_RESERVE0;
        uint256 reserve1 = quoter.computeReserve1FromReserve0(reserve0, LIQUIDITY);
        
        (int256 inputDelta, int256 outputDelta) = quoter.computeDeltas(reserve0, reserve1, 0, LIQUIDITY, true);
        assertTrue(inputDelta == 0, "Zero input should give zero input");
        assertTrue(outputDelta == 0, "Zero input should give zero output");
    }

    function test_ZeroLiquidity() public {
        uint256 reserve0 = 100 * 10**6;
        uint256 reserve1 = 100 * 10**6;
        
        vm.expectRevert(); // Should revert when liquidity is 0
        quoter.computeDeltas(reserve0, reserve1, 10 * 10**6, 0, true);
    }

    function test_ComputeDeltas() public {
        uint256 reserve0 = INITIAL_RESERVE0; // Initial reserve0
        uint256 reserve1 = quoter.computeReserve1FromReserve0(reserve0, LIQUIDITY); // Compute matching reserve1
        uint256 inputAmount = 10 * 1e18; // 10 tokens input
        
        // Compute deltas for swapping token0 for token1
        (int256 inputDelta, int256 outputDelta) = quoter.computeDeltas(
            reserve0, 
            reserve1, 
            inputAmount, 
            LIQUIDITY, 
            true
        );
        
        console.log("Input amount:", inputAmount);
        console.log("Input delta:", inputDelta);
        console.log("Output delta:", outputDelta);
        
        // Input delta should be positive and equal to input amount
        assertEq(inputDelta, int256(inputAmount), "Input delta should equal input amount");
        
        // Output delta should be negative
        assertTrue(outputDelta < 0, "Output delta should be negative");
        
        // Absolute value of output delta should be less than input (due to slippage)
        assertTrue(-outputDelta < inputDelta, "Absolute output delta should be less than input delta");
        
        // Output shouldn't be zero
        assertTrue(outputDelta != 0, "Output delta shouldn't be zero");
    }

    function test_ComputeDeltasReverse() public {
        uint256 reserve1 = INITIAL_RESERVE1; // Initial reserve1
        uint256 reserve0 = quoter.computeReserve0FromReserve1(reserve1, LIQUIDITY); // Compute matching reserve0
        uint256 inputAmount = 10 * 1e18; // 10 tokens input
        
        // Compute deltas for swapping token1 for token0
        (int256 inputDelta, int256 outputDelta) = quoter.computeDeltas(
            reserve1, 
            reserve0, 
            inputAmount, 
            LIQUIDITY, 
            false
        );
        
        console.log("Input amount:", inputAmount);
        console.log("Input delta:", inputDelta);
        console.log("Output delta:", outputDelta);
        
        // Input delta should be positive and equal to input amount
        assertEq(inputDelta, int256(inputAmount), "Input delta should equal input amount");
        
        // Output delta should be negative
        assertTrue(outputDelta < 0, "Output delta should be negative");
        
        // Absolute value of output delta should be less than input (due to slippage)
        assertTrue(-outputDelta < inputDelta, "Absolute output delta should be less than input delta");
        
        // Output shouldn't be zero
        assertTrue(outputDelta != 0, "Output delta shouldn't be zero");
    }

    function test_SmallAmountsDeltas() public {
        uint256 reserve0 = INITIAL_RESERVE0; // Initial reserve0
        uint256 reserve1 = quoter.computeReserve1FromReserve0(reserve0, LIQUIDITY); // Compute matching reserve1
        uint256 inputAmount = 1 * 1e18; // 1 token input
        
        // For very small amounts relative to reserves, output should be close to input
        (int256 inputDelta, int256 outputDelta) = quoter.computeDeltas(
            reserve0, 
            reserve1, 
            inputAmount, 
            LIQUIDITY, 
            true
        );
        
        console.log("Small input amount:", inputAmount);
        console.log("Small input delta:", inputDelta);
        console.log("Small output delta:", outputDelta);
        
        // For small amounts, output delta should be close to input delta in magnitude
        uint256 difference = uint256(inputDelta + outputDelta); // Since outputDelta is negative
        assertTrue(difference < uint256(inputDelta) / 10, "Small amounts should have less than 10% slippage");
    }

    function test_ZeroInputDeltas() public {
        uint256 reserve0 = INITIAL_RESERVE0;
        uint256 reserve1 = quoter.computeReserve1FromReserve0(reserve0, LIQUIDITY);
        
        (int256 inputDelta, int256 outputDelta) = quoter.computeDeltas(
            reserve0, 
            reserve1, 
            0, 
            LIQUIDITY, 
            true
        );
        
        assertTrue(inputDelta == 0, "Zero input should give zero input delta");
        assertTrue(outputDelta == 0, "Zero input should give zero output delta");
    }

    function test_ZeroLiquidityDeltas() public {
        uint256 reserve0 = 100 * 10**6;
        uint256 reserve1 = 100 * 10**6;
        
        vm.expectRevert(); // Should revert when liquidity is 0
        quoter.computeDeltas(reserve0, reserve1, 10 * 10**6, 0, true);
    }

}
