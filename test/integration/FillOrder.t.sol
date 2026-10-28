// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";

import {StackFixture} from "./StackFixture.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";

/// @notice The commits of a round fill in commit order: each commit records the round's commit before it when
///         their fill windows overlap, and `fill` reverts while that one is pending and its window is open.
///         One print can price many instants, so the order holds across instants too. A backrun's buy fills
///         after the victim's, which makes it a round trip after the victim's price impact, and a round trip
///         at one print loses. A commit that cannot fill is refunded and lets the next one through; one
///         nobody fills holds the next ones only until its own window ends.
contract FillOrderTest is StackFixture {
    address internal lp = makeAddr("lp");
    address internal eve = makeAddr("eve");
    address internal victim = makeAddr("victim");
    uint256 internal constant CAPITAL = 1_000_000e18;
    uint256 internal constant LOT = 20_000e18;

    function _commitBuy(address user, uint8 product, uint256 shares, uint256 limit)
        internal
        returns (uint256)
    {
        vm.prank(user);
        return router.commit{value: FILL_FEE}(roundId, product, true, shares, limit);
    }

    function _commitSell(address user, uint8 product, uint256 shares) internal returns (uint256 id) {
        Ticket memory token = _token(product);
        vm.startPrank(user);
        token.approve(address(router), shares);
        id = router.commit{value: FILL_FEE}(roundId, product, false, shares, 0);
        vm.stopPrank();
    }

    /// @dev A backrun as an FCFS sequencer sees it: the victim's commit lands first, Eve's buy
    ///      and sell after it in the same second. Eve then tries her order and the fill order holds.
    function _backrun(uint8 product, uint256 price) internal returns (int256 eveNet, uint256 victimExtra) {
        _buy(eve, product, LOT, price); // eve's inventory from before
        _warp(clock + 10);
        uint256 snap = vm.snapshotState();
        uint256 alone;
        {
            uint256 b = chip.balanceOf(victim);
            _fillAt(_commitBuy(victim, product, LOT, b), price);
            alone = b - chip.balanceOf(victim);
        }
        vm.revertToState(snap);

        uint256 eveBefore = chip.balanceOf(eve);
        uint256 vBefore = chip.balanceOf(victim);
        uint256 v = _commitBuy(victim, product, LOT, vBefore);
        uint256 a = _commitBuy(eve, product, LOT, eveBefore);
        uint256 s = _commitSell(eve, product, LOT);
        assertEq(router.getCommit(a).prev, v, "eve's buy comes after the victim's");
        assertEq(router.getCommit(s).prev, a);
        uint256 vp = router.getCommit(v).prev;
        assertTrue(
            vp == 0 || router.getCommit(vp).status != IFallpitRouter.CommitStatus.Pending,
            "nothing pending before the victim's"
        );

        // Eve's order is refused: her buy cannot go before the victim's, her sell not before her buy.
        uint64 t = router.getCommit(v).fillTs;
        _warp(t);
        oracle.set(NVDA, KEEPER, t, price);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(IFallpitRouter.EarlierCommitPending.selector, v));
        router.fill(a, abi.encode(KEEPER));
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(IFallpitRouter.EarlierCommitPending.selector, a));
        router.fill(s, abi.encode(KEEPER));

        // The commit order: the victim, then eve's round trip.
        assertTrue(_fillAt(v, price));
        assertTrue(_fillAt(a, price));
        assertTrue(_fillAt(s, price));
        eveNet = int256(chip.balanceOf(eve)) - int256(eveBefore);
        victimExtra = (vBefore - chip.balanceOf(victim)) - alone;
    }

    function test_fillOrder_backrunSandwichLoses() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, 1_000_000e18);
        _fund(victim, 1_000_000e18);
        _open(3600);
        (int256 netPair, uint256 extraPair) = _backrun(HIGHER, S0);
        (int256 netFloor, uint256 extraFloor) = _backrun(F5, S0);
        console.log("HIGHER: victim pays %s more than alone; eve nets", extraPair / 1e18);
        console.logInt(netPair / 1e18);
        console.log("floor +0.5..+1 sd: victim pays %s more than alone; eve nets", extraFloor / 1e18);
        console.logInt(netFloor / 1e18);
        assertEq(extraPair, 0, "the victim pays exactly what it would alone");
        assertEq(extraFloor, 0);
        assertLt(netPair, 0, "a round trip after the victim, at one print, loses its fees");
        assertLt(netFloor, 0);
    }

    /// @dev A buy committed before the victim's in the same second still sandwiches it. On an FCFS
    ///      sequencer with a private mempool nobody sees the victim's commit before it lands, so this
    ///      needs a guess, not a backrun.
    function test_aBuyCommittedBeforeTheVictimInTheSameSecondStillProfits() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, 1_000_000e18);
        _fund(victim, 1_000_000e18);
        _open(3600);
        _buy(eve, HIGHER, LOT, S0);
        _warp(clock + 10);
        uint256 eveBefore = chip.balanceOf(eve);
        uint256 a = _commitBuy(eve, HIGHER, LOT, eveBefore);
        uint256 v = _commitBuy(victim, HIGHER, LOT, chip.balanceOf(victim));
        uint256 s = _commitSell(eve, HIGHER, LOT);
        assertTrue(_fillAt(a, S0));
        assertTrue(_fillAt(v, S0));
        assertTrue(_fillAt(s, S0));
        assertGt(int256(chip.balanceOf(eve)) - int256(eveBefore), 0);
    }

    /// @dev An earlier commit that can never fill is refunded by `fill` (here its own limit), and the next
    ///      one fills at once.
    function test_fillOrder_aRefundedEarlierCommitLetsTheNextFill() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, 1_000_000e18);
        _fund(victim, 1_000_000e18);
        _open(3600);
        uint256 first = _commitBuy(eve, HIGHER, LOT, 1e18); // a limit of one chip: refunded
        uint256 second = _commitBuy(victim, HIGHER, LOT, chip.balanceOf(victim));
        assertEq(router.getCommit(second).prev, first);
        uint64 t = router.getCommit(first).fillTs;
        _warp(t);
        oracle.set(NVDA, KEEPER, t, S0);
        vm.prank(keeper);
        assertFalse(router.fill(first, abi.encode(KEEPER)), "refunded: over its limit");
        assertEq(uint8(router.getCommit(first).status), uint8(IFallpitRouter.CommitStatus.Refunded));
        assertTrue(_fillAt(second, S0));
    }

    /// @dev An earlier commit nobody fills holds the later ones only until the window they share ends;
    ///      then all are refundable, in any order, by anyone.
    function test_fillOrder_aStuckEarlierCommitBlocksOnlyUntilTheWindowEnds() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, 1_000_000e18);
        _fund(victim, 1_000_000e18);
        _open(3600);
        uint256 first = _commitBuy(eve, HIGHER, LOT, chip.balanceOf(eve));
        uint256 second = _commitBuy(victim, HIGHER, LOT, chip.balanceOf(victim));
        IFallpitRouter.Commit memory c = router.getCommit(second);
        _warp(c.fillTs);
        oracle.set(NVDA, KEEPER, c.fillTs, S0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IFallpitRouter.EarlierCommitPending.selector, first));
        router.fill(second, abi.encode(KEEPER));
        // nobody fills the first; the window ends for both at once
        _warp(c.fillTs + c.refundDelay + 1);
        uint256 vBefore = chip.balanceOf(victim);
        router.refund(second);
        router.refund(first);
        assertEq(chip.balanceOf(victim) - vBefore, c.escrow, "the victim's escrow is back");
        assertEq(uint8(router.getCommit(first).status), uint8(IFallpitRouter.CommitStatus.Refunded));
    }

    /// @dev A commit one second later waits for the earlier one too: the order is per round, not per instant.
    function test_fillOrder_acrossInstants_inCommitOrder() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, 1_000_000e18);
        _fund(victim, 1_000_000e18);
        _open(3600);
        uint256 first = _commitBuy(eve, HIGHER, LOT, chip.balanceOf(eve));
        _warp(clock + 1);
        uint256 later = _commitBuy(victim, HIGHER, LOT, chip.balanceOf(victim));
        assertEq(router.getCommit(later).prev, first, "another second: still the round's previous commit");
        uint64 t = router.getCommit(later).fillTs;
        _warp(t);
        oracle.set(NVDA, KEEPER, t, S0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IFallpitRouter.EarlierCommitPending.selector, first));
        router.fill(later, abi.encode(KEEPER));
        assertTrue(_fillAt(first, S0));
        assertTrue(_fillAt(later, S0));
    }

    /// @dev The victim commits at T; Eve backruns one second later with a buy and a sell.
    ///      No print falls between the two instants, so one print prices both. Eve's buy cannot be filled
    ///      before the victim's: the backrun is a round trip after the victim's impact, and it loses.
    function test_fillOrder_sandwichAcrossTwoInstantsUnderOnePrint_reverts() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, 1_000_000e18);
        _fund(victim, 1_000_000e18);
        _open(3600);
        _buy(eve, HIGHER, LOT, S0); // eve's inventory from before
        _warp(clock + 40); // that commit's window is over: it holds nobody

        uint256 eveBefore = chip.balanceOf(eve);
        uint256 v = _commitBuy(victim, HIGHER, LOT, chip.balanceOf(victim));
        _warp(clock + 1);
        uint256 a = _commitBuy(eve, HIGHER, LOT, eveBefore);
        uint256 s = _commitSell(eve, HIGHER, LOT);
        assertEq(router.getCommit(v).prev, 0, "the victim's has no pending predecessor");
        assertEq(router.getCommit(a).prev, v, "eve's buy, one second later, comes after the victim's");
        assertEq(router.getCommit(s).prev, a);

        // one print covers both instants: the same price at each
        uint64 tv = router.getCommit(v).fillTs;
        uint64 ta = router.getCommit(a).fillTs;
        assertEq(ta, tv + 1);
        oracle.set(NVDA, KEEPER, tv, S0);
        oracle.set(NVDA, KEEPER, ta, S0);
        _warp(ta);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(IFallpitRouter.EarlierCommitPending.selector, v));
        router.fill(a, abi.encode(KEEPER));
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(IFallpitRouter.EarlierCommitPending.selector, a));
        router.fill(s, abi.encode(KEEPER));

        assertTrue(_fillAt(v, S0));
        assertTrue(_fillAt(a, S0));
        assertTrue(_fillAt(s, S0));
        assertLt(int256(chip.balanceOf(eve)) - int256(eveBefore), 0, "the round trip after the victim loses");
    }

    /// @dev A stuck earlier commit (no print for its instant, nobody fills it) holds a later one only until
    ///      its own window ends. The later one, at a later instant, then fills inside its own window, with
    ///      the earlier one still pending; the earlier one is refunded afterwards.
    function test_fillOrder_aStuckEarlierCommitDoesNotBlockALaterInstantAfterItsWindow() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, 1_000_000e18);
        _fund(victim, 1_000_000e18);
        _open(3600);
        uint256 first = _commitBuy(eve, HIGHER, LOT, chip.balanceOf(eve));
        _warp(clock + 5);
        uint256 later = _commitBuy(victim, HIGHER, LOT, chip.balanceOf(victim));
        IFallpitRouter.Commit memory f = router.getCommit(first);
        IFallpitRouter.Commit memory c = router.getCommit(later);
        assertEq(c.prev, first);
        oracle.set(NVDA, KEEPER, c.fillTs, S0);

        _warp(c.fillTs);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IFallpitRouter.EarlierCommitPending.selector, first));
        router.fill(later, abi.encode(KEEPER));

        // the first one's window ends; the later one's is still open
        _warp(f.fillTs + f.refundDelay + 1);
        assertLe(clock, c.fillTs + c.refundDelay);
        assertEq(uint8(router.getCommit(first).status), uint8(IFallpitRouter.CommitStatus.Pending));
        vm.prank(keeper);
        assertTrue(router.fill(later, abi.encode(KEEPER)), "the later commit fills in its own window");
        router.refund(first);
        assertEq(uint8(router.getCommit(first).status), uint8(IFallpitRouter.CommitStatus.Refunded));
    }

    /// @dev A commit whose window cannot overlap the previous one's has no predecessor.
    function test_fillOrder_noPredecessorOnceTheWindowsCannotOverlap() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, 1_000_000e18);
        _fund(victim, 1_000_000e18);
        _open(3600);
        uint256 first = _commitBuy(eve, HIGHER, LOT, chip.balanceOf(eve));
        IFallpitRouter.Commit memory f = router.getCommit(first);
        _warp(clock + f.refundDelay); // fillTs of the next one is then f.fillTs + refundDelay: still overlaps
        uint256 edge = _commitBuy(victim, HIGHER, LOT, 1_000e18);
        assertEq(router.getCommit(edge).prev, first);
        _warp(clock + 1);
        uint256 apart = _commitBuy(victim, HIGHER, LOT, 1_000e18);
        assertEq(router.getCommit(apart).prev, edge, "the newest commit of the round");
        _warp(clock + f.refundDelay + 1);
        uint256 alone = _commitBuy(victim, HIGHER, LOT, 1_000e18);
        assertEq(router.getCommit(alone).prev, 0, "no window it could share");
    }
}
