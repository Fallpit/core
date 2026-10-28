// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {HookFixture} from "./HookFixture.sol";
import {MockChip} from "./mocks/MockChips.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {PitMath} from "../../src/hook/PitMath.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {Menus} from "../Menus.sol";

/// @notice Fees and quotes, settlement and the challenge window, voids, the next round, other decimals.
contract FallpitLifecycleTest is HookFixture {
    uint256 internal constant STAKE = 100_000e18;

    function setUp() public override {
        super.setUp();
        _fund(alice, STAKE);
        _fund(bob, STAKE);
        _fund(carol, STAKE);
    }

    // --------------------------------------------------------------------------------------------
    // fees and quotes
    // --------------------------------------------------------------------------------------------

    function test_fees_baseRampAndVega_matchLensQuote() public {
        _open();
        uint256 shares = 1_000e18;
        uint256 vegaFee = shares * 0.1e18 / 1e18 * math.VEGA() / 1e18; // vegaFeeWad * vega per share

        // early in the session: 2% of the cost plus the vega fee
        (uint256 quoted, uint256 quotedFee, uint256 pBefore, uint256 pAfter,,) =
            lens.quote(roundId, HIGHER, true, shares, S0, clock + 2);
        assertGt(pAfter, pBefore, "a buy moves the odds up");
        uint256 cost = _buy(alice, HIGHER, shares, S0);
        assertEq(cost, quoted, "the fill charges exactly the quote for the same print");
        assertEq(quotedFee, _ceilWad(quoted - quotedFee, 0.02e18) + vegaFee);
        assertEq(_state().protocolFees, quotedFee / 10, "10% of the fees is the protocol's");

        // 60 minutes before the close the rate is halfway up the ramp: 3.5%
        _warp(NYTime.closeTs(day) - 3600 - 2);
        (quoted, quotedFee,,,,) = lens.quote(roundId, HIGHER, true, shares, S0, clock + 2);
        cost = _buy(alice, HIGHER, shares, S0);
        assertEq(cost, quoted);
        assertEq(quotedFee, _ceilWad(quoted - quotedFee, 0.035e18) + vegaFee);

        // a sell pays the same kind of fee out of its proceeds
        (uint256 net, uint256 sellFee, uint256 pb, uint256 pa,,) =
            lens.quote(roundId, HIGHER, false, 500e18, S0, clock + 2);
        assertLt(pa, pb, "a sell moves the odds down");
        uint256 proceeds = _sell(alice, HIGHER, 500e18, S0);
        assertEq(proceeds, net);
        assertGt(sellFee, 0);
        assertLt(proceeds, cost / 2, "selling half right after buying returns less than half the cost");

        (uint256 worst, uint256 covered) = lens.solvency(roundId);
        assertLe(worst, covered);
        assertEq(lens.maxFill(roundId), HOUSE_CAPITAL / 50);
    }

    /// @dev The lens reports what the hook would do with the fill, in the hook's order: round not open,
    ///      per-fill cap, product cap, trading window, then the solvency and loss limit check. The round
    ///      opens with a product cap of a tenth of the capital per floor (the default
    ///      has no product cap) so that the cap's place in the order is covered.
    function test_lens_quote_reportsTheHooksRejection() public {
        IPitBook.Params memory p = book.defaultParams();
        p.floorCapBps = 1000;
        _setParams(p);
        _open();
        uint256 cap = lens.maxFill(roundId);
        (uint256 cushion, uint256 floor) = lens.lossLimit(roundId);
        assertEq(cushion, HOUSE_CAPITAL, "a fresh round has its whole capital as cushion");
        assertEq(floor, HOUSE_CAPITAL * 7 / 10, "the default loss limit: 30% of the capital");

        (uint256 chips,,,,, RefundReason rejection) = lens.quote(roundId, HIGHER, true, cap, S0, clock + 2);
        assertEq(uint8(rejection), uint8(RefundReason.None));
        assertGt(chips, 0);
        (chips,,,,, rejection) = lens.quote(roundId, HIGHER, true, cap + 1, S0, clock + 2);
        assertEq(uint8(rejection), uint8(RefundReason.Cap));
        assertGt(chips, 0, "the price is still quoted");
        uint256 id = _commitBuy(alice, HIGHER, cap + 1, STAKE);
        assertFalse(_fill(id, S0), "and the hook does refuse it");

        // a floor may have a tenth of the capital outstanding: five fills of the per-fill cap, not six
        for (uint256 i; i < 5; ++i) {
            (,,,,, rejection) = lens.quote(roundId, F4, true, cap, S0, clock + 2);
            assertEq(uint8(rejection), uint8(RefundReason.None));
            _buy(alice, F4, cap, S0);
        }
        (chips,,,,, rejection) = lens.quote(roundId, F4, true, 1e18, S0, clock + 2);
        assertEq(uint8(rejection), uint8(RefundReason.ProductCap));
        assertGt(chips, 0, "the price is still quoted");
        id = _commitBuy(alice, F4, 1e18, STAKE / 10);
        assertFalse(_fill(id, S0), "and the hook does refuse it");
        // the per-fill cap is reported before the product cap, and the product cap before the window
        (,,,,, rejection) = lens.quote(roundId, F4, true, cap + 1, S0, clock + 2);
        assertEq(uint8(rejection), uint8(RefundReason.Cap));
        (,,,,, rejection) = lens.quote(roundId, F4, true, 1e18, S0, NYTime.at(day0, 20 hours));
        assertEq(uint8(rejection), uint8(RefundReason.ProductCap));
        // a sell of the capped floor is never refused for the cap
        for (uint256 i; i < 5; ++i) {
            (,,,,, rejection) = lens.quote(roundId, F4, false, cap, S0, clock + 2);
            assertEq(uint8(rejection), uint8(RefundReason.None));
            _sell(alice, F4, cap, S0);
        }

        uint64 cutoff = hook.getConfig(roundId).cutoff;
        (,,,,, rejection) = lens.quote(roundId, HIGHER, true, cap, S0, cutoff);
        assertEq(uint8(rejection), uint8(RefundReason.None));
        (,,,,, rejection) = lens.quote(roundId, HIGHER, true, cap, S0, cutoff + 1);
        assertEq(uint8(rejection), uint8(RefundReason.Window));
        // overnight, between the after-hours and the pre-market
        (,,,,, rejection) = lens.quote(roundId, HIGHER, true, cap, S0, NYTime.at(day0, 20 hours));
        assertEq(uint8(rejection), uint8(RefundReason.Window));
        (,,,,, rejection) = lens.quote(roundId, HIGHER, true, cap, S0, NYTime.at(day, 4 hours) - 1);
        assertEq(uint8(rejection), uint8(RefundReason.Window));
        (,,,,, rejection) = lens.quote(roundId, HIGHER, true, cap, S0, NYTime.at(day, 4 hours));
        assertEq(uint8(rejection), uint8(RefundReason.None));

        // a sell of tokens nobody holds is quoted against an empty book and passes the checks
        (,,,,, rejection) = lens.quote(roundId, HIGHER, false, 1e18, S0, clock + 2);
        assertEq(uint8(rejection), uint8(RefundReason.None));

        _buy(alice, HIGHER, 1_000e18, S0);
        (cushion,) = lens.lossLimit(roundId);
        IFallpitHook.RoundState memory st = _state();
        assertEq(cushion, st.held - st.protocolFees - 1_000e18);
        // a floor inside HIGHER adds to the worst band, a floor outside it does not
        _buy(alice, F5, 300e18, S0);
        _buy(alice, F2, 200e18, S0);
        (cushion,) = lens.lossLimit(roundId);
        st = _state();
        assertEq(cushion, st.held - st.protocolFees - 1_300e18);

        _recordClose(S0, TRUSTLESS);
        hook.settleRound(house, day);
        (,,,,, rejection) = lens.quote(roundId, HIGHER, true, cap, S0, cutoff);
        assertEq(uint8(rejection), uint8(RefundReason.NotOpen));
    }

    /// @dev The check is the worst of the 40 bands of whatever menu the round has. The numbers are
    ///      checked on the six-product threshold menu, and repeated on the default menu.
    function test_postFillCheck_solvencyForAll_lossLimitForBuysOnly() public pure {
        // worst band pays 90: products 0 and 5 both win between the bottom and the middle strike
        uint256 m = Menus.thresholds();
        uint256[12] memory s;
        s[0] = 60;
        s[5] = 30;
        assertEq(PitMath.maxPayout(s, m), 90);
        // capital 100 at a 50% limit: a buy must leave a cushion of 50
        assertEq(uint8(PitMath.postFillCheck(s, m, 140, 0, 100, 5000, true)), uint8(RefundReason.None));
        assertEq(uint8(PitMath.postFillCheck(s, m, 139, 0, 100, 5000, true)), uint8(RefundReason.LossLimit));
        assertEq(uint8(PitMath.postFillCheck(s, m, 139, 0, 100, 5000, false)), uint8(RefundReason.None));
        // the protocol's fees are not the house's
        assertEq(uint8(PitMath.postFillCheck(s, m, 140, 1, 100, 5000, true)), uint8(RefundReason.LossLimit));
        // a sell only has to keep the round solvent
        assertEq(uint8(PitMath.postFillCheck(s, m, 90, 0, 100, 5000, false)), uint8(RefundReason.None));
        assertEq(uint8(PitMath.postFillCheck(s, m, 89, 0, 100, 5000, false)), uint8(RefundReason.Solvency));
        assertEq(uint8(PitMath.postFillCheck(s, m, 90, 1, 100, 5000, false)), uint8(RefundReason.Solvency));
        assertEq(uint8(PitMath.postFillCheck(s, m, 89, 0, 100, 5000, true)), uint8(RefundReason.Solvency));
        // a limit of 100% leaves only the solvency check
        assertEq(uint8(PitMath.postFillCheck(s, m, 90, 0, 100, 10_000, true)), uint8(RefundReason.None));
        // the tightest limit, 10%: a cushion of 90
        assertEq(uint8(PitMath.postFillCheck(s, m, 180, 0, 100, 1000, true)), uint8(RefundReason.None));
        assertEq(uint8(PitMath.postFillCheck(s, m, 179, 0, 100, 1000, true)), uint8(RefundReason.LossLimit));
        // the floor is not rounded down: half of 101 is 50.5, so a cushion of 50 is short
        assertEq(uint8(PitMath.postFillCheck(s, m, 140, 0, 101, 5000, true)), uint8(RefundReason.LossLimit));
        assertEq(uint8(PitMath.postFillCheck(s, m, 141, 0, 101, 5000, true)), uint8(RefundReason.None));

        // the default menu: a floor and the half of the pair that contains it are both paid in its bands
        m = Menus.standard();
        delete s;
        s[F5] = 60;
        s[HIGHER] = 30;
        s[LOWER] = 80;
        s[F1] = 5;
        assertEq(PitMath.maxPayout(s, m), 90, "F5 and HIGHER, not LOWER and F1");
        assertEq(uint8(PitMath.postFillCheck(s, m, 140, 0, 100, 5000, true)), uint8(RefundReason.None));
        assertEq(uint8(PitMath.postFillCheck(s, m, 139, 0, 100, 5000, true)), uint8(RefundReason.LossLimit));
        assertEq(uint8(PitMath.postFillCheck(s, m, 89, 0, 100, 5000, false)), uint8(RefundReason.Solvency));
        s[F1] = 11;
        assertEq(PitMath.maxPayout(s, m), 91, "now LOWER and F1");
    }

    function test_feeRate_bounds() public pure {
        uint64 close = 1_000_000;
        assertEq(PitMath.feeRate(0.02e18, 0.05e18, 7200, close, close - 7200), 0.02e18);
        assertEq(PitMath.feeRate(0.02e18, 0.05e18, 7200, close, close - 30_000), 0.02e18);
        assertEq(PitMath.feeRate(0.02e18, 0.05e18, 7200, close, close - 3600), 0.035e18);
        assertEq(PitMath.feeRate(0.02e18, 0.05e18, 7200, close, close), 0.05e18);
        assertEq(PitMath.feeRate(0.02e18, 0.05e18, 7200, close, close + 1), 0.05e18);
        assertEq(PitMath.feeRate(0.02e18, 0.05e18, 0, close, close - 1), 0.02e18, "no ramp");
    }

    /// @dev The winners are the products of the round's menu whose run contains the close's band. The
    ///      masks are checked on the six-product threshold menu, then on the default menu.
    function test_winnersAndWorstBand() public pure {
        uint256 m = Menus.thresholds();
        // band <= 15: every LOWER wins; band >= 24: every HIGHER wins
        assertEq(PitMath.winners(m, 0), uint16(2 | 8 | 32));
        assertEq(PitMath.winners(m, 15), uint16(2 | 8 | 32));
        assertEq(PitMath.winners(m, 16), uint16(1 | 8 | 32));
        assertEq(PitMath.winners(m, 19), uint16(1 | 8 | 32));
        assertEq(PitMath.winners(m, 20), uint16(1 | 4 | 32));
        assertEq(PitMath.winners(m, 23), uint16(1 | 4 | 32));
        assertEq(PitMath.winners(m, 24), uint16(1 | 4 | 16));
        assertEq(PitMath.winners(m, 39), uint16(1 | 4 | 16));
        uint256[12] memory s;
        (s[0], s[1], s[2], s[3], s[4], s[5]) = (1, 20, 300, 4000, 50_000, 600_000);
        // the four regions of the three strikes: L15+L19+L23, H15+L19+L23, H15+H19+L23, H15+H19+H23
        assertEq(PitMath.maxPayout(s, m), 20 + 4000 + 600_000);
        s[4] = 700_000;
        assertEq(PitMath.maxPayout(s, m), 1 + 300 + 700_000);
        (uint8 lo, uint8 hi) = PitMath.run(m, 0);
        assertEq(lo, 16);
        assertEq(hi, 39);
        (lo, hi) = PitMath.run(m, 5);
        assertEq(lo, 0);
        assertEq(hi, 23);

        // the default menu: in every band exactly one floor wins, and one of the pair
        m = Menus.standard();
        assertEq(PitMath.winners(m, 0), uint16(1 << F0 | 1 << LOWER));
        assertEq(PitMath.winners(m, 11), uint16(1 << F0 | 1 << LOWER));
        assertEq(PitMath.winners(m, 12), uint16(1 << F1 | 1 << LOWER));
        assertEq(PitMath.winners(m, 17), uint16(1 << F2 | 1 << LOWER));
        assertEq(PitMath.winners(m, 19), uint16(1 << F3 | 1 << LOWER));
        assertEq(PitMath.winners(m, 20), uint16(1 << F4 | 1 << HIGHER));
        assertEq(PitMath.winners(m, 23), uint16(1 << F5 | 1 << HIGHER));
        assertEq(PitMath.winners(m, 27), uint16(1 << F6 | 1 << HIGHER));
        assertEq(PitMath.winners(m, 28), uint16(1 << F7 | 1 << HIGHER));
        assertEq(PitMath.winners(m, 39), uint16(1 << F7 | 1 << HIGHER));
        delete s;
        for (uint256 i; i < PRODUCTS; ++i) {
            s[i] = 10 ** i;
        }
        assertEq(PitMath.maxPayout(s, m), 10 ** F7 + 10 ** HIGHER);
        s[F3] = 5e9;
        assertEq(PitMath.maxPayout(s, m), 5e9 + 10 ** LOWER);
        assertEq(PitMath.payoutOf(s, PitMath.winners(m, 18)), 5e9 + 10 ** LOWER);
    }

    function test_oracleFee_paidFromForwardedEth() public {
        _open();
        oracle.setFee(0.001 ether);
        uint256 id = _commitBuy(alice, HIGHER, 100e18, STAKE);
        _warp(router.getCommit(id).fillTs);
        bytes memory report = _report(clock, S0);

        // without ETH the oracle rejects the verification and the commit stays pending
        vm.expectRevert();
        router.fill(id, report);
        assertEq(uint8(router.getCommit(id).status), uint8(IFallpitRouter.CommitStatus.Pending));

        // ETH sent with the fill reaches the oracle through the hook; the change stays in the hook
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        assertTrue(router.fill{value: 0.01 ether}(id, report));
        assertEq(address(oracle).balance, 0.001 ether);
        assertEq(address(hook).balance, 0.009 ether);
        assertEq(address(router).balance, 0);
    }

    // --------------------------------------------------------------------------------------------
    // settlement, challenge window, void
    // --------------------------------------------------------------------------------------------

    function test_settle_requiresClose_and_isPermissionless() public {
        _open();
        _buy(alice, HIGHER, 1_000e18, S0);
        vm.expectRevert(IFallpitHook.CloseNotRecorded.selector);
        hook.settleRound(house, day);
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        hook.finalizeRound(house, day);

        _recordClose(S0, KEEPER); // exactly at the previous close: HIGHER wins (close at or above)
        vm.prank(carol);
        hook.settleRound(house, day);
        assertEq(_state().closeBand, 20);
        // the floor just above the previous close, and HIGHER
        assertEq(_state().winners, uint16(1 << F4 | 1 << HIGHER));
        vm.expectRevert(IFallpitHook.AlreadySettled.selector);
        hook.settleRound(house, day);
    }

    function test_challengeWindow_keeperClose() public {
        _open();
        _buy(alice, HIGHER, 1_000e18, S0);
        _buy(bob, LOWER, 1_000e18, S0);
        _recordClose(S0 * 101 / 100, KEEPER);
        hook.settleRound(house, day);
        uint64 settledAt = clock;
        assertFalse(_state().settledTrustless);

        // not final during the window, and nothing redeems yet
        vm.expectRevert(IFallpitHook.ChallengeWindowOpen.selector);
        hook.finalizeRound(house, day);
        uint256 higher = _token(HIGHER).id;
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        vm.prank(alice);
        hook.redeem(higher, alice, 1e18);

        // On the round clock the default challenge window is 900 s.
        assertEq(hook.getConfig(roundId).params.challengeWindow, 900);
        _warp(settledAt + 899);
        vm.expectRevert(IFallpitHook.ChallengeWindowOpen.selector);
        hook.finalizeRound(house, day);
        _warp(settledAt + 900);
        // the guardian's window is over at the same instant finalization opens, and a settled round can
        // never be voided
        vm.expectRevert(IPitBook.DisputeNotAllowed.selector);
        vm.prank(guardian);
        book.dispute(roundId);
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        vm.prank(guardian);
        hook.voidRound(house, day);
        hook.finalizeRound(house, day);
        vm.prank(alice);
        assertEq(hook.redeem(higher, alice, 1_000e18), 1_000e18);
    }

    function test_trustlessPrintReplacesKeeperClose_andResettles() public {
        _open();
        _buy(alice, HIGHER, 1_000e18, S0);
        _buy(bob, LOWER, 1_000e18, S0);
        _recordClose(S0 * 1002 / 1000, KEEPER); // keeper says up
        hook.settleRound(house, day);
        assertEq(_state().winners, uint16(1 << F4 | 1 << HIGHER));

        // the same keeper cannot overwrite its own close (no dispute runs)
        bytes memory again = abi.encode(NVDA, KEEPER, oracle.printCount(NVDA, KEEPER) - 1);
        vm.expectRevert(IPitBook.ReplacementRefused.selector);
        book.recordClose(NVDA, day, again);

        // a trustless print for the same instant says down: it replaces the close
        book.recordClose(NVDA, day, oracle.post(NVDA, TRUSTLESS, S0 * 998 / 1000, NYTime.closeTs(day)));
        vm.expectRevert(IFallpitHook.CloseChanged.selector);
        hook.finalizeRound(house, day);
        // the guardian has no say once the close is trustless
        vm.expectRevert(IPitBook.DisputeNotAllowed.selector);
        vm.prank(guardian);
        book.dispute(roundId);

        hook.settleRound(house, day);
        assertTrue(_state().settledTrustless);
        assertEq(_state().winners, uint16(1 << F3 | 1 << LOWER), "LOWER wins on the trustless close");
        hook.finalizeRound(house, day); // immediately

        // nothing replaces a trustless close
        vm.expectRevert(IPitBook.CloseIsFinal.selector);
        book.recordClose(NVDA, day, again);

        uint256 lower = _token(LOWER).id;
        uint256 higher = _token(HIGHER).id;
        vm.prank(bob);
        assertEq(hook.redeem(lower, bob, 1_000e18), 1_000e18);
        vm.expectRevert(IFallpitHook.NotWinner.selector);
        vm.prank(alice);
        hook.redeem(higher, alice, 1_000e18);
    }

    /// @dev A void (no close 24 hours after the close) refunds every token its product's average cost. (The
    ///      guardian cannot void.)
    function test_void_refundsAverageCost() public {
        _open();
        _buy(alice, HIGHER, 2_000e18, S0);
        _buy(bob, HIGHER, 1_000e18, S0 * 1001 / 1000);
        uint256 carolCost = _buy(carol, F5, 3_000e18, S0); // a floor (was LOWER at +1 sigma)
        _sell(alice, HIGHER, 500e18, S0);
        (, uint256[12] memory premium) = hook.getSupplies(roundId);
        IFallpitHook.RoundState memory open = _state();

        // the close is never recorded; a day later anyone voids
        _warp(NYTime.closeTs(day) + 24 hours + 1);
        vm.prank(owner);
        hook.voidRound(house, day);

        IFallpitHook.RoundState memory st = _state();
        assertEq(uint8(st.status), uint8(IFallpitHook.Status.Void));
        uint256 refunds = premium[HIGHER] + premium[F5];
        assertEq(st.payoutOwed, refunds);
        assertEq(st.protocolFees, 0, "fees are refunded with the cost, none go to the protocol");
        assertEq(chip.balanceOf(address(vault)), open.held - refunds, "the vault gets what is left");
        assertFalse(vault.isLocked(house));
        assertEq(hook.protocolFeesAccrued(address(chip)), 0);

        // HIGHER: 2500 shares outstanding share one pot; the floor: carol gets her whole cost back
        uint256 t2 = _token(HIGHER).id;
        uint256 t5 = _token(F5).id;
        assertEq(premium[F5], carolCost);
        vm.prank(carol);
        assertEq(hook.redeem(t5, carol, 3_000e18), carolCost);
        vm.prank(alice);
        uint256 aliceRefund = hook.redeem(t2, alice, 1_500e18);
        vm.prank(bob);
        uint256 bobRefund = router.redeem(t2, 1_000e18);
        assertApproxEqAbs(aliceRefund, premium[HIGHER] * 1500 / 2500, 1);
        assertApproxEqAbs(bobRefund, premium[HIGHER] * 1000 / 2500, 1);
        assertLe(aliceRefund + bobRefund, premium[HIGHER]);

        assertLe(_state().payoutOwed, 1, "at most rounding dust stays owed");
        _assertHookSolvent(address(chip));
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        hook.finalizeRound(house, day);
    }

    function test_void_noCloseAfter24h_isPermissionless() public {
        _open();
        uint256 cost = _buy(alice, F3, 1_000e18, S0);
        uint64 closeAt = NYTime.closeTs(day);

        _warp(closeAt + 24 hours);
        vm.expectRevert(IFallpitHook.VoidNotAllowed.selector);
        hook.voidRound(house, day);
        _warp(closeAt + 24 hours + 1);
        vm.prank(carol);
        hook.voidRound(house, day);

        assertEq(chip.balanceOf(address(vault)), HOUSE_CAPITAL, "the house gets exactly its capital back");
        uint256 t0 = _token(F3).id;
        vm.prank(alice);
        assertEq(
            hook.redeem(t0, alice, 1_000e18), cost, "the only holder gets the full cost back, fees included"
        );
        assertEq(chip.balanceOf(alice), STAKE);
        assertEq(chip.balanceOf(address(hook)), 0);
    }

    function test_void_notAllowedOnceCloseRecorded() public {
        _open();
        _buy(alice, F3, 1_000e18, S0);
        _warp(NYTime.closeTs(day) + 1 hours);
        _recordClose(S0, KEEPER);
        _warp(NYTime.closeTs(day) + 25 hours);
        vm.expectRevert(IFallpitHook.VoidNotAllowed.selector);
        hook.voidRound(house, day);
        hook.settleRound(house, day); // a close recorded in time settles, however late the settle
    }

    /// @dev A close first recorded after the void point (12 hours after its instant) is late: it settles
    ///      nothing and does not stop the void.
    function test_void_aLateCloseDoesNotStopIt() public {
        _open();
        _buy(alice, F3, 1_000e18, S0);
        _warp(NYTime.closeTs(day) + 25 hours);
        _recordClose(S0, KEEPER);
        vm.expectRevert(IFallpitHook.CloseNotRecorded.selector);
        hook.settleRound(house, day);
        hook.voidRound(house, day);
        assertEq(uint8(hook.getState(roundId).status), uint8(IFallpitHook.Status.Void));
    }

    // --------------------------------------------------------------------------------------------
    // the next round, other decimals
    // --------------------------------------------------------------------------------------------

    function test_nextRound_opensWithTheReturnedCapital() public {
        _open();
        _buy(alice, LOWER, 5_000e18, S0); // LOWER loses below
        _closeAndFinalize(S0 * 101 / 100);
        uint256 capital = vault.roundCapital(house);
        assertGt(capital, HOUSE_CAPITAL, "the house kept the losing premium");

        // Wednesday opens on Tuesday's close and the updated variance
        bytes32 next = hook.openRound(NVDA, address(chip), day + 1);
        IFallpitHook.RoundConfig memory c = hook.getConfig(next);
        assertEq(c.capital, capital);
        assertEq(c.s0, S0 * 101 / 100);
        assertEq(c.sigma, FixedPointMathLib.sqrtWad(book.getTicker(NVDA).varWad));
        assertEq(hook.houseRound(house), next);
        // the old round is untouched
        assertEq(uint8(_state().status), uint8(IFallpitHook.Status.Final));
    }

    function test_sixDecimalChip_fullRound() public {
        MockChip usd = new MockChip(6);
        bytes32 usdHouse = _fundHouse(address(usd), 50_000e6);
        roundId = hook.openRound(NVDA, address(usd), day);
        _warp(NYTime.openTs(day) + 60);
        usd.mint(alice, 10_000e6);
        vm.prank(alice);
        usd.approve(address(router), type(uint256).max);

        vm.prank(alice);
        uint256 id = router.commit{value: FILL_FEE}(roundId, HIGHER, true, 500e6, 10_000e6);
        assertTrue(_fill(id, S0));
        Ticket memory token = _token(HIGHER);
        assertEq(token.decimals(), 6);
        assertEq(token.balanceOf(alice), 500e6);
        uint256 cost = 10_000e6 - usd.balanceOf(alice);
        assertGt(cost, 200e6);
        assertLt(cost, 320e6);

        vm.startPrank(alice);
        token.approve(address(router), 200e6);
        id = router.commit{value: FILL_FEE}(roundId, HIGHER, false, 200e6, 0);
        vm.stopPrank();
        assertTrue(_fill(id, S0));
        _assertSupplies();
        _assertHookSolvent(address(usd));

        _warp(NYTime.closeTs(day) + 5);
        book.recordClose(NVDA, day, oracle.post(NVDA, TRUSTLESS, S0 * 1001 / 1000, NYTime.closeTs(day)));
        hook.settleRound(usdHouse, day);
        hook.finalizeRound(usdHouse, day);
        vm.prank(alice);
        assertEq(router.redeem(token.id, 300e6), 300e6);
        uint256 fees = hook.collectProtocolFees(address(usd));
        assertEq(usd.balanceOf(alice) + usd.balanceOf(address(vault)) + fees, 60_000e6, "conservation");
        assertEq(usd.balanceOf(address(hook)), 0);
    }

    function test_collectProtocolFees_needsRecipient() public {
        _open();
        _buy(alice, HIGHER, 1_000e18, S0);
        _closeAndFinalize(S0);
        vm.prank(owner);
        book.setFeeRecipient(address(0));
        vm.expectRevert(IFallpitHook.ZeroAddress.selector);
        hook.collectProtocolFees(address(chip));
    }

    function _ceilWad(uint256 a, uint256 rate) private pure returns (uint256) {
        return (a * rate + 1e18 - 1) / 1e18;
    }
}
