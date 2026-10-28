// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title NYTime
/// @notice New York wall-clock instants for a trading day, with the US daylight-saving rule computed on chain.
/// @dev `day` is the number of days since 1970-01-01 of the New York calendar date. DST runs from the second
///      Sunday of March to the first Sunday of November; both switch days are Sundays, so a weekday is
///      entirely on one side of the switch. The switch itself is at 02:00 on those Sundays and the whole
///      Sunday is counted on the new side, so every instant from 02:00 on (16:00:00 included) is right on
///      every day of the week; only the first two hours of a switch Sunday are an hour off, and nothing
///      here or in the contracts uses them.
library NYTime {
    uint256 internal constant PRE_MARKET_SECONDS = 4 hours; // 04:00:00
    uint256 internal constant OPEN_SECONDS = 9 hours + 30 minutes; // 09:30:00
    uint256 internal constant CLOSE_SECONDS = 16 hours; // 16:00:00
    uint256 internal constant AFTER_HOURS_END_SECONDS = 20 hours; // 20:00:00

    /// @notice True for Monday to Friday.
    function isWeekday(uint32 day) internal pure returns (bool) {
        uint256 dow = _dow(day);
        return dow >= 1 && dow <= 5;
    }

    /// @notice `day * 1 days + utcOffsetHours(day) * 1 hours`: the base of every instant of `day`, so
    ///         `at(day, s) == midnight(day) + s`.
    function midnight(uint32 day) internal pure returns (uint64) {
        // Bound: below 2^32 * 86400 + 18000 < 2^49.
        unchecked {
            return uint64(uint256(day) * 1 days + utcOffsetHours(day) * 1 hours);
        }
    }

    /// @notice Unix timestamp of `secondsIntoDay` New York wall-clock time on `day`.
    function at(uint32 day, uint256 secondsIntoDay) internal pure returns (uint64) {
        return uint64(uint256(midnight(day)) + secondsIntoDay);
    }

    /// @notice 09:30:00 New York on `day`.
    function openTs(uint32 day) internal pure returns (uint64) {
        return at(day, OPEN_SECONDS);
    }

    /// @notice 16:00:00 New York on `day`.
    function closeTs(uint32 day) internal pure returns (uint64) {
        return at(day, CLOSE_SECONDS);
    }

    /// @notice Hours New York is behind UTC on `day`: 4 during daylight-saving time, otherwise 5.
    /// @dev The same steps as `civilFromDays` and `daysFromCivil`, for the year of `day` only. Bound: a
    ///      uint32 day gives a year from 1970 to below 2^24, so every step stays inside uint256 and none goes
    ///      below zero: March 1 of a year from 1970 on is a day at or after 59 (1970-03-01), and November 1
    ///      is 245 days after March 1 of the same year.
    function utcOffsetHours(uint32 day) internal pure returns (uint256) {
        unchecked {
            // the year of `day` (civilFromDays)
            uint256 z = uint256(day) + 719468;
            uint256 era = z / 146097;
            uint256 doe = z - era * 146097;
            uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
            uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            uint256 mp = (5 * doy + 2) / 153;
            uint256 year = yoe + era * 400 + (mp < 10 ? 0 : 1);
            // March 1 of that year (daysFromCivil(year, 3, 1): day of year 0 in a year that starts in March)
            era = year / 400;
            yoe = year - era * 400;
            uint256 march1 = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 - 719468;
            uint256 dstStart = _firstSundayOnOrAfter(march1) + 7;
            uint256 dstEnd = _firstSundayOnOrAfter(march1 + 245);
            return (day >= dstStart && day < dstEnd) ? 4 : 5;
        }
    }

    /// @notice Calendar date of a day number (Howard Hinnant's civil_from_days, for dates from 1970).
    function civilFromDays(uint256 day) internal pure returns (uint256 year, uint256 month, uint256 dom) {
        uint256 z = day + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        dom = doy - (153 * mp + 2) / 5 + 1;
        month = mp < 10 ? mp + 3 : mp - 9;
        year = yoe + era * 400 + (month <= 2 ? 1 : 0);
    }

    /// @notice Day number of a calendar date (Howard Hinnant's days_from_civil, for dates from 1970).
    function daysFromCivil(uint256 year, uint256 month, uint256 dom) internal pure returns (uint256) {
        uint256 y = month <= 2 ? year - 1 : year;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + dom - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    /// @dev 0 = Sunday. 1970-01-01 was a Thursday. Callers pass days below 2^33 (a uint32 day, or a day
    ///      of `utcOffsetHours`), so nothing wraps.
    function _dow(uint256 day) private pure returns (uint256) {
        unchecked {
            return (day + 4) % 7;
        }
    }

    /// @dev Callers pass days below 2^33 (`utcOffsetHours`), so nothing wraps.
    function _firstSundayOnOrAfter(uint256 day) private pure returns (uint256) {
        unchecked {
            return day + (7 - _dow(day)) % 7;
        }
    }
}
