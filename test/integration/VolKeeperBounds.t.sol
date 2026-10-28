// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {AttackBase} from "./AttackBase.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";

/// @notice The vol keeper is one key, and `setSigmaEff` reprices an open round with no trade.
///         `PitBook.stepSigmaEff` bounds it: at most 10% per update, one update per 5 minutes, 0.8x to 1.5x
///         of the round's sigma, and all rises of one round together at most 1.5x. A keeper that colludes
///         with a trader gains little.
contract VolKeeperBoundsTest is AttackBase {
    address internal vk = makeAddr("volKeeper");
    uint256 internal constant LOT = 20_000e18;
    uint256 internal constant LOTS = 6;

    function _testRiskCapBps() internal pure override returns (uint16) {
        return 300;
    }

    function setUp() public override {
        super.setUp();
        vm.warp(clock - 24 hours);
        vm.prank(owner);
        book.setVolKeeper(vk);
        vm.warp(clock);
        _open();
    }

    function _buyTails() internal {
        for (uint256 i; i < LOTS; ++i) {
            _eveBuy(F7, LOT, S0);
            _eveBuy(F0, LOT, S0);
        }
    }

    function _sellTails() internal {
        for (uint256 i; i < LOTS; ++i) {
            _eveSell(F7, LOT, S0);
            _eveSell(F0, LOT, S0);
        }
    }

    function _post(uint256 s) internal {
        vm.prank(vk);
        hook.setSigmaEff(roundId, s);
    }

    /// @dev Eve buys the tails, waits `wait` seconds (the keeper posts `posts` times, as fast as the book
    ///      allows, each asking for 2.5x the round's sigma), and sells them back.
    function _roundTrip(uint256 posts, uint256 wait) internal returns (int256 pnl) {
        uint256 before = MockChip(roundChip).balanceOf(address(eve));
        _buyTails();
        uint64 t0 = clock;
        uint256 s = hook.getConfig(roundId).sigma;
        for (uint256 k; k < posts; ++k) {
            _warp(t0 + uint64(k * 300));
            _post(s * 5 / 2);
        }
        _warp(t0 + uint64(wait));
        _sellTails();
        pnl = int256(MockChip(roundChip).balanceOf(address(eve))) - int256(before);
    }

    function test_honestRoundTripLoses() public {
        int256 pnl = _roundTrip(0, 180);
        console.log("no sigma change, eve pnl (chips)", pnl / 1e18);
        assertLt(pnl, 0);
    }

    /// @dev Three posts of 2.5x a minute apart. The first moves the sigma 10%, the next two are refused.
    ///      Eve's gain is less than what the same round trip costs her with no sigma change (about +1.2k
    ///      against a 3.8k cost).
    function test_colludingVolKeeperCannotDrain() public {
        int256 honest = _honestPnl(180);
        uint256 before = MockChip(roundChip).balanceOf(address(eve));
        _buyTails();
        uint256 s = hook.getConfig(roundId).sigma;
        _post(s * 5 / 2);
        assertEq(hook.sigmaEffOf(roundId), s * 11 / 10, "one step is at most 10%");
        for (uint256 k; k < 2; ++k) {
            _warp(clock + 60);
            vm.prank(vk);
            vm.expectRevert(IFallpitHook.SigmaEffTooSoon.selector);
            hook.setSigmaEff(roundId, s * 5 / 2);
        }
        _warp(clock + 60);
        _sellTails();
        int256 pnl = int256(MockChip(roundChip).balanceOf(address(eve))) - int256(before);
        console.log("sigma 1x -> 1.1x in 3 min, eve pnl (chips)", pnl / 1e18);
        console.log("same trades, no sigma change (chips)", honest / 1e18);
        assertLt(honest, 0);
        assertLt(pnl, -honest, "the gain is less than the honest round trip's cost");
        assertLt(pnl, int256(hook.getConfig(roundId).capital / 500), "under 0.2% of capital");
    }

    /// @dev The fastest ramp the book allows, 1.1x, 1.21x, 1.33x, 1.46x, 1.5x in 20 minutes. A colluding
    ///      keeper still pays the trader about 1.8% of capital. The rise budget allows it once per round
    ///      (`test_riseBudgetStopsCycling`). Limits alone cannot close it: a tail's price moves about
    ///      five times the sigma step. Mainnet needs vol updates signed by the oracle quorum (DESIGN.md 18).
    function test_fastestRampIsBoundedOncePerRound() public {
        int256 honest = _honestPnl(1200);
        int256 pnl = _roundTrip(5, 1200);
        uint256 s = hook.getConfig(roundId).sigma;
        assertEq(hook.sigmaEffOf(roundId), s * 3 / 2, "at the 1.5x top");
        console.log("sigma 1x -> 1.5x in 20 min, eve pnl (chips)", pnl / 1e18);
        console.log("same trades, no sigma change (chips)", honest / 1e18);
        console.log("capital (chips)", hook.getConfig(roundId).capital / 1e18);
        assertLt(pnl, int256(hook.getConfig(roundId).capital / 40), "under 2.5% of capital, once per round");
        // the same ramp again is refused: the rise budget is spent
        _warp(clock + 300);
        _post(s * 5 / 2);
        assertEq(hook.sigmaEffOf(roundId), s * 3 / 2);
    }

    /// @dev The other direction. Eve buys the centre floors, the keeper ramps the
    ///      sigma down to the 0.8x floor (0.9x, 0.81x, 0.8x in 10 minutes), eve sells. Falls have no budget,
    ///      but the floor bounds them: one ramp from 1.5x to 0.8x is the most a round can see.
    function test_downRampIsBounded() public {
        uint256 before = MockChip(roundChip).balanceOf(address(eve));
        for (uint256 i; i < LOTS; ++i) {
            _eveBuy(F4, LOT, S0);
            _eveBuy(F3, LOT, S0);
        }
        uint64 t0 = clock;
        uint256 s = hook.getConfig(roundId).sigma;
        for (uint256 k; k < 3; ++k) {
            _warp(t0 + uint64(k * 300));
            _post(0);
        }
        assertEq(hook.sigmaEffOf(roundId), s * 8 / 10, "at the 0.8x floor");
        _warp(t0 + 600);
        for (uint256 i; i < LOTS; ++i) {
            _eveSell(F4, LOT, S0);
            _eveSell(F3, LOT, S0);
        }
        int256 pnl = int256(MockChip(roundChip).balanceOf(address(eve))) - int256(before);
        console.log("sigma 1x -> 0.8x in 10 min, centre floors, eve pnl (chips)", pnl / 1e18);
        assertLt(pnl, int256(hook.getConfig(roundId).capital / 40), "under 2.5% of capital");
    }

    /// @dev Eve's result on the same trades and the same wait with no sigma change, from a snapshot.
    function _honestPnl(uint256 wait) internal returns (int256 pnl) {
        uint256 snap = vm.snapshotState();
        uint64 c0 = clock;
        pnl = _roundTrip(0, wait);
        vm.revertToState(snap);
        clock = c0;
    }

    /// @dev Once the rises of a round reach 1.5x in total, the sigma can only fall: a keeper cannot cycle
    ///      it up and down through the day.
    function test_riseBudgetStopsCycling() public {
        uint256 s = hook.getConfig(roundId).sigma;
        uint64 t0 = clock;
        for (uint256 k; k < 5; ++k) {
            _warp(t0 + uint64(k * 300));
            _post(s * 2);
        }
        assertEq(hook.sigmaEffOf(roundId), s * 3 / 2);
        // down to the round's sigma
        for (uint256 k; k < 4; ++k) {
            _warp(clock + 300);
            _post(s);
        }
        assertEq(hook.sigmaEffOf(roundId), s, "down to 1x");
        // and up again: the budget is spent
        _warp(clock + 300);
        _post(s * 2);
        assertApproxEqRel(hook.sigmaEffOf(roundId), s, 1e9, "no rise left");
        (,, uint96 rise) = book.sigmaEffState(roundId);
        assertLe(rise, 1.5e18);
        assertGe(rise, 1.5e18 - 1e9);
    }
}
