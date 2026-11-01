// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IPitBook} from "./IPitBook.sol";
import {IPitOracle} from "../interfaces/IPitOracle.sol";
import {IFallpitHook} from "../interfaces/IFallpitHook.sol";
import {NYTime} from "../lib/NYTime.sol";
import {PitClock} from "./PitClock.sol";
import {PitBook} from "./PitBook.sol";

/// @title PitBookLogic
/// @notice The cold paths of `PitBook` that read or write its storage: the terms a round opens with, a
///         ticker's registration, the guardian's dispute, and the bounded step of a round's learned sigma.
///         An external library linked into the book (it runs in the book's context, on the book's
///         storage, and its events come from the book): these run once a round, once a day or on an
///         owner call, and keeping them out of the book keeps it under the contract size limit. The rules
///         are on the book's functions; the book keeps every caller check (owner, guardian, hook, vol
///         keeper) in front of each call here.
library PitBookLogic {
    using FixedPointMathLib for uint256;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    /// @dev The most calendar days a round may start after the close it starts from.
    uint32 internal constant MAX_CLOSE_AGE = 6;
    /// @dev How long after a close's instant the guardian may dispute it.
    uint64 internal constant DISPUTE_WINDOW = 1 hours;

    // bounds of the learned sigma (`stepSigmaEff`)
    uint256 internal constant SIGMA_EFF_GAP = 5 minutes;
    uint256 private constant SIGMA_STEP_BPS = 1000;
    uint256 private constant SIGMA_LO_BPS = 8000;
    uint256 private constant SIGMA_HI_BPS = 15_000;
    uint256 private constant SIGMA_RISE_CAP = 1.5e18;

    /// @notice `PitBook.openTerms` without the pause check and the parameters (the book adds both).
    function openTerms(
        mapping(bytes32 ticker => IPitBook.Ticker) storage tickers,
        mapping(bytes32 ticker => IPitBook.Reseed) storage reseeds,
        mapping(bytes32 ticker => mapping(uint32 day => PitBook.Close)) storage closes,
        mapping(bytes32 ticker => mapping(uint32 day => bool)) storage skip,
        mapping(bytes32 ticker => mapping(uint32 day => bool)) storage skipAfterHours,
        bytes32 ticker,
        uint32 day
    )
        external
        view
        returns (uint256 s0, uint256 sigma, IPitBook.RoundClock memory clock, IPitBook.FillSource fillSource)
    {
        (IPitBook.Ticker memory tk, uint256 n) = _openable(tickers, reseeds, skip, ticker, day);
        clock = _roundClock(tk, n, tk.clock != IPitBook.Clock.EveryDay && skipAfterHours[ticker][day], day);
        s0 = closes[ticker][tk.lastCloseDay].price;
        sigma = (tk.varWad * n).sqrtWad();
        fillSource = tk.fillSource;
    }

    /// @dev The checks of `openTerms`: the ticker in force, a day with a round, the newest close recent
    ///      enough, and every day in between skipped or missed. Returns the ticker and the trading days
    ///      the round spans.
    function _openable(
        mapping(bytes32 ticker => IPitBook.Ticker) storage tickers,
        mapping(bytes32 ticker => IPitBook.Reseed) storage reseeds,
        mapping(bytes32 ticker => mapping(uint32 day => bool)) storage skip,
        bytes32 ticker,
        uint32 day
    ) private view returns (IPitBook.Ticker memory tk, uint256 n) {
        tk = tickerOf(tickers, reseeds, ticker);
        if (tk.varWad == 0) revert IPitBook.UnknownTicker();
        bool everyDay = tk.clock == IPitBook.Clock.EveryDay;
        if ((!everyDay && !NYTime.isWeekday(day)) || skip[ticker][day]) revert IPitBook.NotTradingDay();
        uint32 last = tk.lastCloseDay;
        if (last >= day || day - last > MAX_CLOSE_AGE) revert IPitBook.NoRecentClose();
        (bool ok, uint256 extra) = span(skip, ticker, tk.clock, last, day);
        if (!ok) revert IPitBook.NotNextTradingDay();
        n = 1 + extra;
    }

    /// @notice `PitBook.registerTicker` after its owner check and its terms check (`PitBookRules.tickerTerms`,
    ///         which gives the weights and windows in `next`): the ticker known to the oracle, the
    ///         registration or reseed `next` scheduled `delay` from now (its `eta` is set here).
    function registerTicker(
        mapping(bytes32 ticker => IPitBook.Ticker) storage tickers,
        mapping(bytes32 ticker => IPitBook.Reseed) storage reseeds,
        bytes32[] storage tickerList,
        IPitOracle oracle,
        uint64 delay,
        bytes32 ticker,
        IPitBook.Clock clock,
        IPitBook.Reseed memory next
    ) external {
        if (!oracle.supported(ticker)) revert IPitBook.UnknownTicker();
        IPitBook.Ticker storage tk = tickers[ticker];
        promote(reseeds, ticker, tk);
        if (tk.varWad == 0) {
            // a first registration (not a second call before the first is in force) joins the list
            if (reseeds[ticker].eta == 0) tickerList.push(ticker);
            tk.clock = clock;
        } else if (clock != tk.clock) {
            revert IPitBook.BadParams();
        }
        next.eta = uint64(block.timestamp) + delay;
        reseeds[ticker] = next;
        emit IPitBook.TickerRegistered(
            ticker, next.varWad, clock, next.weights, next.windows, next.fillSource, next.eta
        );
    }

    /// @notice `PitBook.dispute` after its guardian check.
    function dispute(
        mapping(bytes32 ticker => mapping(uint32 day => PitBook.Close)) storage closes,
        address hook,
        bytes32 roundId
    ) external {
        IFallpitHook h = IFallpitHook(hook);
        IFallpitHook.RoundConfig memory c = h.getConfig(roundId);
        IFallpitHook.RoundState memory st = h.getState(roundId);
        PitBook.Close storage cl = closes[c.ticker][c.day];
        uint64 until = NYTime.closeTs(c.day) + DISPUTE_WINDOW;
        if (
            st.status != IFallpitHook.Status.Settled || st.settledTrustless || cl.trustless
                || block.timestamp >= uint256(st.settledAt) + c.params.challengeWindow
                || block.timestamp >= until
        ) revert IPitBook.DisputeNotAllowed();
        cl.disputeEnd = until;
        emit IPitBook.CloseDisputed(c.ticker, c.day, roundId, until);
    }

    /// @notice `PitBook.stepSigmaEff` after its hook, vol keeper and `SIGMA_EFF_GAP` checks.
    function stepSigmaEff(
        mapping(bytes32 roundId => IPitBook.SigmaEffState) storage sigmaEffState,
        bytes32 roundId,
        uint256 sigma,
        uint256 proposed
    ) external returns (uint256 next) {
        IPitBook.SigmaEffState memory cur = sigmaEffState[roundId];
        uint256 inForce = cur.sigma == 0 ? sigma : cur.sigma;
        uint256 rise = cur.rise == 0 ? WAD : cur.rise;
        next = proposed.max(inForce * (BPS - SIGMA_STEP_BPS) / BPS)
            .min(inForce * (BPS + SIGMA_STEP_BPS) / BPS)
            .max(sigma * SIGMA_LO_BPS / BPS)
            .min(sigma * SIGMA_HI_BPS / BPS);
        if (next > inForce) {
            // the highest the rise budget still allows; never below the sigma in force
            next = next.min(inForce * SIGMA_RISE_CAP / rise).max(inForce);
            rise = rise * next / inForce;
        }
        sigmaEffState[roundId] =
            IPitBook.SigmaEffState({sigma: uint96(next), at: uint64(block.timestamp), rise: uint96(rise)});
    }

    // ------------------------------------------------------------------------------------- shared

    /// @notice `PitBook.getTicker`: the ticker as it applies now, a reseed in force included.
    function tickerOf(
        mapping(bytes32 ticker => IPitBook.Ticker) storage tickers,
        mapping(bytes32 ticker => IPitBook.Reseed) storage reseeds,
        bytes32 ticker
    ) internal view returns (IPitBook.Ticker memory tk) {
        tk = tickers[ticker];
        IPitBook.Reseed storage r = reseeds[ticker];
        if (r.eta != 0 && block.timestamp >= r.eta) {
            tk.varWad = r.varWad;
            tk.varBefore = r.varWad;
            tk.weights = r.weights;
            tk.windows = r.windows;
            tk.fillSource = r.fillSource;
            tk.lastCloseStepped = false;
        }
    }

    /// @notice Writes the reseed of `ticker` that has come into force into the ticker `tk`, before the
    ///         ticker changes.
    function promote(
        mapping(bytes32 ticker => IPitBook.Reseed) storage reseeds,
        bytes32 ticker,
        IPitBook.Ticker storage tk
    ) internal {
        IPitBook.Reseed storage r = reseeds[ticker];
        if (r.eta == 0 || block.timestamp < r.eta) return;
        tk.varWad = r.varWad;
        tk.varBefore = r.varWad;
        tk.weights = r.weights;
        tk.windows = r.windows;
        tk.fillSource = r.fillSource;
        // the newest close's step was made on the variance the reseed replaced: nothing to redo
        tk.lastCloseStepped = false;
        delete reseeds[ticker];
    }

    /// @notice Whether the round of `day` may start from the close of `last`, and how many days without a
    ///         close it spans besides its own (`PitBook._span`).
    function span(
        mapping(bytes32 ticker => mapping(uint32 day => bool)) storage skip,
        bytes32 ticker,
        IPitBook.Clock clock,
        uint32 last,
        uint32 day
    ) internal view returns (bool ok, uint256 extra) {
        if (day <= last || day - last > MAX_CLOSE_AGE) return (false, 0);
        for (uint32 d = last + 1; d < day; ++d) {
            if (clock == IPitBook.Clock.NYWeekdays && !NYTime.isWeekday(d)) continue;
            if (!skip[ticker][d] && block.timestamp <= NYTime.closeTs(d) + PitClock.MISSED_CLOSE) {
                return (false, 0);
            }
            ++extra;
        }
        return (true, extra);
    }

    /// @dev The frozen clock of the round of `day` that spans `n` trading days (see `PitBook.openTerms`).
    function _roundClock(IPitBook.Ticker memory tk, uint256 n, bool skipAfterHours, uint32 day)
        private
        pure
        returns (IPitBook.RoundClock memory clock)
    {
        bool everyDay = tk.clock == IPitBook.Clock.EveryDay;
        IPitBook.Weights memory w = tk.weights;
        if (!everyDay && n != 1) {
            w.afterHours = uint16(w.afterHours / n);
            w.preMarket = uint16(w.preMarket / n);
            w.regular = uint16(w.regular / n);
            w.gap = uint16(BPS - w.afterHours - w.preMarket - w.regular);
        }
        clock.kind = tk.clock;
        clock.skipAfterHours = skipAfterHours;
        clock.windows = tk.windows;
        clock.prevDay = tk.lastCloseDay;
        clock.day = day;
        clock.afterHours = w.afterHours;
        clock.gap = w.gap;
        clock.preMarket = w.preMarket;
        clock.regular = w.regular;
    }
}
