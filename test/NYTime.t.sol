// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NYTime} from "../src/lib/NYTime.sol";

contract NYTimeTest is Test {
    function test_closeTs_duringDaylightSaving() public pure {
        // Friday 2026-10-02 16:00:00 New York (EDT) = 20:00:00 UTC
        uint32 day = uint32(NYTime.daysFromCivil(2026, 10, 2));
        assertEq(NYTime.closeTs(day), 1790971200);
        assertEq(NYTime.openTs(day), 1790971200 - 6 hours - 30 minutes);
        assertTrue(NYTime.isWeekday(day));
    }

    function test_closeTs_standardTime() public pure {
        // Monday 2026-12-07 16:00:00 New York (EST) = 21:00:00 UTC
        uint32 day = uint32(NYTime.daysFromCivil(2026, 12, 7));
        assertEq(NYTime.closeTs(day), uint256(day) * 1 days + 21 hours);
        assertEq(NYTime.utcOffsetHours(day), 5);
    }

    function test_dstBoundaries_2026() public pure {
        // DST 2026: starts Sunday March 8, ends Sunday November 1.
        assertEq(NYTime.utcOffsetHours(uint32(NYTime.daysFromCivil(2026, 3, 6))), 5);
        assertEq(NYTime.utcOffsetHours(uint32(NYTime.daysFromCivil(2026, 3, 9))), 4);
        assertEq(NYTime.utcOffsetHours(uint32(NYTime.daysFromCivil(2026, 10, 30))), 4);
        assertEq(NYTime.utcOffsetHours(uint32(NYTime.daysFromCivil(2026, 11, 2))), 5);
    }

    function test_weekend() public pure {
        assertFalse(NYTime.isWeekday(uint32(NYTime.daysFromCivil(2026, 10, 3)))); // Saturday
        assertFalse(NYTime.isWeekday(uint32(NYTime.daysFromCivil(2026, 10, 4)))); // Sunday
        assertTrue(NYTime.isWeekday(uint32(NYTime.daysFromCivil(2026, 10, 5)))); // Monday
    }

    function testFuzz_civilRoundTrip(uint32 day) public pure {
        day = uint32(bound(day, 0, 100_000));
        (uint256 y, uint256 m, uint256 d) = NYTime.civilFromDays(day);
        assertEq(NYTime.daysFromCivil(y, m, d), day);
    }
}
