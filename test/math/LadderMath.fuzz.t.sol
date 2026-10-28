// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILadderMath} from "../../src/interfaces/ILadderMath.sol";
import {LadderMathBase} from "./LadderMathBase.sol";

/// @notice Property tests over the fuzz domain of SPEC section 3: sigma in [0.005, 0.15], capital in
///         [1e17, 1e30] wei (0.1 to 1e12 tokens), alpha in [0.05, 0.79], |x| <= 8 sigma, sd in
///         [0.05, 1.5] sigma, depth scale in [0.3, 1], |delta| <= capital. Every scenario is a state reached
///         by up to three real fills (buys, sells, new anchors, depth decay), so each test also checks that
///         `fill` never reverts inside the domain.
/// @dev What is exact and what carries a tolerance:
///      - No-profit round trips (with and without a depth rescale) are asserted with NO tolerance.
///      - Path independence holds to 1e-9 relative plus the safety margin of the four fills involved.
///      - Monotonicity in delta holds up to the safety margin (see testFuzz_costMonotoneInDelta).
contract LadderMathFuzzTest is LadderMathBase {
    /// @dev 1e-12 in WAD.
    uint256 internal constant PRICE_TOL = 1e6;

    /*//////////////////////////////////////////////////////////////
                                PRICES
    //////////////////////////////////////////////////////////////*/

    function testFuzz_pricesSumToOne(uint256 seed) public view {
        Scn memory s = _scenario(seed);
        uint256[40] memory p = math.prices(s.v, s.b0, s.sigma, _ctx(s.x, s.sd, s.g, s.g));
        uint256 total;
        for (uint256 j; j < BANDS; ++j) {
            total += p[j];
        }
        assertApproxEqAbs(total, WAD, PRICE_TOL);
    }

    /// @dev A depth rescale (gNew < gOld) moves no band price by more than 1e-12.
    function testFuzz_rescaleMovesNoPrice(uint256 seed) public view {
        Scn memory s = _scenario(seed);
        uint256 gNew = bound(_rand(seed, 20), 0.3e18, s.g);
        uint256[40] memory before = math.prices(s.v, s.b0, s.sigma, _ctx(s.x, s.sd, s.g, s.g));
        ILadderMath.Fill memory f = _fill(s, gNew, 0, 0, 0);
        uint256[40] memory afterwards = math.prices(f.v, s.b0, s.sigma, _ctx(s.x, s.sd, gNew, gNew));
        assertEq(f.amount, 0);
        for (uint256 j; j < BANDS; ++j) {
            assertApproxEqAbs(afterwards[j], before[j], PRICE_TOL);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           PATH INDEPENDENCE
    //////////////////////////////////////////////////////////////*/

    /// @dev Signed payment of the trader: positive for a buy, negative for a sell.
    function _pay(ILadderMath.Fill memory f, int256 delta) internal pure returns (int256) {
        return delta > 0 ? int256(f.amount) : -int256(f.amount);
    }

    /// @dev A then B costs the same as B then A (any sets, buys or sells) and ends in the same state.
    function testFuzz_pathIndependence(uint256 seed) public view {
        Scn memory s = _scenario(seed);
        (uint8 loA, uint8 hiA) = _set(seed, 21);
        (uint8 loB, uint8 hiB) = _set(seed, 22);
        int256 dA = int256(_size(seed, 23, s.capital));
        int256 dB = int256(_size(seed, 24, s.capital));
        if (_rand(seed, 25) % 4 == 0) dA = -dA;
        if (_rand(seed, 26) % 4 == 0) dB = -dB;
        ILadderMath.Ctx memory ctx = _ctx(s.x, s.sd, s.g, s.g);

        ILadderMath.Fill memory a1 = math.fill(s.v, s.b0, s.sigma, ctx, loA, hiA, dA);
        ILadderMath.Fill memory b1 = math.fill(a1.v, s.b0, s.sigma, ctx, loB, hiB, dB);
        ILadderMath.Fill memory b2 = math.fill(s.v, s.b0, s.sigma, ctx, loB, hiB, dB);
        ILadderMath.Fill memory a2 = math.fill(b2.v, s.b0, s.sigma, ctx, loA, hiA, dA);

        for (uint256 j; j < BANDS; ++j) {
            assertEq(b1.v[j], a2.v[j]);
        }
        int256 ab = _pay(a1, dA) + _pay(b1, dB);
        int256 ba = _pay(b2, dB) + _pay(a2, dA);
        uint256 gross = a1.amount + b1.amount + b2.amount + a2.amount;
        uint256 tol = gross / 4e9 + 4 * _marginBound(s.b0, s.g);
        assertApproxEqAbs(ab, ba, tol);
    }

    /*//////////////////////////////////////////////////////////////
                              ROUND TRIPS
    //////////////////////////////////////////////////////////////*/

    /// @dev Buy then sell the same size at the same anchor never profits, with or without a depth
    ///      rescale in between. No tolerance.
    function testFuzz_buyThenSell_neverProfits(uint256 seed) public view {
        Scn memory s = _scenario(seed);
        (uint8 lo, uint8 hi) = _set(seed, 21);
        int256 delta = int256(_size(seed, 22, s.capital));
        // half of the runs sell at a lower depth scale, down to 1 wei below or all the way to 0.3
        uint256 gSell = s.g;
        uint256 mode = _rand(seed, 23) % 4;
        if (mode == 1) gSell = s.g - 1;
        else if (mode == 2) gSell = bound(_rand(seed, 24), 0.3e18, s.g);
        else if (mode == 3) gSell = 0.3e18;

        ILadderMath.Fill memory buy = _fill(s, s.g, lo, hi, delta);
        ILadderMath.Fill memory sell =
            math.fill(buy.v, s.b0, s.sigma, _ctx(s.x, s.sd, s.g, gSell), lo, hi, -delta);
        assertLe(sell.amount, buy.amount, "round trip profit");
    }

    /// @dev The mirror image: sell then buy back never profits.
    function testFuzz_sellThenBuy_neverProfits(uint256 seed) public view {
        Scn memory s = _scenario(seed);
        (uint8 lo, uint8 hi) = _set(seed, 21);
        int256 delta = int256(_size(seed, 22, s.capital));
        uint256 gBuy = s.g;
        uint256 mode = _rand(seed, 23) % 4;
        if (mode == 1) gBuy = s.g - 1;
        else if (mode == 2) gBuy = bound(_rand(seed, 24), 0.3e18, s.g);
        else if (mode == 3) gBuy = 0.3e18;

        ILadderMath.Fill memory sell = _fill(s, s.g, lo, hi, -delta);
        ILadderMath.Fill memory buy =
            math.fill(sell.v, s.b0, s.sigma, _ctx(s.x, s.sd, s.g, gBuy), lo, hi, delta);
        assertGe(buy.amount, sell.amount, "round trip profit");
    }

    /// @dev The rescale and the trade in one fill, then the way back at the already lower depth.
    function testFuzz_roundTripStartingWithRescale_neverProfits(uint256 seed) public view {
        Scn memory s = _scenario(seed);
        (uint8 lo, uint8 hi) = _set(seed, 21);
        int256 delta = int256(_size(seed, 22, s.capital));
        if (_rand(seed, 23) % 2 == 0) delta = -delta;
        uint256 gNew = bound(_rand(seed, 24), 0.3e18, s.g);

        ILadderMath.Fill memory first = _fill(s, gNew, lo, hi, delta);
        ILadderMath.Fill memory back =
            math.fill(first.v, s.b0, s.sigma, _ctx(s.x, s.sd, gNew, gNew), lo, hi, -delta);
        if (delta > 0) assertLe(back.amount, first.amount, "round trip profit");
        else assertGe(back.amount, first.amount, "round trip profit");
    }

    /// @dev Splitting a buy in two never makes it cheaper, and splitting a sell never pays more.
    function testFuzz_splittingNeverHelps(uint256 seed) public view {
        Scn memory s = _scenario(seed);
        (uint8 lo, uint8 hi) = _set(seed, 21);
        uint256 size = _size(seed, 22, s.capital);
        if (size < 2) size = 2;
        uint256 part = bound(_rand(seed, 23), 1, size - 1);
        bool isBuy = _rand(seed, 24) % 2 == 0;
        int256 sign = isBuy ? int256(1) : int256(-1);

        ILadderMath.Fill memory whole = _fill(s, s.g, lo, hi, sign * int256(size));
        ILadderMath.Fill memory one = _fill(s, s.g, lo, hi, sign * int256(part));
        ILadderMath.Fill memory two =
            math.fill(one.v, s.b0, s.sigma, _ctx(s.x, s.sd, s.g, s.g), lo, hi, sign * int256(size - part));
        // The whole trade carries one margin, the split carries two: allow the whole to exceed the split
        // by one margin on a buy (and the reverse on a sell). Splitting never gains more than that dust.
        uint256 margin = _marginBound(s.b0, s.g);
        if (isBuy) assertGe(one.amount + two.amount + margin, whole.amount);
        else assertLe(one.amount + two.amount, whole.amount + margin);
    }

    /*//////////////////////////////////////////////////////////////
                             MONOTONICITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Cost is monotone in delta. The true cost difference is exactly monotone; the amount adds a
    ///      safety margin to each side that depends on the state, so two nearby sizes can swap order by at
    ///      most that margin (about 3.6e-17 of the largest depth: under 1e-5 token on a 1e12 token house).
    ///      Strict monotonicity therefore holds whenever the sizes differ by more than margin / price.
    function testFuzz_costMonotoneInDelta(uint256 seed) public view {
        Scn memory s = _scenario(seed);
        (uint8 lo, uint8 hi) = _set(seed, 21);
        uint256 small = _size(seed, 22, s.capital);
        uint256 big = _size(seed, 23, s.capital);
        if (small > big) (small, big) = (big, small);
        uint256 margin = _marginBound(s.b0, s.g);

        ILadderMath.Fill memory buySmall = _fill(s, s.g, lo, hi, int256(small));
        ILadderMath.Fill memory buyBig = _fill(s, s.g, lo, hi, int256(big));
        assertGe(buyBig.amount + margin, buySmall.amount, "buy cost not monotone");
        assertGe(buyBig.pAfter + PRICE_TOL, buySmall.pAfter, "buy price not monotone");
        assertGe(buySmall.pAfter + PRICE_TOL, buySmall.pBefore, "buy lowers the price");

        ILadderMath.Fill memory sellSmall = _fill(s, s.g, lo, hi, -int256(small));
        ILadderMath.Fill memory sellBig = _fill(s, s.g, lo, hi, -int256(big));
        assertGe(sellBig.amount + margin, sellSmall.amount, "sell proceeds not monotone");
        assertLe(sellBig.pAfter, sellSmall.pAfter + PRICE_TOL, "sell price not monotone");
        assertLe(sellSmall.pAfter, sellSmall.pBefore + PRICE_TOL, "sell raises the price");

        // A buy always costs at least what a sell of the same size returns.
        assertGe(buySmall.amount, sellSmall.amount);
        assertGe(buyBig.amount, sellBig.amount);
    }

    /// @dev Convexity bounds: delta * pBefore <= buy cost <= delta * pAfter, and the mirror for a sell.
    ///      The lower bound of a buy and the upper bound of a sell are enforced by the contract exactly.
    function testFuzz_amountBetweenMarginalPrices(uint256 seed) public view {
        Scn memory s = _scenario(seed);
        (uint8 lo, uint8 hi) = _set(seed, 21);
        uint256 size = _size(seed, 22, s.capital);
        uint256 tol = _marginBound(s.b0, s.g) + _clampTol(size);

        ILadderMath.Fill memory buy = _fill(s, s.g, lo, hi, int256(size));
        assertGe(buy.amount * WAD, size * buy.pBefore, "buy below size * pBefore");
        assertLe(buy.amount, size * buy.pAfter / WAD + tol, "buy above size * pAfter");
        assertLe(buy.amount, size + tol, "buy above 1 per share");

        ILadderMath.Fill memory sell = _fill(s, s.g, lo, hi, -int256(size));
        assertLe(sell.amount * WAD, size * sell.pBefore, "sell above size * pBefore");
        assertGe(sell.amount + tol, size * sell.pAfter / WAD, "sell below size * pAfter");
    }

    /// @dev Strict monotonicity is FALSE at the wei level, and this pins a counterexample so the tolerance
    ///      above is not mistaken for sloppiness. House of 1e12 tokens (1e30 wei), alpha 0.79, the upper
    ///      set [20, 39]: buying 1e27 + 32e10 wei costs about 1.9e10 wei LESS than buying 1e27 + 31e10 wei
    ///      (where the noise falls depends on the warm-started solve). The true
    ///      cost of the extra 1e10 wei is about 1e6 wei; the evaluation noise of two cost functions of size
    ///      1e30 is larger. The swap is 2e-13 of the amount and far smaller than the safety margin that both
    ///      amounts already include, so neither trade is under-charged.
    function test_costMonotone_strictIsFalse_counterexample() public view {
        uint256[40] memory b0 = math.openDepths(0.035e18, 1e30, 0.79e18);
        int256[40] memory v;
        ILadderMath.Ctx memory ctx = _ctx(0.004e18, 0.03e18, WAD, WAD);
        v = math.fill(v, b0, 0.035e18, ctx, 20, 39, 9e28).v;
        v = math.fill(v, b0, 0.035e18, ctx, 0, 15, 3e28).v;
        uint256 smaller = math.fill(v, b0, 0.035e18, ctx, 20, 39, 1e27 + 31e10).amount;
        uint256 larger = math.fill(v, b0, 0.035e18, ctx, 20, 39, 1e27 + 32e10).amount;
        assertLt(larger, smaller, "the pinned counterexample no longer holds");
        assertLt(smaller - larger, _marginBound(b0, WAD) / 100);
    }

    /*//////////////////////////////////////////////////////////////
                             NEVER REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Longer random walks through the domain, extremes included: |delta| up to capital, the corners
    ///      of (x, sd), depth decayed to 0.3. Any revert fails the test.
    function testFuzz_fillNeverReverts(uint256 seed) public view {
        Scn memory s = _round(seed);
        _warm(s, seed, 6);
        (s.x, s.sd) = _anchor(seed, 7, s.sigma);
        (uint8 lo, uint8 hi) = _set(seed, 21);
        int256 delta = int256(s.capital);
        if (_rand(seed, 22) % 2 == 0) delta = -delta;
        ILadderMath.Fill memory f = _fill(s, _rand(seed, 23) % 2 == 0 ? s.g : 0.3e18, lo, hi, delta);
        assertLe(f.pBefore, WAD);
        assertLe(f.pAfter, WAD);
        if (delta > 0) assertLe(f.amount, s.capital + _marginBound(s.b0, s.g));
        else assertLe(f.amount, s.capital);
    }

    /// @dev Far outside the spec's fuzz domain, towards the documented input limits: capital up to 1e33 wei
    ///      or down to about the smallest `openDepths` accepts, any state within 1e35, |delta| up to 1e35, any
    ///      x within 1e36, sd from 1 wei to 1e36, depth scale down to 0.1. Nothing overflows, nothing reverts.
    function testFuzz_fillNeverReverts_wideDomain(uint256 seed) public view {
        uint256 sigma = bound(_rand(seed, 1), 0.001e18, 1e18);
        uint256 capital = _rand(seed, 2) % 4 == 0 ? 3e16 : bound(_rand(seed, 3), 3e16, 1e33);
        if (_rand(seed, 2) % 4 == 1) capital = 1e33;
        uint256[40] memory b0 = math.openDepths(sigma, capital, bound(_rand(seed, 4), 0.05e18, 0.79e18));
        int256[40] memory v;
        int256 span = int256(10 ** bound(_rand(seed, 5), 0, 35));
        for (uint256 j; j < BANDS; ++j) {
            v[j] = bound(int256(_rand(seed, 100 + j) >> 1), -span, span);
        }
        uint256 gOld = bound(_rand(seed, 6), 0.1e18, WAD);
        uint256 gNew = bound(_rand(seed, 7), 0.1e18, gOld);
        int256 x = bound(int256(_rand(seed, 8) >> 1), -1e36, 1e36);
        if (_rand(seed, 9) % 2 == 0) x = bound(x, -int256(sigma) * 10, int256(sigma) * 10);
        uint256 sd = 10 ** bound(_rand(seed, 10), 0, 36);
        if (_rand(seed, 11) % 2 == 0) sd = bound(_rand(seed, 12), sigma / 100, sigma * 2);
        (uint8 lo, uint8 hi) = _set(seed, 13);
        int256 delta = int256(10 ** bound(_rand(seed, 14), 0, 35));
        ILadderMath.Ctx memory ctx = _ctx(x, sd, gOld, gNew);

        ILadderMath.Fill memory buy = math.fill(v, b0, sigma, ctx, lo, hi, delta);
        ILadderMath.Fill memory sell = math.fill(v, b0, sigma, ctx, lo, hi, -delta);
        assertGe(buy.amount, sell.amount);
        assertLe(sell.amount, uint256(delta));
        ctx.gOld = gNew;
        ILadderMath.Fill memory back = math.fill(buy.v, b0, sigma, ctx, lo, hi, -delta);
        assertLe(back.amount, buy.amount, "round trip profit");
    }

    /// @dev External so that each scenario's memory is released.
    function scenarioEvaluations(uint256 seed) external view returns (uint256) {
        Scn memory s = _scenario(seed);
        return math.solveEvaluations(s.v, s.b0, s.sigma, _ctx(s.x, s.sd, s.g, s.g));
    }

    /// @dev The lambda solve is capped at 64 log-sum evaluations. Newton from the tight lower bound needs far
    ///      fewer: at most 12 over these 150 scenarios (4 to 7 typically).
    function test_solve_evaluationCount() public {
        uint256 worst;
        uint256 total;
        uint256 n = 150;
        for (uint256 seed = 1; seed <= n; ++seed) {
            uint256 e = this.scenarioEvaluations(seed);
            total += e;
            if (e > worst) worst = e;
        }
        emit log_named_uint("lambda solve: worst evaluations", worst);
        emit log_named_decimal_uint("lambda solve: mean evaluations", total * 100 / n, 2);
        assertLe(worst, 12);
    }

    /// @dev A complete set is worth exactly 1: buying it costs delta (plus margin), selling returns delta
    ///      (minus margin), whatever the state.
    function testFuzz_completeSet(uint256 seed) public view {
        Scn memory s = _scenario(seed);
        uint256 size = _size(seed, 21, s.capital);
        uint256 margin = _marginBound(s.b0, s.g) + _clampTol(size);
        ILadderMath.Fill memory buy = _fill(s, s.g, 0, 39, int256(size));
        assertGe(buy.amount, size);
        assertLe(buy.amount, size + margin);
        ILadderMath.Fill memory sell = _fill(s, s.g, 0, 39, -int256(size));
        assertLe(sell.amount, size);
        assertGe(sell.amount + margin, size);
    }
}
