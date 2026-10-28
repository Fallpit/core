// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {RevertingFiller, GuzzlingFiller, ReentrantFiller} from "../hook/mocks/Fillers.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";

/// @notice The trader-paid fill fee on the real system (SPEC 7.3). Every commit carries the round's
///         `fillFee` in native coin. Whoever calls `fill` for the commit is paid it, when the fill ends in
///         a trade and when it ends in a refund; when nobody fills in time it goes back to the trader. The
///         payment can neither be blocked nor reentered, and the router's native balance is always the
///         fees of the pending commits plus what it owes in `ethOwed`.
contract FillFeeTest is IntegrationFixture {
    uint256 internal constant STAKE = 100_000e18;

    event FillFeePaid(uint256 indexed commitId, address indexed to, uint256 amount, bool sent);
    event EthClaimed(address indexed account, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();
        _fund(alice, STAKE);
        _fund(bob, STAKE);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
    }

    /// @dev Sum of the fill fees of the commits that are still pending.
    function _pendingFees() internal view returns (uint256 sum) {
        for (uint256 id = 1; id < router.nextCommitId(); ++id) {
            IFallpitRouter.Commit memory c = router.getCommit(id);
            if (c.status == IFallpitRouter.CommitStatus.Pending) sum += c.fillFee;
        }
    }

    // --------------------------------------------------------------------------------------------
    // the parameter
    // --------------------------------------------------------------------------------------------

    /// @dev Default 0.0001 ETH: a fill of about 3.5M gas at the chain's 0.02 gwei with a 30% margin. The
    ///      round freezes it at open, the commit carries it, and the lens quotes it.
    function test_fillFee_default_frozenPerRound_quotedByTheLens() public {
        assertEq(book.defaultParams().fillFee, FILL_FEE);
        assertEq(FILL_FEE, 0.0001 ether);
        assertGe(FILL_FEE, uint256(3_500_000) * 0.02 gwei * 130 / 100, "covers 3.5M gas plus 30%");
        _open();
        assertEq(hook.getConfig(roundId).params.fillFee, FILL_FEE);
        (,,,,,, uint64 contextFee,) = hook.commitContext(roundId, 2);
        assertEq(contextFee, FILL_FEE);
        (,,,, uint256 quotedFee,) = lens.quote(roundId, HIGHER, true, 1_000e18, S0, clock + 2);
        assertEq(quotedFee, FILL_FEE, "the lens tells the app what to attach");

        // the owner's new default reaches rounds opened a day later, never this one
        IPitBook.Params memory p = book.defaultParams();
        p.fillFee = 0.001 ether;
        vm.prank(owner);
        book.setDefaultParams(p);
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, STAKE);
        assertEq(router.getCommit(id).fillFee, FILL_FEE);
        _warp(clock + 24 hours);
        assertEq(book.defaultParams().fillFee, 0.001 ether);
        assertEq(hook.getConfig(roundId).params.fillFee, FILL_FEE, "an open round keeps its fee");
    }

    function test_fillFee_ownerBounds_zeroToOneHundredthOfAnEther() public {
        IPitBook.Params memory p = book.defaultParams();
        vm.startPrank(owner);
        p.fillFee = 0.01 ether + 1;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.fillFee = 0.01 ether;
        book.setDefaultParams(p);
        p.fillFee = 0;
        book.setDefaultParams(p);
        vm.stopPrank();
    }

    // --------------------------------------------------------------------------------------------
    // commit: exactly the fee
    // --------------------------------------------------------------------------------------------

    function test_fillFee_wrongValueAtCommit_reverts() public {
        _open();
        uint256[4] memory wrong = [uint256(0), FILL_FEE - 1, FILL_FEE + 1, 1 ether];
        for (uint256 i; i < 4; ++i) {
            vm.prank(alice);
            vm.expectRevert(IFallpitRouter.WrongFillFee.selector);
            router.commit{value: wrong[i]}(roundId, HIGHER, true, 1_000e18, 1_000e18);
        }
        // a sell commit pays it too
        _buy(alice, HIGHER, 1_000e18, S0);
        vm.startPrank(alice);
        _token(HIGHER).approve(address(router), 500e18);
        vm.expectRevert(IFallpitRouter.WrongFillFee.selector);
        router.commit(roundId, HIGHER, false, 500e18, 0);
        vm.stopPrank();

        assertEq(address(router).balance, 0, "nothing was taken");
        assertEq(chip.balanceOf(address(router)), 0);
        assertEq(router.nextCommitId(), 2, "only the one buy above was ever committed");

        // with the right value the fee sits in the router with the commit
        uint256 before = alice.balance;
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, 1_000e18);
        assertEq(alice.balance, before - FILL_FEE);
        assertEq(address(router).balance, FILL_FEE);
        assertEq(router.getCommit(id).fillFee, FILL_FEE);
        assertEq(_pendingFees(), FILL_FEE);
    }

    // --------------------------------------------------------------------------------------------
    // who is paid
    // --------------------------------------------------------------------------------------------

    function test_fillFee_paidToTheFiller_onAFill() public {
        _open();
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, STAKE);
        bytes memory report = _printFor(id, S0);
        address filler = makeAddr("anyFiller");
        uint256 aliceEth = alice.balance;

        vm.expectEmit(true, true, false, true, address(router));
        emit FillFeePaid(id, filler, FILL_FEE, true);
        vm.prank(filler);
        assertTrue(router.fill(id, report));

        assertEq(filler.balance, FILL_FEE, "whoever fills is paid, not a named keeper");
        assertEq(address(router).balance, 0);
        assertEq(router.ethOwed(filler), 0);
        assertEq(alice.balance, aliceEth, "the trader paid at commit and gets nothing back");
        assertEq(_token(HIGHER).balanceOf(alice), 1_000e18);
    }

    /// @dev A fill the hook rejects for good, and a fill the commit's own limit rejects, are refunds. The
    ///      trader gets the whole escrow back; the filler did the work and keeps the fee.
    function test_fillFee_paidToTheFiller_onARefundInsideFill() public {
        _open();
        address filler = makeAddr("anyFiller");
        uint256 cap = hook.getConfig(roundId).maxFill;

        // rejected by the hook: over the per-fill cap
        uint256 id = _commitBuy(alice, HIGHER, cap + 1, STAKE);
        bytes memory report = _printFor(id, S0);
        vm.expectEmit(true, true, false, true, address(router));
        emit FillFeePaid(id, filler, FILL_FEE, true);
        vm.prank(filler);
        assertFalse(router.fill(id, report));
        assertEq(uint8(router.getCommit(id).status), uint8(IFallpitRouter.CommitStatus.Refunded));
        assertEq(chip.balanceOf(alice), STAKE, "the chips came back whole");
        assertEq(filler.balance, FILL_FEE);

        // rejected by the commit's limit, after a full pricing run
        id = _commitBuy(alice, HIGHER, 1_000e18, 1);
        report = _printFor(id, S0);
        vm.prank(filler);
        assertFalse(router.fill(id, report));
        assertEq(chip.balanceOf(alice), STAKE);
        assertEq(filler.balance, 2 * FILL_FEE);

        assertEq(address(router).balance, 0);
        assertEq(alice.balance, 1 ether - 2 * FILL_FEE, "a commit that cannot fill costs its sender the fee");
    }

    function test_fillFee_returnsToTheTrader_whenNobodyFills() public {
        _open();
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, 5_000e18);
        IFallpitRouter.Commit memory c = router.getCommit(id);
        assertEq(alice.balance, 1 ether - FILL_FEE);

        // not yet: the fill window is still open
        _warp(c.fillTs + c.refundDelay);
        vm.expectRevert(IFallpitRouter.RefundNotDue.selector);
        router.refund(id);

        _warp(c.fillTs + c.refundDelay + 1);
        address anyone = makeAddr("anyone");
        vm.expectEmit(true, true, false, true, address(router));
        emit FillFeePaid(id, alice, FILL_FEE, true);
        vm.prank(anyone);
        router.refund(id);
        assertEq(alice.balance, 1 ether, "the fee went back to the trader");
        assertEq(chip.balanceOf(alice), STAKE);
        assertEq(anyone.balance, 0, "whoever calls refund earns nothing");
        assertEq(address(router).balance, 0);

        // and it is gone for a late filler
        bytes memory report = _signedPrint(NVDA, S0, c.fillTs, c.fillTs - 1);
        vm.prank(keeper);
        vm.expectRevert(IFallpitRouter.CommitNotPending.selector);
        router.fill(id, report);
        assertEq(keeper.balance, 0);
    }

    /// @dev A fill that reverts (a report that is not the print for the instant) pays nobody and leaves the
    ///      commit and its fee where they were.
    function test_fillFee_aRevertedFill_paysNothing() public {
        _open();
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, STAKE);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t + 3);
        _fillReverts(id, _keeperPrint(NVDA, S0, t + 3));
        assertEq(keeper.balance, 0);
        assertEq(address(router).balance, FILL_FEE);
        assertEq(_pendingFees(), FILL_FEE);
        assertTrue(_fill(id, S0));
        assertEq(keeper.balance, FILL_FEE);
    }

    // --------------------------------------------------------------------------------------------
    // with the oracle's own fee (Pyth)
    // --------------------------------------------------------------------------------------------

    /// @dev The filler brings the oracle's update fee with `fill`; that is separate from the fill fee the
    ///      trader brought with the commit. On a fill the oracle is paid from the filler's ETH and the
    ///      filler earns the fill fee; on a refund the filler's ETH comes back with the fill fee.
    function test_fillFee_andTheOraclesUpdateFee_areSeparate() public {
        _use(TSLA, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        _open();
        pyth.setFee(7);
        vm.deal(keeper, 1 ether);

        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        bytes memory report = _printFor(id, TSLA_S0);
        // the router holds the trader's fee; without the oracle's fee the fill cannot use it for the oracle
        assertEq(address(router).balance, FILL_FEE);
        _fillReverts(id, report);
        assertEq(address(router).balance, FILL_FEE, "fill fees never pay the oracle");

        vm.prank(keeper);
        assertTrue(router.fill{value: 7}(id, report));
        assertEq(address(pyth).balance, 7);
        assertEq(keeper.balance, 1 ether - 7 + FILL_FEE);
        assertEq(address(router).balance, 0);
        assertEq(address(hook).balance, 0);

        // a refund inside fill: the oracle fee the filler sent comes back, with the fill fee on top
        id = _commitBuy(bob, HIGHER, 20_001e18, STAKE);
        report = _printFor(id, TSLA_S0);
        vm.prank(keeper);
        assertFalse(router.fill{value: 7}(id, report));
        assertEq(chip.balanceOf(bob), STAKE);
        assertEq(keeper.balance, 1 ether - 7 + 2 * FILL_FEE);
        assertEq(address(pyth).balance, 7);
        assertEq(address(router).balance, 0);
        assertEq(address(hook).balance, 0);
    }

    // --------------------------------------------------------------------------------------------
    // a receiver that will not take the coin
    // --------------------------------------------------------------------------------------------

    /// @dev A filler contract whose `receive` reverts. The fill goes through all the same; the fee waits
    ///      for it in `ethOwed` and it pulls it to an address of its choice.
    function test_fillFee_fillerThatRevertsOnReceive_cannotBlockTheFill_andClaimsLater() public {
        _open();
        RevertingFiller grump = new RevertingFiller(router);
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, STAKE);
        bytes memory report = _printFor(id, S0);

        vm.expectEmit(true, true, false, true, address(router));
        emit FillFeePaid(id, address(grump), FILL_FEE, false);
        assertTrue(grump.fill(id, report), "the trade went through");
        assertEq(_token(HIGHER).balanceOf(alice), 1_000e18);
        assertEq(address(grump).balance, 0);
        assertEq(router.ethOwed(address(grump)), FILL_FEE);
        assertEq(address(router).balance, FILL_FEE);

        // the same on a refund inside fill
        uint256 id2 = _commitBuy(bob, HIGHER, 20_001e18, STAKE);
        report = _printFor(id2, S0);
        assertFalse(grump.fill(id2, report));
        assertEq(chip.balanceOf(bob), STAKE, "the trader's refund is not held up");
        assertEq(router.ethOwed(address(grump)), 2 * FILL_FEE);
        assertEq(address(router).balance, 2 * FILL_FEE + _pendingFees());

        // nobody else can take it
        vm.prank(alice);
        vm.expectRevert(IFallpitRouter.NothingToClaim.selector);
        router.claimEth(alice);
        // claiming to itself fails while it refuses coin, and nothing is lost
        vm.expectRevert();
        grump.claim(address(grump));
        assertEq(router.ethOwed(address(grump)), 2 * FILL_FEE);

        address payout = makeAddr("payout");
        vm.expectEmit(true, true, false, true, address(router));
        emit EthClaimed(address(grump), payout, 2 * FILL_FEE);
        assertEq(grump.claim(payout), 2 * FILL_FEE);
        assertEq(payout.balance, 2 * FILL_FEE);
        assertEq(router.ethOwed(address(grump)), 0);
        assertEq(address(router).balance, 0);
        vm.expectRevert(IFallpitRouter.NothingToClaim.selector);
        grump.claim(payout);
    }

    /// @dev The oracle fee a reverting filler sent with a fill that ends in a refund is credited with the
    ///      fill fee: before the fill fee existed, such a filler made its own refund-fill revert.
    function test_fillFee_revertingFiller_oracleEthOfARefundIsCreditedToo() public {
        _use(TSLA, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        _open();
        pyth.setFee(7);
        RevertingFiller grump = new RevertingFiller{value: 1 ether}(router);
        uint256 id = _commitBuy(alice, HIGHER, 20_001e18, STAKE);
        bytes memory report = _printFor(id, TSLA_S0);
        assertFalse(grump.fill{value: 7}(id, report));
        assertEq(chip.balanceOf(alice), STAKE);
        assertEq(router.ethOwed(address(grump)), FILL_FEE + 7);
        assertEq(address(router).balance, FILL_FEE + 7);
        grump.setAccepts(true);
        assertEq(grump.claim(address(grump)), FILL_FEE + 7);
        assertEq(address(router).balance, 0);
    }

    /// @dev A filler whose `receive` burns all the gas it gets. The payment is capped at 100,000 gas, so
    ///      the fill completes and the fee waits in `ethOwed`.
    function test_fillFee_fillerThatBurnsItsGas_cannotBlockTheFill() public {
        _open();
        GuzzlingFiller guzzler = new GuzzlingFiller(router);
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, STAKE);
        bytes memory report = _printFor(id, S0);
        uint256 gasBefore = gasleft();
        assertTrue(guzzler.fill(id, report));
        uint256 used = gasBefore - gasleft();
        // a fill with the vol-mix prior costs about 5M; the guzzler may add only its 100,000
        assertLt(used, 6_000_000, "the receiver burned its allowance, not the fill's gas");
        assertEq(_token(HIGHER).balanceOf(alice), 1_000e18);
        assertEq(router.ethOwed(address(guzzler)), FILL_FEE);
        address payout = makeAddr("payout");
        assertEq(guzzler.claim(payout), FILL_FEE);
        assertEq(payout.balance, FILL_FEE);
    }

    /// @dev A trader contract that refuses coin and whose commit nobody fills. Anyone can still refund it:
    ///      the chips go back, and the fee waits for the trader in `ethOwed`.
    function test_fillFee_traderThatRevertsOnReceive_cannotBlockItsTimeoutRefund() public {
        _open();
        RevertingFiller trader = new RevertingFiller{value: 1 ether}(router);
        chip.mint(address(trader), STAKE);
        trader.approve(address(chip), address(router));
        uint256 id = trader.commit(roundId, HIGHER, true, 1_000e18, 5_000e18, FILL_FEE);
        IFallpitRouter.Commit memory c = router.getCommit(id);
        _warp(c.fillTs + c.refundDelay + 1);

        vm.expectEmit(true, true, false, true, address(router));
        emit FillFeePaid(id, address(trader), FILL_FEE, false);
        router.refund(id);
        assertEq(chip.balanceOf(address(trader)), STAKE, "the escrow is back");
        assertEq(router.ethOwed(address(trader)), FILL_FEE);
        assertEq(uint8(router.getCommit(id).status), uint8(IFallpitRouter.CommitStatus.Refunded));
        address payout = makeAddr("payout");
        assertEq(trader.claim(payout), FILL_FEE);
        assertEq(payout.balance, FILL_FEE);
        assertEq(address(router).balance, 0);
    }

    // --------------------------------------------------------------------------------------------
    // a receiver that reenters
    // --------------------------------------------------------------------------------------------

    /// @dev While it is paid for one fill, a filler tries to fill a second pending commit (to be paid
    ///      twice in one call), to refund it, to claim and to commit. The commit it was paid for is
    ///      already closed and the router is locked: every call is refused, the first payment stands, and
    ///      the second commit is untouched.
    function test_fillFee_reentrantFiller_isLockedOut() public {
        _open();
        ReentrantFiller reenter = new ReentrantFiller{value: 1 ether}(router);
        uint256 first = _commitBuy(alice, HIGHER, 1_000e18, STAKE);
        uint256 second = _commitBuy(bob, LOWER, 1_000e18, STAKE);
        bytes memory report = _printFor(first, S0);
        reenter.arm(second, report, roundId, FILL_FEE);

        assertTrue(reenter.fill(first, report));
        assertEq(reenter.paidCalls(), 1, "the payment did reach the filler's receive");
        assertEq(reenter.successes(), 0, "none of the four calls got back in");
        assertEq(reenter.lastRevert(), IFallpitRouter.Reentrancy.selector);
        assertEq(address(reenter).balance, 1 ether + FILL_FEE, "paid once");
        assertEq(router.ethOwed(address(reenter)), 0);

        assertEq(uint8(router.getCommit(second).status), uint8(IFallpitRouter.CommitStatus.Pending));
        assertEq(router.nextCommitId(), 3, "no commit was made from inside");
        assertEq(address(router).balance, FILL_FEE, "the second commit's fee is still there");
        assertEq(_pendingFees(), FILL_FEE);
        assertEq(_token(LOWER).totalSupply(), 0);

        // filling the second commit the ordinary way pays the ordinary fee
        assertTrue(reenter.fill(second, report));
        assertEq(reenter.paidCalls(), 2);
        assertEq(reenter.successes(), 0);
        assertEq(address(reenter).balance, 1 ether + 2 * FILL_FEE);
        assertEq(address(router).balance, 0);
    }

    // --------------------------------------------------------------------------------------------
    // a fee of zero switches it off
    // --------------------------------------------------------------------------------------------

    function test_fillFee_zero_disablesIt() public {
        IPitBook.Params memory p = book.defaultParams();
        p.fillFee = 0;
        _setParams(p);
        _open();
        assertEq(hook.getConfig(roundId).params.fillFee, 0);

        vm.prank(alice);
        vm.expectRevert(IFallpitRouter.WrongFillFee.selector);
        router.commit{value: 1}(roundId, HIGHER, true, 1_000e18, 1_000e18);

        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, 5_000e18);
        assertEq(alice.balance, 1 ether);
        assertEq(address(router).balance, 0);
        assertTrue(_fill(id, S0));
        assertEq(keeper.balance, 0);

        id = _commitBuy(alice, HIGHER, 1_000e18, 5_000e18);
        IFallpitRouter.Commit memory c = router.getCommit(id);
        _warp(c.fillTs + c.refundDelay + 1);
        router.refund(id);
        assertEq(alice.balance, 1 ether);
        assertEq(address(router).balance, 0);
    }

    // --------------------------------------------------------------------------------------------
    // conservation
    // --------------------------------------------------------------------------------------------

    /// @dev Every way a commit can end, mixed, with fillers that take coin and fillers that do not: after
    ///      each step the router holds exactly the fees of the pending commits plus what it owes.
    function test_fillFee_routerBalance_isPendingFeesPlusOwed() public {
        _open();
        RevertingFiller grump = new RevertingFiller(router);
        uint256 owed;
        uint256[] memory stale = new uint256[](4);
        uint256 staleCount;
        for (uint256 i; i < 12; ++i) {
            address user = i % 2 == 0 ? alice : bob;
            // every third commit is left for the timeout, every fourth cannot fill (over the cap)
            uint256 shares = i % 4 == 3 ? 20_001e18 : 500e18 + i * 100e18;
            uint256 id = _commitBuy(user, uint8(i % PRODUCTS), shares, 5_000e18);
            assertEq(address(router).balance, _pendingFees() + owed);
            if (i % 3 == 2) {
                stale[staleCount++] = id;
                // the next commit after its window: a pending commit holds the round's later ones until then
                IFallpitRouter.Commit memory c = router.getCommit(id);
                _warp(c.fillTs + c.refundDelay + 1);
                continue;
            }
            bytes memory report = _printFor(id, S0);
            if (i % 2 == 0) {
                grump.fill(id, report);
                owed += FILL_FEE;
            } else {
                vm.prank(keeper);
                router.fill(id, report);
            }
            assertEq(router.ethOwed(address(grump)), owed);
            assertEq(address(router).balance, _pendingFees() + owed);
        }
        assertEq(_pendingFees(), staleCount * FILL_FEE);

        _warp(clock + 60);
        for (uint256 i; i < staleCount; ++i) {
            router.refund(stale[i]);
            assertEq(address(router).balance, _pendingFees() + owed);
        }
        assertEq(_pendingFees(), 0);
        assertEq(address(router).balance, owed);

        address payout = makeAddr("payout");
        grump.claim(payout);
        assertEq(address(router).balance, 0);
        // every wei the traders attached is with a filler, back with a trader, or claimed
        assertEq(
            alice.balance + bob.balance + keeper.balance + payout.balance, 2 ether, "native coin is conserved"
        );
    }
}
