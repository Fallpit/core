// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {HookFixture} from "./HookFixture.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice Closes, the EWMA variance and the calendar rules of the book.
contract PitBookTest is HookFixture {
    uint256 internal constant MIN_VAR = 0.000025e18; // 0.005^2
    uint256 internal constant MAX_VAR = 0.0225e18; // 0.15^2

    event CloseRecorded(
        bytes32 indexed ticker, uint32 indexed day, uint256 price, bool trustless, uint256 varWad
    );

    function _closeOn(uint32 d, uint256 price, uint8 source) internal {
        uint64 closeAt = NYTime.closeTs(d);
        if (clock < closeAt) _warp(closeAt);
        book.recordClose(NVDA, d, oracle.post(NVDA, source, price, closeAt));
    }

    function _ewma(uint256 varWad, uint256 previous, uint256 close) internal pure returns (uint256) {
        return _ewmaOver(varWad, previous, close, 1);
    }

    /// @dev The book's step over `n` trading days: the squared return divided by `n`, capped at 16
    ///      variances.
    function _ewmaOver(uint256 varWad, uint256 previous, uint256 close, uint256 n)
        internal
        pure
        returns (uint256)
    {
        int256 r = FixedPointMathLib.lnWad(int256(close * 1e18 / previous));
        uint256 sq = uint256(r * r) / 1e18 / n;
        if (sq > 16 * varWad) sq = 16 * varWad;
        return (94 * varWad + 6 * sq) / 100;
    }

    /// @dev The owner marks a day skipped, a week ahead of now (the book wants 24 hours' notice).
    function _skipEarly(bytes32 ticker, uint32 d) internal {
        vm.warp(clock - 7 days);
        vm.prank(owner);
        book.setSkip(ticker, d, true);
        vm.warp(clock);
    }

    function test_setUp_firstCloseSeedsNothing() public view {
        IPitBook.Ticker memory tk = book.getTicker(NVDA);
        assertEq(tk.varWad, SEED_VAR, "the first close has no return to learn from");
        assertEq(tk.lastCloseDay, day0);
        assertEq(tk.prevCloseDay, 0);
        (uint256 price, bool trustless) = book.closeOf(NVDA, day0);
        assertEq(price, S0);
        assertTrue(trustless);
    }

    function test_recordClose_rules() public {
        bytes memory report = oracle.post(NVDA, KEEPER, S0, NYTime.closeTs(day));
        // one second before the close instant
        _warp(NYTime.closeTs(day) - 1);
        vm.expectRevert(IPitBook.TooEarly.selector);
        book.recordClose(NVDA, day, report);
        _warp(NYTime.closeTs(day));
        vm.expectRevert(IPitBook.NotTradingDay.selector);
        book.recordClose(NVDA, day0 + 5, report); // Saturday
        vm.expectRevert(IPitBook.UnknownTicker.selector);
        book.recordClose(bytes32("TSLA"), day, report);
        // a print for another instant is not the close (a close may be up to 300 s late, not 301)
        bytes memory other = oracle.post(NVDA, TRUSTLESS, S0, NYTime.closeTs(day) + 301);
        vm.expectRevert();
        book.recordClose(NVDA, day, other);
        // a zero price is refused
        _warp(NYTime.closeTs(day + 1));
        bytes memory zero = oracle.post(NVDA, KEEPER, 0, NYTime.closeTs(day + 1));
        vm.expectRevert(IPitBook.BadPrice.selector);
        book.recordClose(NVDA, day + 1, zero);

        // anyone records; the event carries the new variance
        uint256 expected = _ewma(SEED_VAR, S0, S0);
        vm.expectEmit(true, true, false, true, address(book));
        emit CloseRecorded(NVDA, day, S0, false, expected);
        vm.prank(alice);
        book.recordClose(NVDA, day, report);
    }

    function test_ewma_updatesFromThePreviousClose() public {
        uint256 close1 = S0 * 103 / 100;
        _closeOn(day, close1, TRUSTLESS);
        uint256 var1 = _ewma(SEED_VAR, S0, close1);
        IPitBook.Ticker memory tk = book.getTicker(NVDA);
        assertEq(tk.varWad, var1);
        assertEq(tk.varBefore, SEED_VAR);
        assertEq(tk.lastCloseDay, day);
        assertEq(tk.prevCloseDay, day0);
        assertGt(var1, SEED_VAR, "a 3% day raises a 2% volatility");

        uint256 close2 = close1 * 999 / 1000;
        _closeOn(day + 1, close2, TRUSTLESS);
        uint256 var2 = _ewma(var1, close1, close2);
        assertEq(book.getTicker(NVDA).varWad, var2);
        assertLt(var2, var1, "a quiet day lowers it");

        // the next round's sigma is the square root of the variance
        (uint256 s0, uint256 sigma,,,) = book.openTerms(NVDA, day + 2);
        assertEq(s0, close2);
        assertEq(sigma, FixedPointMathLib.sqrtWad(var2));
    }

    function test_ewma_clamped() public {
        // a 40% crash: clamped to 0.15^2 (the reseeds were announced a day ahead, see `_reseed`)
        _reseed(
            NVDA,
            MAX_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.KeeperOnly
        );
        _closeOn(day, S0 * 60 / 100, TRUSTLESS);
        assertEq(book.getTicker(NVDA).varWad, MAX_VAR);
        // flat days from the floor stay at the floor
        _reseed(
            NVDA,
            MIN_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.KeeperOnly
        );
        _closeOn(day + 1, S0 * 60 / 100, TRUSTLESS);
        assertEq(book.getTicker(NVDA).varWad, MIN_VAR);
    }

    function test_trustlessReplacement_redoesTheUpdate_once() public {
        uint256 keeperClose = S0 * 104 / 100;
        uint256 trueClose = S0 * 101 / 100;
        _closeOn(day, keeperClose, KEEPER);
        assertEq(book.getTicker(NVDA).varWad, _ewma(SEED_VAR, S0, keeperClose));
        (, bool trustless) = book.closeOf(NVDA, day);
        assertFalse(trustless);

        _closeOn(day, trueClose, TRUSTLESS);
        IPitBook.Ticker memory tk = book.getTicker(NVDA);
        assertEq(
            tk.varWad, _ewma(SEED_VAR, S0, trueClose), "the update is redone from the variance before it"
        );
        assertEq(tk.lastCloseDay, day);
        assertEq(tk.prevCloseDay, day0);
        (uint256 price, bool nowTrustless) = book.closeOf(NVDA, day);
        assertEq(price, trueClose);
        assertTrue(nowTrustless);
    }

    /// @dev A close that
    ///      follows a missed weekday steps the variance with its return spread over the trading days it
    ///      spans (Tuesday missed: Monday to Wednesday is two days), and a close older than the newest
    ///      one is the owner's to record, without a step.
    function test_olderClose_isStoredWithoutTouchingTheVariance() public {
        // Tuesday's close is missed; Wednesday's is recorded first
        _closeOn(day + 1, S0 * 102 / 100, TRUSTLESS);
        IPitBook.Ticker memory tk = book.getTicker(NVDA);
        uint256 v = _ewmaOver(SEED_VAR, S0, S0 * 102 / 100, 2);
        assertEq(tk.varWad, v, "a two-day return booked as two days");
        assertEq(tk.lastCloseDay, day + 1);
        assertTrue(tk.lastCloseStepped);

        // Tuesday's close cannot be recorded by just anyone
        bytes memory tuesday = oracle.post(NVDA, KEEPER, S0 * 101 / 100, NYTime.closeTs(day));
        vm.prank(alice);
        vm.expectRevert(IPitBook.CloseTooOld.selector);
        book.recordClose(NVDA, day, tuesday);
        // the owner fills the gap; the variance and the newest close stay as they are
        vm.prank(owner);
        book.recordClose(NVDA, day, tuesday);
        (uint256 price,) = book.closeOf(NVDA, day);
        assertEq(price, S0 * 101 / 100);
        tk = book.getTicker(NVDA);
        assertEq(tk.varWad, v);
        assertEq(tk.lastCloseDay, day + 1);

        // from here the chain is whole again: Thursday is a one-day step from Wednesday
        _closeOn(day + 2, S0 * 103 / 100, TRUSTLESS);
        assertEq(book.getTicker(NVDA).varWad, _ewma(v, S0 * 102 / 100, S0 * 103 / 100));
    }

    /// @dev Anyone may record a close for three days after its instant, not later.
    function test_recordClose_staleCloses_areTheOwnersOnly() public {
        uint64 closeAt = NYTime.closeTs(day);
        bytes memory report = oracle.post(NVDA, TRUSTLESS, S0 * 13 / 10, closeAt);
        _warp(closeAt + 3 days + 1);
        vm.prank(alice);
        vm.expectRevert(IPitBook.CloseTooOld.selector);
        book.recordClose(NVDA, day, report);

        // the owner may still seed it, and a stale close never moves the variance, whatever it says
        vm.prank(owner);
        book.recordClose(NVDA, day, report);
        IPitBook.Ticker memory tk = book.getTicker(NVDA);
        assertEq(tk.lastCloseDay, day);
        assertEq(tk.varWad, SEED_VAR, "a 30% print recorded late is stored, not booked as a return");

        // exactly at the end of the window anyone still can
        uint32 friday = day0 + 4;
        uint64 fridayClose = NYTime.closeTs(friday);
        bytes memory fresh = oracle.post(NVDA, TRUSTLESS, S0, fridayClose);
        _warp(fridayClose + 3 days);
        vm.prank(alice);
        book.recordClose(NVDA, friday, fresh);
        assertEq(book.getTicker(NVDA).lastCloseDay, friday);
    }

    /// @dev Every step is the return per trading day it spans. A weekend is
    ///      inside the daily EWMA (close to close); a missed or skipped weekday is one more day.
    function test_variance_movesOnlyOnAOneDayStep() public {
        // Tuesday: a step
        _closeOn(day, S0 * 101 / 100, TRUSTLESS);
        uint256 v1 = _ewma(SEED_VAR, S0, S0 * 101 / 100);
        assertEq(book.getTicker(NVDA).varWad, v1);
        assertTrue(book.getTicker(NVDA).lastCloseStepped);
        // Thursday with Wednesday missing: the 9% move is spread over two days
        _closeOn(day + 2, S0 * 110 / 100, TRUSTLESS);
        uint256 v2 = _ewmaOver(v1, S0 * 101 / 100, S0 * 110 / 100, 2);
        assertEq(book.getTicker(NVDA).varWad, v2);
        // Friday: one day from Thursday's close
        _closeOn(day + 3, S0 * 111 / 100, TRUSTLESS);
        uint256 v3 = _ewma(v2, S0 * 110 / 100, S0 * 111 / 100);
        assertEq(book.getTicker(NVDA).varWad, v3);
        // Monday after the weekend: one day (only a weekend in between)
        _closeOn(day + 6, S0 * 112 / 100, TRUSTLESS);
        uint256 v4 = _ewma(v3, S0 * 111 / 100, S0 * 112 / 100);
        assertEq(book.getTicker(NVDA).varWad, v4);
        // a skipped weekday in between counts as a trading day of the step
        _skipEarly(NVDA, day + 7);
        _closeOn(day + 8, S0 * 113 / 100, TRUSTLESS);
        assertEq(book.getTicker(NVDA).varWad, _ewmaOver(v4, S0 * 112 / 100, S0 * 113 / 100, 2));
    }

    /// @dev A keeper close that did not step the variance is not "redone" into a step when a
    ///      trustless print replaces it. (A close recorded after its three-day window, by the owner, does
    ///      not step.)
    function test_trustlessReplacement_ofACloseThatDidNotStep_doesNotStepEither() public {
        uint64 closeAt = NYTime.closeTs(day);
        bytes memory late = oracle.post(NVDA, KEEPER, S0 * 104 / 100, closeAt);
        _warp(closeAt + 3 days + 1);
        vm.prank(owner);
        book.recordClose(NVDA, day, late);
        assertEq(book.getTicker(NVDA).varWad, SEED_VAR);
        assertFalse(book.getTicker(NVDA).lastCloseStepped);
        bytes memory pyth = oracle.post(NVDA, TRUSTLESS, S0 * 101 / 100, closeAt);
        vm.prank(owner);
        book.recordClose(NVDA, day, pyth);
        assertEq(book.getTicker(NVDA).varWad, SEED_VAR);
        (uint256 price, bool trustless) = book.closeOf(NVDA, day);
        assertEq(price, S0 * 101 / 100);
        assertTrue(trustless);
    }

    /// @dev New default parameters reach only rounds opened 24 hours after they were announced.
    function test_defaultParams_takeEffectAfter24Hours() public {
        IPitBook.Params memory p = book.defaultParams();
        p.baseFee = 0.05e18;
        p.maxFillBps = 500;
        uint64 eta = clock + 24 hours;
        vm.expectEmit(false, false, false, true, address(book));
        emit IPitBook.DefaultParamsSet(p, eta);
        vm.prank(owner);
        book.setDefaultParams(p);
        assertEq(book.defaultParams().maxFillBps, 200, "nothing changes now");
        (,,,, IPitBook.Params memory terms) = book.openTerms(NVDA, day);
        assertEq(terms.baseFee, 0.02e18);
        (IPitBook.Params memory pending, uint64 pendingEta) = book.pendingDefaultParams();
        assertEq(pending.maxFillBps, 500);
        assertEq(pendingEta, eta);

        _warp(eta - 1);
        assertEq(book.defaultParams().maxFillBps, 200);
        // a second announcement replaces the first and restarts the clock
        p.maxFillBps = 300;
        vm.prank(owner);
        book.setDefaultParams(p);
        _warp(eta);
        assertEq(book.defaultParams().maxFillBps, 200, "the replaced set never comes into force");
        _warp(eta - 1 + 24 hours);
        assertEq(book.defaultParams().maxFillBps, 300);
        assertEq(book.defaultParams().baseFee, 0.05e18);
        (, pendingEta) = book.pendingDefaultParams();
        assertEq(pendingEta, 0);
        // a set that is in force is not lost when the next one is announced
        p.maxFillBps = 400;
        vm.prank(owner);
        book.setDefaultParams(p);
        assertEq(book.defaultParams().maxFillBps, 300);
    }

    /// @dev A reseed of a registered ticker waits 24 hours; so does a new ticker.
    function test_reseed_takesEffectAfter24Hours() public {
        uint64 eta = clock + 24 hours;
        vm.expectEmit(true, false, false, true, address(book));
        IPitBook.Weights memory flat = IPitBook.Weights(0, 0, 0, 10_000);
        // (the reseed also switches the nights on: windows 15)
        emit IPitBook.TickerRegistered(
            NVDA, MAX_VAR, IPitBook.Clock.NYWeekdays, flat, 15, IPitBook.FillSource.TrustlessOnly, eta
        );
        vm.prank(owner);
        book.registerTicker(
            NVDA, MAX_VAR, IPitBook.Clock.NYWeekdays, flat, 15, IPitBook.FillSource.TrustlessOnly
        );
        IPitBook.Ticker memory tk = book.getTicker(NVDA);
        assertEq(tk.varWad, SEED_VAR);
        assertEq(tk.weights.regular, 7000);
        assertEq(tk.windows, 13, "no nights yet");
        assertEq(book.pendingReseed(NVDA).windows, 15);
        assertEq(uint8(tk.fillSource), uint8(IPitBook.FillSource.KeeperOnly));
        (, uint256 sigma, IPitBook.RoundClock memory rc, IPitBook.FillSource source,) =
            book.openTerms(NVDA, day);
        assertEq(sigma, 0.02e18, "a round opened now is priced on the old seed");
        assertEq(rc.regular, 7000, "and runs on the old clock weights");
        assertEq(rc.windows, 13, "and trades the old windows");
        assertEq(uint8(source), uint8(IPitBook.FillSource.KeeperOnly));
        assertEq(book.pendingReseed(NVDA).eta, eta);

        // a close recorded in the meantime steps the old variance; the reseed then replaces it
        _closeOn(day, S0 * 101 / 100, TRUSTLESS);
        assertEq(book.getTicker(NVDA).varWad, _ewma(SEED_VAR, S0, S0 * 101 / 100));
        _warp(eta);
        tk = book.getTicker(NVDA);
        assertEq(tk.varWad, MAX_VAR);
        assertEq(tk.weights.regular, 10_000);
        assertEq(tk.weights.afterHours, 0);
        assertEq(tk.windows, 15, "the nights are switched on a day after the owner said so");
        assertEq(uint8(tk.fillSource), uint8(IPitBook.FillSource.TrustlessOnly));
        assertEq(book.pendingReseed(NVDA).eta, 0);
        (, sigma, rc, source,) = book.openTerms(NVDA, day + 1);
        assertEq(sigma, 0.15e18);
        assertEq(rc.regular, 10_000);
        assertEq(rc.windows, 15);
        // and the next close steps the reseeded variance
        _closeOn(day + 1, S0 * 101 / 100, TRUSTLESS);
        assertEq(book.getTicker(NVDA).varWad, _ewma(MAX_VAR, S0 * 101 / 100, S0 * 101 / 100));

        // a new ticker waits 24 hours too: its registration is visible, nothing can use it yet
        bytes32 tsla = bytes32("TSLA");
        oracle.setSupported(tsla, true);
        vm.prank(owner);
        book.registerTicker(
            tsla,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        uint64 tslaEta = clock + 24 hours;
        assertEq(book.getTicker(tsla).varWad, 0, "not in force");
        assertEq(book.pendingReseed(tsla).eta, tslaEta, "the pending registration");
        assertEq(book.pendingReseed(tsla).varWad, SEED_VAR);
        assertFalse(book.supported(tsla), "no house for it yet");
        uint32 tslaDay = NYTime.isWeekday(day + 2) ? day + 2 : day + 4;
        bytes memory early = oracle.post(tsla, TRUSTLESS, S0, NYTime.closeTs(day + 1) + 1);
        vm.expectRevert(IPitBook.UnknownTicker.selector);
        book.recordClose(tsla, day + 1, early);
        vm.expectRevert(IPitBook.UnknownTicker.selector);
        book.openTerms(tsla, tslaDay);
        _warp(tslaEta);
        assertEq(book.getTicker(tsla).varWad, SEED_VAR);
        assertTrue(book.supported(tsla));
        assertEq(book.pendingReseed(tsla).eta, 0);
    }

    function test_openTerms_longWeekend() public {
        // Friday's close is the newest; Monday is a holiday
        uint32 friday = day0 + 4;
        uint32 monday = friday + 3;
        uint32 tuesday = friday + 4;
        _closeOn(day, S0, TRUSTLESS);
        _closeOn(day + 1, S0, TRUSTLESS);
        _closeOn(day + 2, S0, TRUSTLESS);
        _closeOn(friday, S0 * 102 / 100, TRUSTLESS);

        // Monday opens on Friday's close; Tuesday cannot be opened ahead of Monday
        (uint256 s0,,,,) = book.openTerms(NVDA, monday);
        assertEq(s0, S0 * 102 / 100);
        vm.expectRevert(IPitBook.NotNextTradingDay.selector);
        book.openTerms(NVDA, tuesday);
        vm.expectRevert(IPitBook.NotTradingDay.selector);
        book.openTerms(NVDA, friday + 1);

        // with Monday marked as a holiday, Tuesday opens on Friday's close (4 calendar days back)
        _skipEarly(NVDA, monday);
        vm.expectRevert(IPitBook.NotTradingDay.selector);
        book.openTerms(NVDA, monday);
        (s0,,,,) = book.openTerms(NVDA, tuesday);
        assertEq(s0, S0 * 102 / 100);
        // Six days back are allowed, so the Monday after Thanksgiving (Wednesday close, Thursday and
        // Friday skipped) can open; seven are too old.
        _skipEarly(NVDA, tuesday);
        (s0,,,,) = book.openTerms(NVDA, tuesday + 1);
        assertEq(s0, S0 * 102 / 100, "five days back");
        _skipEarly(NVDA, tuesday + 1);
        (s0,,,,) = book.openTerms(NVDA, tuesday + 2);
        assertEq(s0, S0 * 102 / 100, "six days back");
        _skipEarly(NVDA, tuesday + 2);
        vm.expectRevert(IPitBook.NoRecentClose.selector);
        book.openTerms(NVDA, tuesday + 3);
    }

    function test_pause_stopsOnlyOpening() public {
        vm.prank(owner);
        book.setPaused(true);
        vm.expectRevert(IPitBook.OpeningPaused.selector);
        hook.openRound(NVDA, address(chip), day);
        // closes are still recorded while paused
        _closeOn(day, S0, TRUSTLESS);
        vm.prank(owner);
        book.setPaused(false);
        hook.openRound(NVDA, address(chip), day + 1);
    }

    // --------------------------------------------------------------------------------------------
    // clocks
    // --------------------------------------------------------------------------------------------

    bytes32 internal constant ETH = bytes32("ETH");

    /// @dev ETH on the every-day clock, registered a day ago (a new ticker is in force after 24 hours).
    function _registerEth() internal {
        oracle.setSupported(ETH, true);
        vm.warp(clock - 24 hours);
        vm.prank(owner);
        book.registerTicker(
            ETH,
            SEED_VAR,
            IPitBook.Clock.EveryDay,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        vm.warp(clock);
    }

    function _ethClose(uint32 d, uint256 price) internal {
        uint64 closeAt = NYTime.closeTs(d);
        if (clock < closeAt) _warp(closeAt);
        book.recordClose(ETH, d, oracle.post(ETH, TRUSTLESS, price, closeAt));
    }

    function test_registerTicker_clockAndWeights() public {
        // all-zero weights: the defaults of the clock, written out
        IPitBook.Ticker memory tk = book.getTicker(NVDA);
        assertEq(uint8(tk.clock), uint8(IPitBook.Clock.NYWeekdays));
        assertEq(tk.weights.afterHours, 600);
        assertEq(tk.weights.gap, 1400);
        assertEq(tk.weights.preMarket, 1000);
        assertEq(tk.weights.regular, 7000);
        IPitBook.Weights memory w = book.defaultWeights(IPitBook.Clock.NYWeekdays);
        assertEq(uint256(w.afterHours) + w.gap + w.preMarket + w.regular, 10_000);

        oracle.setSupported(ETH, true);
        vm.expectEmit(true, false, false, true, address(book));
        emit IPitBook.TickerRegistered(
            ETH,
            SEED_VAR,
            IPitBook.Clock.EveryDay,
            IPitBook.Weights(0, 0, 0, 10_000),
            15,
            IPitBook.FillSource.TrustlessOnly,
            clock + 24 hours
        );
        vm.startPrank(owner);
        book.registerTicker(
            ETH,
            SEED_VAR,
            IPitBook.Clock.EveryDay,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        tk = book.getTicker(ETH);
        assertEq(tk.varWad, 0, "a new ticker is in force a day later");
        vm.warp(clock + 24 hours);
        tk = book.getTicker(ETH);
        assertEq(uint8(tk.clock), uint8(IPitBook.Clock.EveryDay));
        assertEq(tk.weights.regular, 10_000, "one segment");
        assertEq(tk.weights.afterHours, 0);

        // an every-day clock has one segment: stock weights are refused
        bytes32 btc = bytes32("BTC");
        oracle.setSupported(btc, true);
        vm.expectRevert(IPitBook.BadParams.selector);
        book.registerTicker(
            btc,
            SEED_VAR,
            IPitBook.Clock.EveryDay,
            IPitBook.Weights(600, 1400, 1000, 7000),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        // stock weights: any split that sums to 100% with at least a quarter in the regular session
        vm.expectRevert(IPitBook.BadParams.selector);
        book.registerTicker(
            btc,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(600, 1400, 1000, 6999),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        vm.expectRevert(IPitBook.BadParams.selector);
        book.registerTicker(
            btc,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(3000, 3000, 1501, 2499),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        book.registerTicker(
            btc,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(3000, 3000, 1500, 2500),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        // the clock is chosen once (once the registration is in force)
        vm.expectRevert(IPitBook.BadParams.selector);
        book.registerTicker(
            ETH,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        vm.stopPrank();
    }

    /// @dev Which windows of a stock round trade is a per-ticker mask (1 after-hours, 2 overnight, 4
    ///      pre-market, 8 regular session). Zero means the default, 13: everything but the nights.
    function test_registerTicker_tradingWindows() public {
        IPitBook.Weights memory none = IPitBook.Weights(0, 0, 0, 0);
        IPitBook.FillSource pythOnly = IPitBook.FillSource.TrustlessOnly;
        assertEq(book.getTicker(NVDA).windows, 13, "the default: after-hours, pre-market, regular");
        (,, IPitBook.RoundClock memory rc,,) = book.openTerms(NVDA, day);
        assertEq(rc.windows, 13);

        bytes32 qqq = bytes32("QQQ");
        oracle.setSupported(qqq, true);
        oracle.setSupported(ETH, true);
        vm.startPrank(owner);
        // the regular session is always in; nothing above the four bits
        vm.expectRevert(IPitBook.BadParams.selector);
        book.registerTicker(qqq, SEED_VAR, IPitBook.Clock.NYWeekdays, none, 7, pythOnly);
        vm.expectRevert(IPitBook.BadParams.selector);
        book.registerTicker(qqq, SEED_VAR, IPitBook.Clock.NYWeekdays, none, 16, pythOnly);
        // a ticker that trades the nights too, from its first round
        book.registerTicker(qqq, SEED_VAR, IPitBook.Clock.NYWeekdays, none, 15, pythOnly);
        assertEq(book.pendingReseed(qqq).windows, 15);
        // and one that trades the regular session only
        bytes32 gme = bytes32("GME");
        oracle.setSupported(gme, true);
        book.registerTicker(gme, SEED_VAR, IPitBook.Clock.NYWeekdays, none, 8, pythOnly);
        // an every-day asset trades around the clock: it has no mask to set
        vm.expectRevert(IPitBook.BadParams.selector);
        book.registerTicker(ETH, SEED_VAR, IPitBook.Clock.EveryDay, none, 13, pythOnly);
        book.registerTicker(ETH, SEED_VAR, IPitBook.Clock.EveryDay, none, 0, pythOnly);
        vm.stopPrank();
        // in force a day later
        vm.warp(clock + 24 hours);
        assertEq(book.getTicker(qqq).windows, 15);
        assertEq(book.getTicker(gme).windows, 8);
        assertEq(book.getTicker(ETH).windows, 15);
    }

    function test_skipAfterHours_ownerOnly_readWhenTheRoundOpens() public {
        vm.expectRevert(IPitBook.OnlyOwner.selector);
        book.setSkipAfterHours(NVDA, day, true);
        (,, IPitBook.RoundClock memory rc,,) = book.openTerms(NVDA, day);
        assertFalse(rc.skipAfterHours);
        assertEq(rc.prevDay, day0);
        assertEq(rc.day, day);

        vm.expectEmit(true, true, false, true, address(book));
        emit IPitBook.SkipAfterHoursSet(NVDA, day, true);
        vm.prank(owner);
        book.setSkipAfterHours(NVDA, day, true);
        assertTrue(book.skipAfterHours(NVDA, day));
        (,, rc,,) = book.openTerms(NVDA, day);
        assertTrue(rc.skipAfterHours, "immediate: the round that opens now carries the flag");
        // the flag belongs to one day
        _closeOn(day, S0, TRUSTLESS);
        (,, rc,,) = book.openTerms(NVDA, day + 1);
        assertFalse(rc.skipAfterHours);
        // the day itself still has its round: `skip` is the flag that takes that away
        assertFalse(book.skip(NVDA, day));
    }

    function test_everyDay_closesAndRoundsOnEveryCalendarDay() public {
        _registerEth();
        uint32 friday = day0 + 4;
        uint32 saturday = friday + 1;
        uint32 sunday = friday + 2;
        uint32 mondayNext = friday + 3;

        // a stock has no close on a Saturday; an every-day asset does
        _warp(NYTime.closeTs(saturday));
        bytes memory nvda = oracle.post(NVDA, TRUSTLESS, S0, NYTime.closeTs(saturday));
        vm.expectRevert(IPitBook.NotTradingDay.selector);
        book.recordClose(NVDA, saturday, nvda);
        _ethClose(saturday, 4_000e18);
        assertEq(book.getTicker(ETH).lastCloseDay, saturday);

        // Sunday's round opens on Saturday's close; Monday's cannot be opened ahead of it
        (uint256 s0,, IPitBook.RoundClock memory rc,,) = book.openTerms(ETH, sunday);
        assertEq(s0, 4_000e18);
        assertEq(uint8(rc.kind), uint8(IPitBook.Clock.EveryDay));
        assertEq(rc.prevDay, saturday);
        assertEq(rc.day, sunday);
        assertEq(rc.regular, 10_000);
        vm.expectRevert(IPitBook.NotNextTradingDay.selector);
        book.openTerms(ETH, mondayNext);
        vm.expectRevert(IPitBook.NoRecentClose.selector);
        book.openTerms(ETH, saturday);

        // the after-hours flag is a stock's: it does not reach an every-day round
        vm.prank(owner);
        book.setSkipAfterHours(ETH, sunday, true);
        (,, rc,,) = book.openTerms(ETH, sunday);
        assertFalse(rc.skipAfterHours);
        // `skip` keeps its meaning: no round that day
        _skipEarly(ETH, sunday);
        vm.expectRevert(IPitBook.NotTradingDay.selector);
        book.openTerms(ETH, sunday);
        // Monday's round may start from Saturday's close over the skipped Sunday (two days of variance) ...
        uint256 sigma;
        (s0, sigma, rc,,) = book.openTerms(ETH, mondayNext);
        assertEq(s0, 4_000e18);
        assertEq(rc.prevDay, saturday);
        assertEq(sigma, FixedPointMathLib.sqrtWad(2 * SEED_VAR), "two days: sigma * sqrt(2)");
        // ... and from Sunday's close once it is on the books
        _ethClose(sunday, 4_100e18);
        (s0, sigma, rc,,) = book.openTerms(ETH, mondayNext);
        assertEq(s0, 4_100e18);
        assertEq(rc.prevDay, sunday);
    }

    /// @dev The variance-poisoning guard on the every-day clock: the EWMA steps from one calendar
    ///      day to the next, weekends included; a missed or skipped day in between makes it a step over
    ///      two days.
    function test_everyDay_varianceStepsOnConsecutiveCalendarDaysOnly() public {
        _registerEth();
        uint32 friday = day0 + 4;
        _ethClose(friday, 4_000e18);
        assertEq(book.getTicker(ETH).varWad, SEED_VAR, "the first close has no return to learn from");
        // Saturday and Sunday: one step each
        _ethClose(friday + 1, 4_120e18);
        uint256 v1 = _ewma(SEED_VAR, 4_000e18, 4_120e18);
        assertEq(book.getTicker(ETH).varWad, v1);
        _ethClose(friday + 2, 4_080e18);
        uint256 v2 = _ewma(v1, 4_120e18, 4_080e18);
        assertEq(book.getTicker(ETH).varWad, v2);
        // Monday's close is left out and Tuesday's recorded: a two-day return, booked as two days
        _ethClose(friday + 4, 4_700e18);
        uint256 v3 = _ewmaOver(v2, 4_080e18, 4_700e18, 2);
        assertEq(book.getTicker(ETH).varWad, v3, "the gap is booked as two daily returns");
        assertTrue(book.getTicker(ETH).lastCloseStepped);
        // the same with the day in between marked as skipped
        _skipEarly(ETH, friday + 5);
        _ethClose(friday + 6, 4_800e18);
        uint256 v4 = _ewmaOver(v3, 4_700e18, 4_800e18, 2);
        assertEq(book.getTicker(ETH).varWad, v4);
        // Monday's close is the owner's to add now, and moves nothing
        bytes memory monday = oracle.post(ETH, KEEPER, 4_500e18, NYTime.closeTs(friday + 3));
        vm.prank(alice);
        vm.expectRevert(IPitBook.CloseTooOld.selector);
        book.recordClose(ETH, friday + 3, monday);
        // the chain is whole again from the newest close on
        _ethClose(friday + 7, 4_750e18);
        assertEq(book.getTicker(ETH).varWad, _ewma(v4, 4_800e18, 4_750e18));
    }

    /// @dev The same fix on the stock clock, unchanged: a step is one trading day, so Friday to Monday is
    ///      one step and a Saturday is no day at all.
    function test_stock_varianceStepsOnConsecutiveTradingDays() public {
        _closeOn(day, S0, TRUSTLESS);
        _closeOn(day + 1, S0, TRUSTLESS);
        _closeOn(day + 2, S0, TRUSTLESS);
        uint32 friday = day0 + 4;
        _closeOn(friday, S0 * 102 / 100, TRUSTLESS);
        uint256 v = book.getTicker(NVDA).varWad;
        _closeOn(friday + 3, S0 * 105 / 100, TRUSTLESS);
        assertEq(book.getTicker(NVDA).varWad, _ewma(v, S0 * 102 / 100, S0 * 105 / 100), "Friday to Monday");
        assertTrue(book.getTicker(NVDA).lastCloseStepped);
    }
}
