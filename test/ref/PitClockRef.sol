// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTimeRef as NYTime} from "./NYTimeRef.sol";

/// @title PitClockRef (test only: a frozen copy of PitClock that computes the time-zone offset per instant, the reference of PitClockDiff.t.sol)
/// @notice The clock of a round: for a timestamp, how much of the round's variance is still ahead (`rho`)
///         and whether the round trades. Pure, and the same code in the book (which the hook calls) and
///         in the lens. See contracts/SPEC.md section 7.2.
/// @dev A round runs from the close it starts from (16:00:00 New York on `prevDay`) to its own close
///      (16:00:00 New York on `day`). `rho` is 1e18 at the first, 0 at the second, and falls in between
///      along straight lines, so it never rises.
///
///      `EveryDay`: one line from close to close. The round trades from the previous close to the cutoff.
///
///      `NYWeekdays`: four segments, each with its weight (basis points, summing to 10000) and each a
///      straight line in time. Which of them trade is the round's `windows` mask (the defaults: all but
///      the nights):
///        after-hours   16:00 to 20:00 on `prevDay`               AFTER_HOURS, and not `skipAfterHours`
///        gap           20:00 on `prevDay` to 04:00 on `day`      OVERNIGHT, weekday nights only
///        pre-market    04:00 to 09:30 on `day`                   PRE_MARKET
///        regular       09:30 to 16:00 on `day`                   REGULAR, until the cutoff
///      The gap holds the night and, when there is one, the weekend and the skipped days. By default
///      nothing fills in it, so its weight reaches the prices as a jump at the first pre-market fill.
///      With OVERNIGHT the nights of the gap trade (20:00 to 04:00 New York, the night into a weekday:
///      Sunday evening to Friday morning), and rho simply goes on falling through them; the daytime of a
///      skipped day and everything from Friday 20:00 to Sunday 20:00 never trade.
///
///      Edges, to the second: the after-hours window is `[16:00:00, 20:00:00)` (20:00:00 itself does not
///      trade unless the night does), a night `[20:00:00, 04:00:00)`, the pre-market and the regular
///      session together `[04:00:00, cutoff]` (the cutoff itself trades). Times are New York wall-clock times of each day, so a round that spans a
///      daylight-saving switch has a gap one hour shorter or longer and segments of the usual length.
library PitClockRef {
    uint256 internal constant WAD = 1e18;
    /// @dev One basis point in WAD.
    uint256 internal constant BP = 1e14;
    /// @dev Trading stops 630 s before the close (15:49:30 New York).
    uint64 internal constant CUTOFF_LEAD = 630;
    /// @dev A close not recorded this long after its instant (04:00 the next morning) is missed: the next
    ///      round may open from the close before it (the book), and the round of the missed day is voided
    ///      when its house opens that next round (the hook).
    uint64 internal constant MISSED_CLOSE = 12 hours;

    /// @dev Bits of `RoundClock.windows`: the windows of a `NYWeekdays` round that trade.
    uint8 internal constant AFTER_HOURS = 1;
    uint8 internal constant OVERNIGHT = 2;
    uint8 internal constant PRE_MARKET = 4;
    uint8 internal constant REGULAR = 8;
    /// @dev The default: the after-hours, the pre-market and the regular session; no nights.
    uint8 internal constant DEFAULT_WINDOWS = AFTER_HOURS | PRE_MARKET | REGULAR;
    uint8 internal constant ALL_WINDOWS = AFTER_HOURS | OVERNIGHT | PRE_MARKET | REGULAR;

    /// @notice The instants that bound a round's segments, unix seconds. For `EveryDay` the three in the
    ///         middle are unused and equal `prevClose`.
    struct Times {
        uint64 prevClose;
        uint64 afterHoursEnd;
        uint64 preMarketStart;
        uint64 regularStart;
        uint64 cutoff;
        uint64 close;
    }

    /// @notice The instants of `clock`.
    function times(IPitBook.RoundClock memory clock) internal pure returns (Times memory t) {
        t.prevClose = NYTime.closeTs(clock.prevDay);
        t.close = NYTime.closeTs(clock.day);
        t.cutoff = t.close - CUTOFF_LEAD;
        if (clock.kind == IPitBook.Clock.EveryDay) {
            t.afterHoursEnd = t.preMarketStart = t.regularStart = t.prevClose;
        } else {
            t.afterHoursEnd = NYTime.at(clock.prevDay, NYTime.AFTER_HOURS_END_SECONDS);
            t.preMarketStart = NYTime.at(clock.day, NYTime.PRE_MARKET_SECONDS);
            t.regularStart = NYTime.openTs(clock.day);
        }
    }

    /// @notice The clock at `ts`.
    /// @return rho share of the round's variance still ahead, WAD, rounded down
    /// @return tradable true when a fill may be priced by a print made at `ts`
    function at(IPitBook.RoundClock memory clock, uint64 ts)
        internal
        pure
        returns (uint256 rho, bool tradable)
    {
        Times memory t = times(clock);
        if (ts >= t.close) return (0, false);
        if (ts < t.prevClose) return (WAD, false);
        if (clock.kind == IPitBook.Clock.EveryDay) {
            return (uint256(t.close - ts) * WAD / (t.close - t.prevClose), ts <= t.cutoff);
        }
        if (ts < t.afterHoursEnd) {
            rho = _segment(
                uint256(clock.gap) + clock.preMarket + clock.regular,
                clock.afterHours,
                t.prevClose,
                t.afterHoursEnd,
                ts
            );
            return (rho, clock.windows & AFTER_HOURS != 0 && !clock.skipAfterHours);
        }
        if (ts < t.preMarketStart) {
            rho = _segment(
                uint256(clock.preMarket) + clock.regular, clock.gap, t.afterHoursEnd, t.preMarketStart, ts
            );
            return (rho, clock.windows & OVERNIGHT != 0 && _weekdayNight(clock, ts));
        }
        if (ts < t.regularStart) {
            rho = _segment(clock.regular, clock.preMarket, t.preMarketStart, t.regularStart, ts);
            return (rho, clock.windows & PRE_MARKET != 0);
        }
        return (
            _segment(0, clock.regular, t.regularStart, t.close, ts),
            clock.windows & REGULAR != 0 && ts <= t.cutoff
        );
    }

    /// @dev True when `ts`, an instant of the round's gap, is in a night that trades: 20:00:00 New York
    ///      of an evening up to (not including) 04:00:00 of the morning after, when that morning is a
    ///      weekday's. So Sunday evening to Friday morning; never Friday 20:00 to Sunday 20:00, and never
    ///      the daytime of a skipped day. The gap is at most six days long.
    function _weekdayNight(IPitBook.RoundClock memory clock, uint64 ts) private pure returns (bool) {
        // the newest evening (20:00:00) at or before `ts`; the gap begins with the evening of `prevDay`
        uint32 evening = clock.day - 1;
        while (ts < NYTime.at(evening, NYTime.AFTER_HOURS_END_SECONDS)) {
            if (evening == clock.prevDay) return false;
            --evening;
        }
        return ts < NYTime.at(evening + 1, NYTime.PRE_MARKET_SECONDS) && NYTime.isWeekday(evening + 1);
    }

    /// @dev `rho` inside the segment `[start, end)` of weight `weight`, with `later` basis points of
    ///      weight in the segments after it: `later + weight * (end - ts) / (end - start)`, in WAD.
    function _segment(uint256 later, uint256 weight, uint64 start, uint64 end, uint64 ts)
        private
        pure
        returns (uint256)
    {
        uint256 span = end - start;
        return (later * span + weight * (end - ts)) * BP / span;
    }
}
