// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LadderMathBase} from "./LadderMathBase.sol";

/// @notice The vol-mix prior: the normal CDF averaged over three sd nodes,
///         sd_i = sd * exp(0.2 x_i - 0.02), x = -sqrt3, 0, sqrt3, weights 1/6, 2/3, 1/6.
contract VolMixTest is LadderMathBase {
    /// @dev x inside 8 sigma, sd from 0.05 to 2.5 sigma (the learned sigma goes up to 2.5x).
    function _anchorOf(uint256 seed) internal pure returns (uint256 sigma, int256 x, uint256 sd) {
        sigma = bound(uint256(keccak256(abi.encode(seed, 1))), 0.005e18, 0.15e18);
        x = bound(int256(uint256(keccak256(abi.encode(seed, 2))) >> 1), -8 * int256(sigma), 8 * int256(sigma));
        sd = bound(uint256(keccak256(abi.encode(seed, 3))), sigma / 20, sigma * 5 / 2);
    }

    /// @dev The node multipliers are exp(0.2 x_i - 0.02) truncated to the wei (90-digit values in the comment).
    function test_nodes_areTheGaussHermiteMultipliers() public view {
        (uint256 lo, uint256 mid, uint256 hi) = math.mixNodes();
        assertEq(lo, 693218411377872994); // 0.693218411377872994388...
        assertEq(mid, 980198673306755302); // 0.980198673306755302220...
        assertEq(hi, 1385983729489546675); // 1.385983729489546675360...
        // sd_i = sd * exp(0.2 X - 0.02) with X standard normal: E[sd_i / sd] = 1 and E[sd_i^2 / sd^2] = exp(0.04)
        // (the mix widens the variance by about 4%). Three Gauss-Hermite nodes match the first to 5.3e-7 and the
        // second to 3.3e-5.
        uint256 m1 = (lo + 4 * mid + hi) / 6;
        uint256 m2 = (lo * lo + 4 * mid * mid + hi * hi) / 6 / 1e18;
        assertApproxEqRel(m1, 1e18, 1e12);
        assertApproxEqRel(m2, 1040810774192388226, 1e14);
    }

    /// @dev The mix is exactly the weighted average of the three node CDFs (one wei of division dust).
    function testFuzz_cdfMix_isTheWeightedNodeAverage(uint256 seed, uint8 m) public view {
        (uint256 sigma, int256 x, uint256 sd) = _anchorOf(seed);
        m = uint8(bound(m, 0, 38));
        (uint256 lo, uint256 mid, uint256 hi) = math.mixNodes();
        int256 e = math.edge(sigma, m);
        uint256 expected =
            (_nodeCdf(e, x, sd * lo / 1e18)
                    + 4
                    * _nodeCdf(e, x, sd * mid / 1e18)
                    + _nodeCdf(e, x, sd * hi / 1e18)) / 6;
        assertEq(math.cdfMix(sigma, m, x, sd), expected);
    }

    function _nodeCdf(int256 e, int256 x, uint256 sdi) internal view returns (uint256) {
        return math.cdf((e - x) * 1e18 / int256(sdi) + int256(sdi / 2));
    }

    /// @dev Monotone along the ladder up to the CDF's own error (2 wei per node, 3 wei after averaging).
    function testFuzz_cdfMix_monotone(uint256 seed) public view {
        (uint256 sigma, int256 x, uint256 sd) = _anchorOf(seed);
        uint256 prev = math.cdfMix(sigma, 0, x, sd);
        for (uint256 m = 1; m < 39; ++m) {
            uint256 c = math.cdfMix(sigma, m, x, sd);
            assertGe(c + 3, prev, "mix cdf falls along the ladder");
            assertLe(c, WAD);
            prev = c;
        }
    }

    /// @dev The prior sums to exactly 1, every band is at least the floor's share, and it has more weight
    ///      in both far tails than the single normal of the same sd (the mix's fatter tails).
    function testFuzz_prior_sumsToOne_floored(uint256 seed) public view {
        (uint256 sigma, int256 x, uint256 sd) = _anchorOf(seed);
        uint256[40] memory pi = math.prior(sigma, x, sd);
        uint256 total;
        for (uint256 j; j < BANDS; ++j) {
            total += pi[j];
            // floor 1e-4 renormalised by a sum of at most 1 + 40e-4
            assertGe(pi[j], uint256(1e14) * 1e18 / (1e18 + 40e14));
        }
        assertEq(total, WAD);
    }

    /// @dev At the open (x 0, sd sigma) the mix puts more mass beyond 2 sd on each side than the normal.
    function test_prior_fatterTailsThanNormal() public view {
        uint256 sigma = 0.035e18;
        uint256[40] memory pi = math.prior(sigma, 0, sigma);
        // bands 0..10 lie below edge 11 = -2 sigma; bands 28..39 above edge 27 = +2 sigma
        uint256 low;
        uint256 high;
        for (uint256 j; j <= 10; ++j) {
            low += pi[j];
        }
        for (uint256 j = 28; j < BANDS; ++j) {
            high += pi[j];
        }
        int256 z11 = (math.edge(sigma, 10) - 0) * 1e18 / int256(sigma) + int256(sigma / 2);
        int256 z27 = (math.edge(sigma, 27) - 0) * 1e18 / int256(sigma) + int256(sigma / 2);
        assertGt(low, math.cdf(z11));
        assertGt(high, WAD - math.cdf(z27));
    }
}
