// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPitBook} from "./IPitBook.sol";
import {PitClock} from "./PitClock.sol";
import {PitMath} from "./PitMath.sol";

/// @title PitBookRules
/// @notice The bounds `PitBook` checks the owner's settings against (the default round parameters, a
///         ticker's registration terms, a menu word) and the daily variance step of a recorded close.
///         An external library linked into the book: these run on owner calls and once a day per
///         ticker, and keeping them out of the book keeps it under the contract size limit.
library PitBookRules {
    using FixedPointMathLib for uint256;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant EWMA_KEEP = 94;
    /// @dev A daily squared return enters the EWMA at most at (4 sigma)^2, sigma the variance's own before
    ///      the step: one jump (a crash, a missed corporate action) moves the variance by a bounded factor.
    uint256 private constant MAX_STEP_IN_VARIANCES = 16;
    uint256 internal constant MIN_VAR = 0.005e18 * 0.005e18 / WAD;
    uint256 internal constant MAX_VAR = 0.15e18 * 0.15e18 / WAD;
    uint256 internal constant MAX_ALPHA = 0.79e18;
    uint256 internal constant MIN_BASE_FEE = 0.005e18;
    uint256 internal constant MAX_BASE_FEE = 0.1e18;
    uint256 internal constant MAX_CLOSE_FEE = 0.2e18;
    uint256 internal constant MAX_VEGA_FEE = 1e18;
    uint256 internal constant MAX_FEE_RAMP = 6.5 hours;
    /// @dev The next round of a house opens only when this one is final, and trades in the after-hours
    ///      from then on: the window is short. Five minutes is the least a guardian can act in.
    uint256 internal constant MIN_CHALLENGE = 5 minutes;
    uint256 internal constant MAX_CHALLENGE = 1 hours;
    /// @dev A commit is priced at least two seconds after it was made: one second is the resolution of
    ///      both clocks (the chain's and the oracle's), so one more keeps the print out of sight.
    uint256 internal constant MIN_FILL_DELAY = 2;
    uint256 internal constant MAX_FILL_DELAY = 60;
    /// @dev An unfilled commit stays fillable at its old print for this long: short, because for that
    ///      time it is an option on the price for its owner.
    uint256 internal constant MIN_REFUND_DELAY = 10;
    uint256 internal constant MAX_REFUND_DELAY = 120;
    /// @dev A regular session with less than this share of the variance would make the prior a near
    ///      point mass at the open.
    uint256 internal constant MIN_REGULAR_WEIGHT = 2500;
    uint256 internal constant MAX_PROTOCOL_FEE_BPS = 5000;
    /// @dev Smallest `alpha * minCapital` (alpha in WAD, minCapital in whole chips). `ILadderMath.openDepths`
    ///      refuses a depth below 1e14 wei, and the depth of band j is `alpha * capital / ln(1 / pi_j)` with
    ///      `ln(1 / pi_j)` below 9.3 for the floored prior. A round opens with at least `minCapital` whole
    ///      chips, which is `minCapital * 1e18` in the math's WAD units whatever the chip's decimals, so
    ///      `alpha * minCapital >= 9.3e14` opens every band. This bound keeps a margin on top.
    uint256 internal constant MIN_ALPHA_TIMES_CAPITAL = 1e15;
    /// @dev `ILadderMath.openDepths` refuses a capital above 1e33 wei (1e15 whole chips).
    uint256 internal constant MAX_MIN_CAPITAL = 1e15;
    /// @dev Bounds of the smallest trade: a millionth of a token to a thousand tokens.
    uint256 internal constant MIN_MIN_TRADE = 1e12;
    uint256 internal constant MAX_MIN_TRADE = 1_000e18;
    /// @dev Bounds of the per-round loss limit: a round may always put a tenth of its capital at risk
    ///      (less would stop ordinary trading at alpha 0.2), and never more than all of it.
    uint256 internal constant MIN_LOSS_LIMIT_BPS = 1000;
    /// @dev Bounds of the risk budget per print second: from a tenth of a percent of capital to all of it
    ///      (the default is 300; the top of the range leaves the budget out of the way).
    uint256 internal constant MIN_RISK_CAP_BPS = 10;
    uint256 internal constant MAX_RISK_CAP_BPS = 10_000;
    /// @dev The floor of g (PitMath.G_FLOOR): the smallest risk budget is riskCapBps * 0.3.
    uint256 internal constant G_FLOOR_TENTHS = 3;
    /// @dev The fill fee pays a filler's gas, nothing more: a hundred times the default is the ceiling.
    uint256 internal constant MAX_FILL_FEE = 0.01 ether;
    /// @dev A buy is never charged more than a fifth of a chip per token by the minimum price alone.
    uint256 internal constant MAX_MIN_PRICE = 0.2e18;

    /// @notice Reverts `BadParams` unless `p` is a valid set of default round parameters (see
    ///         `PitBook.setDefaultParams`).
    function checkParams(IPitBook.Params calldata p) external pure {
        if (
            p.alpha == 0 || p.alpha > MAX_ALPHA || p.baseFee < MIN_BASE_FEE || p.baseFee > MAX_BASE_FEE
                || p.closeFee > MAX_CLOSE_FEE || p.closeFee < p.baseFee || p.vegaFee > MAX_VEGA_FEE
                || p.feeRamp > MAX_FEE_RAMP || p.challengeWindow < MIN_CHALLENGE
                || p.challengeWindow > MAX_CHALLENGE || p.fillDelay < MIN_FILL_DELAY
                || p.fillDelay > MAX_FILL_DELAY || p.refundDelay < MIN_REFUND_DELAY
                || p.refundDelay > MAX_REFUND_DELAY || p.protocolFeeBps > MAX_PROTOCOL_FEE_BPS
                || p.maxFillBps == 0 || p.maxFillBps > BPS || p.minCapital == 0
                || p.minCapital > MAX_MIN_CAPITAL || uint256(p.alpha) * p.minCapital < MIN_ALPHA_TIMES_CAPITAL
                || p.minTrade < MIN_MIN_TRADE || p.minTrade > MAX_MIN_TRADE
                || uint256(p.minCapital) * WAD * p.maxFillBps / BPS < p.minTrade
                || p.riskCapBps < MIN_RISK_CAP_BPS || p.riskCapBps > MAX_RISK_CAP_BPS
                || uint256(p.minCapital) * WAD * p.riskCapBps * G_FLOOR_TENTHS / (BPS * 10) < p.minTrade
                || p.lossLimitBps < MIN_LOSS_LIMIT_BPS || p.lossLimitBps > BPS || p.fillFee > MAX_FILL_FEE
                || p.floorCapBps > BPS || uint256(p.minCapital) * WAD * p.floorCapBps / BPS < p.minTrade
                || p.minPriceWad > MAX_MIN_PRICE || !PitMath.validMenu(p.menu)
        ) revert IPitBook.BadParams();
    }

    /// @notice A ticker's registration terms as `PitBook.registerTicker` stores them: all-zero weights
    ///         become the clock's defaults and a zero `windows` the clock's default windows. Reverts
    ///         `BadParams` on terms out of bounds.
    function tickerTerms(uint256 varWad, IPitBook.Clock clock, IPitBook.Weights memory weights, uint8 windows)
        external
        pure
        returns (IPitBook.Weights memory, uint8)
    {
        if (uint256(weights.afterHours) + weights.gap + weights.preMarket + weights.regular == 0) {
            weights = defaultWeights(clock);
        }
        if (clock == IPitBook.Clock.EveryDay) {
            if (windows != 0) revert IPitBook.BadParams();
            windows = PitClock.ALL_WINDOWS;
        } else if (windows == 0) {
            windows = PitClock.DEFAULT_WINDOWS;
        }
        if (
            varWad < MIN_VAR || varWad > MAX_VAR
                || uint256(weights.afterHours) + weights.gap + weights.preMarket + weights.regular != BPS
                || weights.regular < (clock == IPitBook.Clock.EveryDay ? BPS : MIN_REGULAR_WEIGHT)
                || windows > PitClock.ALL_WINDOWS || windows & PitClock.REGULAR == 0
        ) {
            revert IPitBook.BadParams();
        }
        return (weights, windows);
    }

    /// @notice A menu word from its runs (`PitBook.packMenu`). Reverts `BadParams` unless well formed.
    function packMenu(uint8[] calldata lo, uint8[] calldata hi) external pure returns (uint256 menu) {
        if (lo.length != hi.length || lo.length > PitMath.MAX_MENU) revert IPitBook.BadParams();
        menu = PitMath.pack(lo, hi);
        if (!PitMath.validMenu(menu)) revert IPitBook.BadParams();
    }

    /// @notice The runs of a menu word (`PitBook.unpackMenu`).
    function unpackMenu(uint256 menu) external pure returns (uint8[] memory lo, uint8[] memory hi) {
        uint256 n = PitMath.count(menu);
        lo = new uint8[](n);
        hi = new uint8[](n);
        for (uint256 i; i < n; ++i) {
            (lo[i], hi[i]) = PitMath.run(menu, i);
        }
    }

    /// @notice EWMA of the daily variance with weight 0.94 on the past, clamped to [0.005^2, 0.15^2]. The new
    ///         observation is the squared log return over `periods` trading days divided by `periods`, at most
    ///         `MAX_STEP_IN_VARIANCES` times `varWad`.
    function ewma(uint256 varWad, uint256 previousClose, uint256 close, uint256 periods)
        external
        pure
        returns (uint256)
    {
        int256 ret = FixedPointMathLib.lnWad(int256(close.divWad(previousClose)));
        uint256 squared = uint256(ret * ret) / WAD / periods;
        uint256 cap = MAX_STEP_IN_VARIANCES * varWad;
        if (squared > cap) squared = cap;
        uint256 next = (EWMA_KEEP * varWad + (100 - EWMA_KEEP) * squared) / 100;
        return next < MIN_VAR ? MIN_VAR : (next > MAX_VAR ? MAX_VAR : next);
    }

    /// @notice The weights a ticker registered with all-zero weights gets (`PitBook.defaultWeights`).
    function defaultWeights(IPitBook.Clock clock) internal pure returns (IPitBook.Weights memory) {
        return clock == IPitBook.Clock.EveryDay
            ? IPitBook.Weights(0, 0, 0, uint16(BPS))
            : IPitBook.Weights(600, 1400, 1000, 7000);
    }
}
