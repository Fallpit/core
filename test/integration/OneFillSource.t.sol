// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {StackFixture} from "./StackFixture.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";

/// @notice A ticker takes prints from one source only (`TrustlessOnly` or `KeeperOnly`, frozen per round), so
///         one print prices both legs of a complete set. A fill with the other source's print reverts, and a
///         complete set costs more than it pays however far apart the two sources are.
contract OneFillSourceTest is StackFixture {
    address internal lp = makeAddr("lp");
    address internal eve = makeAddr("eve");

    uint256 internal constant CAPITAL = 1_000_000e18;
    uint256 internal constant LOT = 20_000e18; // the per-fill cap, 2% of the capital

    /// @dev One HIGHER and one LOWER commit in the same block. Eve tries to fill HIGHER with the lower
    ///      (trustless) print; the round takes keeper prints only, so that
    ///      fill reverts and both legs end up priced by the one keeper print. The two sources differ by
    ///      `bps` basis points at that instant.
    function _completeSet(uint256 bps) internal returns (uint256 cost) {
        uint256 before = chip.balanceOf(eve);
        vm.startPrank(eve);
        uint256 higher = router.commit{value: FILL_FEE}(roundId, HIGHER, true, LOT, LOT);
        uint256 lower = router.commit{value: FILL_FEE}(roundId, LOWER, true, LOT, LOT);
        vm.stopPrank();
        uint64 t = router.getCommit(higher).fillTs;
        _warp(t);
        oracle.set(NVDA, TRUSTLESS, t, S0);
        oracle.set(NVDA, KEEPER, t, S0 * (10_000 + bps) / 10_000);
        vm.startPrank(eve);
        // the attack's first leg: HIGHER on the lower print of the other source
        try router.fill(higher, abi.encode(TRUSTLESS)) returns (bool) {
            revert("the other source's print filled");
        } catch {}
        require(
            router.getCommit(higher).status == IFallpitRouter.CommitStatus.Pending,
            "a refused print leaves the commit pending"
        );
        require(router.fill(higher, abi.encode(KEEPER)), "HIGHER on the round's own print");
        require(router.fill(lower, abi.encode(KEEPER)), "LOWER on the same print");
        vm.stopPrank();
        cost = before - chip.balanceOf(eve);
    }

    function test_oneSource_completeSetsCostMoreThanTheyPay() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, CAPITAL);
        roundId = hook.openRound(NVDA, address(chip), day);
        assertEq(uint8(hook.getConfig(roundId).fillSource), uint8(IPitBook.FillSource.KeeperOnly));
        assertEq(uint8(type(IPitBook.FillSource).max), 1, "TrustlessOnly and KeeperOnly: there is no Any");
        // twenty minutes before the close, the stock at the previous close
        _warp(NYTime.closeTs(day) - 1200);

        uint256 snap = vm.snapshotState();
        uint256 same = _completeSet(0);
        vm.revertToState(snap);
        uint256 five = _completeSet(5);
        vm.revertToState(snap);
        uint256 ten = _completeSet(10);
        vm.revertToState(snap);
        console.log(
            "20,000 complete sets cost: %s (sources agree), %s (5 bps apart), %s (10 bps apart)",
            same / 1e18,
            five / 1e18,
            ten / 1e18
        );
        assertGt(same, LOT, "a complete set costs more than it pays (fees)");
        assertGt(five, LOT, "also when the sources are 5 bps apart");
        assertGt(ten, LOT, "also when the sources are 10 bps apart");

        // Twenty seconds of it.
        uint256 start = chip.balanceOf(eve);
        for (uint256 i; i < 20; ++i) {
            _completeSet(10);
            _warp(clock + 1);
        }
        // Whatever the close, exactly one of the two tokens wins.
        _closeAndFinalize(S0 * 1003 / 1000);
        uint256 token = _token(HIGHER).id;
        vm.prank(eve);
        router.redeem(token, 20 * LOT);
        uint256 loss = start - chip.balanceOf(eve);
        uint256 houseAfter = vault.getHouse(house).lpAssets;
        console.log(
            "eve's loss on the attempt: %s chips; house capital %s -> %s",
            loss / 1e18,
            CAPITAL / 1e18,
            houseAfter / 1e18
        );
        assertGt(loss, 0, "the attempt costs eve the fees of 20 complete sets");
        assertGt(houseAfter, CAPITAL, "and the house is better off");
    }
}
