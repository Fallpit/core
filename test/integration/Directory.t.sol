// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {FallpitDirectory} from "../../src/hook/FallpitDirectory.sol";
import {PitOracle} from "../../src/PitOracle.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";

/// @notice The app's discovery lens on the real system: the ticker and house lists, an LP's position, and
///         the next round a ticker can open, checked against what `openRound` itself does.
contract DirectoryTest is IntegrationFixture {
    address internal lp2 = makeAddr("lp2");

    /// @dev Records the trustless close of `t` on `d` at `price`, moving the clock to just after it.
    function _closeOf(bytes32 t, uint32 d, uint256 price) internal {
        uint64 closeAt = NYTime.closeTs(d);
        if (clock < closeAt + 5) _warp(closeAt + 5);
        book.recordClose(t, d, _pythPrint(t, price, closeAt));
    }

    function _next(bytes32 t) internal view returns (uint32 d, uint64 openTs, uint64 closeTs, bool openable) {
        return directory.nextOpenableDay(t);
    }

    // ------------------------------------------------------------------------------------------ tickers

    function test_tickers_liveAndPending_oneEntryEach() public {
        FallpitDirectory.TickerView[] memory list = directory.tickers();
        assertEq(list.length, 2, "NVDA and TSLA from the fixture");
        assertEq(list[0].ticker, NVDA);
        assertTrue(list[0].live);
        assertEq(list[0].pendingEta, 0);
        assertEq(uint8(list[0].fillSource), uint8(IPitBook.FillSource.KeeperOnly));
        assertEq(uint8(list[0].clock), uint8(IPitBook.Clock.NYWeekdays));
        assertEq(list[0].windows, 13, "the default windows");
        assertEq(list[0].lastCloseDay, day0);
        assertEq(list[0].varWad, SEED_VAR);
        assertEq(list[1].ticker, TSLA);
        assertEq(uint8(list[1].fillSource), uint8(IPitBook.FillSource.TrustlessOnly));

        // a new ticker is listed at once, as pending, with what it will have
        vm.startPrank(owner);
        PitOracle.TickerConfig memory c;
        c.pythFeedId = ETH_ID;
        oracle.setTicker(ETH, c);
        book.registerTicker(
            ETH,
            SEED_VAR,
            IPitBook.Clock.EveryDay,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        // registered again before it is in force, and a reseed of a live ticker: no new entries
        book.registerTicker(
            ETH,
            SEED_VAR * 2,
            IPitBook.Clock.EveryDay,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        book.registerTicker(
            NVDA,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            15,
            IPitBook.FillSource.KeeperOnly
        );
        vm.stopPrank();
        uint64 eta = clock + 24 hours;
        list = directory.tickers();
        assertEq(list.length, 3);
        assertEq(book.tickers().length, 3);
        assertEq(list[2].ticker, ETH);
        assertFalse(list[2].live, "pending for 24 hours");
        assertEq(list[2].pendingEta, eta);
        assertEq(uint8(list[2].clock), uint8(IPitBook.Clock.EveryDay));
        assertEq(uint8(list[2].fillSource), uint8(IPitBook.FillSource.TrustlessOnly));
        assertEq(list[2].varWad, SEED_VAR * 2, "the latest registration");
        assertEq(list[2].windows, 15, "every window: around the clock");
        assertTrue(list[0].live);
        assertEq(list[0].pendingEta, eta, "NVDA's reseed waits");
        assertEq(list[0].windows, 13, "the windows in force until then");
        assertFalse(book.supported(ETH));

        _warp(eta);
        list = directory.tickers();
        assertEq(list.length, 3);
        assertTrue(list[2].live);
        assertEq(list[2].pendingEta, 0);
        assertEq(list[0].windows, 15, "the reseed is in force");
        assertTrue(book.supported(ETH));

        FallpitDirectory.TickerView memory none = directory.tickerOf(bytes32("NOPE"));
        assertEq(none.ticker, bytes32("NOPE"));
        assertFalse(none.live);
        assertEq(none.varWad, 0);
    }

    // ------------------------------------------------------------------------------------------- houses

    function test_houses_followTheRounds_andRoll() public {
        bytes32 nvdaHouse = house;
        _use(TSLA, address(chip));
        bytes32 tslaHouse = house;
        _lpDeposit(lp, tslaHouse, HOUSE_CAPITAL / 2);

        FallpitDirectory.HouseView[] memory list = directory.houses();
        assertEq(list.length, 2);
        assertEq(vault.houseCount(), 2);
        assertEq(list[0].house, nvdaHouse);
        assertEq(list[0].ticker, NVDA);
        assertEq(list[0].chip, address(chip));
        assertEq(list[0].capital, HOUSE_CAPITAL);
        assertFalse(list[0].locked);
        assertEq(list[0].roundId, bytes32(0));
        assertEq(uint8(list[0].roundStatus), uint8(IFallpitHook.Status.None));
        assertEq(list[0].roundDay, 0);
        assertEq(list[1].house, tslaHouse);
        assertEq(list[1].capital, HOUSE_CAPITAL / 2);

        // pages
        assertEq(directory.houses(1, 10).length, 1);
        assertEq(directory.houses(1, 10)[0].house, tslaHouse);
        assertEq(directory.houses(0, 1)[0].house, nvdaHouse);
        assertEq(directory.houses(2, 1).length, 0);
        assertEq(directory.houses(7, 3).length, 0);

        // a round opens: the house is locked and points at it
        _use(NVDA, address(chip));
        bytes32 first = _open();
        FallpitDirectory.HouseView memory v = directory.houseOf(nvdaHouse);
        assertTrue(v.locked);
        assertEq(v.roundId, first);
        assertEq(uint8(v.roundStatus), uint8(IFallpitHook.Status.Open));
        assertEq(v.roundDay, day);
        assertEq(v.capital, hook.getConfig(first).capital, "the round's capital");

        // a winning bet, the close, settlement and finalization: the house's capital moves
        _fund(alice, 100_000e18);
        _buy(alice, HIGHER, 10_000e18, S0);
        _recordClose(S0 * 99 / 100, PYTH_SOURCE);
        hook.settleRound(house, day);
        assertEq(uint8(directory.houseOf(nvdaHouse).roundStatus), uint8(IFallpitHook.Status.Settled));
        hook.finalizeRound(house, day);
        v = directory.houseOf(nvdaHouse);
        assertFalse(v.locked);
        assertEq(uint8(v.roundStatus), uint8(IFallpitHook.Status.Final));
        assertGt(v.capital, HOUSE_CAPITAL, "HIGHER lost: the house kept the premium");

        // the round rolls: the next day's round
        uint32 firstDay = day;
        day += 1;
        bytes32 second = _open();
        v = directory.houseOf(nvdaHouse);
        assertTrue(v.locked);
        assertEq(v.roundId, second);
        assertTrue(second != first);
        assertEq(v.roundDay, firstDay + 1);
        assertEq(uint8(v.roundStatus), uint8(IFallpitHook.Status.Open));
        assertEq(directory.houses().length, 2, "still two houses");

        FallpitDirectory.HouseView memory none = directory.houseOf(bytes32(uint256(1)));
        assertEq(none.chip, address(0));
        assertEq(none.roundId, bytes32(0));
    }

    // -------------------------------------------------------------------------------------------- LPs

    function test_positionOf_depositsQueuesAndClaims_acrossARoll() public {
        (uint256 shares, uint256 assets, uint256 pending, uint256 queued, uint256 claimable) =
            directory.positionOf(lp, house);
        assertEq(shares, vault.balanceOf(lp, uint256(house)));
        assertGt(shares, 0);
        assertEq(assets, HOUSE_CAPITAL);
        assertEq(pending + queued + claimable, 0);

        _open();
        // during the round: a queued deposit by lp2, a queued withdrawal of half of lp's shares
        MockChip(address(chip)).mint(lp2, 50_000e18);
        vm.startPrank(lp2);
        chip.approve(address(vault), 50_000e18);
        vault.deposit(house, 50_000e18);
        vm.stopPrank();
        vm.prank(lp);
        vault.requestWithdraw(house, shares / 2);

        (uint256 s2, uint256 a2, uint256 p2, uint256 q2, uint256 c2) = directory.positionOf(lp2, house);
        assertEq(s2, 0);
        assertEq(a2, 0);
        assertEq(p2, 50_000e18, "waiting in the deposit queue");
        assertEq(q2 + c2, 0);
        (shares, assets, pending, queued, claimable) = directory.positionOf(lp, house);
        assertEq(queued, vault.balanceOf(address(vault), uint256(house)), "the queued half");
        assertEq(shares + queued, vault.totalSupply(uint256(house)));
        assertEq(claimable, 0);

        // the round ends flat and the next one opens: the queues are processed at that moment
        _closeAndFinalize(S0);
        day += 1;
        _open();
        (s2, a2, p2, q2, c2) = directory.positionOf(lp2, house);
        assertGt(s2, 0, "minted for the processed deposit");
        assertApproxEqAbs(a2, 50_000e18, 1e6);
        assertEq(p2, 0);
        (shares, assets, pending, queued, claimable) = directory.positionOf(lp, house);
        assertEq(queued, 0);
        assertApproxEqAbs(claimable, HOUSE_CAPITAL / 2, 1e6, "the processed withdrawal");
        vm.prank(lp);
        assertEq(vault.claim(house), claimable, "what claim pays");
        (,,,, claimable) = directory.positionOf(lp, house);
        assertEq(claimable, 0);
    }

    /// @dev What the lists cost: the write on `createHouse` and the read per house. The figures quoted in
    ///      FallpitDirectory's note.
    function test_gas_discoveryLists() public {
        MockChip c2 = new MockChip(18);
        vm.prank(owner);
        guard.approve(address(c2), true);
        uint256 g = gasleft();
        _createHouse(TSLA, address(c2));
        uint256 createHouse = g - gasleft();
        _use(NVDA, address(chip));
        _open();
        g = gasleft();
        FallpitDirectory.HouseView[] memory list = directory.houses();
        uint256 read = g - gasleft();
        g = gasleft();
        directory.tickers();
        uint256 tickersRead = g - gasleft();
        g = gasleft();
        directory.nextOpenableDay(NVDA);
        uint256 next = g - gasleft();
        console.log("createHouse with its list entry", createHouse);
        console.log("houses() of 2 houses, one with a round", read);
        console.log("tickers() of 2 tickers", tickersRead);
        console.log("nextOpenableDay", next);
        assertEq(list.length, 2);
        assertLt(read / list.length, 75_000, "an eth_call reads hundreds of houses (all cold here)");
    }

    // ----------------------------------------------------------------------------- next openable day

    function test_nextOpenableDay_afterAClose_isTheNextTradingDay_andOpenRoundAgrees() public {
        (uint32 d, uint64 openTs, uint64 closeTs, bool openable) = _next(NVDA);
        assertEq(d, day, "Tuesday, from Monday's close");
        assertEq(openTs, NYTime.closeTs(day0));
        assertEq(closeTs, NYTime.closeTs(day));
        assertTrue(openable);
        // the hook agrees, and only for that day
        vm.expectRevert(IPitBook.NotNextTradingDay.selector);
        hook.openRound(NVDA, address(chip), day + 1);
        hook.openRound(NVDA, address(chip), d);
        // per ticker, not per house: still Tuesday while Tuesday trades
        (d,,, openable) = _next(NVDA);
        assertEq(d, day);
        assertTrue(openable);
    }

    function test_nextOpenableDay_pastTheCutoff_waitsForTheClose() public {
        _warp(NYTime.closeTs(day) - 600); // 15:50, past the 15:49:30 cutoff, nothing opened today
        (uint32 d, uint64 openTs, uint64 closeTs, bool openable) = _next(NVDA);
        assertEq(d, day + 1, "Wednesday");
        assertEq(openTs, NYTime.closeTs(day), "once Tuesday's close is in");
        assertEq(closeTs, NYTime.closeTs(day + 1));
        assertFalse(openable);
        vm.expectRevert(IFallpitHook.TooLate.selector);
        hook.openRound(NVDA, address(chip), day);
        vm.expectRevert(IPitBook.NotNextTradingDay.selector);
        hook.openRound(NVDA, address(chip), day + 1);

        // Tuesday's close: Wednesday opens
        _recordClose(S0, KEEPER_SOURCE);
        (d, openTs,, openable) = _next(NVDA);
        assertEq(d, day + 1);
        assertEq(openTs, NYTime.closeTs(day));
        assertTrue(openable);
        hook.openRound(NVDA, address(chip), d);
    }

    function test_nextOpenableDay_aMissedClose_opensTheDayAfter() public {
        // Tuesday's close is never recorded; 12 hours later it is missed
        _warp(NYTime.closeTs(day) + 12 hours);
        (uint32 d,,, bool openable) = _next(NVDA);
        assertEq(d, day + 1);
        assertFalse(openable, "not missed yet");
        _warp(NYTime.closeTs(day) + 12 hours + 1);
        uint64 openTs;
        (d, openTs,, openable) = _next(NVDA);
        assertEq(d, day + 1, "Wednesday, from Monday's close");
        assertEq(openTs, NYTime.closeTs(day0));
        assertTrue(openable);
        hook.openRound(NVDA, address(chip), d);
    }

    function test_nextOpenableDay_weekendSkipsAndEveryDay() public {
        // an every-day ticker beside the stock
        vm.startPrank(owner);
        _addTickerOn(ETH, ETH_ID, IPitBook.Clock.EveryDay, IPitBook.FillSource.TrustlessOnly);
        vm.stopPrank();
        _closeOf(ETH, day0, 2_400e18);
        // closes Tuesday to Friday for both
        for (uint32 d = day0 + 1; d <= day0 + 4; ++d) {
            _closeOf(NVDA, d, S0);
            _closeOf(ETH, d, 2_400e18);
        }
        uint32 friday = day0 + 4;
        (uint32 n, uint64 openTs,, bool openable) = _next(NVDA);
        assertEq(n, friday + 3, "Monday after the weekend");
        assertEq(openTs, NYTime.closeTs(friday));
        assertTrue(openable);
        (n,,, openable) = _next(ETH);
        assertEq(n, friday + 1, "Saturday for ETH");
        assertTrue(openable);

        // Monday skipped (announced more than 24 hours ahead): Tuesday
        vm.prank(owner);
        book.setSkip(NVDA, friday + 3, true);
        (n, openTs,, openable) = _next(NVDA);
        assertEq(n, friday + 4);
        assertEq(openTs, NYTime.closeTs(friday));
        assertTrue(openable);
        vm.expectRevert(IPitBook.NotTradingDay.selector);
        hook.openRound(NVDA, address(chip), friday + 3);
        hook.openRound(NVDA, address(chip), n);

        // Monday 15:50, past its cutoff: still Tuesday (Monday is skipped, no round of it is lost)
        _warp(NYTime.closeTs(friday + 3) - 600);
        (n,,, openable) = _next(NVDA);
        assertEq(n, friday + 4);
        assertTrue(openable);
    }

    function test_nextOpenableDay_zeroWhenPausedUnknownOrWithoutClose() public {
        vm.prank(owner);
        book.setPaused(true);
        (uint32 d, uint64 openTs, uint64 closeTs, bool openable) = _next(NVDA);
        assertEq(d, 0);
        assertEq(openTs, 0);
        assertEq(closeTs, 0);
        assertFalse(openable);
        vm.prank(owner);
        book.setPaused(false);
        (d,,, openable) = _next(NVDA);
        assertEq(d, day);
        assertTrue(openable);

        (d,,, openable) = _next(bytes32("NOPE"));
        assertEq(d, 0);
        assertFalse(openable);

        // registered and live, but no close recorded yet
        vm.startPrank(owner);
        _addTickerOn(ETH, ETH_ID, IPitBook.Clock.EveryDay, IPitBook.FillSource.TrustlessOnly);
        vm.stopPrank();
        (d,,, openable) = _next(ETH);
        assertEq(d, 0);
        assertFalse(openable);
    }
}
