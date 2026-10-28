// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PitBook} from "../../src/hook/PitBook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {PitClock} from "../../src/hook/PitClock.sol";
import {PitMath} from "../../src/hook/PitMath.sol";
import {IPitOracle} from "../../src/interfaces/IPitOracle.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice The clock of a round (SPEC 7.2), for both kinds: which seconds trade and how much of the
///         round's variance is still ahead, on ordinary days, over a weekend, over a skipped day, across
///         both daylight-saving switches, with the after-hours skipped, and to the second at every edge.
contract PitClockTest is Test {
    uint256 internal constant WAD = 1e18;

    PitBook internal book;

    /// @dev Monday 2026-10-05 and Tuesday 2026-10-06, both in daylight-saving time.
    uint32 internal monday = uint32(NYTime.daysFromCivil(2026, 10, 5));
    uint32 internal tuesday = uint32(NYTime.daysFromCivil(2026, 10, 6));

    function setUp() public {
        book = new PitBook(IPitOracle(address(1)), address(this), 24 hours);
    }

    function _stock(uint32 prevDay, uint32 day) internal pure returns (IPitBook.RoundClock memory) {
        return IPitBook.RoundClock({
            kind: IPitBook.Clock.NYWeekdays,
            skipAfterHours: false,
            windows: PitClock.DEFAULT_WINDOWS,
            prevDay: prevDay,
            day: day,
            afterHours: 600,
            gap: 1400,
            preMarket: 1000,
            regular: 7000
        });
    }

    function _everyDay(uint32 day) internal pure returns (IPitBook.RoundClock memory) {
        return IPitBook.RoundClock({
            kind: IPitBook.Clock.EveryDay,
            skipAfterHours: false,
            windows: PitClock.ALL_WINDOWS,
            prevDay: day - 1,
            day: day,
            afterHours: 0,
            gap: 0,
            preMarket: 0,
            regular: 10_000
        });
    }

    function _rho(IPitBook.RoundClock memory c, uint64 ts) internal pure returns (uint256 rho) {
        (rho,) = PitClock.at(c, ts);
    }

    function _trades(IPitBook.RoundClock memory c, uint64 ts) internal pure returns (bool tradable) {
        (, tradable) = PitClock.at(c, ts);
    }

    // --------------------------------------------------------------------------------------------
    // a stock round: Monday's close to Tuesday's close
    // --------------------------------------------------------------------------------------------

    function test_stock_instants() public view {
        PitClock.Times memory t = PitClock.times(_stock(monday, tuesday));
        // New York is four hours behind UTC in October
        assertEq(t.prevClose, uint64(monday) * 1 days + 20 hours, "Monday 16:00:00");
        assertEq(t.afterHoursEnd, uint64(monday) * 1 days + 24 hours, "Monday 20:00:00");
        assertEq(t.preMarketStart, uint64(tuesday) * 1 days + 8 hours, "Tuesday 04:00:00");
        assertEq(t.regularStart, uint64(tuesday) * 1 days + 13 hours + 30 minutes, "Tuesday 09:30:00");
        assertEq(t.cutoff, uint64(tuesday) * 1 days + 20 hours - 630, "Tuesday 15:49:30");
        assertEq(t.close, uint64(tuesday) * 1 days + 20 hours, "Tuesday 16:00:00");
    }

    function test_stock_windows_toTheSecond() public view {
        IPitBook.RoundClock memory c = _stock(monday, tuesday);
        PitClock.Times memory t = PitClock.times(c);

        // before the previous close there is no round
        assertFalse(_trades(c, t.prevClose - 1));
        // after-hours: [16:00:00, 20:00:00)
        assertTrue(_trades(c, t.prevClose));
        assertTrue(_trades(c, t.prevClose + 1));
        assertTrue(_trades(c, t.afterHoursEnd - 1), "19:59:59 trades");
        assertFalse(_trades(c, t.afterHoursEnd), "20:00:00 does not");
        // the night
        assertFalse(_trades(c, t.afterHoursEnd + 1));
        assertFalse(_trades(c, t.afterHoursEnd + 4 hours), "midnight");
        assertFalse(_trades(c, t.preMarketStart - 1), "03:59:59 does not trade");
        // pre-market and regular session, without a break: [04:00:00, 15:49:30]
        assertTrue(_trades(c, t.preMarketStart), "04:00:00 trades");
        assertTrue(_trades(c, t.regularStart - 1), "09:29:59");
        assertTrue(_trades(c, t.regularStart), "09:30:00");
        assertTrue(_trades(c, t.cutoff), "15:49:30 trades");
        assertFalse(_trades(c, t.cutoff + 1), "15:49:31 does not");
        assertFalse(_trades(c, t.close - 1));
        assertFalse(_trades(c, t.close));
        assertFalse(_trades(c, t.close + 1));
    }

    function test_stock_rho_atEveryEdgeAndMidpoint() public view {
        IPitBook.RoundClock memory c = _stock(monday, tuesday);
        PitClock.Times memory t = PitClock.times(c);

        assertEq(_rho(c, t.prevClose - 1), WAD, "the whole variance before the round starts");
        assertEq(_rho(c, t.prevClose), WAD, "1 at the previous close");
        // after-hours: 6% over four hours
        assertEq(_rho(c, t.prevClose + 2 hours), 0.97e18);
        assertEq(_rho(c, t.afterHoursEnd - 1), 0.94e18 + uint256(0.06e18) / 14_400);
        assertEq(_rho(c, t.afterHoursEnd), 0.94e18, "94% left at 20:00");
        // the gap: 14% over the eight hours of the night
        assertEq(_rho(c, t.afterHoursEnd + 4 hours), 0.87e18);
        assertEq(_rho(c, t.preMarketStart - 1), 0.8e18 + uint256(0.14e18) / 28_800);
        assertEq(
            _rho(c, t.preMarketStart), 0.8e18, "80% left at 04:00: the first pre-market fill sees the jump"
        );
        // pre-market: 10% over five and a half hours
        assertEq(_rho(c, t.preMarketStart + 2 hours + 45 minutes), 0.75e18);
        assertEq(_rho(c, t.regularStart), 0.7e18, "70% left at the opening bell");
        // regular session: 70% over six and a half hours
        assertEq(_rho(c, t.regularStart + 3 hours + 15 minutes), 0.35e18);
        assertEq(_rho(c, t.cutoff), uint256(0.7e18) * 630 / 23_400, "about 1.9% left at the cutoff");
        assertEq(_rho(c, t.close - 1), uint256(0.7e18) / 23_400);
        assertEq(_rho(c, t.close), 0, "0 at the close");
        assertEq(_rho(c, t.close + 1 days), 0);
    }

    function test_stock_skipAfterHours_onlyTheAfterHoursStop() public view {
        IPitBook.RoundClock memory c = _stock(monday, tuesday);
        IPitBook.RoundClock memory skipped = _stock(monday, tuesday);
        skipped.skipAfterHours = true;
        PitClock.Times memory t = PitClock.times(c);

        for (uint64 ts = t.prevClose; ts < t.afterHoursEnd; ts += 300) {
            assertTrue(_trades(c, ts));
            assertFalse(_trades(skipped, ts), "no second of the after-hours trades");
        }
        assertFalse(_trades(skipped, t.afterHoursEnd - 1));
        assertFalse(_trades(skipped, t.preMarketStart - 1));
        assertTrue(_trades(skipped, t.preMarketStart), "the pre-market trades as always");
        assertTrue(_trades(skipped, t.cutoff));
        assertFalse(_trades(skipped, t.cutoff + 1));
        // the clock itself is the same: the variance of the skipped window still runs off
        for (uint64 ts = t.prevClose - 600; ts <= t.close + 600; ts += 97) {
            assertEq(_rho(skipped, ts), _rho(c, ts));
        }
    }

    // --------------------------------------------------------------------------------------------
    // a stock round over a weekend and over a skipped day
    // --------------------------------------------------------------------------------------------

    function test_stock_fridayToMonday() public view {
        uint32 friday = monday - 3;
        IPitBook.RoundClock memory c = _stock(friday, monday);
        PitClock.Times memory t = PitClock.times(c);
        assertEq(t.afterHoursEnd - t.prevClose, 4 hours, "Friday's after-hours");
        assertEq(t.preMarketStart - t.afterHoursEnd, 56 hours, "Friday 20:00 to Monday 04:00");
        assertEq(t.close - t.prevClose, 72 hours);

        assertTrue(_trades(c, t.prevClose + 1 hours), "Friday 17:00");
        assertTrue(_trades(c, t.afterHoursEnd - 1), "Friday 19:59:59");
        // nothing on Saturday or Sunday, at any hour (also not in what would be their trading hours)
        for (uint64 ts = t.afterHoursEnd; ts < t.preMarketStart; ts += 900) {
            assertFalse(_trades(c, ts), "the weekend does not trade");
        }
        assertFalse(_trades(c, NYTime.at(friday + 1, 10 hours)), "Saturday 10:00");
        assertFalse(_trades(c, NYTime.at(friday + 2, 17 hours)), "Sunday 17:00");
        assertFalse(_trades(c, t.preMarketStart - 1), "Monday 03:59:59");
        assertTrue(_trades(c, t.preMarketStart), "Monday 04:00:00");
        assertTrue(_trades(c, t.regularStart + 1 hours));

        // the gap's 14% runs off evenly over the 56 hours
        assertEq(_rho(c, t.afterHoursEnd), 0.94e18);
        assertEq(_rho(c, t.afterHoursEnd + 28 hours), 0.87e18, "Saturday midnight plus four hours");
        assertEq(_rho(c, t.preMarketStart), 0.8e18);
        assertEq(_rho(c, t.regularStart), 0.7e18);
    }

    function test_stock_skippedDayInBetween() public pure {
        // Wednesday 2026-11-25 to Friday 2026-11-27: Thursday is Thanksgiving, skipped
        uint32 wednesday = uint32(NYTime.daysFromCivil(2026, 11, 25));
        uint32 friday = wednesday + 2;
        IPitBook.RoundClock memory c = _stock(wednesday, friday);
        PitClock.Times memory t = PitClock.times(c);
        assertEq(t.preMarketStart - t.afterHoursEnd, 32 hours, "Wednesday 20:00 to Friday 04:00");

        assertTrue(_trades(c, t.prevClose + 30 minutes), "Wednesday's after-hours");
        // Thursday does not trade at all: not in its pre-market, not in its session, not in its after-hours
        assertFalse(_trades(c, NYTime.at(wednesday + 1, 4 hours)));
        assertFalse(_trades(c, NYTime.at(wednesday + 1, 9 hours + 30 minutes)));
        assertFalse(_trades(c, NYTime.at(wednesday + 1, 12 hours)));
        assertFalse(_trades(c, NYTime.at(wednesday + 1, 17 hours)));
        assertTrue(_trades(c, NYTime.at(friday, 4 hours)));
        assertTrue(_trades(c, NYTime.at(friday, 12 hours)));
        assertEq(
            _rho(c, NYTime.at(wednesday + 1, 12 hours)), 0.94e18 - uint256(0.14e18) / 2, "half of the gap"
        );
    }

    // --------------------------------------------------------------------------------------------
    // the windows mask: which segments of a stock round trade
    // --------------------------------------------------------------------------------------------

    function _withWindows(IPitBook.RoundClock memory c, uint8 windows)
        internal
        pure
        returns (IPitBook.RoundClock memory)
    {
        c.windows = windows;
        return c;
    }

    /// @dev Nights switched on (windows 15), Monday's close to Tuesday's: the round trades without a
    ///      break from the previous close to the cutoff, and rho is the very same clock.
    function test_stock_overnight_mondayToTuesday_tradesWithoutABreak() public view {
        IPitBook.RoundClock memory c = _stock(monday, tuesday);
        IPitBook.RoundClock memory nights = _withWindows(_stock(monday, tuesday), PitClock.ALL_WINDOWS);
        PitClock.Times memory t = PitClock.times(c);

        assertTrue(_trades(nights, t.afterHoursEnd - 1), "19:59:59");
        assertTrue(_trades(nights, t.afterHoursEnd), "20:00:00 trades now");
        assertTrue(_trades(nights, t.afterHoursEnd + 4 hours), "midnight");
        assertTrue(_trades(nights, t.preMarketStart - 1), "03:59:59");
        assertTrue(_trades(nights, t.preMarketStart));
        for (uint64 ts = t.prevClose; ts <= t.cutoff; ts += 600) {
            assertTrue(_trades(nights, ts), "every ten minutes from the previous close to the cutoff");
        }
        assertFalse(_trades(nights, t.prevClose - 1));
        assertFalse(_trades(nights, t.cutoff + 1));
        // rho runs on through the night along the gap's line, as it did when nothing traded there
        for (uint64 ts = t.prevClose - 600; ts <= t.close + 600; ts += 97) {
            assertEq(_rho(nights, ts), _rho(c, ts));
        }
        assertEq(_rho(nights, t.afterHoursEnd), 0.94e18);
        assertEq(_rho(nights, t.afterHoursEnd + 2 hours), 0.94e18 - uint256(0.14e18) / 4);
        assertEq(_rho(nights, t.afterHoursEnd + 4 hours), 0.87e18);
        assertEq(_rho(nights, t.preMarketStart), 0.8e18);
        // the default mask has no night
        assertFalse(_trades(c, t.afterHoursEnd));
        assertFalse(_trades(c, t.afterHoursEnd + 4 hours));
    }

    /// @dev Nights are weekday nights: Sunday evening to Friday morning. From Friday 20:00 to Sunday
    ///      20:00 a stock round never trades, mask or no mask.
    function test_stock_overnight_fridayToMonday_onlySundayNight() public view {
        uint32 friday = monday - 3;
        IPitBook.RoundClock memory c = _withWindows(_stock(friday, monday), PitClock.ALL_WINDOWS);
        PitClock.Times memory t = PitClock.times(c);
        uint64 sundayEvening = NYTime.at(friday + 2, 20 hours);

        assertTrue(_trades(c, t.afterHoursEnd - 1), "Friday 19:59:59: the after-hours");
        assertFalse(_trades(c, t.afterHoursEnd), "Friday 20:00:00: the weekend has begun");
        for (uint64 ts = t.afterHoursEnd; ts < sundayEvening; ts += 900) {
            assertFalse(_trades(c, ts), "nothing from Friday 20:00 to Sunday 20:00");
        }
        assertFalse(_trades(c, NYTime.at(friday + 1, 2 hours)), "Saturday 02:00 (Friday's night)");
        assertFalse(_trades(c, NYTime.at(friday + 1, 22 hours)), "Saturday 22:00");
        assertFalse(_trades(c, NYTime.at(friday + 2, 3 hours)), "Sunday 03:00 (Saturday's night)");
        assertFalse(_trades(c, sundayEvening - 1), "Sunday 19:59:59");
        assertTrue(_trades(c, sundayEvening), "Sunday 20:00:00: the night into Monday trades");
        for (uint64 ts = sundayEvening; ts <= t.cutoff; ts += 900) {
            assertTrue(_trades(c, ts), "from Sunday 20:00 to Monday's cutoff without a break");
        }
        // the gap's 14% still runs off evenly over its 56 hours; 48 of them are gone on Sunday at 20:00
        assertEq(_rho(c, sundayEvening), 0.8e18 + uint256(0.14e18) * 8 / 56);
        assertEq(_rho(c, t.preMarketStart), 0.8e18);
    }

    /// @dev A skipped day in between (Wednesday to Friday over Thanksgiving): both nights trade, the
    ///      skipped Thursday's daytime does not.
    function test_stock_overnight_skippedDay_itsDaytimeDoesNotTrade() public pure {
        uint32 wednesday = uint32(NYTime.daysFromCivil(2026, 11, 25));
        uint32 friday = wednesday + 2;
        IPitBook.RoundClock memory c = _withWindows(_stock(wednesday, friday), PitClock.ALL_WINDOWS);

        assertTrue(_trades(c, NYTime.at(wednesday, 20 hours)), "Wednesday 20:00");
        assertTrue(_trades(c, NYTime.at(wednesday + 1, 4 hours) - 1), "Thursday 03:59:59");
        assertFalse(
            _trades(c, NYTime.at(wednesday + 1, 4 hours)), "Thursday 04:00:00: a skipped day's pre-market"
        );
        assertFalse(_trades(c, NYTime.at(wednesday + 1, 12 hours)), "its session");
        assertFalse(_trades(c, NYTime.at(wednesday + 1, 17 hours)), "its after-hours");
        assertFalse(_trades(c, NYTime.at(wednesday + 1, 20 hours) - 1), "Thursday 19:59:59");
        assertTrue(_trades(c, NYTime.at(wednesday + 1, 20 hours)), "Thursday 20:00:00: the night into Friday");
        assertTrue(_trades(c, NYTime.at(friday, 4 hours) - 1));
        assertTrue(_trades(c, NYTime.at(friday, 4 hours)));
    }

    function test_stock_overnight_acrossTheSpringSwitch() public pure {
        // Friday 2026-03-06 (standard time) to Monday 2026-03-09: Sunday 20:00 is daylight-saving time
        uint32 friday = uint32(NYTime.daysFromCivil(2026, 3, 6));
        IPitBook.RoundClock memory c = _withWindows(_stock(friday, friday + 3), PitClock.ALL_WINDOWS);
        uint64 sundayEvening = uint64(friday + 3) * 1 days; // Sunday 20:00 EDT is Monday 00:00 UTC
        assertEq(NYTime.at(friday + 2, 20 hours), sundayEvening);
        assertFalse(_trades(c, sundayEvening - 1));
        assertTrue(_trades(c, sundayEvening));
        assertTrue(_trades(c, sundayEvening + 8 hours - 1), "Monday 03:59:59 EDT");
        assertTrue(_trades(c, sundayEvening + 8 hours), "Monday 04:00:00 EDT");
    }

    /// @dev Each bit switches its own window and nothing else.
    function test_stock_windowsMask_bitByBit() public view {
        PitClock.Times memory t = PitClock.times(_stock(monday, tuesday));
        uint64[4] memory at = [
            t.prevClose + 1 hours,
            t.afterHoursEnd + 1 hours,
            t.preMarketStart + 1 hours,
            t.regularStart + 1 hours
        ];
        for (uint8 windows = 8; windows < 16; ++windows) {
            IPitBook.RoundClock memory c = _withWindows(_stock(monday, tuesday), windows);
            assertEq(_trades(c, at[0]), windows & PitClock.AFTER_HOURS != 0);
            assertEq(_trades(c, at[1]), windows & PitClock.OVERNIGHT != 0);
            assertEq(_trades(c, at[2]), windows & PitClock.PRE_MARKET != 0);
            assertTrue(_trades(c, at[3]), "the regular session is in every mask");
            assertTrue(_trades(c, t.cutoff));
            assertFalse(_trades(c, t.cutoff + 1));
        }
        // the after-hours flag of a day is on top of the mask, and leaves the night alone
        IPitBook.RoundClock memory flagged = _withWindows(_stock(monday, tuesday), PitClock.ALL_WINDOWS);
        flagged.skipAfterHours = true;
        assertFalse(_trades(flagged, at[0]));
        assertFalse(_trades(flagged, t.afterHoursEnd - 1));
        assertTrue(_trades(flagged, t.afterHoursEnd), "20:00:00");
        // an every-day round ignores the mask
        IPitBook.RoundClock memory every = _withWindows(_everyDay(tuesday), 8);
        assertTrue(_trades(every, NYTime.at(monday, 22 hours)));
    }

    // --------------------------------------------------------------------------------------------
    // daylight-saving switches (both on a Sunday at 02:00)
    // --------------------------------------------------------------------------------------------

    function test_stock_springForward_theGapIsAnHourShorter() public pure {
        // Friday 2026-03-06 (standard time) to Monday 2026-03-09 (daylight-saving time)
        uint32 friday = uint32(NYTime.daysFromCivil(2026, 3, 6));
        uint32 mon = friday + 3;
        IPitBook.RoundClock memory c = _stock(friday, mon);
        PitClock.Times memory t = PitClock.times(c);
        assertEq(t.prevClose, uint64(friday) * 1 days + 21 hours, "Friday 16:00 EST");
        assertEq(t.afterHoursEnd, uint64(friday) * 1 days + 25 hours, "Friday 20:00 EST");
        assertEq(t.preMarketStart, uint64(mon) * 1 days + 8 hours, "Monday 04:00 EDT");
        assertEq(t.regularStart, uint64(mon) * 1 days + 13 hours + 30 minutes, "Monday 09:30 EDT");
        assertEq(t.close, uint64(mon) * 1 days + 20 hours, "Monday 16:00 EDT");
        assertEq(t.preMarketStart - t.afterHoursEnd, 55 hours, "one hour short of 56");
        assertEq(t.close - t.prevClose, 71 hours);
        // the trading segments keep their length, and the edges their rho
        assertEq(_rho(c, t.afterHoursEnd), 0.94e18);
        assertEq(_rho(c, t.preMarketStart), 0.8e18);
        assertEq(_rho(c, t.regularStart), 0.7e18);
        assertTrue(_trades(c, t.afterHoursEnd - 1));
        assertFalse(_trades(c, t.afterHoursEnd));
        assertFalse(_trades(c, t.preMarketStart - 1));
        assertTrue(_trades(c, t.preMarketStart));
        assertTrue(_trades(c, t.cutoff));
        assertFalse(_trades(c, t.cutoff + 1));
    }

    function test_stock_fallBack_theGapIsAnHourLonger() public pure {
        // Friday 2026-10-30 (daylight-saving time) to Monday 2026-11-02 (standard time)
        uint32 friday = uint32(NYTime.daysFromCivil(2026, 10, 30));
        uint32 mon = friday + 3;
        IPitBook.RoundClock memory c = _stock(friday, mon);
        PitClock.Times memory t = PitClock.times(c);
        assertEq(t.prevClose, uint64(friday) * 1 days + 20 hours, "Friday 16:00 EDT");
        assertEq(t.preMarketStart, uint64(mon) * 1 days + 9 hours, "Monday 04:00 EST");
        assertEq(t.close, uint64(mon) * 1 days + 21 hours, "Monday 16:00 EST");
        assertEq(t.preMarketStart - t.afterHoursEnd, 57 hours, "one hour more than 56");
        assertEq(t.regularStart - t.preMarketStart, 5 hours + 30 minutes);
        assertEq(t.close - t.regularStart, 6 hours + 30 minutes);
        assertEq(_rho(c, t.preMarketStart), 0.8e18);
        assertFalse(_trades(c, t.preMarketStart - 1));
        assertTrue(_trades(c, t.preMarketStart));
    }

    // --------------------------------------------------------------------------------------------
    // an every-day round
    // --------------------------------------------------------------------------------------------

    function test_everyDay_tradesAroundTheClock_weekendsIncluded() public view {
        uint32 saturday = monday - 2;
        IPitBook.RoundClock memory c = _everyDay(saturday);
        PitClock.Times memory t = PitClock.times(c);
        assertEq(t.prevClose, NYTime.closeTs(saturday - 1), "Friday 16:00:00");
        assertEq(t.close, NYTime.closeTs(saturday), "Saturday 16:00:00");
        assertEq(t.close - t.prevClose, 24 hours);
        assertEq(t.cutoff, t.close - 630);

        assertFalse(_trades(c, t.prevClose - 1));
        // every quarter of an hour from the previous close to the cutoff: the evening, the night, the morning
        for (uint64 ts = t.prevClose; ts <= t.cutoff; ts += 900) {
            assertTrue(_trades(c, ts));
        }
        assertTrue(_trades(c, t.cutoff), "15:49:30 trades");
        assertFalse(_trades(c, t.cutoff + 1), "15:49:31 does not");
        assertFalse(_trades(c, t.close));

        // one straight line
        assertEq(_rho(c, t.prevClose), WAD);
        assertEq(_rho(c, t.prevClose + 6 hours), 0.75e18);
        assertEq(_rho(c, t.prevClose + 12 hours), 0.5e18);
        assertEq(_rho(c, t.cutoff), uint256(630) * WAD / 86_400);
        assertEq(_rho(c, t.close), 0);
        // the stock flag means nothing here
        c.skipAfterHours = true;
        assertTrue(_trades(c, t.prevClose + 1 hours));
    }

    function test_everyDay_daylightSavingSundays() public pure {
        // Sunday 2026-03-08: the clocks go forward, the round lasts 23 hours
        uint32 spring = uint32(NYTime.daysFromCivil(2026, 3, 8));
        IPitBook.RoundClock memory c = _everyDay(spring);
        PitClock.Times memory t = PitClock.times(c);
        assertEq(t.prevClose, uint64(spring - 1) * 1 days + 21 hours, "Saturday 16:00 EST");
        assertEq(t.close, uint64(spring) * 1 days + 20 hours, "Sunday 16:00 EDT");
        assertEq(t.close - t.prevClose, 23 hours);
        assertEq(_rho(c, t.prevClose + 11 hours + 30 minutes), 0.5e18);
        assertTrue(_trades(c, t.prevClose + 11 hours + 30 minutes));

        // Sunday 2026-11-01: the clocks go back, the round lasts 25 hours
        uint32 fall = uint32(NYTime.daysFromCivil(2026, 11, 1));
        c = _everyDay(fall);
        t = PitClock.times(c);
        assertEq(t.prevClose, uint64(fall - 1) * 1 days + 20 hours, "Saturday 16:00 EDT");
        assertEq(t.close, uint64(fall) * 1 days + 21 hours, "Sunday 16:00 EST");
        assertEq(t.close - t.prevClose, 25 hours);
        assertEq(_rho(c, t.prevClose + 12 hours + 30 minutes), 0.5e18);
        assertTrue(_trades(c, t.cutoff));
        assertFalse(_trades(c, t.cutoff + 1));
        // and the Monday after each switch is an ordinary 24 hours again
        t = PitClock.times(_everyDay(fall + 1));
        assertEq(t.close - t.prevClose, 24 hours);
    }

    // --------------------------------------------------------------------------------------------
    // properties
    // --------------------------------------------------------------------------------------------

    /// @dev Any valid clock: a stock clock with any weights over a gap of one to six days, or an every-day
    ///      clock, anywhere in the years 2024 to 2040.
    function _anyClock(uint256 seed) internal pure returns (IPitBook.RoundClock memory c) {
        uint32 day = uint32(bound(seed, 19_800, 25_500));
        seed = uint256(keccak256(abi.encode(seed)));
        if (seed % 3 == 0) return _everyDay(day);
        c = _stock(day - uint32(1 + (seed >> 8) % 6), day);
        c.skipAfterHours = (seed >> 16) % 4 == 0;
        // any mask with the regular session in it
        c.windows = uint8(8 | ((seed >> 20) % 8));
        // the regular session holds at least a quarter; the rest is split any way
        uint256 rest = (seed >> 24) % 7501;
        c.afterHours = uint16((seed >> 40) % (rest + 1));
        c.gap = uint16((seed >> 56) % (rest - c.afterHours + 1));
        c.preMarket = uint16(rest - c.afterHours - c.gap);
        c.regular = uint16(10_000 - rest);
    }

    function testFuzz_rho_neverRises_andStaysInItsRange(uint256 seed, uint64 a, uint64 b) public pure {
        IPitBook.RoundClock memory c = _anyClock(seed);
        PitClock.Times memory t = PitClock.times(c);
        a = uint64(bound(a, t.prevClose - 1 hours, t.close + 1 hours));
        b = uint64(bound(b, a, t.close + 1 hours));
        (uint256 rhoA, bool tradesA) = PitClock.at(c, a);
        (uint256 rhoB,) = PitClock.at(c, b);
        assertLe(rhoB, rhoA, "rho never rises");
        assertLe(rhoA, WAD);
        if (tradesA) {
            assertGt(rhoA, 0, "a second that trades has variance ahead of it");
            assertGe(a, t.prevClose);
            assertLe(a, t.cutoff);
        }
        // one second on, rho has not jumped: at most the steepest segment's slope (the weights sum to 1)
        (uint256 next,) = PitClock.at(c, a + 1);
        assertLe(rhoA - next, WAD / 14_400 + 1, "no jump in wall-clock time");
    }

    function testFuzz_rho_isExactAtTheEdges(uint256 seed) public pure {
        IPitBook.RoundClock memory c = _anyClock(seed);
        PitClock.Times memory t = PitClock.times(c);
        assertEq(_rho(c, t.prevClose), WAD);
        assertEq(_rho(c, t.close), 0);
        if (c.kind == IPitBook.Clock.NYWeekdays) {
            assertEq(_rho(c, t.afterHoursEnd), uint256(10_000 - c.afterHours) * 1e14);
            assertEq(_rho(c, t.preMarketStart), (uint256(c.preMarket) + c.regular) * 1e14);
            assertEq(_rho(c, t.regularStart), uint256(c.regular) * 1e14);
            assertEq(t.afterHoursEnd - t.prevClose, 4 hours);
            assertEq(t.regularStart - t.preMarketStart, 5 hours + 30 minutes);
            assertEq(t.close - t.regularStart, 6 hours + 30 minutes);
        }
    }

    /// @dev The depth scale of a round over any sequence of fills in time order: `g = min(g, max(sqrt(rho),
    ///      0.3))` never rises and never falls under its floor, and the remaining standard deviation is
    ///      `sigma * sqrt(rho)`.
    function testFuzz_depthScale_neverRises(uint256 seed, uint64[12] memory steps) public pure {
        IPitBook.RoundClock memory c = _anyClock(seed);
        PitClock.Times memory t = PitClock.times(c);
        uint256 g = WAD;
        uint64 ts = t.prevClose;
        uint256 lastSd = type(uint256).max;
        for (uint256 i; i < steps.length; ++i) {
            ts += uint64(bound(steps[i], 0, uint256(t.close - t.prevClose) / 8));
            if (ts > t.cutoff) break;
            (uint256 rho,) = PitClock.at(c, ts);
            (, uint256 sd, uint256 gNew) = PitMath.context(0.02e18, rho, 180e18, 181e18, g);
            assertLe(gNew, g, "g never rises");
            assertGe(gNew, 0.3e18, "g never falls under its floor");
            assertLe(sd, lastSd, "the remaining standard deviation never rises");
            assertLe(sd, 0.02e18);
            assertGt(sd, 0);
            (g, lastSd) = (gNew, sd);
        }
    }

    function testFuzz_theBookAnswersWithTheSameClock(uint256 seed, uint64 ts) public view {
        IPitBook.RoundClock memory c = _anyClock(seed);
        PitClock.Times memory t = PitClock.times(c);
        ts = uint64(bound(ts, t.prevClose - 1 days, t.close + 1 days));
        (uint256 rho, bool tradable) = PitClock.at(c, ts);
        (uint256 bookRho, bool bookTradable) = book.clockAt(c, ts);
        assertEq(bookRho, rho);
        assertEq(bookTradable, tradable);
    }

    function test_context_sdAndDepth() public pure {
        // the whole variance ahead: sd is sigma, depth is full
        (int256 x, uint256 sd, uint256 g) = PitMath.context(0.02e18, WAD, 180e18, 180e18, WAD);
        assertEq(x, 0);
        assertEq(sd, 0.02e18);
        assertEq(g, WAD);
        // 49% ahead: sd = 0.7 sigma, depth 0.7
        (, sd, g) = PitMath.context(0.02e18, 0.49e18, 180e18, 180e18, WAD);
        assertEq(sd, 0.014e18);
        assertEq(g, 0.7e18);
        // depth does not come back when a later print is passed a larger rho
        (,, g) = PitMath.context(0.02e18, 0.81e18, 180e18, 180e18, 0.7e18);
        assertEq(g, 0.7e18);
        // 4% ahead: sd = 0.2 sigma, depth on its floor of 0.3
        (, sd, g) = PitMath.context(0.02e18, 0.04e18, 180e18, 180e18, 0.7e18);
        assertEq(sd, 0.004e18);
        assertEq(g, 0.3e18);
    }
}
