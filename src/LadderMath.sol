// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ILadderMath} from "./interfaces/ILadderMath.sol";
import {Gaussian} from "./lib/Gaussian.sol";

/// @title LadderMath
/// @notice Stateless pricing engine of a Fallpit round: an oracle-anchored, depth-weighted LMSR over 40
///         bands of the close's log return. See contracts/SPEC.md section 3.
/// @dev Notation. pi is the prior, v the pricing state, b_j = b0_j * g / 1e18 the depth of band j, and
///
///        p_j(lambda) = pi_j * exp((v_j - lambda) / b_j)
///        F(lambda)   = lambda + sum_j b_j * (p_j(lambda) - pi_j)
///        C(v)        = F(lambda*), where lambda* is the root of sum_j p_j(lambda) = 1.
///
///      Depths are never rounded: every formula uses the exact rational b0_j * g / 1e18, so a depth rescale
///      is an exact affine map of the state and the homogeneity C_g(v) = g * C_1(v / g) holds exactly.
///
///      Rounding against the trader. F'(lambda) = 1 - sum_j p_j(lambda) and F is convex, so C(v) is the
///      minimum of F: an inexact lambda can only overstate C, and only at second order. With S the sum of
///      prices at the solved lambda and bMax the largest depth,
///
///        0 <= F(lambda) - C(v) <= |1 - S| * |lambda - lambda*| <= |1 - S| * |ln S| * bMax,
///
///      because |d/dlambda ln sum_j p_j| >= 1 / bMax. The evaluation of F itself is off by at most
///      bMax * (1e-18 + r + a * 1e-18) + 2 wei, where 1e-18 is the truncation of the exponent to WAD, and
///      r <= 1e-19 and a <= 1.01 are the relative and absolute errors of solady's expWad (asserted against
///      a 90-digit reference in test/math/Gaussian.t.sol). That is below 2.2e-18 * bMax; EVAL_ERR = 8
///      charges 8e-18 * bMax, more than three times the bound. Each cost evaluation therefore carries a
///      `slack` with |computed - C(v)| <= slack (asserted to the wei in test/math/LadderMath.margin.t.sol), and
///
///        buy:  amount = computed C(v') - computed C(v) + slack(v') + slack(v) + RESCALE_DUST  >= true cost
///        sell: amount = computed C(v) - computed C(v') - slack(v) - slack(v') - RESCALE_DUST  <= true proceeds
///
///      RESCALE_DUST covers the 1 wei per band that the depth rescale rounds the state by: C is 1-Lipschitz
///      in the sup norm (its gradient is the price vector), so that rounding moves any cost difference by at
///      most 2 wei. On top of that a buy is never charged less than delta * pBefore and a sell never
///      receives more than delta * pBefore (both follow from convexity).
///
///      Supported domain (inputs outside it revert with a custom error, never return a wrong number):
///        sigma in (0, 1e18], sd in (0, 1e36], |x| <= 1e36, g in (0, 1e18], |v_j| and |delta| <= 1e36,
///        capital and b0_j <= 1e33 (1e15 tokens), b0_j * g >= 1e24 (a depth of at least 1e6 wei).
///      `fill` also reverts rather than return a state entry above 1e36, so a trade can never push the
///      state out of the domain. The per-band loops run unchecked or in assembly only on values that these
///      checks bound; each such block states why it cannot overflow. All other arithmetic is checked.
///      Precision domain: lambda is an integer number of wei, and one wei of lambda moves the price sum
///      by up to 1 / min_j b_j, so the 1e-12 price-sum check needs every depth b_j >= 1e13 wei.
///      `openDepths` refuses to return a depth below 1e14 wei, so every round it opens is inside the
///      precision domain for any depth scale g >= 0.1 (the hook never goes below 0.3).
contract LadderMath is ILadderMath {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BANDS = 40;
    uint256 internal constant EDGES = 39;

    /// @dev Prior floor per band before renormalisation: 1e-4.
    uint256 internal constant PRIOR_FLOOR = 1e14;
    /// @dev Largest depth fraction: above 0.79 a tail band can lose more than the capital.
    uint256 internal constant MAX_ALPHA = 0.79e18;
    /// @dev Prices must sum to 1 within 1e-12 or the call reverts.
    uint256 internal constant SUM_TOL = 1e6;
    /// @dev Iteration cap of the lambda solve.
    uint256 internal constant MAX_ITERATIONS = 64;

    /// @dev `_solve` with no warm start: from the lower end of the bracket.
    int256 internal constant COLD = type(int256).min;
    /// @dev The solve stops when |ln sum p| <= 128e-18. The evaluation noise of the log-sum is at most
    ///      about 42e-18 (40 truncated exponentials, typically 3e-18), and a Newton step taken on a noisy
    ///      value lands within twice the noise of the root, so the stop is always reached.
    uint256 internal constant LOG_TOL = 128;

    uint256 internal constant MAX_SIGMA = 1e18;
    /// @dev Bound on |x|, sd, |v_j| and |delta|.
    uint256 internal constant MAX_MAGNITUDE = 1e36;
    /// @dev Bound on the capital and on each depth b0_j: 1e15 tokens. Keeps the excursion of a depth
    ///      rescale (at most 9.3 depths below the state) a thousand times smaller than the state bound.
    uint256 internal constant MAX_DEPTH = 1e33;
    /// @dev Smallest b0_j * g accepted: a depth of 1e6 wei.
    uint256 internal constant MIN_SCALED_DEPTH = 1e24;
    /// @dev Smallest depth `openDepths` returns, in wei. See the precision domain in the contract notes.
    uint256 internal constant MIN_OPEN_DEPTH = 1e14;
    /// @dev Exponent above which a price cannot belong to a converged state (pi_j >= 9.9e-5, so at the
    ///      root (v_j - lambda) / b_j <= ln(1 / pi_j) < 9.3). Keeps expWad far from its overflow.
    int256 internal constant MAX_EXPONENT = 60e18;

    /// @dev Evaluation error of a cost, in units of 1e-18 of the largest depth. See the contract notes.
    uint256 internal constant EVAL_ERR = 8;
    /// @dev Bound on the error of the computed price sum, in wei of WAD (40 floored band prices plus the
    ///      exponent truncations: the true bound is about 45).
    uint256 internal constant SUM_ERR = 1e3;
    /// @dev Flooring and truncation dust of one cost evaluation, in wei.
    uint256 internal constant EVAL_DUST = 3;
    /// @dev Effect on a cost difference of rounding the rescaled state, in wei.
    uint256 internal constant RESCALE_DUST = 2;
    /// @dev Vol-mix node multipliers of the sd, WAD, truncated: exp(-0.2 sqrt3 - 0.02), exp(-0.02) and
    ///      exp(0.2 sqrt3 - 0.02).
    uint256 internal constant MIX_LO = 693218411377872994;
    uint256 internal constant MIX_MID = 980198673306755302;
    uint256 internal constant MIX_HI = 1385983729489546675;
    /// @dev Error allowance per finite edge of the vega output, in wei of WAD (pdf error below 3 wei times
    ///      |z - sd| below 10.2).
    uint256 internal constant VEGA_DUST = 32;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice alpha is above 0.79.
    error AlphaTooHigh();
    /// @notice sigma is zero or above 1e18.
    error InvalidSigma();
    /// @notice sd is zero or above 1e36.
    error InvalidSd();
    /// @notice |x| is above 1e36.
    error InvalidLogReturn();
    /// @notice capital is zero or above 1e33.
    error InvalidCapital();
    /// @notice A depth scale is zero, above 1e18, or gNew is above gOld.
    error InvalidDepthScale();
    /// @notice A depth is too small (below 1e14 wei at the open, below 1e6 wei in a fill) or above 1e33.
    error InvalidDepth();
    /// @notice A pricing state entry is above 1e36 in magnitude, on the way in or on the way out.
    error InvalidState();
    /// @notice The set is not a contiguous run of bands inside 0..39.
    error InvalidSet();
    /// @notice |delta| is above 1e36.
    error InvalidDelta();
    /// @notice The edge index is above 38.
    error InvalidEdge();
    /// @notice The solved prices do not sum to 1 within 1e-12.
    error LambdaNotConverged();

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @dev Working set of one pricing call.
    /// @param pi prior, sums to exactly 1e18
    /// @param lnPi ln(pi_j) in WAD, negative
    /// @param bg b0_j * g: the depth of band j in wei, times 1e18
    /// @param bgMax largest bg
    /// @param bPi sum_j bg_j * pi_j: sum_j b_j * pi_j in wei, times 1e36
    /// @param scratch reusable buffer of the lambda solve
    struct Book {
        uint256[40] pi;
        int256[40] lnPi;
        uint256[40] bg;
        uint256 bgMax;
        uint256 bPi;
        int256[40] scratch;
    }

    /// @dev One cost evaluation.
    /// @param p band prices at the solved lambda
    /// @param cost computed C(v), within `slack` of the true value
    /// @param slack bound on |cost - C(v)| in wei
    struct Quote {
        uint256[40] p;
        int256 cost;
        uint256 slack;
    }

    /*//////////////////////////////////////////////////////////////
                               EXTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILadderMath
    /// @dev Rounded down (a shallower book is the conservative side for the house). Reverts if alpha is
    ///      above 0.79, if capital is zero or above 1e33, or if a depth would be below 1e14 wei (which needs
    ///      alpha * capital of at least about 1e15 wei).
    function openDepths(uint256 sigma, uint256 capital, uint256 alpha)
        external
        pure
        returns (uint256[40] memory b0)
    {
        return _depths(_openLnInv(sigma), capital, alpha);
    }

    /// @inheritdoc ILadderMath
    function openLnInv(uint256 sigma) external pure returns (uint256[10] memory packed) {
        return _openLnInv(sigma);
    }

    /// @inheritdoc ILadderMath
    function depths(uint256[10] calldata packed, uint256 capital, uint256 alpha)
        external
        pure
        returns (uint256[40] memory b0)
    {
        return _depths(packed, capital, alpha);
    }

    function _openLnInv(uint256 sigma) internal pure returns (uint256[10] memory packed) {
        uint256[40] memory pi = _prior(sigma, 0, sigma);
        // Bound: j < 40 and each logarithm is in (-9.3e18, 0), so no step can overflow.
        unchecked {
            for (uint256 j; j < BANDS; ++j) {
                // pi_j <= 1 - 39 * 9.9e-5, so the logarithm is strictly negative; pi_j >= 9.9e-5, so it is
                // below 9.3e18 and fits 64 bits.
                uint256 lnInv = uint256(-FixedPointMathLib.lnWad(int256(pi[j])));
                packed[j / 4] |= lnInv << (64 * (j % 4));
            }
        }
    }

    /// @dev Rounded down (a shallower book is the conservative side for the house). Reverts if alpha is
    ///      above 0.79, if capital is zero or above 1e33, or if a depth would be below 1e14 wei (which needs
    ///      alpha * capital of at least about 1e15 wei).
    function _depths(uint256[10] memory packed, uint256 capital, uint256 alpha)
        internal
        pure
        returns (uint256[40] memory b0)
    {
        if (alpha > MAX_ALPHA) revert AlphaTooHigh();
        if (capital == 0 || capital > MAX_DEPTH) revert InvalidCapital();
        for (uint256 j; j < BANDS; ++j) {
            uint256 lnInv = (packed[j / 4] >> (64 * (j % 4))) & type(uint64).max;
            b0[j] = FixedPointMathLib.fullMulDiv(alpha, capital, lnInv);
            if (b0[j] < MIN_OPEN_DEPTH) revert InvalidDepth();
        }
    }

    /// @inheritdoc ILadderMath
    function prior(uint256 sigma, int256 x, uint256 sd) external pure returns (uint256[40] memory pi) {
        return _prior(sigma, x, sd);
    }

    /// @inheritdoc ILadderMath
    /// @dev Raw solved prices: they sum to 1e18 within 1e-12 (1e6 wei), not exactly. ctx.gNew is ignored.
    function prices(int256[40] calldata v, uint256[40] calldata b0, uint256 sigma, Ctx calldata ctx)
        external
        pure
        returns (uint256[40] memory p)
    {
        if (ctx.gOld == 0 || ctx.gOld > WAD) revert InvalidDepthScale();
        int256[40] memory w = _loadState(v);
        Book memory bk = _book(sigma, ctx.x, ctx.sd);
        _setDepth(bk, b0, ctx.gOld);
        return _quote(w, bk, _solve(w, bk, COLD)).p;
    }

    /// @inheritdoc ILadderMath
    /// @dev delta == 0 returns amount 0 and the rescaled state. pBefore and pAfter are capped at 1e18.
    ///      vega is rounded up by VEGA_DUST per finite edge of the set.
    function fill(
        int256[40] calldata v,
        uint256[40] calldata b0,
        uint256 sigma,
        Ctx calldata ctx,
        uint8 lo,
        uint8 hi,
        int256 delta
    ) external pure returns (Fill memory f) {
        if (lo > hi || hi >= BANDS) revert InvalidSet();
        if (FixedPointMathLib.abs(delta) > MAX_MAGNITUDE) revert InvalidDelta();
        if (ctx.gNew == 0 || ctx.gNew > ctx.gOld || ctx.gOld > WAD) revert InvalidDepthScale();

        // 1. Prior at the fill's oracle price and remaining standard deviation.
        int256[40] memory w = _loadState(v);
        Book memory bk = _book(sigma, ctx.x, ctx.sd);

        // 2. Depth rescale around lambda1, the root at the old depth. (Any centre would keep every price
        //    and every cost difference; the spec centres on lambda1, which keeps the state near its level.)
        //    The rescaled state at the new depth has the same root, so it seeds the next solve.
        int256 seed = COLD;
        if (ctx.gNew < ctx.gOld) {
            _setDepth(bk, b0, ctx.gOld);
            seed = _solve(w, bk, COLD);
            _rescale(w, seed, ctx.gNew, ctx.gOld);
        }

        // 3. Cost and set price before the trade, at the new depth.
        _setDepth(bk, b0, ctx.gNew);
        int256 lam0 = _solve(w, bk, seed);
        Quote memory q0 = _quote(w, bk, lam0);
        f.pBefore = _setPrice(q0.p, lo, hi);
        f.pAfter = f.pBefore;

        // 4 and 5. Trade, cost after, amount rounded against the trader.
        if (delta != 0) {
            // Bound: |v_j| < 1.01e36 after the rescale and |delta| <= 1e36, so the sum fits; lo <= hi <= 39
            // keeps the writes inside w.
            assembly ("memory-safe") {
                for { let o := shl(5, lo) } iszero(gt(o, shl(5, hi))) { o := add(o, 32) } {
                    let p := add(w, o)
                    mstore(p, add(mload(p), delta))
                }
            }
            // the root after the trade is near the one before it (a warm start)
            Quote memory q1 = _quote(w, bk, _solve(w, bk, lam0));
            f.pAfter = _setPrice(q1.p, lo, hi);
            f.amount = _amount(q0, q1, f.pBefore, delta);
        }

        // 6. Vega of the set.
        f.vega = _vega(sigma, ctx.x, ctx.sd, lo, hi);

        // Never hand back a state that the next call would refuse.
        if (_outOfRange(w)) revert InvalidState();
        f.v = w;
    }

    /// @inheritdoc ILadderMath
    function edge(uint256 sigma, uint8 m) external pure returns (int256) {
        if (m >= EDGES) revert InvalidEdge();
        if (sigma == 0 || sigma > MAX_SIGMA) revert InvalidSigma();
        return _edge(sigma, m);
    }

    /// @inheritdoc ILadderMath
    /// @dev Uses the same rounded edges as `edge`, so bandOf(sigma, edge(sigma, m)) == m + 1.
    function bandOf(uint256 sigma, int256 x) external pure returns (uint8 band) {
        if (sigma == 0 || sigma > MAX_SIGMA) revert InvalidSigma();
        while (band < EDGES && _edge(sigma, band) <= x) {
            ++band;
        }
    }

    /*//////////////////////////////////////////////////////////////
                           PRIOR AND GREEKS
    //////////////////////////////////////////////////////////////*/

    /// @dev (m - 19) * sigma / 4, truncated toward zero.
    function _edge(uint256 sigma, uint256 m) internal pure returns (int256) {
        return (int256(m) - 19) * int256(sigma) / 4;
    }

    /// @dev z = (edge_m - x) / sd + sd / 2 in WAD. With |x| <= 1e36 and sd >= 1 the result is below 1e55.
    function _z(uint256 sigma, uint256 m, int256 x, uint256 sd) internal pure returns (int256) {
        return (_edge(sigma, m) - x) * int256(WAD) / int256(sd) + int256(sd / 2);
    }

    /// @dev Input bounds of the prior. They keep every cast and product of `_z` in range.
    function _checkAnchor(uint256 sigma, int256 x, uint256 sd) internal pure {
        if (sigma == 0 || sigma > MAX_SIGMA) revert InvalidSigma();
        if (sd == 0 || sd > MAX_MAGNITUDE) revert InvalidSd();
        if (FixedPointMathLib.abs(x) > MAX_MAGNITUDE) revert InvalidLogReturn();
    }

    /// @dev The vol-mix CDF at inner edge m: the normal CDF averaged over a 3-node Gauss-Hermite mixture of the
    ///      sd, sd_i = sd * exp(0.2 x_i - 0.02) with x = -sqrt3, 0, sqrt3 and weights 1/6, 2/3, 1/6. Each node
    ///      uses its own sd in z, drift included. Error: the 2 wei of each CDF plus 1 wei of the division.
    function _cdfMix(uint256 sigma, uint256 m, int256 x, uint256 sd) internal pure returns (uint256) {
        (uint256 sdLo, uint256 sdMid, uint256 sdHi) = _mixSd(sd);
        return _mixAt((_edge(sigma, m) - x) * int256(WAD), sdLo, sdMid, sdHi);
    }

    /// @dev The sds of the three vol-mix nodes. A node sd that truncates to 0 is set to 1 (sdHi cannot:
    ///      MIX_HI is above 1e18).
    function _mixSd(uint256 sd) internal pure returns (uint256 sdLo, uint256 sdMid, uint256 sdHi) {
        sdLo = sd * MIX_LO / WAD;
        if (sdLo == 0) sdLo = 1;
        sdMid = sd * MIX_MID / WAD;
        if (sdMid == 0) sdMid = 1;
        sdHi = sd * MIX_HI / WAD;
    }

    /// @dev The vol-mix CDF from ex = (edge - x) * 1e18 and the three node sds. The node z is
    ///      ex / sd_i + sd_i / 2: the integer expression of `_z`.
    function _mixAt(int256 ex, uint256 sdLo, uint256 sdMid, uint256 sdHi) internal pure returns (uint256) {
        // Bound: each CDF is at most 1e18, so the weighted sum is at most 6e18.
        unchecked {
            return (Gaussian.cdf(_zNode(ex, sdLo))
                    + 4
                    * Gaussian.cdf(_zNode(ex, sdMid))
                    + Gaussian.cdf(_zNode(ex, sdHi))) / 6;
        }
    }

    /// @dev ex / sdN + sdN / 2 for a node sd from `_mixSd` (1 <= sdN < 2^196).
    function _zNode(int256 ex, uint256 sdN) private pure returns (int256) {
        // Bound: sdN >= 1 and below 2^196, so int256(sdN) is positive and sdN / 2 < 2^195. If sdN == 1 the
        // second term is 0; else |ex / sdN| <= 2^254. The sum fits in either case.
        unchecked {
            return ex / int256(sdN) + int256(sdN / 2);
        }
    }

    /// @dev Band probabilities: differences of the vol-mix CDF (`_cdfMix`) at the 39 edges, floored at 1e-4,
    ///      then renormalised. The division dust (below 40 wei) goes to the largest band so the sum is exactly
    ///      1e18.
    function _prior(uint256 sigma, int256 x, uint256 sd) internal pure returns (uint256[40] memory pi) {
        _checkAnchor(sigma, x, sd);
        (uint256 sdLo, uint256 sdMid, uint256 sdHi) = _mixSd(sd);
        uint256 prev;
        uint256 sum;
        uint256 total;
        uint256 top;
        // Bound: |x| <= 1e36 and |edge| < 4.8e18, so |ex| < 1.1e54. Each c is at most 1e18, so each raw band
        // is at most 1e18 and the sum below 41e18; each q is at most 1e18 and the total at most 1e18.
        unchecked {
            for (uint256 j; j < BANDS; ++j) {
                uint256 c = WAD;
                if (j < EDGES) c = _mixAt((_edge(sigma, j) - x) * int256(WAD), sdLo, sdMid, sdHi);
                // The CDF is monotone up to its 2 wei error; never let that produce a negative band.
                if (c < prev) c = prev;
                uint256 raw = c - prev;
                if (raw < PRIOR_FLOOR) raw = PRIOR_FLOOR;
                pi[j] = raw;
                sum += raw;
                prev = c;
            }
            // The first largest band takes the dust.
            uint256 topQ;
            for (uint256 j; j < BANDS; ++j) {
                uint256 q = pi[j] * WAD / sum;
                pi[j] = q;
                total += q;
                if (q > topQ) {
                    topQ = q;
                    top = j;
                }
            }
        }
        pi[top] += WAD - total;
    }

    /// @dev Vega(e) = phi(z) * (z - sd) for inner edge m, truncated.
    function _edgeVega(uint256 sigma, uint256 m, int256 x, uint256 sd) internal pure returns (int256) {
        int256 z = _z(sigma, m, x, sd);
        uint256 density = Gaussian.pdf(z);
        if (density == 0) return 0;
        // density > 0 means |z| < 9.2e18.
        return int256(density) * (z - int256(sd)) / int256(WAD);
    }

    /// @dev |Vega(lower edge) - Vega(upper edge)| per share, rounded up by the error allowance.
    function _vega(uint256 sigma, int256 x, uint256 sd, uint256 lo, uint256 hi)
        internal
        pure
        returns (uint256 vega)
    {
        int256 lower;
        int256 upper;
        if (lo > 0) {
            lower = _edgeVega(sigma, lo - 1, x, sd);
            vega += VEGA_DUST;
        }
        if (hi < BANDS - 1) {
            upper = _edgeVega(sigma, hi, x, sd);
            vega += VEGA_DUST;
        }
        vega += FixedPointMathLib.abs(lower - upper);
    }

    /*//////////////////////////////////////////////////////////////
                                 BOOK
    //////////////////////////////////////////////////////////////*/

    /// @dev Copies the pricing state to memory and checks its bound.
    function _loadState(int256[40] calldata v) internal pure returns (int256[40] memory w) {
        uint256 bad;
        // Bound: the offsets stay inside the 40 words of v and w. See `_outOfRange` for the compare.
        assembly ("memory-safe") {
            for { let o := 0 } lt(o, 1280) { o := add(o, 32) } {
                let vj := calldataload(add(v, o))
                // |v_j| > 1e36, as in `_outOfRange`
                let shifted := add(vj, 1000000000000000000000000000000000000)
                let big := gt(shifted, 2000000000000000000000000000000000000)
                bad := or(bad, big)
                mstore(add(w, o), vj)
            }
        }
        if (bad != 0) revert InvalidState();
    }

    /// @dev True if any |w_j| is above 1e36.
    function _outOfRange(int256[40] memory w) private pure returns (bool bad) {
        // Bound: w_j + 1e36 wraps (mod 2^256) only for w_j < -1e36, to a value above 2^255; it never wraps
        // for w_j >= -1e36 (w_j < 2^255). So the unsigned compare is exactly |w_j| > 1e36.
        assembly ("memory-safe") {
            for { let o := 0 } lt(o, 1280) { o := add(o, 32) } {
                let shifted := add(mload(add(w, o)), 1000000000000000000000000000000000000)
                let big := gt(shifted, 2000000000000000000000000000000000000)
                bad := or(bad, big)
            }
        }
    }

    /// @dev Prior and its logarithms. Depths are set separately with `_setDepth`.
    function _book(uint256 sigma, int256 x, uint256 sd) internal pure returns (Book memory bk) {
        uint256[40] memory pi = _prior(sigma, x, sd);
        bk.pi = pi;
        int256[40] memory lnPi = bk.lnPi;
        // Bound: the offsets stay inside the 40 words of pi and lnPi.
        unchecked {
            for (uint256 o; o < 1280; o += 32) {
                int256 pj;
                assembly ("memory-safe") {
                    pj := mload(add(pi, o))
                }
                int256 l = FixedPointMathLib.lnWad(pj);
                assembly ("memory-safe") {
                    mstore(add(lnPi, o), l)
                }
            }
        }
    }

    /// @dev Sets the depths of the book to b0 * g (kept as the exact product, never divided by 1e18).
    ///      Every caller checks g <= 1e18.
    function _setDepth(Book memory bk, uint256[40] calldata b0, uint256 g) internal pure {
        uint256[40] memory bgs = bk.bg;
        uint256[40] memory pi = bk.pi;
        uint256 bgMax;
        uint256 bPi;
        // Bound: b <= 1e33 is checked before the product and g <= 1e18, so bg <= 1e51; pi_j <= 1e18, so each
        // bg * pi_j is at most 1e69 and the sum below 4.1e70.
        unchecked {
            for (uint256 o; o < 1280; o += 32) {
                uint256 b;
                uint256 pj;
                assembly ("memory-safe") {
                    b := calldataload(add(b0, o))
                    pj := mload(add(pi, o))
                }
                if (b > MAX_DEPTH) revert InvalidDepth();
                uint256 bg = b * g;
                if (bg < MIN_SCALED_DEPTH) revert InvalidDepth();
                assembly ("memory-safe") {
                    mstore(add(bgs, o), bg)
                }
                if (bg > bgMax) bgMax = bg;
                bPi += bg * pj;
            }
        }
        bk.bgMax = bgMax;
        bk.bPi = bPi;
    }

    /// @dev v_j <- centre + (v_j - centre) * gNew / gOld, truncated: off by less than 1 wei per band.
    function _rescale(int256[40] memory w, int256 centre, uint256 gNew, uint256 gOld) internal pure {
        // Bound: |v_j| <= 1e36 and the centre (a root inside the solve's bracket) is within 1.01e36 of 0, so
        // |v_j - centre| < 2.02e36; gNew <= 1e18 makes the product below 2.1e54; gOld > 0 (fill checks
        // 0 < gNew <= gOld <= 1e18). sdiv truncates toward zero, as Solidity's signed division does.
        assembly ("memory-safe") {
            for { let o := 0 } lt(o, 1280) { o := add(o, 32) } {
                let p := add(w, o)
                mstore(p, add(centre, sdiv(mul(sub(mload(p), centre), gNew), gOld)))
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             LAMBDA SOLVE
    //////////////////////////////////////////////////////////////*/

    /// @dev Root of g(lambda) = ln sum_j exp(ln pi_j + (v_j - lambda) / b_j).
    ///      Bracket: no price can exceed 1, so lambda* >= max_j (v_j + b_j ln pi_j), which lies inside the
    ///      spec's [min_j (v_j + b_j ln pi_j), max_j v_j]. At that lower end 0 <= g <= ln 40. g is convex
    ///      and decreasing, so Newton started there increases monotonically to the root and never
    ///      overshoots; steps that leave the bracket (possible only through rounding) fall back to bisection.
    ///      The result is validated by the caller (`_quote`), not here.
    ///      A `start` strictly inside the bracket (a warm start) is taken as the first point instead of
    ///      the lower end. From the left of the root Newton climbs as above; from the right its first step
    ///      lands at or left of the root (g convex: the tangent lies below g), and the bracket keeps every
    ///      later step inside. `COLD` starts at the lower end.
    function _solve(int256[40] memory w, Book memory bk, int256 start) internal pure returns (int256 lam) {
        (lam,) = _solveCounted(w, bk, start);
    }

    /// @dev `_solve` plus the number of log-sum evaluations it took (for tests).
    function _solveCounted(int256[40] memory w, Book memory bk, int256 start)
        internal
        pure
        returns (int256 lam, uint256 evaluations)
    {
        (int256 lo, int256 hi) = _bracket(w, bk);
        lam = start > lo && start < hi ? start : lo;
        while (evaluations < MAX_ITERATIONS) {
            ++evaluations;
            (int256 g, uint256 s, uint256 d) = _logSum(w, bk, lam);
            uint256 gAbs = FixedPointMathLib.abs(g);
            if (gAbs <= LOG_TOL) break;
            if (g > 0) lo = lam;
            else hi = lam;
            if (hi - lo <= 1) break;
            // Newton step g / |g'| in wei: g * S / sum_j (e_j / b_j). gAbs * s < 2e68 and d >= 1e21.
            uint256 step = FixedPointMathLib.fullMulDiv(gAbs * s, WAD, d);
            if (step == 0) break;
            int256 next = g > 0 ? lam + int256(step) : lam - int256(step);
            if (next <= lo || next >= hi) next = lo + (hi - lo) / 2;
            lam = next;
        }
    }

    /// @dev The solve's bracket: lo = max_j (v_j + b_j ln pi_j) - 1, hi = max_j v_j + 1.
    function _bracket(int256[40] memory w, Book memory bk) private pure returns (int256 lo, int256 hi) {
        uint256[40] memory bg = bk.bg;
        int256[40] memory lnPi = bk.lnPi;
        lo = type(int256).min;
        hi = type(int256).min;
        // v_j + b_j * ln(pi_j), rounded down. Bound: bg <= 1e51 and 0 <= -ln(pi_j) < 9.3e18, so the product
        // is below 9.3e69 and the rounded quotient below 9.3e33; |v_j| < 2.01e36, so the difference fits.
        assembly ("memory-safe") {
            for { let o := 0 } lt(o, 1280) { o := add(o, 32) } {
                let wj := mload(add(w, o))
                let prod := mul(mload(add(bg, o)), sub(0, mload(add(lnPi, o))))
                let up := add(prod, 999999999999999999999999999999999999)
                up := div(up, 1000000000000000000000000000000000000)
                let floorJ := sub(wj, up)
                if sgt(floorJ, lo) { lo := floorJ }
                if sgt(wj, hi) { hi := wj }
            }
        }
        lo -= 1;
        hi += 1;
    }

    /// @dev Log-sum-exp evaluation: g = ln sum_j exp(a_j) with a_j = ln pi_j + (v_j - lambda) / b_j, taken
    ///      as max a + ln sum exp(a_j - max a) so no exponential can overflow.
    /// @return g ln of the price sum, WAD
    /// @return s sum_j exp(a_j - max a), WAD, in [1e18, 40e18]
    /// @return d sum_j exp(a_j - max a) / b_j, scaled so that the Newton step is g * s * 1e18 / d
    function _logSum(int256[40] memory w, Book memory bk, int256 lam)
        private
        pure
        returns (int256 g, uint256 s, uint256 d)
    {
        int256[40] memory a = bk.scratch;
        int256[40] memory lnPi = bk.lnPi;
        uint256[40] memory bg = bk.bg;
        int256 top = type(int256).min;
        // Bound: |v_j| < 2.01e36 (state, delta and rescale dust) and lambda lies inside the bracket, so
        // |v_j - lambda| < 4.1e36 and times 1e36 is below 4.1e72; bg_j >= 1e24 (`_setDepth`), so the
        // quotient is below 4.1e48 and adding ln(pi_j) fits.
        assembly ("memory-safe") {
            for { let o := 0 } lt(o, 1280) { o := add(o, 32) } {
                let num := mul(sub(mload(add(w, o)), lam), 1000000000000000000000000000000000000)
                let aj := add(mload(add(lnPi, o)), sdiv(num, mload(add(bg, o))))
                mstore(add(a, o), aj)
                if sgt(aj, top) { top := aj }
            }
        }
        // Bound: a_j - top is in [-8.3e48, 0], so e_j <= 1e18; e_j * 1e54 <= 1e72 and bg_j >= 1e24, so
        // each term of d is below 1e48; s <= 40e18.
        unchecked {
            for (uint256 o; o < 1280; o += 32) {
                int256 aj;
                assembly ("memory-safe") {
                    aj := mload(add(a, o))
                }
                uint256 e = uint256(FixedPointMathLib.expWad(aj - top));
                s += e;
                assembly ("memory-safe") {
                    let num := mul(e, 1000000000000000000000000000000000000000000000000000000)
                    d := add(d, div(num, mload(add(bg, o))))
                }
            }
        }
        g = top + FixedPointMathLib.lnWad(int256(s));
    }

    /*//////////////////////////////////////////////////////////////
                                 COST
    //////////////////////////////////////////////////////////////*/

    /// @dev Prices, cost and error bound at a solved lambda. Reverts unless the prices sum to 1 within 1e-12.
    function _quote(int256[40] memory w, Book memory bk, int256 lam) internal pure returns (Quote memory q) {
        uint256[40] memory p = q.p;
        uint256[40] memory pi = bk.pi;
        uint256[40] memory bg = bk.bg;
        uint256 s;
        uint256 t;
        // Bound: u as in `_logSum` (|v_j - lambda| < 4.1e36, bg_j >= 1e24). u <= 60e18 keeps
        // pi_j * exp(u) below 1.2e62; past the checks each p_j <= 2e18 and each term of t is below 2e69.
        unchecked {
            for (uint256 o; o < 1280; o += 32) {
                int256 u;
                uint256 bgj;
                uint256 pij;
                assembly ("memory-safe") {
                    bgj := mload(add(bg, o))
                    pij := mload(add(pi, o))
                    u := sdiv(mul(sub(mload(add(w, o)), lam), 1000000000000000000000000000000000000), bgj)
                }
                if (u > MAX_EXPONENT) revert LambdaNotConverged();
                // pi_j * exp(u_j) at 1e36 scale. A price above 2 cannot belong to a converged state.
                uint256 pe = pij * uint256(FixedPointMathLib.expWad(u));
                if (pe > 2e36) revert LambdaNotConverged();
                uint256 pj = pe / WAD;
                assembly ("memory-safe") {
                    mstore(add(p, o), pj)
                }
                s += pj;
                // b_j * p_j in wei, times 1e36. Below 2e69 per band.
                t += FixedPointMathLib.fullMulDiv(bgj, pe, WAD);
            }
        }
        uint256 ds = s > WAD ? s - WAD : WAD - s;
        if (ds > SUM_TOL) revert LambdaNotConverged();

        q.cost = lam + _floorDiv(int256(t) - int256(bk.bPi), 1e36);

        // Evaluation error plus the second-order lambda error |1 - S| * |ln S| * bMax <= 2 * dS^2 * bMax.
        ds += SUM_ERR;
        q.slack = _ceilDiv(EVAL_ERR * bk.bgMax, 1e36) + 2 * _ceilDiv(ds * ds * bk.bgMax, 1e54) + EVAL_DUST;
    }

    /// @dev Amount of a trade from the two cost evaluations, rounded against the trader.
    function _amount(Quote memory q0, Quote memory q1, uint256 pBefore, int256 delta)
        internal
        pure
        returns (uint256)
    {
        int256 margin = int256(q0.slack + q1.slack + RESCALE_DUST);
        uint256 size = FixedPointMathLib.abs(delta);
        if (delta > 0) {
            // Buy: never below the true C(v') - C(v), and never below size * pBefore.
            int256 cost = q1.cost - q0.cost + margin;
            uint256 amount = cost > 0 ? uint256(cost) : 0;
            uint256 least = FixedPointMathLib.fullMulDivUp(size, pBefore, WAD);
            return amount > least ? amount : least;
        }
        // Sell: never above the true C(v) - C(v'), and never above size * pBefore.
        int256 proceeds = q0.cost - q1.cost - margin;
        if (proceeds <= 0) return 0;
        uint256 most = FixedPointMathLib.fullMulDiv(size, pBefore, WAD);
        return uint256(proceeds) < most ? uint256(proceeds) : most;
    }

    /// @dev Sum of the prices of bands lo..hi, capped at 1e18.
    function _setPrice(uint256[40] memory p, uint256 lo, uint256 hi) internal pure returns (uint256 sum) {
        for (uint256 j = lo; j <= hi; ++j) {
            sum += p[j];
        }
        if (sum > WAD) sum = WAD;
    }

    /// @dev a / d rounded toward minus infinity, for d > 0.
    function _floorDiv(int256 a, int256 d) private pure returns (int256 q) {
        q = a / d;
        if (a % d < 0) q -= 1;
    }

    /// @dev a / d rounded up.
    function _ceilDiv(uint256 a, uint256 d) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / d + 1;
    }
}
