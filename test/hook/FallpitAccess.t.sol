// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {HookFixture} from "./HookFixture.sol";
import {MockChip} from "./mocks/MockChips.sol";
import {MockPitOracle} from "./mocks/MockPitOracle.sol";
import {FallpitHook} from "../../src/FallpitHook.sol";
import {FallpitRouter} from "../../src/FallpitRouter.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {ILadderMath} from "../../src/interfaces/ILadderMath.sol";
import {IPitOracle} from "../../src/interfaces/IPitOracle.sol";
import {IPitVault} from "../../src/interfaces/IPitVault.sol";
import {IChipGuard} from "../../src/interfaces/IChipGuard.sol";

/// @notice Who may call what: the router gate of fills and escrow, commit and fill rules, the one-time
///         router wiring, the tickets and book permissions.
contract FallpitAccessTest is HookFixture {
    address internal mallory = makeAddr("mallory");

    function setUp() public override {
        super.setUp();
        _fund(alice, 100_000e18);
        _fund(bob, 100_000e18);
    }

    // --------------------------------------------------------------------------------------------
    // the router gate
    // --------------------------------------------------------------------------------------------

    function test_fillAndPull_onlyTheRouter() public {
        _open();
        _buy(alice, HIGHER, 1_000e18, S0);
        uint256 id = _commitBuy(alice, LOWER, 1_000e18, 10_000e18);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t);
        bytes memory report = _report(t, S0);
        uint256 ticket = _token(HIGHER).id;

        // the attacker copies exactly what the router would send, naming alice as the user
        address[3] memory callers = [mallory, keeper, book.owner()];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(IFallpitHook.OnlyRouter.selector);
            hook.fill(roundId, LOWER, true, 1_000e18, 10_000e18, alice, t, report);
            vm.expectRevert(IFallpitHook.OnlyRouter.selector);
            hook.fill(roundId, HIGHER, false, 1_000e18, 0, callers[i], t, report);
            vm.expectRevert(IFallpitHook.OnlyRouter.selector);
            hook.pull(alice, ticket, 1_000e18);
            // nor through the router's own fill body
            vm.expectRevert(IFallpitRouter.OnlySelf.selector);
            router.execute(id, report);
            vm.stopPrank();
        }
        assertEq(_token(LOWER).totalSupply(), 0);
        assertEq(_token(HIGHER).balanceOf(alice), 1_000e18);
    }

    function test_aGiftOfChips_changesNothingTheHookAccounts() public {
        _open();
        chip.mint(mallory, 500e18);
        vm.prank(mallory);
        chip.transfer(address(hook), 500e18);
        (uint256 held, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(held, HOUSE_CAPITAL + 500e18);
        assertEq(owed, HOUSE_CAPITAL);
        assertEq(_state().held, HOUSE_CAPITAL);
    }

    // --------------------------------------------------------------------------------------------
    // commit and fill rules
    // --------------------------------------------------------------------------------------------

    function test_fill_onlyWithThePrintForItsInstant() public {
        _open();
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, 100_000e18);
        uint64 t = router.getCommit(id).fillTs;

        vm.expectRevert(IFallpitRouter.TooEarly.selector);
        router.fill(id, "");

        // prints before, at and after the fill instant
        bytes memory before = oracle.post(NVDA, KEEPER, S0 * 99 / 100, t - 1);
        bytes memory theOne = oracle.post(NVDA, KEEPER, S0, t + 1);
        bytes memory later = oracle.post(NVDA, KEEPER, S0 * 98 / 100, t + 4);
        _warp(t + 10);

        try router.fill(id, before) {
            fail("filled with an earlier print");
        } catch (bytes memory err) {
            assertEq(bytes4(err), MockPitOracle.NotThePrint.selector, "the raw revert");
        }
        try router.fill(id, later) {
            fail("filled with a later print");
        } catch (bytes memory err) {
            assertEq(bytes4(err), MockPitOracle.NotThePrint.selector, "the raw revert");
        }
        // a print of another ticker for the same instant
        oracle.setSupported(bytes32("TSLA"), true);
        bytes memory otherTicker = oracle.post(bytes32("TSLA"), KEEPER, 1e18, t + 1);
        try router.fill(id, otherTicker) {
            fail("filled with another ticker's print");
        } catch (bytes memory err) {
            assertEq(bytes4(err), MockPitOracle.WrongTicker.selector, "the raw revert");
        }
        vm.expectRevert();
        router.fill(id, "");
        assertEq(
            uint8(router.getCommit(id).status), uint8(IFallpitRouter.CommitStatus.Pending), "still pending"
        );

        // the unique print fills it, once
        vm.prank(mallory); // anyone may fill
        assertTrue(router.fill(id, theOne));
        assertEq(_token(HIGHER).balanceOf(alice), 1_000e18, "tokens go to the committer, not the filler");
        vm.expectRevert(IFallpitRouter.CommitNotPending.selector);
        router.fill(id, theOne);
        _warp(t + 500);
        vm.expectRevert(IFallpitRouter.CommitNotPending.selector);
        router.refund(id);
    }

    function test_fillWindow_thenRefund_neverBoth() public {
        _open();
        uint256 chipsBefore = chip.balanceOf(alice);
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, 5_000e18);
        assertEq(chip.balanceOf(alice), chipsBefore - 5_000e18, "the limit is escrowed");
        assertEq(router.escrowed(address(chip)), 5_000e18);
        uint64 t = router.getCommit(id).fillTs;
        bytes memory report = _report(t, S0);

        // inside the window nobody can refund, and the user cannot cancel. (The default window is 30 s.)
        _warp(t + 30);
        vm.expectRevert(IFallpitRouter.RefundNotDue.selector);
        router.refund(id);

        // after the window the fill is gone for good, even with the right print
        _warp(t + 31);
        vm.expectRevert(IFallpitRouter.FillWindowClosed.selector);
        router.fill(id, report);
        vm.prank(mallory); // anyone may refund; the chips go back to the committer
        router.refund(id);
        assertEq(chip.balanceOf(alice), chipsBefore);
        assertEq(router.escrowed(address(chip)), 0);
        assertEq(uint8(router.getCommit(id).status), uint8(IFallpitRouter.CommitStatus.Refunded));
        vm.expectRevert(IFallpitRouter.CommitNotPending.selector);
        router.refund(id);
        vm.expectRevert(IFallpitRouter.CommitNotPending.selector);
        router.fill(id, report);
    }

    function test_hook_enforcesTheFillWindowItself() public {
        _open();
        uint64 t = clock;
        bytes memory report = _report(t, S0);
        _warp(t + 31);
        vm.prank(address(router));
        vm.expectRevert(IFallpitHook.FillExpired.selector);
        hook.fill(roundId, HIGHER, false, 1e18, 0, alice, t, report);
    }

    function test_commit_rules() public {
        // unknown round
        vm.expectRevert(IFallpitRouter.RoundNotOpen.selector);
        vm.prank(alice);
        router.commit{value: FILL_FEE}(bytes32(uint256(1)), 2, true, 1e18, 1e18);

        // the round opens a minute after Monday's close and takes commits at once (the after-hours)
        roundId = hook.openRound(NVDA, address(chip), day);
        _commitBuy(alice, HIGHER, 1e18, 1e18);
        // a commit is priced two seconds later: the last one of the after-hours is made at 19:59:57
        _warp(NYTime.at(day0, 20 hours) - 3);
        _commitBuy(alice, HIGHER, 1e18, 1e18);
        _warp(NYTime.at(day0, 20 hours) - 2);
        vm.expectRevert(IFallpitRouter.OutsideTradingWindow.selector);
        vm.prank(alice);
        router.commit{value: FILL_FEE}(roundId, HIGHER, true, 1e18, 1e18);
        // nothing overnight; the first commit of the pre-market is made at 03:59:58
        _warp(NYTime.at(day, 4 hours) - 3);
        vm.expectRevert(IFallpitRouter.OutsideTradingWindow.selector);
        vm.prank(alice);
        router.commit{value: FILL_FEE}(roundId, HIGHER, true, 1e18, 1e18);
        _warp(NYTime.at(day, 4 hours) - 2);
        _commitBuy(alice, HIGHER, 1e18, 1e18);
        // no break between the pre-market and the regular session
        _warp(NYTime.openTs(day) - 2);
        _commitBuy(alice, HIGHER, 1e18, 1e18);
        _warp(NYTime.openTs(day));
        _commitBuy(alice, HIGHER, 1e18, 1e18);

        vm.startPrank(alice);
        vm.expectRevert(IFallpitRouter.ZeroAmount.selector);
        router.commit{value: FILL_FEE}(roundId, HIGHER, true, 0, 1e18);
        vm.expectRevert(IFallpitRouter.ZeroAmount.selector);
        router.commit{value: FILL_FEE}(roundId, HIGHER, true, 1e18, 0);
        // a product the menu does not have
        vm.expectRevert(IFallpitRouter.UnknownProduct.selector);
        router.commit{value: FILL_FEE}(roundId, uint8(PRODUCTS), true, 1e18, 1e18);
        vm.expectRevert(IFallpitRouter.UnknownProduct.selector);
        router.commit{value: FILL_FEE}(roundId, 12, true, 1e18, 1e18);
        vm.expectRevert(IFallpitRouter.UnknownProduct.selector);
        router.commit{value: FILL_FEE}(roundId, 255, false, 1e18, 0);
        vm.expectRevert(); // selling tokens the user does not hold
        router.commit{value: FILL_FEE}(roundId, HIGHER, false, 1e18, 0);
        vm.stopPrank();

        // the last commit is the one whose fill instant is the cutoff
        uint64 cutoff = NYTime.closeTs(day) - 630;
        _warp(cutoff - 2);
        uint256 last = _commitBuy(alice, HIGHER, 10e18, 100e18);
        assertEq(router.getCommit(last).fillTs, cutoff);
        _warp(cutoff - 1);
        vm.expectRevert(IFallpitRouter.OutsideTradingWindow.selector);
        vm.prank(alice);
        router.commit{value: FILL_FEE}(roundId, HIGHER, true, 1e18, 1e18);
        assertTrue(_fill(last, S0));

        // after settlement the round takes no commits
        _recordClose(S0, TRUSTLESS);
        hook.settleRound(house, day);
        vm.expectRevert(IFallpitRouter.RoundNotOpen.selector);
        vm.prank(alice);
        router.commit{value: FILL_FEE}(roundId, HIGHER, true, 1e18, 1e18);
    }

    function test_redeem_onlyHolderOrRouter() public {
        _open();
        _buy(alice, HIGHER, 1_000e18, S0);
        _closeAndFinalize(S0 * 101 / 100);
        uint256 token = _token(HIGHER).id;

        vm.expectRevert(IFallpitHook.NotHolder.selector);
        vm.prank(mallory);
        hook.redeem(token, alice, 1_000e18);
        vm.expectRevert(IFallpitHook.UnknownToken.selector);
        vm.prank(alice);
        hook.redeem(uint256(uint160(address(chip))), alice, 1e18);
        vm.expectRevert(IFallpitHook.UnknownToken.selector);
        vm.prank(alice);
        hook.redeem(token | 0x0b, alice, 1e18); // an index above the menu
        vm.expectRevert(IFallpitHook.ZeroAmount.selector);
        vm.prank(alice);
        hook.redeem(token, alice, 0);
        // through the router only the caller's own tokens burn
        vm.expectRevert();
        vm.prank(mallory);
        router.redeem(token, 1e18);
        vm.prank(alice);
        assertEq(router.redeem(token, 1_000e18), 1_000e18);
    }

    // --------------------------------------------------------------------------------------------
    // router wiring
    // --------------------------------------------------------------------------------------------

    function test_setHook_once_byDeployer_thenFrozen() public {
        FallpitRouter fresh = new FallpitRouter(IPoolManager(address(pm)));
        assertEq(fresh.deployer(), address(this));
        assertEq(address(fresh.hook()), address(0));

        vm.expectRevert(IFallpitRouter.HookNotSet.selector);
        fresh.commit(bytes32(0), 0, true, 1, 1);

        vm.expectRevert(IFallpitRouter.OnlyDeployer.selector);
        vm.prank(mallory);
        fresh.setHook(address(hook));
        // a hook that names another router, and something that is not a hook at all
        vm.expectRevert(IFallpitRouter.BadHook.selector);
        fresh.setHook(address(hook));
        vm.expectRevert(IFallpitRouter.BadHook.selector);
        fresh.setHook(mallory);
        vm.expectRevert();
        fresh.setHook(address(chip));

        address at = address(uint160(0xBEEF) << 144);
        FallpitHook hook2 = _deployHook(at, address(fresh));
        fresh.setHook(address(hook2));
        assertEq(address(fresh.hook()), address(hook2));

        // frozen: not the deployer, not even to the same hook
        vm.expectRevert(IFallpitRouter.HookAlreadySet.selector);
        fresh.setHook(address(hook2));
        address at3 = address(uint160(0xCAFE) << 144);
        FallpitHook hook3 = _deployHook(at3, address(fresh));
        vm.expectRevert(IFallpitRouter.HookAlreadySet.selector);
        fresh.setHook(address(hook3));
        assertEq(address(fresh.hook()), address(hook2));

        // the live router is frozen too
        vm.expectRevert(IFallpitRouter.HookAlreadySet.selector);
        router.setHook(address(hook3));
        assertEq(hook.router(), address(router));
    }

    function test_routerUnlockCallback_guarded() public {
        vm.expectRevert(IFallpitRouter.OnlyPoolManager.selector);
        router.unlockCallback(abi.encode(uint256(1), bytes("")));
        vm.prank(address(pm));
        vm.expectRevert(IFallpitRouter.OnlySelf.selector);
        router.unlockCallback(abi.encode(uint256(1), bytes("")));
    }

    function test_hookConstructor_refusesZeroDependencies() public {
        address[6] memory deps =
            [address(router), address(math), address(oracle), address(vault), address(guard), address(book)];
        for (uint256 i; i < 6; ++i) {
            address[6] memory d = deps;
            d[i] = address(0);
            vm.expectRevert(IFallpitHook.ZeroAddress.selector);
            new FallpitHook(
                d[0], ILadderMath(d[1]), IPitOracle(d[2]), IPitVault(d[3]), IChipGuard(d[4]), IPitBook(d[5])
            );
        }
    }

    function deployHookAt(bytes memory args, address at) external {
        deployCodeTo("FallpitHook.sol:FallpitHook", args, at);
    }

    // --------------------------------------------------------------------------------------------
    // tickets
    // --------------------------------------------------------------------------------------------

    function test_tickets_onlyTheHookMintsAndBurns_andTheyTransferAsERC6909() public {
        _open();
        _buy(alice, HIGHER, 1_000e18, S0);
        Ticket memory token = _token(HIGHER);
        // no one but a fill or a redemption mints or burns: the hook has no such function to call

        // a plain ERC-6909 otherwise: transfers work, no implicit allowances or operators
        vm.prank(alice);
        token.transfer(bob, 400e18);
        assertEq(token.balanceOf(bob), 400e18);
        assertEq(hook.allowance(alice, address(router), token.id), 0, "the router needs no allowance");
        assertFalse(hook.isOperator(alice, address(router)));
        vm.expectRevert();
        vm.prank(mallory);
        hook.transferFrom(alice, mallory, token.id, 1e18);
        vm.prank(alice);
        hook.approve(mallory, token.id, 1e18);
        vm.prank(mallory);
        hook.transferFrom(alice, mallory, token.id, 1e18);
        assertEq(token.balanceOf(mallory), 1e18);
        assertEq(token.totalSupply(), 1_000e18, "a transfer moves tickets, the supply stays");
        assertEq(hook.decimals(token.id), 18);
    }

    // --------------------------------------------------------------------------------------------
    // owner and guardian powers
    // --------------------------------------------------------------------------------------------

    function test_owner_cannotChangeAnOpenRound() public {
        _open();
        IPitBook.Params memory p = book.defaultParams();
        p.baseFee = 0.1e18;
        p.closeFee = 0.2e18;
        p.maxFillBps = 10;
        p.fillDelay = 60;
        p.refundDelay = 120;
        p.protocolFeeBps = 5000;
        vm.startPrank(owner);
        book.setDefaultParams(p);
        book.setPaused(true);
        // the day of an open round cannot be skipped at all: its close is less than 24 hours away
        vm.expectRevert(IPitBook.SkipTooLate.selector);
        book.setSkip(NVDA, day, true);
        book.registerTicker(
            NVDA,
            0.0225e18,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 10_000),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        book.setSkipAfterHours(NVDA, day, true);
        vm.stopPrank();

        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(c.params.baseFee, 0.02e18);
        assertEq(c.params.maxFillBps, 200);
        assertEq(c.params.fillDelay, 2);
        assertEq(c.sigma, 0.02e18);
        assertEq(uint8(c.fillSource), uint8(IPitBook.FillSource.KeeperOnly));
        assertEq(c.clock.regular, 7000, "the clock weights it opened with");
        assertFalse(c.clock.skipAfterHours, "a flag set after the round opened does not reach it");
        // and the owner's changes do not even reach a round opened in
        // the next 24 hours: until then the book hands out the old defaults and the old seed
        assertEq(book.defaultParams().maxFillBps, 200);
        assertEq(book.getTicker(NVDA).varWad, SEED_VAR);
        (IPitBook.Params memory pending, uint64 eta) = book.pendingDefaultParams();
        assertEq(pending.maxFillBps, 10);
        assertEq(eta, clock + 24 hours);
        assertEq(book.pendingReseed(NVDA).varWad, 0.0225e18);
        assertEq(book.pendingReseed(NVDA).eta, clock + 24 hours);
        // the open round trades, settles and pays as before
        uint256 id = _commitBuy(alice, HIGHER, 15_000e18, 100_000e18);
        assertEq(router.getCommit(id).fillTs, clock + 2);
        assertTrue(_fill(id, S0));
        _closeAndFinalize(S0 * 101 / 100);
        uint256 token = _token(HIGHER).id;
        vm.prank(alice);
        assertEq(router.redeem(token, 15_000e18), 15_000e18);
    }

    function test_guardian_hasNoOtherPower() public {
        _open();
        _buy(alice, HIGHER, 1_000e18, S0);
        // an open round cannot be voided by the guardian, nor disputed
        vm.prank(guardian);
        vm.expectRevert(IFallpitHook.VoidNotAllowed.selector);
        hook.voidRound(house, day);
        vm.prank(guardian);
        vm.expectRevert(IPitBook.DisputeNotAllowed.selector);
        book.dispute(roundId);
        // nor a finalized one
        _closeAndFinalize(S0 * 101 / 100);
        vm.prank(guardian);
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        hook.voidRound(house, day);
    }

    function test_book_onlyOwner_andBounds() public {
        IPitBook.Params memory p = book.defaultParams();
        vm.startPrank(mallory);
        vm.expectRevert(IPitBook.OnlyOwner.selector);
        book.registerTicker(
            NVDA,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.KeeperOnly
        );
        vm.expectRevert(IPitBook.OnlyOwner.selector);
        book.setSkip(NVDA, day, true);
        vm.expectRevert(IPitBook.OnlyOwner.selector);
        book.setPaused(true);
        vm.expectRevert(IPitBook.OnlyOwner.selector);
        book.setGuardian(mallory);
        vm.expectRevert(IPitBook.OnlyOwner.selector);
        book.setFeeRecipient(mallory);
        vm.expectRevert(IPitBook.OnlyOwner.selector);
        book.setDefaultParams(p);
        vm.expectRevert(IPitBook.OnlyOwner.selector);
        book.transferOwnership(mallory);
        vm.expectRevert(IPitBook.OnlyOwner.selector);
        book.acceptOwnership();
        vm.stopPrank();
        // the guardian has no power in the book
        vm.expectRevert(IPitBook.OnlyOwner.selector);
        vm.prank(guardian);
        book.setPaused(true);

        vm.startPrank(owner);
        p.alpha = 0.79e18 + 1;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.alpha = 0.79e18;
        book.setDefaultParams(p);
        p.closeFee = 0.2e18 + 1;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.baseFee = 0.005e18 - 1; // below the fee floor
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.baseFee = 0.02e18;
        p.closeFee = 0.01e18; // below the base fee
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.closeFee = 0.05e18;
        p.refundDelay = 121; // a long fill window is a long free look at the price
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.refundDelay = 9;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.refundDelay = 120;
        // On the round clock the challenge window is 300 to 3600 s.
        // The next round opens when this one is final and trades in the after-hours from then on.
        p.challengeWindow = 299;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.challengeWindow = 3601;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.challengeWindow = 300;
        book.setDefaultParams(p);
        p.challengeWindow = 3600;
        p.protocolFeeBps = 5001;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.protocolFeeBps = 1000;
        p.maxFillBps = 0;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.maxFillBps = 200;
        p.fillDelay = 1; // one second is the resolution of both clocks: the floor is two
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.fillDelay = 2;
        p.minTrade = 1e12 - 1;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.minTrade = 1_000e18 + 1;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        // the smallest trade must fit under the per-fill cap of the smallest round
        p.minTrade = 21e18; // minCapital 1000 at a 2% cap allows 20
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.minTrade = 20e18;
        book.setDefaultParams(p);
        // the loss limit: a round may always risk a tenth of its capital, and never more than all of it
        assertEq(p.lossLimitBps, 3000, "the default: 30% of the capital");
        p.lossLimitBps = 999;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.lossLimitBps = 10_001;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.lossLimitBps = 1000;
        book.setDefaultParams(p);
        p.lossLimitBps = 10_000;
        book.setDefaultParams(p);
        // the product cap: at most the whole capital, and the smallest trade must fit under it
        assertEq(p.floorCapBps, 10_000, "the default: no product cap");
        p.floorCapBps = 10_001;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.floorCapBps = 0;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.floorCapBps = 199; // minCapital 1000 at a cap of 1.99% allows 19.9, the smallest trade is 20
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.floorCapBps = 200;
        book.setDefaultParams(p);
        p.floorCapBps = 10_000;
        book.setDefaultParams(p);
        // the minimum price: none to a fifth of a chip
        assertEq(p.minPriceWad, 0.02e18, "the default: two hundredths of a chip");
        p.minPriceWad = 0.2e18 + 1;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.minPriceWad = 0.2e18;
        book.setDefaultParams(p);
        p.minPriceWad = 0;
        book.setDefaultParams(p);
        // the menu must be well formed (FallpitMenu.t.sol has every rule)
        p.menu = 0;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.menu = book.DEFAULT_MENU();
        book.setDefaultParams(p);

        vm.expectRevert(IPitBook.BadParams.selector);
        book.registerTicker(
            NVDA,
            0.15e18 * 0.15e18 / 1e18 + 1,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.KeeperOnly
        );
        // clock weights: they sum to 100%, and the regular session holds at least a quarter
        vm.expectRevert(IPitBook.BadParams.selector);
        book.registerTicker(
            NVDA,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(2500, 2500, 2501, 2499),
            0,
            IPitBook.FillSource.KeeperOnly
        );
        vm.expectRevert(IPitBook.BadParams.selector);
        book.registerTicker(
            NVDA,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(600, 1400, 1000, 7001),
            0,
            IPitBook.FillSource.KeeperOnly
        );
        book.registerTicker(
            NVDA,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(2500, 2500, 2500, 2500),
            0,
            IPitBook.FillSource.KeeperOnly
        );
        // the clock of a registered ticker is not a parameter: a reseed must repeat it
        vm.expectRevert(IPitBook.BadParams.selector);
        book.registerTicker(
            NVDA,
            SEED_VAR,
            IPitBook.Clock.EveryDay,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.KeeperOnly
        );
        vm.expectRevert(IPitBook.UnknownTicker.selector);
        book.registerTicker(
            bytes32("NOPE"),
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.KeeperOnly
        );

        // two-step ownership
        book.transferOwnership(mallory);
        vm.stopPrank();
        assertEq(book.owner(), owner);
        vm.prank(mallory);
        book.acceptOwnership();
        assertEq(book.owner(), mallory);
        vm.expectRevert(IPitBook.OnlyOwner.selector);
        vm.prank(owner);
        book.setPaused(true);
    }
}
