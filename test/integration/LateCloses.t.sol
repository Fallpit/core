// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {PitOracle} from "../../src/PitOracle.sol";
import {PitClock} from "../../src/hook/PitClock.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {VaultFeeForwarderFactory} from "../../src/listing/VaultFeeForwarder.sol";
import {IPitVault} from "../../src/interfaces/IPitVault.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";

/// @notice A close first recorded more than 12 hours after its instant is late and settles nothing; the
///         oracle owner cannot stop or pick an open round's close; and a house has no fee forwarder address
///         before it is listed. The real system.
contract LateClosesTest is IntegrationFixture {
    uint256 internal constant STAKE = 100_000e18;

    // -------------------------------------------------------------------- a missed close is final

    /// @dev Nobody records Tuesday's close for 12 hours. Then anyone (here the holder of the winning side)
    ///      records it from the public Pyth update: it is stored and is Wednesday's start price, but it
    ///      settles nothing, and opening Wednesday's round still voids Tuesday's.
    function test_missedClose_aCloseRecordedAfterTheVoidPoint_cannotSettle() public {
        _open();
        _fund(alice, STAKE);
        _buy(alice, HIGHER, 1_000e18, S0);
        uint64 closeAt = NYTime.closeTs(day);
        uint256 closePrice = _grid(S0 * 101 / 100); // HIGHER wins

        _warp(closeAt + PitClock.MISSED_CLOSE + 1);
        vm.prank(alice);
        book.recordClose(ticker, day, _pythPrint(ticker, closePrice, closeAt));
        (uint256 recorded,) = book.closeOf(ticker, day);
        assertEq(recorded, closePrice, "stored: the next round starts from it");
        (uint256 settling, bool trustless, uint64 disputeEnd) = book.closeState(ticker, day);
        assertEq(settling, 0, "but it settles nothing");
        assertFalse(trustless);
        assertEq(disputeEnd, 0);
        assertTrue(book.closeInfo(ticker, day).late);

        vm.expectRevert(IFallpitHook.CloseNotRecorded.selector);
        hook.settleRound(house, day);

        bytes32 tuesday = roundId;
        bytes32 wednesday = hook.openRound(ticker, roundChip, day + 1);
        assertEq(uint8(hook.getState(tuesday).status), uint8(IFallpitHook.Status.Void), "voided");
        assertEq(hook.getConfig(wednesday).s0, closePrice, "Wednesday starts from the late close");
    }

    /// @dev The owner's gap-fill after the void point is late too: the 24 hour void still works.
    function test_missedClose_ownerGapFillAfterTheVoidPoint_doesNotStopTheVoid() public {
        _open();
        _fund(alice, STAKE);
        _buy(alice, LOWER, 1_000e18, S0);
        uint64 closeAt = NYTime.closeTs(day);
        _warp(closeAt + 20 hours);
        vm.prank(owner);
        book.recordClose(ticker, day, _keeperPrint(ticker, S0 * 99 / 100, closeAt));
        assertTrue(book.closeInfo(ticker, day).late);
        vm.expectRevert(IFallpitHook.CloseNotRecorded.selector);
        hook.settleRound(house, day);

        vm.expectRevert(IFallpitHook.VoidNotAllowed.selector);
        hook.voidRound(house, day);
        _warp(closeAt + 24 hours + 1);
        hook.voidRound(house, day);
        assertEq(uint8(_state().status), uint8(IFallpitHook.Status.Void));
    }

    /// @dev A close recorded up to the void point itself (12 hours after its instant) is in time: it settles,
    ///      and then the round can no longer be voided.
    function test_missedClose_aCloseAtTheVoidPoint_stillSettles() public {
        _open();
        _fund(alice, STAKE);
        _buy(alice, HIGHER, 1_000e18, S0);
        uint64 closeAt = NYTime.closeTs(day);
        uint256 closePrice = _grid(S0 * 101 / 100);
        _warp(closeAt + PitClock.MISSED_CLOSE);
        book.recordClose(ticker, day, _pythPrint(ticker, closePrice, closeAt));
        assertFalse(book.closeInfo(ticker, day).late);
        (uint256 settling,,) = book.closeState(ticker, day);
        assertEq(settling, closePrice);

        _warp(clock + 1); // past the void point now: the close is recorded, so nothing voids
        hook.settleRound(house, day);
        vm.expectRevert(IFallpitHook.PreviousRoundActive.selector);
        hook.openRound(ticker, roundChip, day + 1);
        hook.finalizeRound(house, day); // a trustless close finalizes at once
        assertEq(uint8(_state().status), uint8(IFallpitHook.Status.Final));
        uint256 higher = _token(HIGHER).id;
        vm.prank(alice);
        assertEq(hook.redeem(higher, alice, 1_000e18), 1_000e18, "HIGHER pays a chip");
    }

    /// @dev The ordinary case: a close recorded at the bell settles and finalizes.
    function test_missedClose_aCloseInsideTwelveHours_settles() public {
        _open();
        _fund(alice, STAKE);
        _buy(alice, HIGHER, 1_000e18, S0);
        _warp(NYTime.closeTs(day) + 6 hours);
        _closeAndFinalize(S0 * 101 / 100);
        assertEq(uint8(_state().status), uint8(IFallpitHook.Status.Final));
    }

    // ------------------------------------------------------- the oracle owner and an open round

    /// @dev The oracle owner switches both sources of NVDA off at 15:59:50, after the round opened. Fills
    ///      stop at once, but the round's close still verifies, even when it is recorded hours later, and
    ///      the round settles on it. Only closes a day later are refused.
    function test_oracleOwner_switchOffAfterTheRoundOpened_doesNotStopItsClose() public {
        _open();
        _fund(alice, STAKE);
        _buy(alice, HIGHER, 1_000e18, S0);
        uint64 closeAt = NYTime.closeTs(day);
        uint256 pending = _commitBuy(alice, HIGHER, 1_000e18, STAKE / 2);

        vm.startPrank(owner);
        oracle.setSourceDisabled(ticker, PYTH_SOURCE, true);
        oracle.setSourceDisabled(ticker, KEEPER_SOURCE, true);
        vm.stopPrank();
        assertFalse(oracle.supported(ticker), "no fill source");

        // the brake: the fill reverts (not final) and the commit refunds when its window ends
        bytes4 err = _fillReverts(pending, _printFor(pending, S0));
        assertEq(err, PitOracle.UnsupportedTicker.selector);
        IFallpitRouter.Commit memory c = router.getCommit(pending);
        _warp(c.fillTs + c.refundDelay + 1);
        router.refund(pending);

        // the close of the round still verifies, 11 hours after the bell, and settles the round
        _warp(closeAt + 11 hours);
        book.recordClose(ticker, day, _keeperPrint(ticker, S0 * 101 / 100, closeAt));
        hook.settleRound(house, day);
        _warp(clock + hook.getConfig(roundId).params.challengeWindow);
        hook.finalizeRound(house, day);
        assertEq(uint8(_state().status), uint8(IFallpitHook.Status.Final));

        // a close a day later is past the switch's delay: refused
        uint64 nextClose = NYTime.closeTs(day + 1);
        _warp(nextClose + 5);
        bytes memory report = _keeperPrint(ticker, S0, nextClose);
        vm.expectRevert(abi.encodeWithSelector(PitOracle.UnsupportedTicker.selector, ticker));
        book.recordClose(ticker, day + 1, report);
    }

    /// @dev A Pyth feed id filled in on a keeper-only ticker cannot pick the close of an open round: it
    ///      verifies nothing until SIGNER_DELAY has passed.
    function test_oracleOwner_aFilledInPythFeedWaits() public {
        bytes32 amd = bytes32("AMD");
        vm.startPrank(owner);
        _addTicker(amd, bytes32(0), IPitBook.FillSource.KeeperOnly);
        PitOracle.TickerConfig memory c = oracle.config(amd);
        c.pythFeedId = NVDA_ID;
        oracle.setTicker(amd, c);
        vm.stopPrank();
        assertEq(oracle.config(amd).pythFeedId, bytes32(0), "not in force yet");
        (PitOracle.TickerConfig memory p, uint64 from) = oracle.pendingConfig(amd);
        assertEq(p.pythFeedId, NVDA_ID);
        assertEq(from, clock + 24 hours);
    }

    // ----------------------------------------------------------------------- forwarder addresses

    /// @dev A house that is not listed has no forwarder address: fees sent to one would be lost.
    function test_forwarderOf_unlistedHouse_reverts() public {
        VaultFeeForwarderFactory factory = new VaultFeeForwarderFactory(IPitVault(address(vault)));
        bytes32 unlisted = vault.houseId(TSLA, address(chip));
        assertEq(vault.chipOf(unlisted), address(0));
        vm.expectRevert(VaultFeeForwarderFactory.UnknownHouse.selector);
        factory.forwarderOf(unlisted, alice);
        vm.expectRevert(VaultFeeForwarderFactory.UnknownHouse.selector);
        factory.create(unlisted, alice);

        // once it is listed the address is known, before the forwarder exists
        bytes32 listed = _createHouse(TSLA, address(chip));
        assertEq(listed, unlisted);
        address at = factory.forwarderOf(listed, alice);
        assertEq(at.code.length, 0);
        assertEq(factory.create(listed, alice), at);
    }
}
