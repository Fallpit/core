// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LadderMath} from "../../src/LadderMath.sol";
import {Gaussian} from "../../src/lib/Gaussian.sol";

/// @notice Exposes LadderMath internals so tests can feed an exact integer prior (instead of the on-chain
///         one) and read the cost and its error bound, plus the Gaussian library and solady's expWad.
contract LadderMathHarness is LadderMath {
    struct Trade {
        uint256 amount;
        int256 cost0;
        uint256 slack0;
        int256 cost1;
        uint256 slack1;
        uint256 pBefore;
    }

    function cdf(int256 z) external pure returns (uint256) {
        return Gaussian.cdf(z);
    }

    function pdf(int256 z) external pure returns (uint256) {
        return Gaussian.pdf(z);
    }

    /// @notice The vol-mix CDF of the prior at inner edge m.
    function cdfMix(uint256 sigma, uint256 m, int256 x, uint256 sd) external pure returns (uint256) {
        return _cdfMix(sigma, m, x, sd);
    }

    /// @notice The node multipliers of the vol mix.
    function mixNodes() external pure returns (uint256 lo, uint256 mid, uint256 hi) {
        return (MIX_LO, MIX_MID, MIX_HI);
    }

    function expWad(int256 x) external pure returns (int256) {
        return FixedPointMathLib.expWad(x);
    }

    /// @notice The margin constants, so tests can state tolerances in terms of them.
    function constants() external pure returns (uint256 evalErr, uint256 evalDust, uint256 rescaleDust) {
        return (EVAL_ERR, EVAL_DUST, RESCALE_DUST);
    }

    /// @notice Number of log-sum evaluations the lambda solve takes for a state, with the on-chain prior.
    function solveEvaluations(int256[40] calldata v, uint256[40] calldata b0, uint256 sigma, Ctx calldata ctx)
        external
        pure
        returns (uint256 evaluations)
    {
        // `_setDepth` needs g <= 1e18, as `prices` checks.
        if (ctx.gOld == 0 || ctx.gOld > WAD) revert InvalidDepthScale();
        int256[40] memory w = _loadState(v);
        Book memory bk = _book(sigma, ctx.x, ctx.sd);
        _setDepth(bk, b0, ctx.gOld);
        (, evaluations) = _solveCounted(w, bk, COLD);
    }

    /// @notice Steps 3 to 5 of `fill` with a caller-supplied prior and no rescale.
    function tradeGiven(
        int256[40] calldata v,
        uint256[40] calldata pi,
        uint256[40] calldata b0,
        uint256 g,
        uint8 lo,
        uint8 hi,
        int256 delta
    ) external pure returns (Trade memory t) {
        // The book's loops need g <= 1e18 and every pi_j in (0, 1e18], as the on-chain prior has.
        if (g == 0 || g > WAD) revert InvalidDepthScale();
        int256[40] memory w = _loadState(v);
        Book memory bk;
        for (uint256 j; j < BANDS; ++j) {
            require(pi[j] <= WAD, "prior above 1");
            bk.pi[j] = pi[j];
            bk.lnPi[j] = FixedPointMathLib.lnWad(int256(pi[j]));
        }
        _setDepth(bk, b0, g);
        Quote memory q0 = _quote(w, bk, _solve(w, bk, COLD));
        t.pBefore = _setPrice(q0.p, lo, hi);
        for (uint256 j = lo; j <= hi; ++j) {
            w[j] += delta;
        }
        Quote memory q1 = _quote(w, bk, _solve(w, bk, COLD));
        t.amount = delta == 0 ? 0 : _amount(q0, q1, t.pBefore, delta);
        (t.cost0, t.slack0, t.cost1, t.slack1) = (q0.cost, q0.slack, q1.cost, q1.slack);
    }
}
