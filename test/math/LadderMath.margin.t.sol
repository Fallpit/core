// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LadderMathBase} from "./LadderMathBase.sol";
import {LadderMathHarness} from "./LadderMathHarness.sol";

/// @notice Proof by vectors that every rounding goes against the trader. margin.json holds exact integer
///         inputs (prior, depths, state, trade) and the true cost C(v) and cost difference computed with 90
///         digits. The harness prices the same integers, so the comparison is to the wei.
contract LadderMathMarginTest is LadderMathBase {
    struct Vectors {
        uint256[] pi;
        uint256[] b0;
        uint256[] g;
        int256[] v;
        uint256[] lo;
        uint256[] hi;
        int256[] delta;
        int256[] c0Floor;
        int256[] c1Floor;
        uint256[] diffFloor;
        uint256[] diffCeil;
    }

    function _load() internal view returns (Vectors memory s) {
        string memory json = vm.readFile("test/vectors/margin.json");
        s.pi = vm.parseJsonUintArray(json, ".pi");
        s.b0 = vm.parseJsonUintArray(json, ".b0");
        s.g = vm.parseJsonUintArray(json, ".g");
        s.v = vm.parseJsonIntArray(json, ".v");
        s.lo = vm.parseJsonUintArray(json, ".lo");
        s.hi = vm.parseJsonUintArray(json, ".hi");
        s.delta = vm.parseJsonIntArray(json, ".delta");
        s.c0Floor = vm.parseJsonIntArray(json, ".c0Floor");
        s.c1Floor = vm.parseJsonIntArray(json, ".c1Floor");
        s.diffFloor = vm.parseJsonUintArray(json, ".diffFloor");
        s.diffCeil = vm.parseJsonUintArray(json, ".diffCeil");
    }

    function _trade(Vectors memory s, uint256 i) internal view returns (LadderMathHarness.Trade memory) {
        return math.tradeGiven(
            _slice(s.v, i),
            _slice(s.pi, i),
            _slice(s.b0, i),
            s.g[i],
            uint8(s.lo[i]),
            uint8(s.hi[i]),
            s.delta[i]
        );
    }

    /// @dev The true C(v) lies in [floor, floor + 1). It must lie inside [cost - slack, cost + slack].
    function _assertInsideSlack(int256 cost, uint256 slack, int256 trueFloor)
        internal
        pure
        returns (uint256 used)
    {
        assertLe(cost - int256(slack), trueFloor, "true cost below cost - slack");
        assertGe(cost + int256(slack), trueFloor + 1, "true cost above cost + slack");
        // share of the slack actually used, in 1e-4
        uint256 off = cost > trueFloor ? uint256(cost - trueFloor) : uint256(trueFloor + 1 - cost);
        used = off * 1e4 / slack;
    }

    /// @dev |computed C(v) - true C(v)| <= slack on both sides of every trade.
    function test_costErrorInsideSlack() public {
        Vectors memory s = _load();
        assertEq(s.g.length, 320);
        uint256 worst;
        for (uint256 i; i < s.g.length; ++i) {
            LadderMathHarness.Trade memory t = _trade(s, i);
            uint256 used = _assertInsideSlack(t.cost0, t.slack0, s.c0Floor[i]);
            if (used > worst) worst = used;
            used = _assertInsideSlack(t.cost1, t.slack1, s.c1Floor[i]);
            if (used > worst) worst = used;
        }
        emit log_named_decimal_uint("largest share of the slack used by the real error", worst, 4);
    }

    /// @dev A buy is charged at least the true cost rounded up, a sell is paid at most the true proceeds
    ///      rounded down, and the difference to the true amount is no more than the documented margin
    ///      (plus the pBefore clamp, which can add at most the price-sum tolerance of 1e-12 per share).
    function test_neverUnderCharged() public {
        Vectors memory s = _load();
        uint256 buys;
        uint256 sells;
        uint256 worstOver;
        for (uint256 i; i < s.g.length; ++i) {
            LadderMathHarness.Trade memory t = _trade(s, i);
            uint256 size = s.delta[i] > 0 ? uint256(s.delta[i]) : uint256(-s.delta[i]);
            uint256 margin = _marginBound(_slice(s.b0, i), s.g[i]) + _clampTol(size);
            if (s.delta[i] > 0) {
                ++buys;
                assertGe(t.amount, s.diffCeil[i], "buy charged less than the true cost");
                assertLe(t.amount - s.diffCeil[i], margin, "buy margin above its bound");
                if (t.amount - s.diffCeil[i] > worstOver) worstOver = t.amount - s.diffCeil[i];
            } else {
                ++sells;
                assertLe(t.amount, s.diffFloor[i], "sell paid more than the true proceeds");
                assertLe(s.diffFloor[i] - t.amount, margin, "sell margin above its bound");
            }
        }
        assertGt(buys, 100);
        assertGt(sells, 60);
        emit log_named_uint("largest over-charge of a buy (wei, capital up to 1e30 wei)", worstOver);
    }
}
