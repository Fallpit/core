// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {HookFixture} from "./HookFixture.sol";
import {MockChip, MockFeeChip, ReentrantChip} from "./mocks/MockChips.sol";
import {PitAttacker, GiveawayMath} from "./mocks/PitAttacker.sol";
import {FallpitHook} from "../../src/FallpitHook.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {Menus} from "../Menus.sol";

/// @notice Adversarial tests. Every attack runs from an attacker contract (`PitAttacker`) or a hostile
///         chip.
contract FallpitAttacksTest is HookFixture {
    PitAttacker internal eve;
    uint256 internal constant EVE_CHIPS = 200_000e18;

    event Refunded(uint256 indexed commitId, address indexed user, RefundReason reason);

    function setUp() public override {
        super.setUp();
        eve = _attacker(address(chip), EVE_CHIPS);
        _fund(alice, 100_000e18);
        _fund(bob, 100_000e18);
    }

    function _attacker(address chip_, uint256 amount) internal returns (PitAttacker a) {
        a = new PitAttacker{value: 10 ether}(router, hook);
        MockChip(chip_).mint(address(a), amount);
        a.approve(chip_, address(router));
    }

    /// @dev Warps to the commit's fill instant and returns the keeper print for it.
    function _printFor(uint256 id, uint256 price) internal returns (bytes memory) {
        uint64 t = router.getCommit(id).fillTs;
        if (clock < t) _warp(t);
        return _report(t, price);
    }

    function _eveBuy(uint8 index, uint256 shares, uint256 price) internal returns (uint256 cost) {
        uint256 before = chip.balanceOf(address(eve));
        uint256 id = eve.commit(roundId, index, true, shares, before);
        require(eve.fill(id, _printFor(id, price)), "eve buy refunded");
        cost = before - chip.balanceOf(address(eve));
    }

    /// @dev A buy that the hook may refuse (a floor at its cap): `filled` false and nothing spent then.
    function _eveTryBuy(uint8 index, uint256 shares, uint256 price)
        internal
        returns (bool filled, uint256 cost)
    {
        uint256 before = chip.balanceOf(address(eve));
        uint256 id = eve.commit(roundId, index, true, shares, before);
        filled = eve.fill(id, _printFor(id, price));
        cost = before - chip.balanceOf(address(eve));
    }

    function _eveSell(uint8 index, uint256 shares, uint256 price) internal returns (uint256 proceeds) {
        uint256 before = chip.balanceOf(address(eve));
        eve.approve(_token(index).id, address(router));
        uint256 id = eve.commit(roundId, index, false, shares, 0);
        require(eve.fill(id, _printFor(id, price)), "eve sell refunded");
        proceeds = chip.balanceOf(address(eve)) - before;
    }

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

    /// @dev Commits of one second fill in commit order, so commits that can never
    ///      trade sit in front of an honest one in the same second. The keeper clears them in order (each
    ///      a refund that pays the keeper the fee the attacker attached) and the honest commit fills in its
    ///      window. Commits nobody touches hold a later commit only until their own window ends.
    function test_attack_neverFillableCommits_cannotGriefTheRound() public {
        _open();
        uint256[] memory ids = new uint256[](30);
        for (uint256 i; i < 15; ++i) {
            ids[i] = eve.commit(roundId, uint8(i % PRODUCTS), true, 1e18, 1 + i);
        }
        // honest trading in the same second: it waits for eve's commits, which the keeper clears in order
        uint256 aliceBefore = chip.balanceOf(alice);
        uint256 aliceId = _commitBuy(alice, HIGHER, 1_000e18, aliceBefore);
        uint64 t = router.getCommit(aliceId).fillTs;
        _warp(t);
        bytes memory report = _report(t, S0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IFallpitRouter.EarlierCommitPending.selector, ids[14]));
        router.fill(aliceId, report);
        uint256 keeperBefore = keeper.balance;
        for (uint256 i; i < 15; ++i) {
            vm.prank(keeper);
            assertFalse(router.fill(ids[i], report));
        }
        assertEq(keeper.balance - keeperBefore, 15 * _fillFee(), "eve paid the keeper for every one");
        assertTrue(_fill(aliceId, S0));
        assertGt(aliceBefore - chip.balanceOf(alice), 0);
        // fifteen more, left alone, in a later second: a later trade waits only until their window ends
        _warp(clock + 5);
        for (uint256 i = 15; i < 30; ++i) {
            ids[i] = eve.commit(roundId, uint8(i % PRODUCTS), true, 1e18, 1 + i);
        }
        _warp(clock + 1);
        uint256 later = _commitBuy(alice, LOWER, 10e18, chip.balanceOf(alice));
        uint64 laterTs = router.getCommit(later).fillTs;
        _warp(laterTs);
        bytes memory laterReport = _report(laterTs, S0);
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

        // the first print at or after the cutoff instant came after the cutoff: no trade
        _warp(cutoff + 3);
        bytes memory late = oracle.post(NVDA, KEEPER, S0, cutoff + 3);
        vm.expectEmit(true, true, false, true, address(router));
        emit Refunded(atCutoff, address(eve), RefundReason.Window);
        assertFalse(eve.fill(atCutoff, late));
        assertFalse(eve.fill(alsoAtCutoff, late));
        assertEq(chip.balanceOf(address(eve)), EVE_CHIPS);
        _assertPristine();
    }

    // --------------------------------------------------------------------------------------------
    // latency: nobody picks the print
    // --------------------------------------------------------------------------------------------

    function test_attack_latency_onlyTheUniquePrintFills() public {
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(id).fillTs;

        // the tape: a print just before t, the print for t, then the price runs up 2%
        bytes[] memory reports = new bytes[](5);
        reports[0] = oracle.post(NVDA, KEEPER, S0 * 97 / 100, t - 1); // cheaper, but before the instant
        reports[2] = oracle.post(NVDA, KEEPER, S0, t); // the one print for t
        reports[1] = oracle.post(NVDA, KEEPER, S0 * 96 / 100, t + 3); // cheaper, later
        reports[3] = oracle.post(NVDA, KEEPER, S0 * 102 / 100, t + 9);
        reports[4] = abi.encode(NVDA, KEEPER, uint256(99)); // a print that does not exist
        _warp(t + 10);

        // eve now knows HIGHER is worth more than at t. She tries every report in her preferred order
        // (cheapest first); only the print for t is accepted, so she pays the price at t, not a cheaper one.
        (uint256 fair,,,,,) = lens.quote(roundId, HIGHER, true, 5_000e18, S0, t);
        (uint256 cheap,,,,,) = lens.quote(roundId, HIGHER, true, 5_000e18, S0 * 96 / 100, t + 3);
        assertLt(cheap, fair);
        uint256 used = eve.fillWithAny(id, reports);
        assertEq(used, 2, "only the unique print at commit time plus fill delay fills");
        assertEq(EVE_CHIPS - chip.balanceOf(address(eve)), fair);
    }

    function test_attack_latency_cannotCancelAfterSeeingThePrice() public {
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(id).fillTs;
        bytes memory theOne = oracle.post(NVDA, KEEPER, S0, t);
        oracle.post(NVDA, KEEPER, S0 * 98 / 100, t + 5); // the price drops right after: eve regrets
        _warp(t + 6);

        // she cannot take the commit back, and cannot refund inside the fill window
        vm.expectRevert(IFallpitRouter.RefundNotDue.selector);
        eve.refund(id);
        // the keeper fills her at the price of t regardless
        vm.prank(keeper);
        assertTrue(router.fill(id, theOne));
        assertEq(_token(HIGHER).balanceOf(address(eve)), 5_000e18);
        vm.expectRevert(IFallpitRouter.CommitNotPending.selector);
        eve.refund(id);
    }

    function test_attack_latency_staleFillIsNotAnOption() public {
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, EVE_CHIPS);
        uint64 t = router.getCommit(id).fillTs;
        bytes memory theOne = oracle.post(NVDA, KEEPER, S0, t);
        // nobody filled for the whole window; the price is now 3% higher and eve wants the old price
        _warp(t + 31);
        oracle.post(NVDA, KEEPER, S0 * 103 / 100, t + 31);
        vm.expectRevert(IFallpitRouter.FillWindowClosed.selector);
        eve.fill(id, theOne);
        eve.refund(id);
        assertEq(chip.balanceOf(address(eve)), EVE_CHIPS);
        assertEq(_token(HIGHER).totalSupply(), 0);
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

    /// @dev A complete set has no exposure at all; carrying it across any decay and any oracle move
    ///      returns less than it cost. On a menu of floors there are several ways to hold every band exactly once: the pair, the eight floors, the four lower floors
    ///      with HIGHER, LOWER with the four upper floors. (The mock engine here; the real one is in
    ///      test/integration/Floors.t.sol.)
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

    function test_attack_oneSidedFlow_staysSolvent_andPaysEveryWinner() public {
        _open();
        PitAttacker[4] memory gang;
        for (uint256 i; i < 4; ++i) {
            gang[i] = _attacker(address(chip), 2_000_000e18);
        }
        // everybody buys HIGHER at the per-fill cap, again and again, while the price runs up. (A narrow
        // product is a floor and stops at its cap, see the next test. Only the pair can have more claims
        // outstanding than the house brought.)
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
        // the house lost, but never more than it brought, and the books close to the unit
        uint256 back = chip.balanceOf(address(vault));
        assertLt(back, HOUSE_CAPITAL);
        assertEq(HOUSE_CAPITAL + totalCost, paid + back + fees, "cash conservation");
        assertEq(chip.balanceOf(address(hook)), 0);
    }

    /// @dev The same gang on a floor, in a round with a product cap of a tenth of the capital per floor
    ///      (the default has no product cap; the mechanism stays for an owner who sets
    ///      one). A floor's outstanding supply stops at the cap: the sixth fill at the per-fill cap is
    ///      refunded with its own reason, whoever sends it, and what the house can lose on the floor is
    ///      that tenth less what the buyers paid. A sell makes room.
    function test_attack_oneSidedFlow_intoAFloor_stopsAtTheProductCap() public {
        IPitBook.Params memory p = book.defaultParams();
        p.floorCapBps = 1000;
        _setParams(p);
        _open();
        PitAttacker[4] memory gang;
        for (uint256 i; i < 4; ++i) {
            gang[i] = _attacker(address(chip), 2_000_000e18);
        }
        uint256 cap = HOUSE_CAPITAL / 10;
        uint256 totalCost;
        for (uint256 i; i < 5; ++i) {
            PitAttacker a = gang[i % 4];
            uint256 before = chip.balanceOf(address(a));
            uint256 id = a.commit(roundId, F6, true, 20_000e18, before);
            assertTrue(a.fill(id, _printFor(id, S0)));
            totalCost += before - chip.balanceOf(address(a));
        }
        assertEq(_token(F6).totalSupply(), cap);
        // the cap is the product's, not a buyer's: no member of the gang gets one more token
        for (uint256 i; i < 4; ++i) {
            uint256 before = chip.balanceOf(address(gang[i]));
            uint256 id = gang[i].commit(roundId, F6, true, 1e18, before);
            _warp(router.getCommit(id).fillTs);
            vm.expectEmit(true, true, false, true, address(router));
            emit Refunded(id, address(gang[i]), RefundReason.ProductCap);
            // rejected before the oracle is asked, like the per-fill cap: any report refunds it
            assertFalse(gang[i].fill(id, ""));
            assertEq(chip.balanceOf(address(gang[i])), before, "escrow returned");
        }
        assertEq(_token(F6).totalSupply(), cap);
        // the other products are not touched by it: the floor next door, and the half that contains it
        assertGt(_buy(alice, F5, 1_000e18, S0), 0);
        assertGt(_buy(alice, HIGHER, 1_000e18, S0), 0);
        // a sell makes room for exactly what it took off
        gang[0].approve(_token(F6).id, address(router));
        uint256 sellId = gang[0].commit(roundId, F6, false, 3_000e18, 0);
        assertTrue(gang[0].fill(sellId, _printFor(sellId, S0)));
        uint256 again = gang[1].commit(roundId, F6, true, 3_000e18 + 1, chip.balanceOf(address(gang[1])));
        assertFalse(gang[1].fill(again, _printFor(again, S0)));
        again = gang[1].commit(roundId, F6, true, 3_000e18, chip.balanceOf(address(gang[1])));
        assertTrue(gang[1].fill(again, _printFor(again, S0)));
        assertEq(_token(F6).totalSupply(), cap);

        (uint256 worst, uint256 covered) = lens.solvency(roundId);
        assertEq(worst, cap + 1_000e18, "the floor and the HIGHER tokens over it");
        assertGt(covered, HOUSE_CAPITAL);
        assertGt(totalCost, 0);
        _assertSupplies();
        _assertHookSolvent(address(chip));
    }

    // --------------------------------------------------------------------------------------------
    // rounding
    // --------------------------------------------------------------------------------------------

    /// @dev The rounds of these two tests allow the smallest trade the book's bounds permit (1e12 wei of
    ///      a token, one unit of a 6-decimal chip). A commit below the round's minimum trade is refused,
    ///      so true one-unit dust does not reach the engine on an 18-decimal chip; the loops run at the smallest size that does.
    function _allowDust() internal {
        IPitBook.Params memory p = book.defaultParams();
        p.minTrade = 1e12;
        _setParams(p);
    }

    function test_attack_dustBelowTheMinimumTrade_isRefusedAtCommit() public {
        _open();
        // default minimum: one whole token
        vm.expectRevert(IFallpitRouter.BelowMinimumTrade.selector);
        eve.commit(roundId, HIGHER, true, 1e18 - 1, 1e18);
        vm.expectRevert(IFallpitRouter.BelowMinimumTrade.selector);
        eve.commit(roundId, HIGHER, true, 1, 1e18);
        uint256 id = eve.commit(roundId, HIGHER, true, 1e18, 1e18);
        assertTrue(eve.fill(id, _printFor(id, S0)));
        // sells too: a holder cannot peel dust off a position
        eve.approve(_token(HIGHER).id, address(router));
        vm.expectRevert(IFallpitRouter.BelowMinimumTrade.selector);
        eve.commit(roundId, HIGHER, false, 1e18 - 1, 0);
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
        _fundHouse(address(usd), 100_000e6);
        roundId = hook.openRound(NVDA, address(usd), day);
        _warp(NYTime.openTs(day) + 60);
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

    // --------------------------------------------------------------------------------------------
    // fee-on-transfer chip
    // --------------------------------------------------------------------------------------------

    /// @dev A chip that burns 1% of every transfer is not a chip. A chip the guard refuses (the real
    ///      guard refuses every flagged chip) opens no round, and a tax chip the guard does not know about
    ///      is refused by the router at commit. The rest of the test is defence in depth, for a chip that
    ///      starts to tax after a commit was made: the hook books only what it received, and every
    ///      outflow is the nominal amount.
    function test_attack_feeOnTransferChip_refusedAtCommit_lateTaxKeepsHookSolvent() public {
        MockFeeChip tax = new MockFeeChip();
        bytes32 taxHouse = vault.createHouse(NVDA, address(tax));
        tax.mint(address(this), 1_000_000e18);
        tax.approve(address(vault), 1_000_000e18);
        // the mock vault takes a taxed deposit; the real one refuses it (test/vault, test/integration)
        vault.deposit(taxHouse, 1_000_000e18);
        assertEq(vault.roundCapital(taxHouse), 990_000e18);

        // entry point 1: the guard says no
        guard.set(address(tax), false, true);
        vm.expectRevert(IFallpitHook.ChipNotAllowed.selector);
        hook.openRound(NVDA, address(tax), day);

        // a tax chip the guard does not know about: the round opens on what the hook booked
        guard.set(address(tax), true, false);
        roundId = hook.openRound(NVDA, address(tax), day);
        _warp(NYTime.openTs(day) + 60);
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(c.capital, 980_100e18, "L is what the hook booked, after the chip's tax");
        assertEq(tax.balanceOf(address(hook)), 980_100e18);
        _assertHookSolvent(address(tax));

        // entry point 2: the router refuses an escrow that arrives short, and takes nothing
        PitAttacker a = _attacker(address(tax), 50_000e18);
        vm.expectRevert(IFallpitRouter.BadEscrow.selector);
        a.commit(roundId, HIGHER, true, 10_000e18, 10_000e18);
        assertEq(tax.balanceOf(address(a)), 50_000e18);
        assertEq(tax.balanceOf(address(router)), 0);
        assertEq(router.nextCommitId(), 1, "no commit was made");

        // defence in depth: plain at the commit, taxed at the fill. The router sends the grossed-up cost.
        tax.setTax(false);
        (uint256 quoted,,,,,) = lens.quote(roundId, HIGHER, true, 10_000e18, S0, clock + 2);
        uint256 id = a.commit(roundId, HIGHER, true, 10_000e18, 10_000e18);
        assertEq(router.getCommit(id).escrow, 10_000e18);
        tax.setTax(true);
        assertTrue(a.fill(id, _printFor(id, S0)));
        assertEq(_state().held, c.capital + quoted, "the hook books exactly the cost it received");
        assertGe(tax.balanceOf(address(hook)), c.capital + quoted);
        uint256 sent = 50_000e18 - tax.balanceOf(address(a));
        assertGt(sent, quoted * 100 / 99, "the user bears the chip's tax on the way in");
        assertLt(sent, quoted * 104 / 100);
        assertEq(tax.balanceOf(address(router)), 0, "unused escrow went back");
        _assertHookSolvent(address(tax));

        // a limit that covers the cost but not the tax on top refunds
        tax.setTax(false);
        (quoted,,,,,) = lens.quote(roundId, LOWER, true, 1_000e18, S0, clock + 2);
        id = a.commit(roundId, LOWER, true, 1_000e18, quoted * 1005 / 1000);
        tax.setTax(true);
        assertFalse(a.fill(id, _printFor(id, S0)));
        assertEq(_token(LOWER).totalSupply(), 0);

        // sell: the escrow is the product's tokens, so the commit is exact; proceeds arrive net of the tax
        a.approve(_token(HIGHER).id, address(router));
        uint256 before = tax.balanceOf(address(a));
        (uint256 net,,,,,) = lens.quote(roundId, HIGHER, false, 4_000e18, S0, clock + 2);
        id = a.commit(roundId, HIGHER, false, 4_000e18, 0);
        assertTrue(a.fill(id, _printFor(id, S0)));
        assertEq(tax.balanceOf(address(a)) - before, net - net / 100);
        _assertSupplies();
        _assertHookSolvent(address(tax));

        // settle, finalize, redeem: every outflow is the nominal amount, the receiver bears the tax
        _warp(NYTime.closeTs(day) + 5);
        book.recordClose(NVDA, day, oracle.post(NVDA, TRUSTLESS, S0 * 101 / 100, NYTime.closeTs(day)));
        hook.settleRound(taxHouse, day);
        IFallpitHook.RoundState memory st = _state();
        hook.finalizeRound(taxHouse, day);
        uint256 back = st.held - st.payoutOwed - st.protocolFees;
        assertEq(tax.balanceOf(address(vault)), back - back / 100);
        assertEq(vault.roundCapital(taxHouse), back - back / 100);
        before = tax.balanceOf(address(a));
        assertEq(a.redeem(_token(HIGHER).id, 6_000e18), 6_000e18);
        assertEq(tax.balanceOf(address(a)) - before, 5_940e18);
        hook.collectProtocolFees(address(tax));

        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(tax));
        assertEq(claims, 0);
        assertEq(owed, 0);
        assertLe(tax.balanceOf(address(hook)), 4, "only gross-up dust is left in the hook");
        // nothing was created: every chip minted is somewhere or was burned as tax
        assertEq(
            1_050_000e18,
            tax.balanceOf(address(a)) + tax.balanceOf(address(vault)) + tax.balanceOf(feeRecipient)
                + tax.balanceOf(address(hook)) + tax.balanceOf(address(router)) + tax.taxed()
        );
    }

    // --------------------------------------------------------------------------------------------
    // void
    // --------------------------------------------------------------------------------------------

    /// @dev Wild oracle swings let one trader take out more than traders as a group put in. On a void
    ///      the house comes first: it gets back what the round holds, up to its capital, and the holders
    ///      share only what is above that. Here nothing is. The round runs with the loss limit off
    ///      (10000): the default limit stops x's buying long before the round holds less than the holders
    ///      paid.
    ///      The swings are ridden in the after-hours, right after the round opened, with the whole
    ///      variance still ahead. (A minute into the regular session the round has 70% of its variance
    ///      ahead, and the same swings do not take the round below what the holders paid.)
    ///      The round is on the six-product threshold menu (`Menus.thresholds`: HIGHER and LOWER at three
    ///      strikes), with the two protections of the floor model switched off like the loss limit (the
    ///      product cap at its ceiling, no minimum price): the scenario needs a trader who turns over 90%
    ///      of the capital in one narrow product per swing, which is exactly what the product cap
    ///      refuses. The rule under test is the void rule, and it does not depend on the menu. The swings
    ///      are tuned at alpha 0.3, set explicitly: at the default of 0.2 the book is
    ///      shallower, x takes less out per swing and the round never holds less than the holders paid.
    function test_attack_voidRefunds_neverExceedWhatTheRoundHolds() public {
        MockChip small = new MockChip(18);
        bytes32 smallHouse = _fundHouse(address(small), 1_000e18);
        IPitBook.Params memory p = book.defaultParams();
        p.alpha = 0.3e18;
        p.maxFillBps = 10_000;
        p.lossLimitBps = 10_000;
        p.floorCapBps = 10_000;
        p.minPriceWad = 0;
        p.menu = Menus.thresholds();
        _setParams(p);
        roundId = hook.openRound(NVDA, address(small), day);
        house = smallHouse;

        PitAttacker x = _attacker(address(small), 10_000e18);
        PitAttacker y = _attacker(address(small), 10_000e18);
        PitAttacker z = _attacker(address(small), 10_000e18);
        uint256 low = S0 * 95 / 100;
        uint256 high = S0 * 105 / 100;

        // y buys the top HIGHER strike dear while the stock is up; z buys the opposite side dear when it
        // is down. Both paid close to one chip per token.
        _trade(y, 4, true, 300e18, high);
        _trade(z, 5, true, 600e18, low);
        // x rides the same swings on another token: buys LOWER@15 for little while the stock is up and
        // sells it dear when the stock is down, again and again, until solvency stops the selling
        for (uint256 trips; trips < 60; ++trips) {
            uint256 id = _commit(x, 1, true, 900e18);
            if (!x.fill(id, _printFor(id, high))) break;
            id = _commit(x, 1, false, 900e18);
            bool soldAll = x.fill(id, _printFor(id, low));
            for (uint256 chunks; !soldAll && chunks < 9; ++chunks) {
                id = _commit(x, 1, false, 100e18);
                if (!x.fill(id, _printFor(id, low))) break;
            }
            (uint256 worst, uint256 covered) = lens.solvency(roundId);
            assertLe(worst, covered, "payouts stay covered throughout");
            if (!soldAll) break;
        }
        assertGt(small.balanceOf(address(x)), 10_000e18, "x took chips out of the round");

        (uint256[12] memory supply, uint256[12] memory premium) = hook.getSupplies(roundId);
        IFallpitHook.RoundState memory st = _state();
        uint256 costBasis = premium[1] + premium[4] + premium[5];
        assertGt(costBasis, st.held, "scenario: the holders' cost exceeds what the round still holds");
        assertLt(st.held, 1_000e18, "scenario: the round holds less than the house brought");

        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        IFallpitHook.RoundState memory voided = _state();
        assertEq(voided.payoutOwed, 0, "nothing is above the house's capital: no refunds");
        assertEq(small.balanceOf(address(vault)), st.held, "the house takes all the round still holds");
        assertFalse(vault.isLocked(house));

        // the tokens still redeem, for nothing; nobody is paid out of the house's capital
        uint256 fromY = y.redeemDirect(_token(4).id, 300e18);
        uint256 fromZ = z.redeem(_token(5).id, 600e18);
        uint256 fromX = supply[1] == 0 ? 0 : x.redeem(_token(1).id, supply[1]);
        assertEq(fromX + fromY + fromZ, 0);
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(small));
        assertEq(claims, 0);
        assertEq(owed, 0);
    }

    /// @dev The middle case of the same rule: the round holds more than the house's capital but less
    ///      than capital plus the holders' cost. The house is whole and every holder takes the same
    ///      haircut on its token's average cost.
    function test_attack_voidRefunds_houseFirst_thenHoldersProRata() public {
        _open();
        chip.mint(address(eve), 300_000e18);
        // alice and bob hold the downside (the floor just under the previous close, and LOWER); eve buys
        // HIGHER before a rally and sells it dear at the top: she takes more out than she put in.
        uint256 evePaid = _eveBuy(HIGHER, 5_000e18, S0);
        uint256 high = S0 * 104 / 100;
        uint256 alicePaid = _buy(alice, F3, 20_000e18, S0);
        uint256 bobPaid = _buy(bob, LOWER, 20_000e18, S0);
        uint256 eveGot = _eveSell(HIGHER, 5_000e18, high);
        assertGt(eveGot, evePaid, "scenario: eve realised a gain");
        IFallpitHook.RoundState memory st = _state();
        (, uint256[12] memory premium) = hook.getSupplies(roundId);
        assertEq(premium[F3], alicePaid);
        assertEq(premium[LOWER], bobPaid);
        uint256 above = st.held - HOUSE_CAPITAL;
        assertEq(above, alicePaid + bobPaid + evePaid - eveGot);
        assertLt(above, alicePaid + bobPaid, "scenario: less is left than the holders paid");

        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        assertEq(chip.balanceOf(address(vault)) + _state().payoutOwed, st.held);
        assertGe(chip.balanceOf(address(vault)), HOUSE_CAPITAL, "the house is whole");
        assertLe(chip.balanceOf(address(vault)), HOUSE_CAPITAL + 2, "and keeps only rounding dust on top");
        uint256 lowA = _token(F3).id;
        uint256 lowB = _token(LOWER).id;
        vm.prank(alice);
        uint256 aliceBack = router.redeem(lowA, 20_000e18);
        vm.prank(bob);
        uint256 bobBack = router.redeem(lowB, 20_000e18);
        assertApproxEqAbs(aliceBack, alicePaid * above / (alicePaid + bobPaid), 1);
        assertApproxEqAbs(bobBack, bobPaid * above / (alicePaid + bobPaid), 1);
        assertLt(aliceBack, alicePaid);
        assertLe(aliceBack + bobBack, above);
    }

    function _commit(PitAttacker a, uint8 index, bool isBuy, uint256 shares) internal returns (uint256) {
        address asset = hook.getConfig(roundId).chip;
        if (isBuy) a.approve(asset, address(router)); // a sell needs no approval
        return a.commit(roundId, index, isBuy, shares, isBuy ? MockChip(asset).balanceOf(address(a)) : 0);
    }

    function _trade(PitAttacker a, uint8 index, bool isBuy, uint256 shares, uint256 price) internal {
        uint256 id = _commit(a, index, isBuy, shares);
        require(a.fill(id, _printFor(id, price)), "trade refunded");
    }

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
    ///      On HIGHER (a narrow product is a floor, which would stop at its cap long before 400,000
    ///      tokens).
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
    }

    /// @dev The same in aggregate, for any mix of buys and sells at one oracle price: what a void refunds
    ///      is never more than the traders' net cash in, so the house's capital comes back whole.
    function testFuzz_attack_voidRefunds_neverPayOutHouseCapital(uint256 seed) public {
        _open();
        uint256 paid;
        uint256 got;
        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint8 index = uint8(seed % PRODUCTS);
            uint256 held = _token(index).balanceOf(address(eve));
            // (sizes from the round's minimum trade of one token up)
            if (held >= 1e18 && (seed >> 8) % 2 == 0) {
                got += _eveSell(index, bound(seed >> 16, 1e18, held > 20_000e18 ? 20_000e18 : held), S0);
            } else {
                // a buy that would take a floor over its cap is refunded and costs nothing
                (, uint256 cost) = _eveTryBuy(index, bound(seed >> 16, 1e18, 20_000e18), S0);
                paid += cost;
            }
        }
        uint256 held_ = _state().held;
        assertEq(held_, HOUSE_CAPITAL + paid - got);
        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        assertLe(_state().payoutOwed, paid - got, "refunds never exceed the net cash traders put in");
        assertGe(chip.balanceOf(address(vault)), HOUSE_CAPITAL);
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
        // tickets parked with a third party, and stray tickets sent to the hook or the router, are not
        // anyone's claim and move no accounting
        vm.startPrank(alice);
        token.transfer(address(hook), 100e18);
        token.transfer(address(router), 100e18);
        token.transfer(bob, 800e18);
        vm.stopPrank();
        _assertSupplies();

        // sells still burn exactly the seller's escrow and leave the stray ones alone
        _sell(alice, HIGHER, 500e18, S0);
        assertEq(token.balanceOf(address(hook)), 100e18);
        assertEq(token.balanceOf(address(router)), 100e18);
        assertEq(token.totalSupply(), 2_500e18);
        _assertSupplies();
        _closeAndFinalize(S0 * 101 / 100);
        assertEq(_state().payoutOwed, 2_500e18);
        // the strays the router holds are no user's: redeemFor refuses the router and the hook as holders
        vm.expectRevert(IFallpitRouter.BadHolder.selector);
        router.redeemFor(address(router), token.id);
        vm.expectRevert(IFallpitRouter.BadHolder.selector);
        router.redeemFor(address(hook), token.id);
        _assertHookSolvent(address(chip));
    }

    // --------------------------------------------------------------------------------------------
    // reentrancy through a malicious chip
    // --------------------------------------------------------------------------------------------

    function test_attack_reentrancyThroughMaliciousChip() public {
        ReentrantChip evil = new ReentrantChip();
        bytes32 evilHouse = _fundHouse(address(evil), 1_000_000e18);
        house = evilHouse;
        uint256 attempts;

        // openRound: while the capital moves vault -> hook the chip tries to open again
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
        bytes memory report = _report(t, S0);

        // fill: while the cost moves router -> hook the chip tries to fill the other commit ...
        evil.arm(address(router), abi.encodeCall(router.fill, (id2, report)));
        vm.prank(keeper);
        assertTrue(router.fill(id1, report));
        attempts = _assertBlocked(evil, attempts, IFallpitRouter.Reentrancy.selector);
        // ... and to call the hook's fill itself while the router's escrow moves to the hook, posing as the
        // router (only the router may fill)
        evil.arm(
            address(hook),
            abi.encodeCall(hook.fill, (roundId, HIGHER, true, 5_000e18, 100_000e18, address(evil), t, report))
        );
        vm.prank(keeper);
        assertTrue(router.fill(id2, report));
        attempts = _assertBlocked(evil, attempts, IFallpitHook.OnlyRouter.selector);
        assertEq(_token(HIGHER).totalSupply(), 10_000e18, "exactly the two fills minted");

        // sell: while the proceeds move hook -> user the chip tries to refund a pending commit
        // (the sell is committed first: commits of one second fill in commit order, and it fills first)
        vm.prank(alice);
        uint256 id4 = router.commit{value: FILL_FEE}(roundId, HIGHER, false, 2_000e18, 0);
        uint256 id3 = _commitBuy(bob, LOWER, 1_000e18, 10_000e18);
        evil.arm(address(router), abi.encodeCall(router.refund, (id3)));
        attempts = evil.attempts(); // the commit of a sell moves no chips
        assertTrue(_fill(id4, S0));
        attempts = _assertBlocked(evil, attempts, IFallpitRouter.Reentrancy.selector);
        evil.disarm();
        assertTrue(_fill(id3, S0));
        _assertSupplies();
        _assertHookSolvent(address(evil));

        // finalize: while the house's share moves hook -> vault the chip tries to finalize again
        _warp(NYTime.closeTs(day) + 5);
        book.recordClose(NVDA, day, oracle.post(NVDA, TRUSTLESS, S0 * 101 / 100, NYTime.closeTs(day)));
        hook.settleRound(house, day);
        evil.arm(address(hook), abi.encodeCall(hook.finalizeRound, (house, day)));
        hook.finalizeRound(house, day);
        attempts = _assertBlocked(evil, attempts, IFallpitHook.Reentrancy.selector);

        // redeem: while the payout moves hook -> holder the chip, itself a holder of winning tickets,
        // tries to redeem inside the redeem
        Ticket memory token = _token(HIGHER);
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
        evil.disarm();

        assertEq(evil.successes(), 0, "no reentrant call ever got through");
        // the books still close: bob redeems, and what the hook owes is exactly the chip's own tokens
        vm.prank(bob);
        assertEq(router.redeem(token.id, 5_000e18), 5_000e18);
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(evil));
        assertEq(claims, owed);
        assertEq(owed, 1_000e18, "only the tickets parked on the chip contract are still owed");
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

    function _assertPristine() internal view {
        IFallpitHook.RoundState memory st = _state();
        assertEq(st.held, hook.getConfig(roundId).capital);
        assertEq(st.g, 1e18);
        assertEq(st.protocolFees, 0);
        (int256[40] memory v,) = hook.getCurve(roundId);
        for (uint256 j; j < 40; ++j) {
            assertEq(v[j], 0);
        }
        (uint256[12] memory supply, uint256[12] memory premium) = hook.getSupplies(roundId);
        for (uint256 i; i < MAX_PRODUCTS; ++i) {
            assertEq(supply[i], 0);
            assertEq(premium[i], 0);
            if (i < PRODUCTS) assertEq(_token(uint8(i)).totalSupply(), 0);
        }
    }
}

/// @notice The pricing engine is replaced by one that gives tokens away. The hook's own checks must still
///         hold the line: it never owes more than it holds, and one round can never spend another's chips.
/// @dev The first three tests isolate the solvency check and the loss limit: they trade the pair (HIGHER,
///      which has no product cap) in rounds without a minimum price, so that a free token is still free.
///      The last test is the same engine against a floor with the default protections, where the product
///      cap and the minimum price do their part.
contract FallpitBrokenMathTest is HookFixture {
    GiveawayMath internal giveaway;
    bytes32 internal constant TSLA = bytes32("TSLA");

    function _mathAddress() internal override returns (address) {
        if (address(giveaway) == address(0)) giveaway = new GiveawayMath();
        return address(giveaway);
    }

    /// @dev With the loss limit off (10000) only the solvency check stands between a broken engine and
    ///      the round's capital: all of it goes, and not one chip more.
    function test_attack_brokenMath_limitOff_cannotOverdrawTheRoundOrTouchAnother() public {
        (uint256 filled, uint256 taken) = _giveaway(10_000);
        assertEq(filled, 50, "the 51st free fill would owe more than the round holds");
        assertGt(taken, HOUSE_CAPITAL * 9 / 10, "the broken engine did give the round away");
    }

    /// @dev With a loss limit of 50% the same broken engine is stopped
    ///      at half the capital: the 26th free fill would leave the house less than half of what it
    ///      brought, and after eve sold the free tokens back for one chip each no further buy fits under
    ///      the limit.
    function test_attack_brokenMath_lossLimitHalvesTheDamage() public {
        (uint256 filled, uint256 taken) = _giveaway(5000);
        assertEq(filled, 25, "the 26th free fill would put more than half the capital at risk");
        // 500,000 free tokens sold back at one chip each, less the 2% fee the round keeps
        assertLe(taken, HOUSE_CAPITAL / 2, "never more than the limit");
        assertGt(taken, HOUSE_CAPITAL * 48 / 100, "the broken engine gave away what the limit allows");
        (uint256 cushion, uint256 floor) = lens.lossLimit(roundId);
        assertEq(floor, HOUSE_CAPITAL / 2);
        assertGe(cushion, floor);
    }

    /// @dev At the default loss limit of 30% the damage is bounded at 30%: the
    ///      16th free fill would leave the house less than 70% of what it brought.
    function test_attack_brokenMath_lossLimitAtTheDefault_boundsTheDamageAtThirtyPercent() public {
        assertEq(book.defaultParams().lossLimitBps, 3000);
        (uint256 filled, uint256 taken) = _giveaway(3000);
        assertEq(filled, 15, "the 16th free fill would put more than 30% of the capital at risk");
        // 300,000 free tokens sold back at one chip each, less the 2% fee the round keeps
        assertLe(taken, HOUSE_CAPITAL * 3 / 10, "never more than the limit");
        assertGt(taken, HOUSE_CAPITAL * 29 / 100, "the broken engine gave away what the limit allows");
        (uint256 cushion, uint256 floor) = lens.lossLimit(roundId);
        assertEq(floor, HOUSE_CAPITAL * 7 / 10);
        assertGe(cushion, floor);
    }

    /// @dev What the loss limit does not stop (stated, not prevented): it binds buys, and sells are exempt.
    ///      A give-away engine hands out free tokens on two sides that can never both win (HIGHER and
    ///      LOWER), each up to the
    ///      limit, and buys them all back at one chip. The round stays solvent throughout and loses
    ///      nearly twice the limit: 15 free fills a side at the default limit of 30%.
    function test_attack_brokenMath_knownLimit_twoSidesPassTheLossLimit() public {
        IPitBook.Params memory p = book.defaultParams();
        p.minPriceWad = 0;
        _setParams(p);
        _open();
        assertEq(hook.getConfig(roundId).params.lossLimitBps, 3000);
        PitAttacker eve = new PitAttacker{value: 10 ether}(router, hook);
        chip.mint(address(eve), 1e18);
        eve.approve(address(chip), address(router));
        uint8[2] memory sides = [HIGHER, LOWER];
        for (uint256 n; n < 2; ++n) {
            uint256 filled;
            for (uint256 i; i < 30; ++i) {
                uint256 id = eve.commit(roundId, sides[n], true, 20_000e18, 1e6);
                uint64 t = router.getCommit(id).fillTs;
                if (clock < t) _warp(t);
                if (!eve.fill(id, _report(t, S0))) break;
                ++filled;
            }
            assertEq(filled, 15, "each side on its own stops at the limit: 300,000 tokens, 30%");
        }
        (uint256 cushion, uint256 floor) = lens.lossLimit(roundId);
        assertGe(cushion, floor, "no buy took the cushion under the floor");

        for (uint256 n; n < 2; ++n) {
            eve.approve(_token(sides[n]).id, address(router));
            for (uint256 i; i < 15; ++i) {
                uint256 id = eve.commit(roundId, sides[n], false, 20_000e18, 0);
                uint64 t = router.getCommit(id).fillTs;
                if (clock < t) _warp(t);
                assertTrue(eve.fill(id, _report(t, S0)), "sells only have to keep the round solvent");
                (uint256 worst, uint256 covered) = lens.solvency(roundId);
                assertLe(worst, covered);
            }
        }
        (cushion,) = lens.lossLimit(roundId);
        uint256 taken = chip.balanceOf(address(eve)) - 1e18;
        assertLt(cushion, floor, "the sells took the cushion under the floor");
        // 600,000 tokens sold back at one chip each, less the 2% fee the round keeps
        assertGt(taken, HOUSE_CAPITAL * 58 / 100, "nearly twice the limit is gone");
        assertLt(taken, HOUSE_CAPITAL * 60 / 100);
        assertEq(_state().held + taken, HOUSE_CAPITAL);
        _assertHookSolvent(address(chip));
    }

    /// @dev The same engine against a floor of a round with the default protections (no product
    ///      cap, loss limit 30%, minimum price 0.02). The loss limit lets fifteen
    ///      free fills through, 30% of the capital, and each token costs the minimum price of two
    ///      hundredths of a chip plus fees instead of nothing. Cycling free buys and full-price sells
    ///      still drains the round through the floor (sells are exempt from the loss limit, as on the
    ///      pair), but every cycle is 30% of the capital at most and pays the minimum price on the way
    ///      in: the two protections slow a broken engine down, they do not replace a sound one.
    function test_attack_brokenMath_onAFloor_lossLimitAndMinPriceBound_eachCycle() public {
        (uint256 filled, uint256 paid, uint256 taken) = _freeFillsOnAFloor(10_000);
        assertEq(filled, 15, "the sixteenth free fill would put more than 30% of the capital at risk");
        // 300,000 tokens at the minimum price of 0.02, plus the 2% fee on that (the mock's vega is zero)
        assertEq(paid, 6_000e18 + 120e18, "a free token costs the minimum price and its fee");
        assertLt(taken, HOUSE_CAPITAL * 3 / 10, "one cycle takes less than the loss limit");
        assertGt(taken, HOUSE_CAPITAL * 28 / 100);
    }

    /// @dev With a product cap of a tenth of the capital per floor the cap comes
    ///      first: five free fills, a tenth of the capital, and the cycle takes less than the cap.
    function test_attack_brokenMath_onAFloor_capAndMinPriceBound_eachCycle() public {
        (uint256 filled, uint256 paid, uint256 taken) = _freeFillsOnAFloor(1000);
        assertEq(filled, 5, "the sixth free fill would take the floor over a tenth of the capital");
        assertEq(paid, 2_000e18 + 40e18, "a free token costs the minimum price and its fee");
        assertLt(taken, HOUSE_CAPITAL / 10, "one cycle takes less than the product cap");
    }

    /// @dev Eve takes free fills of the per-fill cap on the floor from +1 to +2 sigma until one is
    ///      refused, then sells every token back at one chip. Returns the fills that went through, what
    ///      she paid for them and what she took out of the round.
    function _freeFillsOnAFloor(uint16 floorCapBps)
        internal
        returns (uint256 filled, uint256 paid, uint256 taken)
    {
        IPitBook.Params memory p = book.defaultParams();
        p.floorCapBps = floorCapBps;
        _setParams(p);
        _open();
        assertEq(hook.getConfig(roundId).params.minPriceWad, 0.02e18);
        assertEq(hook.getConfig(roundId).params.lossLimitBps, 3000);
        PitAttacker eve = new PitAttacker{value: 10 ether}(router, hook);
        chip.mint(address(eve), 100_000e18);
        eve.approve(address(chip), address(router));
        for (uint256 i; i < 20; ++i) {
            uint256 before = chip.balanceOf(address(eve));
            uint256 id = eve.commit(roundId, F6, true, 20_000e18, before);
            uint64 t = router.getCommit(id).fillTs;
            if (clock < t) _warp(t);
            if (!eve.fill(id, _report(t, S0))) break;
            ++filled;
            paid += before - chip.balanceOf(address(eve));
        }
        uint256 atRisk = filled * 20_000e18;
        (uint256 worst, uint256 covered) = lens.solvency(roundId);
        assertEq(worst, atRisk);
        assertLe(worst, covered);
        (uint256 cushion, uint256 floor) = lens.lossLimit(roundId);
        assertGt(cushion, HOUSE_CAPITAL - atRisk, "one cycle puts the fills at risk, less the premium");
        assertGe(cushion, floor);

        // sold back at one chip each: the round lost the tokens less what eve paid, and no more
        eve.approve(_token(F6).id, address(router));
        for (uint256 i; i < filled; ++i) {
            uint256 id = eve.commit(roundId, F6, false, 20_000e18, 0);
            uint64 t = router.getCommit(id).fillTs;
            if (clock < t) _warp(t);
            assertTrue(eve.fill(id, _report(t, S0)));
        }
        taken = chip.balanceOf(address(eve)) - 100_000e18;
        assertEq(_state().held + taken, HOUSE_CAPITAL);
        _assertHookSolvent(address(chip));
    }

    /// @dev Eve takes what a give-away engine lets her take from the NVDA round, with a TSLA round open in
    ///      the same chip. Returns the free fills that went through and the chips she took out.
    function _giveaway(uint16 lossLimitBps) internal returns (uint256 filled, uint256 taken) {
        IPitBook.Params memory p = book.defaultParams();
        p.lossLimitBps = lossLimitBps;
        p.minPriceWad = 0;
        _setParams(p);
        // a second house in the same chip, for another ticker
        oracle.setSupported(TSLA, true);
        // registered a day ago: a new ticker is in force 24 hours after its registration
        vm.warp(clock - 24 hours);
        vm.prank(owner);
        book.registerTicker(
            TSLA,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.KeeperOnly
        );
        vm.warp(clock);
        book.recordClose(TSLA, day0, oracle.post(TSLA, TRUSTLESS, 400e18, NYTime.closeTs(day0)));
        bytes32 tslaHouse = vault.createHouse(TSLA, address(chip));
        chip.mint(address(this), 500_000e18);
        chip.approve(address(vault), 500_000e18);
        vault.deposit(tslaHouse, 500_000e18);
        bytes32 tslaRound = hook.openRound(TSLA, address(chip), day);
        _open();

        PitAttacker eve = new PitAttacker{value: 10 ether}(router, hook);
        chip.mint(address(eve), 1e18);
        eve.approve(address(chip), address(router));
        uint256 dust = 1e6;

        // free tokens at the cap, until a fill is refused
        for (uint256 i; i < 60; ++i) {
            uint256 id = eve.commit(roundId, HIGHER, true, 20_000e18, dust);
            uint64 t = router.getCommit(id).fillTs;
            if (clock < t) _warp(t);
            if (!eve.fill(id, _report(t, S0))) break;
            ++filled;
            (uint256 worst, uint256 covered) = lens.solvency(roundId);
            assertLe(worst, covered);
        }
        assertLt(1e18 - chip.balanceOf(address(eve)), dust, "eve paid dust");

        // Selling them back at one chip each drains this round: with a broken engine the house capital
        // the round may put at risk is lost. Eve keeps cycling free buys and full-price sells until
        // nothing fills.
        eve.approve(_token(HIGHER).id, address(router));
        for (uint256 i; i < 120; ++i) {
            uint256 balance = _token(HIGHER).balanceOf(address(eve));
            bool isBuy = balance == 0;
            uint256 shares = isBuy ? 20_000e18 : (balance > 20_000e18 ? 20_000e18 : balance);
            uint256 id = eve.commit(roundId, HIGHER, isBuy, shares, isBuy ? dust : 0);
            uint64 t = router.getCommit(id).fillTs;
            if (clock < t) _warp(t);
            if (!eve.fill(id, _report(t, S0))) break;
            (uint256 worst, uint256 covered) = lens.solvency(roundId);
            assertLe(worst, covered, "what is outstanding stays covered");
        }
        IFallpitHook.RoundState memory st = _state();
        taken = chip.balanceOf(address(eve)) + chip.balanceOf(address(router)) - 1e18;
        // never more than this one round held, and the round still covers what is outstanding
        assertLe(taken, HOUSE_CAPITAL);
        assertGe(st.held, _token(HIGHER).totalSupply() + st.protocolFees);
        assertEq(st.held + taken, HOUSE_CAPITAL, "every chip eve took came out of this round's own balance");

        // the other house's round, in the same chip on the same hook, is untouched and fully backed
        assertEq(hook.getState(tslaRound).held, 500_000e18);
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, owed);
        assertEq(owed, st.held + 500_000e18);
        assertEq(chip.balanceOf(address(hook)), claims);
    }
}
