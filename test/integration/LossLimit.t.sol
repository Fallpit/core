// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AttackBase} from "./AttackBase.sol";
import {PitAttacker} from "../hook/mocks/PitAttacker.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";

/// @notice The per-round loss limit on the real system (SPEC 7.5). After a buy the round must still hold,
///         in the worst of its 40 bands, `capital * (10000 - lossLimitBps) / 10000` above the winners'
///         payout and the protocol's fees; a buy that would leave less is refused and refunded
///         (`LossLimit`). A sell only has to keep the round solvent, so holders can always exit.
/// @dev "Cushion" below is `held - protocolFees - maxPayout`, what `lens.lossLimit` returns; the floor is
///      the smallest cushion a buy may leave. (The loss limit's "floor" is a number of chips; the menu's
///      floors are products. The tests say "the limit's floor" where both are near.)
///      The pair is the at-the-money pair. A product as narrow as HIGHER on bands 24 to 39 is a floor,
///      and one-sided buying of a floor ends at its product cap, long before the loss limit. The floor
///      tests measure the floor from +1 to +2 sigma, and where a test needs the loss limit to bind on a
///      floor it opens the round with the product cap at its ceiling.
contract LossLimitTest is AttackBase {
    uint256 internal constant LOT = 20_000e18; // the default per-fill cap: 2% of the capital

    /// @dev The two-argument form sets a product cap of a tenth of the capital per floor: the known-limit
    ///      measurements below are made with it.
    function _openWith(uint16 lossLimitBps, uint16 maxFillBps) internal {
        _openWith(lossLimitBps, maxFillBps, 1000);
    }

    function _openWith(uint16 lossLimitBps, uint16 maxFillBps, uint16 floorCapBps) internal {
        IPitBook.Params memory p = book.defaultParams();
        p.lossLimitBps = lossLimitBps;
        p.maxFillBps = maxFillBps;
        p.floorCapBps = floorCapBps;
        _setParams(p);
        _open();
    }

    function _cushion() internal view returns (uint256 cushion) {
        (cushion,) = lens.lossLimit(roundId);
    }

    /// @dev Why the last buy of `_oneSided` was refused (`None` when none was).
    RefundReason internal stoppedBy;

    /// @dev Buys `LOT` of product `index` at one oracle price, again and again, until a buy is refused or
    ///      `maxFills` went through. Returns the fills, the chips paid, the lowest cushion seen and the
    ///      shares bought when it was seen; `stoppedBy` has the reason of the refusal.
    function _oneSided(PitAttacker gang, uint8 index, uint256 price, uint256 maxFills)
        internal
        returns (uint256 fills, uint256 paid, uint256 lowest, uint256 sharesAtLowest)
    {
        stoppedBy = RefundReason.None;
        uint256 start = chip.balanceOf(address(gang));
        (, uint256 floor) = lens.lossLimit(roundId);
        lowest = _cushion();
        for (; fills < maxFills; ++fills) {
            (,,,,, RefundReason rejection) = lens.quote(roundId, index, true, LOT, price, clock + 2);
            bool filled = _tryTrade(gang, index, true, LOT, price);
            assertEq(filled, rejection == RefundReason.None, "the lens foresaw it");
            if (!filled) {
                stoppedBy = rejection;
                break;
            }
            uint256 cushion = _cushion();
            assertGe(cushion, floor, "a buy that fills leaves the cushion at or above the floor");
            if (cushion < lowest) (lowest, sharesAtLowest) = (cushion, (fills + 1) * LOT);
        }
        paid = start - chip.balanceOf(address(gang));
    }

    // --------------------------------------------------------------------------------------------
    // measured: one-sided buying at the default parameters (alpha 0.2, loss limit 30%, no product cap)
    // --------------------------------------------------------------------------------------------

    /// @dev One-sided buying of HIGHER at the money, at the cap, with the oracle at the previous close,
    ///      one minute into the regular session. 3,000,000 tokens (three times the house's capital) go
    ///      through and the limit never binds: the cushion bottoms out near 96% of the capital after
    ///      about 300,000 tokens and rises from there, because every further token costs about one chip
    ///      plus fees. (At alpha 0.3 it bottomed out at 94.1% after about 380,000 tokens: the shallower
    ///      book of alpha 0.2 takes the token to one chip sooner.)
    function test_lossLimit_default_oneSidedBuyingAtTheMoney_neverBinds() public {
        _open();
        assertEq(hook.getConfig(roundId).params.lossLimitBps, 3000);
        assertEq(hook.getConfig(roundId).params.alpha, 0.2e18);
        PitAttacker gang = _attacker(address(chip), 10_000_000e18);
        (uint256 fills, uint256 paid, uint256 lowest, uint256 at) = _oneSided(gang, HIGHER, S0, 150);
        _report("at the money (HIGHER at the previous close)", fills, paid, lowest, at);
        assertEq(fills, 150, "no buy was refused");
        assertGt(lowest, HOUSE_CAPITAL * 95 / 100, "at most 5% of the capital was ever at risk");
        assertLt(lowest, HOUSE_CAPITAL * 97 / 100);
    }

    /// @dev One-sided buying of a floor: the one from +1 to +2 sigma, a token that starts near 0.11. With
    ///      no product cap it behaves like the pair: the token goes to one chip and the cushion bottoms
    ///      out near 88% of the capital after 340,000 tokens (a floor starts cheaper than the pair, so
    ///      more of it is bought before a token costs a chip). What stops the buying is the cap's
    ///      ceiling, the whole capital in tokens (50 lots), with `ProductCap`; the loss limit never
    ///      binds.
    function test_lossLimit_default_oneSidedBuyingOfAFloor_neverBinds_stopsAtTheWholeCapital() public {
        _open();
        PitAttacker gang = _attacker(address(chip), 10_000_000e18);
        (uint256 fills, uint256 paid, uint256 lowest, uint256 at) = _oneSided(gang, F6, S0, 150);
        _report("floor from +1 to +2 sigma", fills, paid, lowest, at);
        assertEq(fills, 50, "the 51st lot would take the floor over the whole capital");
        assertEq(uint8(stoppedBy), uint8(RefundReason.ProductCap));
        assertGt(lowest, HOUSE_CAPITAL * 87 / 100, "at most 13% of the capital was ever at risk");
        assertLt(lowest, HOUSE_CAPITAL * 90 / 100);
    }

    /// @dev The most one-sided buying can put at risk at one oracle price on the default menu: every
    ///      product that pays in one band, the floor to the whole capital and then the half of the pair
    ///      over it. Measured for the band just above the previous close (F4 and HIGHER) and for the far
    ///      one (F7 and HIGHER). The engine bounds a band's exposure at about alpha times the capital
    ///      less what the buyers paid: the floor alone bottoms out at 91% (F4) and 84% (F7), and HIGHER
    ///      over it does not take the cushion much further.
    function test_lossLimit_default_oneSidedBuyingOfAFloorAndThePairOverIt() public {
        _open();
        PitAttacker gang = _attacker(address(chip), 10_000_000e18);
        uint256 snapshot = vm.snapshotState();
        uint8[2] memory floors = [F4, F7];
        for (uint256 k; k < 2; ++k) {
            (uint256 fills, uint256 paid, uint256 lowest, uint256 at) = _oneSided(gang, floors[k], S0, 150);
            assertEq(fills, 50);
            assertEq(uint8(stoppedBy), uint8(RefundReason.ProductCap));
            _report(
                k == 0
                    ? "floor from 0 to +0.5 sigma, to the whole capital"
                    : "floor above +2 sigma, to the whole capital",
                fills,
                paid,
                lowest,
                at
            );
            // 30 lots of HIGHER (60 would take the test over the gas limit of a run); the cushion
            // bottoms out well inside them
            (fills, paid, lowest, at) = _oneSided(gang, HIGHER, S0, 30);
            _report("then HIGHER over it", fills, paid, lowest, at);
            assertEq(fills, 30, "no buy of HIGHER was refused");
            assertGt(
                lowest, HOUSE_CAPITAL * 80 / 100, "the two together put under a fifth of the capital at risk"
            );
            vm.revertToState(snapshot);
        }
    }

    /// @dev The same two measurements in the after-hours, two minutes after the previous close, with
    ///      nearly the whole variance of the round still ahead (rho 0.9995 against 0.698 at 09:31). The
    ///      cushion bottoms out near 95% of the capital at the money and near 88% on the floor, about
    ///      what the regular session shows, and a floor runs to the whole capital as it does there.
    ///      This measures the engine at one oracle price; it says nothing about how after-hours prices
    ///      behave.
    function test_lossLimit_default_oneSidedBuyingAtTheMoney_afterHours_neverBinds() public {
        _openAfterHours();
        PitAttacker gang = _attacker(address(chip), 10_000_000e18);
        (uint256 fills, uint256 paid, uint256 lowest, uint256 at) = _oneSided(gang, HIGHER, S0, 150);
        _report("after-hours, at the money (HIGHER at the previous close)", fills, paid, lowest, at);
        assertEq(fills, 150, "no buy was refused");
        assertGt(lowest, HOUSE_CAPITAL * 94 / 100, "at most 6% of the capital was ever at risk");
        assertLt(lowest, HOUSE_CAPITAL * 97 / 100);
    }

    function test_lossLimit_default_oneSidedBuyingOfAFloor_afterHours_neverBinds() public {
        _openAfterHours();
        PitAttacker gang = _attacker(address(chip), 10_000_000e18);
        (uint256 fills, uint256 paid, uint256 lowest, uint256 at) = _oneSided(gang, F6, S0, 150);
        _report("after-hours, floor from +1 to +2 sigma", fills, paid, lowest, at);
        assertEq(fills, 50);
        assertEq(uint8(stoppedBy), uint8(RefundReason.ProductCap));
        assertGt(lowest, HOUSE_CAPITAL * 86 / 100, "at most 14% of the capital was ever at risk");
        assertLt(lowest, HOUSE_CAPITAL * 90 / 100);
    }

    /// @dev A product cap of a tenth of the capital per floor, set explicitly: a
    ///      floor stops at five lots with `ProductCap`, the house has at most that tenth at risk on it
    ///      less what the buyers paid. The mechanism is kept for an owner who wants a cap.
    function test_lossLimit_productCap_oneSidedBuyingOfAFloor_stopsAtTheProductCap() public {
        _openWith(3000, 200, 1000);
        PitAttacker gang = _attacker(address(chip), 10_000_000e18);
        (uint256 fills, uint256 paid, uint256 lowest, uint256 at) = _oneSided(gang, F6, S0, 150);
        _report("floor from +1 to +2 sigma, product cap 10%", fills, paid, lowest, at);
        assertEq(fills, 5, "the sixth lot would take the floor over a tenth of the capital");
        assertEq(uint8(stoppedBy), uint8(RefundReason.ProductCap));
        assertEq(lowest, HOUSE_CAPITAL - 5 * LOT + paid - _state().protocolFees);
        assertGt(lowest, HOUSE_CAPITAL * 91 / 100, "at most 9% of the capital was ever at risk");
        assertLt(lowest, HOUSE_CAPITAL * 94 / 100);
    }

    function _report(string memory what, uint256 fills, uint256 paid, uint256 lowest, uint256 at) internal {
        emit log_string(what);
        emit log_named_uint("  fills of 20,000 tokens that went through", fills);
        emit log_named_decimal_uint(
            "  tokens bought, share of the capital", fills * LOT * 1e18 / HOUSE_CAPITAL, 18
        );
        emit log_named_decimal_uint("  chips paid, share of the capital", paid * 1e18 / HOUSE_CAPITAL, 18);
        emit log_named_decimal_uint(
            "  lowest cushion, share of the capital", lowest * 1e18 / HOUSE_CAPITAL, 18
        );
        emit log_named_decimal_uint("  tokens bought when the cushion was lowest", at, 18);
    }

    // --------------------------------------------------------------------------------------------
    // the limit binds under one-sided buying (at the tightest limit the owner may set)
    // --------------------------------------------------------------------------------------------

    /// @dev With `lossLimitBps = 1000` (the house may put a tenth of its capital at risk) and the product
    ///      cap out of the way (at its ceiling, the whole capital), one-sided buying of the floor from +1
    ///      to +2 sigma is stopped by the loss limit after 160,000 tokens (120,000 at alpha 0.3: the
    ///      shallower book of alpha 0.2 charges more per lot, so more lots fit under the limit). From
    ///      there: the same buy stays refused, a sell fills, and a buy of a product that pays in other
    ///      bands fills, because it does not deepen the worst case. (With a product cap of a tenth the
    ///      loss limit of a tenth cannot bind on one floor: the cap comes first.)
    function test_lossLimit_tenPercent_bindsUnderOneSidedBuying_sellsStillFill() public {
        _openWith(1000, 200, 10_000);
        (, uint256 floor) = lens.lossLimit(roundId);
        assertEq(floor, HOUSE_CAPITAL * 9 / 10);
        PitAttacker gang = _attacker(address(chip), 10_000_000e18);
        (uint256 fills, uint256 paid, uint256 lowest, uint256 at) = _oneSided(gang, F6, S0, 150);
        _report("floor from +1 to +2 sigma, loss limit 10%, no product cap", fills, paid, lowest, at);
        assertEq(uint8(stoppedBy), uint8(RefundReason.LossLimit), "refused for the loss limit");
        assertEq(fills, 8, "the ninth lot would leave less than 90% of the capital");
        assertGe(lowest, floor);
        assertEq(chip.balanceOf(address(router)), 0, "the refused buy was refunded in full");
        assertEq(_token(F6).totalSupply(), 8 * LOT);

        // the refusal is the hook's `FillRejected(LossLimit)`, turned into a refund by the router
        uint256 id = _commit(gang, F6, true, LOT);
        bytes memory report = _printFor(id, S0);
        vm.expectEmit(true, true, false, true, address(router));
        emit Refunded(id, address(gang), RefundReason.LossLimit);
        assertFalse(gang.fill(id, report));

        // blocked for everybody, not only for the gang
        uint256 aliceId = _commitBuy(alice, F6, LOT, STAKE);
        assertFalse(_fill(aliceId, S0), "the limit is the round's, whoever buys");
        assertEq(chip.balanceOf(alice), STAKE);
        // the half of the pair that pays in the same bands is judged by the same cushion: a lot of it
        // fills only if what it adds to the worst band, less what it pays in, still leaves 90%
        {
            (uint256 chips, uint256 fee,,,, RefundReason rejection) =
                lens.quote(roundId, HIGHER, true, LOT, S0, clock + 2);
            uint256 left = _cushion() + chips - fee / 10 - LOT;
            assertEq(rejection == RefundReason.LossLimit, left < floor, "HIGHER deepens the same worst band");
        }

        // a sell fills while buys are blocked, and brings the cushion back up
        uint256 before = _cushion();
        _trade(gang, F6, false, LOT, S0);
        assertGt(_cushion(), before, "selling the token back takes risk off the house");
        // products that pay in other bands (LOWER, the floor next door) do not deepen the worst case
        _trade(gang, LOWER, true, LOT, S0);
        _trade(gang, F5, true, LOT, S0);
        // and the buy fits again once the sell made room for it
        assertTrue(_tryTrade(gang, F6, true, LOT, S0));
        assertGe(_cushion(), floor);
    }

    /// @dev At the money even the tightest limit (10%) is out of reach of one-sided buying: the cushion
    ///      never falls under 93% of the capital.
    function test_lossLimit_tenPercent_oneSidedBuyingAtTheMoney_stillNeverBinds() public {
        _openWith(1000, 200);
        PitAttacker gang = _attacker(address(chip), 10_000_000e18);
        (uint256 fills,, uint256 lowest,) = _oneSided(gang, HIGHER, S0, 60);
        assertEq(fills, 60);
        assertGt(lowest, HOUSE_CAPITAL * 92 / 100);
    }

    // --------------------------------------------------------------------------------------------
    // ordinary two-sided flow is not blocked
    // --------------------------------------------------------------------------------------------

    /// @dev A busy ordinary day at the default parameters: three users buy and sell every product of the
    ///      menu while the oracle drifts inside one standard deviation. Nothing is
    ///      refused and the cushion stays above 95% of the capital, far from the limit's floor of 70%.
    function test_lossLimit_default_balancedFlow_isNotBlocked() public {
        _open();
        _fund(carol, STAKE);
        address[3] memory users = [alice, bob, carol];
        uint256 lowest = _cushion();
        for (uint256 i; i < 48; ++i) {
            address user = users[i % 3];
            uint8 index = uint8((i * 7 + i / 10) % PRODUCTS);
            // a sawtooth between 1.6% down and 1.5% up
            uint256 price = S0 * (984 + (i * 7) % 32) / 1000;
            uint256 held = _token(index).balanceOf(user);
            if (i % 4 == 3 && held >= 1_000e18) {
                _sell(user, index, held / 2, price);
            } else {
                uint256 shares = 2_000e18 + (i % 5) * 1_500e18;
                (,,,,, RefundReason rejection) = lens.quote(roundId, index, true, shares, price, clock + 2);
                assertEq(uint8(rejection), uint8(RefundReason.None));
                _buy(user, index, shares, price);
            }
            uint256 cushion = _cushion();
            if (cushion < lowest) lowest = cushion;
            _warp(clock + 240);
        }
        emit log_named_decimal_uint(
            "lowest cushion of the day, share of the capital", lowest * 1e18 / HOUSE_CAPITAL, 18
        );
        assertGt(lowest, HOUSE_CAPITAL * 95 / 100);
        _assertSupplies();
        _assertHookSolvent(address(chip));
    }

    // --------------------------------------------------------------------------------------------
    // what the limit does not cover (stated, not prevented)
    // --------------------------------------------------------------------------------------------

    /// @dev The limit is checked on buys only. A sell takes chips out of the round, and in the outcomes
    ///      where the sold token would have lost anyway that lowers the cushion. So a gang that holds a
    ///      cheap position on one side and rides oracle swings on the other can sell the cushion to
    ///      below the limit's floor: the stock swings between 8% down and 6% up, the gang parks the
    ///      bottom floor (below -2 sigma) bought at the minimum price at a high, then buys the top floor
    ///      (above +2 sigma) at every low and sells it at every high. No buy ever left the cushion under
    ///      the limit's floor, buys stop for good once it is there, and the round stays solvent; but if
    ///      the day ends at the low the house has lost more than the limit. The absolute bound is the
    ///      solvency check: never more than it brought.
    ///      On floors the product cap sets the pace: a tenth of the capital parked, a tenth ridden per
    ///      swing. The next test is the same play on the pair, which has no product cap.
    function test_lossLimit_knownLimit_sellsOnAnotherTokenCanTakeTheCushionBelowTheFloor() public {
        _openWith(5000, 1000);
        uint256 cap = hook.getConfig(roundId).maxFill;
        (, uint256 floor) = lens.lossLimit(roundId);
        PitAttacker gang = _attacker(address(chip), 3_000_000e18);
        uint256 start = chip.balanceOf(address(gang));
        uint256 low = S0 * 92 / 100;
        uint256 high = S0 * 106 / 100;

        // at a high: the bottom floor, while a capped lot costs under a tenth of a chip a token
        for (uint256 k; k < 6; ++k) {
            (uint256 quoted,,,,,) = lens.quote(roundId, F0, true, cap, high, clock + 2);
            if (quoted > cap / 10 || !_tryTrade(gang, F0, true, cap, high)) break;
            assertGe(_cushion(), floor);
        }
        uint256 parked = _token(F0).totalSupply();
        assertEq(parked, HOUSE_CAPITAL / 10, "the product cap: a tenth of the capital, in one lot");
        assertGt(parked, 0, "scenario: a cheap position on the low side");

        uint256 refusedBuys;
        uint256 swings;
        for (uint256 cycles; cycles < 12; ++cycles) {
            (,,,,, RefundReason verdict) = lens.quote(roundId, F7, true, cap, low, clock + 2);
            if (!_tryTrade(gang, F7, true, cap, low)) {
                assertEq(uint8(verdict), uint8(RefundReason.LossLimit));
                ++refusedBuys;
                break;
            }
            ++swings;
            assertGe(_cushion(), floor, "no buy ever leaves the cushion under the floor");
            assertTrue(_tryTrade(gang, F7, false, cap, high), "holders can always exit");
            (uint256 worst, uint256 covered) = lens.solvency(roundId);
            assertLe(worst, covered, "solvent throughout");
        }
        uint256 cushion = _cushion();
        emit log_named_decimal_uint("tokens parked on the low side", parked, 18);
        emit log_named_uint("swings ridden before a buy was refused", swings);
        emit log_named_uint("buys refused by the loss limit", refusedBuys);
        emit log_named_decimal_uint(
            "cushion at the end of the swings, share of the capital", cushion * 1e18 / HOUSE_CAPITAL, 18
        );
        assertGt(refusedBuys, 0, "the limit did stop the buying");
        assertLt(cushion, floor, "and the sells still took the cushion under the floor");
        // buying is over wherever a buy would not lift the cushion back over the limit's floor
        assertFalse(_tryTrade(gang, F7, true, cap, low));
        (,,,,, RefundReason rejection) = lens.quote(roundId, F1, true, cap, high, clock + 2);
        assertEq(uint8(rejection), uint8(RefundReason.LossLimit));

        // the day ends at the low: the parked tokens win
        _closeAndFinalize(low);
        assertEq(gang.redeem(_token(F0).id, parked), parked);
        uint256 back = chip.balanceOf(address(vault));
        uint256 fees = hook.collectProtocolFees(address(chip));
        assertEq(chip.balanceOf(address(gang)) - start + fees, HOUSE_CAPITAL - back);
        emit log_named_decimal_uint("left of the house's 1,000,000", back, 18);
        assertLt(back, floor, "the house lost more than the limit");
        assertGt(back, 0, "and less than it brought");
    }

    /// @dev The same play on the pair, which has no product cap: LOWER parked at a high, HIGHER bought at
    ///      every low and sold at every high. What limits the parked position is the engine, not a cap:
    ///      a cheap token stops being cheap as it is bought (after about alpha times the capital in
    ///      tokens), so the gang parks while a lot still costs under a tenth of a chip a token. The
    ///      loss limit then lets it ride the swings until a buy would leave the house less than half,
    ///      and the sells of the last swing take the cushion under the limit's floor.
    function test_lossLimit_knownLimit_onThePair_sellsTakeTheCushionBelowTheFloor() public {
        _openWith(5000, 1000);
        uint256 cap = hook.getConfig(roundId).maxFill;
        (, uint256 floor) = lens.lossLimit(roundId);
        PitAttacker gang = _attacker(address(chip), 3_000_000e18);
        uint256 start = chip.balanceOf(address(gang));
        uint256 low = S0 * 92 / 100;
        uint256 high = S0 * 106 / 100;

        // at a high: LOWER, while a capped lot costs under a tenth of a chip a token
        for (uint256 k; k < 6; ++k) {
            (uint256 quoted,,,,,) = lens.quote(roundId, LOWER, true, cap, high, clock + 2);
            if (quoted > cap / 10 || !_tryTrade(gang, LOWER, true, cap, high)) break;
            assertGe(_cushion(), floor);
        }
        uint256 parked = _token(LOWER).totalSupply();
        assertGt(parked, 0, "scenario: a cheap position on the low side");

        uint256 refusedBuys;
        for (uint256 cycles; cycles < 8; ++cycles) {
            for (uint256 k; k < 6; ++k) {
                (uint256 quoted,,,,,) = lens.quote(roundId, HIGHER, true, cap, low, clock + 2);
                if (quoted > cap / 2) break;
                if (!_tryTrade(gang, HIGHER, true, cap, low)) {
                    ++refusedBuys;
                    break;
                }
                assertGe(_cushion(), floor, "no buy ever leaves the cushion under the floor");
            }
            for (uint256 balance = _token(HIGHER).balanceOf(address(gang)); balance != 0;) {
                uint256 lot = balance > cap ? cap : balance;
                assertTrue(_tryTrade(gang, HIGHER, false, lot, high), "holders can always exit");
                balance -= lot;
            }
            (uint256 worst, uint256 covered) = lens.solvency(roundId);
            assertLe(worst, covered, "solvent throughout");
        }
        uint256 cushion = _cushion();
        emit log_named_decimal_uint("LOWER parked at the high", parked, 18);
        emit log_named_uint("buys refused by the loss limit", refusedBuys);
        emit log_named_decimal_uint(
            "cushion at the end of the swings, share of the capital", cushion * 1e18 / HOUSE_CAPITAL, 18
        );
        assertGt(refusedBuys, 0, "the limit did stop the buying");
        assertLt(cushion, floor, "and the sells still took the cushion under the floor");

        // the day ends at the low: the parked tokens win
        _closeAndFinalize(low);
        assertEq(gang.redeem(_token(LOWER).id, parked), parked);
        uint256 back = chip.balanceOf(address(vault));
        uint256 fees = hook.collectProtocolFees(address(chip));
        assertEq(chip.balanceOf(address(gang)) - start + fees, HOUSE_CAPITAL - back);
        emit log_named_decimal_uint("left of the house's 1,000,000", back, 18);
        assertLt(back, floor, "the house lost more than the limit");
        assertGt(back, 0, "and less than it brought");
    }
}
