// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {StackFixture} from "./StackFixture.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice On a void the house gets its round capital back first. Holders then share what the round holds
///         above it, pro rata to cost basis and never more than their cost basis, so no position in a void
///         round is a free option written by the house. Refunds are per token, not per buyer (SPEC 7.3).
contract VoidRefundsTest is StackFixture {
    address internal lp = makeAddr("lp");
    address internal eve = makeAddr("eve");
    address internal alice = makeAddr("alice");

    uint256 internal constant CAPITAL = 1_000_000e18;

    /// @dev The stock moves by `k` daily standard deviations, eve sells the side that gained, nobody can
    ///      record a close, the round is voided and eve redeems the side that lost.
    function _moveSellVoidRedeem(int256 k) internal returns (int256 eveNet, uint256 houseAfter) {
        _warp(clock + 3 hours);
        uint8 gained = k >= 0 ? HIGHER : LOWER;
        if (k != 0) {
            uint256 px = _priceAtSigmas(k);
            for (uint256 i; i < 10; ++i) {
                _sell(eve, gained, 20_000e18, px);
            }
        }
        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        for (uint8 idx = LOWER; idx <= HIGHER; ++idx) {
            uint256 token = _token(idx).id;
            uint256 left = _token(idx).balanceOf(eve);
            if (left == 0) continue;
            vm.prank(eve);
            router.redeem(token, left);
        }
        eveNet = int256(chip.balanceOf(eve)) - int256(CAPITAL);
        houseAfter = vault.getHouse(house).lpAssets;
    }

    function test_void_noPositionIsAFreeOption_theHouseIsWholeFirst() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, CAPITAL);
        _open(60);
        // Eve buys both sides of the pair: 200,000 HIGHER and 200,000 LOWER.
        uint256 paid;
        for (uint256 i; i < 10; ++i) {
            paid += _buy(eve, HIGHER, 20_000e18, S0);
            paid += _buy(eve, LOWER, 20_000e18, S0);
        }
        console.log("eve paid %s chips for 200,000 HIGHER + 200,000 LOWER", paid / 1e18);
        uint256 snap = vm.snapshotState();

        (int256 up, uint256 houseUp) = _moveSellVoidRedeem(1e18);
        console.log("stock +1 sd, void: eve %s, house capital %s", vm.toString(up / 1e18), houseUp / 1e18);
        vm.revertToState(snap);
        (int256 down, uint256 houseDown) = _moveSellVoidRedeem(-1e18);
        console.log("stock -1 sd, void: eve %s, house capital %s", vm.toString(down / 1e18), houseDown / 1e18);
        vm.revertToState(snap);
        (int256 flat, uint256 houseFlat) = _moveSellVoidRedeem(0);
        console.log("stock flat,  void: eve %s, house capital %s", vm.toString(flat / 1e18), houseFlat / 1e18);

        // Whichever way the stock moves, the sale plus the refund return at most what eve paid: the
        // refund of the side she kept is what she still had in the round, not its cost. The house gets
        // its capital back to the unit, and what eve loses the house keeps: the two are zero-sum (the
        // protocol's fees of a void round are cancelled). At alpha 0.2 the sale of 200,000 HIGHER one
        // sigma up returns 9,324 less than the tokens cost: eve's trading loss, not a free option.
        assertLe(up, 0);
        assertLe(down, 0);
        assertLe(flat, 0);
        assertGe(down, -6);
        assertGe(flat, -6);
        assertGe(up, -10_000e18, "a trading loss on the sale, bounded");
        assertGe(houseUp, CAPITAL);
        assertGe(houseDown, CAPITAL);
        assertGe(houseFlat, CAPITAL);
        assertLe(houseDown, CAPITAL + 6);
        assertLe(houseFlat, CAPITAL + 6);
        assertEq(up + int256(houseUp), int256(CAPITAL), "zero-sum: what eve lost the house kept");
        assertLe(houseUp, CAPITAL + 10_000e18);
    }

    /// @dev Tokens are fungible, so a void pays every holder of a token the same average cost. A
    ///      late buyer of a token that has fallen takes part of the refund of those who bought it dear.
    function test_void_lateCheapBuyerTakesEarlyBuyersRefund() public {
        _lpDeposit(lp, CAPITAL);
        _fund(alice, CAPITAL);
        _fund(eve, CAPITAL);
        _open(60);

        // Alice buys HIGHER while the stock is up one standard deviation (about 0.85 per token).
        uint256 alicePaid = _buy(alice, HIGHER, 20_000e18, _priceAtSigmas(1e18));
        // The stock falls to minus two; eve buys the same token for a few cents.
        _warp(clock + 5 hours);
        uint256 evePaid = _buy(eve, HIGHER, 20_000e18, _priceAtSigmas(-2e18));

        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        uint256 token = _token(HIGHER).id;
        vm.prank(alice);
        uint256 aliceRefund = router.redeem(token, 20_000e18);
        vm.prank(eve);
        uint256 eveRefund = router.redeem(token, 20_000e18);

        console.log("alice paid %s, refunded %s", alicePaid / 1e18, aliceRefund / 1e18);
        console.log("eve   paid %s, refunded %s", evePaid / 1e18, eveRefund / 1e18);
        assertGt(eveRefund, 10 * evePaid, "eve is refunded many times what she paid");
        assertLt(aliceRefund, alicePaid * 55 / 100, "alice gets back about half of what she paid");
        assertApproxEqAbs(aliceRefund + eveRefund, alicePaid + evePaid, 2, "the house is not involved");
    }
}
