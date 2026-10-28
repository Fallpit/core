// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PitVault} from "../../src/PitVault.sol";
import {ITickerGate} from "../../src/interfaces/IPitVault.sol";
import {ChipGuard} from "../../src/ChipGuard.sol";
import {VaultBase} from "./VaultBase.sol";
import {MockChip, MockFeeChip, ReentrantChip} from "./mocks/MockChip.sol";

contract PitVaultTest is VaultBase {
    // ---------------------------------------------------------------------------------------------
    // Houses
    // ---------------------------------------------------------------------------------------------

    function test_houseId_matchesSpec() public view {
        assertEq(vault.houseId(NVDA, address(chip)), keccak256(abi.encode(NVDA, address(chip))));
        assertEq(house, keccak256(abi.encode(bytes32("NVDA"), address(chip))));
    }

    function test_createHouse_onlyTheListerAndOnce() public {
        vm.prank(dave);
        vm.expectRevert(PitVault.OnlyLister.selector);
        vault.createHouse(TSLA, address(chip));
        bytes32 h = vault.createHouse(TSLA, address(chip)); // this test is the vault's lister
        PitVault.House memory s = _h(h);
        assertEq(s.ticker, TSLA);
        assertEq(s.chip, address(chip));
        assertEq(vault.chipOf(h), address(chip));
        vm.expectRevert(PitVault.HouseExists.selector);
        vault.createHouse(TSLA, address(chip));
    }

    function test_createHouse_requiresAllowedChipAndSupportedTicker() public {
        MockChip stranger = new MockChip("Stranger", "STR", 18);
        vm.expectRevert(PitVault.ChipNotAllowed.selector);
        vault.createHouse(NVDA, address(stranger));

        vm.expectRevert(PitVault.TickerNotSupported.selector);
        vault.createHouse(bytes32("NOPE"), address(chip));

        vm.prank(guardOwner);
        guard.refuse(address(chip), true);
        vm.expectRevert(PitVault.ChipNotAllowed.selector);
        vault.createHouse(TSLA, address(chip));
    }

    function test_unknownHouse_reverts() public {
        bytes32 nope = keccak256("nope");
        vm.startPrank(alice);
        vm.expectRevert(PitVault.UnknownHouse.selector);
        vault.deposit(nope, 1e18);
        vm.expectRevert(PitVault.UnknownHouse.selector);
        vault.requestWithdraw(nope, 1);
        vm.expectRevert(PitVault.UnknownHouse.selector);
        vault.claim(nope);
        vm.expectRevert(PitVault.UnknownHouse.selector);
        vault.donate(nope, 1e18);
        vm.stopPrank();
        vm.prank(address(hook));
        vm.expectRevert(PitVault.UnknownHouse.selector);
        vault.pullRoundCapital(nope, address(hook));
        assertEq(vault.roundCapital(nope), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Deposit, withdraw, queue ordering
    // ---------------------------------------------------------------------------------------------

    function test_deposit_and_withdraw_whenUnlocked_executeNow() public {
        uint256 shares = _deposit(alice, house, 100e18);
        assertEq(shares, 100e18 * V);
        assertEq(_shares(alice, house), shares);
        assertEq(vault.totalSupply(uint256(house)), shares);
        assertEq(_h(house).lpAssets, 100e18);
        assertEq(vault.roundCapital(house), 100e18);
        _assertBooks(chip, house);

        uint256 before = chip.balanceOf(alice);
        uint256 assets = _withdraw(alice, house, shares / 4);
        assertEq(assets, 25e18);
        assertEq(chip.balanceOf(alice) - before, 25e18);
        assertEq(_h(house).lpAssets, 75e18);
        _assertBooks(chip, house);

        vm.prank(alice);
        vm.expectRevert(PitVault.InsufficientShares.selector);
        vault.requestWithdraw(house, shares);
        vm.prank(alice);
        vm.expectRevert(PitVault.ZeroAmount.selector);
        vault.requestWithdraw(house, 0);
        vm.prank(alice);
        vm.expectRevert(PitVault.ZeroAmount.selector);
        vault.deposit(house, 0);
        vm.prank(alice);
        vm.expectRevert(PitVault.NothingToClaim.selector);
        vault.claim(house);
    }

    function test_queue_executesAtNextPull_atThePriceAfterTheRound() public {
        _deposit(alice, house, 100e18);
        uint256 bobShares = _deposit(bob, house, 100e18);
        assertEq(hook.pull(house), 200e18);
        assertTrue(vault.isLocked(house));
        assertEq(vault.roundCapital(house), 0);

        // While locked: a deposit and a withdrawal both wait.
        assertEq(_deposit(carol, house, 50e18), 0);
        assertEq(_shares(carol, house), 0);
        assertEq(_withdraw(bob, house, bobShares), 0);
        assertEq(_shares(bob, house), 0);
        assertEq(_shares(address(vault), house), bobShares, "queued shares are held by the vault");
        assertEq(vault.totalSupply(uint256(house)), 200e18 * V, "queued shares still count");
        (, uint256 queuedAssets,,) = vault.positionOf(house, carol);
        (,, uint256 queuedShares,) = vault.positionOf(house, bob);
        assertEq(queuedAssets, 50e18);
        assertEq(queuedShares, bobShares);
        _assertBooks(chip, house);

        // The round wins 10%.
        _finish(house, chip, 220e18);
        assertFalse(vault.isLocked(house));
        assertEq(_h(house).lpAssets, 220e18);

        // Price after the result: both queue entries use it.
        uint256 bobExpected = bobShares * (220e18 + 1) / (200e18 * V + V);
        uint256 carolExpected = uint256(50e18) * (200e18 * V + V) / (220e18 + 1);
        assertEq(vault.roundCapital(house), 220e18 - bobExpected + 50e18);

        uint256 sent = hook.pull(house);
        assertEq(sent, 220e18 - bobExpected + 50e18, "next round gets capital after the queues");

        (uint256 carolShares,,,) = vault.positionOf(house, carol);
        (,,, uint256 bobClaimable) = vault.positionOf(house, bob);
        assertEq(carolShares, carolExpected);
        assertEq(bobClaimable, bobExpected);
        assertApproxEqAbs(bobExpected, 110e18, 1e6, "bob took the round's result with him");

        uint256 before = chip.balanceOf(bob);
        assertEq(_claim(bob, house), bobExpected);
        assertEq(chip.balanceOf(bob) - before, bobExpected);
        vm.prank(bob);
        vm.expectRevert(PitVault.NothingToClaim.selector);
        vault.claim(house);

        vault.settle(house, carol);
        assertEq(_shares(carol, house), carolExpected);
        assertEq(_shares(address(vault), house), 0);
        assertEq(_shares(alice, house) + _shares(carol, house), vault.totalSupply(uint256(house)));
        _assertBooks(chip, house);
    }

    function test_queue_processedOnFirstTouchAfterUnlock_withoutANextRound() public {
        uint256 aliceShares = _deposit(alice, house, 100e18);
        hook.pull(house);
        _deposit(bob, house, 40e18);
        _withdraw(alice, house, aliceShares);
        _finish(house, chip, 100e18);

        // No next round opens. Anyone can process the queue; the LPs are not stuck.
        vm.prank(dave);
        vault.processQueues(house);
        assertEq(_claim(alice, house), 100e18);
        vault.settle(house, bob);
        assertEq(_shares(bob, house), 40e18 * V);
        assertEq(_withdraw(bob, house, 40e18 * V), 40e18);
        assertEq(vault.accounted(address(chip)), 0);
        assertEq(chip.balanceOf(address(vault)), 0);
    }

    function test_queue_claimAloneProcessesAndPays() public {
        uint256 aliceShares = _deposit(alice, house, 100e18);
        hook.pull(house);
        _withdraw(alice, house, aliceShares);
        _finish(house, chip, 90e18);
        assertEq(_claim(alice, house), 90e18);
    }

    function test_queue_repeatedRequestsInOneRoundAddUp_andOldOnesSettleFirst() public {
        uint256 aliceShares = _deposit(alice, house, 100e18);
        hook.pull(house);
        _deposit(bob, house, 10e18);
        _deposit(bob, house, 5e18);
        _withdraw(alice, house, aliceShares / 4);
        _withdraw(alice, house, aliceShares / 4);
        (, uint256 queuedAssets,,) = vault.positionOf(house, bob);
        (,, uint256 queuedShares,) = vault.positionOf(house, alice);
        assertEq(queuedAssets, 15e18);
        assertEq(queuedShares, aliceShares / 2);
        _finish(house, chip, 100e18);

        // Next round: the old entries are processed at pull, new ones join the new queue.
        hook.pull(house);
        _deposit(bob, house, 7e18);
        _withdraw(alice, house, aliceShares / 2);
        assertEq(_shares(bob, house), 15e18 * V, "first deposit settled when the second was queued");
        (,,, uint256 claimable) = vault.positionOf(house, alice);
        assertEq(claimable, 50e18);
        _finish(house, chip, 65e18);
        assertEq(_claim(alice, house), 100e18);
        vault.settle(house, bob);
        assertEq(_shares(bob, house), 22e18 * V);
    }

    function test_cancelDeposit_onlyWhileQueued() public {
        _deposit(alice, house, 100e18);
        vm.prank(bob);
        vm.expectRevert(PitVault.NothingToCancel.selector);
        vault.cancelDeposit(house);

        hook.pull(house);
        _deposit(bob, house, 30e18);
        uint256 before = chip.balanceOf(bob);
        vm.prank(bob);
        assertEq(vault.cancelDeposit(house), 30e18);
        assertEq(chip.balanceOf(bob) - before, 30e18);
        assertEq(_h(house).pendingDeposits, 0);
        _assertBooks(chip, house);

        _deposit(bob, house, 30e18);
        _finish(house, chip, 100e18);
        vm.prank(bob);
        vm.expectRevert(PitVault.NothingToCancel.selector);
        vault.cancelDeposit(house);
    }

    // ---------------------------------------------------------------------------------------------
    // Share price across rounds
    // ---------------------------------------------------------------------------------------------

    function test_sharePrice_acrossWinningAndLosingRounds() public {
        uint256 aliceShares = _deposit(alice, house, 100e18);
        assertEq(vault.convertToAssets(house, aliceShares), 100e18);

        _round(house, chip, 120e18); // +20%
        assertApproxEqAbs(vault.convertToAssets(house, aliceShares), 120e18, 1);

        // Bob joins after the win at the new price: he gets fewer shares per chip.
        uint256 bobShares = _deposit(bob, house, 120e18);
        assertApproxEqRel(bobShares, aliceShares, 1e6);
        assertApproxEqAbs(vault.convertToAssets(house, bobShares), 120e18, 1);

        _round(house, chip, 180e18); // -25%
        assertApproxEqAbs(vault.convertToAssets(house, aliceShares), 90e18, 1);
        assertApproxEqAbs(vault.convertToAssets(house, bobShares), 90e18, 1);

        uint256 a = _withdraw(alice, house, aliceShares);
        uint256 b = _withdraw(bob, house, bobShares);
        assertApproxEqAbs(a, 90e18, 1);
        assertApproxEqAbs(b, 90e18, 1);
        assertLe(a + b, 180e18);
        _assertBooks(chip, house);
    }

    // ---------------------------------------------------------------------------------------------
    // Endowment waterfall
    // ---------------------------------------------------------------------------------------------

    /// @dev Profits and losses are both shared pro rata to capital at lock time. A loss that reduced the
    ///      endowment before the shares would let an LP who bets against its own house keep the win and
    ///      get most of a lost bet back, at the endowment's expense.
    function test_endowment_sharesProfitsAndLossesProRata() public {
        _donate(dave, house, 50e18);
        uint256 aliceShares = _deposit(alice, house, 100e18);
        assertEq(_h(house).endowment, 50e18);
        assertEq(vault.totalSupply(uint256(house)), aliceShares, "a donation mints no shares");
        assertEq(vault.convertToAssets(house, aliceShares), 100e18, "a donation moves no share price");

        // A loss of 30 on 150: each side loses a fifth (100 : 50).
        assertEq(_round(house, chip, 120e18), 150e18);
        assertEq(_h(house).lpAssets, 80e18);
        assertEq(_h(house).endowment, 40e18);

        // Another loss of 30, now on 120: each side loses a quarter (80 : 40).
        assertEq(_round(house, chip, 90e18), 120e18);
        assertEq(_h(house).lpAssets, 60e18);
        assertEq(_h(house).endowment, 30e18);

        // A profit of 9 on 90 (60 : 30): both gain 10%.
        _round(house, chip, 99e18);
        assertEq(_h(house).lpAssets, 66e18);
        assertEq(_h(house).endowment, 33e18);

        // After another donation the split follows the new capital at lock time (66 : 44).
        _donate(dave, house, 11e18);
        assertEq(_round(house, chip, 121e18), 110e18);
        assertEq(_h(house).lpAssets, 66e18 + 6.6e18);
        assertEq(_h(house).endowment, 44e18 + 4.4e18);

        // A total loss takes both to zero; nothing is owed by anyone.
        _round(house, chip, 0);
        assertEq(_h(house).lpAssets, 0);
        assertEq(_h(house).endowment, 0);
        _assertBooks(chip, house);
    }

    function test_endowment_canNeverBeWithdrawn() public {
        _donate(dave, house, 50e18);
        uint256 aliceShares = _deposit(alice, house, 100e18);
        _round(house, chip, 165e18); // +10% for both

        uint256 out = _withdraw(alice, house, aliceShares);
        assertApproxEqAbs(out, 110e18, 1);
        assertEq(_h(house).endowment, 55e18);
        assertEq(vault.totalSupply(uint256(house)), 0);
        assertGe(chip.balanceOf(address(vault)), 55e18, "the endowment stays");

        // The donor has no shares and no claim.
        assertEq(_shares(dave, house), 0);
        vm.prank(dave);
        vm.expectRevert(PitVault.InsufficientShares.selector);
        vault.requestWithdraw(house, 1);
        vm.prank(dave);
        vm.expectRevert(PitVault.NothingToClaim.selector);
        vault.claim(house);

        // An endowment-only house still plays rounds.
        uint256 dust = _h(house).lpAssets;
        assertLe(dust, 1);
        assertEq(vault.roundCapital(house), 55e18 + dust);
        _round(house, chip, 60e18);
        assertEq(_h(house).lpAssets, 0, "capital no share can claim joins the endowment");
        assertEq(_h(house).endowment, 60e18);
        _assertBooks(chip, house);
    }

    function test_donate_whileLocked_joinsAfterTheRound_andTakesNoPartInIt() public {
        _deposit(alice, house, 100e18);
        hook.pull(house);
        _donate(dave, house, 50e18);
        assertEq(_h(house).endowment, 0);
        assertEq(_h(house).pendingDonations, 50e18);
        _assertBooks(chip, house);

        // The round loses 10: the queued donation absorbs none of it.
        _finish(house, chip, 90e18);
        assertEq(_h(house).lpAssets, 90e18);
        assertEq(_h(house).endowment, 50e18);
        assertEq(_h(house).pendingDonations, 0);
        _assertBooks(chip, house);
    }

    // ---------------------------------------------------------------------------------------------
    // Just-in-time deposits and withdrawals
    // ---------------------------------------------------------------------------------------------

    function test_justInTimeDeposit_cannotCaptureALockedRoundsResult() public {
        _deposit(alice, house, 100e18);
        hook.pull(house);

        // Carol sees the round is going to win big and piles in before it ends.
        _deposit(carol, house, 100e18);
        _finish(house, chip, 200e18); // the house doubles

        vault.processQueues(house);
        vault.settle(house, carol);
        uint256 carolOut = _withdraw(carol, house, _shares(carol, house));
        assertLe(carolOut, 100e18, "no profit from the locked round");
        assertGe(carolOut, 100e18 - 2);
        assertApproxEqAbs(
            _withdraw(alice, house, _shares(alice, house)), 200e18, 2, "alice keeps the whole win"
        );
    }

    function test_justInTimeWithdraw_cannotDodgeALockedRoundsResult() public {
        uint256 aliceShares = _deposit(alice, house, 100e18);
        uint256 bobShares = _deposit(bob, house, 100e18);
        hook.pull(house);

        // Bob sees the round is going to lose and asks out before it ends.
        _withdraw(bob, house, bobShares);
        _finish(house, chip, 100e18); // the house halves

        assertApproxEqAbs(_claim(bob, house), 50e18, 1, "bob bears his half of the loss");
        assertApproxEqAbs(_withdraw(alice, house, aliceShares), 50e18, 1);
        _assertBooks(chip, house);
    }

    function test_transferWhileLocked_sharesStillBearTheResult() public {
        uint256 aliceShares = _deposit(alice, house, 100e18);
        hook.pull(house);
        vm.prank(alice);
        vault.transfer(bob, uint256(house), aliceShares);
        _finish(house, chip, 80e18);
        assertEq(_withdraw(bob, house, aliceShares), 80e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Fee-on-transfer chip (1% tax): not a chip
    // ---------------------------------------------------------------------------------------------

    /// @dev A chip the guard has flagged gets no house at all.
    function test_feeOnTransferChip_flagged_cannotOpenAHouse() public {
        MockFeeChip flagged = new MockFeeChip();
        vm.startPrank(guardOwner);
        guard.approve(address(flagged), true);
        guard.setFeeOnTransfer(address(flagged), true);
        vm.stopPrank();
        (bool allowed, bool isFlagged) = guard.check(address(flagged));
        assertFalse(allowed);
        assertTrue(isFlagged);
        vm.expectRevert(PitVault.ChipNotAllowed.selector);
        vault.createHouse(TSLA, address(flagged));

        // unflagged it is an ordinary approved coin again
        vm.prank(guardOwner);
        guard.setFeeOnTransfer(address(flagged), false);
        vault.createHouse(TSLA, address(flagged));
    }

    /// @dev A tax chip the guard does not know about has a house (`taxHouse`), and still cannot fund it:
    ///      a deposit or a donation that arrives short reverts, and nothing is booked.
    function test_feeOnTransferChip_unflagged_cannotDepositOrDonate() public {
        (bool allowed, bool flagged) = guard.check(address(taxChip));
        assertTrue(allowed);
        assertFalse(flagged);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PitVault.InexactTransfer.selector, 100e18, 99e18));
        vault.deposit(taxHouse, 100e18);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(PitVault.InexactTransfer.selector, 10e18, 9.9e18));
        vault.donate(taxHouse, 10e18);
        // one unit: the tax rounds to zero and the unit arrives whole, which is exact
        assertEq(_deposit(alice, taxHouse, 1), V);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PitVault.InexactTransfer.selector, 100, 99));
        vault.deposit(taxHouse, 100);

        assertEq(_h(taxHouse).lpAssets, 1);
        assertEq(_h(taxHouse).endowment, 0);
        assertEq(vault.accounted(address(taxChip)), 1);
        assertEq(taxChip.balanceOf(address(vault)), 1);
        assertEq(taxChip.balanceOf(alice), 1_000_000e18 - 1, "a refused deposit takes nothing");
        assertEq(taxChip.balanceOf(dave), 1_000_000e18);

        // a queued deposit into a locked house is refused the same way
        hook.pull(taxHouse);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PitVault.InexactTransfer.selector, 50e18, 49.5e18));
        vault.deposit(taxHouse, 50e18);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(PitVault.InexactTransfer.selector, 10e18, 9.9e18));
        vault.donate(taxHouse, 10e18);
    }

    /// @dev Defence in depth. A chip that starts to tax its transfers after its house was funded: every
    ///      inflow from then on is refused, every outflow is the nominal amount, a round's return is booked by what arrives, and the books never exceed the balance.
    function test_chipThatStartsToTaxLater_booksStayExact() public {
        taxChip.setTax(false);
        uint256 shares = _deposit(alice, taxHouse, 100e18);
        assertEq(shares, 100e18 * V);
        assertEq(_donate(dave, taxHouse, 10e18), 10e18);
        _assertBooks(taxChip, taxHouse);
        assertEq(taxChip.balanceOf(address(vault)), 110e18);

        taxChip.setTax(true);
        // Pull sends the nominal capital; the receiver measures what arrived.
        uint256 sent = hook.pull(taxHouse);
        assertEq(sent, 110e18);
        assertEq(taxChip.balanceOf(address(hook)), 110e18 * 99 / 100);
        assertEq(taxChip.balanceOf(address(vault)), 0);

        // The hook sends everything back; the vault books what arrives. The two taxes are a loss like any
        // other: shared pro rata between the shares and the endowment.
        uint256 back = taxChip.balanceOf(address(hook));
        uint256 received = hook.giveBack(taxHouse, address(taxChip), back);
        assertEq(received, back * 99 / 100);
        uint256 lpAfter = received * 100e18 / sent;
        assertEq(_h(taxHouse).lpAssets, lpAfter);
        assertEq(_h(taxHouse).endowment, received - lpAfter);
        assertLt(lpAfter, 100e18);
        assertLt(received - lpAfter, 10e18);
        _assertBooks(taxChip, taxHouse);
        assertEq(taxChip.balanceOf(address(vault)), vault.accounted(address(taxChip)));

        // While locked: a new deposit is refused, a withdrawal queues and is paid the nominal amount.
        hook.pull(taxHouse);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PitVault.InexactTransfer.selector, 50e18, 49.5e18));
        vault.deposit(taxHouse, 50e18);
        _withdraw(alice, taxHouse, shares);
        back = taxChip.balanceOf(address(hook));
        hook.giveBack(taxHouse, address(taxChip), back);
        uint256 before = taxChip.balanceOf(alice);
        uint256 claimed = _claim(alice, taxHouse);
        assertEq(taxChip.balanceOf(alice) - before, claimed * 99 / 100);
        _assertBooks(taxChip, taxHouse);
        assertEq(taxChip.balanceOf(address(vault)), vault.accounted(address(taxChip)));
    }

    // ---------------------------------------------------------------------------------------------
    // Inflation attack and stray chips
    // ---------------------------------------------------------------------------------------------

    function test_inflationAttack_firstDepositorCannotGrief() public {
        // The attacker is first in with 1 unit, then tries to inflate the share price both ways it can
        // reach the vault: a plain transfer and a donation.
        uint256 attackerShares = _deposit(alice, house, 1);
        vm.prank(alice);
        chip.transfer(address(vault), 1000e18);
        _donate(alice, house, 1000e18);

        uint256 victimShares = _deposit(bob, house, 10e18);
        assertEq(victimShares, 10e18 * V, "the victim's mint is not rounded away");
        uint256 victimOut = _withdraw(bob, house, victimShares);
        assertGe(victimOut, 10e18 - 1);
        assertLe(_withdraw(alice, house, attackerShares), 1, "the attacker gets his unit back at most");
    }

    function testFuzz_inflationAttack_victimLosesAtMostDust(
        uint256 attackerIn,
        uint256 gift,
        uint256 victimIn
    ) public {
        attackerIn = bound(attackerIn, 1, 1e18);
        gift = bound(gift, 0, 400_000e18);
        victimIn = bound(victimIn, 1e6, 100_000e18);
        _deposit(alice, house, attackerIn);
        if (gift != 0) {
            vm.prank(alice);
            chip.transfer(address(vault), gift / 2 + 1);
            _donate(alice, house, gift / 2 + 1);
        }
        uint256 victimShares = _deposit(bob, house, victimIn);
        assertGe(_withdraw(bob, house, victimShares), victimIn - 1);
    }

    function test_strayChips_areNotCreditedToDepositors_andAreBookedByTheNextReturn() public {
        vm.prank(dave);
        chip.transfer(address(vault), 5e18);
        uint256 shares = _deposit(bob, house, 10e18);
        assertEq(shares, 10e18 * V);
        assertEq(vault.accounted(address(chip)), 10e18);
        assertEq(chip.balanceOf(address(vault)), 15e18);

        // The round itself is flat; the stray chips are booked as its result.
        uint256 sent = hook.pull(house);
        uint256 received = hook.giveBack(house, address(chip), sent);
        assertEq(received, 15e18);
        assertEq(_h(house).lpAssets, 15e18);
        _assertBooks(chip, house);
        assertEq(chip.balanceOf(address(vault)), vault.accounted(address(chip)));
    }

    // ---------------------------------------------------------------------------------------------
    // A round that returns nothing
    // ---------------------------------------------------------------------------------------------

    function test_roundReturnsZero_sharesStayValidAtPriceZero_nothingBricks() public {
        uint256 aliceShares = _deposit(alice, house, 100e18);
        uint256 bobShares = _deposit(bob, house, 100e18);
        hook.pull(house);
        assertEq(hook.giveBack(house, address(chip), 0), 0);

        // Shares are still there and price at 0.
        assertFalse(vault.isLocked(house));
        assertEq(_shares(alice, house), aliceShares);
        assertEq(vault.totalSupply(uint256(house)), aliceShares + bobShares);
        assertEq(vault.convertToAssets(house, aliceShares), 0);
        assertEq(vault.roundCapital(house), 0);

        // They still transfer and redeem (for nothing).
        vm.prank(alice);
        vault.transfer(carol, uint256(house), aliceShares / 2);
        assertEq(_withdraw(alice, house, aliceShares / 2), 0);

        // An empty house can even be pulled and returned again.
        assertEq(hook.pull(house), 0);
        assertEq(hook.giveBack(house, address(chip), 0), 0);

        // New capital starts a fresh supply at the opening price; the old shares are void.
        uint256 daveShares = _deposit(dave, house, 40e18);
        assertEq(daveShares, 40e18 * V);
        assertEq(vault.totalSupply(uint256(house)), daveShares);
        assertEq(_shares(bob, house), 0);
        assertEq(_shares(carol, house), 0);
        assertEq(_h(house).generation, 1);

        _round(house, chip, 44e18);
        assertApproxEqAbs(_withdraw(dave, house, daveShares), 44e18, 1);
        _assertBooks(chip, house);
    }

    function test_roundReturnsZero_withQueuedDepositAndWithdrawal() public {
        uint256 aliceShares = _deposit(alice, house, 100e18);
        _donate(dave, house, 20e18);
        hook.pull(house);
        _deposit(bob, house, 30e18);
        _withdraw(alice, house, aliceShares / 2);
        _donate(dave, house, 5e18);
        hook.giveBack(house, address(chip), 0);

        assertEq(_h(house).lpAssets, 0);
        assertEq(_h(house).endowment, 5e18, "only the donation queued during the round is left");
        assertEq(vault.roundCapital(house), 35e18);

        // The queue processes at price 0: the withdrawal pays nothing, the deposit starts a fresh supply.
        assertEq(hook.pull(house), 35e18);
        vm.prank(alice);
        vm.expectRevert(PitVault.NothingToClaim.selector);
        vault.claim(house);
        vault.settle(house, bob);
        assertEq(_shares(bob, house), 30e18 * V);
        assertEq(vault.totalSupply(uint256(house)), 30e18 * V);
        assertEq(_shares(alice, house), 0, "alice's remaining old shares are void");
        _finish(house, chip, 35e18);
        assertEq(_withdraw(bob, house, 30e18 * V), 30e18);
        _assertBooks(chip, house);
    }

    function test_roundReturnsDust_dustJoinsTheEndowment_andSupplyStaysBounded() public {
        _deposit(alice, house, 100e18);
        _round(house, chip, 1000); // 1000 units left of 100e18
        assertEq(_h(house).lpAssets, 0);
        assertEq(_h(house).endowment, 1000);

        // Repeat wipeouts many times: the share supply never grows past one fresh supply.
        for (uint256 i; i < 40; ++i) {
            uint256 shares = _deposit(bob, house, 100e18);
            assertEq(shares, 100e18 * V);
            _round(house, chip, i % 2 == 0 ? 0 : 7);
        }
        assertEq(_h(house).generation, 40);
        _assertBooks(chip, house);
    }

    function test_roundLosesAlmostEverything_butAboveTheDustFloor_sharesKeepTheirClaim() public {
        uint256 aliceShares = _deposit(alice, house, 100e18);
        _round(house, chip, 1e9); // price falls by 1e11, still above the 1e12 floor
        assertEq(_h(house).lpAssets, 1e9);
        assertEq(_h(house).generation, 0);
        uint256 bobShares = _deposit(bob, house, 1e9);
        assertApproxEqRel(bobShares, aliceShares, 1e10);
        assertApproxEqAbs(_withdraw(alice, house, aliceShares), 1e9, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Hook only
    // ---------------------------------------------------------------------------------------------

    function test_roundFunctions_onlyHook() public {
        _deposit(alice, house, 100e18);
        vm.prank(alice);
        vm.expectRevert(PitVault.OnlyHook.selector);
        vault.pullRoundCapital(house, alice);
        vm.prank(alice);
        vm.expectRevert(PitVault.OnlyHook.selector);
        vault.returnRoundCapital(house);

        vm.prank(address(hook));
        vm.expectRevert(PitVault.HouseNotLocked.selector);
        vault.returnRoundCapital(house);
        hook.pull(house);
        vm.prank(address(hook));
        vm.expectRevert(PitVault.HouseLocked.selector);
        vault.pullRoundCapital(house, address(hook));
        vm.expectRevert(PitVault.HouseLocked.selector);
        vault.processQueues(house);
    }

    function test_twoHousesOnOneChip_keepSeparateBooks() public {
        bytes32 tsla = vault.createHouse(TSLA, address(chip));
        _deposit(alice, house, 100e18);
        _deposit(bob, tsla, 60e18);
        hook.pull(house);
        // The NVDA house is out; the TSLA house is untouched and still liquid.
        assertEq(chip.balanceOf(address(vault)), 60e18);
        assertEq(_withdraw(bob, tsla, 10e18 * V), 10e18);
        _finish(house, chip, 130e18);
        assertEq(_h(house).lpAssets, 130e18);
        assertEq(_h(tsla).lpAssets, 50e18);
        assertEq(vault.heldFor(house) + vault.heldFor(tsla), vault.accounted(address(chip)));
        assertEq(chip.balanceOf(address(vault)), vault.accounted(address(chip)));
    }

    // ---------------------------------------------------------------------------------------------
    // Share ledger
    // ---------------------------------------------------------------------------------------------

    function test_ledger_transferApproveOperator() public {
        uint256 shares = _deposit(alice, house, 100e18);
        uint256 id = uint256(house);

        vm.prank(alice);
        assertTrue(vault.transfer(bob, id, shares / 4));
        assertEq(_shares(bob, house), shares / 4);

        vm.prank(carol);
        vm.expectRevert(PitVault.InsufficientPermission.selector);
        vault.transferFrom(alice, carol, id, 1);

        vm.prank(alice);
        vault.approve(carol, id, shares / 4);
        vm.prank(carol);
        vault.transferFrom(alice, carol, id, shares / 4);
        assertEq(vault.allowance(alice, carol, id), 0);
        assertEq(_shares(carol, house), shares / 4);

        vm.prank(alice);
        vault.setOperator(dave, true);
        vm.prank(dave);
        vault.transferFrom(alice, dave, id, shares / 4);
        assertEq(_shares(dave, house), shares / 4);
        assertEq(_shares(alice, house), shares / 4);

        vm.startPrank(alice);
        vm.expectRevert(PitVault.InsufficientShares.selector);
        vault.transfer(bob, id, shares);
        vm.expectRevert(PitVault.InvalidReceiver.selector);
        vault.transfer(address(0), id, 1);
        vm.expectRevert(PitVault.InvalidReceiver.selector);
        vault.transfer(address(vault), id, 1);
        vm.stopPrank();

        assertTrue(vault.supportsInterface(0x0f632fb3));
        assertTrue(vault.supportsInterface(0x01ffc9a7));
        assertFalse(vault.supportsInterface(0xffffffff));

        // Transferred shares redeem like any other.
        assertEq(_withdraw(bob, house, shares / 4), 25e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Reentrancy through a hostile chip
    // ---------------------------------------------------------------------------------------------

    function test_reentrancy_throughAHostileChip_isBlocked() public {
        ReentrantChip evil = new ReentrantChip();
        vm.prank(guardOwner);
        guard.approve(address(evil), true);
        bytes32 evilHouse = vault.createHouse(NVDA, address(evil));
        evil.mint(alice, 100e18);
        vm.startPrank(alice);
        evil.approve(address(vault), type(uint256).max);
        vault.deposit(evilHouse, 10e18);

        bytes[5] memory payloads = [
            abi.encodeCall(PitVault.deposit, (evilHouse, 1e18)),
            abi.encodeCall(PitVault.requestWithdraw, (evilHouse, 1)),
            abi.encodeCall(PitVault.claim, (evilHouse)),
            abi.encodeCall(PitVault.donate, (evilHouse, 1e18)),
            abi.encodeCall(PitVault.transfer, (bob, uint256(evilHouse), 1))
        ];
        bytes4 reentrancy = bytes4(keccak256("Reentrancy()"));
        for (uint256 i; i < payloads.length; ++i) {
            // The chip calls back in the middle of an inflow and of an outflow; every way in is shut.
            evil.arm(address(vault), payloads[i]);
            vault.deposit(evilHouse, 1e18);
            assertFalse(evil.reentered());
            assertEq(bytes4(evil.lastRevert()), reentrancy);
            evil.arm(address(vault), payloads[i]);
            vault.requestWithdraw(evilHouse, 1e18 * V);
            assertFalse(evil.reentered());
            assertEq(bytes4(evil.lastRevert()), reentrancy);
        }
        vm.stopPrank();
        assertEq(vault.getHouse(evilHouse).lpAssets, 10e18);
        assertEq(evil.balanceOf(address(vault)), 10e18);
        assertEq(vault.accounted(address(evil)), 10e18);

        // Same while the hook pulls the capital out.
        evil.arm(address(vault), abi.encodeCall(PitVault.deposit, (evilHouse, 1e18)));
        hook.pull(evilHouse);
        assertFalse(evil.reentered());
        assertEq(bytes4(evil.lastRevert()), reentrancy);
        hook.giveBack(evilHouse, address(evil), 10e18);
        assertEq(vault.getHouse(evilHouse).lpAssets, 10e18);
    }

    // ---------------------------------------------------------------------------------------------
    // No admin
    // ---------------------------------------------------------------------------------------------

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(PitVault.ZeroAddress.selector);
        new PitVault(address(0), guard, ITickerGate(address(oracle)));
        vm.expectRevert(PitVault.ZeroAddress.selector);
        new PitVault(address(hook), ChipGuard(address(0)), ITickerGate(address(oracle)));
    }

    function test_brokenBalanceRead_revertsInsteadOfBookingALoss() public {
        _deposit(alice, house, 100e18);
        hook.pull(house);
        // The chip's balanceOf fails for a while. Reading that as 0 would book a total loss for good.
        vm.mockCallRevert(
            address(chip), abi.encodeWithSignature("balanceOf(address)", address(vault)), "down"
        );
        vm.prank(address(hook));
        vm.expectRevert(PitVault.BalanceQueryFailed.selector);
        vault.returnRoundCapital(house);
        vm.clearMockedCalls();
        _finish(house, chip, 100e18);
        assertEq(_h(house).lpAssets, 100e18);
    }

    function test_guardOwner_cannotTouchHouseFunds() public {
        _deposit(alice, house, 100e18);
        _donate(dave, house, 50e18);
        // The only owner in the system is the guard's. Refusing the chip stops new houses, nothing else.
        vm.prank(guardOwner);
        guard.refuse(address(chip), true);
        assertEq(_withdraw(alice, house, 100e18 * V), 100e18);
        assertEq(_h(house).endowment, 50e18);
        vm.startPrank(guardOwner);
        vm.expectRevert(PitVault.OnlyHook.selector);
        vault.pullRoundCapital(house, guardOwner);
        vm.expectRevert(PitVault.InsufficientShares.selector);
        vault.requestWithdraw(house, 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    /// @dev Deposits and withdrawals alone never move the share price down, and never up by more than
    ///      rounding dust (less than one chip unit over the whole supply).
    function testFuzz_sharePrice_unmovedByDepositsAndWithdrawals(
        uint256 seedIn,
        uint256 back,
        uint256 amount,
        uint256 withdrawBps
    ) public {
        seedIn = bound(seedIn, 1, 100_000e18);
        back = bound(back, seedIn / 1000 + 1, seedIn * 3);
        amount = bound(amount, 1, 100_000e18);
        withdrawBps = bound(withdrawBps, 1, 10_000);
        _deposit(alice, house, seedIn);
        _round(house, chip, back); // any price

        PitVault.House memory a = _h(house);
        vm.prank(bob);
        try vault.deposit(house, amount) {}
        catch (bytes memory err) {
            assertEq(bytes4(err), PitVault.ZeroShares.selector);
            return;
        }
        PitVault.House memory b = _h(house);
        _assertPriceHeld(a, b);

        uint256 burn = _shares(bob, house) * withdrawBps / 10_000;
        if (burn == 0) return;
        _withdraw(bob, house, burn);
        _assertPriceHeld(b, _h(house));
    }

    /// @dev In and straight out never makes a profit, whatever the price.
    function testFuzz_depositThenWithdraw_neverProfits(uint256 seedIn, uint256 back, uint256 amount) public {
        seedIn = bound(seedIn, 1, 100_000e18);
        back = bound(back, 0, seedIn * 3);
        amount = bound(amount, 1, 100_000e18);
        _deposit(alice, house, seedIn);
        _donate(dave, house, seedIn / 3 + 1);
        _round(house, chip, back);
        vm.prank(bob);
        try vault.deposit(house, amount) returns (uint256 shares) {
            assertLe(_withdraw(bob, house, shares), amount);
        } catch (bytes memory err) {
            assertEq(bytes4(err), PitVault.ZeroShares.selector);
        }
        _assertBooks(chip, house);
    }

    /// @dev The waterfall: whatever comes
    ///      back is split pro rata to capital at lock time, the shares' part rounded down; books always
    ///      exact. The dust rule moves a wiped-out remainder to the endowment.
    function testFuzz_waterfall(uint256 lpIn, uint256 gift, uint256 back) public {
        lpIn = bound(lpIn, 1e6, 100_000e18);
        gift = bound(gift, 1, 100_000e18);
        back = bound(back, 0, (lpIn + gift) * 2);
        _deposit(alice, house, lpIn);
        _donate(dave, house, gift);
        uint256 sent = _round(house, chip, back);
        assertEq(sent, lpIn + gift);
        PitVault.House memory s = _h(house);
        uint256 lp = back * lpIn / sent;
        if (lp != 0 && s.totalShares / 1e18 > lp) lp = 0; // dust under a wiped-out supply
        assertEq(s.lpAssets, lp, "the shares keep their fraction of what came back");
        assertEq(s.endowment, back - lp, "the endowment has the rest");
        if (back < sent && lp != 0) {
            // a loss is never taken by one side alone: both shrink by the same factor, up to rounding
            assertLt(s.lpAssets, lpIn);
            assertLe(s.endowment, gift);
            assertApproxEqAbs(s.endowment * lpIn / gift, s.lpAssets, lpIn / gift + 2);
        }
        _assertBooks(chip, house);
    }

    function _assertPriceHeld(PitVault.House memory a, PitVault.House memory b) internal pure {
        // price = (lpAssets + 1) / (totalShares + 1e6); compare by cross-multiplying.
        uint256 left = (b.lpAssets + 1) * (a.totalShares + V);
        uint256 right = (a.lpAssets + 1) * (b.totalShares + V);
        assertGe(left, right, "price fell");
        uint256 slack = a.lpAssets + 1 > a.totalShares + V ? a.lpAssets + 1 : a.totalShares + V;
        assertLe(left - right, slack, "price rose by more than rounding dust");
    }
}
