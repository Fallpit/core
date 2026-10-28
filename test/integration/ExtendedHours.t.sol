// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {PitVault} from "../../src/PitVault.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {PitClock} from "../../src/hook/PitClock.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";

/// @notice Rounds on the two clocks, through the real contracts (SPEC 7.2, 7.3): a stock round that opens
///         a minute after the previous close and is traded in the after-hours, the pre-market and the
///         regular session; the edges of every window, for commits and for fills; the after-hours skip
///         flag; a stock round over a weekend; and an every-day asset that rolls from one daily round
///         into the next through a weekend.
/// @dev What these tests show is that the contracts do what the SPEC says in the extended hours. They do
///      not show that the pricing engine is safe there: its simulations only covered the regular session.
contract ExtendedHoursTest is IntegrationFixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant STAKE = 200_000e18;
    address internal lp2 = makeAddr("lp2");

    uint64 internal prevClose;
    uint64 internal afterHoursEnd;
    uint64 internal preMarketStart;
    uint64 internal regularStart;
    uint64 internal cutoff;

    event Refunded(uint256 indexed commitId, address indexed user, RefundReason reason);

    function setUp() public override {
        super.setUp();
        _fund(alice, STAKE);
        _fund(bob, STAKE);
        _fund(carol, STAKE);
        _setTimes(day0, day);
    }

    function _setTimes(uint32 prevDay, uint32 roundDay) internal {
        prevClose = NYTime.closeTs(prevDay);
        afterHoursEnd = NYTime.at(prevDay, 20 hours);
        preMarketStart = NYTime.at(roundDay, 4 hours);
        regularStart = NYTime.openTs(roundDay);
        cutoff = NYTime.closeTs(roundDay) - 630;
    }

    /// @dev A commit made now must be refused by the router: its fill instant is outside every window.
    function _expectNoCommit(address user) internal {
        vm.expectRevert(IFallpitRouter.OutsideTradingWindow.selector);
        vm.prank(user);
        router.commit{value: FILL_FEE}(roundId, HIGHER, true, 1_000e18, STAKE);
    }

    /// @dev Buys at the print of `ts` (the commit is made two seconds earlier) and checks that the fill
    ///      was priced on the clock's rho of that second and cost what the lens quoted.
    function _buyAt(uint64 ts, address user, uint8 index, uint256 shares, uint256 price)
        internal
        returns (uint256 cost)
    {
        _warp(ts - 2);
        (uint256 quoted,,,,, RefundReason rejection) =
            lens.quote(roundId, index, true, shares, _grid(price), ts);
        assertEq(uint8(rejection), uint8(RefundReason.None));
        uint256 gBefore = _state().g;
        cost = _buy(user, index, shares, price);
        assertEq(clock, ts, "filled at the print of that second");
        assertEq(cost, quoted, "the lens quoted the fill");
        (uint256 rho, bool tradable) = lens.clockAt(roundId, ts);
        assertTrue(tradable);
        uint256 g = rho.sqrtWad() < 0.3e18 ? 0.3e18 : rho.sqrtWad();
        assertEq(_state().g, g < gBefore ? g : gBefore, "depth follows the clock and never rises");
    }

    function _sumOf(address[5] memory who) internal view returns (uint256 sum) {
        for (uint256 i; i < who.length; ++i) {
            sum += chip.balanceOf(who[i]);
        }
    }

    // --------------------------------------------------------------------------------------------
    // a stock round, traded in all three windows
    // --------------------------------------------------------------------------------------------

    function test_stockRound_tradedInAfterHoursPreMarketAndRegularSession() public {
        uint256 minted = 3 * STAKE + HOUSE_CAPITAL;
        // Monday 16:01 New York: Monday's close is on the books and the house is free. Tuesday's round opens.
        assertEq(clock, prevClose + 60);
        bytes32 tuesday = hook.openRound(NVDA, address(chip), day);
        roundId = tuesday;
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(c.openTs, prevClose + 60, "open from the moment it was opened");
        assertEq(c.closeTs, NYTime.closeTs(day));
        assertEq(c.clock.prevDay, day0);
        PitClock.Times memory w = lens.windows(roundId);
        assertEq(w.prevClose, prevClose);
        assertEq(w.afterHoursEnd, afterHoursEnd);
        assertEq(w.preMarketStart, preMarketStart);
        assertEq(w.regularStart, regularStart);
        assertEq(w.cutoff, cutoff);
        assertTrue(vault.isLocked(house), "the house is in the round from now to Tuesday's close");

        // ---- Monday's after-hours
        uint256 aliceCost = _buyAt(prevClose + 5 minutes, alice, HIGHER, 10_000e18, S0 * 1002 / 1000);
        (uint256 rho,) = lens.clockAt(roundId, clock);
        assertEq(rho, 1e18 - uint256(0.06e18) * 300 / 14_400, "five minutes of the after-hours' 6% are gone");
        _buyAt(prevClose + 2 hours, bob, LOWER, 8_000e18, S0 * 998 / 1000);
        assertEq(_state().g, uint256(0.97e18).sqrtWad());
        // the last second of the after-hours trades; the commit for it is made at 19:59:57
        _buyAt(afterHoursEnd - 1, carol, F4, 3_000e18, S0 * 1001 / 1000);

        // ---- the night: no commit is taken, and the lens says why
        _expectNoCommit(alice);
        _warp(afterHoursEnd + 4 hours);
        _expectNoCommit(alice);
        (uint256 nightQuote,,,,, RefundReason rejection) =
            lens.quote(roundId, HIGHER, true, 1_000e18, S0, afterHoursEnd + 4 hours);
        assertEq(uint8(rejection), uint8(RefundReason.Window));
        assertGt(nightQuote, 0, "a price is still quoted");

        // ---- Tuesday's pre-market: the overnight gap's 14% reaches the book at the first fill
        _buyAt(preMarketStart, bob, LOWER, 2_000e18, S0 * 1006 / 1000);
        assertEq(_state().g, uint256(0.8e18).sqrtWad(), "80% of the variance is left at 04:00");
        uint256 before = chip.balanceOf(alice);
        _warp(preMarketStart + 2 hours);
        uint256 proceeds = _sell(alice, HIGHER, 4_000e18, S0 * 1007 / 1000);
        assertEq(chip.balanceOf(alice), before + proceeds);
        assertGt(proceeds, 0);

        // ---- the regular session, without a break after the pre-market
        _buyAt(regularStart - 60, carol, F4, 2_000e18, S0 * 1005 / 1000);
        _buyAt(regularStart, alice, F4, 5_000e18, S0 * 1005 / 1000);
        assertEq(_state().g, uint256(0.7e18).sqrtWad(), "70% is left at the opening bell");
        _buyAt(regularStart + 3 hours + 15 minutes, bob, F6, 6_000e18, S0 * 1009 / 1000);
        assertEq(_state().g, uint256(0.35e18).sqrtWad());
        // the cutoff itself trades (the commit for it is made at 15:49:28); nothing later does
        _buyAt(cutoff, carol, HIGHER, 1_000e18, S0 * 1008 / 1000);
        assertEq(_state().g, 0.3e18, "the depth scale is on its floor");
        _expectNoCommit(alice);
        _assertSupplies();
        _assertHookSolvent(address(chip));
        assertLt(aliceCost, 10_000e18);

        // ---- the close: a keeper print, so the round waits out the challenge window (900 s by default)
        uint256 close = _grid(S0 * 1008 / 1000);
        _recordClose(close, KEEPER_SOURCE);
        hook.settleRound(house, day);
        IFallpitHook.RoundState memory settled = _state();
        // (on the three strikes: HIGHER@15, HIGHER@19, LOWER@23)
        assertEq(settled.winners, uint16(1 << F4 | 1 << HIGHER), "up 0.8%: the floor from 0 to +0.5, HIGHER");
        vm.expectRevert(IFallpitHook.ChallengeWindowOpen.selector);
        hook.finalizeRound(house, day);
        vm.expectRevert(IFallpitHook.PreviousRoundActive.selector);
        hook.openRound(NVDA, address(chip), day + 1);
        _warp(settled.settledAt + 900);
        hook.finalizeRound(house, day);

        // ---- and Wednesday's round opens at once, in Tuesday's after-hours, and trades
        day += 1;
        _setTimes(day - 1, day);
        bytes32 wednesday = hook.openRound(NVDA, address(chip), day);
        roundId = wednesday;
        assertEq(hook.getConfig(wednesday).s0, close, "Wednesday starts from Tuesday's close");
        assertEq(hook.getConfig(wednesday).openTs, clock);
        assertLt(clock, afterHoursEnd, "Tuesday 16:15: the after-hours");
        uint256 wednesdayCost = _buyAt(clock + 60, alice, LOWER, 2_000e18, close);

        // Tuesday's winners redeem while Wednesday trades
        Ticket[12] memory tokens = ticketsOf(hook, tuesday);
        vm.prank(alice);
        assertEq(router.redeem(tokens[HIGHER].id, 6_000e18), 6_000e18);
        vm.prank(alice);
        assertEq(router.redeem(tokens[F4].id, 5_000e18), 5_000e18);
        vm.prank(carol);
        assertEq(router.redeem(tokens[F4].id, 5_000e18), 5_000e18);
        vm.prank(carol);
        assertEq(router.redeem(tokens[HIGHER].id, 1_000e18), 1_000e18);
        vm.expectRevert(IFallpitHook.NotWinner.selector);
        vm.prank(bob);
        router.redeem(tokens[LOWER].id, 10_000e18);
        vm.expectRevert(IFallpitHook.NotWinner.selector);
        vm.prank(bob);
        router.redeem(tokens[F6].id, 6_000e18);
        hook.collectProtocolFees(address(chip));

        // every chip is where the books say: the traders, the fee recipient, and Wednesday's round
        IFallpitHook.RoundState memory open = _state();
        assertEq(open.held, hook.getConfig(wednesday).capital + wednesdayCost);
        assertEq(chip.balanceOf(address(router)), 0);
        assertEq(
            _sumOf([alice, bob, carol, feeRecipient, address(vault)]) + chip.balanceOf(address(hook)),
            minted,
            "cash conservation"
        );
        assertEq(
            chip.balanceOf(address(hook)), open.held, "the hook holds Wednesday's round and nothing else"
        );
        _assertVaultBacked(address(chip));
    }

    // --------------------------------------------------------------------------------------------
    // the edges of the windows
    // --------------------------------------------------------------------------------------------

    /// @dev A commit is priced `fillDelay` (2 s) after it was made, and it is accepted only when that
    ///      instant is inside a window: the last commit of a window is made two seconds before its end.
    function test_commits_atEveryWindowEdge() public {
        roundId = hook.openRound(NVDA, address(chip), day);

        // after-hours [16:00:00, 20:00:00): the last fill instant is 19:59:59
        _warp(afterHoursEnd - 3);
        uint256 lastOfAfterHours = _commitBuy(alice, HIGHER, 1_000e18, 5_000e18);
        assertEq(router.getCommit(lastOfAfterHours).fillTs, afterHoursEnd - 1);
        _warp(afterHoursEnd - 2);
        _expectNoCommit(alice);
        assertTrue(_fill(lastOfAfterHours, S0), "the commit priced at 19:59:59 fills");
        _warp(afterHoursEnd);
        _expectNoCommit(alice);

        // pre-market from 04:00:00: the first fill instant is 04:00:00, committed at 03:59:58
        _warp(preMarketStart - 3);
        _expectNoCommit(alice);
        _warp(preMarketStart - 2);
        uint256 firstOfPreMarket = _commitBuy(alice, HIGHER, 1_000e18, 5_000e18);
        assertEq(router.getCommit(firstOfPreMarket).fillTs, preMarketStart);
        assertTrue(_fill(firstOfPreMarket, S0));

        // no edge at 09:30:00: the pre-market runs into the regular session
        _warp(regularStart - 3);
        uint256 a = _commitBuy(bob, LOWER, 1_000e18, 5_000e18);
        _warp(regularStart - 2);
        uint256 b = _commitBuy(bob, LOWER, 1_000e18, 5_000e18);
        assertTrue(_fill(a, S0));
        assertTrue(_fill(b, S0));

        // the cutoff 15:49:30 is the last fill instant, committed at 15:49:28
        _warp(cutoff - 2);
        uint256 last = _commitBuy(carol, F5, 1_000e18, 5_000e18);
        assertEq(router.getCommit(last).fillTs, cutoff);
        _warp(cutoff - 1);
        _expectNoCommit(carol);
        assertTrue(_fill(last, S0), "the commit priced at the cutoff fills");
        _warp(cutoff + 1);
        _expectNoCommit(carol);
    }

    /// @dev The print that prices a commit is the first one at or after its fill instant, up to 30 s
    ///      later. When that print was made outside the window the fill is rejected for good (`Window`),
    ///      the escrow goes back and the filler keeps the fill fee.
    function test_fillWhosePrintIsOutsideTheWindow_isRefunded() public {
        roundId = hook.openRound(NVDA, address(chip), day);
        uint64[2] memory edges = [afterHoursEnd - 1, cutoff];
        for (uint256 i; i < 2; ++i) {
            uint64 t = edges[i];
            _warp(t - 2);
            uint256 id = _commitBuy(alice, HIGHER, 1_000e18, 5_000e18);
            assertEq(router.getCommit(id).fillTs, t);
            // the keeper skipped two seconds: its next print covers the instant and was made at t + 2
            _warp(t + 2);
            bytes memory late = _signedPrint(NVDA, S0, t + 2, t - 1);
            (, bool tradable) = lens.clockAt(roundId, t + 2);
            assertFalse(tradable);

            // had the print been made inside the window (at t itself), the commit would have filled
            uint256 snapshot = vm.snapshotState();
            bytes memory onTime = _signedPrint(NVDA, S0, t, t - 1);
            vm.prank(keeper);
            assertTrue(router.fill(id, onTime));
            vm.revertToState(snapshot);
            vm.warp(clock);

            vm.expectEmit(true, true, false, true, address(router));
            emit Refunded(id, alice, RefundReason.Window);
            uint256 keeperBefore = keeper.balance;
            vm.prank(keeper);
            assertFalse(router.fill(id, late));
            assertEq(keeper.balance - keeperBefore, FILL_FEE, "the filler did the work: the fee is theirs");
            assertEq(chip.balanceOf(alice), STAKE, "the escrow is back");
            assertEq(_token(HIGHER).totalSupply(), 0);
        }
    }

    // --------------------------------------------------------------------------------------------
    // the after-hours skip flag
    // --------------------------------------------------------------------------------------------

    /// @dev Earnings come out after Monday's close: the owner flagged Tuesday beforehand. Tuesday's round
    ///      opens as always (the house is locked into it) and trades from the pre-market on.
    function test_skipAfterHours_theRoundTradesFromThePreMarket() public {
        vm.prank(owner);
        book.setSkipAfterHours(NVDA, day, true);
        roundId = hook.openRound(NVDA, address(chip), day);
        assertTrue(hook.getConfig(roundId).clock.skipAfterHours);
        assertTrue(vault.isLocked(house));

        _expectNoCommit(alice);
        (,,,,, RefundReason rejection) = lens.quote(roundId, HIGHER, true, 1_000e18, S0, clock + 2);
        assertEq(uint8(rejection), uint8(RefundReason.Window));
        // taking the flag back does not reach the open round: nobody changes an open round
        vm.prank(owner);
        book.setSkipAfterHours(NVDA, day, false);
        _warp(prevClose + 2 hours);
        _expectNoCommit(alice);
        _warp(afterHoursEnd - 3);
        _expectNoCommit(alice);

        // 04:00: the stock opened 6% down on the news; the book was closed all evening and sees the
        // after-hours' and the gap's variance (20%) at once
        _warp(preMarketStart - 3);
        _expectNoCommit(alice);
        _buyAt(preMarketStart, alice, LOWER, 5_000e18, S0 * 94 / 100);
        assertEq(_state().g, uint256(0.8e18).sqrtWad());
        _buyAt(regularStart + 1 hours, bob, HIGHER, 5_000e18, S0 * 95 / 100);
        _closeAndFinalize(_grid(S0 * 95 / 100));
        // (on the three strikes: every LOWER token)
        assertEq(_state().winners, uint16(1 << F0 | 1 << LOWER), "down 5%: the floor below -2 sigma, LOWER");
    }

    /// @dev And the other way round: a flag set after the round opened does not stop its after-hours.
    function test_skipAfterHours_setAfterTheOpen_doesNotReachTheRound() public {
        roundId = hook.openRound(NVDA, address(chip), day);
        vm.prank(owner);
        book.setSkipAfterHours(NVDA, day, true);
        assertFalse(hook.getConfig(roundId).clock.skipAfterHours);
        _buyAt(prevClose + 10 minutes, alice, HIGHER, 1_000e18, S0);
        _buyAt(afterHoursEnd - 1, alice, HIGHER, 1_000e18, S0);
    }

    // --------------------------------------------------------------------------------------------
    // the windows mask: a stock whose nights are switched on
    // --------------------------------------------------------------------------------------------

    /// @dev A stock registered with windows 15 (after-hours, overnight, pre-market, regular) and priced by
    ///      Pyth trades from the previous close to the cutoff without a break, while a stock on the default
    ///      mask stops at 20:00. The clock is the same for both: rho runs through the night either way.
    function test_stockRound_withTheNightsSwitchedOn_tradesOvernight() public {
        bytes32 qqq = bytes32("QQQ");
        uint256 price = 600e18;
        vm.startPrank(owner);
        _addTickerWith(
            qqq,
            0x9695e2b96ea7b3859da9ed25b7a46a920a776e2fdae19a7bcfdf2b219230452d,
            IPitBook.Clock.NYWeekdays,
            15,
            IPitBook.FillSource.TrustlessOnly
        );
        vm.stopPrank();
        book.recordClose(qqq, day0, _pythPrint(qqq, price, prevClose));
        bytes32 nvdaRound = hook.openRound(NVDA, address(chip), day);
        assertEq(hook.getConfig(nvdaRound).clock.windows, 13, "NVDA: the default, no nights");
        _use(qqq, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        roundId = hook.openRound(qqq, address(chip), day);
        assertEq(hook.getConfig(roundId).clock.windows, 15, "QQQ: all four windows");

        _buyAt(prevClose + 1 hours, alice, HIGHER, 2_000e18, price);
        // no edge at 20:00:00: the commit made at 19:59:58 is priced there and fills
        _buyAt(afterHoursEnd, bob, LOWER, 1_000e18, price * 1001 / 1000);
        assertEq(_state().g, uint256(0.94e18).sqrtWad());
        // at the same second the round on the default mask takes no commit
        _use(NVDA, address(chip));
        assertEq(roundId, nvdaRound);
        _expectNoCommit(alice);
        (, bool nvdaTrades) = lens.clockAt(nvdaRound, clock + 2);
        assertFalse(nvdaTrades);
        _use(qqq, address(chip));

        // midnight: half of the gap's 14% has run off, and the book follows it fill by fill
        _buyAt(afterHoursEnd + 4 hours, carol, F6, 1_500e18, price * 1002 / 1000);
        assertEq(_state().g, uint256(0.87e18).sqrtWad());
        uint256 before = chip.balanceOf(alice);
        _warp(afterHoursEnd + 6 hours);
        uint256 proceeds = _sell(alice, HIGHER, 500e18, price * 1003 / 1000);
        assertGt(proceeds, 0);
        assertEq(chip.balanceOf(alice), before + proceeds);
        // into the pre-market without an edge: 03:59:50, then 04:00:00
        _buyAt(preMarketStart - 10, bob, LOWER, 500e18, price * 1003 / 1000);
        _buyAt(preMarketStart, bob, LOWER, 500e18, price * 1003 / 1000);
        assertEq(_state().g, uint256(0.8e18).sqrtWad(), "the same 80% at 04:00 as on the default mask");
        _buyAt(regularStart + 1 hours, carol, F6, 1_000e18, price * 1004 / 1000);
        _buyAt(cutoff, alice, HIGHER, 500e18, price * 1004 / 1000);
        _expectNoCommit(alice);
        _assertSupplies();
        _assertHookSolvent(address(chip));
        _closeAndFinalize(_grid(price * 1005 / 1000));
        // (on the three strikes: HIGHER@15, HIGHER@19, LOWER@23)
        assertEq(_state().winners, uint16(1 << F4 | 1 << HIGHER), "up 0.5%: the floor from 0 to +0.5, HIGHER");
    }

    // --------------------------------------------------------------------------------------------
    // a stock round over a weekend
    // --------------------------------------------------------------------------------------------

    function test_stockRound_fridayAfterHours_thenMonday() public {
        // the week passes without rounds; Friday's close is recorded
        uint32 friday = day0 + 4;
        for (day = day0 + 1; day <= friday; ++day) {
            _recordClose(S0, PYTH_SOURCE);
        }
        uint32 monday = friday + 3;
        day = monday;
        _setTimes(friday, monday);
        assertEq(preMarketStart - afterHoursEnd, 56 hours);

        // Saturday's and Sunday's "rounds" do not exist for a stock
        vm.expectRevert(IPitBook.NotTradingDay.selector);
        hook.openRound(NVDA, address(chip), friday + 1);
        // Monday's round opens on Friday evening
        roundId = hook.openRound(NVDA, address(chip), monday);
        assertEq(hook.getConfig(roundId).clock.prevDay, friday);
        _buyAt(prevClose + 1 hours, alice, HIGHER, 5_000e18, S0 * 1001 / 1000);
        _buyAt(afterHoursEnd - 1, bob, LOWER, 5_000e18, S0 * 1001 / 1000);

        // nothing on Saturday or Sunday, whatever the hour
        uint64[5] memory weekend = [
            afterHoursEnd,
            NYTime.at(friday + 1, 10 hours),
            NYTime.at(friday + 1, 17 hours),
            NYTime.at(friday + 2, 12 hours),
            preMarketStart - 3
        ];
        for (uint256 i; i < weekend.length; ++i) {
            _warp(weekend[i]);
            _expectNoCommit(alice);
        }

        // Monday: the weekend's news is in the price, and its variance (the gap's 14%) is off the clock
        _buyAt(preMarketStart, carol, F6, 4_000e18, S0 * 1012 / 1000);
        assertEq(_state().g, uint256(0.8e18).sqrtWad());
        _buyAt(regularStart + 2 hours, alice, HIGHER, 3_000e18, S0 * 1011 / 1000);
        _closeAndFinalize(_grid(S0 * 1015 / 1000));
        // up 1.5%: the floor from +0.5 to +1 sigma, and HIGHER
        assertEq(_state().winners, uint16(1 << F5 | 1 << HIGHER));
        // one trading day's return went into the variance: Friday to Monday is one step
        assertTrue(book.getTicker(NVDA).lastCloseStepped);
        _assertHookSolvent(address(chip));
    }

    // --------------------------------------------------------------------------------------------
    // an every-day asset: daily rounds through a weekend, each opened as the one before it ends
    // --------------------------------------------------------------------------------------------

    function test_everyDay_consecutiveDailyRoundsThroughAWeekend() public {
        vm.startPrank(owner);
        _addTickerOn(ETH, ETH_ID, IPitBook.Clock.EveryDay, IPitBook.FillSource.TrustlessOnly);
        vm.stopPrank();
        _use(ETH, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        uint256 minted = 3 * STAKE + 2 * HOUSE_CAPITAL + 100_000e18;

        // closes of Monday to Thursday, one a day; the variance steps from Tuesday on
        ethPrice = 4_000e18;
        for (day = day0; day <= day0 + 3; ++day) {
            _recordClose(ethPrice, PYTH_SOURCE);
        }
        ethVariance = book.getTicker(ETH).varWad;
        assertEq(ethVariance, SEED_VAR * 94 / 100 * 94 / 100 * 94 / 100, "three flat days");

        // four rounds: Friday, Saturday, Sunday, Monday. Each opens seconds after the one before closed.
        uint256[4] memory closes =
            [uint256(4_060e18), uint256(3_990e18), uint256(4_105e18), uint256(4_105e18)];
        uint256 queuedShares = vault.balanceOf(lp, uint256(house)) / 5;
        for (uint256 n; n < 4; ++n) {
            day = day0 + 4 + uint32(n);
            _setTimes(day - 1, day);
            assertEq(clock, prevClose + 5, "five seconds after the previous close");
            PitVault.House memory h = vault.getHouse(house);
            roundId = hook.openRound(ETH, address(chip), day);
            if (n == 2) {
                // Sunday's round pulled the capital: the queues ran first, at the price after Saturday's result
                uint256 assetsOut = queuedShares.fullMulDiv(h.lpAssets + 1, h.totalShares + 1e6);
                uint256 mintedShares = uint256(100_000e18).fullMulDiv(h.totalShares + 1e6, h.lpAssets + 1);
                assertEq(
                    hook.getConfig(roundId).capital,
                    h.lpAssets + h.endowment - assetsOut + 100_000e18,
                    "what the house is worth after the queues"
                );
                (uint256 shares2,,,) = vault.positionOf(house, lp2);
                assertEq(shares2, mintedShares, "lp2 was minted at the roll");
                vm.prank(lp);
                assertEq(vault.claim(house), assetsOut, "and lp's withdrawal was paid at the roll");
            }
            _tradeAnEveryDayRound(n);
            if (n == 1) {
                // Saturday: LP moves made during the round wait in the queue until the roll
                assertEq(
                    _lpDeposit(lp2, house, 100_000e18), 0, "a deposit into a locked house mints nothing yet"
                );
                vm.prank(lp);
                assertEq(vault.requestWithdraw(house, queuedShares), 0, "and a withdrawal pays nothing yet");
            }
            _closeAnEveryDayRound(closes[n]);
        }

        // Tuesday's round opens too: the house went from round to round for five days without a break
        day += 1;
        hook.openRound(ETH, address(chip), day);
        assertTrue(vault.isLocked(house));
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, owed);
        assertEq(chip.balanceOf(address(hook)), claims);
        assertEq(chip.balanceOf(address(router)), 0);
        assertEq(
            _sumOf([alice, bob, carol, lp, lp2]) + chip.balanceOf(feeRecipient)
                + chip.balanceOf(address(vault)) + chip.balanceOf(address(hook)),
            minted,
            "cash conservation over the four rounds"
        );
        _assertVaultBacked(address(chip));
    }

    uint256 internal ethPrice;
    uint256 internal ethVariance;

    /// @dev One every-day round, traded around the clock: the evening, the middle of the night, the early
    ///      morning, midday, and the cutoff.
    function _tradeAnEveryDayRound(uint256 n) internal {
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(uint8(c.clock.kind), uint8(IPitBook.Clock.EveryDay));
        assertEq(c.clock.prevDay, day - 1);
        assertEq(c.s0, ethPrice, "the round starts from the close of the day before");
        assertEq(c.sigma, ethVariance.sqrtWad());
        assertEq(c.closeTs - prevClose, 24 hours);
        assertEq(c.openTs, prevClose + 5);

        _buyAt(prevClose + 2 hours, alice, HIGHER, 4_000e18, ethPrice * 1002 / 1000);
        (uint256 rho,) = lens.clockAt(roundId, clock);
        assertEq(rho, uint256(22 hours) * 1e18 / 24 hours, "one straight line from close to close");
        // 20:00 to 04:00 New York, the hours a stock does not trade
        _buyAt(prevClose + 4 hours, bob, LOWER, 1_000e18, ethPrice * 1001 / 1000);
        _buyAt(prevClose + 8 hours, bob, LOWER, 3_000e18, ethPrice * 997 / 1000);
        _buyAt(prevClose + 12 hours, carol, n % 2 == 0 ? F6 : F1, 2_000e18, ethPrice * 1004 / 1000);
        assertEq(_state().g, uint256(0.5e18).sqrtWad());
        _warp(prevClose + 20 hours);
        assertGt(_sell(alice, HIGHER, 1_500e18, ethPrice * 1001 / 1000), 0);
        // the cutoff is 15:49:30 on every day of the week
        _buyAt(cutoff, bob, LOWER, 1_000e18, ethPrice);
        _expectNoCommit(alice);
        _assertSupplies();
        _assertHookSolvent(address(chip));
    }

    /// @dev The close of an every-day round is a Pyth update: final at once, the house is free in the same
    ///      block, and the variance stepped on this calendar day (a Saturday or a Sunday too).
    function _closeAnEveryDayRound(uint256 close) internal {
        uint256 previous = ethPrice;
        ethPrice = close;
        _closeAndFinalize(close);
        assertEq(clock, NYTime.closeTs(day) + 5);
        assertFalse(vault.isLocked(house));
        int256 ret = FixedPointMathLib.lnWad(int256(close.divWad(previous)));
        ethVariance = (94 * ethVariance + 6 * (uint256(ret * ret) / 1e18)) / 100;
        IPitBook.Ticker memory tk = book.getTicker(ETH);
        assertEq(tk.varWad, ethVariance);
        assertTrue(tk.lastCloseStepped);
        assertEq(tk.lastCloseDay, day);
    }
}
