// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AttackBase} from "./AttackBase.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";
import {PitOracle} from "../../src/PitOracle.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice On the full real stack: the 24 hour delay on the book owner's pricing inputs, stale closes with
///         the real oracle, ETH sent with a fill that ends in a refund, the two second floor of the fill
///         delay, and the minimum trade frozen per round.
contract OracleAndFillRulesTest is AttackBase {
    receive() external payable {}

    /// @dev The owner (or a stolen owner key) reseeds the variance to the bottom of the clamp and
    ///      loosens the defaults, then opens the round in the same block to trade against it. The round
    ///      opens on the values that were public a day ago.
    function test_ownerCannotMispriceTheNextRoundWithoutADaysNotice() public {
        IPitBook.Params memory p = book.defaultParams();
        p.maxFillBps = 10_000;
        p.baseFee = 0.005e18;
        p.vegaFee = 0;
        vm.startPrank(owner);
        // sigma 0.5%, and the regular session's weight at its floor
        book.registerTicker(
            NVDA,
            0.000025e18,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(2500, 2500, 2500, 2500),
            0,
            IPitBook.FillSource.KeeperOnly
        );
        book.setDefaultParams(p);
        vm.stopPrank();

        _open();
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(c.sigma, 0.02e18, "the seed of a day ago");
        assertEq(c.clock.regular, 7000, "the clock weights of a day ago");
        assertEq(c.params.maxFillBps, 200);
        assertEq(c.params.baseFee, 0.02e18);
        assertEq(c.params.vegaFee, 0.1e18);

        // everyone can see what is coming and when
        assertEq(book.pendingReseed(NVDA).varWad, 0.000025e18);
        (IPitBook.Params memory pending, uint64 eta) = book.pendingDefaultParams();
        assertEq(pending.maxFillBps, 10_000);
        assertEq(eta, NYTime.closeTs(day0) + 60 + 24 hours);
        // The day's close is recorded and steps the old variance; the round after it opens on the
        // reseeded variance (the reseed came into force a minute after that close).
        _closeAndFinalize(S0);
        day += 1;
        _warp(eta);
        roundId = hook.openRound(NVDA, address(chip), day);
        c = hook.getConfig(roundId);
        assertEq(c.sigma, 0.005e18);
        assertEq(c.params.maxFillBps, 10_000);
    }

    /// @dev With the real oracle, a genuine Pyth update for a 16:00:00 of last week still verifies
    ///      in the oracle; the book takes it only from the owner, and never as a variance step.
    function test_staleCloseWithARealOracleReport() public {
        // NVDA's close of Tuesday is never recorded; a week later eve brings the genuine print for it
        uint64 closeAt = NYTime.closeTs(day);
        _warp(closeAt + 7 days);
        bytes memory report = _pythPrint(NVDA, S0 * 130 / 100, closeAt);
        (uint256 price,, bool trustless) = oracle.verifyAt(NVDA, closeAt, report);
        assertEq(price, S0 * 130 / 100);
        assertTrue(trustless);
        vm.prank(alice);
        vm.expectRevert(IPitBook.CloseTooOld.selector);
        book.recordClose(NVDA, day, report);
        vm.prank(owner);
        book.recordClose(NVDA, day, report);
        assertEq(book.getTicker(NVDA).varWad, SEED_VAR, "a 30% print recorded late moves nothing");
        assertEq(book.getTicker(NVDA).lastCloseDay, day);
    }

    /// @dev ETH sent with a fill pays the oracle's update fee. When the fill ends in a refund the
    ///      fill was rolled back, and the ETH goes back to the filler instead of staying in the hook.
    ///      (The filler, here this contract, also earns the commit's fill fee, on the
    ///      refund and on the fill; the oracle fee is still accounted to the wei on top of that.)
    function test_ethSentWithARefundedFill_returnsToTheFiller() public {
        _use(TSLA, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        _open();
        pyth.setFee(7);
        vm.deal(address(this), 1 ether);

        // a commit over the per-fill cap: refunded whatever the report
        uint256 id = _commitBuy(alice, HIGHER, 20_001e18, STAKE);
        bytes memory report = _printFor(id, TSLA_S0);
        uint256 before = address(this).balance;
        assertFalse(router.fill{value: 7}(id, report));
        assertEq(address(this).balance, before + FILL_FEE, "the oracle fee came back with the refund");
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(chip.balanceOf(alice), STAKE);

        // a commit that fills: the fee is spent, to the wei
        id = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        report = _printFor(id, TSLA_S0);
        assertTrue(router.fill{value: 7}(id, report));
        assertEq(address(this).balance, before + 2 * FILL_FEE - 7, "the oracle fee is spent, to the wei");
        assertEq(address(pyth).balance, 7);
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);

        // without the fee the fill reverts (it does not refund) and the commit stays pending
        id = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        report = _printFor(id, TSLA_S0);
        assertEq(_fillReverts(id, report), PitOracle.InsufficientFee.selector);
        assertEq(address(router).balance, FILL_FEE, "the pending commit's fill fee never pays the oracle");
    }

    /// @dev A fill delay of one second would let a print be public before the commit whenever the
    ///      chain's clock lags the oracle's by a second. Two seconds is the floor.
    function test_fillDelayHasATwoSecondFloor() public {
        IPitBook.Params memory p = book.defaultParams();
        assertEq(p.fillDelay, 2);
        p.fillDelay = 1;
        vm.prank(owner);
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
    }

    /// @dev A keeper is never asked to price dust, on either oracle path.
    function test_minimumTradeIsFrozenPerRound() public {
        IPitBook.Params memory p = book.defaultParams();
        p.minTrade = 5e18;
        _setParams(p);
        _open();
        assertEq(hook.getConfig(roundId).params.minTrade, 5e18);
        (,,,,, uint256 minShares,,) = hook.commitContext(roundId, 2);
        assertEq(minShares, 5e18);
        vm.prank(alice);
        vm.expectRevert(IFallpitRouter.BelowMinimumTrade.selector);
        router.commit{value: FILL_FEE}(roundId, HIGHER, true, 5e18 - 1, STAKE);
        // the owner lowering the minimum does not reach the open round
        p.minTrade = 1e12;
        vm.prank(owner);
        book.setDefaultParams(p);
        vm.prank(alice);
        vm.expectRevert(IFallpitRouter.BelowMinimumTrade.selector);
        router.commit{value: FILL_FEE}(roundId, HIGHER, true, 1e18, STAKE);
        _buy(alice, HIGHER, 5e18, S0);
    }
}
