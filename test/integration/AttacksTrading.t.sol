// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {AttackBase} from "./AttackBase.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";
import {PitAttacker} from "../hook/mocks/PitAttacker.sol";
import {PitVault} from "../../src/PitVault.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice Trading attacks against the real pricing engine behind the real hook: refunds that leave no
///         trace, depth decay, one-sided flow up to the solvency limit, rounding dust, cap griefing, a
///         sandwich, and gas starvation.
contract AttacksTradingTest is AttackBase {
    // --------------------------------------------------------------------------------------------
    // limit and cap refunds, never-fillable commits
    // --------------------------------------------------------------------------------------------

    function test_attack_limitRefunds_leaveNoTrace() public {
        _open();
        // a buy whose limit can never cover the cost
        uint256 id = eve.commit(roundId, HIGHER, true, 1_000e18, 1);
        assertEq(chip.balanceOf(address(eve)), EVE_CHIPS - 1);
        bytes memory report = _printFor(id, S0);
        vm.expectEmit(true, true, false, true, address(router));
        emit Refunded(id, address(eve), RefundReason.Limit);
        assertFalse(eve.fill(id, report));
        assertEq(chip.balanceOf(address(eve)), EVE_CHIPS, "escrow returned");
        assertEq(uint8(router.getCommit(id).status), uint8(IFallpitRouter.CommitStatus.Refunded));
        _assertPristine();

        // one unit below the exact cost refunds, the exact cost fills with nothing left over
        (uint256 quoted,,,,,) = lens.quote(roundId, HIGHER, true, 1_000e18, S0, clock + 2);
        id = eve.commit(roundId, HIGHER, true, 1_000e18, quoted - 1);
        assertFalse(eve.fill(id, _printFor(id, S0)));
        _assertPristine();
        (quoted,,,,,) = lens.quote(roundId, HIGHER, true, 1_000e18, S0, clock + 2);
        id = eve.commit(roundId, HIGHER, true, 1_000e18, quoted);
        assertTrue(eve.fill(id, _printFor(id, S0)));
        assertEq(chip.balanceOf(address(eve)), EVE_CHIPS - quoted);
        assertEq(_token(HIGHER).balanceOf(address(eve)), 1_000e18);

        // a sell whose floor is above the proceeds: the tokens come back, nothing else moves
        IFallpitHook.RoundState memory st = _state();
        (uint256 net,,,,,) = lens.quote(roundId, HIGHER, false, 1_000e18, S0, clock + 2);
        eve.approve(_token(HIGHER).id, address(router));
        id = eve.commit(roundId, HIGHER, false, 1_000e18, net + 1);
        assertEq(_token(HIGHER).balanceOf(address(router)), 1_000e18, "tokens escrowed");
        report = _printFor(id, S0);
        vm.expectEmit(true, true, false, true, address(router));
        emit Refunded(id, address(eve), RefundReason.Limit);
        assertFalse(eve.fill(id, report));
        assertEq(_token(HIGHER).balanceOf(address(eve)), 1_000e18);
        assertEq(_token(HIGHER).totalSupply(), 1_000e18);
        assertEq(_state().held, st.held);
        assertEq(router.escrowedTickets(_token(HIGHER).id), 0);
    }

    function test_attack_capRefund() public {
        _open();
        uint256 cap = hook.getConfig(roundId).maxFill;
        assertEq(cap, 20_000e18);
        // over the cap: rejected for good before the oracle is even asked, so any report refunds it
        uint256 id = eve.commit(roundId, HIGHER, true, cap + 1, EVE_CHIPS);
        _warp(router.getCommit(id).fillTs);
        vm.expectEmit(true, true, false, true, address(router));
        emit Refunded(id, address(eve), RefundReason.Cap);
        assertFalse(eve.fill(id, ""));
        assertEq(chip.balanceOf(address(eve)), EVE_CHIPS);
        _assertPristine();

        // exactly the cap fills
        id = eve.commit(roundId, HIGHER, true, cap, EVE_CHIPS);
        assertTrue(eve.fill(id, _printFor(id, S0)));
        assertEq(_token(HIGHER).balanceOf(address(eve)), cap);
    }

    /// @dev Commits of one second fill in commit order: eve's commits that can never
    ///      trade sit in front of alice's in the same second. The keeper clears them in order (each a
    ///      refund that pays the keeper the fee eve attached) and alice's fills in its window. Commits
    ///      nobody touches block nothing after their own second.
    function test_attack_neverFillableCommits_cannotGriefTheRound() public {
        _open();
        uint256[] memory ids = new uint256[](30);
        for (uint256 i; i < 15; ++i) {
            ids[i] = eve.commit(roundId, uint8(i % PRODUCTS), true, 1e18, 1 + i);
        }
        // honest trading in the same second waits for them; the keeper clears them in commit order
        uint256 aliceId = _commitBuy(alice, HIGHER, 1_000e18, STAKE);
        bytes memory report = _print(router.getCommit(aliceId).fillTs, S0);
        _warp(router.getCommit(aliceId).fillTs);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IFallpitRouter.EarlierCommitPending.selector, ids[14]));
        router.fill(aliceId, report);
        for (uint256 i; i < 15; ++i) {
            vm.prank(keeper);
            assertFalse(router.fill(ids[i], report));
        }
        vm.prank(keeper);
        assertTrue(router.fill(aliceId, report));
        // fifteen more, left alone, in a later second: a later trade waits only until their window ends
        _warp(clock + 5);
        for (uint256 i = 15; i < 30; ++i) {
            ids[i] = eve.commit(roundId, uint8(i % PRODUCTS), true, 1e18, 1 + i);
        }
        _warp(clock + 1);
        uint256 later = _commitBuy(alice, LOWER, 10e18, chip.balanceOf(alice));
        bytes memory laterReport = _printFor(later, S0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IFallpitRouter.EarlierCommitPending.selector, ids[29]));
        router.fill(later, laterReport);
        IFallpitRouter.Commit memory last = router.getCommit(ids[29]);
        _warp(last.fillTs + last.refundDelay + 1);
        vm.prank(keeper);
        assertTrue(
            router.fill(later, laterReport), "filled inside its own window, the leftovers still pending"
        );
        // the round closes, settles and pays with commits still pending
        _closeAndFinalize(S0 * 101 / 100);
        uint256 token = _token(HIGHER).id;
        vm.prank(alice);
        assertEq(router.redeem(token, 1_000e18), 1_000e18);
        // the leftovers are refundable to the attacker, to the unit, and can never fill
        for (uint256 i = 15; i < 30; ++i) {
            vm.expectRevert(IFallpitRouter.FillWindowClosed.selector);
            router.fill(ids[i], "");
            router.refund(ids[i]);
        }
        assertEq(chip.balanceOf(address(eve)), EVE_CHIPS);
        assertEq(chip.balanceOf(address(router)), 0);
        assertEq(router.escrowed(address(chip)), 0);
    }

    function test_attack_fillPastTheCutoff_refunds() public {
        _open();
        uint64 cutoff = hook.getConfig(roundId).cutoff;
        _warp(cutoff - 2);
        uint256 atCutoff = eve.commit(roundId, HIGHER, true, 100e18, 1_000e18);
        uint256 alsoAtCutoff = eve.commit(roundId, LOWER, true, 100e18, 1_000e18);
        assertEq(router.getCommit(atCutoff).fillTs, cutoff);
        // one second later commits are not taken
        _warp(cutoff - 1);
        vm.expectRevert(IFallpitRouter.OutsideTradingWindow.selector);
        eve.commit(roundId, HIGHER, true, 100e18, 1_000e18);

        // the keeper was silent for three seconds: the first print at or after the cutoff instant came
        // after the cutoff, so there is no trade
        _warp(cutoff + 3);
        bytes memory late = _signedPrint(NVDA, S0, cutoff + 3, cutoff - 1);
        vm.expectEmit(true, true, false, true, address(router));
        emit Refunded(atCutoff, address(eve), RefundReason.Window);
        assertFalse(eve.fill(atCutoff, late));
        assertFalse(eve.fill(alsoAtCutoff, late));
        assertEq(chip.balanceOf(address(eve)), EVE_CHIPS);
        _assertPristine();
    }

    // --------------------------------------------------------------------------------------------
    // depth decay
    // --------------------------------------------------------------------------------------------

    /// @dev Buy at the open, hold while depth decays to its floor, sell at the same oracle price. The
    ///      rescale keeps every price where the buy left it, so the round trip only loses fees. Uses the
    ///      at-the-money pair at x = 0, where the passing of time itself moves the prior by well under
    ///      the fee, to isolate depth decay from ordinary time decay of an in-the-money token.
    function testFuzz_attack_depthDecayRoundTrip_neverProfits(
        uint256 shares,
        uint256 holdSeconds,
        bool higher
    ) public {
        shares = bound(shares, 1e18, 20_000e18);
        holdSeconds = bound(holdSeconds, 2, 22_000);
        uint8 index = higher ? HIGHER : LOWER;
        _open();

        (,,, uint256 pAfterBuy,,) = lens.quote(roundId, index, true, shares, S0, clock + 2);
        uint256 cost = _eveBuy(index, shares, S0);
        _warp(clock + uint64(holdSeconds));
        (,, uint256 pBeforeSell,,,) = lens.quote(roundId, index, false, shares, S0, clock + 2);
        uint256 proceeds = _eveSell(index, shares, S0);

        assertLt(proceeds, cost, "the round trip loses money");
        assertLe(_state().g, 1e18);
        // the price the attacker pushed up did not drift further up while depth decayed (0.5% covers the
        // prior's own drift at x = 0)
        assertLe(pBeforeSell, pAfterBuy + 0.005e18, "depth decay moves no price in the holder's favour");
        assertEq(chip.balanceOf(address(eve)), EVE_CHIPS - cost + proceeds);
        _assertHookSolvent(address(chip));
    }

    /// @dev The sharper variant: two traders. Bob's buy lands first; eve buys after him, depth decays to
    ///      its floor, and bob sells into the thinner book. Whatever the order, eve's own round trip at
    ///      one oracle price never ends above water.
    function testFuzz_attack_depthDecay_withAnotherTradersFlow_neverProfits(
        uint256 shares,
        uint256 others,
        uint256 holdSeconds,
        bool bobSellsFirst
    ) public {
        shares = bound(shares, 1e18, 20_000e18);
        others = bound(others, 1e18, 20_000e18);
        holdSeconds = bound(holdSeconds, 2, 22_000);
        _open();
        _buy(bob, HIGHER, others, S0);
        uint256 cost = _eveBuy(HIGHER, shares, S0);
        _warp(clock + uint64(holdSeconds));
        uint256 proceeds;
        if (bobSellsFirst) {
            _sell(bob, HIGHER, others, S0);
            proceeds = _eveSell(HIGHER, shares, S0);
        } else {
            proceeds = _eveSell(HIGHER, shares, S0);
            _sell(bob, HIGHER, others, S0);
        }
        assertLt(proceeds, cost, "eve's round trip loses money");
        assertGe(_state().held, HOUSE_CAPITAL, "and the house is no worse off at an unchanged oracle price");
    }

    /// @dev A complete set has no exposure at all; carrying it across any decay and any oracle move
    ///      returns less than it cost. On the default menu there are
    ///      four ways to hold every band exactly once: the pair, the eight floors, the four lower floors
    ///      with HIGHER, LOWER with the four upper floors. (test/integration/Floors.t.sol has the sharper
    ///      statement: bought at one print, a set costs at least its payout before any fee.)
    /// forge-config: default.fuzz.runs = 96
    function testFuzz_attack_completeSetAcrossDecay_neverProfits(
        uint256 shares,
        uint256 holdSeconds,
        uint256 move,
        uint256 kind
    ) public {
        shares = bound(shares, 1e18, 20_000e18);
        holdSeconds = bound(holdSeconds, 2, 22_000);
        move = bound(move, 960, 1040);
        uint8[] memory set = _completeSet(bound(kind, 0, 3));
        _open();
        uint256 cost;
        for (uint256 i; i < set.length; ++i) {
            cost += _eveBuy(set[i], shares, S0);
        }
        assertGe(cost, shares, "a complete set never costs less than its payout");
        _warp(clock + uint64(holdSeconds));
        uint256 price = S0 * move / 1000;
        uint256 proceeds;
        for (uint256 i; i < set.length; ++i) {
            proceeds += _eveSell(set[i], shares, price);
        }
        assertLt(proceeds, shares, "and never sells for more");
    }

    /// @dev The ways to hold every band of the default menu exactly once.
    function _completeSet(uint256 kind) internal pure returns (uint8[] memory set) {
        if (kind == 0) {
            set = new uint8[](2);
            (set[0], set[1]) = (HIGHER, LOWER);
        } else if (kind == 1) {
            set = new uint8[](8);
            for (uint8 i; i < 8; ++i) {
                set[i] = i;
            }
        } else if (kind == 2) {
            set = new uint8[](5);
            (set[0], set[1], set[2], set[3], set[4]) = (F0, F1, F2, F3, HIGHER);
        } else {
            set = new uint8[](5);
            (set[0], set[1], set[2], set[3], set[4]) = (LOWER, F4, F5, F6, F7);
        }
    }

    // --------------------------------------------------------------------------------------------
    // one-sided flow
    // --------------------------------------------------------------------------------------------

    /// @dev Everybody buys HIGHER at the per-fill cap, again and again, while the price runs up. (A
    ///      narrow product is a floor and stops at its product cap: see `LossLimit.t.sol`. Only the pair
    ///      can have more claims outstanding than the house brought.)
    function test_attack_oneSidedFlow_staysSolvent_andPaysEveryWinner() public {
        _open();
        PitAttacker[4] memory gang;
        for (uint256 i; i < 4; ++i) {
            gang[i] = _attacker(address(chip), 2_000_000e18);
        }
        uint256 price = S0;
        uint256 totalCost;
        for (uint256 i; i < 80; ++i) {
            PitAttacker a = gang[i % 4];
            if (i % 10 == 9) price = price * 1004 / 1000;
            uint256 before = chip.balanceOf(address(a));
            uint256 id = a.commit(roundId, HIGHER, true, 20_000e18, before);
            bool filled = a.fill(id, _printFor(id, price));
            totalCost += before - chip.balanceOf(address(a));
            (uint256 worst, uint256 covered) = lens.solvency(roundId);
            assertLe(worst, covered, "worst-case payout is covered after every fill");
            if (!filled) break;
        }
        _assertSupplies();
        uint256 supply = _token(HIGHER).totalSupply();
        assertGt(supply, HOUSE_CAPITAL, "more winning claims outstanding than the house brought");

        // the close lands above the previous close: every one of those tokens wins
        _closeAndFinalize(S0 * 105 / 100);
        assertEq(_state().payoutOwed, supply);
        uint256 paid;
        for (uint256 i; i < 4; ++i) {
            uint256 balance = _token(HIGHER).balanceOf(address(gang[i]));
            paid += i % 2 == 0
                ? gang[i].redeem(_token(HIGHER).id, balance)
                : gang[i].redeemDirect(_token(HIGHER).id, balance);
        }
        assertEq(paid, supply, "every winner is paid in full");
        uint256 fees = hook.collectProtocolFees(address(chip));
        // the house never loses more than it brought, and the books close to the unit
        uint256 back = chip.balanceOf(address(vault));
        assertEq(HOUSE_CAPITAL + totalCost, paid + back + fees, "cash conservation");
        assertEq(chip.balanceOf(address(hook)), 0);
        emit log_named_decimal_uint("gang paid", totalCost, 18);
        emit log_named_decimal_uint("gang won", paid, 18);
        emit log_named_decimal_int(
            "house result, share of its capital (1e18 = all)",
            (int256(back) - int256(HOUSE_CAPITAL)) * 1e18 / int256(HOUSE_CAPITAL),
            18
        );
        // the day's loss stays far below the capital: the token goes to one chip and from there every
        // token is paid for in full. At the default alpha of 0.2 the book is shallower, the
        // token reaches one chip sooner and the house ends the day slightly ahead (at alpha 0.3 the
        // house loses a few percent on this path)
        assertGt(back, HOUSE_CAPITAL * 55 / 100);
        assertLt(back, HOUSE_CAPITAL * 102 / 100);
    }

    /// @dev With the real engine one-sided buying alone cannot reach the pooled solvency limit: the price
    ///      of the token being bought goes to one chip long before, and from there every token is paid
    ///      for in full. What reaches it is the worst day there is: the stock whipsaws between 8% down and
    ///      6% up, again and again, and a gang buys HIGHER at lottery prices at every low (the minimum
    ///      price: four sigma down, HIGHER is as far away as a far strike, and it has no product cap) and sells it back near one chip at every high, until the round can pay no
    ///      more. The hook never
    ///      owes more than it holds: the house can lose what it brought, never more; every fill it cannot
    ///      cover is refused and refunded; every winner is paid; and the vault survives a near-total loss.
    ///
    ///      Note (per-round loss limit). This scenario is what the loss limit is for, and with the default
    ///      limit it ends with the house keeping 70% of its capital: see
    ///      `test_attack_whipsaw_lossLimitStopsTheBuying_houseKeepsSeventyPercent` below. Here the limit is switched
    ///      off (`lossLimitBps = 10000`, the owner's upper bound), so that the last line of defence, the
    ///      pooled solvency check, stays covered in its worst case.
    function test_attack_whipsawToTheSolvencyLimit_limitOff_houseLosesAtMostItsCapital() public {
        // a 10% per-fill cap keeps the number of fills (each about 4M gas) manageable
        IPitBook.Params memory p = book.defaultParams();
        p.maxFillBps = 1000;
        p.lossLimitBps = 10_000;
        _setParams(p);
        _open();
        uint256 cap = hook.getConfig(roundId).maxFill;
        assertEq(cap, 100_000e18);
        PitAttacker gang = _attacker(address(chip), 3_000_000e18);
        uint256 start = chip.balanceOf(address(gang));
        uint256 low = S0 * 92 / 100;
        uint256 high = S0 * 106 / 100;

        bool refused;
        uint256 cycles;
        for (; cycles < 12 && !refused; ++cycles) {
            // at the low: buy while a capped fill still costs under half a chip per token
            for (uint256 k; k < 6; ++k) {
                (uint256 quoted,,,,,) = lens.quote(roundId, HIGHER, true, cap, low, clock + 2);
                if (quoted > cap / 2) break;
                if (!_tryTrade(gang, HIGHER, true, cap, low)) {
                    refused = true;
                    break;
                }
                _assertCovered();
            }
            if (refused) break;
            // at the high: sell everything back, as much as the round can pay
            uint256 balance = _token(HIGHER).balanceOf(address(gang));
            while (balance != 0) {
                uint256 lot = balance > cap ? cap : balance;
                if (!_tryTrade(gang, HIGHER, false, lot, high)) {
                    refused = true;
                    break;
                }
                _assertCovered();
                balance -= lot;
            }
        }
        assertTrue(refused, "scenario: the solvency limit was reached");
        IFallpitHook.RoundState memory open = _state();
        uint256 supply = _token(HIGHER).totalSupply();
        emit log_named_uint("whipsaw cycles before a fill was refused", cycles);
        emit log_named_decimal_uint("chips left in the round", open.held, 18);
        emit log_named_decimal_uint("winning-side tokens outstanding", supply, 18);
        emit log_named_decimal_int(
            "gang's cash result so far", int256(chip.balanceOf(address(gang))) - int256(start), 18
        );
        assertLe(supply + open.protocolFees, open.held, "what is outstanding is covered");
        assertLt(open.held, HOUSE_CAPITAL, "the round has paid out more than traders put in");
        assertEq(chip.balanceOf(address(router)), 0, "the refused fill was refunded");
        _assertSupplies();
        _assertHookSolvent(address(chip));

        // the close lands above the previous close: whatever the gang still holds wins and is paid in full
        _closeAndFinalize(high);
        uint256 paid = supply == 0 ? 0 : gang.redeem(_token(HIGHER).id, supply);
        assertEq(paid, supply, "every winner is paid in full");
        uint256 back = chip.balanceOf(address(vault));
        assertEq(back, open.held - supply - open.protocolFees);
        uint256 gangWon = chip.balanceOf(address(gang)) - start;
        uint256 fees = hook.collectProtocolFees(address(chip));
        emit log_named_decimal_uint("gang's total winnings", gangWon, 18);
        emit log_named_decimal_uint("left of the house's 1,000,000", back, 18);
        assertEq(
            gangWon + fees, HOUSE_CAPITAL - back, "what the gang and the protocol got is what the house lost"
        );
        assertLe(gangWon, HOUSE_CAPITAL, "never more than the house brought");
        assertLt(back, HOUSE_CAPITAL / 2, "scenario: the house lost most of its capital");

        // the hook closes its books to the unit and the vault is not bricked
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, 0);
        assertEq(owed, 0);
        assertEq(chip.balanceOf(address(hook)), 0);
        PitVault.House memory h = vault.getHouse(house);
        assertEq(h.lpAssets + h.endowment, back);
        assertFalse(h.locked);
        // the LP's shares are worth what is left, and the house takes new capital and opens again
        uint256 lpShares = vault.balanceOf(lp, uint256(house));
        assertLe(vault.convertToAssets(house, lpShares), back);
        _lpDeposit(bob, house, 50_000e18);
        day += 1;
        roundId = hook.openRound(NVDA, address(chip), day);
        assertEq(hook.getConfig(roundId).capital, back + 50_000e18);
        _assertVaultBacked(address(chip));
    }

    /// @dev The same worst day with the default loss limit of 30%. (With the
    ///      limit switched off this scenario runs to the solvency limit and the house loses about
    ///      970,000: that case is above.) The gang keeps trying for eight swings. Every buy that would
    ///      leave the house less than 70% of its capital in the worst outcome is refused and refunded
    ///      (`LossLimit`), the lens says so beforehand, every sell still fills while buys are blocked,
    ///      and the house ends the day with at least 70% of what it brought: the gang trades one token
    ///      only, and a sell of it can never take the cushion under the floor (SPEC 7.5): the whipsaw gang takes exactly the limit.
    function test_attack_whipsaw_lossLimitStopsTheBuying_houseKeepsSeventyPercent() public {
        IPitBook.Params memory p = book.defaultParams();
        assertEq(p.lossLimitBps, 3000);
        p.maxFillBps = 1000;
        _setParams(p);
        _open();
        uint256 cap = hook.getConfig(roundId).maxFill;
        PitAttacker gang = _attacker(address(chip), 3_000_000e18);
        uint256 start = chip.balanceOf(address(gang));
        uint256 low = S0 * 92 / 100;
        uint256 high = S0 * 106 / 100;
        uint256 floor = HOUSE_CAPITAL * 7 / 10;

        uint256 refusedBuys;
        uint256 sellsWhileBlocked;
        uint256 lowestCushion = HOUSE_CAPITAL;
        for (uint256 cycles; cycles < 8; ++cycles) {
            // at the low: buy while a capped fill still costs under half a chip per token
            bool blocked;
            for (uint256 k; k < 6; ++k) {
                (uint256 quoted,,,,, RefundReason rejection) =
                    lens.quote(roundId, HIGHER, true, cap, low, clock + 2);
                if (quoted > cap / 2) break;
                bool filled = _tryTrade(gang, HIGHER, true, cap, low);
                assertEq(filled, rejection == RefundReason.None, "the lens foresaw it");
                if (!filled) {
                    assertEq(uint8(rejection), uint8(RefundReason.LossLimit));
                    ++refusedBuys;
                    blocked = true;
                    // a smaller lot may still fit under the limit (at 30% the first lot of a cycle is
                    // what gets refused once the swings have taken the house near the floor); the
                    // gang takes it, so that it holds something to sell while buys are blocked
                    for (uint256 small = cap / 5; small >= cap / 500; small /= 10) {
                        if (_tryTrade(gang, HIGHER, true, small, low)) break;
                    }
                    break;
                }
                (uint256 afterBuy, uint256 limitFloor) = lens.lossLimit(roundId);
                assertEq(limitFloor, floor);
                assertGe(afterBuy, floor, "every buy that fills leaves the house 70% of its capital");
                if (afterBuy < lowestCushion) lowestCushion = afterBuy;
            }
            // at the high: sell everything back. A sell is never refused for the loss limit.
            uint256 balance = _token(HIGHER).balanceOf(address(gang));
            while (balance != 0) {
                uint256 lot = balance > cap ? cap : balance;
                assertTrue(_tryTrade(gang, HIGHER, false, lot, high), "holders can always exit");
                if (blocked) ++sellsWhileBlocked;
                balance -= lot;
                _assertCovered();
                (uint256 afterSell,) = lens.lossLimit(roundId);
                if (afterSell < lowestCushion) lowestCushion = afterSell;
            }
        }
        assertGt(refusedBuys, 0, "scenario: the loss limit was reached");
        assertGt(sellsWhileBlocked, 0, "scenario: sells filled after a buy was refused");
        assertGe(lowestCushion, floor, "selling the one token back never took the cushion under the floor");
        assertEq(chip.balanceOf(address(router)), 0, "every refused buy was refunded");
        _assertSupplies();
        _assertHookSolvent(address(chip));

        IFallpitHook.RoundState memory open = _state();
        assertEq(_token(HIGHER).totalSupply(), 0);
        _closeAndFinalize(high);
        uint256 back = chip.balanceOf(address(vault));
        assertEq(back, open.held - open.protocolFees);
        uint256 gangWon = chip.balanceOf(address(gang)) - start;
        uint256 fees = hook.collectProtocolFees(address(chip));
        emit log_named_uint("buys refused by the loss limit", refusedBuys);
        emit log_named_uint("sells filled while buys were blocked", sellsWhileBlocked);
        emit log_named_decimal_uint("lowest worst-case cushion of the day", lowestCushion, 18);
        emit log_named_decimal_uint("gang's total winnings", gangWon, 18);
        emit log_named_decimal_uint("left of the house's 1,000,000", back, 18);
        assertEq(
            gangWon + fees, HOUSE_CAPITAL - back, "what the gang and the protocol got is what the house lost"
        );
        assertGe(back, floor, "the house keeps at least 70% of what it brought");
        assertLt(back, HOUSE_CAPITAL * 4 / 5, "scenario: the limit was what stopped the loss");
    }

    function _assertCovered() internal view {
        (uint256 worst, uint256 covered) = lens.solvency(roundId);
        assertLe(worst, covered, "worst-case payout is covered after every fill");
    }

    // --------------------------------------------------------------------------------------------
    // rounding
    // --------------------------------------------------------------------------------------------

    /// @dev The rounds of the dust tests allow the smallest trade the book's bounds permit (1e12 wei of a
    ///      token, one unit of a 6-decimal chip). A commit below the round's minimum trade is refused, so
    ///      true one-unit dust does not reach the engine on an 18-decimal chip; the loops run at the
    ///      smallest size that does.
    function _allowDust() internal {
        IPitBook.Params memory p = book.defaultParams();
        p.minTrade = 1e12;
        _setParams(p);
    }

    function test_attack_dustBelowTheMinimumTrade_isRefusedAtCommit() public {
        _open();
        // default minimum: one whole token, for buys and for sells
        vm.expectRevert(IFallpitRouter.BelowMinimumTrade.selector);
        eve.commit(roundId, HIGHER, true, 1e18 - 1, 1e18);
        vm.expectRevert(IFallpitRouter.BelowMinimumTrade.selector);
        eve.commit(roundId, HIGHER, true, 1, 1e18);
        _eveBuy(HIGHER, 1e18, S0);
        vm.expectRevert(IFallpitRouter.BelowMinimumTrade.selector);
        eve.commit(roundId, HIGHER, false, 1e18 - 1, 0);
        // a keeper never has to price dust: nothing below the minimum is ever pending
        assertEq(router.escrowed(address(chip)), 0);

        // on a 6-decimal chip the same minimum is one whole token of 1e6 units
        MockChip usd = new MockChip(6);
        vm.prank(owner);
        guard.approve(address(usd), true);
        _use(NVDA, address(usd));
        _lpDeposit(lp, house, 100_000e6);
        roundId = hook.openRound(NVDA, address(usd), day);
        PitAttacker a = _attacker(address(usd), 1_000e6);
        vm.expectRevert(IFallpitRouter.BelowMinimumTrade.selector);
        a.commit(roundId, HIGHER, true, 1e6 - 1, 1e6);
        a.commit(roundId, HIGHER, true, 1e6, 1e6);
    }

    function test_attack_dustLoops_loseMoney() public {
        _allowDust();
        _open();
        uint256 unit = 1e12; // the smallest trade
        uint256 balance = chip.balanceOf(address(eve));
        for (uint256 i; i < 40; ++i) {
            uint8 index = uint8(i % PRODUCTS);
            uint256 shares = (1 + i % 3) * unit; // 1 to 3 times the minimum
            uint256 cost = _eveBuy(index, shares, S0);
            uint256 proceeds = _eveSell(index, shares, S0);
            assertGt(cost, proceeds, "a dust round trip never pays");
            uint256 now_ = chip.balanceOf(address(eve));
            assertLt(now_, balance, "the attacker's balance only goes down");
            balance = now_;
        }
        // many dust buys, one sell
        uint256 spent;
        for (uint256 i; i < 25; ++i) {
            spent += _eveBuy(HIGHER, 7 * unit, S0);
        }
        assertGt(spent, _eveSell(HIGHER, 175 * unit, S0));
        // one buy, many dust sells
        spent = _eveBuy(LOWER, 500 * unit, S0);
        uint256 got;
        for (uint256 i; i < 25; ++i) {
            got += _eveSell(LOWER, 20 * unit, S0);
        }
        assertGt(spent, got);
        assertGe(_state().held, HOUSE_CAPITAL, "the house never lost a unit to rounding");
        _assertSupplies();
        _assertHookSolvent(address(chip));
    }

    function test_attack_dustLoops_sixDecimals() public {
        _allowDust();
        MockChip usd = new MockChip(6);
        vm.prank(owner);
        guard.approve(address(usd), true);
        _use(NVDA, address(usd));
        _lpDeposit(lp, house, 100_000e6);
        _open();
        PitAttacker a = _attacker(address(usd), 1_000e6);
        uint256 balance = 1_000e6;
        for (uint256 i; i < 30; ++i) {
            uint8 index = uint8(i % PRODUCTS);
            uint256 id = a.commit(roundId, index, true, 1 + i % 4, 1e6);
            assertTrue(a.fill(id, _printFor(id, S0)));
            a.approve(_token(index).id, address(router));
            id = a.commit(roundId, index, false, 1 + i % 4, 0);
            assertTrue(a.fill(id, _printFor(id, S0)));
            uint256 now_ = usd.balanceOf(address(a));
            assertLt(now_, balance);
            balance = now_;
        }
        assertGe(_state().held, 100_000e6);
        _assertHookSolvent(address(usd));
    }

    /// @dev Splitting a trade into pieces priced by the same print never beats the single trade: the
    ///      engine's safety margins and every per-unit rounding go to the house. (Pieces priced at later
    ///      prints differ by the passing of time, which is the market moving, not rounding.) `SLACK` is the
    ///      engine's own error allowance on one cost evaluation at this depth, about 1e-11 of a chip.
    function testFuzz_attack_splitting_neverBeatsOneTrade(uint256 shares, uint8 pieces, uint8 index) public {
        uint256 slack = 1e8;
        shares = bound(shares, 12e18, 5_000e18); // every piece at least the minimum trade of one token
        uint256 n = bound(pieces, 2, 12);
        index = uint8(index % PRODUCTS);
        _open();
        eve.approve(_token(index).id, address(router));
        uint256 snapshot = vm.snapshotState();
        uint256 whole = _eveBuy(index, shares, S0);
        uint256 wholeBack = _eveSell(index, shares, S0);
        vm.revertToState(snapshot);

        uint256 split = _splitTrade(index, true, shares, n);
        assertGe(split + slack, whole, "splitting a buy is never cheaper");
        uint256 splitBack = _splitTrade(index, false, shares, n);
        assertLe(splitBack, wholeBack + slack, "splitting a sell never pays more");
        assertLt(splitBack, split, "and the round trip loses either way");
    }

    /// @dev `n` commits made in one second, so one print prices them all, filled one after the other.
    function _splitTrade(uint8 index, bool isBuy, uint256 shares, uint256 n)
        internal
        returns (uint256 chips)
    {
        uint256 before = chip.balanceOf(address(eve));
        uint256 piece = shares / n;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = eve.commit(
                roundId,
                index,
                isBuy,
                i + 1 == n ? shares - piece * (n - 1) : piece,
                isBuy ? EVE_CHIPS / n : 0
            );
        }
        bytes memory print = _printFor(ids[0], S0);
        for (uint256 i; i < n; ++i) {
            assertTrue(eve.fill(ids[i], print));
        }
        uint256 afterwards = chip.balanceOf(address(eve));
        chips = isBuy ? before - afterwards : afterwards - before;
    }

    // --------------------------------------------------------------------------------------------
    // griefing by filling the cap
    // --------------------------------------------------------------------------------------------

    /// @dev Eve takes every capped fill of the at-the-money HIGHER token she can afford, to price honest
    ///      buyers out. It never blocks the round: a buyer of the same token is filled or refunded in the
    ///      same call (never stuck), the other side gets cheaper, and eve's own exit returns less than
    ///      she put in. Griefing is paid for by the griefer.
    function test_attack_capGriefing_costsTheGriefer_andBlocksNobody() public {
        _open();
        chip.mint(address(eve), 1_800_000e18);
        uint256 eveStart = chip.balanceOf(address(eve));
        (uint256 fairHigher,,,,,) = lens.quote(roundId, HIGHER, true, 1_000e18, S0, clock + 2);
        (uint256 fairLower,,,,,) = lens.quote(roundId, LOWER, true, 1_000e18, S0, clock + 2);

        uint256 fills;
        for (uint256 i; i < 40; ++i) {
            if (!_tryTrade(eve, HIGHER, true, 20_000e18, S0)) break;
            ++fills;
        }
        assertEq(fills, 40, "the solvency check never stood in her way: she paid for what she holds");
        uint256 eveSpent = eveStart - chip.balanceOf(address(eve));
        uint256 held = _token(HIGHER).balanceOf(address(eve));
        assertEq(held, 800_000e18);
        assertGt(eveSpent, held * 80 / 100, "she paid on average over 0.80 for a coin flip");

        // alice still gets the same token (at eve's inflated price, protected by her own limit) ...
        (uint256 dearHigher,,,,,) = lens.quote(roundId, HIGHER, true, 1_000e18, S0, clock + 2);
        assertGt(dearHigher, fairHigher * 15 / 10);
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, fairHigher * 11 / 10);
        assertFalse(_fill(id, S0), "her limit refunds her instead of overpaying");
        assertEq(chip.balanceOf(alice), STAKE);
        id = _commitBuy(alice, HIGHER, 1_000e18, STAKE);
        assertTrue(_fill(id, S0), "and without a tight limit the fill goes through");
        // ... and bob gets the other side for a fraction of its fair price, at eve's expense
        uint256 bobCost = _buy(bob, LOWER, 20_000e18, S0);
        assertLt(bobCost, fairLower * 20 / 2, "LOWER is on sale");

        // eve unwinds: every sell fills, and she is out of pocket
        uint256 back;
        for (uint256 i; i < 40; ++i) {
            back += _eveSell(HIGHER, 20_000e18, S0);
        }
        assertLt(back, eveSpent, "the griefer paid for the griefing");
        emit log_named_decimal_uint("griefer spent", eveSpent, 18);
        emit log_named_decimal_uint("griefer got back", back, 18);
        _assertSupplies();
        _assertHookSolvent(address(chip));
        assertGt(_state().held, HOUSE_CAPITAL, "the round is richer for it");
    }

    /// @dev The product cap opens a griefing of its own: whoever holds a floor's whole cap keeps everybody
    ///      else out of that floor until she sells. Eve fills the cap of the far floor (above +2 sigma), the
    ///      cheapest to corner. What it does: honest buyers of that floor are refunded, never stuck (the
    ///      lens says `ProductCap` beforehand; a commit sent anyway costs its sender the fill fee, which
    ///      goes to the filler like for any final rejection). What it does not do: block any other
    ///      product, the half of the pair over the same bands included. What it costs: eve paid for
    ///      100,000 tokens, at least the minimum price each, holds a real position for it, and gets back
    ///      less than she paid if she unwinds at an unchanged price. The round opens with a product cap
    ///      of a tenth of the capital per floor: the default has no product cap,
    ///      which also ends this griefing; the mechanism stays for an owner who sets a cap.
    function test_attack_capGriefing_onAFloor_locksOnlyThatFloor_atACost() public {
        IPitBook.Params memory p = book.defaultParams();
        p.floorCapBps = 1000;
        _setParams(p);
        _open();
        uint256 eveStart = chip.balanceOf(address(eve));
        for (uint256 i; i < 5; ++i) {
            assertTrue(_tryTrade(eve, F7, true, 20_000e18, S0));
        }
        uint256 eveSpent = eveStart - chip.balanceOf(address(eve));
        assertEq(_token(F7).totalSupply(), HOUSE_CAPITAL / 10, "the floor is at its cap");
        assertGt(eveSpent, 100_000e18 * 2 / 100, "at least the minimum price for every token");
        emit log_named_decimal_uint("chips it took to corner the far floor", eveSpent, 18);

        // alice is kept out of that floor: told so by the lens, refunded by the hook if she tries
        (,,,,, RefundReason rejection) = lens.quote(roundId, F7, true, 1e18, S0, clock + 2);
        assertEq(uint8(rejection), uint8(RefundReason.ProductCap));
        uint256 ethBefore = alice.balance;
        uint256 id = _commitBuy(alice, F7, 1e18, STAKE);
        bytes memory report = _printFor(id, S0);
        vm.expectEmit(true, true, false, true, address(router));
        emit Refunded(id, alice, RefundReason.ProductCap);
        vm.prank(keeper);
        assertFalse(router.fill(id, report));
        assertEq(chip.balanceOf(alice), STAKE, "her chips came back");
        assertEq(ethBefore - alice.balance, FILL_FEE, "the fill fee went to the filler");
        // everything else trades: the floor next door, and HIGHER, which pays in the same bands
        _buy(alice, F6, 1_000e18, S0);
        _buy(alice, HIGHER, 1_000e18, S0);
        _buy(bob, F0, 1_000e18, S0);

        // eve unwinds at the same oracle price: every sell fills, she is out of pocket, the floor reopens
        uint256 back;
        for (uint256 i; i < 5; ++i) {
            back += _eveSell(F7, 20_000e18, S0);
        }
        assertLt(back, eveSpent, "the griefer paid for the griefing");
        emit log_named_decimal_uint("of which she got back", back, 18);
        _buy(alice, F7, 1_000e18, S0);
        _assertSupplies();
        _assertHookSolvent(address(chip));
    }

    // --------------------------------------------------------------------------------------------
    // sandwich
    // --------------------------------------------------------------------------------------------

    /// @dev Eve sees alice's commit, commits a buy in the same second, fills her own first and alice's
    ///      second, then sells. Two-step fills make the exit wait for a later print (price risk the test
    ///      leaves out, in eve's favour); the same fee on buys and sells and alice's own limit are the
    ///      defence. With a limit 1% above her quote alice is refunded and eve is left with a losing
    ///      round trip. With no limit at all, on a trade of the full per-fill cap, eve's gain is bounded by
    ///      what alice overpaid against her quote.
    function test_attack_sandwich_boundedByTheVictimsLimit() public {
        _open();
        uint256 shares = 20_000e18; // the per-fill cap: the largest price impact one fill can have
        (uint256 quote,,,,,) = lens.quote(roundId, HIGHER, true, shares, S0, clock + 2);

        // --- eve's commit lands after alice's in the same second: she cannot fill ahead of it
        //     (commits of one second fill in commit order)
        uint256 snapshot = vm.snapshotState();
        uint256 aliceId = _commitBuy(alice, HIGHER, shares, quote * 101 / 100);
        uint256 eveId = _commit(eve, HIGHER, true, shares);
        bytes memory print = _printFor(aliceId, S0);
        vm.expectRevert(abi.encodeWithSelector(IFallpitRouter.EarlierCommitPending.selector, aliceId));
        eve.fill(eveId, print);
        vm.revertToState(snapshot);

        // --- eve guessed and committed first in the same second; alice protects herself with a limit 1%
        //     above the quote she saw
        snapshot = vm.snapshotState();
        eveId = _commit(eve, HIGHER, true, shares);
        aliceId = _commitBuy(alice, HIGHER, shares, quote * 101 / 100);
        print = _printFor(aliceId, S0);
        assertTrue(eve.fill(eveId, print), "eve front-runs");
        assertFalse(eve.fill(aliceId, print), "alice's fill would cost more than her limit: refunded");
        assertEq(chip.balanceOf(alice), STAKE, "alice lost nothing");
        uint256 evePaid = EVE_CHIPS - chip.balanceOf(address(eve));
        uint256 eveBack = _eveSell(HIGHER, shares, S0);
        assertLt(eveBack, evePaid, "eve's front-run is a losing round trip");
        vm.revertToState(snapshot);

        // --- alice sends a market order: her whole balance as the limit (eve first again)
        eveId = _commit(eve, HIGHER, true, shares);
        aliceId = _commitBuy(alice, HIGHER, shares, STAKE);
        print = _printFor(aliceId, S0);
        assertTrue(eve.fill(eveId, print));
        assertTrue(eve.fill(aliceId, print));
        uint256 alicePaid = STAKE - chip.balanceOf(alice);
        evePaid = EVE_CHIPS - chip.balanceOf(address(eve));
        eveBack = _eveSell(HIGHER, shares, S0);
        emit log_named_decimal_uint("alice's quote", quote, 18);
        emit log_named_decimal_uint("alice paid", alicePaid, 18);
        emit log_named_decimal_int("eve's result", int256(eveBack) - int256(evePaid), 18);
        assertGt(alicePaid, quote, "alice overpaid: this is what a limit is for");
        assertLt(
            int256(eveBack) - int256(evePaid),
            int256(alicePaid - quote),
            "eve gains less than alice's slippage: the fees on both legs come out of it"
        );
        assertGe(
            _state().held, HOUSE_CAPITAL + quote, "the house is no worse off than if alice had traded alone"
        );
    }

    // --------------------------------------------------------------------------------------------
    // gas starvation
    // --------------------------------------------------------------------------------------------

    /// @dev A filler who starves the fill of gas must not be able to turn it into a refund: at every gas
    ///      limit the fill either reverts (the commit stays pending) or executes. With the real engine
    ///      (about 2.2M gas inside the math call) and the real oracle.
    function test_attack_gasStarvation_neverRefunds() public {
        _open();
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        bytes memory report = _printFor(id, S0);
        uint256 snapshot = vm.snapshotState();
        uint256 executed;
        for (uint256 gasLimit = 60_000; gasLimit <= 6_000_000; gasLimit += 90_000) {
            try router.fill{gas: gasLimit}(id, report) returns (bool filled) {
                assertTrue(filled, "a fill that returns must have executed, never refunded");
                ++executed;
            } catch {
                assertEq(
                    uint8(router.getCommit(id).status),
                    uint8(IFallpitRouter.CommitStatus.Pending),
                    "still pending"
                );
            }
            vm.revertToState(snapshot);
        }
        assertGt(executed, 0);
        assertEq(chip.balanceOf(alice), STAKE - 10_000e18, "the escrow stayed in the router throughout");
    }
}
