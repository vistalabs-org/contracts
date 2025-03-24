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



}
