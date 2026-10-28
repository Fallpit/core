// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {StackFixture} from "./StackFixture.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice A skip needs 24 hours' notice (`setSkip` refuses a day whose close is closer), and a round prices
///         every trading day it spans: sigma is the daily sigma times `sqrt(1 + k)`, k the skipped (or
///         missed) weekdays inside it, and the close at the end steps the EWMA with the squared return
///         divided by `1 + k`. Real FallpitHook, FallpitRouter, PitBook, LadderMath and PitVault; the oracle
///         and the chip guard are stand-ins.
contract SkipNoticeTest is StackFixture {
    address internal lp = makeAddr("lp");
    address internal eve = makeAddr("eve");
    uint256 internal constant CAPITAL = 1_000_000e18;
    uint256 internal constant LOT = 20_000e18; // the per-fill cap at 2% of the capital

    /// @dev The owner marks `days` skipped `ahead` before now (the book needs the notice) and the clock
    ///      comes back.
    function _skipAhead(uint32 first, uint32 last, uint64 ahead) internal {
        vm.warp(clock - ahead);
        vm.startPrank(owner);
        for (uint32 d = first; d <= last; ++d) {
            book.setSkip(NVDA, d, true);
        }
        vm.stopPrank();
        vm.warp(clock);
    }

    function test_skip_noSkipWithoutNotice_andTheFourDayRoundIsPricedOnFourDays() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, 1_000_000e18);
        uint32 friday = day0 + 4;
        uint64 mondayEvening = NYTime.closeTs(day0) + 60;
        _warp(mondayEvening);

        // At Monday 16:01 Tuesday's close is 23h59 away, too close to skip.
        vm.prank(owner);
        vm.expectRevert(IPitBook.SkipTooLate.selector);
        book.setSkip(NVDA, day0 + 1, true);
        // and without the skip Friday's round cannot open on Monday's close
        vm.expectRevert(IPitBook.NotNextTradingDay.selector);
        hook.openRound(NVDA, address(chip), friday);

        // The honest case: Tuesday to Thursday were skipped with notice (on the Saturday before). Friday's
        // round opens on Monday's close and spans four trading days.
        _skipAhead(day0 + 1, day0 + 3, 2 days);
        day = friday;
        roundId = hook.openRound(NVDA, address(chip), friday);
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(c.clock.prevDay, day0, "starts from Monday's close");
        assertEq(c.sigma, 0.04e18, "sigma of four days: 2% * sqrt(4)");
        // the weights: one day's after-hours, pre-market and regular session each; the gap holds the rest
        assertEq(c.clock.afterHours, 150);
        assertEq(c.clock.preMarket, 250);
        assertEq(c.clock.regular, 1750);
        assertEq(c.clock.gap, 7850);
        // at Friday's pre-market the variance ahead is one day's pre-market and session: 0.8 of a day
        (uint256 rho,) = book.clockAt(c.clock, NYTime.at(friday, 4 hours));
        assertEq(rho, 0.2e18, "rho 0.2 of four days = 0.8 of one day");

        // Eve buys both tail floors in Monday's after-hours. The floors are cut in
        // standard deviations of the round: F7 now pays above +2 four-day sigmas (+8%), not above +4%.
        _warp(mondayEvening + 60);
        uint256 paid;
        for (uint256 i; i < 5; ++i) {
            paid += _buy(eve, F7, LOT, S0);
            paid += _buy(eve, F0, LOT, S0);
        }
        assertApproxEqRel(_token(F7).low(), S0 * 10_833 / 10_000, 0.001e18, "F7 starts at +8%: exp(0.08)");
        // Fair value over four days: each tail is beyond two sd of the round, P = 2.275%: 4,550 chips for
        // 100,000 of each. Eve pays a price that covers it, fees and the minimum price on top.
        uint256 fairBoth = 4_550e18;
        console.log("eve paid %s chips for 100,000 F7 and 100,000 F0 (fair four-day value 4550)", paid / 1e18);
        assertGt(paid, fairBoth, "no edge left");

        // Friday +5%: a 1.25 sd move of the real horizon, inside F6 (+1 to +2 sd), not a tail. Eve's
        // tails lose.
        uint256 close = S0 * uint256(FixedPointMathLib.expWad(0.05e18)) / 1e18;
        _closeAndFinalize(close);
        assertEq(_state().winners >> F7 & 1, 0, "F7 lost");
        assertEq(_state().winners >> F6 & 1, 1, "F6 won");
        int256 ret = FixedPointMathLib.lnWad(int256(close * 1e18 / S0));
        uint256 perDay = uint256(ret * ret) / 1e18 / 4;
        uint256 expected = (94 * SEED_VAR + 6 * perDay) / 100;
        IPitBook.Ticker memory tk = book.getTicker(NVDA);
        assertApproxEqAbs(tk.varWad, expected, 1e9, "the EWMA steps on the return per trading day");
        console.log("variance after the four-day close (WAD)", tk.varWad, "seed", SEED_VAR);
    }

    /// @dev The same price range costs several times more in a four-day round than in a one-day round.
    function test_skip_oneDayAndFourDayRoundsQuoteDifferently() public {
        _lpDeposit(lp, CAPITAL);
        uint64 mondayEvening = NYTime.closeTs(day0) + 60;
        _warp(mondayEvening);
        uint256 snap = vm.snapshotState();
        bytes32 oneDay = hook.openRound(NVDA, address(chip), day0 + 1);
        (uint256 chipsOneDay,,,,,) = lens.quote(oneDay, F7, true, LOT, S0, mondayEvening + 60);
        vm.revertToState(snap);

        // The same house, the same evening, with Tuesday to Thursday skipped a week ahead.
        _skipAhead(day0 + 1, day0 + 3, 7 days);
        bytes32 fourDay = hook.openRound(NVDA, address(chip), day0 + 4);
        // "above +4%" is F7 of the one-day round (+2 of its sd) and F6 plus F7 of the four-day round
        // (+1 of its sd and up)
        (uint256 f6,,,,,) = lens.quote(fourDay, F6, true, LOT, S0, mondayEvening + 60);
        (uint256 f7,,,,,) = lens.quote(fourDay, F7, true, LOT, S0, mondayEvening + 60);
        uint256 chipsFourDay = f6 + f7;
        console.log(
            "20,000 of 'above +4%%': one-day round %s, four-day round %s",
            chipsOneDay / 1e18,
            chipsFourDay / 1e18
        );
        assertGt(chipsFourDay, 3 * chipsOneDay, "four days of variance, priced as four days");
    }

    /// @dev A skip comes with 24 hours' notice in both directions; the after-hours skip stays immediate
    ///      (it only removes trading).
    function test_setSkip_needs24hNotice_skipAfterHoursDoesNot() public {
        uint32 wednesday = day0 + 2;
        // Monday 16:01: Wednesday's close is 47h59 away
        vm.startPrank(owner);
        book.setSkip(NVDA, wednesday, true);
        assertTrue(book.skip(NVDA, wednesday));
        vm.warp(NYTime.closeTs(wednesday) - 24 hours);
        book.setSkip(NVDA, wednesday, false);
        vm.warp(NYTime.closeTs(wednesday) - 24 hours + 1);
        vm.expectRevert(IPitBook.SkipTooLate.selector);
        book.setSkip(NVDA, wednesday, true);
        book.setSkipAfterHours(NVDA, wednesday, true);
        assertTrue(book.skipAfterHours(NVDA, wednesday));
        vm.stopPrank();
    }
}
