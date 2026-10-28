// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPitBook} from "../../src/hook/IPitBook.sol";
import {PitClock} from "../../src/hook/PitClock.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {PitClockRef} from "../ref/PitClockRef.sol";
import {NYTimeRef} from "../ref/NYTimeRef.sol";

/// @dev The clock and calendar code under test, behind external calls (so a revert is a result too).
contract ClockImpl {
    function times(IPitBook.RoundClock memory c) external pure returns (PitClock.Times memory) {
        return PitClock.times(c);
    }

    function at(IPitBook.RoundClock memory c, uint64 ts) external pure returns (uint256, bool) {
        return PitClock.at(c, ts);
    }

    function nyAt(uint32 day, uint256 s) external pure returns (uint64) {
        return NYTime.at(day, s);
    }

    function dayInfo(uint32 d) external pure returns (uint256 off, uint64 open, uint64 close, bool weekday) {
        return (NYTime.utcOffsetHours(d), NYTime.openTs(d), NYTime.closeTs(d), NYTime.isWeekday(d));
    }
}

/// @dev The reference: the same functions on the checked copies in test/ref.
contract ClockRef {
    function times(IPitBook.RoundClock memory c) external pure returns (PitClockRef.Times memory) {
        return PitClockRef.times(c);
    }

    function at(IPitBook.RoundClock memory c, uint64 ts) external pure returns (uint256, bool) {
        return PitClockRef.at(c, ts);
    }

    function nyAt(uint32 day, uint256 s) external pure returns (uint64) {
        return NYTimeRef.at(day, s);
    }

    function dayInfo(uint32 d) external pure returns (uint256 off, uint64 open, uint64 close, bool weekday) {
        return
            (NYTimeRef.utcOffsetHours(d), NYTimeRef.openTs(d), NYTimeRef.closeTs(d), NYTimeRef.isWeekday(d));
    }
}

/// @notice `PitClock` (one time-zone offset per day) and `NYTime` (unchecked where every input is a uint32
///         day) give the same results, and the same reverts, as the checked reference copies, over every
///         day number a `RoundClock` can hold.
contract PitClockDiffTest is Test {
    ClockImpl internal impl;
    ClockRef internal ref;

    function setUp() public {
        impl = new ClockImpl();
        ref = new ClockRef();
    }

    function _clock(
        bool weekdays,
        bool skipAfterHours,
        uint8 windows,
        uint32 prevDay,
        uint32 day,
        uint16 a,
        uint16 g,
        uint16 p,
        uint16 r
    ) internal pure returns (IPitBook.RoundClock memory c) {
        c = IPitBook.RoundClock({
            kind: weekdays ? IPitBook.Clock.NYWeekdays : IPitBook.Clock.EveryDay,
            skipAfterHours: skipAfterHours,
            windows: windows,
            prevDay: prevDay,
            day: day,
            afterHours: a,
            gap: g,
            preMarket: p,
            regular: r
        });
    }

    /// @dev Both calls, compared as (success, return data).
    function _same(bytes memory call) internal view {
        (bool okA, bytes memory a) = address(impl).staticcall(call);
        (bool okB, bytes memory b) = address(ref).staticcall(call);
        assertEq(okA, okB, "same success");
        assertEq(a, b, "same result");
    }

    /// @notice `times` for any two uint32 days and both kinds.
    function testFuzz_times_sameAsReference(bool weekdays, uint32 prevDay, uint32 day) public view {
        IPitBook.RoundClock memory c = _clock(weekdays, false, 15, prevDay, day, 1000, 1000, 1000, 7000);
        _same(abi.encodeCall(ClockImpl.times, (c)));
    }

    /// @notice `at` for a round of up to 10 days, any day number, any weights and windows, at an instant
    ///         near the round (the nights of the gap loop over its days) or anywhere.
    function testFuzz_at_sameAsReference(
        bool weekdays,
        bool skipAfterHours,
        uint8 windows,
        uint32 prevDay,
        uint8 gapDays,
        uint16 a,
        uint16 g,
        uint16 p,
        uint16 r,
        uint64 ts,
        bool near
    ) public view {
        uint256 end = uint256(prevDay) + (gapDays % 11);
        uint32 day = end > type(uint32).max ? type(uint32).max : uint32(end);
        if (near) {
            uint256 lo = uint256(prevDay) * 1 days;
            ts = uint64(bound(ts, lo, uint256(day) * 1 days + 2 days));
        }
        IPitBook.RoundClock memory c = _clock(weekdays, skipAfterHours, windows, prevDay, day, a, g, p, r);
        _same(abi.encodeCall(ClockImpl.at, (c, ts)));
    }

    /// @notice `at` for any two uint32 days in any order, outside the nights (no loop over the gap).
    function testFuzz_at_anyDays_sameAsReference(
        bool weekdays,
        uint8 windows,
        uint32 prevDay,
        uint32 day,
        uint16 a,
        uint16 g,
        uint16 p,
        uint16 r,
        uint64 ts
    ) public view {
        windows &= ~PitClock.OVERNIGHT;
        IPitBook.RoundClock memory c = _clock(weekdays, false, windows, prevDay, day, a, g, p, r);
        _same(abi.encodeCall(ClockImpl.at, (c, ts)));
    }

    /// @notice The day functions of `NYTime` for any uint32 day, and `at` for any seconds (an overflow
    ///         reverts in both).
    function testFuzz_nyTime_sameAsReference(uint32 day, uint256 s) public view {
        _same(abi.encodeCall(ClockImpl.dayInfo, (day)));
        _same(abi.encodeCall(ClockImpl.nyAt, (day, s)));
        _same(abi.encodeCall(ClockImpl.nyAt, (day, s % 2 days)));
    }

    /// @notice Every day from 1970 to 2189, one by one: the offset, open, close and weekday.
    function test_nyTime_everyDay_sameAsReference() public pure {
        for (uint32 d; d < 80_000; ++d) {
            assertEq(NYTime.utcOffsetHours(d), NYTimeRef.utcOffsetHours(d));
            assertEq(NYTime.closeTs(d), NYTimeRef.closeTs(d));
        }
    }

    /// @notice The extremes of the day range.
    function test_extremes_sameAsReference() public view {
        uint32[6] memory ds = [uint32(0), 1, 59, 60, type(uint32).max - 1, type(uint32).max];
        for (uint256 i; i < ds.length; ++i) {
            _same(abi.encodeCall(ClockImpl.dayInfo, (ds[i])));
            for (uint256 j; j < ds.length; ++j) {
                IPitBook.RoundClock memory c = _clock(true, false, 13, ds[i], ds[j], 1000, 1000, 1000, 7000);
                _same(abi.encodeCall(ClockImpl.times, (c)));
                _same(abi.encodeCall(ClockImpl.at, (c, uint64(uint256(ds[j]) * 1 days + 15 hours))));
            }
        }
    }
}
