// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";

import {StackFixture} from "./StackFixture.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {PitBook} from "../../src/hook/PitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";

/// @notice The guardian cannot void. Its one power is `PitBook.dispute(roundId)` inside the challenge window
///         of a keeper-closed round: every round on that close then finalizes only one hour after the close
///         (`PitBook.DISPUTE_WINDOW`), and until then anyone may replace the close with a trustless print, or
///         once with another valid keeper print for the same instant more than the oracle's bound away. A new
///         guardian takes over 24 hours after it is named.
contract DisputesTest is StackFixture {
    address internal lp = makeAddr("lp");
    address internal eve = makeAddr("eve");
    uint256 internal constant CAPITAL = 1_000_000e18;
    uint256 internal constant LOT = 20_000e18;

    /// @dev The print of `source` for the close of `day` becomes `price` (for the keeper: a second valid
    ///      print for the instant, what equivocating signers would produce) and is offered to the book.
    function _offerClose(uint256 price, uint8 source) internal {
        oracle.set(NVDA, source, NYTime.closeTs(day), price);
        book.recordClose(NVDA, day, abi.encode(source));
    }

    /// @dev The same, expecting the book to refuse it with `err`.
    function _offerCloseRefused(uint256 price, uint8 source, bytes4 err) internal {
        oracle.set(NVDA, source, NYTime.closeTs(day), price);
        vm.expectRevert(err);
        book.recordClose(NVDA, day, abi.encode(source));
    }

    function test_guardian_cannotVoid_aDisputeIsNoFreeOption() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, 1_000_000e18);

        // The owner names eve's accomplice: it takes over only 24 hours later, in the open.
        address accomplice = makeAddr("accomplice");
        vm.warp(clock - 24 hours);
        vm.prank(owner);
        book.setGuardian(accomplice);
        (address next, uint64 eta) = book.pendingGuardian();
        assertEq(next, accomplice);
        assertEq(eta, clock, "in force 24 hours after it was named");
        assertEq(book.guardian(), guardian, "the old guardian until then");
        vm.warp(clock);
        assertEq(book.guardian(), accomplice);

        _open(3600);
        uint256 paid;
        for (uint256 i; i < 5; ++i) {
            paid += _buy(eve, HIGHER, LOT, S0);
        }
        uint256 higher = _token(HIGHER).id;
        uint256 snap = vm.snapshotState();

        // Tails: the close is 1% down, HIGHER lost. The accomplice cannot void the settled round.
        _recordCloseOf(day, S0 * 99 / 100, KEEPER);
        hook.settleRound(house, day);
        vm.prank(accomplice);
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        hook.voidRound(house, day);
        // It can dispute; that only holds the round open for a correction. With no other valid print
        // for the instant nothing changes, and an hour after the close the round finalizes on it.
        vm.prank(accomplice);
        book.dispute(roundId);
        _offerCloseRefused(S0 * 99 / 100, KEEPER, IPitBook.ReplacementRefused.selector); // the same print again
        vm.expectRevert(IFallpitHook.ChallengeWindowOpen.selector);
        hook.finalizeRound(house, day);
        _warp(NYTime.closeTs(day) + 1 hours);
        hook.finalizeRound(house, day);
        vm.prank(eve);
        vm.expectRevert(IFallpitHook.NotWinner.selector);
        router.redeem(higher, 100_000e18);
        uint256 houseAfterLoss = vault.getHouse(house).lpAssets + vault.getHouse(house).endowment;
        console.log("close -1%%, disputed: eve gets 0 of %s; house %s", paid / 1e18, houseAfterLoss / 1e18);
        assertGt(
            houseAfterLoss, CAPITAL + paid * 9 / 10, "the house keeps the lost bet (less the protocol fee)"
        );

        vm.revertToState(snap);

        // Heads: the close is 1% up, HIGHER won, the round finalizes after the window.
        _recordCloseOf(day, S0 * 101 / 100, KEEPER);
        hook.settleRound(house, day);
        _warp(clock + 900);
        hook.finalizeRound(house, day);
        vm.prank(eve);
        uint256 won = router.redeem(higher, 100_000e18);
        int256 expected = (int256(won) - 2 * int256(paid)) / 2;
        console.log("close +1%%, final: eve redeems %s; her expected result at p = 0.5:", won / 1e18);
        console.logInt(expected / 1e18);
        assertLt(expected, 0, "no option left: a fair bet less the fees");
    }

    function test_dispute_onlyTheGuardian_onlyInTheWindow_onlyAKeeperClose() public {
        _lpDeposit(lp, CAPITAL);
        _open(3600);
        _recordCloseOf(day, S0, KEEPER);
        // not before the round is settled
        vm.prank(guardian);
        vm.expectRevert(IPitBook.DisputeNotAllowed.selector);
        book.dispute(roundId);
        hook.settleRound(house, day);
        uint64 settledAt = hook.getState(roundId).settledAt;
        // only the guardian
        vm.prank(owner);
        vm.expectRevert(IPitBook.OnlyGuardian.selector);
        book.dispute(roundId);
        // not once the window is over
        uint256 snap = vm.snapshotState();
        vm.warp(settledAt + 900);
        vm.prank(guardian);
        vm.expectRevert(IPitBook.DisputeNotAllowed.selector);
        book.dispute(roundId);
        vm.revertToState(snap);
        // not on a trustless close
        _offerClose(S0, TRUSTLESS);
        vm.prank(guardian);
        vm.expectRevert(IPitBook.DisputeNotAllowed.selector);
        book.dispute(roundId);
    }

    /// @dev The replacement rule during a dispute, which nobody can game: a keeper print replaces a keeper
    ///      close once, only more than the bound (60 bps) away; nothing goes back and forth; a trustless
    ///      print always wins and is final; every round on the close waits for the dispute.
    function test_dispute_replacementRule() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, 1_000_000e18);
        // a second house of the ticker, in another chip, on the same close
        MockChip chip2 = new MockChip(18);
        guard.set(address(chip2), true, false);
        bytes32 house2 = vault.createHouse(NVDA, address(chip2));
        chip2.mint(lp, CAPITAL);
        vm.startPrank(lp);
        chip2.approve(address(vault), CAPITAL);
        vault.deposit(house2, CAPITAL);
        vm.stopPrank();
        bytes32 round2 = hook.openRound(NVDA, address(chip2), day);

        _open(3600);
        _buy(eve, HIGHER, LOT, S0);
        uint64 closeAt = NYTime.closeTs(day);

        // Outside a dispute a keeper close is never replaced by a keeper print.
        _recordCloseOf(day, S0 * 1003 / 1000, KEEPER);
        _offerCloseRefused(S0 * 990 / 1000, KEEPER, IPitBook.ReplacementRefused.selector);
        hook.settleRound(house, day);
        hook.settleRound(house2, day);
        assertEq(hook.getState(roundId).winners >> HIGHER & 1, 1, "HIGHER on +30 bps");

        vm.prank(guardian);
        book.dispute(roundId);
        PitBook.Close memory cl = book.closeInfo(NVDA, day);
        assertEq(cl.disputeEnd, closeAt + 1 hours);
        assertEq(book.DISPUTE_WINDOW(), 1 hours);

        // Within the bound: refused. 50 bps away would flip HIGHER to LOWER on a whim.
        _offerCloseRefused(S0 * 998 / 1000, KEEPER, IPitBook.ReplacementRefused.selector);
        // More than the bound: accepted, once.
        _offerClose(S0 * 990 / 1000, KEEPER);
        (uint256 price,) = book.closeOf(NVDA, day);
        assertEq(price, S0 * 990 / 1000);
        // and nobody goes back, however far
        _offerCloseRefused(S0 * 1003 / 1000, KEEPER, IPitBook.ReplacementRefused.selector);
        // both houses re-settle on the new close and wait for the dispute to end
        vm.expectRevert(IFallpitHook.CloseChanged.selector);
        hook.finalizeRound(house, day);
        hook.settleRound(house, day);
        hook.settleRound(house2, day);
        assertEq(hook.getState(roundId).winners >> LOWER & 1, 1, "LOWER on -100 bps");
        _warp(closeAt + 1 hours - 1);
        vm.expectRevert(IFallpitHook.ChallengeWindowOpen.selector);
        hook.finalizeRound(house2, day);

        // A trustless print wins whatever came before, and the rounds finalize on it at once.
        _offerClose(S0 * 1001 / 1000, TRUSTLESS);
        hook.settleRound(house, day);
        hook.settleRound(house2, day);
        hook.finalizeRound(house, day);
        hook.finalizeRound(house2, day);
        assertEq(hook.getState(roundId).winners >> HIGHER & 1, 1, "HIGHER on the trustless close");
        assertEq(uint8(hook.getState(round2).status), uint8(IFallpitHook.Status.Final));
        _offerCloseRefused(S0, TRUSTLESS, IPitBook.CloseIsFinal.selector);
    }

    /// @dev The window ends one hour after the close's instant whenever the round was settled: a close
    ///      recorded and settled late leaves the guardian nothing to dispute, and the call says so instead
    ///      of recording a dispute that holds nothing. Inside the hour a late settlement is still disputable.
    function test_dispute_oneHourAfterTheClose_lateSettlement() public {
        _lpDeposit(lp, CAPITAL);
        _open(3600);
        uint64 closeAt = NYTime.closeTs(day);
        uint256 snap = vm.snapshotState();

        // recorded and settled 50 minutes after the close: the guardian has until 17:00
        _warp(closeAt + 50 minutes);
        _recordCloseOf(day, S0 * 1003 / 1000, KEEPER);
        hook.settleRound(house, day);
        vm.prank(guardian);
        book.dispute(roundId);
        assertEq(book.closeInfo(NVDA, day).disputeEnd, closeAt + 1 hours);
        _warp(closeAt + 1 hours - 1);
        vm.expectRevert(IFallpitHook.ChallengeWindowOpen.selector);
        hook.finalizeRound(house, day);
        // the challenge window of the settlement (900 s) outlasts the dispute: finalize waits for both
        _warp(closeAt + 1 hours);
        vm.expectRevert(IFallpitHook.ChallengeWindowOpen.selector);
        hook.finalizeRound(house, day);
        _warp(closeAt + 50 minutes + 900);
        hook.finalizeRound(house, day);

        vm.revertToState(snap);
        // recorded and settled at 17:05: inside the settlement's challenge window, past the dispute window
        _warp(closeAt + 1 hours + 5 minutes);
        _recordCloseOf(day, S0 * 1003 / 1000, KEEPER);
        hook.settleRound(house, day);
        vm.prank(guardian);
        vm.expectRevert(IPitBook.DisputeNotAllowed.selector);
        book.dispute(roundId);
        _warp(closeAt + 1 hours + 5 minutes + 900);
        hook.finalizeRound(house, day);
    }

    /// @dev After the dispute window (one hour after the close) the rounds finalize on the latest close
    ///      (here a keeper replacement).
    function test_dispute_finalizesOnTheLatestCloseAfterOneHour() public {
        _lpDeposit(lp, CAPITAL);
        _open(3600);
        uint64 closeAt = NYTime.closeTs(day);
        _recordCloseOf(day, S0 * 1003 / 1000, KEEPER);
        hook.settleRound(house, day);
        vm.prank(guardian);
        book.dispute(roundId);
        _offerClose(S0 * 990 / 1000, KEEPER);
        hook.settleRound(house, day);
        _warp(closeAt + 1 hours - 1);
        vm.expectRevert(IFallpitHook.ChallengeWindowOpen.selector);
        hook.finalizeRound(house, day);
        // the window is over: no replacement any more, the round finalizes on the latest close
        _warp(closeAt + 1 hours);
        _offerCloseRefused(S0 * 970 / 1000, KEEPER, IPitBook.ReplacementRefused.selector);
        hook.finalizeRound(house, day);
        assertEq(hook.getState(roundId).settledPrice, S0 * 990 / 1000);
    }
}
