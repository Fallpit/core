// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILadderMath} from "../../src/interfaces/ILadderMath.sol";
import {LadderMathBase} from "./LadderMathBase.sol";

/// @notice Differential tests against the Python references in test/vectors/gen_vectors.py: the float64
///         port of test/vectors/ladder_house_sim.py (prior.json piSim, sim.json) and the
///         high-precision engine (prior.json pi and b0, fill.json).
/// @dev Tolerances. Prices and costs: 1e-9 relative, as the spec asks. A relative tolerance alone is
///      meaningless for a price of a few wei, so prices also get a few wei of absolute room, and amounts get
///      the documented safety margin of `fill` (about 2e-17 of the largest depth, see _marginBound).
contract LadderMathDiffTest is LadderMathBase {
    /// @dev Absolute room for one band price (truncations) and for a set price (up to 40 of them).
    uint256 internal constant BAND_DUST = 4;
    uint256 internal constant SET_DUST = 100;

    function _relTol(uint256 ref) internal pure returns (uint256) {
        return ref / 1e9;
    }

    /*//////////////////////////////////////////////////////////////
                                 PRIOR
    //////////////////////////////////////////////////////////////*/

    function test_prior_matchesReference() public {
        string memory json = vm.readFile("test/vectors/prior.json");
        uint256[] memory sigma = vm.parseJsonUintArray(json, ".sigma");
        int256[] memory x = vm.parseJsonIntArray(json, ".x");
        uint256[] memory sd = vm.parseJsonUintArray(json, ".sd");
        uint256[] memory piSim = vm.parseJsonUintArray(json, ".piSim");
        uint256[] memory piExact = vm.parseJsonUintArray(json, ".pi");
        assertEq(sigma.length, 120);
        uint256 worst;
        for (uint256 i; i < sigma.length; ++i) {
            uint256[40] memory pi = math.prior(sigma[i], x[i], sd[i]);
            uint256 total;
            for (uint256 j; j < BANDS; ++j) {
                total += pi[j];
                // float64 reference (fair_probs): 1e-9 relative
                assertLe(_absDiff(pi[j], piSim[i * BANDS + j]), _relTol(piSim[i * BANDS + j]), "prior vs sim");
                // high-precision reference: a few dozen wei (CDF error and renormalisation dust)
                uint256 e = _absDiff(pi[j], piExact[i * BANDS + j]);
                if (e > worst) worst = e;
            }
            assertEq(total, WAD, "prior does not sum to 1e18");
        }
        emit log_named_uint("prior: worst error vs 90-digit reference (wei of WAD)", worst);
        assertLe(worst, 64, "prior vs exact");
    }

    function test_openDepths_matchesReference() public {
        string memory json = vm.readFile("test/vectors/prior.json");
        uint256[] memory sigma = vm.parseJsonUintArray(json, ".sigma");
        uint256[] memory capital = vm.parseJsonUintArray(json, ".capital");
        uint256[] memory alpha = vm.parseJsonUintArray(json, ".alpha");
        uint256[] memory ref = vm.parseJsonUintArray(json, ".b0");
        uint256 worst;
        for (uint256 i; i < sigma.length; ++i) {
            uint256[40] memory b0 = math.openDepths(sigma[i], capital[i], alpha[i]);
            for (uint256 j; j < BANDS; ++j) {
                uint256 r = ref[i * BANDS + j];
                uint256 rel = _absDiff(b0[j], r) * 1e18 / r;
                if (rel > worst) worst = rel;
            }
        }
        emit log_named_uint("openDepths: worst relative error (1e-18)", worst);
        assertLe(worst, 1e7, "openDepths relative error above 1e-11");
    }

    /*//////////////////////////////////////////////////////////////
                         FLOAT64 SIM REFERENCE
    //////////////////////////////////////////////////////////////*/

    struct SimVectors {
        uint256 steps;
        uint256[] sigma;
        uint256[] capital;
        uint256[] alpha;
        int256[] x;
        uint256[] sd;
        uint256[] lo;
        uint256[] hi;
        uint256[] delta;
        uint256[] cost;
        uint256[] pBefore;
        uint256[] pAfter;
        uint256[] prices;
    }

    function _loadSim() internal view returns (SimVectors memory s) {
        string memory json = vm.readFile("test/vectors/sim.json");
        s.steps = vm.parseJsonUint(json, ".steps");
        s.sigma = vm.parseJsonUintArray(json, ".sigma");
        s.capital = vm.parseJsonUintArray(json, ".capital");
        s.alpha = vm.parseJsonUintArray(json, ".alpha");
        s.x = vm.parseJsonIntArray(json, ".x");
        s.sd = vm.parseJsonUintArray(json, ".sd");
        s.lo = vm.parseJsonUintArray(json, ".lo");
        s.hi = vm.parseJsonUintArray(json, ".hi");
        s.delta = vm.parseJsonUintArray(json, ".delta");
        s.cost = vm.parseJsonUintArray(json, ".cost");
        s.pBefore = vm.parseJsonUintArray(json, ".pBefore");
        s.pAfter = vm.parseJsonUintArray(json, ".pAfter");
        s.prices = vm.parseJsonUintArray(json, ".prices");
    }

    /// @dev Buys of the six strike sets, priced by the sim's cost_fn and prices (float64).
    function test_fill_matchesSimReference() public view {
        SimVectors memory s = _loadSim();
        assertEq(s.sigma.length, 40);
        for (uint256 c; c < s.sigma.length; ++c) {
            uint256[40] memory b0 = math.openDepths(s.sigma[c], s.capital[c], s.alpha[c]);
            uint256 margin = _marginBound(b0, WAD);
            int256[40] memory v;
            ILadderMath.Ctx memory ctx;
            for (uint256 k; k < s.steps; ++k) {
                uint256 i = c * s.steps + k;
                ctx = _ctx(s.x[i], s.sd[i], WAD, WAD);
                ILadderMath.Fill memory f =
                    math.fill(v, b0, s.sigma[c], ctx, uint8(s.lo[i]), uint8(s.hi[i]), int256(s.delta[i]));
                assertLe(_absDiff(f.amount, s.cost[i]), _relTol(s.cost[i]) + margin, "cost vs sim");
                assertLe(
                    _absDiff(f.pBefore, s.pBefore[i]), _relTol(s.pBefore[i]) + SET_DUST, "pBefore vs sim"
                );
                assertLe(_absDiff(f.pAfter, s.pAfter[i]), _relTol(s.pAfter[i]) + SET_DUST, "pAfter vs sim");
                v = f.v;
            }
            uint256[40] memory p = math.prices(v, b0, s.sigma[c], ctx);
            for (uint256 j; j < BANDS; ++j) {
                uint256 ref = s.prices[c * BANDS + j];
                assertLe(_absDiff(p[j], ref), _relTol(ref) + BAND_DUST, "prices vs sim");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                       HIGH-PRECISION REFERENCE
    //////////////////////////////////////////////////////////////*/

    struct FillVectors {
        uint256 steps;
        uint256[] sigma;
        uint256[] capital;
        uint256[] alpha;
        int256[] x;
        uint256[] sd;
        uint256[] gOld;
        uint256[] gNew;
        uint256[] lo;
        uint256[] hi;
        int256[] delta;
        uint256[] amount;
        uint256[] pBefore;
        uint256[] pAfter;
        uint256[] vega;
        uint256[] prices;
    }

    function _loadFill() internal view returns (FillVectors memory s) {
        string memory json = vm.readFile("test/vectors/fill.json");
        s.steps = vm.parseJsonUint(json, ".steps");
        s.sigma = vm.parseJsonUintArray(json, ".sigma");
        s.capital = vm.parseJsonUintArray(json, ".capital");
        s.alpha = vm.parseJsonUintArray(json, ".alpha");
        s.x = vm.parseJsonIntArray(json, ".x");
        s.sd = vm.parseJsonUintArray(json, ".sd");
        s.gOld = vm.parseJsonUintArray(json, ".gOld");
        s.gNew = vm.parseJsonUintArray(json, ".gNew");
        s.lo = vm.parseJsonUintArray(json, ".lo");
        s.hi = vm.parseJsonUintArray(json, ".hi");
        s.delta = vm.parseJsonIntArray(json, ".delta");
        s.amount = vm.parseJsonUintArray(json, ".amount");
        s.pBefore = vm.parseJsonUintArray(json, ".pBefore");
        s.pAfter = vm.parseJsonUintArray(json, ".pAfter");
        s.vega = vm.parseJsonUintArray(json, ".vega");
        s.prices = vm.parseJsonUintArray(json, ".prices");
    }

    /// @dev Whole `fill` sequences: re-anchored prior, depth rescale, buys and sells of arbitrary sets.
    function test_fill_matchesHighPrecisionReference() public view {
        FillVectors memory s = _loadFill();
        assertEq(s.sigma.length, 48);
        for (uint256 c; c < s.sigma.length; ++c) {
            uint256[40] memory b0 = math.openDepths(s.sigma[c], s.capital[c], s.alpha[c]);
            uint256 margin = _marginBound(b0, WAD);
            int256[40] memory v;
            ILadderMath.Ctx memory ctx;
            for (uint256 k; k < s.steps; ++k) {
                uint256 i = c * s.steps + k;
                ctx = _ctx(s.x[i], s.sd[i], s.gOld[i], s.gNew[i]);
                ILadderMath.Fill memory f =
                    math.fill(v, b0, s.sigma[c], ctx, uint8(s.lo[i]), uint8(s.hi[i]), s.delta[i]);
                // Rounding direction first: a buy never costs less, a sell never pays more. The reference
                // amount is rounded to the nearest wei and its depths differ from the on-chain ones by
                // about 1e-13 relative, hence the relative allowance on the direction check.
                if (s.delta[i] > 0) {
                    assertGe(f.amount + _relTol(s.amount[i]) + 1, s.amount[i], "buy under-charged");
                } else {
                    assertLe(f.amount, s.amount[i] + _relTol(s.amount[i]) + 1, "sell over-paid");
                }
                assertLe(_absDiff(f.amount, s.amount[i]), _relTol(s.amount[i]) + margin, "amount vs exact");
                assertLe(_absDiff(f.pBefore, s.pBefore[i]), _relTol(s.pBefore[i]) + SET_DUST, "pBefore");
                assertLe(_absDiff(f.pAfter, s.pAfter[i]), _relTol(s.pAfter[i]) + SET_DUST, "pAfter");
                // vega is rounded up: 32 wei of allowance per finite edge on top of an edge value that is
                // itself within 32 wei, so it lands in [exact, exact + 128]. The reference is floored.
                assertGe(f.vega, s.vega[i], "vega rounded down");
                assertLe(f.vega, s.vega[i] + 129, "vega too high");
                v = f.v;
            }
            ctx.gOld = ctx.gNew;
            uint256[40] memory p = math.prices(v, b0, s.sigma[c], ctx);
            for (uint256 j; j < BANDS; ++j) {
                uint256 ref = s.prices[c * BANDS + j];
                assertLe(_absDiff(p[j], ref), _relTol(ref) + BAND_DUST, "prices vs exact");
            }
        }
    }
}
