// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {Menus} from "../Menus.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";

/// @notice Gas of a real fill: the real LadderMath, PitOracle (2-of-3 keeper print with the Chainlink bound,
///         or a Pyth update through the stand-in core contract), hook and router. The SPEC asks for a
///         fill under 5M gas. And the gas of opening a round (a ticket is an id of the hook, so nothing is
///         deployed per product): it must stay under 15M.
contract IntegrationGasTest is IntegrationFixture {
    function setUp() public override {
        super.setUp();
        _fund(alice, 100_000e18);
    }

    function _measure(uint256 id, uint256 price) internal returns (uint256 used) {
        bytes memory report = _printFor(id, price);
        vm.prank(keeper);
        uint256 gasBefore = gasleft();
        router.fill(id, report);
        used = gasBefore - gasleft();
    }

    function _run(string memory label, uint256 s0) internal {
        _open();
        // first fill of the round writes the 20 pricing slots (40 packed band states) for the first time
        uint256 first = _measure(_commitBuy(alice, HIGHER, 1_000e18, 10_000e18), s0);
        uint256 buy = _measure(_commitBuy(alice, LOWER, 1_000e18, 10_000e18), s0 * 1001 / 1000);
        // a fill after depth has started to decay (the rescale adds a third lambda solve)
        _warp(clock + 3 hours);
        uint256 lateBuy = _measure(_commitBuy(alice, F6, 1_000e18, 10_000e18), s0 * 1002 / 1000);
        // floors: a middle one (two finite edges), the far one (at the minimum price), and a sell
        uint256 floorBuy = _measure(_commitBuy(alice, F4, 1_000e18, 10_000e18), s0 * 1001 / 1000);
        uint256 farFloorBuy = _measure(_commitBuy(alice, F7, 1_000e18, 10_000e18), s0);
        uint256 floorSell = _measure(_commitSell(alice, F4, 400e18, 0), s0);
        uint256 pairBuy = _measure(_commitBuy(alice, HIGHER, 1_000e18, 10_000e18), s0);
        uint256 sell = _measure(_commitSell(alice, HIGHER, 400e18, 0), s0);
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        router.commit{value: FILL_FEE}(roundId, F5, true, 1_000e18, 10_000e18);
        uint256 commit = gasBefore - gasleft();

        emit log_string(label);
        emit log_named_uint("  commit (buy)", commit);
        emit log_named_uint("  fill, first buy of a round (pair)", first);
        emit log_named_uint("  fill, later buy (pair)", buy);
        emit log_named_uint("  fill, buy of a floor after depth decay", lateBuy);
        emit log_named_uint("  fill, buy of a floor", floorBuy);
        emit log_named_uint("  fill, buy of the far floor (minimum price)", farFloorBuy);
        emit log_named_uint("  fill, sell of a floor", floorSell);
        emit log_named_uint("  fill, buy of the pair", pairBuy);
        emit log_named_uint("  fill, sell of the pair", sell);
        assertLt(first, 5_000_000);
        assertLt(buy, 5_000_000);
        assertLt(lateBuy, 5_000_000);
        assertLt(floorBuy, 5_000_000);
        assertLt(farFloorBuy, 5_000_000);
        assertLt(floorSell, 5_000_000);
        assertLt(pairBuy, 5_000_000);
        assertLt(sell, 5_000_000);
    }

    /// @dev The extended hours: the first fill of a round in the after-hours, a later one there, and the
    ///      first fill of the pre-market (the depth rescale after the overnight gap).
    function test_gas_fill_extendedHours() public {
        roundId = hook.openRound(ticker, roundChip, day);
        _warp(clock + 60);
        uint256 first = _measure(_commitBuy(alice, HIGHER, 1_000e18, 10_000e18), S0);
        uint256 buy = _measure(_commitBuy(alice, LOWER, 1_000e18, 10_000e18), S0 * 1001 / 1000);
        _warp(NYTime.at(day, 4 hours) - 2);
        uint256 preMarket = _measure(_commitBuy(alice, F6, 1_000e18, 10_000e18), S0 * 1002 / 1000);
        uint256 sell = _measure(_commitSell(alice, HIGHER, 400e18, 0), S0);
        emit log_string("keeper-signed print, extended hours");
        emit log_named_uint("  fill, first buy of a round (after-hours)", first);
        emit log_named_uint("  fill, later buy (after-hours)", buy);
        emit log_named_uint("  fill, first buy of the pre-market", preMarket);
        emit log_named_uint("  fill, sell (pre-market)", sell);
        assertLt(first, 5_000_000);
        assertLt(buy, 5_000_000);
        assertLt(preMarket, 5_000_000);
        assertLt(sell, 5_000_000);
    }

    /// @dev A batch of four buys of one round at one print, after the round's first fill: the cost of an
    ///      extra fill in the batch next to a later fill on its own.
    function test_gas_fillBatch() public {
        _open();
        _measure(_commitBuy(alice, HIGHER, 1_000e18, 10_000e18), S0);
        uint256 single = _measure(_commitBuy(alice, LOWER, 1_000e18, 10_000e18), S0);
        uint256[] memory ids = new uint256[](4);
        bytes[] memory reports = new bytes[](4);
        ids[0] = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        ids[1] = _commitBuy(alice, LOWER, 1_000e18, 10_000e18);
        ids[2] = _commitBuy(alice, F4, 1_000e18, 10_000e18);
        ids[3] = _commitBuy(alice, F5, 1_000e18, 10_000e18);
        bytes memory report = _printFor(ids[0], S0 * 1001 / 1000);
        for (uint256 i; i < 4; ++i) {
            reports[i] = report;
        }
        vm.prank(keeper);
        uint256 gasBefore = gasleft();
        bool[] memory ok = router.fillBatch(ids, reports);
        uint256 batch = gasBefore - gasleft();
        for (uint256 i; i < 4; ++i) {
            assertTrue(ok[i]);
        }
        emit log_string("fillBatch, keeper-signed print");
        emit log_named_uint("  fill, later buy on its own", single);
        emit log_named_uint("  fillBatch of 4", batch);
        emit log_named_uint("  per extra fill in the batch", (batch - single) / 3);
        assertLt(batch, 4 * single, "a batch costs less than the fills one by one");
    }

    function test_gas_fill_keeperSignedPrint() public {
        _run("keeper-signed print (2 of 3, Chainlink-bounded)", S0);
    }

    function test_gas_fill_pythUpdate() public {
        _use(TSLA, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        _run("Pyth update (stand-in core contract; the real one adds its own verification)", TSLA_S0);
    }

    /// @dev Opening a round: the capital pull and the 40 depths, on menus of every size. The
    ///      default menu has 10 products; the largest a menu can be is 12, the smallest 2.
    function test_gas_openRound_perMenu() public {
        uint256 snapshot = vm.snapshotState();
        uint256 standard = _openGas(book.DEFAULT_MENU());
        vm.revertToState(snapshot);
        uint256 smallest = _openGas(Menus.pairOnly());
        vm.revertToState(snapshot);
        uint8[2][] memory runs = new uint8[2][](12);
        for (uint8 i; i < 12; ++i) {
            runs[i] = [i * 3, i * 3 + 6];
        }
        uint256 largest = _openGas(Menus.pack(runs));
        vm.revertToState(snapshot);
        uint256 old = _openGas(Menus.thresholds());
        emit log_named_uint("openRound, default menu (10 products)", standard);
        emit log_named_uint("openRound, 2 products", smallest);
        emit log_named_uint("openRound, 6 products (the threshold menu)", old);
        emit log_named_uint("openRound, 12 products", largest);
        emit log_named_uint("  per product, about", (largest - smallest) / 10);
        assertLt(standard, 15_000_000, "the default menu opens far under 15M gas");
        assertLt(largest, 15_000_000, "and so does the largest menu");
    }

    /// @dev The next day's open writes the house's open depths over the used slots of the day before.
    function test_gas_openRound_secondDay() public {
        uint256 g = gasleft();
        hook.openRound(ticker, roundChip, day);
        uint256 first = g - gasleft();
        _closeAndFinalize(S0);
        _warp(NYTime.closeTs(day) + 120);
        g = gasleft();
        hook.openRound(ticker, roundChip, day + 1);
        uint256 second = g - gasleft();
        emit log_named_uint("openRound, first open of a house", first);
        emit log_named_uint("openRound, next day", second);
        assertLt(second, first);
    }

    /// @dev The first fill of a house's next round, after a traded day: it writes the pricing state where
    ///      the round before kept its own.
    function test_gas_fill_firstOfTheNextRound() public {
        _open();
        uint256 firstEver = _measure(_commitBuy(alice, HIGHER, 1_000e18, 10_000e18), S0);
        _measure(_commitBuy(alice, LOWER, 1_000e18, 10_000e18), S0);
        _closeAndFinalize(S0);
        _warp(NYTime.closeTs(day) + 120);
        day += 1;
        roundId = hook.openRound(ticker, roundChip, day);
        _warp(clock + 60);
        uint256 firstNext = _measure(_commitBuy(alice, HIGHER, 1_000e18, 10_000e18), S0);
        emit log_named_uint("fill, first buy of a house's first round", firstEver);
        emit log_named_uint("fill, first buy of the house's next round", firstNext);
    }

    /// @dev A live strike: one call with the print of now, at 15:00 New York (less than half of the round's
    ///      variance ahead), at the edge nearest to a price `steps` quarter-sigmas from S0.
    function _strikeGas(uint256 s0, int256 steps) internal returns (uint256 used) {
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        uint256 price = _grid(s0 * uint256(FixedPointMathLib.expWad(steps * int256(c.sigma) / 4)) / 1e18);
        (uint8 m, bool ok) = lens.strikeEdgeAt(roundId, price, clock);
        require(ok, "the strike may open");
        bytes memory report = _print(clock, price);
        uint256 g = gasleft();
        hook.openStrike(roundId, m, clock, report);
        used = g - gasleft();
    }

    /// @dev The settle of a round with what it has open (10 or 14 products), with a trustless close.
    function _settleGas(uint256 s0) internal returns (uint256 used) {
        _recordClose(s0, PYTH_SOURCE);
        uint256 g = gasleft();
        hook.settleRound(house, day);
        used = g - gasleft();
    }

    /// @dev Two later fills of the same floor at 15:00, one second apart, the second measured: on the
    ///      round's ten products, or after two strikes on fourteen.
    function _lateFill(uint256 s0, bool strikes) internal returns (uint256 fill, uint256 strike) {
        _open();
        _measure(_commitBuy(alice, HIGHER, 1_000e18, 10_000e18), s0);
        _warp(NYTime.at(day, 15 hours));
        if (strikes) {
            strike = _strikeGas(s0, 4);
            _warp(clock + 1);
            _strikeGas(s0, -4);
            _warp(clock + 1);
        }
        _measure(_commitBuy(alice, F5, 1_000e18, 10_000e18), s0);
        _warp(clock + 1);
        fill = _measure(_commitBuy(alice, F5, 1_000e18, 10_000e18), s0);
        if (strikes) {
            _warp(clock + 1);
            _measure(_commitBuy(alice, 11, 1_000e18, 10_000e18), s0);
        }
    }

    function _strikeRun(string memory label, uint256 s0) internal {
        uint256 snapshot = vm.snapshotState();
        (uint256 ten,) = _lateFill(s0, false);
        uint256 settleTen = _settleGas(s0);
        vm.revertToState(snapshot);
        (uint256 fourteen, uint256 strike) = _lateFill(s0, true);
        uint256 settleFourteen = _settleGas(s0);
        emit log_string(label);
        emit log_named_uint("  openStrike", strike);
        emit log_named_uint("  fill, later buy of a floor, 10 products", ten);
        emit log_named_uint("  fill, later buy of a floor, 14 products", fourteen);
        emit log_named_uint("  settleRound, 10 products", settleTen);
        emit log_named_uint("  settleRound, 14 products", settleFourteen);
        assertLt(strike, 500_000);
        assertLt(fourteen, 5_000_000);
    }

    function test_gas_openStrike_keeperSignedPrint() public {
        _strikeRun("live strike, keeper-signed print", S0);
    }

    function test_gas_openStrike_pythUpdate() public {
        _use(TSLA, address(chip));
        _lpDeposit(lp, house, HOUSE_CAPITAL);
        _strikeRun("live strike, Pyth update (stand-in core contract)", TSLA_S0);
    }

    function _openGas(uint256 menu) internal returns (uint256 used) {
        _setMenu(menu);
        uint256 gasBefore = gasleft();
        hook.openRound(ticker, roundChip, day);
        used = gasBefore - gasleft();
    }
}
