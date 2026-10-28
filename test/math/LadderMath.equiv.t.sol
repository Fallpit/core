// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ILadderMath} from "../../src/interfaces/ILadderMath.sol";
import {LadderMath} from "../../src/LadderMath.sol";
import {Gaussian} from "../../src/lib/Gaussian.sol";
import {LadderMathRef} from "./LadderMathRef.sol";
import {GaussianRef} from "./GaussianRef.sol";

/// @notice Equivalence of LadderMath with LadderMathRef, a plain checked copy of the same formulas. Every
///         call goes to both contracts with the same calldata, and the success flag and the return or
///         revert bytes must be identical. Inputs come from the valid domain, its edges and outside it.
///         The same holds for Gaussian.cdf against GaussianRef.cdf.
/// forge-config: default.fuzz.runs = 5000
contract LadderMathEquivTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BANDS = 40;
    uint256 internal constant MAX_DEPTH = 1e33;
    uint256 internal constant MIN_SCALED_DEPTH = 1e24;
    int256 internal constant MAG = 1e36;
    uint256 internal constant SIGMA = 0.035e18;

    LadderMath internal neu;
    LadderMathRef internal ref;

    /// @dev One random call of `fill` or `prices`.
    struct Case {
        int256[40] v;
        uint256[40] b0;
        uint256 sigma;
        ILadderMath.Ctx ctx;
        uint8 lo;
        uint8 hi;
        int256 delta;
    }

    function setUp() public {
        neu = new LadderMath();
        ref = new LadderMathRef();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Calls both contracts and asserts the same outcome. Returns the success flag.
    function _same(bytes memory data) internal view returns (bool ok) {
        (bool okNew, bytes memory outNew) = address(neu).staticcall(data);
        (bool okRef, bytes memory outRef) = address(ref).staticcall(data);
        assertEq(okNew, okRef, "success differs");
        assertEq(outNew, outRef, "return or revert data differs");
        return okNew;
    }

    function _r(uint256 seed, uint256 tag) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, tag)));
    }

    /// @dev A value in [lo, hi].
    function _in(uint256 r, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + r % (hi - lo + 1);
    }

    /// @dev A value in [-m, m].
    function _sym(uint256 r, uint256 m) internal pure returns (int256) {
        int256 a = int256(r % (m + 1));
        return (r >> 255) == 1 ? -a : a;
    }

    /// @dev log-uniform in [1, 10^maxExp], roughly.
    function _logUni(uint256 r, uint256 maxExp) internal pure returns (uint256 out) {
        out = (1 + (r >> 8) % 1000) * 10 ** (r % (maxExp + 1)) / 1000;
        if (out == 0) out = 1;
    }

    /*//////////////////////////////////////////////////////////////
                               GENERATORS
    //////////////////////////////////////////////////////////////*/

    function _sigma(uint256 r) internal pure returns (uint256) {
        uint256 k = r % 16;
        if (k == 0) return 0;
        if (k == 1) return 1;
        if (k == 2) return WAD;
        if (k == 3) return WAD + 1;
        if (k == 4) return r >> 8;
        if (k == 5) return _in(r >> 8, 1, WAD);
        return _in(r >> 8, 0.005e18, 0.15e18);
    }

    function _x(uint256 r, uint256 sigma) internal pure returns (int256) {
        uint256 k = r % 16;
        if (k == 0) return 0;
        if (k == 1) return MAG;
        if (k == 2) return -MAG;
        if (k == 3) return MAG + 1;
        if (k == 4) return -MAG - 1;
        if (k == 5) return type(int256).min;
        if (k == 6) return int256(r);
        if (k == 7) return _sym(r >> 8, uint256(MAG));
        uint256 span = sigma > WAD ? 8 * WAD : 8 * sigma;
        return _sym(r >> 8, span);
    }

    function _sd(uint256 r, uint256 sigma) internal pure returns (uint256) {
        uint256 k = r % 16;
        if (k == 0) return 0;
        if (k == 1) return 1;
        if (k == 2) return uint256(MAG);
        if (k == 3) return uint256(MAG) + 1;
        if (k == 4) return r >> 8;
        if (k == 5) return _in(r >> 8, 1, uint256(MAG));
        if (k == 6) return _in(r >> 8, 1, WAD);
        if (k == 7) return _in(r >> 8, 1, 1e9);
        uint256 s = sigma == 0 || sigma > WAD ? SIGMA : sigma;
        return _in(r >> 8, s / 20 + 1, s * 3 / 2 + 1);
    }

    function _scales(uint256 r) internal pure returns (uint256 gOld, uint256 gNew) {
        uint256 k = r % 16;
        uint256 a = r >> 8;
        uint256 b = r >> 128;
        if (k == 0) return (0, 0);
        if (k == 1) return (WAD + 1, WAD);
        if (k == 2) return (_in(a, 1, WAD), 0);
        if (k == 3) {
            gOld = _in(a, 1, WAD - 1);
            return (gOld, gOld + 1);
        }
        if (k == 4) {
            gOld = _in(a, 1, WAD);
            return (gOld, gOld);
        }
        if (k == 5) return (WAD, 1);
        if (k == 6) return (a, b);
        if (k == 7) return (WAD, _in(b, 1, WAD));
        gOld = _in(a, 0.3e18, WAD);
        gNew = b % 2 == 0 ? gOld : _in(b >> 1, 0.3e18, gOld);
    }

    function _depthsOf(uint256 r) internal view returns (uint256[40] memory b0) {
        uint256 sigma = _in(r, 0.005e18, 0.15e18);
        uint256 capital = r % 8 == 0 ? MAX_DEPTH : _logUni(r >> 16, 32) + 1e17;
        if (capital > MAX_DEPTH) capital = MAX_DEPTH;
        uint256 alpha = (r >> 32) % 8 == 0 ? 0.79e18 : _in(r >> 40, 0.05e18, 0.79e18);
        try ref.openDepths(sigma, capital, alpha) returns (uint256[40] memory out) {
            b0 = out;
        } catch {
            b0 = ref.openDepths(SIGMA, 20_000e18, 0.3e18);
        }
    }

    function _b0(uint256 r, uint256 g) internal view returns (uint256[40] memory b0) {
        uint256 k = r % 16;
        uint256 a = r >> 8;
        if (k == 8) {
            for (uint256 j; j < BANDS; ++j) {
                b0[j] = MAX_DEPTH;
            }
        } else if (k == 9) {
            b0 = _depthsOf(a);
            b0[a % BANDS] = MAX_DEPTH + 1;
        } else if (k == 10 || k == 11) {
            // the smallest accepted depth at scale g, and one band one below it
            uint256 g1 = g == 0 ? 1 : g;
            uint256 least = (MIN_SCALED_DEPTH + g1 - 1) / g1;
            if (least > MAX_DEPTH) least = MAX_DEPTH;
            b0 = _depthsOf(a);
            for (uint256 j; j < BANDS; ++j) {
                if ((a >> j) & 1 == 1) b0[j] = least;
            }
            if (k == 11) b0[(a >> 64) % BANDS] = least - 1;
        } else if (k == 12) {
            for (uint256 j; j < BANDS; ++j) {
                b0[j] = _in(_r(a, j), 1, MAX_DEPTH + 2);
            }
        } else if (k == 13) {
            for (uint256 j; j < BANDS; ++j) {
                b0[j] = _logUni(_r(a, j), 33);
            }
        } else if (k == 14) {
            b0 = _depthsOf(a);
            b0[a % BANDS] = MAX_DEPTH;
        } else {
            b0 = _depthsOf(a);
        }
    }

    function _maxOf(uint256[40] memory b) internal pure returns (uint256 m) {
        for (uint256 j; j < BANDS; ++j) {
            if (b[j] > m) m = b[j];
        }
    }

    function _v(uint256 r, uint256 bMax) internal pure returns (int256[40] memory v) {
        uint256 k = r % 16;
        uint256 a = r >> 8;
        if (k < 4) return v;
        if (k < 8) {
            // a few depths of excursion: the scale of states that real trading reaches
            uint256 m = bMax == 0 ? 1e21 : bMax * (1 + a % 12);
            if (m > uint256(MAG)) m = uint256(MAG);
            for (uint256 j; j < BANDS; ++j) {
                v[j] = _sym(_r(a, j), m);
            }
        } else if (k == 8) {
            for (uint256 j; j < BANDS; ++j) {
                v[j] = _sym(_r(a, j), uint256(MAG));
            }
        } else if (k == 9) {
            for (uint256 j; j < BANDS; ++j) {
                v[j] = _sym(_r(a, j), 1e21);
            }
        } else if (k == 10) {
            v[a % BANDS] = type(int256).min;
        } else if (k == 11) {
            v[a % BANDS] = MAG;
            v[(a >> 8) % BANDS] = -MAG;
        } else if (k == 12) {
            v[a % BANDS] = (a >> 8) % 2 == 0 ? MAG + 1 : -MAG - 1;
        } else if (k == 13) {
            for (uint256 j; j < BANDS; ++j) {
                v[j] = int256(_r(a, j));
            }
        } else if (k == 14) {
            for (uint256 j; j < BANDS; ++j) {
                v[j] = MAG;
            }
        } else {
            for (uint256 j; j < BANDS; ++j) {
                v[j] = -MAG;
            }
        }
    }

    function _delta(uint256 r, uint256 bMax) internal pure returns (int256) {
        uint256 k = r % 16;
        if (k == 0) return 0;
        if (k == 1) return MAG;
        if (k == 2) return -MAG;
        if (k == 3) return MAG + 1;
        if (k == 4) return -MAG - 1;
        if (k == 5) return type(int256).min;
        if (k == 6) return int256(r);
        if (k == 7) return _sym(r >> 8, uint256(MAG));
        uint256 size = _logUni(r >> 8, 33);
        if (bMax > 0 && k < 12) size = bMax * (1 + (r >> 64) % 8000) / 1000;
        if (size > uint256(MAG)) size = uint256(MAG);
        return (r >> 200) % 3 == 0 ? -int256(size) : int256(size);
    }

    function _set(uint256 r) internal pure returns (uint8 lo, uint8 hi) {
        uint256 k = r % 16;
        if (k == 0) return (uint8(r >> 8), uint8(r >> 16));
        if (k == 1) return (0, 0);
        if (k == 2) return (39, 39);
        if (k == 3) return (0, 39);
        if (k == 4) return (20, 40);
        lo = uint8((r >> 8) % BANDS);
        hi = uint8(lo + (r >> 16) % (BANDS - lo));
    }

    /// @dev Half of the seeds take every field from its valid branch (the low 4 bits pick the branch), so
    ///      that many fills succeed; the other half mix valid, edge and invalid values.
    function _case(uint256 seed) internal view returns (Case memory c) {
        bool tame = _r(seed, 0) % 2 == 0;
        uint256 typical = tame ? 15 : 0;
        c.sigma = tame || _r(seed, 1) % 4 != 0 ? _in(_r(seed, 2), 0.005e18, 0.15e18) : _sigma(_r(seed, 2));
        (c.ctx.gOld, c.ctx.gNew) = _scales(_r(seed, 3) | typical);
        c.ctx.x = _x(_r(seed, 4) | typical, c.sigma);
        c.ctx.sd = _sd(_r(seed, 5) | typical, c.sigma);
        c.b0 = _b0(_r(seed, 6) | typical, c.ctx.gNew == 0 ? c.ctx.gOld : c.ctx.gNew);
        uint256 bMax = _maxOf(c.b0);
        uint256 rv = tame ? (_r(seed, 7) & ~uint256(15)) | (4 + _r(seed, 7) % 4) : _r(seed, 7);
        c.v = _v(rv, bMax * (c.ctx.gOld > WAD ? WAD : c.ctx.gOld) / WAD);
        (c.lo, c.hi) = _set(_r(seed, 8) | typical);
        uint256 rd = tame ? (_r(seed, 9) & ~uint256(15)) | (8 + _r(seed, 9) % 8) : _r(seed, 9);
        c.delta = _delta(rd, bMax);
    }

    function _fillData(Case memory c) internal pure returns (bytes memory) {
        return abi.encodeCall(ILadderMath.fill, (c.v, c.b0, c.sigma, c.ctx, c.lo, c.hi, c.delta));
    }

    function _pricesData(Case memory c) internal pure returns (bytes memory) {
        return abi.encodeCall(ILadderMath.prices, (c.v, c.b0, c.sigma, c.ctx));
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ: FILL
    //////////////////////////////////////////////////////////////*/

    function testFuzz_equiv_fill(uint256 seed) public view {
        _same(_fillData(_case(seed)));
    }

    function testFuzz_equiv_prices(uint256 seed) public view {
        _same(_pricesData(_case(seed)));
    }

    /// @dev A chain of fills: each one starts from the state the last one returned (states of real trading).
    function testFuzz_equiv_fillChain(uint256 seed) public view {
        Case memory c = _case(seed);
        c.sigma = _in(_r(seed, 20), 0.005e18, 0.15e18);
        c.b0 = _depthsOf(_r(seed, 21));
        uint256 bMax = _maxOf(c.b0);
        uint256 g = WAD;
        delete c.v;
        for (uint256 i; i < 4; ++i) {
            uint256 sub = _r(seed, 30 + i);
            c.ctx.x = _sym(_r(sub, 1), 8 * c.sigma);
            c.ctx.sd = _in(_r(sub, 2), c.sigma / 20, c.sigma * 3 / 2);
            c.ctx.gOld = g;
            c.ctx.gNew = _r(sub, 3) % 2 == 0 ? g : _in(_r(sub, 4), 0.3e18, g);
            (c.lo, c.hi) = _set(_r(sub, 5) | 15);
            c.delta = _delta(_r(sub, 6) % 4 == 0 ? _r(sub, 6) : (_r(sub, 6) | 15) - 7, bMax);
            bytes memory data = _fillData(c);
            if (!_same(data)) continue;
            _same(_pricesData(c));
            c.v = neu.fill(c.v, c.b0, c.sigma, c.ctx, c.lo, c.hi, c.delta).v;
            g = c.ctx.gNew;
        }
    }

    /*//////////////////////////////////////////////////////////////
                         FUZZ: OPEN AND PRIOR
    //////////////////////////////////////////////////////////////*/

    function testFuzz_equiv_openLnInv(uint256 sigma, uint256 r) public view {
        if (r % 2 == 0) sigma = _sigma(r >> 1);
        _same(abi.encodeCall(ILadderMath.openLnInv, (sigma)));
    }

    function testFuzz_equiv_openDepths(uint256 sigma, uint256 capital, uint256 alpha, uint256 r) public view {
        if (r % 2 == 0) {
            sigma = _sigma(r >> 1);
            capital = r % 8 == 2 ? MAX_DEPTH + (r >> 8) % 2 : _logUni(r >> 8, 34);
            alpha = r % 16 == 4 ? 0.79e18 + (r >> 16) % 2 : _in(r >> 16, 0, 0.8e18);
        }
        _same(abi.encodeCall(ILadderMath.openDepths, (sigma, capital, alpha)));
    }

    function testFuzz_equiv_depths(uint256 sigma, uint256 capital, uint256 alpha, uint256 r) public view {
        uint256[10] memory packed;
        if (r % 4 == 0) {
            for (uint256 i; i < 10; ++i) {
                packed[i] = _r(r, i);
            }
        } else {
            packed = ref.openLnInv(_in(sigma, 0.005e18, 0.15e18));
            capital = _logUni(capital, 34);
            alpha = _in(alpha, 0, 0.8e18);
        }
        _same(abi.encodeCall(ILadderMath.depths, (packed, capital, alpha)));
    }

    function testFuzz_equiv_prior(uint256 seed) public view {
        uint256 sigma = _sigma(_r(seed, 1));
        _same(abi.encodeCall(ILadderMath.prior, (sigma, _x(_r(seed, 2), sigma), _sd(_r(seed, 3), sigma))));
    }

    function testFuzz_equiv_edgeAndBand(uint256 sigma, uint8 m, int256 x, uint256 r) public view {
        if (r % 2 == 0) sigma = _sigma(r >> 1);
        if (r % 4 == 1) x = _x(r >> 2, sigma);
        _same(abi.encodeCall(ILadderMath.edge, (sigma, m)));
        _same(abi.encodeCall(ILadderMath.bandOf, (sigma, x)));
    }

    /*//////////////////////////////////////////////////////////////
                              GAUSSIAN
    //////////////////////////////////////////////////////////////*/

    function testFuzz_equiv_cdf(int256 z, uint256 r) public pure {
        if (r % 2 == 0) z = _sym(r >> 1, 10e18);
        assertEq(Gaussian.cdf(z), GaussianRef.cdf(z));
        assertEq(Gaussian.pdf(z), GaussianRef.pdf(z));
    }

    /// @dev Every 1e14 over [-9.5, 9.5], plus the cutoffs, the interval ends and the extremes.
    function test_equiv_cdf_sweep() public pure {
        for (int256 z = -9.5e18; z <= 9.5e18; z += 1e14) {
            assertEq(Gaussian.cdf(z), GaussianRef.cdf(z));
        }
        for (int256 k = -19; k <= 19; ++k) {
            int256 z = k * 5e17;
            for (int256 d = -2; d <= 2; ++d) {
                assertEq(Gaussian.cdf(z + d), GaussianRef.cdf(z + d));
            }
        }
        int256[6] memory far = [type(int256).min, type(int256).min + 1, type(int256).max, int256(-1), 1, 0];
        for (uint256 i; i < far.length; ++i) {
            assertEq(Gaussian.cdf(far[i]), GaussianRef.cdf(far[i]));
        }
    }

    /*//////////////////////////////////////////////////////////////
                              EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function _base() internal view returns (Case memory c) {
        c.sigma = SIGMA;
        c.b0 = ref.openDepths(SIGMA, 20_000e18, 0.3e18);
        c.ctx = ILadderMath.Ctx({x: 0.004e18, sd: 0.03e18, gOld: WAD, gNew: WAD});
        c.lo = 20;
        c.hi = 39;
        c.delta = 100e18;
    }

    function _both(Case memory c) internal view {
        _same(_fillData(c));
        _same(_pricesData(c));
    }

    function test_equiv_edge_stateIntMin() public view {
        Case memory c = _base();
        for (uint256 j; j < BANDS; j += 13) {
            c.v[j] = type(int256).min;
            _both(c);
            c.v[j] = 0;
        }
    }

    function test_equiv_edge_stateBound() public view {
        Case memory c = _base();
        int256[6] memory vals = [MAG, -MAG, MAG + 1, -MAG - 1, type(int256).max, MAG - 1];
        for (uint256 i; i < vals.length; ++i) {
            c.v[7] = vals[i];
            _both(c);
            for (uint256 j; j < BANDS; ++j) {
                c.v[j] = vals[i];
            }
            _both(c);
            delete c.v;
        }
    }

    function test_equiv_edge_deltaBound() public view {
        Case memory c = _base();
        int256[7] memory ds = [MAG, -MAG, MAG + 1, -MAG - 1, type(int256).min, type(int256).max, int256(0)];
        for (uint256 i; i < ds.length; ++i) {
            c.delta = ds[i];
            _both(c);
            c.ctx.gNew = 0.7e18;
            _both(c);
            c.ctx.gNew = WAD;
        }
        // a state at the bound plus a delta at the bound: the result is out of range
        for (uint256 j; j < BANDS; ++j) {
            c.v[j] = MAG;
        }
        c.delta = MAG;
        _both(c);
        c.delta = -MAG;
        _both(c);
    }

    function test_equiv_edge_scales() public view {
        Case memory c = _base();
        uint256[5] memory gs = [uint256(1), 0.3e18, 0.5e18, WAD - 1, WAD];
        for (uint256 i; i < gs.length; ++i) {
            c.ctx.gOld = gs[i];
            c.ctx.gNew = gs[i];
            _both(c);
            c.ctx.gNew = gs[i] / 2;
            _both(c);
            c.ctx.gNew = gs[i] + 1;
            _both(c);
        }
        c.ctx.gOld = WAD + 1;
        c.ctx.gNew = WAD;
        _both(c);
        c.ctx.gOld = 0;
        _both(c);
    }

    function test_equiv_edge_sd() public view {
        Case memory c = _base();
        uint256[7] memory sds = [uint256(0), 1, 2, 3, 1e9, uint256(MAG), uint256(MAG) + 1];
        for (uint256 i; i < sds.length; ++i) {
            c.ctx.sd = sds[i];
            _both(c);
            _same(abi.encodeCall(ILadderMath.prior, (SIGMA, c.ctx.x, sds[i])));
            _same(abi.encodeCall(ILadderMath.prior, (WAD, MAG, sds[i])));
        }
    }

    function test_equiv_edge_sigmaAndX() public view {
        Case memory c = _base();
        uint256[5] memory sigmas = [uint256(0), 1, 4, WAD, WAD + 1];
        int256[7] memory xs = [MAG, -MAG, MAG + 1, -MAG - 1, type(int256).min, int256(0), 4.75e18];
        for (uint256 i; i < sigmas.length; ++i) {
            for (uint256 k; k < xs.length; ++k) {
                c.sigma = sigmas[i];
                c.ctx.x = xs[k];
                _both(c);
                _same(abi.encodeCall(ILadderMath.prior, (sigmas[i], xs[k], 1)));
                _same(abi.encodeCall(ILadderMath.prior, (sigmas[i], xs[k], uint256(MAG))));
            }
            _same(abi.encodeCall(ILadderMath.openLnInv, (sigmas[i])));
            _same(abi.encodeCall(ILadderMath.openDepths, (sigmas[i], MAX_DEPTH, 0.79e18)));
        }
    }

    function test_equiv_edge_depthBounds() public view {
        Case memory c = _base();
        for (uint256 j; j < BANDS; ++j) {
            c.b0[j] = MAX_DEPTH;
        }
        _both(c);
        c.b0[5] = MAX_DEPTH + 1;
        _both(c);
        // the smallest depth at g = 0.5, and one wei below it (InvalidDepth)
        c = _base();
        c.ctx.gOld = 0.5e18;
        c.ctx.gNew = 0.5e18;
        c.b0[3] = MIN_SCALED_DEPTH / 0.5e18;
        _both(c);
        c.b0[3] -= 1;
        _both(c);
        // the first band bad on both counts: the depth cap is checked first
        c.b0[0] = MAX_DEPTH + 1;
        _both(c);
    }

    /// @dev A busy book rescaled from 1 to 0.3, a buy and a sell, and a chain of rescales.
    function test_equiv_edge_rescale() public view {
        Case memory c = _base();
        c.v = neu.fill(c.v, c.b0, c.sigma, c.ctx, 20, 39, 900e18).v;
        c.v = neu.fill(c.v, c.b0, c.sigma, c.ctx, 0, 15, 300e18).v;
        c.ctx.gNew = 0.3e18;
        _both(c);
        c.delta = -400e18;
        c.lo = 0;
        c.hi = 23;
        _both(c);
        uint256 g = WAD;
        for (uint256 i; i < 6; ++i) {
            c.ctx.gOld = g;
            c.ctx.gNew = g * 9 / 10;
            _both(c);
            c.v = neu.fill(c.v, c.b0, c.sigma, c.ctx, c.lo, c.hi, c.delta).v;
            g = c.ctx.gNew;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  GAS
    //////////////////////////////////////////////////////////////*/

    function _gasFill(address target, Case memory c) internal view returns (uint256 used) {
        uint256 start = gasleft();
        ILadderMath(target).fill(c.v, c.b0, c.sigma, c.ctx, c.lo, c.hi, c.delta);
        used = start - gasleft();
    }

    function _logPair(string memory name, uint256 before, uint256 afterGas) internal {
        emit log_named_string("case", name);
        emit log_named_uint("  reference gas", before);
        emit log_named_uint("  optimised gas", afterGas);
        emit log_named_uint("  saved", before > afterGas ? before - afterGas : 0);
    }

    /// @dev Gas of the reference and of the optimised contract on the same inputs (LadderMath.gas.t.sol's
    ///      busy book).
    function test_gas_compare() public {
        Case memory c = _base();
        ILadderMath.Ctx memory flat = c.ctx;
        c.v = neu.fill(c.v, c.b0, SIGMA, flat, 20, 39, 900e18).v;
        c.v = neu.fill(c.v, c.b0, SIGMA, flat, 0, 15, 300e18).v;
        c.v = neu.fill(c.v, c.b0, SIGMA, flat, 24, 39, 1500e18).v;
        c.v = neu.fill(c.v, c.b0, SIGMA, flat, 0, 23, 700e18).v;
        c.v = neu.fill(c.v, c.b0, SIGMA, flat, 16, 39, 250e18).v;

        c.ctx = ILadderMath.Ctx(-0.006e18, 0.025e18, WAD, WAD);
        (c.lo, c.hi, c.delta) = (24, 39, 120e18);
        _logPair("fill buy, no rescale", _gasFill(address(ref), c), _gasFill(address(neu), c));
        c.ctx.gNew = 0.82e18;
        _logPair("fill buy, rescale", _gasFill(address(ref), c), _gasFill(address(neu), c));
        c.ctx = ILadderMath.Ctx(0.011e18, 0.004e18, 0.45e18, 0.45e18);
        (c.lo, c.hi, c.delta) = (0, 23, -400e18);
        _logPair("fill sell, no rescale", _gasFill(address(ref), c), _gasFill(address(neu), c));
        c.ctx.gNew = 0.3e18;
        _logPair("fill sell, rescale", _gasFill(address(ref), c), _gasFill(address(neu), c));

        uint256 start = gasleft();
        ref.openLnInv(SIGMA);
        uint256 before = start - gasleft();
        start = gasleft();
        neu.openLnInv(SIGMA);
        _logPair("openLnInv", before, start - gasleft());

        start = gasleft();
        ref.prices(c.v, c.b0, SIGMA, c.ctx);
        before = start - gasleft();
        start = gasleft();
        neu.prices(c.v, c.b0, SIGMA, c.ctx);
        _logPair("prices", before, start - gasleft());

        start = gasleft();
        ref.prior(SIGMA, 0.004e18, 0.03e18);
        before = start - gasleft();
        start = gasleft();
        neu.prior(SIGMA, 0.004e18, 0.03e18);
        _logPair("prior", before, start - gasleft());
    }
}
