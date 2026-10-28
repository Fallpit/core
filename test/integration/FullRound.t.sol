// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {MockChip, MockFeeChip} from "../hook/mocks/MockChips.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {PitVault} from "../../src/PitVault.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice Full rounds through the real contracts, on both oracle paths, with cash conservation to the
///         unit: open, buys and sells on every product of the menu (the eight floors and the pair), record
///         the close, settle, finalize, redeem, and the LP's withdrawal.
contract FullRoundTest is IntegrationFixture {
    uint256 internal constant STAKE = 100_000e18;

    /// @dev Buys and sells on every product of the menu by three users while the oracle drifts.
    function _tradeTheMenu(uint256 s0) internal {
        uint256 price = s0;
        for (uint8 i; i < PRODUCTS; ++i) {
            price = price * (1000 + i) / 1000;
            _buy(alice, i, 4_000e18 + uint256(i) * 100e18, price);
            _buy(bob, i, 2_500e18, price * 999 / 1000);
            _warp(clock + 600);
        }
        for (uint8 i; i < PRODUCTS; ++i) {
            price = price * 998 / 1000;
            _sell(alice, i, 1_000e18, price);
            _sell(bob, i, 2_500e18, price);
            _warp(clock + 300);
        }
        _buy(carol, HIGHER, 10_000e18, s0 * 1005 / 1000);
        _buy(carol, F5, 7_000e18, s0 * 1005 / 1000);
    }

    /// @dev Everybody redeems whatever wins; returns the chips paid.
    function _redeemAll(uint16 winners) internal returns (uint256 paid) {
        address[3] memory users = [alice, bob, carol];
        for (uint256 u; u < 3; ++u) {
            for (uint8 i; i < PRODUCTS; ++i) {
                Ticket memory token = _token(i);
                uint256 balance = token.balanceOf(users[u]);
                if (balance == 0) continue;
                vm.prank(users[u]);
                if (winners >> i & 1 == 0) {
                    vm.expectRevert(IFallpitHook.NotWinner.selector);
                    hook.redeem(token.id, users[u], balance);
                    continue;
                }
                // through the router or straight on the hook: the same
                uint256 payout =
                    u == 0 ? hook.redeem(token.id, users[u], balance) : router.redeem(token.id, balance);
                assertEq(payout, balance, "one chip per winning token");
                paid += payout;
            }
        }
    }

    function _lpWithdrawAll() internal returns (uint256 assets) {
        uint256 shares = vault.balanceOf(lp, uint256(house));
        vm.prank(lp);
        assets = vault.requestWithdraw(house, shares);
    }

    // --------------------------------------------------------------------------------------------
    // keeper-signed path
    // --------------------------------------------------------------------------------------------

    function test_fullRound_keeperPath_cashConservation() public {
        _fund(alice, STAKE);
        _fund(bob, STAKE);
        _fund(carol, STAKE);
        _open();
        IFallpitHook.RoundConfig memory cfg = hook.getConfig(roundId);
        assertEq(cfg.capital, HOUSE_CAPITAL, "the whole house went into the round");
        assertEq(uint8(cfg.fillSource), uint8(IPitBook.FillSource.KeeperOnly));
        assertEq(cfg.s0, S0);
        assertEq(cfg.sigma, 0.02e18);
        assertTrue(vault.isLocked(house));
        assertEq(chip.balanceOf(address(vault)), 0);

        _tradeTheMenu(S0);
        _assertSupplies();
        _assertHookSolvent(address(chip));
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        IFallpitHook.RoundState memory open = _state();
        assertGt(open.protocolFees, 0);
        assertEq(chip.balanceOf(address(hook)), open.held, "every chip of the round sits in the hook");
        assertEq(chip.balanceOf(address(router)), 0, "no escrow left behind");

        // the keeper records the close: up 1.2%, band 22, so the floor from +0.5 to +1 sigma wins, and
        // HIGHER. (On the three strikes: HIGHER@15, HIGHER@19 and LOWER@23.)
        _recordClose(S0 * 1012 / 1000, KEEPER_SOURCE);
        hook.settleRound(house, day);
        IFallpitHook.RoundState memory settled = _state();
        assertEq(uint8(settled.status), uint8(IFallpitHook.Status.Settled));
        assertFalse(settled.settledTrustless);
        assertEq(settled.closeBand, 22);
        assertEq(settled.winners, uint16(1 << F5 | 1 << HIGHER));
        assertEq(settled.payoutOwed, supply[F5] + supply[HIGHER]);

        // a keeper close waits out the challenge window
        vm.expectRevert(IFallpitHook.ChallengeWindowOpen.selector);
        hook.finalizeRound(house, day);
        _warp(settled.settledAt + 900);
        hook.finalizeRound(house, day);
        assertEq(uint8(_state().status), uint8(IFallpitHook.Status.Final));

        // the house's share is back in the vault, booked to the LP
        uint256 back = open.held - settled.payoutOwed - open.protocolFees;
        assertEq(chip.balanceOf(address(vault)), back);
        PitVault.House memory h = vault.getHouse(house);
        assertFalse(h.locked);
        assertEq(h.lpAssets + h.endowment, back);
        assertEq(vault.accounted(address(chip)), back);

        assertEq(_redeemAll(settled.winners), settled.payoutOwed);
        assertEq(hook.collectProtocolFees(address(chip)), open.protocolFees);
        uint256 lpOut = _lpWithdrawAll();
        assertLe(back - lpOut, 1, "the LP takes the house's whole result (the vault rounds down)");

        // chips in = chips out + vault return + protocol fees, to the unit
        uint256 users = chip.balanceOf(alice) + chip.balanceOf(bob) + chip.balanceOf(carol);
        assertEq(
            3 * STAKE + HOUSE_CAPITAL,
            users + chip.balanceOf(lp) + chip.balanceOf(address(vault)) + chip.balanceOf(feeRecipient),
            "cash conservation"
        );
        assertEq(chip.totalSupply(), 3 * STAKE + HOUSE_CAPITAL);
        assertEq(chip.balanceOf(address(pm)), 0, "nothing in the PoolManager");
        assertEq(chip.balanceOf(address(router)), 0);
        assertEq(chip.balanceOf(address(hook)), 0, "nothing stranded in the hook");
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, 0);
        assertEq(owed, 0);
        // the day's result, good or bad, is the LP's alone
        emit log_named_decimal_int("house result (chips)", int256(back) - int256(HOUSE_CAPITAL), 18);
        assertEq(int256(chip.balanceOf(lp)) - int256(HOUSE_CAPITAL), int256(lpOut) - int256(HOUSE_CAPITAL));
    }

    // --------------------------------------------------------------------------------------------
    // Pyth path
    // --------------------------------------------------------------------------------------------

    function test_fullRound_pythPath_cashConservation() public {
        _use(TSLA, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        _fund(alice, STAKE);
        _fund(bob, STAKE);
        _fund(carol, STAKE);
        _open();
        IFallpitHook.RoundConfig memory cfg = hook.getConfig(roundId);
        assertEq(uint8(cfg.fillSource), uint8(IPitBook.FillSource.TrustlessOnly));
        assertEq(cfg.s0, TSLA_S0);

        _tradeTheMenu(TSLA_S0);
        _assertSupplies();
        _assertHookSolvent(address(chip));
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        IFallpitHook.RoundState memory open = _state();

        // down 2.5%: band 14, so the floor from -2 to -1 sigma wins, and LOWER. (On the three strikes:
        // every LOWER token.) A Pyth close finalizes at once.
        _recordClose(TSLA_S0 * 975 / 1000, PYTH_SOURCE);
        hook.settleRound(house, day);
        IFallpitHook.RoundState memory settled = _state();
        assertTrue(settled.settledTrustless);
        assertEq(settled.closeBand, 14);
        assertEq(settled.winners, uint16(1 << F1 | 1 << LOWER));
        assertEq(settled.payoutOwed, supply[F1] + supply[LOWER]);
        hook.finalizeRound(house, day);

        uint256 back = open.held - settled.payoutOwed - open.protocolFees;
        assertEq(chip.balanceOf(address(vault)), HOUSE_CAPITAL + back, "next to the idle NVDA house");
        assertEq(_redeemAll(settled.winners), settled.payoutOwed);
        assertEq(hook.collectProtocolFees(address(chip)), open.protocolFees);
        uint256 lpOut = _lpWithdrawAll();
        assertLe(back - lpOut, 1);

        uint256 users = chip.balanceOf(alice) + chip.balanceOf(bob) + chip.balanceOf(carol);
        assertEq(
            3 * STAKE + 2 * HOUSE_CAPITAL,
            users + chip.balanceOf(lp) + chip.balanceOf(address(vault)) + chip.balanceOf(feeRecipient),
            "cash conservation"
        );
        assertEq(chip.balanceOf(address(hook)), 0);
        assertEq(chip.balanceOf(address(router)), 0);
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, 0);
        assertEq(owed, 0);
    }

    // --------------------------------------------------------------------------------------------
    // 1% fee-on-transfer chip: not a chip
    // --------------------------------------------------------------------------------------------

    /// @dev A full round cannot even start in a tax coin. Flagged in the guard: no house. Not flagged:
    ///      the house exists but the vault refuses every deposit and donation (also through the community
    ///      treasury), so there is no capital and no round.
    function test_fullRound_feeOnTransferChip_cannotStart() public {
        vm.prank(owner);
        guard.setFeeOnTransfer(address(taxChip), true);
        vm.expectRevert(PitVault.ChipNotAllowed.selector);
        _createHouse(NVDA, address(taxChip));
        vm.expectRevert(IFallpitHook.ChipNotAllowed.selector);
        hook.openRound(NVDA, address(taxChip), day);

        vm.prank(owner);
        guard.setFeeOnTransfer(address(taxChip), false);
        _use(NVDA, address(taxChip));
        taxChip.mint(lp, HOUSE_CAPITAL);
        vm.startPrank(lp);
        taxChip.approve(address(vault), HOUSE_CAPITAL);
        vm.expectRevert(
            abi.encodeWithSelector(PitVault.InexactTransfer.selector, HOUSE_CAPITAL, HOUSE_CAPITAL * 99 / 100)
        );
        vault.deposit(house, HOUSE_CAPITAL);
        vm.expectRevert(
            abi.encodeWithSelector(PitVault.InexactTransfer.selector, HOUSE_CAPITAL, HOUSE_CAPITAL * 99 / 100)
        );
        vault.donate(house, HOUSE_CAPITAL);
        vm.stopPrank();
        // launchpad fees that reached the house's inbox cannot be swept in either
        address inbox = treasury.inboxOf(house);
        taxChip.mint(inbox, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(PitVault.InexactTransfer.selector, 1_000e18, 990e18));
        treasury.sweep(house);

        assertEq(vault.roundCapital(house), 0);
        assertEq(vault.accounted(address(taxChip)), 0);
        assertEq(taxChip.balanceOf(address(vault)), 0);
        vm.expectRevert(IFallpitHook.CapitalTooLow.selector);
        hook.openRound(NVDA, address(taxChip), day);
        assertFalse(vault.isLocked(house), "the failed open left the house as it was");
    }

    /// @dev Defence in depth. A chip that taxes from the first deposit cannot get in. Here the chip
    ///      is plain while the house is funded and the round trades, and starts to tax 1% with three buys
    ///      committed and not yet filled. From then on no new buy can be committed, the pending buys fill
    ///      with a grossed-up payment, sells and every later outflow deliver the nominal amount less the
    ///      tax, and every chip ever minted is accounted for to the unit.
    function test_fullRound_chipStartsToTaxMidRound_cashConservation() public {
        _use(NVDA, address(taxChip));
        taxChip.setTax(false);
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        assertEq(vault.roundCapital(house), HOUSE_CAPITAL);
        _fund(alice, STAKE);
        _fund(bob, STAKE);
        _fund(carol, STAKE);
        uint256 minted = HOUSE_CAPITAL + 3 * STAKE;

        _open();
        IFallpitHook.RoundConfig memory cfg = hook.getConfig(roundId);
        assertEq(cfg.capital, HOUSE_CAPITAL);
        _tradeTheMenu(S0);
        assertEq(taxChip.taxed(), 0);

        // three buys are committed, then the chip starts to tax
        uint256[3] memory ids;
        ids[0] = _commitBuy(alice, HIGHER, 3_000e18, 3_000e18);
        ids[1] = _commitBuy(bob, LOWER, 2_000e18, 2_000e18);
        ids[2] = _commitBuy(carol, F6, 1_000e18, 1_000e18);
        taxChip.setTax(true);
        vm.prank(alice);
        vm.expectRevert(IFallpitRouter.BadEscrow.selector);
        router.commit{value: FILL_FEE}(roundId, HIGHER, true, 1_000e18, 1_000e18);
        for (uint256 i; i < 3; ++i) {
            assertTrue(_fill(ids[i], S0 * 1004 / 1000), "a pending buy fills across the switch");
        }
        // sells escrow tickets, so they still commit; the proceeds arrive net of the tax
        uint256 aliceBefore = taxChip.balanceOf(alice);
        uint256 heldBefore = _state().held;
        _sell(alice, HIGHER, 2_000e18, S0 * 1004 / 1000);
        uint256 nominal = heldBefore - _state().held;
        assertEq(taxChip.balanceOf(alice) - aliceBefore, nominal - nominal / 100);

        _assertSupplies();
        _assertHookSolvent(address(taxChip));
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        IFallpitHook.RoundState memory open = _state();
        assertGe(taxChip.balanceOf(address(hook)), open.held, "the hook holds at least what the round books");
        assertEq(taxChip.balanceOf(address(router)), 0, "no escrow left behind");

        _recordClose(S0 * 1012 / 1000, PYTH_SOURCE);
        hook.settleRound(house, day);
        IFallpitHook.RoundState memory settled = _state();
        assertEq(settled.payoutOwed, supply[F5] + supply[HIGHER]);
        hook.finalizeRound(house, day);

        // every outflow is the nominal amount; the receiver bears the chip's own tax
        uint256 back = open.held - settled.payoutOwed - open.protocolFees;
        assertEq(taxChip.balanceOf(address(vault)), back - back / 100);
        PitVault.House memory h = vault.getHouse(house);
        assertEq(h.lpAssets + h.endowment, back - back / 100, "the vault books what arrived");

        uint256 usersBefore = taxChip.balanceOf(alice) + taxChip.balanceOf(bob) + taxChip.balanceOf(carol);
        assertEq(_redeemAll(settled.winners), settled.payoutOwed, "the hook pays one chip per winning token");
        uint256 usersAfter = taxChip.balanceOf(alice) + taxChip.balanceOf(bob) + taxChip.balanceOf(carol);
        assertLt(usersAfter - usersBefore, settled.payoutOwed, "holders receive it net of the tax");
        hook.collectProtocolFees(address(taxChip));
        _lpWithdrawAll();

        // to the unit: every chip ever minted is with someone or was burned by the chip's own tax
        assertEq(
            minted,
            usersAfter + taxChip.balanceOf(lp) + taxChip.balanceOf(address(vault))
                + taxChip.balanceOf(feeRecipient) + taxChip.balanceOf(address(hook))
                + taxChip.balanceOf(address(router)) + taxChip.taxed(),
            "cash conservation"
        );
        assertEq(taxChip.totalSupply() + taxChip.taxed(), minted);
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(taxChip));
        assertEq(claims, 0, "the hook holds nothing");
        assertEq(owed, 0, "and owes nothing");
        assertEq(taxChip.balanceOf(address(router)), 0);
        // What is left in the hook is the gross-up dust of the three taxed buys: at most a few
        // units per buy, nobody's claim.
        assertLe(taxChip.balanceOf(address(hook)), 4 * 3, "only gross-up dust rests in the hook");
        _assertVaultBacked(address(taxChip));
    }
}
