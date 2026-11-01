// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {RefundReason} from "../../src/interfaces/IFallpitHook.sol";

/// @notice `fillBatch` on the real system: the commits run in the order given, each as `fill` would run
///         it (the same events, fee and refund), and a commit that cannot be filled now is skipped with
///         false instead of reverting the batch. An extra fill of the same round in a batch costs less
///         than a fill on its own.
contract FillBatchTest is IntegrationFixture {
    uint256 internal constant STAKE = 100_000e18;

    event FillFeePaid(uint256 indexed commitId, address indexed to, uint256 amount, bool sent);

    address internal filler = makeAddr("batchFiller");

    function setUp() public override {
        super.setUp();
        _fund(alice, STAKE);
        _fund(bob, STAKE);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        _open();
    }

    function _batch(uint256[] memory ids, bytes memory report) internal returns (bool[] memory ok) {
        bytes[] memory reports = new bytes[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            reports[i] = report;
        }
        vm.prank(filler);
        ok = router.fillBatch(ids, reports);
    }

    function _status(uint256 id) internal view returns (uint8) {
        return uint8(router.getCommit(id).status);
    }

    function test_fillBatch_fillsInOrder_withTheEventsAndFeesOfFill() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        ids[1] = _commitBuy(bob, LOWER, 1_000e18, 10_000e18);
        ids[2] = _commitBuy(alice, F4, 1_000e18, 10_000e18);
        bytes memory report = _printFor(ids[0], S0);
        assertEq(router.getCommit(ids[2]).fillTs, router.getCommit(ids[0]).fillTs, "one fill instant");

        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(true, true, false, false, address(router));
            emit IFallpitRouter.Filled(ids[i], i == 1 ? bob : alice, 0);
            vm.expectEmit(true, true, false, true, address(router));
            emit FillFeePaid(ids[i], filler, FILL_FEE, true);
        }
        bool[] memory ok = _batch(ids, report);
        for (uint256 i; i < 3; ++i) {
            assertTrue(ok[i]);
            assertEq(_status(ids[i]), uint8(IFallpitRouter.CommitStatus.Filled));
        }
        assertEq(filler.balance, 3 * FILL_FEE, "the filler earns every fee");
        assertEq(address(router).balance, 0);
        assertEq(chip.balanceOf(address(router)), 0, "no escrow left behind");
        assertEq(_token(HIGHER).balanceOf(alice), 1_000e18);
        assertEq(_token(LOWER).balanceOf(bob), 1_000e18);
        assertEq(_token(F4).balanceOf(alice), 1_000e18);
    }

    /// @dev The same result as the fills one by one: the same tickets and the same chips paid.
    function test_fillBatch_sameResultAsFillsOneByOne() public {
        uint256 snap = vm.snapshotState();
        uint256 a = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        uint256 b = _commitBuy(bob, HIGHER, 2_000e18, 10_000e18);
        bytes memory report = _printFor(a, S0);
        vm.startPrank(filler);
        router.fill(a, report);
        router.fill(b, report);
        vm.stopPrank();
        uint256 aliceOne = chip.balanceOf(alice);
        uint256 bobOne = chip.balanceOf(bob);
        vm.revertToState(snap);

        uint256[] memory ids = new uint256[](2);
        ids[0] = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        ids[1] = _commitBuy(bob, HIGHER, 2_000e18, 10_000e18);
        _batch(ids, _printFor(ids[0], S0));
        assertEq(chip.balanceOf(alice), aliceOne);
        assertEq(chip.balanceOf(bob), bobOne);
    }

    function test_fillBatch_skipsWhatCannotBeFilled_andNeverReverts() public {
        uint256 done = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        _fill(done, S0);
        uint256 a = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        uint256 b = _commitBuy(bob, LOWER, 1_000e18, 10_000e18);
        uint64 t = router.getCommit(a).fillTs;
        bytes memory report = _print(t, S0);
        uint256 escrow = chip.balanceOf(address(router));

        // before the fill instant: every commit is skipped and stays as it was
        uint256[] memory ids = new uint256[](4);
        ids[0] = done; // filled already
        ids[1] = a; // not due yet
        ids[2] = b; // not due yet
        ids[3] = 999; // no such commit
        bool[] memory ok = _batch(ids, report);
        for (uint256 i; i < 4; ++i) {
            assertFalse(ok[i]);
        }
        assertEq(_status(a), uint8(IFallpitRouter.CommitStatus.Pending));
        assertEq(chip.balanceOf(address(router)), escrow);

        // b before a: b is held by the earlier commit still pending, a fills, the rest is skipped
        _warp(t);
        ids = new uint256[](3);
        ids[0] = b;
        ids[1] = a;
        ids[2] = done;
        ok = _batch(ids, report);
        assertFalse(ok[0], "held by the earlier pending commit");
        assertTrue(ok[1]);
        assertFalse(ok[2]);
        assertEq(_status(b), uint8(IFallpitRouter.CommitStatus.Pending));
        assertEq(filler.balance, FILL_FEE, "a skipped commit pays nothing");

        // past the window: skipped, and only `refund` ends it
        _warp(t + hook.getConfig(roundId).params.refundDelay + 1);
        ids = new uint256[](1);
        ids[0] = b;
        assertFalse(_batch(ids, report)[0]);
        router.refund(b);
        assertEq(chip.balanceOf(bob), STAKE);
    }

    /// @dev A report that is not the print for the commit's instant is a fill error, not a final rejection:
    ///      the batch skips the commit and its escrow stays held; a later fill with the right print works.
    function test_fillBatch_aFillErrorSkipsAndKeepsTheEscrow() public {
        uint256 a = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        uint64 t = router.getCommit(a).fillTs;
        _warp(t);
        uint256 escrow = chip.balanceOf(address(router));
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;
        assertFalse(_batch(ids, _print(t - 1, S0))[0]);
        assertEq(_status(a), uint8(IFallpitRouter.CommitStatus.Pending));
        assertEq(chip.balanceOf(address(router)), escrow, "the escrow is still held");
        assertEq(filler.balance, 0);
        // the router still counts the escrow: a fill and then a refund of everything else balance
        assertTrue(_batch(ids, _print(t, S0))[0]);
        assertEq(chip.balanceOf(address(router)), 0);
    }

    /// @dev A final rejection inside a batch is a refund, exactly as in `fill`: the escrow back, the fee to
    ///      the filler, and the batch goes on.
    function test_fillBatch_aRefundInsideTheBatch() public {
        uint256 cap = hook.getConfig(roundId).maxFill;
        uint256[] memory ids = new uint256[](2);
        ids[0] = _commitBuy(alice, HIGHER, cap + 1, STAKE);
        ids[1] = _commitBuy(bob, LOWER, 1_000e18, 10_000e18);
        bytes memory report = _printFor(ids[0], S0);
        vm.expectEmit(true, true, false, true, address(router));
        emit IFallpitRouter.Refunded(ids[0], alice, RefundReason.Cap);
        vm.expectEmit(true, true, false, true, address(router));
        emit FillFeePaid(ids[0], filler, FILL_FEE, true);
        bool[] memory ok = _batch(ids, report);
        assertFalse(ok[0]);
        assertTrue(ok[1]);
        assertEq(_status(ids[0]), uint8(IFallpitRouter.CommitStatus.Refunded));
        assertEq(chip.balanceOf(alice), STAKE, "the chips came back whole");
        assertEq(filler.balance, 2 * FILL_FEE);
    }

    function test_fillBatch_lengthMismatch_reverts() public {
        uint256[] memory ids = new uint256[](2);
        bytes[] memory reports = new bytes[](1);
        vm.expectRevert(IFallpitRouter.LengthMismatch.selector);
        router.fillBatch(ids, reports);
    }
}
