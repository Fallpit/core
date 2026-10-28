// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ILadderMath
/// @notice Stateless pricing engine of a Fallpit round: an oracle-anchored, depth-weighted LMSR over
///         40 bands of the close's log return. See contracts/SPEC.md section 3.
/// @dev All values are WAD (1e18) fixed point unless stated. Band j (0..39) is the interval
///      [edge(j-1), edge(j)) of x = ln(close / S0), where edge(m) = (m - 19) * sigma / 4 for m in 0..38,
///      edge(-1) = -inf and edge(39) = +inf. A set is a contiguous run of bands [lo, hi], both inclusive.
interface ILadderMath {
    /// @param x ln(S_t / S0) from the fill's oracle price
    /// @param sd remaining standard deviation of the close's log return, > 0
    /// @param gOld depth scale the stored pricing state `v` is expressed at, in (0, 1e18]
    /// @param gNew depth scale now, in (0, gOld]: depth never rises during a round
    struct Ctx {
        int256 x;
        uint256 sd;
        uint256 gOld;
        uint256 gNew;
    }

    /// @param v new pricing state, expressed at depth scale gNew
    /// @param amount cost of a buy (rounded up) or proceeds of a sell (rounded down), before fees
    /// @param pBefore price of the set after re-anchoring and before the trade
    /// @param pAfter price of the set after the trade
    /// @param vega |Vega(lower edge of the set) - Vega(upper edge)| per share, where
    ///        Vega(e) = phi(z) * (z - sd), z = (e - x) / sd + sd / 2, and Vega of an infinite edge is 0
    struct Fill {
        int256[40] v;
        uint256 amount;
        uint256 pBefore;
        uint256 pAfter;
        uint256 vega;
    }

    /// @notice Depth per band at the open: b0[j] = alpha * capital / ln(1 / pi_j(open)), with
    ///         pi(open) = prior(sigma, 0, sigma).
    function openDepths(uint256 sigma, uint256 capital, uint256 alpha)
        external
        pure
        returns (uint256[40] memory b0);

    /// @notice The part of the open depths that depends on sigma alone: ln(1 / pi_j(open)) per band,
    ///         WAD, packed four to a word (band j at bits 64 * (j % 4) of word j / 4). Each is below 9.3e18,
    ///         so it fits 64 bits. `openDepths(sigma, capital, alpha) == depths(openLnInv(sigma), capital,
    ///         alpha)` always.
    function openLnInv(uint256 sigma) external pure returns (uint256[10] memory packed);

    /// @notice Depth per band from `openLnInv`: b0[j] = alpha * capital / lnInv_j, with the checks of
    ///         `openDepths`.
    function depths(uint256[10] calldata packed, uint256 capital, uint256 alpha)
        external
        pure
        returns (uint256[40] memory b0);

    /// @notice Lognormal band probabilities of the close given the current log return `x` and the
    ///         remaining standard deviation `sd`, floored at 1e-4 per band and renormalised to sum to 1e18.
    function prior(uint256 sigma, int256 x, uint256 sd) external pure returns (uint256[40] memory pi);

    /// @notice Current band prices p_j = pi_j * exp((v_j - lambda) / b_j), with b_j = b0[j] * gOld and
    ///         lambda solved so the prices sum to 1e18.
    function prices(int256[40] calldata v, uint256[40] calldata b0, uint256 sigma, Ctx calldata ctx)
        external
        pure
        returns (uint256[40] memory p);

    /// @notice Prices one trade of `delta` shares of the set [lo, hi]: re-anchor the prior to ctx.x and
    ///         ctx.sd, rescale the pricing state from depth gOld to gNew without moving any price, then
    ///         charge C(v') - C(v). delta > 0 buys, delta < 0 sells.
    function fill(
        int256[40] calldata v,
        uint256[40] calldata b0,
        uint256 sigma,
        Ctx calldata ctx,
        uint8 lo,
        uint8 hi,
        int256 delta
    ) external pure returns (Fill memory);

    /// @notice Log return of inner edge m (0..38): (m - 19) * sigma / 4.
    function edge(uint256 sigma, uint8 m) external pure returns (int256);

    /// @notice Band that a log return falls in: the number of inner edges that are <= x.
    function bandOf(uint256 sigma, int256 x) external pure returns (uint8);
}
