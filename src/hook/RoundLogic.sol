// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IFallpitHook} from "../interfaces/IFallpitHook.sol";
import {ILadderMath} from "../interfaces/ILadderMath.sol";
import {IPitVault} from "../interfaces/IPitVault.sol";
import {IChipGuard} from "../interfaces/IChipGuard.sol";
import {NYTime} from "../lib/NYTime.sol";
import {IPitBook} from "./IPitBook.sol";
import {PitClock} from "./PitClock.sol";
import {PitMath} from "./PitMath.sol";

/// @dev One round: frozen config, state and the supply and premium of each product of its menu
///      (`cfg.params.menu`; the entries above the last product stay zero). Supplies and cost bases are
///      128-bit, two products a slot: a fill writes one slot of each, and the pooled check reads the menu's
///      supplies from at most 8 slots. A buy that would take either past 2^128 - 1 reverts (no chip has
///      that many units in a round: the payout of the supply must stay covered). The menu in
///      `cfg.params.menu` grows by two products for each live strike (`openStrike`), up to 15. The round's
///      pricing state is kept per house (`HouseBands`).
struct Round {
    IFallpitHook.RoundConfig cfg;
    StoredState st;
    uint128[15] supply;
    uint128[15] premium;
}

/// @dev A round's state as stored: `IFallpitHook.RoundState` in three slots, with the learned sigma
///      (`FallpitHook.setSigmaEff`, 0 until the first update). A fill reads the first two and writes them
///      once each. The narrow fields are bounded: the depth scale `g` is at most 1e18, the learned sigma at
///      most 1.5 times the round's sigma, `settledAt` a timestamp, and the chip amounts at most the capital
///      plus premiums (capital at most 1e33 wei: the engine's depth check at the open), far below 2^128;
///      the writes are checked casts all the same, and the book refuses a close above 2^128 - 1.
struct StoredState {
    IFallpitHook.Status status;
    bool settledTrustless;
    uint8 closeBand;
    uint16 winners;
    uint40 settledAt;
    uint64 g;
    uint96 sigmaEff;
    uint128 held;
    uint128 protocolFees;
    uint128 payoutOwed;
    uint128 settledPrice;
}

/// @dev The pricing state of a house's latest traded round, written over by the next round's first fill
///      (reused slots, not 21 new ones a round). `tag` (the top 128 bits of the round id, `bandTag`) says
///      whose state it is: a round whose tag is not there has the zero state, which is what a round has
///      before its first fill. Rounds of one house differ only in their day, so two of them never share a
///      tag. `v` is the band state of `ILadderMath` packed two bands to a word (`PackedBands`); the packing
///      is exact: `ILadderMath` rejects any |v_j| above 1e36 on the way in and on the way out, and
///      1e36 < 2^127. `lambda` is the root the last fill returned for `v` (the next fill starts its solves
///      there: `ILadderMath.fillFrom`); a root lies within about 1.01e36 of zero (the solve's bracket), so
///      it fits 128 bits, and the tag and the root share one slot. Only the latest round of a house trades,
///      and settling, finalizing, voiding and redeeming never read the pricing state.
struct HouseBands {
    uint128 tag;
    int128 lambda;
    uint256[20] v;
}

/// @dev What a round opens with: the book's terms (`IPitBook.openTerms`) and what the hook derived.
struct OpenArgs {
    bytes32 ticker;
    bytes32 house;
    address chip;
    uint32 day;
    uint8 decimals;
    uint64 closeTs;
    uint64 cutoff;
    uint256 s0;
    uint256 sigma;
    IPitBook.RoundClock clock;
    IPitBook.FillSource fillSource;
    IPitBook.Params p;
}

interface IChipBalance {
    function balanceOf(address owner) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @dev The hook's contracts that `RoundLogic.start` calls (its immutables).
struct OpenDeps {
    IPitBook book;
    IChipGuard chipGuard;
    IPitVault vault;
    ILadderMath math;
}

/// @title RoundLogic
/// @notice The end of a round of `FallpitHook`: settlement on the recorded close, finalization, and the
///         void of a round with no close; the setup of a new round, and its live strikes. An external library linked into the hook (it runs in the
///         hook's context, on the hook's storage): these run once a round, and keeping them out of the
///         hook keeps it under the contract size limit. The rules are on the hook's functions.
library RoundLogic {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;
    using SafeCastLib for uint256;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;

    uint256 private constant INDEX_MASK = 0xff;
    /// @dev A round with no recorded close can be voided this long after its close.
    uint64 private constant VOID_AFTER = 24 hours;

    /// @notice `FallpitHook.openRound`: the round of `day` of the house (`ticker`, `chip`). The book decides
    ///         whether it may open and supplies its terms; the chip must pass the guard and have at most
    ///         18 decimals; the house's previous round must be over (one whose close was missed is voided
    ///         here). Returns the new round's id.
    function start(
        mapping(bytes32 roundId => Round) storage rounds,
        mapping(bytes32 house => bytes32 roundId) storage houseRound,
        mapping(address chip => uint256) storage chipOwed,
        mapping(bytes32 house => uint256[10] packed) storage lnInv,
        OpenDeps memory d,
        bytes32 ticker,
        address chip,
        uint32 day
    ) external returns (bytes32 roundId) {
        OpenArgs memory a = _terms(d, ticker, chip, day);
        _retirePrevious(rounds, houseRound, chipOwed, d, a.house, ticker);
        roundId = bytes32(uint256(keccak256(abi.encode(a.house, day))) & ~INDEX_MASK);
        Round storage r = rounds[roundId];
        if (r.st.status != IFallpitHook.Status.None) revert IFallpitHook.RoundExists();

        houseRound[a.house] = roundId;
        uint256 capital = _setup(r, a, d.vault, d.math, chipOwed, lnInv[a.house]);
        emit IFallpitHook.RoundOpened(roundId, ticker, chip, day, a.s0, a.sigma, capital, a.p.menu);
    }

    /// @dev The book's terms for the round of `day`, the open's time and chip checks, and the house.
    function _terms(OpenDeps memory d, bytes32 ticker, address chip, uint32 day)
        private
        view
        returns (OpenArgs memory a)
    {
        (a.s0, a.sigma, a.clock, a.fillSource, a.p) = d.book.openTerms(ticker, day);
        uint64 closeAt = NYTime.closeTs(day);
        if (block.timestamp >= closeAt - PitClock.CUTOFF_LEAD) revert IFallpitHook.TooLate();
        (bool allowed,) = d.chipGuard.check(chip);
        if (!allowed) revert IFallpitHook.ChipNotAllowed();
        uint8 chipDecimals = IChipBalance(chip).decimals();
        if (chipDecimals > 18) revert IFallpitHook.ChipNotAllowed();
        (a.ticker, a.house, a.chip, a.day) = (ticker, keccak256(abi.encode(ticker, chip)), chip, day);
        (a.decimals, a.closeTs, a.cutoff) = (chipDecimals, closeAt, closeAt - PitClock.CUTOFF_LEAD);
    }

    /// @dev Reverts while the house's previous round is still active; voids it when its close was missed
    ///      or spans a corporate action.
    function _retirePrevious(
        mapping(bytes32 roundId => Round) storage rounds,
        mapping(bytes32 house => bytes32 roundId) storage houseRound,
        mapping(address chip => uint256) storage chipOwed,
        OpenDeps memory d,
        bytes32 house,
        bytes32 ticker
    ) private {
        bytes32 previous = houseRound[house];
        if (previous != bytes32(0)) {
            Round storage pr = rounds[previous];
            IFallpitHook.Status s = pr.st.status;
            if (s == IFallpitHook.Status.Open) {
                (uint256 price,,) = d.book.closeState(ticker, pr.cfg.day);
                bool voids = price == 0
                    ? block.timestamp > pr.cfg.closeTs + PitClock.MISSED_CLOSE
                    : spansCorporateAction(d.book, ticker, pr.cfg.clock.prevDay, pr.cfg.day);
                if (!voids) revert IFallpitHook.PreviousRoundActive();
                _void(pr, previous, d.vault, chipOwed);
            } else if (s == IFallpitHook.Status.Settled) {
                // a settled round across a corporate action can be voided, never left to block the house
                if (!spansCorporateAction(d.book, ticker, pr.cfg.clock.prevDay, pr.cfg.day)) {
                    revert IFallpitHook.PreviousRoundActive();
                }
                _void(pr, previous, d.vault, chipOwed);
            }
        }
    }

    /// @dev The book side of `start` for a new round `r`: writes its frozen config, then pulls the house
    ///      capital (what actually arrived), checks it and the depths, and stores the house's `openLnInv` in
    ///      `lnInv`. Everything that does not depend on the capital is written before the capital is pulled.
    function _setup(
        Round storage r,
        OpenArgs memory a,
        IPitVault vault,
        ILadderMath math,
        mapping(address chip => uint256) storage chipOwed,
        uint256[10] storage lnInv
    ) private returns (uint256 capital) {
        r.st.status = IFallpitHook.Status.Open;
        r.st.g = uint64(WAD);
        IFallpitHook.RoundConfig storage c = r.cfg;
        c.ticker = a.ticker;
        c.house = a.house;
        c.chip = a.chip;
        c.day = a.day;
        c.decimals = a.decimals;
        c.fillSource = a.fillSource;
        c.openTs = uint64(block.timestamp);
        c.closeTs = a.closeTs;
        c.cutoff = a.cutoff;
        c.clock = a.clock;
        c.s0 = a.s0;
        c.sigma = a.sigma;
        c.params = a.p;

        uint256 before = IChipBalance(a.chip).balanceOf(address(this));
        vault.pullRoundCapital(a.house, address(this));
        capital = IChipBalance(a.chip).balanceOf(address(this)) - before;
        if (capital < uint256(a.p.minCapital) * 10 ** a.decimals) revert IFallpitHook.CapitalTooLow();
        c.capital = capital;
        c.maxFill = capital * a.p.maxFillBps / BPS;
        r.st.held = capital.toUint128();
        chipOwed[a.chip] += capital;
        // the depths are checked here and derived again at each fill (inside `math.fillPacked`)
        uint256[10] memory packed = math.openLnInv(a.sigma);
        math.depths(packed, capital * 10 ** (18 - a.decimals), a.p.alpha);
        for (uint256 k; k < 10; ++k) {
            lnInv[k] = packed[k];
        }
    }

    /// @notice The rules of `FallpitHook.openStrike` for round `r` (id `roundId`) on inner edge `m`, at the
    ///         verified print (`price`, `ts`) of an instant the hook has checked: the round's clock trades
    ///         at the print, `m` is the edge nearest to the print, and `PitMath.strikeCheck` passes with the
    ///         remaining standard deviation on the round's learned sigma (`sigmaEff`). Appends the two
    ///         products to the round's menu.
    function openStrike(
        Round storage r,
        bytes32 roundId,
        uint8 m,
        uint256 price,
        uint64 ts,
        uint256 sigmaEff,
        IPitBook book
    ) external {
        uint256 menu = r.cfg.params.menu;
        PitMath.StrikeRule rule = _strikeRule(r.cfg, menu, m, _strikeAt(r, price, ts, sigmaEff, book));
        if (rule == PitMath.StrikeRule.TooEarly) revert IFallpitHook.StrikeTooEarly();
        if (rule == PitMath.StrikeRule.Spacing) revert IFallpitHook.StrikeTooClose();
        if (rule == PitMath.StrikeRule.NotPinned) revert IFallpitHook.StrikeNotPinned();
        if (rule == PitMath.StrikeRule.NoRoom) revert IFallpitHook.StrikeNoRoom();
        uint8 low = uint8(PitMath.count(menu));
        r.cfg.params.menu = PitMath.addStrike(menu, m);
        emit IFallpitHook.StrikeOpened(roundId, m, low, low + 1, price, ts);
    }

    /// @dev The print as the strike rules see it: rho, the log return x and the remaining sd.
    struct StrikeAt {
        uint256 rho;
        int256 x;
        uint256 sd;
    }

    /// @dev The round's clock at the print (it must trade there) and the pricing context of the print.
    function _strikeAt(Round storage r, uint256 price, uint64 ts, uint256 sigmaEff, IPitBook book)
        private
        view
        returns (StrikeAt memory a)
    {
        bool tradable;
        (a.rho, tradable) = book.clockAt(r.cfg.clock, ts);
        if (!tradable) revert IFallpitHook.StrikeWindow();
        (a.x, a.sd,) = PitMath.context(sigmaEff, a.rho, r.cfg.s0, price, r.st.g);
    }

    /// @dev `m` must be the edge nearest to the print; then `PitMath.strikeCheck` decides.
    function _strikeRule(IFallpitHook.RoundConfig storage c, uint256 menu, uint8 m, StrikeAt memory a)
        private
        view
        returns (PitMath.StrikeRule)
    {
        uint256 sigma = c.sigma;
        if (m != PitMath.nearestEdge(sigma, a.x)) revert IFallpitHook.StrikeEdge();
        return PitMath.strikeCheck(menu, m, a.rho, sigma, a.x, a.sd);
    }

    /// @notice `FallpitHook.settleRound` of the round `r` (id `roundId`) on the close of `day`.
    function settle(Round storage r, bytes32 roundId, uint32 day, IPitBook book) external {
        IFallpitHook.RoundConfig storage c = r.cfg;
        StoredState storage st = r.st;
        IFallpitHook.Status s = st.status;
        if (s != IFallpitHook.Status.Open && s != IFallpitHook.Status.Settled) {
            revert IFallpitHook.WrongStatus();
        }
        (uint256 price, bool trustless,) = book.closeState(c.ticker, day);
        if (price == 0) revert IFallpitHook.CloseNotRecorded();
        // a split between the two closes moves the price without the market: the round voids instead
        if (spansCorporateAction(book, c.ticker, c.clock.prevDay, day)) {
            revert IFallpitHook.CorporateAction();
        }
        if (s == IFallpitHook.Status.Settled) {
            if (price == st.settledPrice && trustless == st.settledTrustless) {
                revert IFallpitHook.AlreadySettled();
            }
        } else {
            st.settledAt = uint40(block.timestamp);
        }

        uint8 band = PitMath.bandOf(c.sigma, FixedPointMathLib.lnWad(int256(price.divWad(c.s0))));
        uint16 mask = PitMath.winners(c.params.menu, band);
        uint256 payout = PitMath.payoutOf(PitMath.supplyOf(r.supply, c.params.menu), mask);
        st.status = IFallpitHook.Status.Settled;
        st.closeBand = band;
        st.winners = mask;
        st.payoutOwed = payout.toUint128();
        st.settledPrice = price.toUint128();
        st.settledTrustless = trustless;
        emit IFallpitHook.RoundSettled(roundId, price, band, mask, payout, trustless);
    }

    /// @notice True when the closes of `prevDay` and `day` of `ticker` were recorded with different stock
    ///         token multipliers.
    function spansCorporateAction(IPitBook book, bytes32 ticker, uint32 prevDay, uint32 day)
        public
        view
        returns (bool)
    {
        return book.closeMultiplier(ticker, day) != book.closeMultiplier(ticker, prevDay);
    }

    /// @notice `FallpitHook.finalizeRound` of the round `r` (id `roundId`) of `house` on `day`.
    function finalize(
        Round storage r,
        bytes32 roundId,
        bytes32 house,
        uint32 day,
        IPitBook book,
        IPitVault vault,
        mapping(address chip => uint256) storage protocolFeesAccrued,
        mapping(address chip => uint256) storage chipOwed
    ) external {
        StoredState storage st = r.st;
        if (st.status != IFallpitHook.Status.Settled) revert IFallpitHook.WrongStatus();
        {
            (uint256 price, bool trustless, uint64 disputeEnd) = book.closeState(r.cfg.ticker, day);
            if (price != st.settledPrice) revert IFallpitHook.CloseChanged();
            if (
                !trustless
                    && (block.timestamp < st.settledAt + r.cfg.params.challengeWindow
                        || block.timestamp < disputeEnd)
            ) {
                revert IFallpitHook.ChallengeWindowOpen();
            }
        }

        uint256 payout = st.payoutOwed;
        uint256 fees = st.protocolFees;
        uint256 back = st.held - payout - fees;
        st.status = IFallpitHook.Status.Final;
        (st.held, st.protocolFees) = (payout.toUint128(), 0);
        address chip = r.cfg.chip;
        protocolFeesAccrued[chip] += fees;
        chipOwed[chip] -= back;

        if (back != 0) chip.safeTransfer(address(vault), back);
        vault.returnRoundCapital(house);
        emit IFallpitHook.RoundFinalized(roundId, payout, fees, back);
    }

    /// @notice The book side of `FallpitHook.redeem` of `amount` tickets of product `index` of round `r`:
    ///         one chip a ticket of a winning product after Final, the product's average cost after Void.
    ///         Takes the tickets off the supply and the payout off what the round holds and owes.
    function redeem(Round storage r, uint8 index, uint256 amount) external returns (uint256 payout) {
        StoredState storage st = r.st;
        if (st.status == IFallpitHook.Status.Final) {
            if (st.winners >> index & 1 == 0) revert IFallpitHook.NotWinner();
            payout = amount;
        } else if (st.status == IFallpitHook.Status.Void) {
            uint256 premium = r.premium[index];
            payout = premium.fullMulDiv(amount, r.supply[index]);
            r.premium[index] = uint128(premium - payout);
        } else {
            revert IFallpitHook.WrongStatus();
        }
        r.supply[index] = uint128(uint256(r.supply[index]) - amount);
        (st.held, st.payoutOwed) = ((st.held - payout).toUint128(), (st.payoutOwed - payout).toUint128());
    }

    /// @notice Voids an open round (`FallpitHook.voidRound`): the house first, then the holders pro rata to their cost.
    function void(
        Round storage r,
        bytes32 roundId,
        IPitVault vault,
        mapping(address chip => uint256) storage chipOwed
    ) external {
        _void(r, roundId, vault, chipOwed);
    }

    /// @dev The void of `void` and of a missed round in `start`.
    function _void(
        Round storage r,
        bytes32 roundId,
        IPitVault vault,
        mapping(address chip => uint256) storage chipOwed
    ) private {
        IFallpitHook.RoundConfig storage c = r.cfg;
        StoredState storage st = r.st;
        uint256 held = st.held;
        uint256 refundable = held > c.capital ? held - c.capital : 0;
        uint256 refunds;
        uint256 n = PitMath.count(c.params.menu);
        for (uint256 i; i < n; ++i) {
            refunds += r.premium[i];
        }
        if (refunds > refundable) {
            uint256 total = refunds;
            refunds = 0;
            for (uint256 i; i < n; ++i) {
                // at most the premium it scales, so it fits 128 bits
                uint256 scaled = uint256(r.premium[i]).fullMulDiv(refundable, total);
                r.premium[i] = uint128(scaled);
                refunds += scaled;
            }
        }
        uint256 back = held - refunds;
        st.status = IFallpitHook.Status.Void;
        (st.held, st.protocolFees) = (refunds.toUint128(), 0);
        st.payoutOwed = refunds.toUint128();
        address chip = c.chip;
        chipOwed[chip] -= back;

        if (back != 0) chip.safeTransfer(address(vault), back);
        vault.returnRoundCapital(c.house);
        emit IFallpitHook.RoundVoided(roundId, refunds, back);
    }

    /// @notice `FallpitHook.setSigmaEff`: the book checks the caller and the rate and applies the bounds
    ///         (`PitBook.stepSigmaEff`); the round keeps the result for its fills.
    function setSigmaEff(Round storage r, bytes32 roundId, uint256 sigmaEff, IPitBook book) external {
        if (r.st.status != IFallpitHook.Status.Open) revert IFallpitHook.WrongStatus();
        sigmaEff = book.stepSigmaEff(msg.sender, roundId, r.cfg.sigma, sigmaEff);
        r.st.sigmaEff = sigmaEff.toUint96();
        emit IFallpitHook.SigmaEffSet(roundId, sigmaEff);
    }

    /// @notice `FallpitHook.voidRound`: an open round with a missed close (none a day after the close), or
    ///         an open or settled round with a close across a corporate action, voids. A settled round can
    ///         only be across one if a multiplier was recorded wrongly, as the book keeps each close's first
    ///         multiplier; it voids rather than lock the house (finalize and settle would both refuse it).
    function voidRound(
        Round storage r,
        bytes32 roundId,
        uint32 day,
        IPitBook book,
        IPitVault vault,
        mapping(address chip => uint256) storage chipOwed
    ) external {
        IFallpitHook.Status s = r.st.status;
        if (s != IFallpitHook.Status.Open && s != IFallpitHook.Status.Settled) {
            revert IFallpitHook.WrongStatus();
        }
        (uint256 price,,) = book.closeState(r.cfg.ticker, day);
        bool allowed = price == 0 && s == IFallpitHook.Status.Open
            ? block.timestamp > r.cfg.closeTs + VOID_AFTER
            : spansCorporateAction(book, r.cfg.ticker, r.cfg.clock.prevDay, day);
        if (!allowed) revert IFallpitHook.VoidNotAllowed();
        _void(r, roundId, vault, chipOwed);
    }

    /// @notice `FallpitHook.collectProtocolFees`: the protocol fees of `chip` from finalized rounds, to the
    ///         book's fee recipient.
    function collectProtocolFees(
        address chip,
        IPitBook book,
        mapping(address chip => uint256) storage protocolFeesAccrued,
        mapping(address chip => uint256) storage chipOwed
    ) external returns (uint256 amount) {
        address to = book.feeRecipient();
        if (to == address(0)) revert IFallpitHook.ZeroAddress();
        amount = protocolFeesAccrued[chip];
        protocolFeesAccrued[chip] = 0;
        chipOwed[chip] -= amount;
        if (amount != 0) chip.safeTransfer(to, amount);
        emit IFallpitHook.ProtocolFeesCollected(chip, to, amount);
    }
}
