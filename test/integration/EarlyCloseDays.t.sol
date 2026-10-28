// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StackFixture} from "./StackFixture.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice An early-close day (13:00) is skipped like a holiday, with 24 hours' notice. With Thanksgiving and
///         the early close after it skipped in time, no round exists for either day, and the round after the
///         long weekend is priced on the days it spans.
contract EarlyCloseDaysTest is StackFixture {
    address internal lp = makeAddr("lp");

    function test_earlyCloseDay_isSkipped_noRoundTradesAfterTheEarlyClose() public {
        _lpDeposit(lp, 1_000_000e18);
        uint32 thanksgiving = uint32(NYTime.daysFromCivil(2026, 11, 26));
        uint32 blackFriday = thanksgiving + 1;
        uint32 monday = thanksgiving + 4;

        // The owner skips both days well ahead.
        vm.startPrank(owner);
        book.setSkip(NVDA, thanksgiving, true);
        book.setSkip(NVDA, blackFriday, true);
        vm.stopPrank();
        for (uint32 d = day0 + 1; d < thanksgiving; ++d) {
            if (NYTime.isWeekday(d)) _recordCloseOf(d, S0, KEEPER);
        }

        // Wednesday evening: no round for Thursday or Friday; Monday's round opens on Wednesday's close.
        _warp(NYTime.closeTs(thanksgiving - 1) + 1000);
        vm.expectRevert(IPitBook.NotTradingDay.selector);
        hook.openRound(NVDA, address(chip), blackFriday);
        vm.expectRevert(IPitBook.NotTradingDay.selector);
        hook.openRound(NVDA, address(chip), thanksgiving);
        day = monday;
        roundId = hook.openRound(NVDA, address(chip), monday);
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(c.clock.prevDay, thanksgiving - 1);
        // three trading days of variance (Thursday and Friday counted as whole days: an early close
        // counted in full is the cautious side)
        uint256 v = book.getTicker(NVDA).varWad;
        assertEq(c.sigma, FixedPointMathLib.sqrtWad(3 * v), "the daily sigma times sqrt(3)");

        // Friday 13:00:30: no round exists to buy from.
        _warp(NYTime.at(blackFriday, 13 hours + 30));
        (, bool tradable) = book.clockAt(c.clock, uint64(block.timestamp));
        assertFalse(tradable, "Monday's round does not trade on Black Friday");
        console.log("the 27th has no round; Monday's round spans Wednesday's close to Monday's");
    }

    /// @dev The notice: a skip of the early close set after Wednesday's close (less than 24 hours before
    ///      Friday's 16:00) is refused.
    function test_earlyCloseDay_skipNeedsNotice() public {
        uint32 blackFriday = uint32(NYTime.daysFromCivil(2026, 11, 27));
        vm.warp(NYTime.closeTs(blackFriday) - 24 hours + 1);
        vm.prank(owner);
        vm.expectRevert(IPitBook.SkipTooLate.selector);
        book.setSkip(NVDA, blackFriday, true);
    }
}
