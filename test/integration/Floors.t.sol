// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {PitVault} from "../../src/PitVault.sol";
import {FallpitLens} from "../../src/hook/FallpitLens.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {PitMath} from "../../src/hook/PitMath.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {Menus} from "../Menus.sol";

/// @notice The floor menu on the real system (real LadderMath, PitOracle, vault, router and hook): one floor
///         wins and the books close when the floors partition the ladder; a floor and the half of the pair
///         over the same band are both paid; the product cap and the minimum price, refunds included; a
///         menu that does not partition; other menus; and the property the whole model rests on: a set of
///         products that covers every band exactly once can never be bought for less than it must pay.
contract FloorsTest is IntegrationFixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant STAKE = 400_000e18;

    event Refunded(uint256 indexed commitId, address indexed user, RefundReason reason);

    function setUp() public override {
        super.setUp();
        _fund(alice, STAKE);
        _fund(bob, STAKE);
        _fund(carol, STAKE);
    }

    /// @dev S0 * exp(k * sigma) on the oracle's price grid, for sigma = 2% and k in WAD.
    function _priceAtSigmas(int256 kWad) internal pure returns (uint256) {
        return _grid(S0 * uint256(FixedPointMathLib.expWad(kWad * 2 / 100)) / 1e18);
    }

    function _popcount(uint256 x) internal pure returns (uint256 n) {
        for (; x != 0; x >>= 1) {
            n += x & 1;
        }
    }

    function _sumOfUsers() internal view returns (uint256) {
        return chip.balanceOf(alice) + chip.balanceOf(bob) + chip.balanceOf(carol);
    }

    // --------------------------------------------------------------------------------------------
    // the floors partition the ladder: exactly one wins, and the books close
    // --------------------------------------------------------------------------------------------

    /// @dev Three users trade every floor and the pair while the oracle drifts. Then the same book is
    ///      settled on nine different closes, one inside every floor and one exactly on the previous
    ///      close. Each time exactly one floor wins and exactly one half of the pair, the payout is the
    ///      supply of those two, every winner gets one chip a token, every loser nothing, and every chip
    ///      is accounted for to the unit.
    function test_floors_exactlyOneFloorWins_andConservationHolds() public {
        _open();
        uint256 price = S0;
        for (uint8 i; i < PRODUCTS; ++i) {
            price = _grid(price * (1000 + i) / 1000);
            _buy(alice, i, 6_000e18 + uint256(i) * 500e18, price);
            _buy(bob, i, 3_000e18, _grid(price * 998 / 1000));
            _buy(carol, uint8((i + 3) % PRODUCTS), 2_000e18, price);
            _warp(clock + 400);
        }
        for (uint8 i; i < PRODUCTS; ++i) {
            price = _grid(price * 997 / 1000);
            _sell(alice, i, 2_000e18, price);
            _warp(clock + 300);
        }
        _assertSupplies();
        _assertHookSolvent(address(chip));
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        IFallpitHook.RoundState memory open = _state();

        // closes in sigmas from the previous close, and the floor each lands in
        int256[9] memory closes =
            [int256(-2.6e18), -1.4e18, -0.8e18, -0.2e18, 0, 0.3e18, 0.7e18, 1.5e18, 2.9e18];
        uint8[9] memory floors = [F0, F1, F2, F3, F4, F4, F5, F6, F7];
        uint256 snapshot = vm.snapshotState();
        for (uint256 n; n < closes.length; ++n) {
            uint256 close = closes[n] == 0 ? S0 : _priceAtSigmas(closes[n]);
            _recordClose(close, PYTH_SOURCE);
            hook.settleRound(house, day);
            IFallpitHook.RoundState memory settled = _state();
            uint8 half = closes[n] >= 0 ? HIGHER : LOWER;
            assertEq(_popcount(settled.winners & 0xff), 1, "exactly one floor wins");
            assertEq(_popcount(settled.winners >> 8), 1, "exactly one of the pair wins");
            assertEq(
                settled.winners, uint16(1 << floors[n] | 1 << half), "the floor of the close, and its half"
            );
            assertEq(settled.payoutOwed, supply[floors[n]] + supply[half], "one chip per winning token");
            {
                // the winning floor's own price range holds the close
                Ticket memory winner = _token(floors[n]);
                assertLe(winner.low(), close);
                assertLt(close, winner.high());
            }
            hook.finalizeRound(house, day);

            uint256 paid;
            address[3] memory users = [alice, bob, carol];
            for (uint256 u; u < 3; ++u) {
                for (uint8 i; i < PRODUCTS; ++i) {
                    Ticket memory token = _token(i);
                    uint256 balance = token.balanceOf(users[u]);
                    if (balance == 0) continue;
                    vm.prank(users[u]);
                    if (settled.winners >> i & 1 == 0) {
                        vm.expectRevert(IFallpitHook.NotWinner.selector);
                        router.redeem(token.id, balance);
                    } else {
                        assertEq(router.redeem(token.id, balance), balance);
                        paid += balance;
                    }
                }
            }
            assertEq(paid, settled.payoutOwed, "every winner was paid in full");
            uint256 fees = hook.collectProtocolFees(address(chip));
            assertEq(fees, open.protocolFees);
            uint256 back = chip.balanceOf(address(vault));
            assertEq(back, open.held - paid - fees, "the house keeps the rest");
            assertEq(_sumOfUsers() + back + fees, 3 * STAKE + HOUSE_CAPITAL, "cash conservation");
            assertEq(chip.balanceOf(address(hook)), 0, "nothing stranded");
            (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
            assertEq(claims + owed, 0);
            emit log_named_decimal_int(
                string.concat("house result when the close lands in floor ", vm.toString(floors[n])),
                int256(back) - int256(HOUSE_CAPITAL),
                18
            );
            vm.revertToState(snapshot);
        }
    }

    /// @dev Any close at all: exactly one floor and exactly one half of the pair win, and they are the
    ///      ones whose price range holds the close.
    function testFuzz_floors_anyClose_oneFloorAndOneHalfWin(int256 k) public {
        k = bound(k, -8e18, 8e18);
        roundId = hook.openRound(ticker, roundChip, day);
        uint256 close = _priceAtSigmas(k);
        _recordClose(close, PYTH_SOURCE);
        hook.settleRound(house, day);
        uint16 winners = _state().winners;
        assertEq(_popcount(winners & 0xff), 1, "exactly one floor");
        assertEq(_popcount(winners >> 8), 1, "exactly one of the pair");
        assertEq(winners >> HIGHER & 1 == 1, close >= S0, "HIGHER wins at or above the previous close");
        for (uint8 i; i < PRODUCTS; ++i) {
            Ticket memory token = _token(i);
            // the token's range is rounded to a wei: skip a close within a wei of an edge
            if (close + 1 >= token.low() && close <= token.low() + 1) return;
            if (token.high() != type(uint256).max && close + 1 >= token.high() && close <= token.high() + 1) {
                return;
            }
            assertEq(
                winners >> i & 1 == 1, token.low() <= close && close < token.high(), "range holds the close"
            );
        }
        assertEq(_state().payoutOwed, 0, "nothing was sold, nothing is owed");
    }

    // --------------------------------------------------------------------------------------------
    // overlapping products: a floor and the half of the pair over the same band are both paid
    // --------------------------------------------------------------------------------------------

    function test_floors_floorAndPairOnTheSameBand_bothPaid() public {
        _open();
        uint256 aliceCost = _buy(alice, F5, 10_000e18, S0); // +0.5 to +1 sigma
        uint256 bobCost = _buy(bob, HIGHER, 15_000e18, S0);
        uint256 carolCost = _buy(carol, LOWER, 8_000e18, S0) + _buy(carol, F2, 4_000e18, S0);
        // the worst band is where the floor and HIGHER overlap: both are owed there
        (uint256 worst,) = lens.solvency(roundId);
        assertEq(worst, 25_000e18);
        assertEq(lens.payouts(roundId)[22], 25_000e18);
        assertEq(lens.payouts(roundId)[25], 15_000e18);
        assertEq(lens.payouts(roundId)[16], 12_000e18);
        IFallpitHook.RoundState memory open = _state();

        _closeAndFinalize(_priceAtSigmas(0.75e18)); // inside F5, and above the previous close
        IFallpitHook.RoundState memory fin = _state();
        assertEq(fin.winners, uint16(1 << F5 | 1 << HIGHER));
        assertEq(fin.payoutOwed, 25_000e18, "the floor's holders and HIGHER's holders, each in full");
        uint256 floor = _token(F5).id;
        uint256 higher = _token(HIGHER).id;
        vm.prank(alice);
        assertEq(router.redeem(floor, 10_000e18), 10_000e18);
        vm.prank(bob);
        assertEq(router.redeem(higher, 15_000e18), 15_000e18);
        uint256 lower = _token(LOWER).id;
        vm.prank(carol);
        vm.expectRevert(IFallpitHook.NotWinner.selector);
        router.redeem(lower, 8_000e18);

        uint256 fees = hook.collectProtocolFees(address(chip));
        uint256 back = chip.balanceOf(address(vault));
        assertEq(back, open.held - 25_000e18 - fees);
        assertEq(
            int256(back) - int256(HOUSE_CAPITAL),
            int256(aliceCost + bobCost + carolCost) - 25_000e18 - int256(fees),
            "the house: all premium, less both payouts and the protocol's fees"
        );
        assertEq(_sumOfUsers() + back + fees, 3 * STAKE + HOUSE_CAPITAL, "cash conservation");
    }

    // --------------------------------------------------------------------------------------------
    // the product cap and the minimum price, with the real engine
    // --------------------------------------------------------------------------------------------

    /// @dev The far floor (above +2 sigma) at the previous close: the engine asks under the minimum price for
    ///      the first token (about 0.012 chip with the vol-mix prior), so the first lot is charged the minimum price of two hundredths; the
    ///      buying itself then pushes the engine's price over the minimum, and the later lots cost what
    ///      the engine asks; the fee is taken on what is charged; five lots fill the product cap; the
    ///      sixth is refunded in full with its own reason; a sell is paid the engine's price and makes
    ///      room. The round opens with a product cap of a tenth of the capital per floor: the default has
    ///      no product cap, and the mechanism keeps its test.
    function test_floors_capAndMinPrice_buysAndRefunds() public {
        IPitBook.Params memory p = book.defaultParams();
        p.floorCapBps = 1000;
        _setParams(p);
        _open();
        uint256 lot = 20_000e18;
        uint256 total;
        uint256 lastCost;
        for (uint256 i; i < 5; ++i) {
            (uint256 quoted, uint256 fee, uint256 pBefore,,, RefundReason rejection) =
                lens.quote(roundId, F7, true, lot, S0, clock + 2);
            assertEq(uint8(rejection), uint8(RefundReason.None));
            if (i == 0) assertLt(pBefore, 0.015e18, "the engine's own price: well under the minimum price");
            assertGe(quoted - fee, lot * 2 / 100, "never under the minimum price");
            if (i == 0) assertEq(quoted - fee, lot * 2 / 100, "charged the minimum price, to the unit");
            assertGe(fee, (quoted - fee) * 2 / 100, "the base fee is taken on what is charged");
            uint256 cost = _buy(alice, F7, lot, S0);
            assertEq(cost, quoted, "the fill charges the quote");
            total += cost;
            lastCost = cost;
        }
        assertEq(_token(F7).totalSupply(), HOUSE_CAPITAL / 10, "at the product cap");
        emit log_named_decimal_uint("100,000 of the far floor at the previous close", total, 18);
        assertGe(total, 2_040e18, "never under 2,000 at the minimum price plus the 2% fee");
        // about 8,300 at alpha 0.2 with the vol-mix prior (the shallower book of alpha 0.2 takes
        // the later lots further over the minimum, and the mix's fat tail prices the far floor higher),
        // and the vega fee
        assertLt(total, 9_000e18, "the later lots are over the minimum");

        // over the cap: refunded in full, the reason is its own, the filler is paid for the work
        (,,,,, RefundReason verdict) = lens.quote(roundId, F7, true, 1e18, S0, clock + 2);
        assertEq(uint8(verdict), uint8(RefundReason.ProductCap));
        uint256 chipsBefore = chip.balanceOf(bob);
        uint256 id = _commitBuy(bob, F7, 1e18, chipsBefore);
        assertEq(chip.balanceOf(bob), 0, "the limit is in escrow");
        bytes memory report = _printFor(id, S0);
        uint256 keeperBefore = keeper.balance;
        vm.expectEmit(true, true, false, true, address(router));
        emit Refunded(id, bob, RefundReason.ProductCap);
        vm.prank(keeper);
        assertFalse(router.fill(id, report));
        assertEq(chip.balanceOf(bob), chipsBefore, "every chip came back");
        assertEq(keeper.balance - keeperBefore, FILL_FEE);
        assertEq(uint8(router.getCommit(id).status), uint8(IFallpitRouter.CommitStatus.Refunded));
        // it is refused before the oracle is asked, like the per-fill cap: any report refunds it
        id = _commitBuy(bob, F7, 1e18, chipsBefore);
        _warp(router.getCommit(id).fillTs);
        vm.prank(keeper);
        assertFalse(router.fill(id, ""));
        assertEq(chip.balanceOf(bob), chipsBefore);

        // a sell is not refused for the cap and is paid the engine's price
        uint256 heldBefore = _state().held;
        uint256 back = _sell(alice, F7, lot, S0);
        assertEq(heldBefore - _state().held, back);
        assertLt(back, lastCost, "the last lot, sold straight back, returns less than it cost");
        // and makes room for exactly what it took off
        id = _commitBuy(bob, F7, lot + 1, chipsBefore);
        assertFalse(_fill(id, S0));
        _buy(bob, F7, lot, S0);
        assertEq(_token(F7).totalSupply(), HOUSE_CAPITAL / 10);
        _assertSupplies();
        _assertHookSolvent(address(chip));
    }

    /// @dev No product cap under the defaults (`floorCapBps` 10000): a floor is
    ///      bought lot after lot past a tenth of the capital, the lens never
    ///      says `ProductCap`, nothing is refunded, and what bounds the floor is the engine (the token
    ///      goes toward one chip) and the loss limit at 30%, which fifteen lots do not reach. The cap's
    ///      ceiling is the whole capital in tokens.
    function test_floors_defaults_noProductCapRefusesABuy() public {
        _open();
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(c.params.floorCapBps, 10_000);
        assertEq(c.params.lossLimitBps, 3000);
        FallpitLens.Market memory m = lens.market(roundId, S0, clock + 2);
        assertTrue(m.products[F6].capped, "a floor is a capped product by shape");
        assertEq(m.products[F6].cap, HOUSE_CAPITAL, "and its cap is the whole capital: no cap");
        assertEq(m.products[HIGHER].cap, type(uint256).max);

        _fund(carol, 10_000_000e18);
        uint256 lot = 20_000e18;
        for (uint256 i; i < 15; ++i) {
            (,,,,, RefundReason rejection) = lens.quote(roundId, F6, true, lot, S0, clock + 2);
            assertEq(uint8(rejection), uint8(RefundReason.None), "nothing refuses the buy");
            _buy(carol, F6, lot, S0);
        }
        assertEq(_token(F6).totalSupply(), 300_000e18, "three times a tenth of the capital outstanding");
        m = lens.market(roundId, S0, clock + 2);
        assertEq(m.products[F6].capUsedBps, 3000, "30% of the capital, of a cap that is the capital");
        assertGt(m.products[F6].price, 0.8e18, "the engine has taken the token most of the way to a chip");
        (uint256 cushion, uint256 floor) = lens.lossLimit(roundId);
        assertEq(floor, HOUSE_CAPITAL * 7 / 10);
        assertGt(cushion, HOUSE_CAPITAL * 85 / 100, "far from the loss limit");
        assertEq(chip.balanceOf(address(router)), 0, "no refund was ever made");
        _assertSupplies();
        _assertHookSolvent(address(chip));
    }

    /// @dev The lens's `dead` flag: with the stock three sigma up, the floors far below the price are
    ///      priced by the engine under the minimum price of 0.02, so a buy would be charged the minimum
    ///      and the 50x multiple shown would be the minimum price's, not the odds. The lens marks them
    ///      `dead` (the six floors up to +1 sigma and LOWER, seven products); the two floors around the
    ///      price and HIGHER are not. `buyCosts` gives the all-in cost at one token, ten and the
    ///      per-fill cap, and `quote` charges the same.
    function test_floors_lens_deadFlagsAFarFloor_threeSigmaAway() public {
        _open();
        uint256 price = _priceAtSigmas(3e18);
        FallpitLens.Market memory m = lens.market(roundId, price, clock + 2);
        assertEq(m.minPrice, 0.02e18);
        uint256 deadProducts;
        for (uint256 i; i < PRODUCTS; ++i) {
            FallpitLens.Product memory q = m.products[i];
            assertEq(q.dead, q.price < 0.02e18, "dead is the engine's price under the minimum");
            if (q.dead) {
                ++deadProducts;
                assertEq(q.buyPrice, 0.02e18, "charged the minimum");
                assertEq(q.multiple, 50e18, "the multiple shown is the minimum price's");
            } else {
                assertEq(q.buyPrice, q.price);
            }
        }
        assertTrue(m.products[F0].dead, "below -2 sigma, five sigma from the price");
        assertTrue(m.products[F1].dead, "-2 to -1 sigma");
        assertTrue(m.products[F2].dead, "-1 to -0.5 sigma");
        assertTrue(m.products[F5].dead, "+0.5 to +1 sigma, two sigma under the price");
        assertTrue(m.products[LOWER].dead, "LOWER: three sigma under the price");
        assertFalse(m.products[F6].dead, "+1 to +2 sigma: next to the price");
        assertFalse(m.products[F7].dead, "above +2 sigma: where the price is");
        assertFalse(m.products[HIGHER].dead);
        assertEq(deadProducts, 7, "six floors and LOWER are dead, two floors and HIGHER alive");
        emit log_named_uint("products dead with the stock three sigma up", deadProducts);

        // the all-in cost at size, for a live floor and a dead one, equals the quote at that size
        uint8[2] memory picks = [F7, F0];
        for (uint256 k; k < 2; ++k) {
            (uint256[3] memory shares, uint256[3] memory cost, uint256[3] memory multiple) =
                lens.buyCosts(roundId, picks[k], price, clock + 2);
            assertEq(shares[0], 1e18);
            assertEq(shares[1], 10e18);
            assertEq(shares[2], hook.getConfig(roundId).maxFill);
            for (uint256 i; i < 3; ++i) {
                (uint256 quoted,,,,,) = lens.quote(roundId, picks[k], true, shares[i], price, clock + 2);
                assertEq(cost[i], quoted, "buyCosts is the quote at that size");
                assertEq(multiple[i], shares[i] * 1e18 / cost[i]);
            }
            assertLe(multiple[2], multiple[0], "a bigger ticket never pays a bigger multiple");
        }
        // the dead floor's multiple at size is under 50x all in (the minimum price plus fees), the live
        // floor's is the odds less fees
        (,, uint256[3] memory deadMultiple) = lens.buyCosts(roundId, F0, price, clock + 2);
        assertLt(deadMultiple[0], 50e18);
        assertGt(deadMultiple[0], 40e18);
        // at and after the close nothing is priced
        (uint256[3] memory sharesAtClose, uint256[3] memory costAtClose, uint256[3] memory multAtClose) =
            lens.buyCosts(roundId, F7, price, hook.getConfig(roundId).closeTs);
        assertEq(sharesAtClose[0], 1e18);
        assertEq(costAtClose[0] + costAtClose[1] + costAtClose[2], 0);
        assertEq(multAtClose[0] + multAtClose[1] + multAtClose[2], 0);
        vm.expectRevert(FallpitLens.UnknownProduct.selector);
        lens.buyCosts(roundId, 10, price, clock + 2);
    }

    /// @dev What the minimum price is for: the same 100,000 tokens of the far floor, with and without it.
    function test_floors_minPrice_farFloorIsNotBoughtForDust() public {
        uint256 snapshot = vm.snapshotState();
        _open();
        uint256 withMinimum;
        uint256 firstWithMinimum;
        for (uint256 i; i < 5; ++i) {
            uint256 cost = _buy(alice, F7, 20_000e18, _priceAtSigmas(-1e18));
            if (i == 0) firstWithMinimum = cost;
            withMinimum += cost;
        }
        vm.revertToState(snapshot);
        IPitBook.Params memory p = book.defaultParams();
        p.minPriceWad = 0;
        _setParams(p);
        _open();
        uint256 without;
        uint256 firstWithout;
        for (uint256 i; i < 5; ++i) {
            uint256 cost = _buy(alice, F7, 20_000e18, _priceAtSigmas(-1e18));
            if (i == 0) firstWithout = cost;
            without += cost;
        }
        emit log_named_decimal_uint(
            "100,000 above +2 sigma, stock one sigma down, no minimum price", without, 18
        );
        emit log_named_decimal_uint("  of which the first 20,000", firstWithout, 18);
        emit log_named_decimal_uint("the same with the minimum price of 0.02", withMinimum, 18);
        emit log_named_decimal_uint("  of which the first 20,000", firstWithMinimum, 18);
        // the first lot is the dust ticket: under a hundredth of a chip a token without the minimum,
        // two hundredths plus the fee with it. The later lots push the engine's price over the minimum
        // (at alpha 0.2 after about 40,000 tokens), so the totals are nearer each other than the first
        // lots
        assertLt(firstWithout, 200e18, "under a hundredth of a chip a token");
        assertGe(firstWithMinimum, 408e18, "two hundredths of a chip a token, plus the fee");
        assertLt(firstWithMinimum, 460e18);
        assertGe(withMinimum, 2_040e18, "never under two hundredths of a chip a token in all");
        assertGt(withMinimum, without);
    }

    // --------------------------------------------------------------------------------------------
    // complete sets: no arbitrage against the house
    // --------------------------------------------------------------------------------------------

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

    /// @dev Buys `shares` of every product of `set` at ONE print: all commits are made in the same second,
    ///      so one print prices them all, and they fill one after the other. Returns what the engine
    ///      charged before fees (the sum of every fill's cost, minimum price included) and the chips
    ///      paid in total. Each fill is checked against the lens's quote for the same print.
    function _buySetAtOnePrint(address user, uint8[] memory set, uint256 shares, uint256 price)
        internal
        returns (uint256 beforeFees, uint256 paid)
    {
        uint256[] memory ids = new uint256[](set.length);
        uint256 start = chip.balanceOf(user);
        for (uint256 i; i < set.length; ++i) {
            ids[i] = _commitBuy(user, set[i], shares, start / set.length);
        }
        bytes memory report = _printFor(ids[0], price);
        for (uint256 i; i < set.length; ++i) {
            (uint256 quoted, uint256 fee,,,, RefundReason rejection) =
                lens.quote(roundId, set[i], true, shares, _grid(price), clock);
            assertEq(uint8(rejection), uint8(RefundReason.None));
            uint256 before = chip.balanceOf(user);
            vm.prank(keeper);
            assertTrue(router.fill(ids[i], report));
            // the escrow of this commit came back less the cost
            uint256 cost = start / set.length - (chip.balanceOf(user) - before);
            assertEq(cost, quoted, "the fill charges the quote for the same print");
            beforeFees += quoted - fee;
            paid += cost;
        }
    }

    /// @dev The same for selling a set back at one print. Returns the engine's proceeds before fees.
    function _sellSetAtOnePrint(address user, uint8[] memory set, uint256 shares, uint256 price)
        internal
        returns (uint256 beforeFees, uint256 received)
    {
        uint256[] memory ids = new uint256[](set.length);
        for (uint256 i; i < set.length; ++i) {
            ids[i] = _commitSell(user, set[i], shares, 0);
        }
        bytes memory report = _printFor(ids[0], price);
        for (uint256 i; i < set.length; ++i) {
            (uint256 quoted, uint256 fee,,,,) =
                lens.quote(roundId, set[i], false, shares, _grid(price), clock);
            uint256 before = chip.balanceOf(user);
            vm.prank(keeper);
            assertTrue(router.fill(ids[i], report));
            assertEq(chip.balanceOf(user) - before, quoted);
            beforeFees += quoted + fee;
            received += quoted;
        }
    }

    /// @dev At one print, on a fresh book: HIGHER + LOWER, the eight floors, the four lower floors with
    ///      HIGHER, and LOWER with the four upper floors each pay exactly one chip per set whatever the
    ///      close. None of them can be bought for less than that even before any fee, at the previous
    ///      close or far from it, in the after-hours or late in the session, for one token or for the
    ///      per-fill cap; and none can be sold back for more.
    function test_floors_completeSets_neverCostLessThanTheyPay() public {
        int256[5] memory ks = [int256(0), 1e18, -1e18, 3e18, -3.5e18];
        uint256[3] memory sizes = [uint256(1e18), 1_500e18, 20_000e18];
        roundId = hook.openRound(ticker, roundChip, day);
        uint64[3] memory whens = [clock + 300, NYTime.openTs(day) + 600, NYTime.closeTs(day) - 3600];
        uint256 snapshot = vm.snapshotState();
        uint256 leastMargin = type(uint256).max;
        for (uint256 kind; kind < 4; ++kind) {
            uint8[] memory set = _completeSet(kind);
            for (uint256 n; n < 5; ++n) {
                uint256 shares = sizes[(kind + n) % 3];
                _warp(whens[(kind + 2 * n) % 3]);
                uint256 price = _priceAtSigmas(ks[n]);
                (uint256 beforeFees, uint256 paid) = _buySetAtOnePrint(alice, set, shares, price);
                assertGe(beforeFees, shares, "a complete set costs at least its payout, before any fee");
                assertGt(paid, shares, "and more with the fees");
                if (beforeFees - shares < leastMargin) leastMargin = beforeFees - shares;
                // the house holds the set's payout whatever the close
                IFallpitHook.RoundState memory st = _state();
                (uint256 worst,) = lens.solvency(roundId);
                assertEq(worst, shares, "every band owes exactly one set");
                assertGe(st.held - st.protocolFees, HOUSE_CAPITAL + shares);
                // sold straight back at the same oracle price, the set pays no more than it will redeem for
                _warp(clock + 30);
                (uint256 proceeds, uint256 received) = _sellSetAtOnePrint(alice, set, shares, price);
                assertLe(proceeds, shares, "a complete set never sells for more than its payout");
                assertLt(received, paid, "and the round trip loses");
                assertGe(_state().held, HOUSE_CAPITAL, "the house is no worse off");
                vm.revertToState(snapshot);
            }
        }
        emit log_named_decimal_uint(
            "least margin of a set over its payout, before fees (chips)", leastMargin, 18
        );
    }

    /// @dev The same on a book other traders have skewed, at any oracle price and any time of the round,
    ///      for any size: the cost of a complete set bought at one print is at least its payout before
    ///      fees. (The cost function is translation invariant: adding one token to every band costs
    ///      exactly one chip, and the engine rounds every step against the trader.)
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_floors_completeSet_onASkewedBook_costsAtLeastItsPayout(
        uint256 kind,
        uint256 shares,
        int256 k,
        uint256 when,
        uint256 seed
    ) public {
        uint8[] memory set = _completeSet(bound(kind, 0, 3));
        shares = bound(shares, 1e18, 20_000e18);
        k = bound(k, -4e18, 4e18);
        roundId = hook.openRound(ticker, roundChip, day);
        // other traders first: three buys of any product at any price near the previous close
        _warp(NYTime.openTs(day) + uint64(bound(when, 0, 3 hours)));
        for (uint256 i; i < 3; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 price = _priceAtSigmas(int256(seed % 3e18) - 1.5e18);
            uint256 id =
                _commitBuy(bob, uint8((seed >> 8) % PRODUCTS), bound(seed >> 16, 1e18, 20_000e18), STAKE / 4);
            _fill(id, price);
        }
        _warp(clock + uint64(bound(seed >> 128, 2, 2 hours)));
        uint256 heldBefore = _state().held;
        (uint256 worstBefore,) = lens.solvency(roundId);
        (uint256 beforeFees, uint256 paid) = _buySetAtOnePrint(alice, set, shares, _priceAtSigmas(k));
        assertGe(beforeFees, shares, "a complete set costs at least its payout, before any fee");
        // the house: one more chip owed in every band, and at least one more chip held for it
        (uint256 worst,) = lens.solvency(roundId);
        assertEq(worst, worstBefore + shares);
        assertEq(_state().held - heldBefore, paid);
        assertGt(paid, shares);
    }

    /// @dev A synthetic HIGHER (the four upper floors) and HIGHER itself are the same claim. Bought at one
    ///      print from the same book they cost the same up to the engine's rounding, which is never in
    ///      the buyer's favour; so there is nothing to gain by building one out of the other.
    function test_floors_syntheticHalf_costsWhatTheHalfCosts() public {
        _open();
        _buy(bob, F1, 5_000e18, S0);
        _buy(bob, HIGHER, 9_000e18, _priceAtSigmas(0.4e18));
        uint256 shares = 4_000e18;
        uint256 price = _priceAtSigmas(0.2e18);
        uint256 snapshot = vm.snapshotState();
        uint8[] memory upper = new uint8[](4);
        (upper[0], upper[1], upper[2], upper[3]) = (F4, F5, F6, F7);
        (uint256 synthetic,) = _buySetAtOnePrint(alice, upper, shares, price);
        vm.revertToState(snapshot);
        uint8[] memory half = new uint8[](1);
        half[0] = HIGHER;
        (uint256 direct,) = _buySetAtOnePrint(alice, half, shares, price);
        emit log_named_decimal_uint("four upper floors, before fees", synthetic, 18);
        emit log_named_decimal_uint("HIGHER, before fees", direct, 18);
        // the far floor is charged the minimum price, which can only make the synthetic dearer
        assertGe(synthetic, direct, "building HIGHER out of floors is never cheaper");
        assertApproxEqRel(synthetic, direct, 0.02e18, "and costs about the same");
    }

    // --------------------------------------------------------------------------------------------
    // the lens: prices of a partition sum to one
    // --------------------------------------------------------------------------------------------

    function test_floors_marketView_pricesOfAPartitionSumToOne() public {
        _open();
        _buy(alice, F5, 12_000e18, _priceAtSigmas(0.3e18));
        _buy(bob, LOWER, 7_000e18, _priceAtSigmas(-0.2e18));
        _buy(carol, F0, 3_000e18, S0);
        int256[3] memory ks = [int256(0), 1.2e18, -2.5e18];
        for (uint256 n; n < 3; ++n) {
            FallpitLens.Market memory m = lens.market(roundId, _priceAtSigmas(ks[n]), clock + 2);
            assertEq(m.products.length, PRODUCTS);
            uint256 floorsSum;
            uint256 upper;
            for (uint256 i; i < 8; ++i) {
                floorsSum += m.products[i].price;
                if (i >= 4) upper += m.products[i].price;
            }
            assertApproxEqAbs(floorsSum, 1e18, 1e6, "the eight floors: one chip in all");
            assertApproxEqAbs(
                m.products[LOWER].price + m.products[HIGHER].price, 1e18, 1e6, "the pair: one chip in all"
            );
            assertApproxEqAbs(upper, m.products[HIGHER].price, 1e6, "the four upper floors are HIGHER");
            for (uint256 i; i < PRODUCTS; ++i) {
                (,, uint256 pBefore,,,) =
                    lens.quote(roundId, uint8(i), true, 1e18, _priceAtSigmas(ks[n]), clock + 2);
                assertApproxEqAbs(m.products[i].price, pBefore, 1e6, "the price a quote starts from");
                assertGe(m.products[i].buyPrice, 0.02e18);
                assertLe(m.products[i].multiple, 50e18, "no token pays more than 50 times its price");
            }
        }
    }

    // --------------------------------------------------------------------------------------------
    // other menus on the real engine
    // --------------------------------------------------------------------------------------------

    /// @dev A whole round on `menu`: every product bought by two users and partly sold, a close, and the
    ///      books closed to the unit. Returns the winners.
    function _roundOn(uint256 menu, uint256 close) internal returns (uint16 winners, uint256 paid) {
        _setMenu(menu);
        _open();
        uint256 n = PitMath.count(menu);
        assertEq(hook.getConfig(roundId).params.menu, menu);
        uint256 price = S0;
        for (uint8 i; i < n; ++i) {
            price = _grid(price * (1000 + i) / 1000);
            _buy(alice, i, 5_000e18 + uint256(i) * 300e18, price);
            _buy(bob, i, 2_000e18, _grid(price * 999 / 1000));
            _warp(clock + 500);
        }
        for (uint8 i; i < n; ++i) {
            price = _grid(price * 998 / 1000);
            _sell(alice, i, 1_500e18, price);
            _warp(clock + 300);
        }
        _assertSupplies();
        _assertHookSolvent(address(chip));
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        IFallpitHook.RoundState memory open = _state();
        (uint256 worst, uint256 covered) = lens.solvency(roundId);
        assertLe(worst, covered);

        _closeAndFinalize(close);
        IFallpitHook.RoundState memory fin = _state();
        winners = fin.winners;
        assertEq(winners, PitMath.winners(menu, fin.closeBand));
        for (uint8 i; i < n; ++i) {
            Ticket memory token = _token(i);
            bool wins = token.lo() <= fin.closeBand && fin.closeBand <= token.hi();
            assertEq(winners >> i & 1 == 1, wins, "a product wins when its run holds the band of the close");
            assertEq(supply[i], token.balanceOf(alice) + token.balanceOf(bob), "the token is the claim");
            address[2] memory users = [alice, bob];
            for (uint256 u; u < 2; ++u) {
                uint256 balance = token.balanceOf(users[u]);
                vm.prank(users[u]);
                if (wins) {
                    assertEq(router.redeem(token.id, balance), balance);
                    paid += balance;
                } else {
                    vm.expectRevert(IFallpitHook.NotWinner.selector);
                    router.redeem(token.id, balance);
                }
            }
            if (wins) assertEq(token.totalSupply(), 0, "every winning token was redeemed");
        }
        assertEq(paid, fin.payoutOwed);
        assertLe(paid, worst, "never more than the worst band the round was checked against");
        uint256 fees = hook.collectProtocolFees(address(chip));
        uint256 back = chip.balanceOf(address(vault));
        assertEq(back, open.held - paid - fees);
        assertEq(
            chip.balanceOf(alice) + chip.balanceOf(bob) + back + fees,
            2 * STAKE + HOUSE_CAPITAL,
            "conservation"
        );
        assertEq(chip.balanceOf(address(hook)), 0);
    }

    function test_floors_otherMenu_sixFloorsAndPair() public {
        // up 1.2%: band 22, the floor from +0.5 to +1.5 sigma (index 4) and HIGHER (index 7)
        (uint16 winners,) = _roundOn(Menus.sixFloorsAndPair(), _grid(S0 * 1012 / 1000));
        assertEq(winners, uint16(1 << 4 | 1 << 7));
    }

    /// @dev The six-product threshold menu on a close 1.2% up: HIGHER at edges 15 and 19 and LOWER at
    ///      edge 23 win.
    function test_floors_otherMenu_theSixProductsOfTheFirstVersion() public {
        (uint16 winners,) = _roundOn(Menus.thresholds(), _grid(S0 * 1012 / 1000));
        assertEq(winners, uint16(1 | 4 | 32));
    }

    /// @dev A menu that does not partition the ladder. The products' prices do not sum to one; a close in
    ///      a band two products share pays both; a close in a band nobody covers pays nobody.
    function test_floors_menuThatDoesNotPartition() public {
        uint256 snapshot = vm.snapshotState();
        // down 0.3%: band 19, in the floor [15, 19] (index 1) and in the straddle [18, 21] (index 3)
        (uint16 winners, uint256 paid) = _roundOn(Menus.gappy(), _grid(S0 * 997 / 1000));
        assertEq(winners, uint16(1 << 1 | 1 << 3));
        assertGt(paid, 0);
        vm.revertToState(snapshot);
        // up 6%: band 31, which belongs to no product
        (winners, paid) = _roundOn(Menus.gappy(), _grid(S0 * 106 / 100));
        assertEq(winners, 0);
        assertEq(paid, 0);
        assertGt(chip.balanceOf(address(vault)), HOUSE_CAPITAL, "the house kept every chip of premium");
        vm.revertToState(snapshot);

        // the prices of this menu do not sum to one: the straddle counts bands 18 to 21 a second time,
        // and bands 10 to 14 and 30 to 39 are in no product
        _setMenu(Menus.gappy());
        _open();
        FallpitLens.Market memory m = lens.market(roundId, S0, clock + 2);
        uint256 sum;
        for (uint256 i; i < m.products.length; ++i) {
            sum += m.products[i].price;
        }
        assertGt(sum, 1.2e18);
        assertLt(sum, 1.6e18);
        // the worst band counts both products that share it
        _buy(alice, 1, 9_000e18, S0);
        _buy(alice, 3, 4_000e18, S0);
        _buy(alice, 2, 6_000e18, S0);
        (uint256 worst,) = lens.solvency(roundId);
        assertEq(worst, 13_000e18, "bands 18 and 19: the floor [15, 19] and the straddle [18, 21]");
        uint256[40] memory payout = lens.payouts(roundId);
        assertEq(payout[12], 0, "a band no product covers owes nothing");
        assertEq(payout[20], 10_000e18, "bands 20 and 21: the floor [20, 24] and the straddle");
    }
}
