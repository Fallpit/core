// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {PitVault} from "../../src/PitVault.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {PitMath} from "../../src/hook/PitMath.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice Day-level differential test. `test/vectors/gen_day.py` simulates one whole stock round with
///         the reference math of `test/vectors/ladder_house_sim.py` (float64) plus the clock,
///         fee, minimum price, depth-decay, product cap, solvency, loss limit and settlement rules of the
///         SPEC, and writes `day.json`: an oracle path, 96 timed buys and sells on the ten products of
///         the default menu (the eight floors and the pair; 18 in the after-hours of the day before, 18
///         in the pre-market, 60 in the regular session, the four window edges among them), the close,
///         what every fill costs or pays and what the house is left with. One floor is bought lot after
///         lot past a tenth of the capital (the defaults have no product cap,
///         and with alpha 0.2 one-sided buying cannot reach the loss limit at 30%, so nothing is
///         refused); thirteen buys of far floors are charged the minimum price (the vol-mix prior has
///         fat tails, so some far floors price above it). This test replays that round through the real
///         contracts (keeper prints verified by PitOracle, router, hook, PitBook's clock, LadderMath,
///         vault) and compares
///         the clock at every fill, every fill, the cushion after every fill and the final house result.
/// @dev Tolerance: rounding only. The contracts round every amount against the trader (the engine's
///      safety margin of a few 1e-18 of the largest depth, one chip unit per rounding step) and the
///      reference is float64 (about 1e-16 relative per operation, 1e-12 on a cost difference of state
///      values near 1e5). One part in 1e9 per fill is far above both and far below any modelling error.
contract DaySimTest is IntegrationFixture {
    uint256 internal constant REL_TOL = 1e9; // 1e-9 relative, in WAD
    uint256 internal constant ABS_TOL = 1e9; // 1e-9 chips

    struct Day {
        uint256 trades;
        uint256[] offset;
        uint256[] rho;
        uint256[] price;
        uint256[] product;
        bool[] isBuy;
        uint256[] shares;
        bool[] minPriced;
        uint256[] chips;
        uint256[] fee;
        uint256[] cushion;
        uint256 lowestCushion;
        uint256 closePrice;
        uint256 closeBand;
        uint256 winners;
        uint256 payout;
        uint256[] supplyAtClose;
        uint256 heldAtClose;
        uint256 protocolFees;
        uint256 returned;
        int256 houseResult;
        uint256 gAtClose;
    }

    function _load() internal view returns (Day memory d) {
        string memory json = vm.readFile("test/vectors/day.json");
        assertEq(vm.parseJsonUint(json, ".sigma"), 0.02e18);
        assertEq(vm.parseJsonUint(json, ".s0"), S0);
        assertEq(vm.parseJsonUint(json, ".capital"), HOUSE_CAPITAL);
        d.trades = vm.parseJsonUint(json, ".trades");
        d.offset = vm.parseJsonUintArray(json, ".offset");
        d.rho = vm.parseJsonUintArray(json, ".rho");
        uint256[] memory weights = vm.parseJsonUintArray(json, ".weights");
        assertEq(weights[0], 600);
        assertEq(weights[1], 1400);
        assertEq(weights[2], 1000);
        assertEq(weights[3], 7000);
        assertEq(vm.parseJsonUint(json, ".afterHoursTrades"), 18);
        assertEq(vm.parseJsonUint(json, ".preMarketTrades"), 18);
        assertEq(vm.parseJsonUint(json, ".regularTrades"), 60);
        // the reference's menu, alpha, loss limit, product cap and minimum price are the book's defaults
        uint256[] memory lo = vm.parseJsonUintArray(json, ".menuLo");
        uint256[] memory hi = vm.parseJsonUintArray(json, ".menuHi");
        uint256 menu = book.DEFAULT_MENU();
        assertEq(lo.length, PitMath.count(menu));
        for (uint256 i; i < lo.length; ++i) {
            (uint8 a, uint8 b) = PitMath.run(menu, i);
            assertEq(lo[i], a);
            assertEq(hi[i], b);
        }
        assertEq(vm.parseJsonUint(json, ".alpha"), book.defaultParams().alpha);
        assertEq(vm.parseJsonUint(json, ".lossLimitBps"), book.defaultParams().lossLimitBps);
        assertEq(vm.parseJsonUint(json, ".floorCapBps"), book.defaultParams().floorCapBps);
        assertEq(vm.parseJsonUint(json, ".minPrice"), book.defaultParams().minPriceWad);
        assertEq(vm.parseJsonUint(json, ".refused"), 0);
        assertEq(vm.parseJsonUint(json, ".atTheMinPrice"), 13);
        d.price = vm.parseJsonUintArray(json, ".price");
        d.product = vm.parseJsonUintArray(json, ".product");
        d.isBuy = vm.parseJsonBoolArray(json, ".isBuy");
        d.shares = vm.parseJsonUintArray(json, ".shares");
        d.minPriced = vm.parseJsonBoolArray(json, ".minPriced");
        d.supplyAtClose = vm.parseJsonUintArray(json, ".supplyAtClose");
        d.chips = vm.parseJsonUintArray(json, ".chips");
        d.fee = vm.parseJsonUintArray(json, ".fee");
        d.cushion = vm.parseJsonUintArray(json, ".cushion");
        d.lowestCushion = vm.parseJsonUint(json, ".lowestCushion");
        d.closePrice = vm.parseJsonUint(json, ".closePrice");
        d.closeBand = vm.parseJsonUint(json, ".closeBand");
        d.winners = vm.parseJsonUint(json, ".winners");
        d.payout = vm.parseJsonUint(json, ".payout");
        d.heldAtClose = vm.parseJsonUint(json, ".heldAtClose");
        d.protocolFees = vm.parseJsonUint(json, ".protocolFees");
        d.returned = vm.parseJsonUint(json, ".returned");
        d.houseResult = vm.parseJsonInt(json, ".houseResult");
        d.gAtClose = vm.parseJsonUint(json, ".gAtClose");
    }

    function _within(uint256 got, uint256 want) internal pure returns (bool) {
        uint256 diff = got > want ? got - want : want - got;
        return diff <= want / REL_TOL + ABS_TOL;
    }

    function test_daySim_everyFillAndTheHouseResult_matchTheReference() public {
        Day memory d = _load();
        assertEq(d.trades, 96);
        // the reference assumes the book's default round on the default stock clock, opened a minute
        // after Monday's close: check that this is what opens
        _fund(alice, 5_000_000e18);
        roundId = hook.openRound(ticker, roundChip, day);
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        uint64 prevClose = NYTime.closeTs(day0);
        assertEq(c.openTs, prevClose + 60);
        assertEq(c.sigma, 0.02e18);
        assertEq(c.s0, S0);
        assertEq(c.capital, HOUSE_CAPITAL);
        assertEq(uint8(c.clock.kind), uint8(IPitBook.Clock.NYWeekdays));
        assertFalse(c.clock.skipAfterHours);
        assertEq(c.clock.prevDay, day0);
        assertEq(c.clock.afterHours, 600);
        assertEq(c.clock.gap, 1400);
        assertEq(c.clock.preMarket, 1000);
        assertEq(c.clock.regular, 7000);
        // the book's defaults
        assertEq(c.params.alpha, 0.2e18);
        assertEq(c.params.baseFee, 0.02e18);
        assertEq(c.params.closeFee, 0.05e18);
        assertEq(c.params.feeRamp, 7200);
        assertEq(c.params.vegaFee, 0.1e18);
        assertEq(c.params.protocolFeeBps, 1000);
        assertEq(c.params.maxFillBps, 200);
        assertEq(c.params.lossLimitBps, 3000);
        assertEq(c.params.floorCapBps, 10_000);
        assertEq(c.params.minPriceWad, 0.02e18);
        assertEq(c.params.menu, book.DEFAULT_MENU());
        // the reference's clock is in seconds since the previous close, with no daylight-saving switch
        assertEq(c.closeTs - prevClose, 86_400);
        assertEq(NYTime.at(day0, 20 hours) - prevClose, 14_400);
        assertEq(NYTime.at(day, 4 hours) - prevClose, 43_200);
        assertEq(NYTime.openTs(day) - prevClose, 63_000);
        assertEq(d.offset[17], 14_399, "a fill in the last second of the after-hours");
        assertEq(d.offset[18], 43_200, "a fill in the first second of the pre-market");
        assertEq(d.offset[36], 63_000, "a fill in the first second of the regular session");
        assertEq(d.offset[95], 86_400 - 630, "a fill at the cutoff");

        uint256 worstRel;
        uint256 worstRho;
        uint256 paid;
        uint256 received;
        int256 drift; // sum of (contract - reference), in the house's favour when positive
        uint256 fills;
        uint256 minPriced;
        uint256 lowestCushion = type(uint256).max;
        for (uint256 i; i < d.trades; ++i) {
            // the commit is made two seconds before the print that prices it
            _warp(prevClose + uint64(d.offset[i]) - 2);
            uint8 product = uint8(d.product[i]);
            uint256 fee;
            uint256 pBefore;
            RefundReason verdict;
            (, fee, pBefore,,, verdict) =
                lens.quote(roundId, product, d.isBuy[i], d.shares[i], d.price[i], clock + 2);
            assertEq(uint8(verdict), uint8(RefundReason.None), "nothing is refused on this day");
            uint256 chips = d.isBuy[i]
                ? _buy(alice, product, d.shares[i], d.price[i])
                : _sell(alice, product, d.shares[i], d.price[i]);
            assertEq(clock, prevClose + d.offset[i], "filled at the print the reference priced");
            ++fills;
            if (d.minPriced[i]) {
                // charged the minimum price: exactly two hundredths of a chip per token before the fee
                assertEq(chips - fee, d.shares[i] * 2 / 100, "the minimum price, to the unit");
                assertLt(pBefore, 0.02e18, "the engine asked less");
                ++minPriced;
            } else if (d.isBuy[i]) {
                assertGt(chips - fee, d.shares[i] * 2 / 100, "above the minimum price");
            }
            {
                // the clock at that print: the book's (which the hook used) against the reference's
                (uint256 rho, bool tradable) = book.clockAt(c.clock, clock);
                assertTrue(tradable);
                uint256 rhoDiff = rho > d.rho[i] ? rho - d.rho[i] : d.rho[i] - rho;
                if (rhoDiff > worstRho) worstRho = rhoDiff;
                assertLe(rhoDiff, 1e6, "rho differs from the reference by more than rounding");
            }
            assertTrue(_within(chips, d.chips[i]), "a fill differs from the reference by more than rounding");
            assertTrue(_within(fee, d.fee[i]), "a fee differs from the reference by more than rounding");
            {
                // the house's worst-band cushion after the fill, against the reference's; it never
                // comes near the loss limit's floor on this day
                (uint256 cushion, uint256 floor) = lens.lossLimit(roundId);
                assertTrue(_within(cushion, d.cushion[i]), "the cushion differs from the reference");
                assertEq(floor, HOUSE_CAPITAL * 7 / 10, "the loss limit's floor: 70% of the capital");
                if (cushion < lowestCushion) lowestCushion = cushion;
            }
            uint256 diff = chips > d.chips[i] ? chips - d.chips[i] : d.chips[i] - chips;
            uint256 rel = d.chips[i] == 0 ? 0 : diff * 1e18 / d.chips[i];
            if (rel > worstRel) worstRel = rel;
            if (d.isBuy[i]) {
                paid += chips;
                drift += int256(chips) - int256(d.chips[i]);
            } else {
                received += chips;
                drift += int256(d.chips[i]) - int256(chips);
            }
        }
        assertEq(fills, d.trades, "every trade of the day filled");
        assertEq(minPriced, 13, "buys charged the minimum price");
        assertTrue(_within(lowestCushion, d.lowestCushion), "the lowest cushion of the day");
        assertGt(lowestCushion, HOUSE_CAPITAL * 9 / 10, "the day never puts a tenth of the capital at risk");
        emit log_named_uint("buys charged the minimum price, in both", minPriced);
        emit log_named_decimal_uint("lowest cushion of the day (chips)", lowestCushion, 18);
        emit log_named_decimal_uint("worst difference of rho (1 = the whole variance)", worstRho, 18);
        emit log_named_uint("fills compared", fills);
        emit log_named_decimal_uint("worst relative difference of a fill (1 = 100%)", worstRel, 18);
        emit log_named_decimal_int("sum of differences, in the house's favour (chips)", drift, 18);

        // the state the day ends in
        IFallpitHook.RoundState memory open = _state();
        assertEq(open.g, d.gAtClose, "depth scale at the close");
        assertTrue(_within(open.held, d.heldAtClose), "chips held at the close");
        assertTrue(_within(open.protocolFees, d.protocolFees), "protocol fees");
        {
            (uint256[12] memory supply,) = hook.getSupplies(roundId);
            for (uint256 i; i < PRODUCTS; ++i) {
                assertEq(supply[i], d.supplyAtClose[i], "outstanding supply of every product, to the unit");
            }
            // the popular floor (0 to +0.5 sigma) ended the day past a tenth of the capital: there is no
            // product cap
            assertGt(supply[4], HOUSE_CAPITAL / 10, "the popular floor passed a tenth of the capital");
        }

        // the close, settlement and what the house gets back
        _recordClose(d.closePrice, KEEPER_SOURCE);
        hook.settleRound(house, day);
        IFallpitHook.RoundState memory settled = _state();
        assertEq(settled.closeBand, d.closeBand, "the band of the close");
        assertEq(settled.winners, d.winners, "the winning products");
        assertEq(settled.payoutOwed, d.payout, "what winners are owed, to the unit");
        _warp(settled.settledAt + 900);
        hook.finalizeRound(house, day);

        PitVault.House memory h = vault.getHouse(house);
        uint256 back = h.lpAssets + h.endowment;
        assertTrue(_within(back, d.returned), "what returns to the vault");
        int256 houseResult = int256(back) - int256(HOUSE_CAPITAL);
        int256 gap = houseResult - d.houseResult;
        emit log_named_decimal_int("house result, reference (chips)", d.houseResult, 18);
        emit log_named_decimal_int("house result, contracts (chips)", houseResult, 18);
        emit log_named_decimal_int("difference (chips)", gap, 18);
        // the house result is a small difference of large sums: compare it against the day's volume
        uint256 volume = paid + received;
        assertLe(gap < 0 ? uint256(-gap) : uint256(gap), volume / REL_TOL + ABS_TOL, "house result");
        // every rounding goes against the trader, but the protocol's fee share is rounded down per fill,
        // so nothing is asserted about the sign of the gap beyond the tolerance
        assertEq(back, open.held - settled.payoutOwed - open.protocolFees, "books close to the unit");
    }
}
