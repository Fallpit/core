// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";
import {MockFeesManager} from "../vault/mocks/MockFeesManager.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {PitVault} from "../../src/PitVault.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice The life of a house across rounds, through the real contracts: rolling to the next day with
///         queued LP moves, losing days shared pro rata by endowment and shares, the void paths, the fill source
///         policy with both oracle sources live, and launchpad fees harvested into a house.
contract LifecycleTest is IntegrationFixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant STAKE = 200_000e18;
    address internal lp2 = makeAddr("lp2");
    address internal donor = makeAddr("donor");

    event Refunded(uint256 indexed commitId, address indexed user, RefundReason reason);

    function setUp() public override {
        super.setUp();
        _fund(alice, STAKE);
        _fund(bob, STAKE);
        _fund(carol, STAKE);
    }

    function _donate(uint256 amount) internal {
        chip.mint(donor, amount);
        vm.startPrank(donor);
        chip.approve(address(vault), amount);
        vault.donate(house, amount);
        vm.stopPrank();
    }

    function _sumOf(address[6] memory who) internal view returns (uint256 sum) {
        for (uint256 i; i < who.length; ++i) {
            sum += chip.balanceOf(who[i]);
        }
    }

    // --------------------------------------------------------------------------------------------
    // two consecutive days on one house
    // --------------------------------------------------------------------------------------------

    function test_twoDays_theSameHouseRolls_withQueuedDepositAndWithdrawal() public {
        uint256 minted = 3 * STAKE + HOUSE_CAPITAL + 200_000e18;
        bytes32 tuesday = _open();
        _buy(alice, HIGHER, 15_000e18, S0);
        _buy(bob, LOWER, 12_000e18, S0 * 1002 / 1000);
        _buy(carol, F4, 8_000e18, S0 * 999 / 1000); // the floor just above the previous close
        _sell(alice, HIGHER, 5_000e18, S0 * 1001 / 1000);

        // LP moves during the round wait in the queue: lp2 brings 200,000, lp takes 30% of its shares out
        assertEq(_lpDeposit(lp2, house, 200_000e18), 0, "a deposit into a locked house mints nothing yet");
        uint256 lpShares = vault.balanceOf(lp, uint256(house));
        vm.prank(lp);
        assertEq(vault.requestWithdraw(house, lpShares * 3 / 10), 0, "and a withdrawal pays nothing yet");

        // Wednesday cannot open while Tuesday runs, nor before Tuesday's close is on the books
        vm.expectRevert(IPitBook.NotNextTradingDay.selector);
        hook.openRound(NVDA, address(chip), day + 1);

        uint256 tuesdayClose = _grid(S0 * 1007 / 1000);
        _recordClose(tuesdayClose, PYTH_SOURCE);
        vm.expectRevert(IFallpitHook.PreviousRoundActive.selector);
        hook.openRound(NVDA, address(chip), day + 1);
        hook.settleRound(house, day);
        vm.expectRevert(IFallpitHook.PreviousRoundActive.selector);
        hook.openRound(NVDA, address(chip), day + 1);
        IFallpitHook.RoundState memory settled = _state();
        hook.finalizeRound(house, day);

        // the result is booked to the shares that were in the round: lp's, the queued ones included
        PitVault.House memory h = vault.getHouse(house);
        uint256 back = h.lpAssets;
        assertEq(h.endowment, 0);
        assertEq(h.totalShares, lpShares);
        assertEq(chip.balanceOf(address(vault)), back + 200_000e18, "the result plus the queued deposit");

        // Wednesday opens: the queues run at the price after Tuesday's result, then the capital goes out
        uint256 assetsOut = (lpShares * 3 / 10).fullMulDiv(back + 1, lpShares + 1e6);
        uint256 mintedShares = uint256(200_000e18).fullMulDiv(lpShares + 1e6, back + 1);
        day += 1;
        bytes32 wednesday = _open();
        assertTrue(wednesday != tuesday);
        IFallpitHook.RoundConfig memory cfg = hook.getConfig(wednesday);
        assertEq(cfg.capital, back - assetsOut + 200_000e18, "what the house is worth after the queues");
        assertEq(cfg.s0, tuesdayClose, "Wednesday starts from Tuesday's close");
        {
            // EWMA: 0.94 of the old variance plus 0.06 of Tuesday's squared return
            int256 ret = FixedPointMathLib.lnWad(int256(tuesdayClose.divWad(S0)));
            uint256 variance = (94 * SEED_VAR + 6 * (uint256(ret * ret) / 1e18)) / 100;
            assertEq(book.getTicker(NVDA).varWad, variance);
            assertEq(cfg.sigma, variance.sqrtWad());
        }
        (uint256 shares2,,,) = vault.positionOf(house, lp2);
        assertEq(shares2, mintedShares, "lp2 was minted at the price after the result, not before");
        vm.prank(lp);
        assertEq(vault.claim(house), assetsOut, "lp's withdrawal took Tuesday's result with it");

        // Tuesday's winners can still redeem while Wednesday trades: no deadline, and the rounds are apart
        // up 0.7%: band 21, the floor just above the previous close and HIGHER
        assertEq(settled.winners, uint16(1 << F4 | 1 << HIGHER));
        Ticket memory tuesdayToken = ticketsOf(hook, tuesday)[HIGHER];
        vm.prank(alice);
        assertEq(router.redeem(tuesdayToken.id, 4_000e18), 4_000e18);

        _buy(alice, LOWER, 9_000e18, tuesdayClose);
        _buy(bob, F6, 14_000e18, tuesdayClose * 1004 / 1000);
        _sell(bob, F6, 14_000e18, tuesdayClose * 1001 / 1000);
        _assertSupplies();
        _assertHookSolvent(address(chip));
        _closeAndFinalize(tuesdayClose * 985 / 1000);
        // (on the three strikes: HIGHER@15, LOWER@19, LOWER@23)
        assertEq(
            _state().winners, uint16(1 << F2 | 1 << LOWER), "down 1.5%: the floor from -1 to -0.5, LOWER"
        );

        // everybody collects everything from both days
        vm.prank(alice);
        router.redeem(tuesdayToken.id, 6_000e18);
        Ticket memory carolsToken = ticketsOf(hook, tuesday)[F4];
        Ticket memory alicesToken = ticketsOf(hook, wednesday)[LOWER];
        vm.prank(carol);
        router.redeem(carolsToken.id, 8_000e18);
        vm.prank(alice);
        router.redeem(alicesToken.id, 9_000e18);
        hook.collectProtocolFees(address(chip));
        vm.startPrank(lp);
        vault.requestWithdraw(house, vault.balanceOf(lp, uint256(house)));
        vm.stopPrank();
        // lp2's shares were minted by the queue; `settle` books them to its ledger entry
        assertEq(vault.balanceOf(lp2, uint256(house)), 0);
        vault.settle(house, lp2);
        assertEq(vault.balanceOf(lp2, uint256(house)), mintedShares);
        vm.startPrank(lp2);
        vault.requestWithdraw(house, mintedShares);
        vm.stopPrank();

        // bob's losing Tuesday tokens are the only supply left, worth nothing; every chip is accounted for
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, 0);
        assertEq(owed, 0);
        assertEq(chip.balanceOf(address(hook)), 0);
        assertEq(chip.balanceOf(address(router)), 0);
        assertEq(
            _sumOf([alice, bob, carol, lp, lp2, feeRecipient]) + chip.balanceOf(address(vault)),
            minted,
            "cash conservation over both days"
        );
        assertLe(chip.balanceOf(address(vault)), 2, "the vault keeps only its rounding dust");
        _assertVaultBacked(address(chip));
    }

    // --------------------------------------------------------------------------------------------
    // losing days: the endowment and the shares take their part pro rata
    // --------------------------------------------------------------------------------------------

    /// @dev The endowment is permanent capital, not a first-loss cushion: a
    ///      cushion can be farmed by an LP who bets against its own house. Every result is split pro rata
    ///      to capital at lock time.
    function test_losingDays_areSharedProRataByEndowmentAndShares() public {
        _donate(30_000e18);
        PitVault.House memory before = vault.getHouse(house);
        assertEq(before.endowment, 30_000e18);
        assertEq(before.lpAssets, HOUSE_CAPITAL);
        uint256 sent = HOUSE_CAPITAL + 30_000e18;

        // day 1: one buy at the per-fill cap of the floor from +1 to +2 sigma, and the stock closes 3% up:
        // it wins.
        _open();
        assertEq(hook.getConfig(roundId).capital, sent, "the endowment is in the round");
        uint256 cost = _buy(alice, F6, 20_000e18, S0);
        uint256 close1 = _grid(S0 * 103 / 100);
        _closeAndFinalize(close1);
        assertEq(_state().winners, uint16(1 << F6 | 1 << HIGHER));
        uint256 top = _token(F6).id;
        vm.prank(alice);
        assertEq(router.redeem(top, 20_000e18), 20_000e18, "the winner is paid in full");

        PitVault.House memory mid = vault.getHouse(house);
        uint256 back = mid.lpAssets + mid.endowment;
        uint256 loss1 = sent - back;
        emit log_named_decimal_uint("day 1 house loss", loss1, 18);
        assertGt(loss1, 10_000e18, "scenario: a real loss");
        assertEq(loss1, 20_000e18 - cost + _protocolFeesOf(roundId), "payout minus what the house kept");
        assertEq(mid.lpAssets, back.fullMulDiv(HOUSE_CAPITAL, sent), "the shares keep their fraction");
        assertEq(mid.endowment, back - mid.lpAssets, "the endowment has the rest");
        assertLt(mid.lpAssets, HOUSE_CAPITAL, "the shares took their part of the loss");
        assertLt(mid.endowment, 30_000e18, "and so did the endowment");
        // both lost the same fraction: about 1.7%
        assertApproxEqRel(mid.endowment * 1e18 / 30_000e18, mid.lpAssets * 1e18 / HOUSE_CAPITAL, 1e6);

        // day 2: three capped buys, a bigger loss; the split is again by capital at lock time
        day += 1;
        _open();
        uint256 cost2;
        for (uint256 i; i < 3; ++i) {
            cost2 += _buy(bob, F6, 20_000e18, close1);
        }
        _closeAndFinalize(close1 * 103 / 100);
        assertEq(_state().winners, uint16(1 << F6 | 1 << HIGHER));
        top = _token(F6).id;
        vm.prank(bob);
        assertEq(router.redeem(top, 60_000e18), 60_000e18);

        PitVault.House memory end = vault.getHouse(house);
        uint256 back2 = end.lpAssets + end.endowment;
        emit log_named_decimal_uint("day 2 house loss", back - back2, 18);
        assertGt(back - back2, mid.endowment, "scenario: a loss larger than the whole endowment");
        assertEq(end.lpAssets, back2.fullMulDiv(mid.lpAssets, back));
        assertEq(end.endowment, back2 - end.lpAssets);
        assertGt(end.endowment, 0, "the endowment is never used up ahead of the shares");

        // traders were paid one chip per winning token on both days; only the house lost
        assertEq(chip.balanceOf(alice), STAKE - cost + 20_000e18);
        assertEq(chip.balanceOf(bob), STAKE - cost2 + 60_000e18);
        _assertVaultBacked(address(chip));
    }

    function _protocolFeesOf(bytes32) internal view returns (uint256) {
        return hook.protocolFeesAccrued(address(chip));
    }

    // --------------------------------------------------------------------------------------------
    // void paths
    // --------------------------------------------------------------------------------------------

    function test_void_noCloseFor24Hours_refundsCostAndReturnsTheHouse() public {
        _open();
        uint256 aliceCost = _buy(alice, HIGHER, 10_000e18, S0);
        uint256 bobCost = _buy(bob, F5, 6_000e18, S0 * 1001 / 1000);
        uint256 aliceBack = _sell(alice, HIGHER, 4_000e18, S0 * 1001 / 1000);
        // a commit that is still pending when the round dies
        uint256 pending = _commitBuy(carol, F1, 1_000e18, 5_000e18);
        IFallpitHook.RoundState memory open = _state();

        // the oracle is down: no close. Nobody can void before 24 hours have passed.
        uint64 closeAt = NYTime.closeTs(day);
        _warp(closeAt + 24 hours);
        vm.expectRevert(IFallpitHook.VoidNotAllowed.selector);
        hook.voidRound(house, day);
        vm.expectRevert(IFallpitHook.CloseNotRecorded.selector);
        hook.settleRound(house, day);
        _warp(closeAt + 24 hours + 1);
        vm.prank(carol); // anyone
        hook.voidRound(house, day);

        IFallpitHook.RoundState memory voided = _state();
        assertEq(uint8(voided.status), uint8(IFallpitHook.Status.Void));
        (, uint256[12] memory premium) = hook.getSupplies(roundId);
        assertEq(voided.payoutOwed, premium[HIGHER] + premium[F5]);
        assertEq(premium[F5], bobCost, "bob's whole cost, fees included, is his refund");
        assertLe(premium[HIGHER], aliceCost - aliceBack, "alice's refund is at most her net cash in");

        // the house gets everything else back, never less than it brought, and is unlocked
        uint256 houseBack = chip.balanceOf(address(vault));
        assertEq(houseBack, open.held - voided.payoutOwed);
        assertGe(houseBack, HOUSE_CAPITAL);
        assertFalse(vault.isLocked(house));
        assertEq(hook.protocolFeesAccrued(address(chip)), 0, "a void round pays no protocol fee");

        // holders redeem their average cost; the pending commit refunds; nothing is left anywhere
        uint256 token5_3 = _token(F5).id;
        vm.prank(bob);
        assertEq(router.redeem(token5_3, 6_000e18), bobCost);
        uint256 token2_4 = _token(HIGHER).id;
        vm.prank(alice);
        uint256 aliceRefund = router.redeem(token2_4, 6_000e18);
        assertEq(aliceRefund, premium[HIGHER]);
        router.refund(pending);
        assertEq(chip.balanceOf(bob), STAKE, "bob is whole");
        assertEq(chip.balanceOf(carol), STAKE);
        assertEq(chip.balanceOf(alice) + houseBack, STAKE + HOUSE_CAPITAL, "what alice lost, the house kept");
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, 0);
        assertEq(owed, 0);
        assertEq(chip.balanceOf(address(hook)), 0);

        // Nobody opened Wednesday's round from 04:00 on (which would have voided Tuesday's round then),
        // and the void by the 24 hour rule comes after Wednesday's cutoff, so the
        // house sat out Wednesday. Thursday's round waits for Wednesday's close, which is not missed yet.
        vm.expectRevert(IFallpitHook.TooLate.selector);
        hook.openRound(NVDA, address(chip), day + 1);
        vm.expectRevert(IPitBook.NotNextTradingDay.selector);
        hook.openRound(NVDA, address(chip), day + 2);
        day += 1;
        uint256 wednesdayClose = _grid(S0 * 1004 / 1000);
        _recordClose(wednesdayClose, KEEPER_SOURCE);
        day += 1;
        roundId = hook.openRound(NVDA, address(chip), day);
        assertEq(hook.getConfig(roundId).capital, houseBack);
        assertEq(hook.getConfig(roundId).s0, wednesdayClose, "from the newest close on the books");
    }

    /// @dev The guardian cannot void: it can only dispute a keeper close in the window,
    ///      which holds the rounds on it open for a correction until one hour after the close.
    function test_guardian_disputesOnlyInTheChallengeWindowOfAKeeperClose_neverVoids() public {
        _open();
        _buy(alice, HIGHER, 10_000e18, S0);
        _recordClose(S0 * 101 / 100, KEEPER_SOURCE);

        // not before the round is settled, and only the guardian afterwards
        vm.prank(guardian);
        vm.expectRevert(IPitBook.DisputeNotAllowed.selector);
        book.dispute(roundId);
        hook.settleRound(house, day);
        IFallpitHook.RoundState memory settled = _state();
        assertEq(settled.payoutOwed, 10_000e18, "alice would win 10,000");
        vm.prank(alice);
        vm.expectRevert(IPitBook.OnlyGuardian.selector);
        book.dispute(roundId);
        vm.prank(owner);
        vm.expectRevert(IPitBook.OnlyGuardian.selector);
        book.dispute(roundId);
        // nobody voids a settled round, the guardian included
        vm.prank(guardian);
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        hook.voidRound(house, day);

        uint256 snapshot = vm.snapshotState();
        // the window closes at the instant finalization opens (900 s by default)
        _warp(settled.settledAt + 900);
        vm.prank(guardian);
        vm.expectRevert(IPitBook.DisputeNotAllowed.selector);
        book.dispute(roundId);
        hook.finalizeRound(house, day);
        vm.revertToState(snapshot);

        // inside the window the guardian disputes: the round waits until one hour after the close, then
        // finalizes on the close (nobody replaced it), and alice is paid
        vm.warp(settled.settledAt + 899);
        vm.prank(guardian);
        book.dispute(roundId);
        vm.warp(settled.settledAt + 900);
        vm.expectRevert(IFallpitHook.ChallengeWindowOpen.selector);
        hook.finalizeRound(house, day);
        vm.warp(NYTime.closeTs(day) + 1 hours - 1);
        vm.expectRevert(IFallpitHook.ChallengeWindowOpen.selector);
        hook.finalizeRound(house, day);
        vm.warp(NYTime.closeTs(day) + 1 hours);
        hook.finalizeRound(house, day);
        uint256 higher = _token(HIGHER).id;
        vm.prank(alice);
        assertEq(router.redeem(higher, 10_000e18), 10_000e18, "the win, not her cost");
    }

    function test_void_neverAfterATrustlessClose() public {
        _open();
        _buy(alice, HIGHER, 10_000e18, S0);
        _recordClose(S0 * 101 / 100, PYTH_SOURCE);
        hook.settleRound(house, day);
        vm.prank(guardian);
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        hook.voidRound(house, day);
        vm.prank(guardian);
        vm.expectRevert(IPitBook.DisputeNotAllowed.selector);
        book.dispute(roundId);
        // not even after the 24 hours that would void a round without a close
        _warp(NYTime.closeTs(day) + 24 hours + 1);
        vm.prank(guardian);
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        hook.voidRound(house, day);
        hook.finalizeRound(house, day);
        assertEq(uint8(_state().status), uint8(IFallpitHook.Status.Final));
    }

    /// @dev A recorded close blocks the permissionless 24 hour void of a round nobody settled yet.
    function test_void_notOnceACloseIsRecorded_evenUnsettled() public {
        _open();
        _buy(alice, HIGHER, 10_000e18, S0);
        _recordClose(S0 * 101 / 100, KEEPER_SOURCE);
        _warp(NYTime.closeTs(day) + 24 hours + 1);
        vm.expectRevert(IFallpitHook.VoidNotAllowed.selector);
        hook.voidRound(house, day);
        hook.settleRound(house, day);
    }

    function test_void_afterTheVoid_pendingAndLateFillsRefund() public {
        _open();
        _buy(alice, HIGHER, 10_000e18, S0);
        _warp(hook.getConfig(roundId).cutoff - 10);
        uint256 buyId = _commitBuy(bob, LOWER, 1_000e18, 5_000e18);
        uint256 sellId = _commitSell(alice, HIGHER, 2_000e18, 0);
        // nobody fills them and no close arrives
        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        // their fill windows are long gone: only the time refund is left, and it returns the escrow
        vm.expectRevert(IFallpitRouter.FillWindowClosed.selector);
        router.fill(buyId, "");
        router.refund(buyId);
        router.refund(sellId);
        assertEq(chip.balanceOf(bob), STAKE);
        assertEq(_token(HIGHER).balanceOf(alice), 10_000e18, "the escrowed tokens are back and still redeem");
        (, uint256[12] memory premium) = hook.getSupplies(roundId);
        uint256 token2_6 = _token(HIGHER).id;
        vm.prank(alice);
        assertEq(router.redeem(token2_6, 10_000e18), premium[HIGHER]);
        assertEq(chip.balanceOf(alice), STAKE);
    }

    // --------------------------------------------------------------------------------------------
    // fill source policy, with both oracle sources live for both tickers
    // --------------------------------------------------------------------------------------------

    function test_fillSource_keeperOnlyRound_rejectsAValidPythPrint() public {
        _open();
        uint256 id = _commitBuy(alice, HIGHER, 5_000e18, STAKE);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t);
        // both prints are the genuine print of their source for t, at different prices
        bytes memory pythPrint = _pythPrint(NVDA, S0 * 99 / 100, t);
        bytes memory keeperPrint = _keeperPrint(NVDA, S0, t);
        (uint256 viaPyth,, bool trustless) = oracle.verifyAt(NVDA, t, pythPrint);
        assertEq(viaPyth, S0 * 99 / 100);
        assertTrue(trustless);

        // the cheaper Pyth print is not the print of a KeeperOnly round: a revert, not a refund
        assertEq(_fillReverts(id, pythPrint), IFallpitHook.WrongFillSource.selector);
        (uint256 quoted,,,,,) = lens.quote(roundId, HIGHER, true, 5_000e18, S0, t);
        vm.prank(keeper);
        assertTrue(router.fill(id, keeperPrint));
        assertEq(STAKE - chip.balanceOf(alice), quoted, "filled at the keeper print's price");
    }

    function test_fillSource_trustlessOnlyRound_rejectsAValidKeeperPrint() public {
        _use(TSLA, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        _open();
        uint256 id = _commitBuy(alice, HIGHER, 5_000e18, STAKE);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t);
        bytes memory keeperPrint = _keeperPrint(TSLA, TSLA_S0 * 995 / 1000, t);
        bytes memory pythPrint = _pythPrint(TSLA, TSLA_S0, t);
        (uint256 viaKeeper,, bool trustless) = oracle.verifyAt(TSLA, t, keeperPrint);
        assertEq(viaKeeper, _grid(TSLA_S0 * 995 / 1000));
        assertFalse(trustless);

        assertEq(_fillReverts(id, keeperPrint), IFallpitHook.WrongFillSource.selector);
        (uint256 quoted,,,,,) = lens.quote(roundId, HIGHER, true, 5_000e18, TSLA_S0, t);
        vm.prank(keeper);
        assertTrue(router.fill(id, pythPrint));
        assertEq(STAKE - chip.balanceOf(alice), quoted, "filled at the Pyth price");
    }

    function test_fillSource_doesNotPinTheClose_trustlessReplacesKeeper() public {
        _use(TSLA, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        _open();
        _buy(alice, HIGHER, 10_000e18, TSLA_S0); // HIGHER at the previous close
        _buy(bob, LOWER, 10_000e18, TSLA_S0); // LOWER at the previous close

        // the keeper records the close first, just above the strike: alice wins
        _recordClose(TSLA_S0 * 1001 / 1000, KEEPER_SOURCE);
        hook.settleRound(house, day);
        assertEq(_state().winners >> HIGHER & 1, 1, "HIGHER wins on the keeper's close");
        // a second keeper print cannot replace it
        uint64 closeAt = NYTime.closeTs(day);
        bytes memory other = _signedPrint(TSLA, _grid(TSLA_S0 * 1002 / 1000), closeAt, closeAt - 1);
        vm.expectRevert(IPitBook.ReplacementRefused.selector);
        book.recordClose(TSLA, day, other);

        // the Pyth print for 16:00:00 says just below the strike: it replaces the keeper's close
        _recordClose(TSLA_S0 * 9995 / 10_000, PYTH_SOURCE);
        vm.expectRevert(IFallpitHook.CloseChanged.selector);
        hook.finalizeRound(house, day);
        hook.settleRound(house, day);
        assertEq(_state().winners >> LOWER & 1, 1, "LOWER wins on the trustless close");
        assertEq(_state().winners >> HIGHER & 1, 0);
        // nothing replaces a trustless close, and it finalizes without a challenge window
        vm.expectRevert(IPitBook.CloseIsFinal.selector);
        book.recordClose(TSLA, day, other);
        hook.finalizeRound(house, day);
        uint256 token3_7 = _token(LOWER).id;
        vm.prank(bob);
        assertEq(router.redeem(token3_7, 10_000e18), 10_000e18);
        uint256 loser = _token(HIGHER).id;
        vm.prank(alice);
        vm.expectRevert(IFallpitHook.NotWinner.selector);
        router.redeem(loser, 10_000e18);
    }

    // --------------------------------------------------------------------------------------------
    // launchpad fees into a house, then a round that uses them
    // --------------------------------------------------------------------------------------------

    function test_communityFees_harvestedIntoTheHouse_thenARoundUsesThem() public {
        bytes32 pool = keccak256("CHIP/NVDA launch pool");
        MockFeesManager fees = new MockFeesManager(false);
        MockChip stock = new MockChip(18);
        address creator = makeAddr("creator");
        address protocolSide = makeAddr("protocolSide");
        {
            address[] memory who = new address[](2);
            uint96[] memory shares = new uint96[](2);
            (who[0], who[1]) = (creator, protocolSide);
            (shares[0], shares[1]) = (0.95e18, 0.05e18);
            fees.initPool(pool, address(chip), address(stock), who, shares);
        }
        // the coin's creator points its 95% of the pool's fees at the house's inbox
        address inbox = treasury.inboxOf(house);
        vm.prank(creator);
        fees.updateBeneficiary(pool, inbox);

        // trading on the launchpad accrues 40,000 chips and 3 stock tokens of fees
        address trader = makeAddr("trader");
        chip.mint(trader, 40_000e18);
        stock.mint(trader, 3e18);
        vm.startPrank(trader);
        chip.approve(address(fees), 40_000e18);
        stock.approve(address(fees), 3e18);
        fees.accrue(pool, 40_000e18, 3e18);
        vm.stopPrank();

        // anyone harvests: the chip leg becomes endowment, the other leg stays in the inbox
        vm.prank(carol);
        (uint256 donated, uint256 otherHeld) = treasury.harvest(address(fees), pool, house);
        assertEq(donated, 38_000e18);
        assertEq(otherHeld, 2.85e18);
        assertEq(stock.balanceOf(inbox), 2.85e18);
        PitVault.House memory h = vault.getHouse(house);
        assertEq(h.endowment, 38_000e18);
        assertEq(h.lpAssets, HOUSE_CAPITAL, "a donation mints no shares and moves no share price");

        // the next round runs on the bigger house: more capital, deeper book
        _open();
        IFallpitHook.RoundConfig memory cfg = hook.getConfig(roundId);
        assertEq(cfg.capital, HOUSE_CAPITAL + 38_000e18);
        assertEq(cfg.maxFill, (HOUSE_CAPITAL + 38_000e18) * 200 / 10_000);
        uint256 cost = _buy(alice, F6, 20_000e18, S0);

        // fees harvested while the round runs wait for its result and take no part in it
        chip.mint(trader, 10_000e18);
        vm.startPrank(trader);
        chip.approve(address(fees), 10_000e18);
        fees.accrue(pool, 10_000e18, 0);
        vm.stopPrank();
        (donated,) = treasury.harvest(address(fees), pool, house);
        assertEq(donated, 9_500e18);
        assertEq(vault.getHouse(house).pendingDonations, 9_500e18);

        // a losing day (the floor alice holds wins): the community's fees carry their share of it, pro rata
        _closeAndFinalize(S0 * 103 / 100);
        uint256 top = _token(F6).id;
        vm.prank(alice);
        router.redeem(top, 20_000e18);
        h = vault.getHouse(house);
        uint256 loss = 20_000e18 - cost + hook.protocolFeesAccrued(address(chip));
        uint256 back = HOUSE_CAPITAL + 38_000e18 - loss;
        assertEq(h.lpAssets, back.fullMulDiv(HOUSE_CAPITAL, HOUSE_CAPITAL + 38_000e18));
        assertEq(h.endowment, back - h.lpAssets + 9_500e18, "its share of the loss, then the queued donation");
        assertLt(h.lpAssets, HOUSE_CAPITAL);
        assertGt(h.lpAssets, HOUSE_CAPITAL - loss, "the LP lost less than it would have alone");
        _assertVaultBacked(address(chip));
    }
}
