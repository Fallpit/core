// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {StackFixture} from "./StackFixture.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";

/// @notice A commit fills only at the print of its own instant and only inside its window (30 s by default,
///         at most 120 s). After a longer keeper outage both sides of a commit pair refund in full, so an
///         unfilled commit is an option on the price for no longer than the window.
contract StaleCommitsTest is StackFixture {
    address internal lp = makeAddr("lp");
    address internal eve = makeAddr("eve");

    uint256 internal constant LOT = 20_000e18;

    /// @dev Eve commits HIGHER and LOWER at the previous close, nobody fills for 115 s while the stock
    ///      moves by `bps`, then she tries to fill the side that gained at the earlier print.
    function _run(int256 bps) internal returns (int256 net) {
        uint256 start = chip.balanceOf(eve);
        vm.startPrank(eve);
        uint256 higher = router.commit{value: FILL_FEE}(roundId, HIGHER, true, LOT, LOT);
        uint256 lower = router.commit{value: FILL_FEE}(roundId, LOWER, true, LOT, LOT);
        vm.stopPrank();
        uint64 t = router.getCommit(higher).fillTs;
        assertEq(router.getCommit(higher).refundDelay, 30, "the fill window of a commit");
        oracle.set(NVDA, KEEPER, t, S0);

        // keeper outage: 115 seconds pass, the stock moves
        _warp(t + 115);
        if (bps != 0) {
            uint256 pick = bps > 0 ? higher : lower;
            vm.prank(eve);
            vm.expectRevert(IFallpitRouter.FillWindowClosed.selector);
            router.fill(pick, abi.encode(KEEPER));
        }
        // both commits come back whole
        vm.startPrank(eve);
        router.refund(higher);
        router.refund(lower);
        vm.stopPrank();
        net = int256(chip.balanceOf(eve)) - int256(start);
    }

    function test_unfilledCommit_isNoTwoMinuteOption() public {
        _lpDeposit(lp, 1_000_000e18);
        _fund(eve, 100_000e18);
        roundId = hook.openRound(NVDA, address(chip), day);
        _warp(NYTime.closeTs(day) - 1800); // half an hour before the close

        uint256 snap = vm.snapshotState();
        int256 up = _run(20); // +0.20% in two minutes
        vm.revertToState(snap);
        int256 down = _run(-20);
        vm.revertToState(snap);
        int256 flat = _run(0);
        assertEq(up, 0, "nothing to exercise after the window");
        assertEq(down, 0);
        assertEq(flat, 0);
        assertEq(hook.getState(roundId).held, 1_000_000e18, "the house is untouched");

        // the owner cannot bring the long window back
        IPitBook.Params memory p = book.defaultParams();
        p.refundDelay = 121;
        vm.prank(owner);
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
    }

    /// @dev Inside the window (30 s) the commit's print still fills, so a commit nobody fills is an option
    ///      on the price for that long. It ends at second 31.
    function test_unfilledCommit_fillsAtItsOldPrintOnlyInsideTheWindow() public {
        _lpDeposit(lp, 1_000_000e18);
        _fund(eve, 100_000e18);
        roundId = hook.openRound(NVDA, address(chip), day);
        _warp(NYTime.closeTs(day) - 1800);
        vm.startPrank(eve);
        uint256 a = router.commit{value: FILL_FEE}(roundId, HIGHER, true, LOT, LOT);
        uint256 b = router.commit{value: FILL_FEE}(roundId, LOWER, true, LOT, LOT);
        vm.stopPrank();
        uint64 t = router.getCommit(a).fillTs;
        oracle.set(NVDA, KEEPER, t, S0);
        _warp(t + 30);
        vm.prank(eve);
        assertTrue(router.fill(a, abi.encode(KEEPER)), "second 30: still fillable");
        _warp(t + 31);
        vm.prank(eve);
        vm.expectRevert(IFallpitRouter.FillWindowClosed.selector);
        router.fill(b, abi.encode(KEEPER));
    }
}
