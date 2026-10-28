// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ILadderMath} from "../../src/interfaces/ILadderMath.sol";
import {LadderMathHarness} from "./LadderMathHarness.sol";

/// @notice Shared helpers of the LadderMath tests: vector slicing, tolerances and random scenarios inside
///         the fuzz domain of SPEC section 3.
abstract contract LadderMathBase is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BANDS = 40;

    LadderMathHarness internal math;

    /// @dev A round somewhere inside the fuzz domain, with a pricing state reached by real fills.
    struct Scn {
        uint256 sigma;
        uint256 capital;
        uint256 alpha;
        uint256 g;
        int256 x;
        uint256 sd;
        uint256[40] b0;
        int256[40] v;
    }

    function setUp() public virtual {
        math = new LadderMathHarness();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _ctx(int256 x, uint256 sd, uint256 gOld, uint256 gNew)
        internal
        pure
        returns (ILadderMath.Ctx memory)
    {
        return ILadderMath.Ctx({x: x, sd: sd, gOld: gOld, gNew: gNew});
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _slice(uint256[] memory a, uint256 i) internal pure returns (uint256[40] memory out) {
        for (uint256 j; j < BANDS; ++j) {
            out[j] = a[i * BANDS + j];
        }
    }

    function _slice(int256[] memory a, uint256 i) internal pure returns (int256[40] memory out) {
        for (uint256 j; j < BANDS; ++j) {
            out[j] = a[i * BANDS + j];
        }
    }

    function _max(uint256[40] memory a) internal pure returns (uint256 m) {
        for (uint256 j; j < BANDS; ++j) {
            if (a[j] > m) m = a[j];
        }
    }

    /// @dev Upper bound of |amount of a fill - exact cost difference|. A fill makes two cost evaluations,
    ///      each with slack = EVAL_ERR * 1e-18 * bMax + lambda term + EVAL_DUST. The lambda term is at most
    ///      2 * (1e-12 + 1e-15)^2 * bMax, far below 1e-18 * bMax, so one extra unit of 1e-18 * bMax and a
    ///      few wei of ceilings cover it. The amount adds both slacks and RESCALE_DUST to a computed
    ///      difference that is itself within both slacks of the truth, so the distance is at most
    ///      2 * (slack + slack) + RESCALE_DUST. This is about 3.6e-17 of the largest depth.
    function _marginBound(uint256[40] memory b0, uint256 g) internal view returns (uint256) {
        (uint256 evalErr, uint256 evalDust, uint256 rescaleDust) = math.constants();
        uint256 bMax = _max(b0) * g / WAD + 1;
        return 4 * ((evalErr + 1) * bMax / WAD + 3 + evalDust) + rescaleDust;
    }

    /// @dev Room for the pBefore clamp of `fill`: a buy is charged at least size * pBefore and a sell is
    ///      paid at most size * pBefore, and pBefore carries the price-sum tolerance of 1e-12 (in practice
    ///      about 4e-17: the 40 band prices are each rounded down).
    function _clampTol(uint256 size) internal pure returns (uint256) {
        return size / 1e12 + 1;
    }

    /*//////////////////////////////////////////////////////////////
                           RANDOM SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function _rand(uint256 seed, uint256 tag) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, tag)));
    }

    /// @dev sigma in [0.005, 0.15], capital log-uniform in [1e17, 1e30] wei, alpha in [0.05, 0.79].
    function _round(uint256 seed) internal view returns (Scn memory s) {
        s.sigma = bound(_rand(seed, 1), 0.005e18, 0.15e18);
        s.capital = bound(_rand(seed, 2), 1e17, 1e18) * 10 ** bound(_rand(seed, 3), 0, 12);
        if (s.capital > 1e30 || _rand(seed, 3) % 16 == 0) s.capital = 1e30;
        s.alpha = bound(_rand(seed, 4), 0.05e18, 0.79e18);
        s.b0 = math.openDepths(s.sigma, s.capital, s.alpha);
        s.g = WAD;
        (s.x, s.sd) = _anchor(seed, 5, s.sigma);
    }

    /// @dev |x| <= 8 sigma, sd in [0.05 sigma, 1.5 sigma], with the corners over-represented.
    function _anchor(uint256 seed, uint256 tag, uint256 sigma) internal pure returns (int256 x, uint256 sd) {
        uint256 r = _rand(seed, tag);
        int256 span = int256(8 * sigma);
        uint256 corner = r % 16;
        if (corner == 0) x = span;
        else if (corner == 1) x = -span;
        else if (corner < 9) x = bound(int256(_rand(r, 1) >> 1), -span / 4, span / 4);
        else x = bound(int256(_rand(r, 1) >> 1), -span, span);
        corner = (r >> 8) % 8;
        if (corner == 0) sd = sigma / 20;
        else if (corner == 1) sd = sigma * 3 / 2;
        else sd = bound(_rand(r, 2), sigma / 20, sigma * 3 / 2);
    }

    /// @dev A contiguous set of bands.
    function _set(uint256 seed, uint256 tag) internal pure returns (uint8 lo, uint8 hi) {
        uint256 r = _rand(seed, tag);
        lo = uint8(r % BANDS);
        hi = uint8(lo + (r >> 8) % (BANDS - lo));
    }

    /// @dev A size log-uniform in [1 wei, capital], with capital itself over-represented.
    function _size(uint256 seed, uint256 tag, uint256 capital) internal pure returns (uint256 size) {
        uint256 r = _rand(seed, tag);
        if (r % 8 == 0) return capital;
        size = capital / 10 ** ((r >> 8) % 18) * (1 + (r >> 16) % 1000) / 1000;
        if (size == 0) size = 1;
    }

    /// @dev Applies up to `maxTrades` random fills (buys and sells, new anchors, depth decay down to 0.3).
    function _warm(Scn memory s, uint256 seed, uint256 maxTrades) internal view {
        uint256 n = _rand(seed, 10) % (maxTrades + 1);
        for (uint256 i; i < n; ++i) {
            uint256 sub = _rand(seed, 11 + i);
            (s.x, s.sd) = _anchor(sub, 1, s.sigma);
            uint256 gNew = _rand(sub, 2) % 2 == 0 ? s.g : bound(_rand(sub, 3), 0.3e18, s.g);
            (uint8 lo, uint8 hi) = _set(sub, 4);
            int256 delta = int256(_size(sub, 5, s.capital));
            if (_rand(sub, 6) % 3 == 0) delta = -delta;
            s.v = math.fill(s.v, s.b0, s.sigma, _ctx(s.x, s.sd, s.g, gNew), lo, hi, delta).v;
            s.g = gNew;
        }
    }

    /// @dev A warmed-up scenario with a fresh anchor.
    function _scenario(uint256 seed) internal view returns (Scn memory s) {
        s = _round(seed);
        _warm(s, seed, 3);
        (s.x, s.sd) = _anchor(seed, 7, s.sigma);
    }

    function _fill(Scn memory s, uint256 gNew, uint8 lo, uint8 hi, int256 delta)
        internal
        view
        returns (ILadderMath.Fill memory)
    {
        return math.fill(s.v, s.b0, s.sigma, _ctx(s.x, s.sd, s.g, gNew), lo, hi, delta);
    }
}
