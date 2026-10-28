// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StackFixture} from "./StackFixture.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice Anyone may record a close only for three days after its instant and never for a day before the
///         newest recorded close. The variance moves only when the recorded day is the next trading day after
///         the newest close; closes the owner seeds never move it. Cherry-picked old closes cannot walk the
///         variance before a round opens.
contract VarianceStepsTest is StackFixture {
    bytes32 internal constant TSLA = bytes32("TSLA");
    bytes32 internal constant GME = bytes32("GME");
    uint256 internal constant SEED = 0.0004e18; // the owner's seed: sigma = 2%

    address internal lp = makeAddr("lp");
    address internal eve = makeAddr("eve");

    function _register(bytes32 ticker) internal returns (bytes32 house_) {
        return _registerOn(ticker, IPitBook.Clock.NYWeekdays);
    }

    function _registerOn(bytes32 ticker, IPitBook.Clock kind) internal returns (bytes32 house_) {
        oracle.setSupported(ticker, true);
        // registered a day ago: a new ticker is in force 24 hours after its registration
        vm.warp(clock - 24 hours);
        vm.prank(owner);
        book.registerTicker(
            ticker, SEED, kind, IPitBook.Weights(0, 0, 0, 0), 0, IPitBook.FillSource.KeeperOnly
        );
        vm.warp(clock);
        house_ = vault.createHouse(ticker, address(chip));
        chip.mint(lp, 1_000_000e18);
        vm.startPrank(lp);
        chip.approve(address(vault), 1_000_000e18);
        vault.deposit(house_, 1_000_000e18);
        vm.stopPrank();
    }

    function _record(address who, bytes32 ticker, uint32 d, uint256 price) internal {
        oracle.set(ticker, TRUSTLESS, NYTime.closeTs(d), price);
        vm.prank(who);
        book.recordClose(ticker, d, abi.encode(TRUSTLESS));
    }

    /// @dev Sigma pushed down: a chain of 40 old days whose closes sit at about the same
    ///      level, each one a "daily return" of about zero.
    function test_variance_cherryPickedOldCloses_areRefused() public {
        _register(TSLA);
        uint32 d = uint32(NYTime.daysFromCivil(2026, 6, 1));
        for (uint256 n; n < 40; ++d) {
            if (!NYTime.isWeekday(d)) continue;
            oracle.set(TSLA, TRUSTLESS, NYTime.closeTs(d), n % 2 == 0 ? 250e18 : 250.25e18);
            vm.prank(eve);
            vm.expectRevert(IPitBook.CloseTooOld.selector);
            book.recordClose(TSLA, d, abi.encode(TRUSTLESS));
            ++n;
        }
        assertEq(book.getTicker(TSLA).lastCloseDay, 0, "none of them is on the book");

        // yesterday's close is fresh: eve records it and opens the round, on the seeded sigma
        _record(eve, TSLA, day0, 250e18);
        vm.prank(eve);
        bytes32 round = hook.openRound(TSLA, address(chip), day);
        assertEq(hook.getConfig(round).sigma, 0.02e18, "sigma is the owner's seed");
        assertEq(book.getTicker(TSLA).varWad, SEED);
    }

    /// @dev The same 40 closes recorded by the owner (seeding a new ticker's history) are stored and
    ///      leave the variance alone: an old close is never a step, whoever records it.
    function test_variance_ownerSeedingOldCloses_doesNotMoveTheVariance() public {
        _register(TSLA);
        uint32 d = uint32(NYTime.daysFromCivil(2026, 6, 1));
        for (uint256 n; n < 40; ++d) {
            if (!NYTime.isWeekday(d)) continue;
            _record(owner, TSLA, d, n % 2 == 0 ? 250e18 : 250.25e18);
            ++n;
        }
        assertEq(book.getTicker(TSLA).varWad, SEED, "forty consecutive old closes: no step");
        assertGt(book.getTicker(TSLA).lastCloseDay, 0);
        _record(eve, TSLA, day0, 250e18);
        assertEq(book.getTicker(TSLA).varWad, SEED, "and the jump from August to yesterday is no step");
        bytes32 round = hook.openRound(TSLA, address(chip), day);
        assertEq(hook.getConfig(round).sigma, 0.02e18);
    }

    /// @dev Sigma pushed up: one old close far from today's price, the gap booked as one
    ///      daily return.
    function test_variance_oneOldClose_cannotInflateSigma() public {
        _register(GME);
        uint32 june1 = uint32(NYTime.daysFromCivil(2026, 6, 1));
        // GME closed at 20 some months ago and at 27 yesterday.
        oracle.set(GME, TRUSTLESS, NYTime.closeTs(june1), 20e18);
        vm.prank(eve);
        vm.expectRevert(IPitBook.CloseTooOld.selector);
        book.recordClose(GME, june1, abi.encode(TRUSTLESS));
        // even with the old close on the book (seeded by the owner), yesterday's is not a one-day step
        _record(owner, GME, june1, 20e18);
        _record(eve, GME, day0, 27e18);
        vm.prank(eve);
        bytes32 round = hook.openRound(GME, address(chip), day);
        assertEq(hook.getConfig(round).sigma, 0.02e18, "sigma is still the seed");
    }

    /// @dev With the newest close two trading days old, whoever records next cannot choose which days to
    ///      skip: a day without a recorded close is not a step.
    function test_variance_skippingADay_isNoStep() public {
        _register(GME);
        _record(eve, GME, day0, 27e18);
        // Tuesday's close (a 20% move) is left out; Wednesday's is recorded on Wednesday evening
        _warp(NYTime.closeTs(day + 1) + 5);
        _record(eve, GME, day + 1, 33e18);
        // the two-day gap is a step over two trading days: the squared
        // return halved, and capped at 16 variances (this 20% move hits the cap)
        uint256 stepped = _ewmaOver(SEED, 27e18, 33e18, 2);
        assertEq(book.getTicker(GME).varWad, stepped, "the two-day gap is booked as two days, capped");
        // and Tuesday's close is now the owner's to add; it does not move the variance
        oracle.set(GME, TRUSTLESS, NYTime.closeTs(day), 32.4e18);
        vm.prank(eve);
        vm.expectRevert(IPitBook.CloseTooOld.selector);
        book.recordClose(GME, day, abi.encode(TRUSTLESS));
        _record(owner, GME, day, 32.4e18);
        assertEq(book.getTicker(GME).varWad, stepped);
    }

    function _ewmaOver(uint256 v, uint256 prev, uint256 close, uint256 n) internal pure returns (uint256) {
        int256 r = FixedPointMathLib.lnWad(int256(close * 1e18 / prev));
        uint256 sq = uint256(r * r) / 1e18 / n;
        if (sq > 16 * v) sq = 16 * v;
        return (94 * v + 6 * sq) / 100;
    }

    /// @dev The same rules on the every-day clock. An asset that trades
    ///      around the clock has a close every calendar day, so "the next round's day" is the next
    ///      calendar day: Saturday and Sunday are steps like any other day, and nothing else is. The
    ///      attempts of the stock tests are refused in the same way, and a calendar day without a
    ///      recorded close is never stepped over.
    function test_variance_everyDayClock_stepsOnConsecutiveCalendarDaysOnly() public {
        bytes32 eth = bytes32("ETH");
        _registerOn(eth, IPitBook.Clock.EveryDay);
        // cherry-picked old closes, weekends among them: refused
        uint32 june1 = uint32(NYTime.daysFromCivil(2026, 6, 1));
        for (uint32 n; n < 40; ++n) {
            oracle.set(eth, TRUSTLESS, NYTime.closeTs(june1 + n), n % 2 == 0 ? 4_000e18 : 4_004e18);
            vm.prank(eve);
            vm.expectRevert(IPitBook.CloseTooOld.selector);
            book.recordClose(eth, june1 + n, abi.encode(TRUSTLESS));
        }
        // the owner seeds one of them; the jump from June to yesterday is no step
        _record(owner, eth, june1, 2_500e18);
        _record(eve, eth, day0, 4_000e18);
        assertEq(book.getTicker(eth).varWad, SEED, "an old close is never a step");

        // Tuesday to Friday, then Saturday and Sunday: one step a day
        uint256 variance = SEED;
        uint32 sunday = day0 + 6;
        assertFalse(NYTime.isWeekday(sunday));
        for (uint32 d = day; d <= sunday; ++d) {
            _warp(NYTime.closeTs(d) + 5);
            _record(eve, eth, d, 4_000e18);
            variance = variance * 94 / 100;
            assertEq(book.getTicker(eth).varWad, variance, "a flat day: 0.94 of the variance");
            assertTrue(book.getTicker(eth).lastCloseStepped);
        }

        // Monday's close (a 15% move) is left out; Tuesday's is recorded: a step over two days
        _warp(NYTime.closeTs(sunday + 2) + 5);
        _record(eve, eth, sunday + 2, 4_700e18);
        variance = _ewmaOver(variance, 4_000e18, 4_700e18, 2);
        assertEq(book.getTicker(eth).varWad, variance, "the gap is booked as two daily returns");
        // Monday's close is the owner's to add now; it moves nothing either
        oracle.set(eth, TRUSTLESS, NYTime.closeTs(sunday + 1), 4_600e18);
        vm.prank(eve);
        vm.expectRevert(IPitBook.CloseTooOld.selector);
        book.recordClose(eth, sunday + 1, abi.encode(TRUSTLESS));
        _record(owner, eth, sunday + 1, 4_600e18);
        assertEq(book.getTicker(eth).varWad, variance);

        // and the round that opens next is the next calendar day's, on the seeded sigma
        vm.expectRevert(IPitBook.NotNextTradingDay.selector);
        hook.openRound(eth, address(chip), sunday + 4);
        bytes32 round = hook.openRound(eth, address(chip), sunday + 3);
        assertEq(hook.getConfig(round).sigma, FixedPointMathLib.sqrtWad(variance));
    }
}
