// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILadderMath} from "../../src/interfaces/ILadderMath.sol";
import {LadderMath} from "../../src/LadderMath.sol";
import {LadderMathBase} from "./LadderMathBase.sol";

/// @notice `fillPacked` is `depths` followed by `fillFrom` on the unpacked state, exactly: the same amount,
///         prices, vega and root, the returned state is the packed form of `fillFrom`'s, and it reverts
///         where the two would.
contract LadderMathPackedTest is LadderMathBase {
    function _pack(int256[40] memory v) internal pure returns (uint256[20] memory p) {
        for (uint256 k; k < 20; ++k) {
            p[k] = uint256(uint128(int128(v[2 * k]))) | uint256(v[2 * k + 1]) << 128;
        }
    }

    function _in(Scn memory s, uint256 sigma) internal view returns (ILadderMath.PackedIn memory a) {
        a.v = _pack(s.v);
        a.lnInv = math.openLnInv(sigma);
        a.capital = s.capital;
        a.alpha = s.alpha;
        a.sigma = sigma;
    }

    function testFuzz_fillPacked_isDepthsThenFillFrom(uint256 seed) public view {
        Scn memory s = _scenario(seed);
        ILadderMath.PackedIn memory a = _in(s, s.sigma);
        uint256 gNew = _rand(seed, 40) % 2 == 0 ? s.g : bound(_rand(seed, 41), 0.3e18, s.g);
        (uint8 lo, uint8 hi) = _set(seed, 42);
        int256 delta = int256(_size(seed, 43, s.capital));
        if (_rand(seed, 44) % 3 == 0) delta = -delta;
        int256 guess =
            _rand(seed, 45) % 2 == 0 ? type(int256).min : int256(bound(_rand(seed, 46), 0, 2e36)) - 1e36;
        ILadderMath.Ctx memory ctx = _ctx(s.x, s.sd, s.g, gNew);

        ILadderMath.PackedFill memory p = math.fillPacked(a, ctx, lo, hi, delta, guess);
        uint256[40] memory b0 = math.depths(a.lnInv, s.capital, s.alpha);
        (ILadderMath.Fill memory f, int256 lam) = math.fillFrom(s.v, b0, s.sigma, ctx, lo, hi, delta, guess);
        assertEq(p.amount, f.amount, "amount");
        assertEq(p.pBefore, f.pBefore, "pBefore");
        assertEq(p.pAfter, f.pAfter, "pAfter");
        assertEq(p.vega, f.vega, "vega");
        assertEq(p.lambda, lam, "root");
        uint256[20] memory want = _pack(f.v);
        for (uint256 k; k < 20; ++k) {
            assertEq(p.v[k], want[k], "packed state");
        }
    }

    /// @dev The scenario's depths are `openDepths`, which equal `depths(openLnInv)`: the packed call sees
    ///      the same depths as the scenario's own fills.
    function test_scenarioDepthsAreTheDerivedOnes() public view {
        Scn memory s = _scenario(7);
        uint256[40] memory b0 = math.depths(math.openLnInv(s.sigma), s.capital, s.alpha);
        for (uint256 j; j < BANDS; ++j) {
            assertEq(b0[j], s.b0[j]);
        }
    }

    function test_fillPacked_rejectsAStateOutOfRange() public {
        Scn memory s = _scenario(3);
        ILadderMath.PackedIn memory a = _in(s, s.sigma);
        // band 1 (the high half of word 0) just above 1e36
        a.v[0] = (a.v[0] & type(uint128).max) | uint256(1e36 + 1) << 128;
        vm.expectRevert(LadderMath.InvalidState.selector);
        math.fillPacked(a, _ctx(s.x, s.sd, s.g, s.g), 0, 39, 1e18, type(int256).min);
    }

    function test_fillPacked_checksTheDepthsFirst() public {
        Scn memory s = _scenario(5);
        ILadderMath.PackedIn memory a = _in(s, s.sigma);
        a.alpha = 0.8e18;
        // a bad set too: the depth check comes first, as `depths` comes before `fillFrom`
        vm.expectRevert(LadderMath.AlphaTooHigh.selector);
        math.fillPacked(a, _ctx(s.x, s.sd, s.g, s.g), 3, 2, 1e18, type(int256).min);
    }
}
