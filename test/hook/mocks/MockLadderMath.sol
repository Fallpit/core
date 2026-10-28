// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ILadderMath} from "../../../src/interfaces/ILadderMath.sol";

/// @title MockLadderMath
/// @notice A small but internally consistent stand-in for LadderMath: the same depth-weighted LMSR over 40
///         bands (p_j = pi_j * exp((v_j - lambda) / b_j), C = lambda + sum b_j (p_j - pi_j)) with the same
///         rescale-then-trade order, so cash-conservation and round-trip tests against the hook mean
///         something. It is not the real engine: the prior uses a logistic curve instead of the normal
///         CDF, lambda comes from plain Newton steps, and `vega` is a constant.
/// @dev Costs carry a numerical guard against the trader (added to buys, taken off sells) that is larger
///      than the fixed-point error of the exponentials, so no sequence of trades at one prior can profit.
contract MockLadderMath is ILadderMath {
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;
    int256 internal constant IWAD = 1e18;
    uint256 internal constant FLOOR = 1e14;
    /// @dev Logistic scale that approximates the normal CDF.
    int256 internal constant LOGISTIC_K = 1.702e18;
    uint256 internal constant TOL = 1e6;
    /// @notice Constant vega per share returned by `fill`.
    uint256 public constant VEGA = 0.03e18;

    error NotConverged();
    error DepthIncrease();

    /// @inheritdoc ILadderMath
    function edge(uint256 sigma, uint8 m) public pure returns (int256) {
        return (int256(uint256(m)) - 19) * int256(sigma) / 4;
    }

    /// @inheritdoc ILadderMath
    function bandOf(uint256 sigma, int256 x) external pure returns (uint8 band) {
        for (uint8 m; m < 39; ++m) {
            if (edge(sigma, m) <= x) ++band;
        }
    }

    /// @inheritdoc ILadderMath
    function prior(uint256 sigma, int256 x, uint256 sd) public pure returns (uint256[40] memory pi) {
        uint256 previous;
        uint256 sum;
        for (uint8 j; j < 40; ++j) {
            uint256 cdf = WAD;
            if (j < 39) {
                int256 z = (edge(sigma, j) - x) * IWAD / int256(sd) + int256(sd) / 2;
                int256 y = -(LOGISTIC_K * z / IWAD);
                if (y > 40e18) y = 40e18;
                if (y < -40e18) y = -40e18;
                cdf = WAD * WAD / (WAD + uint256(FixedPointMathLib.expWad(y)));
                if (cdf < previous) cdf = previous;
            }
            uint256 mass = cdf - previous;
            previous = cdf;
            if (mass < FLOOR) mass = FLOOR;
            pi[j] = mass;
            sum += mass;
        }
        // renormalise to exactly 1e18; the rounding remainder goes to the largest band
        uint256 total;
        uint256 largest;
        for (uint8 j; j < 40; ++j) {
            pi[j] = pi[j] * WAD / sum;
            total += pi[j];
            if (pi[j] > pi[largest]) largest = j;
        }
        pi[largest] += WAD - total;
    }

    /// @inheritdoc ILadderMath
    function openDepths(uint256 sigma, uint256 capital, uint256 alpha)
        external
        pure
        returns (uint256[40] memory b0)
    {
        uint256[40] memory pi = prior(sigma, 0, sigma);
        for (uint8 j; j < 40; ++j) {
            b0[j] = alpha * capital / uint256(-FixedPointMathLib.lnWad(int256(pi[j])));
        }
    }

    /// @inheritdoc ILadderMath
    function openLnInv(uint256 sigma) public pure returns (uint256[10] memory packed) {
        uint256[40] memory pi = prior(sigma, 0, sigma);
        for (uint256 j; j < 40; ++j) {
            packed[j / 4] |= uint256(-FixedPointMathLib.lnWad(int256(pi[j]))) << (64 * (j % 4));
        }
    }

    /// @inheritdoc ILadderMath
    function depths(uint256[10] calldata packed, uint256 capital, uint256 alpha)
        external
        pure
        returns (uint256[40] memory b0)
    {
        for (uint256 j; j < 40; ++j) {
            b0[j] = alpha * capital / ((packed[j / 4] >> (64 * (j % 4))) & type(uint64).max);
        }
    }

    /// @inheritdoc ILadderMath
    function prices(int256[40] calldata v, uint256[40] calldata b0, uint256 sigma, Ctx calldata ctx)
        external
        pure
        returns (uint256[40] memory p)
    {
        uint256[40] memory pi = prior(sigma, ctx.x, ctx.sd);
        int256[40] memory vm = v;
        (, p) = _solve(vm, _depths(b0, ctx.gOld), pi);
    }

    /// @inheritdoc ILadderMath
    function fill(
        int256[40] calldata v,
        uint256[40] calldata b0,
        uint256 sigma,
        Ctx calldata ctx,
        uint8 lo,
        uint8 hi,
        int256 delta
    ) external pure virtual returns (Fill memory f) {
        if (ctx.gNew > ctx.gOld) revert DepthIncrease();
        uint256[40] memory pi = prior(sigma, ctx.x, ctx.sd);
        f.v = v;

        // re-anchor at the old depth, then rescale v so that no price moves
        if (ctx.gNew != ctx.gOld) {
            (int256 lambda1,) = _solve(f.v, _depths(b0, ctx.gOld), pi);
            for (uint8 j; j < 40; ++j) {
                f.v[j] = lambda1 + (f.v[j] - lambda1) * int256(ctx.gNew) / int256(ctx.gOld);
            }
        }

        uint256[40] memory b = _depths(b0, ctx.gNew);
        (int256 costBefore, uint256 pBefore) = _costAndPrice(f.v, b, pi, lo, hi);
        for (uint8 j = lo; j <= hi; ++j) {
            f.v[j] += delta;
        }
        (int256 costAfter, uint256 pAfter) = _costAndPrice(f.v, b, pi, lo, hi);

        uint256 guard = _guard(b);
        if (delta > 0) {
            int256 cost = costAfter - costBefore;
            f.amount = (cost > 0 ? uint256(cost) : 0) + guard;
        } else {
            int256 proceeds = costBefore - costAfter;
            f.amount = proceeds > int256(guard) ? uint256(proceeds) - guard : 0;
        }
        f.pBefore = pBefore;
        f.pAfter = pAfter;
        f.vega = VEGA;
    }

    function _depths(uint256[40] calldata b0, uint256 g) private pure returns (uint256[40] memory b) {
        for (uint8 j; j < 40; ++j) {
            b[j] = b0[j] * g / WAD;
        }
    }

    /// @dev Larger than the summed fixed-point error of 40 exponentials at depth b.
    function _guard(uint256[40] memory b) private pure returns (uint256 guard) {
        for (uint8 j; j < 40; ++j) {
            guard += b[j];
        }
        guard = guard / 1e12 + 1;
    }

    function _costAndPrice(
        int256[40] memory v,
        uint256[40] memory b,
        uint256[40] memory pi,
        uint8 lo,
        uint8 hi
    ) private pure returns (int256 cost, uint256 setPrice) {
        (int256 lambda, uint256[40] memory p) = _solve(v, b, pi);
        cost = lambda;
        for (uint8 j; j < 40; ++j) {
            cost += int256(b[j]) * (int256(p[j]) - int256(pi[j])) / IWAD;
            if (j >= lo && j <= hi) setPrice += p[j];
        }
    }

    /// @dev Newton from the left end of the bracket. There every term pi_j * exp((v_j - lambda) / b_j) is
    ///      at most 1, so nothing overflows, and since the sum is convex and decreasing in lambda the
    ///      iterates rise monotonically to the root.
    function _solve(int256[40] memory v, uint256[40] memory b, uint256[40] memory pi)
        private
        pure
        returns (int256 lambda, uint256[40] memory p)
    {
        lambda = type(int256).min;
        for (uint8 j; j < 40; ++j) {
            int256 bound = v[j] + int256(b[j]) * FixedPointMathLib.lnWad(int256(pi[j])) / IWAD;
            if (bound > lambda) lambda = bound;
        }
        for (uint256 i; i < 96; ++i) {
            uint256 sum;
            uint256 slope;
            for (uint8 j; j < 40; ++j) {
                int256 e = (v[j] - lambda) * IWAD / int256(b[j]);
                p[j] = e < -41e18 ? 0 : pi[j] * uint256(FixedPointMathLib.expWad(e)) / WAD;
                sum += p[j];
                slope += p[j] * WAD / b[j];
            }
            if (sum <= WAD + TOL) {
                if (sum + TOL * 1e3 < WAD) revert NotConverged();
                return (lambda, p);
            }
            uint256 step = (sum - WAD) * WAD / slope;
            if (step == 0) return (lambda, p);
            lambda += int256(step);
        }
        revert NotConverged();
    }
}
