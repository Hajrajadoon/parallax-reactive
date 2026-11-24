// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { ParallaxMath } from "../src/ParallaxMath.sol";

contract ParallaxMathHarness {
    function amountOut(uint256 a, uint256 rIn, uint256 rOut) external pure returns (uint256) {
        return ParallaxMath.getAmountOut(a, rIn, rOut);
    }

    function optimal(uint256 in1, uint256 out1, uint256 in2, uint256 out2) external pure returns (uint256) {
        return ParallaxMath.optimalArbInput(in1, out1, in2, out2);
    }

    function spread(uint256 bA, uint256 qA, uint256 bB, uint256 qB) external pure returns (uint256) {
        return ParallaxMath.spreadBps(bA, qA, bB, qB);
    }

    function sqrt(uint256 y) external pure returns (uint256) {
        return ParallaxMath.sqrt(y);
    }
}

contract ParallaxMathTest is Test {
    ParallaxMathHarness internal m;

    function setUp() public {
        m = new ParallaxMathHarness();
    }

    /// quote --cheap pool--> base --rich pool--> quote
    function _profit(uint256 dx, uint256 cq, uint256 cb, uint256 rb, uint256 rq) internal view returns (int256) {
        uint256 baseOut = m.amountOut(dx, cq, cb);
        uint256 quoteOut = m.amountOut(baseOut, rb, rq);
        return int256(quoteOut) - int256(dx);
    }

    function test_noArbWhenPricesEqual() public view {
        assertEq(m.optimal(300_000 ether, 100 ether, 100 ether, 300_000 ether), 0);
    }

    function test_noArbInsideFeeBand() public view {
        // 0.4% gap < 0.6% round-trip fees
        assertEq(m.optimal(300_000 ether, 100 ether, 100 ether, 301_200 ether), 0);
    }

    function test_optimalBeatsNeighbours() public view {
        uint256 cq = 272_802 ether;
        uint256 cb = 110 ether; // cheap: ~2,480
        uint256 rb = 100 ether;
        uint256 rq = 300_000 ether; // rich: 3,000
        uint256 dx = m.optimal(cq, cb, rb, rq);
        assertGt(dx, 0);
        int256 best = _profit(dx, cq, cb, rb, rq);
        assertGt(best, 0);
        assertGe(best, _profit((dx * 99) / 100, cq, cb, rb, rq));
        assertGe(best, _profit((dx * 101) / 100, cq, cb, rb, rq));
        assertGe(best, _profit(dx / 2, cq, cb, rb, rq));
        assertGe(best, _profit(dx * 2, cq, cb, rb, rq));
    }

    function testFuzz_optimalIsLocalMaximum(uint96 cqRaw, uint96 cbRaw, uint96 rbRaw, uint96 rqRaw) public view {
        uint256 cq = bound(uint256(cqRaw), 1_000 ether, 10_000_000 ether);
        uint256 cb = bound(uint256(cbRaw), 1 ether, 10_000 ether);
        uint256 rb = bound(uint256(rbRaw), 1 ether, 10_000 ether);
        uint256 rq = bound(uint256(rqRaw), 1_000 ether, 10_000_000 ether);
        uint256 dx = m.optimal(cq, cb, rb, rq);
        if (dx < 1e12) return; // nothing meaningful to compare
        int256 best = _profit(dx, cq, cb, rb, rq);
        assertGe(best, 0);
        // 1% either side can't be meaningfully better (allow 1 wei-per-unit rounding slack)
        int256 slack = int256(dx / 1e12) + 2;
        assertGe(best + slack, _profit((dx * 99) / 100, cq, cb, rb, rq));
        assertGe(best + slack, _profit((dx * 101) / 100, cq, cb, rb, rq));
    }

    function test_spreadBps() public view {
        assertEq(m.spread(100 ether, 300_000 ether, 100 ether, 300_000 ether), 0);
        // 3,000 vs 3,030 -> 100 bps
        assertEq(m.spread(100 ether, 300_000 ether, 100 ether, 303_000 ether), 100);
        assertEq(m.spread(100 ether, 303_000 ether, 100 ether, 300_000 ether), 100);
    }

    function test_sqrt() public view {
        assertEq(m.sqrt(0), 0);
        assertEq(m.sqrt(1), 1);
        assertEq(m.sqrt(3), 1);
        assertEq(m.sqrt(4), 2);
        assertEq(m.sqrt(1e36), 1e18);
        assertEq(m.sqrt(type(uint256).max), 340282366920938463463374607431768211455);
    }
}
