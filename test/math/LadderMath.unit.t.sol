// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ILadderMath} from "../../src/interfaces/ILadderMath.sol";
import {LadderMath} from "../../src/LadderMath.sol";
import {LadderMathBase} from "./LadderMathBase.sol";

contract LadderMathUnitTest is LadderMathBase {
    uint256 internal constant SIGMA = 0.035e18;
    uint256 internal constant CAPITAL = 20_000e18;
    uint256 internal constant ALPHA = 0.3e18;

    /*//////////////////////////////////////////////////////////////
                            EDGES AND BANDS
    //////////////////////////////////////////////////////////////*/

    function test_edge_values() public view {
        assertEq(math.edge(SIGMA, 19), 0);
        assertEq(math.edge(SIGMA, 0), -19 * int256(SIGMA) / 4);
        assertEq(math.edge(SIGMA, 38), 19 * int256(SIGMA) / 4);
        assertEq(math.edge(SIGMA, 23), int256(SIGMA));
        assertEq(math.edge(SIGMA, 15), -int256(SIGMA));
    }

    function test_edge_revertsAbove38() public {
        vm.expectRevert(LadderMath.InvalidEdge.selector);
        math.edge(SIGMA, 39);
    }

    function test_bandOf_previousCloseIsBand20() public view {
        // Edge 19 is x = 0. HIGHER at edge 19 is the set [20, 39], and x = 0 itself counts as HIGHER.
        assertEq(math.bandOf(SIGMA, 0), 20);
        assertEq(math.bandOf(SIGMA, -1), 19);
        assertEq(math.bandOf(SIGMA, type(int256).min), 0);
        assertEq(math.bandOf(SIGMA, type(int256).max), 39);
    }

    /// @dev bandOf is the number of inner edges <= x, with the same rounded edges that `edge` returns.
    function testFuzz_bandOf_consistentWithEdge(uint256 sigma, uint8 m) public view {
        sigma = bound(sigma, 0.005e18, 0.15e18);
        m = uint8(bound(m, 0, 38));
        int256 e = math.edge(sigma, m);
        assertEq(math.bandOf(sigma, e), m + 1);
        assertEq(math.bandOf(sigma, e - 1), m);
        if (m < 38) assertLt(e, math.edge(sigma, m + 1));
    }

    function testFuzz_bandOf_countsEdges(uint256 sigma, int256 x) public view {
        sigma = bound(sigma, 0.005e18, 0.15e18);
        x = bound(x, -2e18, 2e18);
        uint8 band = math.bandOf(sigma, x);
        if (band > 0) assertLe(math.edge(sigma, band - 1), x);
        if (band < 39) assertGt(math.edge(sigma, band), x);
    }

    /*//////////////////////////////////////////////////////////////
                                 PRIOR
    //////////////////////////////////////////////////////////////*/

    /// @dev Sums to exactly 1e18; every band at least the renormalised floor 1e-4 / (1 + 40e-4).
    function testFuzz_prior_sumsToOne_floored(uint256 seed) public view {
        uint256 sigma = bound(_rand(seed, 1), 0.005e18, 0.15e18);
        (int256 x, uint256 sd) = _anchor(seed, 2, sigma);
        uint256[40] memory pi = math.prior(sigma, x, sd);
        uint256 total;
        for (uint256 j; j < BANDS; ++j) {
            total += pi[j];
            assertGe(pi[j], uint256(1e14) * 1e18 / 1.004e18);
        }
        assertEq(total, WAD);
    }

    /// @dev Outside the spec's fuzz domain the prior still works: any x, any sd > 0.
    function testFuzz_prior_wideInputs(uint256 sigma, int256 x, uint256 sd) public view {
        sigma = bound(sigma, 1, 1e18);
        x = bound(x, -1e36, 1e36);
        sd = bound(sd, 1, 1e36);
        uint256[40] memory pi = math.prior(sigma, x, sd);
        uint256 total;
        for (uint256 j; j < BANDS; ++j) {
            total += pi[j];
        }
        assertEq(total, WAD);
    }

    function test_prior_farAboveTopEdge_concentratesInLastBand() public view {
        uint256[40] memory pi = math.prior(SIGMA, int256(8 * SIGMA), SIGMA / 20);
        assertGt(pi[39], 0.99e18);
        for (uint256 j; j < 39; ++j) {
            assertEq(pi[j], uint256(1e14) * 1e18 / (1e18 + 39e14));
        }
    }

    function test_prior_reverts() public {
        vm.expectRevert(LadderMath.InvalidSigma.selector);
        math.prior(0, 0, 1e16);
        vm.expectRevert(LadderMath.InvalidSigma.selector);
        math.prior(1e18 + 1, 0, 1e16);
        vm.expectRevert(LadderMath.InvalidSd.selector);
        math.prior(SIGMA, 0, 0);
        vm.expectRevert(LadderMath.InvalidSd.selector);
        math.prior(SIGMA, 0, 1e36 + 1);
        vm.expectRevert(LadderMath.InvalidLogReturn.selector);
        math.prior(SIGMA, 1e36 + 1, SIGMA);
    }

    /*//////////////////////////////////////////////////////////////
                              OPEN DEPTHS
    //////////////////////////////////////////////////////////////*/

    function test_openDepths_alphaCap() public {
        math.openDepths(SIGMA, CAPITAL, 0.79e18);
        vm.expectRevert(LadderMath.AlphaTooHigh.selector);
        math.openDepths(SIGMA, CAPITAL, 0.79e18 + 1);
    }

    function test_openDepths_revertsOnBadCapitalOrShallowDepth() public {
        vm.expectRevert(LadderMath.InvalidCapital.selector);
        math.openDepths(SIGMA, 0, ALPHA);
        vm.expectRevert(LadderMath.InvalidCapital.selector);
        math.openDepths(SIGMA, 1e33 + 1, ALPHA);
        vm.expectRevert(LadderMath.InvalidDepth.selector);
        math.openDepths(SIGMA, CAPITAL, 0);
        // The shallowest band has ln(1 / pi) of about 9.2, so alpha * capital = 7e14 is too little
        // for a depth of 1e14 wei and 1.6e15 is enough.
        vm.expectRevert(LadderMath.InvalidDepth.selector);
        math.openDepths(SIGMA, 9e14, 0.79e18);
        math.openDepths(SIGMA, 2e15, 0.79e18);
        math.openDepths(SIGMA, 1e33, 0.79e18);
    }

    /// @dev b0_j * ln(1 / pi_j) = alpha * capital for every band, rounded down.
    function testFuzz_openDepths_formula(uint256 seed) public view {
        Scn memory s = _round(seed);
        uint256[40] memory pi = math.prior(s.sigma, 0, s.sigma);
        uint256 target = s.alpha * s.capital / WAD;
        for (uint256 j; j < BANDS; ++j) {
            uint256 lnInv = uint256(-FixedPointMathLib.lnWad(int256(pi[j])));
            uint256 back = FixedPointMathLib.fullMulDiv(s.b0[j], lnInv, WAD);
            assertLe(back, target);
            assertLe(target - back, 11);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 FILL
    //////////////////////////////////////////////////////////////*/

    function _open() internal view returns (uint256[40] memory) {
        return math.openDepths(SIGMA, CAPITAL, ALPHA);
    }

    function test_fill_freshRound_pricesEqualPrior() public view {
        uint256[40] memory b0 = _open();
        int256[40] memory v;
        ILadderMath.Ctx memory ctx = _ctx(0.01e18, 0.02e18, WAD, WAD);
        uint256[40] memory pi = math.prior(SIGMA, ctx.x, ctx.sd);
        uint256[40] memory p = math.prices(v, b0, SIGMA, ctx);
        // The solve stops when |ln sum p| <= 128e-18 (LOG_TOL), which can move each price by pi_j * 128e-18,
        // plus a few wei of exponent and logarithm truncation.
        for (uint256 j; j < BANDS; ++j) {
            assertApproxEqAbs(p[j], pi[j], pi[j] * 128 / 1e18 + 4);
        }
    }

    function test_fill_zeroDelta_isFree() public view {
        uint256[40] memory b0 = _open();
        int256[40] memory v;
        v[3] = 17e18;
        ILadderMath.Fill memory f = math.fill(v, b0, SIGMA, _ctx(0, SIGMA, WAD, WAD), 20, 39, 0);
        assertEq(f.amount, 0);
        assertEq(f.pBefore, f.pAfter);
        for (uint256 j; j < BANDS; ++j) {
            assertEq(f.v[j], v[j]);
        }
    }

    /// @dev Buying every band pays exactly 1 per share: cost in [delta, delta + margin].
    function test_fill_completeSet_costsDelta() public view {
        uint256[40] memory b0 = _open();
        int256[40] memory v;
        v[25] = 400e18;
        uint256 margin = _marginBound(b0, WAD);
        ILadderMath.Fill memory f = math.fill(v, b0, SIGMA, _ctx(0.01e18, 0.03e18, WAD, WAD), 0, 39, 1234e18);
        assertGe(f.amount, 1234e18);
        assertLe(f.amount, 1234e18 + margin);
        assertEq(f.vega, 0);
        ILadderMath.Fill memory s =
            math.fill(f.v, b0, SIGMA, _ctx(0.01e18, 0.03e18, WAD, WAD), 0, 39, -1234e18);
        assertLe(s.amount, 1234e18);
        assertGe(s.amount + margin, 1234e18);
    }

    /// @dev HIGHER and LOWER at one strike are complementary: prices sum to 1 and the vegas are equal.
    function test_fill_higherAndLowerAreComplements() public view {
        uint256[40] memory b0 = _open();
        int256[40] memory v;
        ILadderMath.Ctx memory ctx = _ctx(-0.004e18, 0.021e18, WAD, WAD);
        ILadderMath.Fill memory higher = math.fill(v, b0, SIGMA, ctx, 24, 39, 10e18);
        ILadderMath.Fill memory lower = math.fill(v, b0, SIGMA, ctx, 0, 23, 10e18);
        assertApproxEqAbs(higher.pBefore + lower.pBefore, WAD, 100);
        assertEq(higher.vega, lower.vega);
        assertGt(higher.pAfter, higher.pBefore);
        assertGt(lower.pAfter, lower.pBefore);
    }

    /// @dev vega = |phi(z)(z - sd)| at the single finite edge, rounded up by at most 64 wei.
    function test_fill_vegaDefinition() public view {
        uint256[40] memory b0 = _open();
        int256[40] memory v;
        int256 x = 0.01e18;
        uint256 sd = 0.02e18;
        ILadderMath.Fill memory f = math.fill(v, b0, SIGMA, _ctx(x, sd, WAD, WAD), 24, 39, 1e18);
        int256 z = (math.edge(SIGMA, 23) - x) * 1e18 / int256(sd) + int256(sd / 2);
        uint256 expected = FixedPointMathLib.abs(int256(math.pdf(z)) * (z - int256(sd)) / 1e18);
        assertGe(f.vega, expected);
        assertLe(f.vega, expected + 64);
        assertGt(expected, 0.1e18);
    }

    function test_fill_depthDecay_keepsPricesAndRaisesImpact() public view {
        uint256[40] memory b0 = _open();
        int256[40] memory v;
        ILadderMath.Ctx memory ctx = _ctx(0.002e18, 0.03e18, WAD, WAD);
        v = math.fill(v, b0, SIGMA, ctx, 20, 39, 500e18).v;
        ILadderMath.Fill memory deep = math.fill(v, b0, SIGMA, ctx, 20, 39, 100e18);
        ctx.gNew = 0.3e18;
        ILadderMath.Fill memory shallow = math.fill(v, b0, SIGMA, ctx, 20, 39, 100e18);
        assertApproxEqAbs(shallow.pBefore, deep.pBefore, 100);
        assertGt(shallow.pAfter, deep.pAfter);
        assertGt(shallow.amount, deep.amount);
    }

    function test_prices_ignoresGNew() public view {
        uint256[40] memory b0 = _open();
        int256[40] memory v;
        v[20] = 300e18;
        uint256[40] memory a = math.prices(v, b0, SIGMA, _ctx(0, SIGMA, 0.8e18, 0.8e18));
        uint256[40] memory b = math.prices(v, b0, SIGMA, _ctx(0, SIGMA, 0.8e18, 0));
        for (uint256 j; j < BANDS; ++j) {
            assertEq(a[j], b[j]);
        }
    }

    function test_fill_reverts() public {
        uint256[40] memory b0 = _open();
        int256[40] memory v;
        ILadderMath.Ctx memory ok = _ctx(0, SIGMA, WAD, WAD);

        vm.expectRevert(LadderMath.InvalidSet.selector);
        math.fill(v, b0, SIGMA, ok, 5, 4, 1e18);
        vm.expectRevert(LadderMath.InvalidSet.selector);
        math.fill(v, b0, SIGMA, ok, 0, 40, 1e18);

        vm.expectRevert(LadderMath.InvalidDepthScale.selector);
        math.fill(v, b0, SIGMA, _ctx(0, SIGMA, 0.5e18, 0.6e18), 0, 3, 1e18);
        vm.expectRevert(LadderMath.InvalidDepthScale.selector);
        math.fill(v, b0, SIGMA, _ctx(0, SIGMA, WAD, 0), 0, 3, 1e18);
        vm.expectRevert(LadderMath.InvalidDepthScale.selector);
        math.fill(v, b0, SIGMA, _ctx(0, SIGMA, WAD + 1, WAD), 0, 3, 1e18);
        vm.expectRevert(LadderMath.InvalidDepthScale.selector);
        math.prices(v, b0, SIGMA, _ctx(0, SIGMA, 0, 0));

        vm.expectRevert(LadderMath.InvalidSd.selector);
        math.fill(v, b0, SIGMA, _ctx(0, 0, WAD, WAD), 0, 3, 1e18);
        vm.expectRevert(LadderMath.InvalidSigma.selector);
        math.fill(v, b0, 0, ok, 0, 3, 1e18);
        vm.expectRevert(LadderMath.InvalidLogReturn.selector);
        math.fill(v, b0, SIGMA, _ctx(type(int256).min, SIGMA, WAD, WAD), 0, 3, 1e18);

        vm.expectRevert(LadderMath.InvalidDelta.selector);
        math.fill(v, b0, SIGMA, ok, 0, 3, 1e36 + 1);
        vm.expectRevert(LadderMath.InvalidDelta.selector);
        math.fill(v, b0, SIGMA, ok, 0, 3, type(int256).min);

        v[7] = -1e36 - 1;
        vm.expectRevert(LadderMath.InvalidState.selector);
        math.fill(v, b0, SIGMA, ok, 0, 3, 1e18);
        // A trade that would push the state out of the domain is refused, so the state never leaves it.
        v[7] = 1e36;
        vm.expectRevert(LadderMath.InvalidState.selector);
        math.fill(v, b0, SIGMA, ok, 7, 7, 1);
        math.fill(v, b0, SIGMA, ok, 7, 7, -1);
        v[7] = 0;

        b0[11] = 0;
        vm.expectRevert(LadderMath.InvalidDepth.selector);
        math.fill(v, b0, SIGMA, ok, 0, 3, 1e18);
        b0[11] = 1e33 + 1;
        vm.expectRevert(LadderMath.InvalidDepth.selector);
        math.fill(v, b0, SIGMA, ok, 0, 3, 1e18);
    }

    /// @dev Not a bug, and stated here so nobody "fixes" it: a round trip across a prior re-anchor at the
    ///      same x but a smaller sd CAN profit. That is time decay, a risk the trader carried (x could have
    ///      moved). The no-profit guarantee holds for the same (x, sd), with or without a depth rescale; see
    ///      the fuzz tests. Counterexample: x = +1 sigma, buy 100 HIGHER at the previous close with
    ///      sd = sigma (price about 0.83), sell with sd = 0.3 sigma (price about 0.9995).
    function test_roundTrip_acrossShrinkingSd_canProfit_counterexample() public view {
        uint256[40] memory b0 = _open();
        int256[40] memory v;
        int256 x = int256(SIGMA);
        ILadderMath.Fill memory buy = math.fill(v, b0, SIGMA, _ctx(x, SIGMA, WAD, WAD), 20, 39, 100e18);
        ILadderMath.Fill memory sell =
            math.fill(buy.v, b0, SIGMA, _ctx(x, SIGMA * 3 / 10, WAD, 0.55e18), 20, 39, -100e18);
        assertLt(buy.amount, 86e18);
        assertGt(sell.amount, 98e18);
    }
}

/// @notice The open depths from the per-sigma cache are the open depths, bit for bit.
contract LadderMathDepthCacheTest is LadderMathBase {
    function testFuzz_depthsFromTheCache_equalOpenDepths(uint256 sigma, uint256 capital, uint256 alpha)
        public
        view
    {
        sigma = bound(sigma, 0.005e18, 0.15e18);
        capital = bound(capital, 1e21, 1e33);
        alpha = bound(alpha, 0.01e18, 0.79e18);
        uint256[10] memory packed = math.openLnInv(sigma);
        uint256[40] memory a = math.openDepths(sigma, capital, alpha);
        uint256[40] memory b = math.depths(packed, capital, alpha);
        for (uint256 j; j < 40; ++j) {
            assertEq(a[j], b[j]);
            assertGt((packed[j / 4] >> (64 * (j % 4))) & type(uint64).max, 0, "every band has its lnInv");
        }
    }
}
