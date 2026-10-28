// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StackFixture} from "./StackFixture.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice A round opens on a close up to six calendar days back. Thanksgiving and the early close after it,
///         or 24 December and Christmas on a Friday, leave Wednesday as the last 16:00 close before Monday:
///         with both days skipped, Monday's round still opens.
contract CalendarSkipsTest is StackFixture {
    address internal lp = makeAddr("lp");

    function test_twoSkippedDaysBeforeAWeekend_mondaysRoundOpens() public {
        _lpDeposit(lp, 1_000_000e18);
        uint32 wednesday = uint32(NYTime.daysFromCivil(2026, 11, 25));
        uint32 thursday = wednesday + 1; // Thanksgiving
        uint32 friday = wednesday + 2; // early close at 13:00
        uint32 monday = wednesday + 5;
        uint32 tuesday = wednesday + 6;

        // (the days between the fixture's Monday and that Wednesday have no closes: the owner seeds it)
        // (the skips are set well ahead: the book wants 24 hours' notice)
        vm.startPrank(owner);
        book.setSkip(NVDA, thursday, true);
        book.setSkip(NVDA, friday, true);
        vm.stopPrank();
        uint64 closeAt = NYTime.closeTs(wednesday);
        _warp(closeAt + 5);
        oracle.set(NVDA, TRUSTLESS, closeAt, S0);
        vm.prank(owner);
        book.recordClose(NVDA, wednesday, abi.encode(TRUSTLESS));

        // Monday cannot be opened ahead of... nothing: Thursday and Friday are skipped, so Monday is the
        // next trading day and opens on Wednesday's close, five days back.
        vm.expectRevert(IPitBook.NotNextTradingDay.selector);
        hook.openRound(NVDA, address(chip), tuesday);
        _warp(NYTime.openTs(monday) - 3600);
        day = monday;
        roundId = hook.openRound(NVDA, address(chip), monday);
        assertEq(hook.getConfig(roundId).s0, S0);
        assertEq(hook.getConfig(roundId).day, monday);
    }
}
