// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LadderMathHarness} from "./LadderMathHarness.sol";

/// @notice Normal CDF and PDF against a 90-digit reference and against math.erf, plus the measured error
///         of solady's expWad that the cost margin of LadderMath relies on.
contract GaussianTest is Test {
    uint256 internal constant WAD = 1e18;

    LadderMathHarness internal h;

    function setUp() public {
        h = new LadderMathHarness();
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @dev Spec: absolute error at most 1e-9 against math.erf. Achieved: at most 2e-18 against the
    ///      high-precision reference (math.erf itself is only good to about 1e-16).
    function test_cdf_vectors() public {
        string memory json = vm.readFile("test/vectors/gaussian.json");
        int256[] memory z = vm.parseJsonIntArray(json, ".z");
        uint256[] memory exact = vm.parseJsonUintArray(json, ".cdf");
        uint256[] memory erf = vm.parseJsonUintArray(json, ".cdfErf");
        assertGt(z.length, 600);
        uint256 worst;
        uint256 worstErf;
        for (uint256 i; i < z.length; ++i) {
            uint256 c = h.cdf(z[i]);
            uint256 e = _absDiff(c, exact[i]);
            if (e > worst) worst = e;
            e = _absDiff(c, erf[i]);
            if (e > worstErf) worstErf = e;
        }
        emit log_named_uint("cdf: worst error vs 90-digit reference (wei of WAD)", worst);
        emit log_named_uint("cdf: worst difference vs math.erf (wei of WAD)", worstErf);
        assertLe(worst, 2, "cdf error above 2e-18");
        assertLe(worstErf, 1e9, "cdf error above the spec's 1e-9");
    }

    function test_pdf_vectors() public {
        string memory json = vm.readFile("test/vectors/gaussian.json");
        int256[] memory z = vm.parseJsonIntArray(json, ".z");
        uint256[] memory exact = vm.parseJsonUintArray(json, ".pdf");
        uint256 worst;
        for (uint256 i; i < z.length; ++i) {
            uint256 e = _absDiff(h.pdf(z[i]), exact[i]);
            if (e > worst) worst = e;
        }
        emit log_named_uint("pdf: worst error vs 90-digit reference (wei of WAD)", worst);
        assertLe(worst, 3, "pdf error above 3e-18");
    }

    function test_cdf_fixedPoints() public view {
        assertEq(h.cdf(0), 5e17);
        assertEq(h.cdf(9e18), WAD);
        assertEq(h.cdf(-9e18), 0);
        assertEq(h.cdf(type(int256).max), WAD);
        assertEq(h.cdf(type(int256).min), 0);
        assertEq(h.pdf(type(int256).max), 0);
        assertEq(h.pdf(type(int256).min), 0);
        assertEq(h.pdf(0), 398942280401432678);
        // Phi(1.96) = 0.975002104851779565863..., Phi(-3) = 0.001349898031630094526...
        assertApproxEqAbs(h.cdf(1.96e18), 975002104851779566, 2);
        assertApproxEqAbs(h.cdf(-3e18), 1349898031630095, 2);
    }

    function testFuzz_cdf_symmetry(int256 z) public view {
        vm.assume(z != type(int256).min);
        assertEq(h.cdf(z) + h.cdf(-z), WAD);
    }

    /// @dev Monotone up to the 2 wei error on each side.
    function testFuzz_cdf_monotone(int256 a, int256 b) public view {
        a = bound(a, -10e18, 10e18);
        b = bound(b, a, 10e18);
        assertLe(h.cdf(a), h.cdf(b) + 4);
    }

    function testFuzz_cdf_inUnitInterval(int256 z) public view {
        assertLe(h.cdf(z), WAD);
    }

    /// @dev The cost margin of LadderMath assumes |expWad(x) - e^x * 1e18| <= 1.01 + 1e-19 * e^x * 1e18 on
    ///      the range it uses (exponents up to 60). The vectors hold floor(e^x * 1e18) from a 90-digit
    ///      reference, so the integer difference must be at most 1 + floor / 1e19.
    function test_expWad_errorBound() public view {
        string memory json = vm.readFile("test/vectors/exp.json");
        int256[] memory x = vm.parseJsonIntArray(json, ".x");
        uint256[] memory fl = vm.parseJsonUintArray(json, ".floor");
        assertGt(x.length, 500);
        for (uint256 i; i < x.length; ++i) {
            uint256 e = uint256(h.expWad(x[i]));
            assertLe(_absDiff(e, fl[i]), 1 + fl[i] / 1e19, "expWad error above the assumed bound");
        }
    }
}
