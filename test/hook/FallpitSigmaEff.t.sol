// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {LadderMath} from "../../src/LadderMath.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {FallpitLens} from "../../src/hook/FallpitLens.sol";

/// @notice House vol learning (SPEC section 10): the book's vol keeper sets the sigma an
///         open round prices its remaining sd and vega with. Who may call, the clamps (the book's
///         `stepSigmaEff`), the rate limit, and
///         that the hook and the lens price with it while the bands stay on the round's sigma. Runs on the
///         real LadderMath.
contract FallpitSigmaEffTest is HookFixture {
    address internal volKeeper = makeAddr("volKeeper");
    uint256 internal constant SIGMA = 0.02e18; // sqrt(SEED_VAR)

    function _mathAddress() internal override returns (address) {
        return address(new LadderMath());
    }

    function setUp() public override {
        super.setUp();
        // the role waits OWNER_DELAY (24 hours in the fixture), like the guardian
        // (announced 24 hours before the fixture's clock, as `_setParams` does)
        vm.warp(clock - 24 hours);
        vm.prank(owner);
        book.setVolKeeper(volKeeper);
        vm.warp(clock);
        _open();
        _fund(alice, 100_000e18);
    }

    function _set(uint256 s) internal returns (uint256) {
        vm.prank(volKeeper);
        hook.setSigmaEff(roundId, s);
        return hook.sigmaEffOf(roundId);
    }

    // ---------------------------------------------------------------------------------------------- roles

    function test_sigmaEff_defaultsToRoundSigma() public view {
        assertEq(hook.getConfig(roundId).sigma, SIGMA);
        assertEq(hook.sigmaEffOf(roundId), SIGMA);
    }

    function test_setSigmaEff_onlyVolKeeper() public {
        vm.prank(alice);
        vm.expectRevert(IFallpitHook.OnlyVolKeeper.selector);
        hook.setSigmaEff(roundId, SIGMA);
        vm.prank(owner);
        vm.expectRevert(IFallpitHook.OnlyVolKeeper.selector);
        hook.setSigmaEff(roundId, SIGMA);
        vm.prank(keeper);
        vm.expectRevert(IFallpitHook.OnlyVolKeeper.selector);
        hook.setSigmaEff(roundId, SIGMA);
    }

    function test_setVolKeeper_onlyOwner_andWaitsTheDelay() public {
        address next = makeAddr("next");
        vm.prank(alice);
        vm.expectRevert();
        book.setVolKeeper(next);

        vm.prank(owner);
        book.setVolKeeper(next);
        // the old one stays in force until the delay is over
        assertEq(book.volKeeper(), volKeeper);
        vm.prank(next);
        vm.expectRevert(IFallpitHook.OnlyVolKeeper.selector);
        hook.setSigmaEff(roundId, SIGMA);
        _warp(clock + 24 hours);
        assertEq(book.volKeeper(), next);
        vm.prank(next);
        hook.setSigmaEff(roundId, SIGMA);
    }

    function test_setVolKeeper_zeroMeansNobody() public {
        vm.prank(owner);
        book.setVolKeeper(address(0));
        _warp(clock + 24 hours);
        assertEq(book.volKeeper(), address(0));
        vm.prank(volKeeper);
        vm.expectRevert(IFallpitHook.OnlyVolKeeper.selector);
        hook.setSigmaEff(roundId, SIGMA);
    }

    function test_setSigmaEff_onlyOpenRounds() public {
        vm.prank(volKeeper);
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        hook.setSigmaEff(keccak256("no such round"), SIGMA);

        _recordClose(S0, TRUSTLESS);
        hook.settleRound(house, day);
        vm.prank(volKeeper);
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        hook.setSigmaEff(roundId, SIGMA);
    }

    // --------------------------------------------------------------------------------------------- clamps

    /// @dev Bounds: at most 10% per update, one update per 5 minutes,
    ///      0.8x to 1.5x of the round's sigma, all rises of a round at most 1.5x in total.
    function test_setSigmaEff_stepClamp() public {
        assertEq(_set(SIGMA * 10), SIGMA * 11 / 10, "one step up is at most 10%");
        _warp(clock + 300);
        assertEq(_set(SIGMA * 10), SIGMA * 121 / 100, "and again from there");
        _warp(clock + 300);
        assertEq(_set(0), SIGMA * 121 / 100 * 9 / 10, "one step down is at most 10%");
    }

    function test_setSigmaEff_topAt1_5x() public {
        for (uint256 i; i < 6; ++i) {
            _set(SIGMA * 10);
            _warp(clock + 300);
        }
        assertEq(hook.sigmaEffOf(roundId), SIGMA * 3 / 2, "never above 1.5x the round's sigma");
    }

    function test_setSigmaEff_floorAt0_8x() public {
        assertEq(_set(1), SIGMA * 9 / 10);
        _warp(clock + 300);
        assertEq(_set(1), SIGMA * 81 / 100);
        _warp(clock + 300);
        assertEq(_set(1), SIGMA * 8 / 10, "never below 0.8x the round's sigma");
    }

    function test_setSigmaEff_insideTheClampsIsTaken() public {
        assertEq(_set(0.021e18), 0.021e18);
        _warp(clock + 300);
        assertEq(_set(0.0195e18), 0.0195e18);
    }

    function test_setSigmaEff_oneUpdateEveryFiveMinutes() public {
        _set(0.021e18);
        _warp(clock + 299);
        vm.prank(volKeeper);
        vm.expectRevert(IFallpitHook.SigmaEffTooSoon.selector);
        hook.setSigmaEff(roundId, 0.022e18);
        _warp(clock + 1);
        assertEq(_set(0.022e18), 0.022e18);
        (uint96 inForce, uint64 at,) = book.sigmaEffState(roundId);
        assertEq(inForce, 0.022e18);
        assertEq(at, clock);
    }

    /// @dev Once the rises of a round reach 1.5x in total, it can only fall: down from 1.21x to 0.98x,
    ///      it can rise again only by what is left (1.5 / 1.21).
    function test_setSigmaEff_riseBudget() public {
        _set(SIGMA * 2);
        _warp(clock + 300);
        _set(SIGMA * 2); // 1.21x, rises so far 1.21
        for (uint256 i; i < 3; ++i) {
            _warp(clock + 300);
            _set(1);
        }
        uint256 low = hook.sigmaEffOf(roundId);
        assertEq(low, SIGMA * 121 / 100 * 9 / 10 * 9 / 10 * 9 / 10, "down three steps");
        for (uint256 i; i < 6; ++i) {
            _warp(clock + 300);
            _set(SIGMA * 2);
        }
        // the rises together reach 1.5: low * 1.5 / 1.21
        assertApproxEqRel(hook.sigmaEffOf(roundId), low * 150 / 121, 1e9, "rises stop at the budget");
        (,, uint96 rise) = book.sigmaEffState(roundId);
        assertApproxEqRel(rise, 1.5e18, 1e9);
        assertLe(rise, 1.5e18);
    }

    function test_setSigmaEff_emits() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit IFallpitHook.SigmaEffSet(roundId, SIGMA * 11 / 10);
        _set(SIGMA * 4);
    }

    /// @dev Any sequence of posts stays inside [0.8, 1.5] x sigma, each step inside [0.9, 1.1] of the sigma
    ///      in force, and the product of the rises at most 1.5.
    function testFuzz_setSigmaEff_alwaysInsideTheClamps(uint256[12] calldata posts) public {
        uint256 inForce = SIGMA;
        uint256 rises = 1e18;
        for (uint256 i; i < posts.length; ++i) {
            uint256 got = _set(bound(posts[i], 0, 1e18));
            assertGe(got, SIGMA * 8 / 10);
            assertLe(got, SIGMA * 3 / 2);
            assertGe(got, inForce * 9 / 10);
            assertLe(got, inForce * 11 / 10);
            if (got > inForce) rises = rises * got / inForce;
            assertLe(rises, 1.5e18 + 1e9);
            inForce = got;
            _warp(clock + 300);
        }
    }

    // ------------------------------------------------------------------------------------------- pricing

    /// @dev A larger learned sigma widens the remaining distribution: with the price 2% above the close,
    ///      HIGHER is cheaper (further from certain); the bands and their price bounds do not move.
    function test_market_pricesWithSigmaEff_bandsStay() public {
        uint256 price = S0 * 102 / 100;
        FallpitLens.Market memory before = lens.market(roundId, price, clock);
        _set(SIGMA * 3 / 2);
        FallpitLens.Market memory wider = lens.market(roundId, price, clock);
        assertEq(wider.sigma, SIGMA, "the round's sigma is unchanged");
        assertEq(wider.sigmaEff, SIGMA * 11 / 10);
        assertLt(wider.products[HIGHER].price, before.products[HIGHER].price, "wider sd: HIGHER cheaper");
        assertGt(wider.products[HIGHER].price, 0.5e18);
        for (uint256 i; i < before.products.length; ++i) {
            assertEq(wider.products[i].low, before.products[i].low);
            assertEq(wider.products[i].high, before.products[i].high);
        }
    }

    /// @dev The hook fills at the learned sigma in force at fill time, exactly as the lens quotes it.
    function test_fill_usesSigmaEffAtFillTime_matchesLens() public {
        uint256 price = S0 * 101 / 100;
        uint256 shares = 1_000e18;
        uint256 start = chip.balanceOf(alice);
        uint256 id = _commitBuy(alice, HIGHER, shares, 100_000e18);
        uint64 t = router.getCommit(id).fillTs;
        (uint256 atRoundSigma,,,,,) = lens.quote(roundId, HIGHER, true, shares, price, t);
        // the update lands between the commit and its fill
        _set(SIGMA / 2 + SIGMA / 4);
        (uint256 quoted,,,,,) = lens.quote(roundId, HIGHER, true, shares, price, t);
        assertGt(quoted, atRoundSigma, "a narrower sd makes HIGHER dearer above the close");
        assertTrue(_fill(id, price));
        assertEq(start - chip.balanceOf(alice), quoted, "the fill paid the lens quote at sigmaEff");
    }

    /// @dev A commit whose limit was set before an update that makes it dearer is refunded, not filled.
    function test_fill_updateAboveLimit_refunds() public {
        uint256 price = S0 * 101 / 100;
        uint256 shares = 1_000e18;
        (uint256 quoted,,,,,) = lens.quote(roundId, HIGHER, true, shares, price, clock + 2);
        uint256 start = chip.balanceOf(alice);
        uint256 id = _commitBuy(alice, HIGHER, shares, quoted * 1001 / 1000);
        _set(SIGMA * 2 / 3);
        assertFalse(_fill(id, price), "refunded on its limit");
        assertEq(chip.balanceOf(alice), start, "the escrow came back");
        assertEq(_token(HIGHER).balanceOf(alice), 0);
    }

    /// @dev The opening depths never change: b0 is read back the same after updates.
    function test_sigmaEff_neverTouchesB0() public {
        (, uint256[40] memory b0Before) = hook.getCurve(roundId);
        _set(SIGMA * 3 / 2);
        (, uint256[40] memory b0After) = hook.getCurve(roundId);
        for (uint256 j; j < 40; ++j) {
            assertEq(b0After[j], b0Before[j]);
        }
    }

    function test_unknownRound_sigmaEffIsZero() public view {
        assertEq(hook.sigmaEffOf(keccak256("no such round")), 0);
    }
}
