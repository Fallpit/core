// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {AttackBase} from "./AttackBase.sol";
import {MockChip, MockFeeChip, ReentrantChip} from "../hook/mocks/MockChips.sol";
import {PitAttacker} from "../hook/mocks/PitAttacker.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {PitVault} from "../../src/PitVault.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {Menus} from "../Menus.sol";

/// @notice Attacks across contracts, with every contract real: a reentrant chip against the hook, the
///         router and the vault at once; wash trades before a void; void refunds when the round is short;
///         a just-in-time LP; a fee-on-transfer chip; and strike tokens that change hands.
contract AttacksSystemTest is AttackBase {
    address internal jit = makeAddr("jit");

    // --------------------------------------------------------------------------------------------
    // reentrancy through a malicious chip
    // --------------------------------------------------------------------------------------------

    function test_attack_reentrantChip_everyEntryPointIsBlocked() public {
        ReentrantChip evil = new ReentrantChip();
        vm.prank(owner);
        guard.approve(address(evil), true);
        _use(NVDA, address(evil));
        _lpDeposit(lp, house, 1_000_000e18);
        uint256 attempts;

        // openRound: while the capital moves vault -> hook the chip tries to open again ...
        evil.arm(address(hook), abi.encodeCall(hook.openRound, (NVDA, address(evil), day)));
        roundId = hook.openRound(NVDA, address(evil), day);
        attempts = _assertBlocked(evil, attempts, IFallpitHook.Reentrancy.selector);
        assertEq(hook.getConfig(roundId).capital, 1_000_000e18);
        evil.disarm();
        _warp(NYTime.openTs(day) + 60);

        evil.mint(alice, 100_000e18);
        evil.mint(bob, 100_000e18);
        vm.prank(alice);
        evil.approve(address(router), type(uint256).max);
        vm.prank(bob);
        evil.approve(address(router), type(uint256).max);

        // commit: while the escrow moves user -> router the chip tries to commit and to fill
        evil.arm(address(router), abi.encodeCall(router.commit, (roundId, HIGHER, true, 1e18, 1e18)));
        uint256 id1 = _commitBuy(alice, HIGHER, 5_000e18, 100_000e18);
        attempts = _assertBlocked(evil, attempts, IFallpitRouter.Reentrancy.selector);
        evil.disarm();
        uint256 id2 = _commitBuy(bob, HIGHER, 5_000e18, 100_000e18);
        uint64 t = router.getCommit(id1).fillTs;
        _warp(t);
        bytes memory report = _print(t, S0);

        // fill: while the cost moves router -> hook the chip tries to fill the other commit ...
        evil.arm(address(router), abi.encodeCall(router.fill, (id2, report)));
        vm.prank(keeper);
        assertTrue(router.fill(id1, report));
        attempts = _assertBlocked(evil, attempts, IFallpitRouter.Reentrancy.selector);
        // ... and to call the hook's fill itself while the escrow moves to the hook, posing as the router
        // (only the router may fill)
        evil.arm(
            address(hook),
            abi.encodeCall(hook.fill, (roundId, HIGHER, true, 5_000e18, 100_000e18, address(evil), t, report))
        );
        vm.prank(keeper);
        assertTrue(router.fill(id2, report));
        attempts = _assertBlocked(evil, attempts, IFallpitHook.OnlyRouter.selector);
        assertEq(_token(HIGHER).totalSupply(), 10_000e18, "exactly the two fills minted");

        // sell: while the proceeds move hook -> user the chip tries to refund a pending commit
        // (the sell is committed first: a round's commits fill in commit order, and it fills first)
        Ticket memory token = _token(HIGHER);
        vm.startPrank(alice);
        token.approve(address(router), 2_000e18);
        uint256 id4 = router.commit{value: FILL_FEE}(roundId, HIGHER, false, 2_000e18, 0);
        vm.stopPrank();
        uint256 id3 = _commitBuy(bob, LOWER, 1_000e18, 10_000e18);
        evil.arm(address(router), abi.encodeCall(router.refund, (id3)));
        attempts = evil.attempts(); // the commit of a sell moves no chips
        assertTrue(_fill(id4, S0));
        attempts = _assertBlocked(evil, attempts, IFallpitRouter.Reentrancy.selector);
        evil.disarm();
        assertTrue(_fill(id3, S0));
        _assertSupplies();
        _assertHookSolvent(address(evil));

        // an LP deposit while the round runs: the chip tries to cancel it in the same breath
        evil.mint(jit, 10_000e18);
        vm.prank(jit);
        evil.approve(address(vault), 10_000e18);
        evil.arm(address(vault), abi.encodeCall(vault.cancelDeposit, (house)));
        vm.prank(jit);
        vault.deposit(house, 10_000e18);
        attempts = _assertBlocked(evil, attempts, bytes4(keccak256("Reentrancy()")));
        evil.disarm();

        // finalize: while the house's share moves hook -> vault the chip tries to finalize again,
        _recordClose(S0 * 101 / 100, PYTH_SOURCE);
        hook.settleRound(house, day);
        evil.arm(address(hook), abi.encodeCall(hook.finalizeRound, (house, day)));
        uint256 snapshot = vm.snapshotState();
        hook.finalizeRound(house, day);
        attempts = _assertBlocked(evil, attempts, IFallpitHook.Reentrancy.selector);
        uint256 honestBack = vault.getHouse(house).lpAssets;
        vm.revertToState(snapshot);
        attempts = evil.attempts();
        // ... or to process the vault's queues before the round's result is booked (the house is locked)
        evil.arm(address(vault), abi.encodeCall(vault.processQueues, (house)));
        hook.finalizeRound(house, day);
        attempts = _assertBlocked(evil, attempts, PitVault.HouseLocked.selector);
        assertEq(vault.getHouse(house).lpAssets, honestBack, "the result is booked the same either way");
        assertEq(vault.getHouse(house).pendingDeposits, 10_000e18, "the queued deposit is untouched");

        // redeem: while the payout moves hook -> holder the chip, itself a holder of winning
        // tokens, tries to redeem inside the redeem
        vm.prank(alice);
        token.transfer(address(evil), 1_000e18);
        evil.arm(address(hook), abi.encodeCall(hook.redeem, (token.id, address(evil), 1_000e18)));
        vm.prank(alice);
        assertEq(hook.redeem(token.id, alice, 2_000e18), 2_000e18);
        attempts = _assertBlocked(evil, attempts, IFallpitHook.Reentrancy.selector);
        // collecting fees: the chip tries to collect them again
        evil.arm(address(hook), abi.encodeCall(hook.collectProtocolFees, (address(evil))));
        uint256 fees = hook.collectProtocolFees(address(evil));
        attempts = _assertBlocked(evil, attempts, IFallpitHook.Reentrancy.selector);
        assertEq(evil.balanceOf(feeRecipient), fees);
        // an LP withdrawal: while the chips move vault -> LP the chip tries to withdraw again
        uint256 lpShares = vault.balanceOf(lp, uint256(house));
        evil.arm(address(vault), abi.encodeCall(vault.requestWithdraw, (house, lpShares / 2)));
        vm.prank(lp);
        vault.requestWithdraw(house, lpShares / 2);
        attempts = _assertBlocked(evil, attempts, bytes4(keccak256("Reentrancy()")));
        evil.disarm();

        assertEq(evil.successes(), 0, "no reentrant call ever got through");
        // the books still close: bob redeems, and what the hook owes is exactly the chip's own tokens
        vm.prank(bob);
        assertEq(router.redeem(token.id, 5_000e18), 5_000e18);
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(evil));
        assertEq(claims, owed);
        assertEq(owed, 1_000e18, "only the tokens parked on the chip contract are still owed");
        assertEq(evil.balanceOf(address(hook)), 1_000e18);
        _assertVaultBacked(address(evil));
    }

    function _assertBlocked(ReentrantChip evil, uint256 attemptsBefore, bytes4 expected)
        internal
        view
        returns (uint256)
    {
        assertGt(evil.attempts(), attemptsBefore, "the chip did try to reenter");
        assertEq(evil.successes(), 0, "and was blocked");
        if (expected != bytes4(0)) assertEq(bytes4(evil.lastRevert()), expected);
        return evil.attempts();
    }

    // --------------------------------------------------------------------------------------------
    // wash trades before a void, and void refunds
    // --------------------------------------------------------------------------------------------

    function test_attack_voidRefunds_sellerCannotClaimTwice() public {
        _open();
        uint256 cost = _eveBuy(HIGHER, 10_000e18, S0);
        uint256 proceeds = _eveSell(HIGHER, 6_000e18, S0);
        (, uint256[12] memory premium) = hook.getSupplies(roundId);
        assertLe(premium[HIGHER], cost * 4_000 / 10_000, "the sold shares took their average cost with them");
        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        uint256 refund = eve.redeem(_token(HIGHER).id, 4_000e18);
        assertEq(refund, premium[HIGHER]);
        assertLt(proceeds + refund, cost, "sell plus void refund returns less than the cost");
        // nothing left to claim
        uint256 token = _token(HIGHER).id;
        vm.expectRevert();
        eve.redeemDirect(token, 1);
        assertGe(chip.balanceOf(address(vault)), HOUSE_CAPITAL);
    }

    /// @dev Wash trades cannot pump the cost basis a void refunds. Eve holds cheap tokens, then
    ///      repeatedly buys a large lot (pushing the price up) and sells it straight back. If a sell only
    ///      removed the average cost, each trip would leave part of the expensive lot's cost in the basis
    ///      of her cheap tokens and a void would pay it out of the house's capital.
    ///      On HIGHER (a narrow product is a floor, which would stop at its product cap long before
    ///      400,000 tokens).
    function test_attack_voidRefunds_washTradesCannotPumpTheCostBasis() public {
        // a large per-fill cap makes the price push, and so the pump, as strong as possible
        IPitBook.Params memory p = book.defaultParams();
        p.maxFillBps = 5000;
        _setParams(p);
        _open();
        chip.mint(address(eve), 2_000_000e18);
        uint256 paid = _eveBuy(HIGHER, 400_000e18, S0);
        uint256 got;
        for (uint256 i; i < 6; ++i) {
            paid += _eveBuy(HIGHER, 400_000e18, S0);
            got += _eveSell(HIGHER, 400_000e18, S0);
            (, uint256[12] memory basis) = hook.getSupplies(roundId);
            assertLe(
                basis[HIGHER], paid - got, "the cost basis never exceeds the net cash paid for the token"
            );
        }
        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        uint256 refund = eve.redeem(_token(HIGHER).id, 400_000e18);
        assertLe(got + refund, paid, "the wash and the void together return no more than eve paid");
        assertGe(chip.balanceOf(address(vault)), HOUSE_CAPITAL, "the house gets all of its capital back");
        emit log_named_decimal_uint("eve paid", paid, 18);
        emit log_named_decimal_uint("eve got back (sells + void refund)", got + refund, 18);
    }

    /// @dev The same in aggregate, for any mix of buys and sells at one oracle price: what a void refunds
    ///      is never more than the traders' net cash in, so the house's capital comes back whole.
    function testFuzz_attack_voidRefunds_neverPayOutHouseCapital(uint256 seed) public {
        _open();
        uint256 paid;
        uint256 got;
        for (uint256 i; i < 10; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint8 index = uint8(seed % PRODUCTS);
            uint256 held = _token(index).balanceOf(address(eve));
            if (held >= 1e18 && (seed >> 8) % 2 == 0) {
                got += _eveSell(index, bound(seed >> 16, 1e18, held > 20_000e18 ? 20_000e18 : held), S0);
            } else {
                // a buy that would take a floor over its product cap is refunded and costs nothing
                uint256 before = chip.balanceOf(address(eve));
                _tryTrade(eve, index, true, bound(seed >> 16, 1e18, 20_000e18), S0);
                paid += before - chip.balanceOf(address(eve));
            }
        }
        uint256 held_ = _state().held;
        assertEq(held_, HOUSE_CAPITAL + paid - got);
        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        assertLe(_state().payoutOwed, paid - got, "refunds never exceed the net cash traders put in");
        assertGe(chip.balanceOf(address(vault)), HOUSE_CAPITAL);
    }

    /// @dev Wild oracle swings let one trader take out more than traders as a group put in (see the
    ///      whipsaw test). On a void the house comes first: it gets back what the round still holds, up to
    ///      its capital, and the holders share only what is above that. Here nothing is, so the holders
    ///      get nothing and the house is not asked to pay for the seller's gain a second time.
    ///      The round runs with the loss limit off (10000): the default limit stops x's buying long
    ///      before the round holds less than the holders paid, and this test is about the void in that
    ///      worst case.
    ///      On the six-product threshold menu (`Menus.thresholds`), with the product cap at its ceiling and no minimum price, like the loss
    ///      limit: the scenario needs three products that are each dear at one end of the swing, one of
    ///      them traded 600,000 tokens at a time, which the product cap of a floor refuses. The void rule
    ///      under test does not depend on the menu. The swings are tuned at alpha 0.3, set explicitly
    ///      (at the default of 0.2 the book is shallower and the same swings leave the
    ///      round holding more than the holders paid).
    function test_attack_voidRefunds_neverExceedWhatTheRoundHolds() public {
        IPitBook.Params memory p = book.defaultParams();
        p.alpha = 0.3e18;
        p.maxFillBps = 1000;
        p.lossLimitBps = 10_000;
        p.floorCapBps = 10_000;
        p.minPriceWad = 0;
        p.menu = Menus.thresholds();
        _setParams(p);
        _open();
        uint256 cap = hook.getConfig(roundId).maxFill;
        PitAttacker x = _attacker(address(chip), 3_000_000e18);
        PitAttacker y = _attacker(address(chip), 500_000e18);
        PitAttacker z = _attacker(address(chip), 500_000e18);
        uint256 low = S0 * 92 / 100;
        uint256 high = S0 * 106 / 100;

        // y buys the bottom HIGHER strike dear while the stock is up; z buys the bottom LOWER strike dear
        // when it is down. Both paid close to one chip per token.
        for (uint256 i; i < 3; ++i) {
            _trade(y, 0, true, cap, high);
        }
        for (uint256 i; i < 3; ++i) {
            _trade(z, 1, true, cap, low);
        }
        // x rides the same swings on another token: buys the top HIGHER strike for little at the lows
        // and sells it dear at the highs, again and again, until the round can pay no more
        for (uint256 trips; trips < 12; ++trips) {
            bool refused;
            for (uint256 k; k < 6 && !refused; ++k) {
                (uint256 quoted,,,,,) = lens.quote(roundId, 4, true, cap, low, clock + 2);
                if (quoted > cap / 2) break;
                refused = !_tryTrade(x, 4, true, cap, low);
            }
            uint256 balance = _token(4).balanceOf(address(x));
            while (balance != 0 && !refused) {
                uint256 lot = balance > cap ? cap : balance;
                refused = !_tryTrade(x, 4, false, lot, high);
                if (!refused) balance -= lot;
            }
            (uint256 worst, uint256 covered) = lens.solvency(roundId);
            assertLe(worst, covered, "payouts stay covered throughout");
            if (refused) break;
        }
        assertGt(chip.balanceOf(address(x)), 3_000_000e18 + 500_000e18, "x took chips out of the round");

        (uint256[12] memory supply, uint256[12] memory premium) = hook.getSupplies(roundId);
        IFallpitHook.RoundState memory st = _state();
        uint256 costBasis = premium[0] + premium[1] + premium[4];
        emit log_named_decimal_uint("holders' cost basis", costBasis, 18);
        emit log_named_decimal_uint("chips the round still holds", st.held, 18);
        assertGt(costBasis, st.held, "scenario: the holders' cost exceeds what the round still holds");

        assertLt(st.held, HOUSE_CAPITAL, "scenario: the round holds less than the house brought");

        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        IFallpitHook.RoundState memory voided = _state();
        assertEq(voided.payoutOwed, 0, "nothing is above the house's capital: no refunds");
        assertEq(chip.balanceOf(address(vault)), st.held, "the house takes all the round still holds");
        assertFalse(vault.isLocked(house));

        // the tokens still redeem, for nothing; nobody is paid out of the house's capital
        uint256 fromY = y.redeemDirect(_token(0).id, supply[0]);
        uint256 fromZ = z.redeem(_token(1).id, supply[1]);
        uint256 fromX = supply[4] == 0 ? 0 : x.redeem(_token(4).id, supply[4]);
        assertEq(fromX + fromY + fromZ, 0);
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, 0);
        assertEq(owed, 0);
        _assertVaultBacked(address(chip));
        PitVault.House memory h = vault.getHouse(house);
        assertEq(h.lpAssets + h.endowment, st.held);
    }

    /// @dev A void is not a free option. Eve buys both sides of the middle strike, the stock moves, she
    ///      sells the side that gained and waits for a void to refund the side that lost. The house gets
    ///      its capital back first, so the holders as a group get back exactly what they as a group still
    ///      have in the round: eve's realised gain comes out of her own refund.
    function test_attack_void_isNotAFreeOption() public {
        _open();
        chip.mint(address(eve), 300_000e18);
        uint256 start = chip.balanceOf(address(eve));
        uint256 paid;
        for (uint256 i; i < 5; ++i) {
            paid += _eveBuy(HIGHER, 20_000e18, S0);
            paid += _eveBuy(LOWER, 20_000e18, S0);
        }
        // the stock gains one standard deviation; HIGHER is now worth far more than she paid for it
        _warp(clock + 3 hours);
        uint256 up = S0 * 102 / 100;
        uint256 got;
        for (uint256 i; i < 5; ++i) {
            got += _eveSell(HIGHER, 20_000e18, up);
        }
        (, uint256[12] memory premium) = hook.getSupplies(roundId);
        assertGt(
            got + premium[LOWER], paid, "under a full-refund rule the sale plus the refund beat her outlay"
        );

        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        uint256 refund = eve.redeem(_token(LOWER).id, 100_000e18);
        assertEq(refund, paid - got, "she gets back what she still had in the round, not her cost");
        assertEq(
            chip.balanceOf(address(eve)), start, "the round trip through a void is worth exactly nothing"
        );
        assertEq(chip.balanceOf(address(vault)), HOUSE_CAPITAL, "and the house is exactly whole");
    }

    // --------------------------------------------------------------------------------------------
    // a just-in-time LP
    // --------------------------------------------------------------------------------------------

    /// @dev The house has a winning day (every token sold loses). A just-in-time LP sees it coming and
    ///      deposits before the round is finalized, to take a share of the result. It gets none: the
    ///      deposit waits in the queue and mints at the price after the result.
    function test_attack_jitLp_cannotCaptureALockedRoundsResult() public {
        _open();
        uint256 cost = _buy(alice, F6, 20_000e18, S0) + _buy(bob, F6, 20_000e18, S0);
        // the close is in: the floor from +1 to +2 sigma lost, the house keeps all of the premium
        _recordClose(S0, PYTH_SOURCE);
        hook.settleRound(house, day);

        // jit deposits a fortune between settlement and finalization, in the finalizing block itself
        uint256 size = 10_000_000e18;
        assertEq(_lpDeposit(jit, house, size), 0, "queued: no shares yet");
        hook.finalizeRound(house, day);
        uint256 fees = hook.protocolFeesAccrued(address(chip));
        PitVault.House memory h = vault.getHouse(house);
        assertEq(h.lpAssets, HOUSE_CAPITAL + cost - fees, "the whole result went to the shares in the round");

        // jit takes its shares and leaves at once
        vault.settle(house, jit);
        uint256 shares = vault.balanceOf(jit, uint256(house));
        vm.prank(jit);
        uint256 out = vault.requestWithdraw(house, shares);
        assertLe(out, size, "it gets back at most what it put in");
        assertGe(out + 1e7, size, "less only the vault's rounding");
        // the honest LP, who carried the round, has all of the profit
        uint256 lpShares = vault.balanceOf(lp, uint256(house));
        vm.prank(lp);
        uint256 lpOut = vault.requestWithdraw(house, lpShares);
        assertGe(lpOut, HOUSE_CAPITAL + cost - fees);
        assertLe(lpOut, HOUSE_CAPITAL + cost - fees + (size - out));
        _assertVaultBacked(address(chip));
    }

    /// @dev The mirror image: an LP who sees a losing day coming cannot get out before the loss lands. A
    ///      withdrawal requested during the round is paid at the price after the result.
    function test_attack_jitLp_cannotDodgeALosingRound() public {
        // two LPs with equal stakes
        _lpDeposit(jit, house, HOUSE_CAPITAL);
        _open();
        uint256 cost = _buy(alice, F6, 20_000e18, S0) + _buy(bob, F6, 20_000e18, S0);
        // the stock runs into their floor (+1 to +2 sigma): jit asks for everything back before the close
        uint256 jitShares = vault.balanceOf(jit, uint256(house));
        vm.prank(jit);
        assertEq(vault.requestWithdraw(house, jitShares), 0, "nothing is paid while the round runs");
        vm.prank(jit);
        vm.expectRevert(PitVault.NothingToClaim.selector);
        vault.claim(house);

        _closeAndFinalize(S0 * 103 / 100);
        uint256 loss = 40_000e18 - cost + hook.protocolFeesAccrued(address(chip));
        assertGt(loss, 20_000e18, "scenario: a real loss");
        vm.prank(jit);
        uint256 out = vault.claim(house);
        assertLe(out, HOUSE_CAPITAL - loss / 2, "jit bears its half of the loss");
        assertGe(out + 2, HOUSE_CAPITAL - loss / 2);
        assertLe(
            vault.convertToAssets(house, vault.balanceOf(lp, uint256(house))),
            HOUSE_CAPITAL - loss / 2,
            "and so does the LP who stayed"
        );
    }

    /// @dev A queued deposit can be cancelled during the round, for exactly what was put in: it never had
    ///      exposure, so it is no option on the round. And chips sent straight to the vault mint nothing
    ///      for the sender: they are booked as part of the house's next result.
    function test_attack_jitLp_cancelAndStrayChips_giveNoEdge() public {
        _open();
        _buy(alice, F6, 20_000e18, S0);
        _lpDeposit(jit, house, 500_000e18);
        vm.prank(jit);
        assertEq(vault.cancelDeposit(house), 500_000e18);
        assertEq(chip.balanceOf(jit), 500_000e18);
        vm.prank(jit);
        vm.expectRevert(PitVault.NothingToCancel.selector);
        vault.cancelDeposit(house);

        // jit pushes chips into the vault by hand, hoping to be credited on the next sync
        vm.prank(jit);
        chip.transfer(address(vault), 100_000e18);
        assertEq(vault.balanceOf(jit, uint256(house)), 0);
        (uint256 shares, uint256 queuedAssets,, uint256 claimable) = vault.positionOf(house, jit);
        assertEq(shares + queuedAssets + claimable, 0);
        _closeAndFinalize(S0);
        // the stray chips became part of the house's result: a gift to the LP who was in the round
        PitVault.House memory h = vault.getHouse(house);
        assertGt(h.lpAssets, HOUSE_CAPITAL + 100_000e18);
        (shares, queuedAssets,, claimable) = vault.positionOf(house, jit);
        assertEq(shares + queuedAssets + claimable, 0, "nothing for the sender");
        _assertVaultBacked(address(chip));
    }

    // --------------------------------------------------------------------------------------------
    // fee-on-transfer chip
    // --------------------------------------------------------------------------------------------

    /// @dev A tax coin is refused at every entry point of the real system. A flagged one: no house and
    ///      no round. An unflagged one (the guard only knows what its owner told it): no deposit, no
    ///      donation, no buy commit.
    function test_attack_feeOnTransferChip_refusedAtEveryEntryPoint() public {
        // flagged: the guard refuses it on every route, so no house can be created
        vm.prank(owner);
        guard.setFeeOnTransfer(address(taxChip), true);
        (bool allowed, bool flagged) = guard.check(address(taxChip));
        assertFalse(allowed);
        assertTrue(flagged);
        bytes32 taxHouse = vault.houseId(NVDA, address(taxChip));
        vm.expectRevert(PitVault.ChipNotAllowed.selector);
        _createHouse(NVDA, address(taxChip));

        // not flagged: the house exists, and stays empty
        vm.prank(owner);
        guard.setFeeOnTransfer(address(taxChip), false);
        _use(NVDA, address(taxChip));
        assertEq(house, taxHouse);
        taxChip.mint(lp, 2_000_000e18);
        vm.startPrank(lp);
        taxChip.approve(address(vault), 2_000_000e18);
        vm.expectRevert(abi.encodeWithSelector(PitVault.InexactTransfer.selector, 1_000_000e18, 990_000e18));
        vault.deposit(house, 1_000_000e18);
        vm.expectRevert(abi.encodeWithSelector(PitVault.InexactTransfer.selector, 1_000_000e18, 990_000e18));
        vault.donate(house, 1_000_000e18);
        vm.stopPrank();
        assertEq(vault.roundCapital(house), 0);
        assertEq(taxChip.balanceOf(address(vault)), 0);
        assertEq(taxChip.balanceOf(lp), 2_000_000e18, "a refused deposit takes nothing");
        vm.expectRevert(IFallpitHook.CapitalTooLow.selector);
        hook.openRound(NVDA, address(taxChip), day);

        // a house funded while the coin was plain: once the guard's owner flags the coin, no round opens
        taxChip.setTax(false);
        vm.prank(lp);
        vault.deposit(house, 1_000_000e18);
        vm.prank(owner);
        guard.setFeeOnTransfer(address(taxChip), true);
        vm.expectRevert(IFallpitHook.ChipNotAllowed.selector);
        hook.openRound(NVDA, address(taxChip), day);
        // the LP is not trapped: withdrawals never ask the guard
        uint256 shares = vault.balanceOf(lp, uint256(house));
        vm.prank(lp);
        assertEq(vault.requestWithdraw(house, shares / 2), 500_000e18);

        // unflagged and taxing again with a round open: the router refuses the escrow of a buy
        vm.prank(owner);
        guard.setFeeOnTransfer(address(taxChip), false);
        _open();
        taxChip.setTax(true);
        PitAttacker a = _attacker(address(taxChip), 50_000e18);
        vm.expectRevert(IFallpitRouter.BadEscrow.selector);
        a.commit(roundId, HIGHER, true, 10_000e18, 10_000e18);
        assertEq(taxChip.balanceOf(address(a)), 50_000e18);
        assertEq(taxChip.balanceOf(address(router)), 0);
        _assertPristine();
    }

    /// @dev Defence in depth. A taxed chip cannot get in, so here the chip starts to tax after the house
    ///      was funded and the commits were made. The hook books only what it received, the router sends the grossed-up cost within the limit, every outflow is the nominal
    ///      amount, and hook and vault stay solvent to the unit.
    function test_attack_chipThatStartsToTaxLater_hookAndVaultStaySolvent() public {
        _use(NVDA, address(taxChip));
        taxChip.setTax(false);
        _lpDeposit(lp, house, 1_000_000e18);
        assertEq(vault.roundCapital(house), 1_000_000e18);
        taxChip.setTax(true);
        _open();
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(c.capital, 990_000e18, "L is what the hook booked, after the chip's tax");
        assertEq(taxChip.balanceOf(address(hook)), 990_000e18);
        _assertHookSolvent(address(taxChip));

        taxChip.setTax(false);
        PitAttacker a = _attacker(address(taxChip), 50_000e18);
        // buy: committed while plain, filled while taxed. The user sends the grossed-up cost.
        (uint256 quoted,,,,,) = lens.quote(roundId, HIGHER, true, 10_000e18, S0, clock + 2);
        uint256 id = a.commit(roundId, HIGHER, true, 10_000e18, 10_000e18);
        assertEq(router.getCommit(id).escrow, 10_000e18);
        taxChip.setTax(true);
        assertTrue(a.fill(id, _printFor(id, S0)));
        assertEq(_state().held, c.capital + quoted, "the hook books exactly the cost it received");
        assertGe(taxChip.balanceOf(address(hook)), c.capital + quoted);
        uint256 sent = 50_000e18 - taxChip.balanceOf(address(a));
        assertGt(sent, quoted * 100 / 99, "the user bears the chip's tax on the way in");
        assertLt(sent, quoted * 104 / 100);
        assertEq(taxChip.balanceOf(address(router)), 0, "unused escrow went back");
        _assertHookSolvent(address(taxChip));

        // a limit that covers the cost but not the tax on top refunds
        taxChip.setTax(false);
        (quoted,,,,,) = lens.quote(roundId, LOWER, true, 1_000e18, S0, clock + 2);
        id = a.commit(roundId, LOWER, true, 1_000e18, quoted * 1005 / 1000);
        taxChip.setTax(true);
        assertFalse(a.fill(id, _printFor(id, S0)));
        assertEq(_token(LOWER).totalSupply(), 0);

        // sell: the escrow is tickets, so the commit is exact; proceeds arrive net of the tax
        a.approve(_token(HIGHER).id, address(router));
        uint256 before = taxChip.balanceOf(address(a));
        (uint256 net,,,,,) = lens.quote(roundId, HIGHER, false, 4_000e18, S0, clock + 2);
        id = a.commit(roundId, HIGHER, false, 4_000e18, 0);
        assertTrue(a.fill(id, _printFor(id, S0)));
        assertEq(taxChip.balanceOf(address(a)) - before, net - net / 100);
        _assertSupplies();
        _assertHookSolvent(address(taxChip));

        // settle, finalize, redeem: every outflow is the nominal amount, the receiver bears the tax
        _recordClose(S0 * 101 / 100, PYTH_SOURCE);
        hook.settleRound(house, day);
        IFallpitHook.RoundState memory st = _state();
        hook.finalizeRound(house, day);
        uint256 back = st.held - st.payoutOwed - st.protocolFees;
        assertEq(taxChip.balanceOf(address(vault)), back - back / 100);
        assertEq(vault.roundCapital(house), back - back / 100);
        before = taxChip.balanceOf(address(a));
        assertEq(a.redeem(_token(HIGHER).id, 6_000e18), 6_000e18);
        assertEq(taxChip.balanceOf(address(a)) - before, 5_940e18);
        hook.collectProtocolFees(address(taxChip));

        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(taxChip));
        assertEq(claims, 0);
        assertEq(owed, 0);
        assertLe(taxChip.balanceOf(address(hook)), 4, "only gross-up dust is left in the hook");
        _assertVaultBacked(address(taxChip));
        // nothing was created: every chip minted is somewhere or was burned as tax
        assertEq(
            1_050_000e18,
            taxChip.balanceOf(address(a)) + taxChip.balanceOf(address(vault))
                + taxChip.balanceOf(feeRecipient) + taxChip.balanceOf(address(hook))
                + taxChip.balanceOf(address(router)) + taxChip.taxed()
        );
        // the house's two transfer taxes of the day (out and back) are a loss like any other
        PitVault.House memory h = vault.getHouse(house);
        assertEq(h.lpAssets + h.endowment, back - back / 100);
    }

    // --------------------------------------------------------------------------------------------
    // the token is the claim
    // --------------------------------------------------------------------------------------------

    function test_attack_secondaryMarketBuyer_redeems_andNobodyRedeemsTwice() public {
        _open();
        _buy(alice, HIGHER, 3_000e18, S0);
        Ticket memory token = _token(HIGHER);
        // alice sells 2000 on some other market to a contract that never touched the router
        PitAttacker dave = new PitAttacker{value: 10 ether}(router, hook);
        vm.prank(alice);
        token.transfer(address(dave), 2_000e18);
        _closeAndFinalize(S0 * 101 / 100);

        assertEq(dave.redeemDirect(token.id, 500e18), 500e18);
        assertEq(dave.redeem(token.id, 500e18), 500e18);
        // the same tokens cannot be redeemed twice in one transaction, nor more than held
        vm.expectRevert();
        dave.redeemTwice(token.id, 600e18);
        vm.expectRevert();
        dave.redeemDirect(token.id, 1_000e18 + 1);
        assertEq(dave.redeemDirect(token.id, 1_000e18), 1_000e18);
        assertEq(chip.balanceOf(address(dave)), 2_000e18);
        // alice kept 1000 and can only redeem those
        vm.prank(alice);
        vm.expectRevert();
        hook.redeem(token.id, alice, 1_000e18 + 1);
        vm.prank(alice);
        assertEq(hook.redeem(token.id, alice, 1_000e18), 1_000e18);
        assertEq(token.totalSupply(), 0);
        assertEq(_state().payoutOwed, 0);
    }

    function test_attack_strayTickets_changeNothing() public {
        _open();
        _buy(alice, HIGHER, 3_000e18, S0);
        Ticket memory token = _token(HIGHER);
        // stray tickets sent to the hook or the router are not anyone's claim and move no accounting
        vm.startPrank(alice);
        token.transfer(address(hook), 100e18);
        token.transfer(address(router), 100e18);
        vm.stopPrank();
        _assertSupplies();
        _sell(alice, HIGHER, 500e18, S0);
        assertEq(token.balanceOf(address(hook)), 100e18);
        assertEq(token.balanceOf(address(router)), 100e18);
        assertEq(token.totalSupply(), 2_500e18);
        _assertSupplies();
        _closeAndFinalize(S0 * 101 / 100);
        assertEq(_state().payoutOwed, 2_500e18);
        _assertHookSolvent(address(chip));
    }
}
