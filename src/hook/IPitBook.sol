// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPitBook
/// @notice The hook's book of record: closes, per-ticker volatility, the trading calendar and clock, the
///         default round parameters and the two roles (owner, guardian). See contracts/SPEC.md sections
///         7.2, 7.3 and 7.8. It holds no funds and has no power over an open round.
interface IPitBook {
    /// @notice Parameters copied into a round when it opens. The owner sets the defaults for future rounds.
    /// @param alpha depth factor of `ILadderMath.openDepths`, WAD, at most 0.79e18
    /// @param baseFee fee rate until `feeRamp` seconds before the close, WAD
    /// @param closeFee fee rate reached at the close, WAD
    /// @param vegaFee multiplier of `ILadderMath.Fill.vega` charged per share, WAD
    /// @param feeRamp seconds before the close over which the fee rises from `baseFee` to `closeFee`
    /// @param challengeWindow seconds after settlement in which a non-trustless close can be challenged
    /// @param fillDelay seconds between a commit and the instant its fill is priced at
    /// @param refundDelay seconds after the fill instant in which the commit can be filled; refundable after
    /// @param minTrade smallest number of tokens in one commit, WAD (1e18 = one whole token)
    /// @param protocolFeeBps share of the fees set aside for the protocol, in basis points
    /// @param maxFillBps largest fill as a share of the round's capital, in basis points
    /// @param minCapital smallest capital a round may open with, in whole chips; at least the smallest
    ///        capital `ILadderMath.openDepths` accepts at `alpha` (alpha * minCapital >= 1e15)
    /// @param lossLimitBps most of its capital a round may put at risk, in basis points: a buy is refused
    ///        when it would leave the round, in its worst outcome, with less than `capital * (10000 -
    ///        lossLimitBps) / 10000` after paying the winners and the protocol's fees. 10000 leaves only
    ///        the solvency check
    /// @param fillFee native coin, in wei, a trader attaches to every commit and the router pays to
    ///        whoever fills it (zero: no fill fee)
    /// @param floorCapBps largest outstanding supply of one product as a share of the round's capital, in
    ///        basis points. It applies to products narrower than half the ladder (the floors, fewer than
    ///        20 bands); a product of 20 bands or more (the HIGHER / LOWER pair) has no product cap.
    ///        10000 (the default) switches the cap off: a floor's supply may reach the whole capital, and
    ///        only the per-fill cap and the loss limit bound it
    /// @param minPriceWad least a buy is charged per token before fees, WAD (zero: none). Sells are not
    ///        affected
    /// @param menu the products of a round (`PitMath`): the lowest byte is their number n, 2 to 12;
    ///        product i is the band run `[lo, hi]` with `lo` in byte `1 + 2 * i` and `hi` in byte
    ///        `2 + 2 * i`, `lo <= hi <= 39`; zero above the last product. Runs may overlap and need not
    ///        cover the ladder. `PitBook.packMenu` builds the word
    struct Params {
        uint64 alpha;
        uint64 baseFee;
        uint64 closeFee;
        uint64 vegaFee;
        uint32 feeRamp;
        uint32 challengeWindow;
        uint32 fillDelay;
        uint32 refundDelay;
        uint16 protocolFeeBps;
        uint16 maxFillBps;
        /// risk budget per print second, in bps of capital at g = 1: every fill of a round priced by one
        /// print (one print timestamp ts) shares capital * riskCapBps * g / 1e4 of house risk
        uint16 riskCapBps;
        uint96 minCapital;
        uint96 minTrade;
        uint16 lossLimitBps;
        uint64 fillFee;
        uint16 floorCapBps;
        uint64 minPriceWad;
        uint256 menu;
    }

    /// @notice Which oracle source prices the fills of a ticker's rounds: exactly one, frozen per round.
    ///         With two sources two prints would qualify for one instant and the filler could pick between
    ///         them, so there is no "either" option.
    enum FillSource {
        TrustlessOnly,
        KeeperOnly
    }

    /// @notice The clock a ticker's rounds run on. Chosen when the ticker is registered, never changed.
    ///         - `NYWeekdays` (stocks): a round per weekday that is not skipped, closing at 16:00:00 New
    ///           York. Which of its four windows trade is the ticker's `windows` mask; by default the
    ///           after-hours of the trading day before (16:00 to 20:00), its own pre-market (04:00 to
    ///           09:30) and its regular session (09:30 to the cutoff), and not the nights.
    ///         - `EveryDay` (assets that trade around the clock): a round every calendar day, closing at
    ///           16:00:00 New York, tradable without a break from the previous close to the cutoff.
    enum Clock {
        NYWeekdays,
        EveryDay
    }

    /// @notice How a `NYWeekdays` round's variance is spread over the time from the previous close to its
    ///         own close, in basis points that sum to 10000. For `EveryDay` there is one segment: (0, 0,
    ///         0, 10000).
    /// @param afterHours 16:00 to 20:00 New York on the day of the previous close
    /// @param gap 20:00 to 04:00, the hours without trading (a weekend or skipped days included)
    /// @param preMarket 04:00 to 09:30 on the round's day
    /// @param regular 09:30 to 16:00 on the round's day
    struct Weights {
        uint16 afterHours;
        uint16 gap;
        uint16 preMarket;
        uint16 regular;
    }

    /// @notice The frozen clock of one round: everything that decides, for a timestamp, how much of the
    ///         round's variance is still ahead and whether the round trades (`clockAt`).
    /// @param kind the ticker's clock
    /// @param skipAfterHours the round does not trade in the after-hours of `prevDay` (`NYWeekdays` only)
    /// @param windows which windows of a `NYWeekdays` round trade, a bit mask of the ticker's when the
    ///        round opened: 1 after-hours, 2 overnight, 4 pre-market, 8 regular session (`PitClock`)
    /// @param prevDay day of the close the round starts from
    /// @param day the round's day
    /// @param afterHours `Weights.afterHours` of the ticker when the round opened (likewise the next three)
    struct RoundClock {
        Clock kind;
        bool skipAfterHours;
        uint8 windows;
        uint32 prevDay;
        uint32 day;
        uint16 afterHours;
        uint16 gap;
        uint16 preMarket;
        uint16 regular;
    }

    /// @notice Per-ticker volatility state.
    /// @param varWad EWMA daily variance of close-to-close log returns, WAD
    /// @param varBefore `varWad` before the update made by the close of `lastCloseDay`
    /// @param lastCloseDay newest day with a recorded close (0 when none)
    /// @param prevCloseDay the recorded close day before `lastCloseDay` (0 when none)
    /// @param fillSource oracle source that prices fills of future rounds
    /// @param lastCloseStepped true when the close of `lastCloseDay` moved the variance (so a trustless
    ///        replacement of that close redoes the step)
    /// @param clock the clock of the ticker's rounds
    /// @param windows which windows of the clock trade in future rounds (the bit mask of `RoundClock`)
    /// @param weights variance weights of the clock's segments for future rounds
    struct Ticker {
        uint256 varWad;
        uint256 varBefore;
        uint32 lastCloseDay;
        uint32 prevCloseDay;
        FillSource fillSource;
        bool lastCloseStepped;
        Clock clock;
        uint8 windows;
        Weights weights;
    }

    /// @notice A reseed of a registered ticker that the owner scheduled. It replaces the ticker's
    ///         variance, clock weights, trading windows and fill source from `eta` on (`eta` zero: none
    ///         scheduled).
    struct Reseed {
        uint256 varWad;
        Weights weights;
        uint8 windows;
        FillSource fillSource;
        uint64 eta;
    }

    event CloseRecorded(
        bytes32 indexed ticker, uint32 indexed day, uint256 price, bool trustless, uint256 varWad
    );
    /// @param eta when the values take effect: 24 hours after the call, for a new ticker and for a reseed
    event TickerRegistered(
        bytes32 indexed ticker,
        uint256 varWad,
        Clock clock,
        Weights weights,
        uint8 windows,
        FillSource fillSource,
        uint64 eta
    );
    event SkipSet(bytes32 indexed ticker, uint32 indexed day, bool skipped);
    /// @notice The guardian disputed the keeper close of `ticker` on `day` (seen in round `roundId`): rounds
    ///         on it finalize only from `until` on, and until then the close can be replaced (`recordClose`).
    event CloseDisputed(bytes32 indexed ticker, uint32 indexed day, bytes32 roundId, uint64 until);
    event HookSet(address indexed hook);
    event SkipAfterHoursSet(bytes32 indexed ticker, uint32 indexed day, bool skipped);
    event PausedSet(bool paused);
    /// @param eta when `guardian` takes over (24 hours after the call)
    event GuardianSet(address guardian, uint64 eta);
    event FeeRecipientSet(address recipient);
    event VolKeeperSet(address volKeeper, uint64 eta);
    /// @param eta when the parameters start to apply to newly opened rounds
    event DefaultParamsSet(Params params, uint64 eta);
    event OwnershipTransferStarted(address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OnlyOwner();
    error OnlyHook();
    error Reentrancy();
    error ZeroAddress();
    error BadParams();
    error BadPrice();
    error UnknownTicker();
    error NotTradingDay();
    error TooEarly();
    error CloseIsFinal();
    error CloseTooOld();
    error OpeningPaused();
    error NoRecentClose();
    error NotNextTradingDay();
    /// @dev `setSkip` for a day whose close is less than `OWNER_DELAY` away.
    error SkipTooLate();
    error OnlyGuardian();
    error OnlyDeployer();
    error HookAlreadySet();
    error BadHook();
    /// @dev `dispute` outside the challenge window of a settled round with a keeper close.
    error DisputeNotAllowed();
    /// @dev A keeper print that may not replace the keeper close: no dispute running, a replacement made
    ///      already, or a price within the oracle's bound of the recorded one.
    error ReplacementRefused();
    /// @dev The constructor on a mainnet chain id with an `OWNER_DELAY` under 24 hours.
    error DelayTooShort();

    /// @notice The learned sigma of a round as the book bounds it (`stepSigmaEff`): the sigma in force (0
    ///         until the first update), when it was set, and the product of all its rises so far (WAD; 0
    ///         until the first update, which means 1).
    struct SigmaEffState {
        uint96 sigma;
        uint64 at;
        uint96 rise;
    }

    /// @notice Stores the close of `ticker` on `day` from the oracle print for 16:00:00 New York. Anyone,
    ///         once that instant has passed and for three days after it, and never for a day before the
    ///         newest recorded close; the owner at any time (for seeding). A trustless print replaces a
    ///         non-trustless one; nothing replaces a trustless one. A `NYWeekdays` ticker has closes on
    ///         weekdays only, an `EveryDay` ticker on every day. A close first recorded more than
    ///         `MISSED_CLOSE` (12 hours) after its instant is late: it is a start price and a step of the
    ///         variance like any close, but it never settles a round (`closeState` shows no close for it),
    ///         because from that instant on the day's rounds can be voided.
    function recordClose(bytes32 ticker, uint32 day, bytes calldata report) external payable;

    /// @notice Terms a round of `ticker` on `day` opens with. Reverts when no round may open: opening is
    ///         paused, the ticker is unknown (or its registration not in force yet), `day` is skipped (or a
    ///         weekend, for a `NYWeekdays` ticker), or the newest recorded close is not one the round may
    ///         start from: at most six days back, and every day in between with a round (a weekday for
    ///         `NYWeekdays`) skipped or with its close missed (12 hours past and not recorded).
    /// @return s0 that previous close, WAD
    /// @return sigma standard deviation of the log return from that close to the round's close, WAD: the
    ///         daily sigma times the square root of the trading days the round spans (one, plus the
    ///         skipped or missed days in between)
    /// @return clock the round's clock, to be frozen in the round and passed to `clockAt`
    /// @return fillSource oracle source allowed to price the round's fills
    /// @return params the current default parameters
    function openTerms(bytes32 ticker, uint32 day)
        external
        view
        returns (
            uint256 s0,
            uint256 sigma,
            RoundClock memory clock,
            FillSource fillSource,
            Params memory params
        );

    /// @notice The clock of a round at `ts`: a pure function of its arguments.
    /// @return rho share of the round's variance still ahead at `ts`, WAD: 1e18 at the previous close
    ///         (and before it), 0 at the round's close (and after it), never rising in between
    /// @return tradable true when a fill may be priced by a print made at `ts`
    function clockAt(RoundClock calldata clock, uint64 ts) external pure returns (uint256 rho, bool tradable);

    /// @notice Adds `risk` (WAD chips) to what the fills of round `roundId` priced by the print of `ts`
    ///         took; false (and nothing written) when the sum would pass `budget`. Only the hook calls it.
    /// @param budget the print's budget in WAD chips, computed by the hook from the round's frozen config:
    ///        `capital * riskCapBps * g / 1e4` (`PitMath.riskBudget`, the same as `PitBook.riskBudgetOf`), g the
    ///        round's depth scale at `ts`
    /// @dev `ts` is the print's own timestamp (`IPitOracle.verifyAt`), not the commit's instant: one print
    ///      prices every instant in `(prevTs, ts]`, and all of them share its one budget.
    function takeRisk(bytes32 roundId, uint64 ts, uint256 risk, uint256 budget) external returns (bool);

    /// @notice House risk (WAD chips) the fills of a round priced by the print of `ts` took from its budget.
    ///         A commit made for instant t is priced by the first print with ts >= t; for a t that has no
    ///         print yet, that is a print of t itself when the keeper prints every second.
    function riskUsed(bytes32 roundId, uint64 ts) external view returns (uint256);

    /// @notice Bounds the vol keeper's next learned sigma for an open round and records it. Only the hook
    ///         calls it, from `IFallpitHook.setSigmaEff`, with the caller of that and the round's frozen
    ///         sigma. Reverts `OnlyVolKeeper` for any caller but `volKeeper()` and `SigmaEffTooSoon` within
    ///         `SIGMA_EFF_GAP` (5 minutes) of the round's last update.
    /// @return next the sigma in force from now on, WAD: within 10% of the sigma in force, within [0.8, 1.5]
    ///         x `sigma`, and a rise only while the product of the round's rises stays at most 1.5
    function stepSigmaEff(address caller, bytes32 roundId, uint256 sigma, uint256 proposed)
        external
        returns (uint256 next);

    /// @notice The learned sigma state of a round (`SigmaEffState`). `at + SIGMA_EFF_GAP` is the first time
    ///         the next update is accepted.
    function sigmaEffState(bytes32 roundId) external view returns (uint96 sigma, uint64 at, uint96 rise);

    /// @notice Recorded close of `ticker` on `day` (price 0 when none) and whether it is trustless. A late
    ///         close is included: this is the price the next round starts from.
    function closeOf(bytes32 ticker, uint32 day) external view returns (uint256 price, bool trustless);

    /// @notice The close that settles the rounds of `ticker` on `day`, and the end of a dispute of it (0
    ///         when it was never disputed): a round on a keeper close finalizes only once its challenge
    ///         window and the dispute are both over. All zero when there is no close or the close is late
    ///         (first recorded more than `MISSED_CLOSE` after its instant): a late close settles nothing.
    function closeState(bytes32 ticker, uint32 day)
        external
        view
        returns (uint256 price, bool trustless, uint64 disputeEnd);

    /// @notice May dispute a keeper close during the challenge window of a round settled on it (`dispute`).
    function guardian() external view returns (address);

    /// @notice May set the learned sigma of an open round on the hook (`IFallpitHook.setSigmaEff`, within
    ///         its clamps). Zero when nobody may.
    function volKeeper() external view returns (address);

    /// @notice Receives the protocol's share of the fees.
    function feeRecipient() external view returns (address);
}
