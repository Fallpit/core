// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IPitBook} from "./IPitBook.sol";
import {IPitOracle} from "../interfaces/IPitOracle.sol";
import {IFallpitHook} from "../interfaces/IFallpitHook.sol";
import {NYTime} from "../lib/NYTime.sol";
import {PitClock} from "./PitClock.sol";
import {PitMath} from "./PitMath.sol";

/// @title PitBook
/// @notice Closes, per-ticker volatility, the trading calendar and clock, default round parameters (the
///         menu of products included) and roles for the Fallpit hook. Split out of the hook only to keep the hook under the code size
///         limit: the hook reads it through an immutable address and copies what it needs into a round
///         when the round opens, so nothing here can change an open round.
/// @dev Holds no funds. The owner registers tickers, marks skipped days and skipped after-hours windows,
///      pauses the opening of new rounds, names the guardian, the vol keeper and the fee recipient, and sets the defaults
///      of future rounds inside hard bounds. Everything of the owner's that feeds the pricing of a round
///      (a new ticker, the default parameters, a reseed of a registered ticker's variance, clock weights or
///      fill source), the guardian and the vol keeper take effect only `OWNER_DELAY` (24 hours on mainnet, zero on a
///      testnet) after they were announced
///      on chain; a skip can be set only for a day whose close is at least `OWNER_DELAY` away. The
///      after-hours skip, the pause and the fee recipient are immediate (the first two only remove
///      trading). The guardian's only power is `dispute`: it holds a keeper close open for replacement
///      until one hour after its instant (`DISPUTE_WINDOW`); it cannot void or settle anything. The vol
///      keeper's only power is the hook's `setSigmaEff`: the learned sigma of an open round's remaining sd,
///      inside the clamps this book applies (`stepSigmaEff`: 0.8x to 1.5x of the round's sigma, at most 10%
///      per update, one update per 5 minutes, and all rises of one round together at most 1.5x).
contract PitBook is IPitBook {
    using FixedPointMathLib for uint256;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant EWMA_KEEP = 94;
    /// @dev A daily squared return enters the EWMA at most at (4 sigma)^2, sigma the variance's own before
    ///      the step: one jump (a crash, a missed corporate action) moves the variance by a bounded factor.
    uint256 private constant MAX_STEP_IN_VARIANCES = 16;
    uint256 private constant MIN_VAR = 0.005e18 * 0.005e18 / WAD;
    uint256 private constant MAX_VAR = 0.15e18 * 0.15e18 / WAD;
    /// @dev The close a round starts from is at most this many calendar days back: a Wednesday close
    ///      before two skipped days and a weekend is five days before Monday; six leaves one to spare.
    uint32 private constant MAX_CLOSE_AGE = 6;
    /// @notice How long after its instant anyone may record a close; later only the owner may.
    uint64 public constant CLOSE_RECORD_WINDOW = 3 days;
    /// @notice Delay between the owner announcing new default parameters, a new ticker, a ticker reseed or
    ///         a new guardian and their taking effect; also the least notice of a skipped day. Fixed at
    ///         deployment: 24 hours on mainnet, zero on a testnet so a fresh deployment is playable the
    ///         same day (the constructor takes it).
    uint64 public immutable OWNER_DELAY;
    /// @notice How long after its instant a disputed keeper close stays open for replacement. One hour: the
    ///         rounds on a disputed close finalize at 17:00 New York and the next rounds still open in the
    ///         after-hours of the same evening, so a dispute costs the ticker an hour of trading, not a day.
    uint64 public constant DISPUTE_WINDOW = 1 hours;
    /// @notice A close not recorded this long after its instant is missed (`PitClock.MISSED_CLOSE`).
    uint64 public constant MISSED_CLOSE = PitClock.MISSED_CLOSE;
    /// @notice Least `OWNER_DELAY` on a mainnet chain (4663, 1, 42161, 8453).
    uint64 public constant MIN_MAINNET_DELAY = 24 hours;

    // bounds of the learned sigma (`stepSigmaEff`)
    /// @notice Least time between two updates of one round's learned sigma.
    uint256 public constant SIGMA_EFF_GAP = 5 minutes;
    /// @dev One update moves the sigma in force by at most 10%, up or down.
    uint256 private constant SIGMA_STEP_BPS = 1000;
    /// @dev The learned sigma stays within [0.8, 1.5] x the round's frozen sigma.
    uint256 private constant SIGMA_LO_BPS = 8000;
    uint256 private constant SIGMA_HI_BPS = 15_000;
    /// @dev The product of all rises of one round's learned sigma is at most 1.5 (WAD): once the round has
    ///      risen by 1.5x in total, it can only fall. So a vol keeper cannot cycle the sigma up and down.
    uint256 private constant SIGMA_RISE_CAP = 1.5e18;

    // hard bounds of the owner-set defaults
    uint256 private constant MAX_ALPHA = 0.79e18;
    uint256 private constant MIN_BASE_FEE = 0.005e18;
    uint256 private constant MAX_BASE_FEE = 0.1e18;
    uint256 private constant MAX_CLOSE_FEE = 0.2e18;
    uint256 private constant MAX_VEGA_FEE = 1e18;
    uint256 private constant MAX_FEE_RAMP = 6.5 hours;
    /// @dev The next round of a house opens only when this one is final, and trades in the after-hours
    ///      from then on: the window is short. Five minutes is the least a guardian can act in.
    uint256 private constant MIN_CHALLENGE = 5 minutes;
    uint256 private constant MAX_CHALLENGE = 1 hours;
    /// @dev A commit is priced at least two seconds after it was made: one second is the resolution of
    ///      both clocks (the chain's and the oracle's), so one more keeps the print out of sight.
    uint256 private constant MIN_FILL_DELAY = 2;
    uint256 private constant MAX_FILL_DELAY = 60;
    /// @dev An unfilled commit stays fillable at its old print for this long: short, because for that
    ///      time it is an option on the price for its owner.
    uint256 private constant MIN_REFUND_DELAY = 10;
    uint256 private constant MAX_REFUND_DELAY = 120;
    /// @dev A regular session with less than this share of the variance would make the prior a near
    ///      point mass at the open.
    uint256 private constant MIN_REGULAR_WEIGHT = 2500;
    uint256 private constant MAX_PROTOCOL_FEE_BPS = 5000;
    /// @dev Smallest `alpha * minCapital` (alpha in WAD, minCapital in whole chips). `ILadderMath.openDepths`
    ///      refuses a depth below 1e14 wei, and the depth of band j is `alpha * capital / ln(1 / pi_j)` with
    ///      `ln(1 / pi_j)` below 9.3 for the floored prior. A round opens with at least `minCapital` whole
    ///      chips, which is `minCapital * 1e18` in the math's WAD units whatever the chip's decimals, so
    ///      `alpha * minCapital >= 9.3e14` opens every band. This bound keeps a margin on top.
    uint256 private constant MIN_ALPHA_TIMES_CAPITAL = 1e15;
    /// @dev `ILadderMath.openDepths` refuses a capital above 1e33 wei (1e15 whole chips).
    uint256 private constant MAX_MIN_CAPITAL = 1e15;
    /// @dev Bounds of the smallest trade: a millionth of a token to a thousand tokens.
    uint256 private constant MIN_MIN_TRADE = 1e12;
    uint256 private constant MAX_MIN_TRADE = 1_000e18;
    /// @dev Bounds of the per-round loss limit: a round may always put a tenth of its capital at risk
    ///      (less would stop ordinary trading at alpha 0.2), and never more than all of it.
    uint256 private constant MIN_LOSS_LIMIT_BPS = 1000;
    /// @dev Bounds of the risk budget per print second: from a tenth of a percent of capital to all of it
    ///      (the default is 300; the top of the range leaves the budget out of the way).
    uint256 private constant MIN_RISK_CAP_BPS = 10;
    uint256 private constant MAX_RISK_CAP_BPS = 10_000;
    /// @dev The floor of g (PitMath.G_FLOOR): the smallest risk budget is riskCapBps * 0.3.
    uint256 private constant G_FLOOR_TENTHS = 3;
    /// @dev The fill fee pays a filler's gas, nothing more: a hundred times the default is the ceiling.
    uint256 private constant MAX_FILL_FEE = 0.01 ether;
    /// @dev A fill is about 3.5M gas. At Robinhood Chain's 0.02 gwei that is 0.00007 ETH; with a margin of
    ///      30% for a busier chain, 0.000091 ETH, rounded to 0.0001.
    uint64 private constant DEFAULT_FILL_FEE = 0.0001 ether;
    /// @dev A buy is never charged more than a fifth of a chip per token by the minimum price alone.
    uint256 private constant MAX_MIN_PRICE = 0.2e18;
    /// @notice The menu a round gets unless the owner set another: 10 products (`PitMath` has the layout
    ///         of the word). Eight floors that partition the 40 bands, in standard deviations of the day
    ///         from the previous close: below -2, -2 to -1, -1 to -0.5, -0.5 to 0, 0 to 0.5, 0.5 to 1,
    ///         1 to 2, above 2. Then the beginner pair at the previous close: LOWER and HIGHER.
    uint256 public constant DEFAULT_MENU = 10 | (0x0b00 << 8) // floor 0: bands 0 to 11
        | (0x0f0c << 24) // floor 1: bands 12 to 15
        | (0x1110 << 40) // floor 2: bands 16 to 17
        | (0x1312 << 56) // floor 3: bands 18 to 19
        | (0x1514 << 72) // floor 4: bands 20 to 21
        | (0x1716 << 88) // floor 5: bands 22 to 23
        | (0x1b18 << 104) // floor 6: bands 24 to 27
        | (0x271c << 120) // floor 7: bands 28 to 39
        | (0x1300 << 136) // LOWER: bands 0 to 19
        | (0x2714 << 152); // HIGHER: bands 20 to 39

    /// @dev One recorded close. `multiplier` is the stock token's `uiMultiplier` when it was recorded.
    ///      `late`: first recorded more than `MISSED_CLOSE` after its instant, so it settles no round.
    struct Close {
        uint128 price;
        uint64 disputeEnd;
        bool trustless;
        bool replaced;
        bool late;
        uint256 multiplier;
    }

    IPitOracle public immutable oracle;
    /// @notice May call `setHook` once. Never changes.
    address public immutable deployer;
    /// @notice The Fallpit hook whose rounds `dispute` reads. Set once by the deployer.
    address public hook;
    /// @inheritdoc IPitBook
    mapping(bytes32 roundId => mapping(uint64 ts => uint256)) public riskUsed;
    /// @inheritdoc IPitBook
    mapping(bytes32 roundId => SigmaEffState) public sigmaEffState;

    address public owner;
    address public pendingOwner;
    /// @inheritdoc IPitBook
    address public feeRecipient;
    address private _guardian;
    address private _pendingGuardian;
    uint64 private _guardianEta;
    address private _volKeeper;
    address private _pendingVolKeeper;
    uint64 private _volKeeperEta;
    /// @notice True while opening new rounds is paused. Open rounds are never affected.
    bool public paused;
    bool private _entered;
    /// @dev When `_pendingDefaults` replaces `_defaults` (zero: nothing pending).
    uint64 private _pendingDefaultsEta;

    Params internal _defaults;
    Params internal _pendingDefaults;
    mapping(bytes32 ticker => Ticker) internal _tickers;
    mapping(bytes32 ticker => Reseed) internal _reseeds;
    mapping(bytes32 ticker => mapping(uint32 day => Close)) internal _closes;
    /// @notice Days on which no round may open for a ticker (holidays, earnings, corporate actions).
    mapping(bytes32 ticker => mapping(uint32 day => bool)) public skip;
    /// @notice Days whose round does not trade in the after-hours of the trading day before (for example
    ///         when earnings come out after that day's close). Read when the round opens.
    mapping(bytes32 ticker => mapping(uint32 day => bool)) public skipAfterHours;
    /// @dev Every ticker ever registered, in the order of its first registration (one entry each, pending
    ///      registrations included). Only the owner registers, so the list stays short.
    bytes32[] internal _tickerList;

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @param ownerDelay_ `OWNER_DELAY`: 24 hours on mainnet, zero on a testnet. On a mainnet chain id
    ///        (4663, 1, 42161, 8453) anything under 24 hours reverts
    constructor(IPitOracle oracle_, address owner_, uint64 ownerDelay_) {
        if (address(oracle_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        // Robinhood Chain, Ethereum, Arbitrum One, Base; a testnet (46630) or anvil (31337) takes any delay
        uint256 id = block.chainid;
        if (ownerDelay_ < MIN_MAINNET_DELAY && (id == 4663 || id == 1 || id == 42161 || id == 8453)) {
            revert DelayTooShort();
        }
        oracle = oracle_;
        deployer = msg.sender;
        owner = owner_;
        OWNER_DELAY = ownerDelay_;
        emit OwnershipTransferred(address(0), owner_);
        // Defaults from simulation: alpha 0.2, no product cap, loss limit 30%. A 10% product cap refused
        // about half of the retail flow while the loss limit at 30% protected the tail just as well;
        // alpha 0.2 takes a third off what a vol-informed trader can buy.
        _defaults = Params({
            alpha: 0.2e18,
            baseFee: 0.02e18,
            closeFee: 0.05e18,
            vegaFee: 0.1e18,
            feeRamp: 120 minutes,
            challengeWindow: 900,
            fillDelay: 2,
            refundDelay: 30,
            protocolFeeBps: 1000,
            maxFillBps: 2000,
            riskCapBps: 300,
            minCapital: 1000,
            minTrade: 1e18,
            lossLimitBps: 3000,
            fillFee: DEFAULT_FILL_FEE,
            floorCapBps: 10_000,
            minPriceWad: 0.02e18,
            menu: DEFAULT_MENU
        });
    }

    /// @notice Accepts the oracle's refund of an unused update fee during `recordClose`.
    receive() external payable {}

    /// @inheritdoc IPitBook
    /// @dev Who and when. Anyone may record a close until `CLOSE_RECORD_WINDOW` after its instant, and
    ///      never for a day before the newest recorded close; the owner is exempt from both limits, to
    ///      seed a ticker or to fill a gap. The print is the oracle's close print (`verifyCloseAt`: up to
    ///      the ticker's `closeMaxLag` after 16:00:00).
    ///
    ///      A missed close is final. From `MISSED_CLOSE` after a close's instant, a day with no close
    ///      counts as missed: the next round may open from the close before it, and that voids the
    ///      house's open round of the day (the hook). A close first recorded after that point is `late`:
    ///      it is stored, it is the start price of the next round and steps the variance like any close,
    ///      but `closeState` does not show it, so it never settles a round and never stops a void. So
    ///      nobody can choose between a void and a settlement once the close's result is known.
    ///
    ///      Replacement. A trustless print replaces a keeper close and is final. A keeper print replaces
    ///      a keeper close only while the guardian's dispute of it runs, only once, and only when it
    ///      differs from the recorded close by more than the oracle's bound for the ticker: two valid
    ///      prints for one instant exist only when signers equivocated, and these rules keep anyone
    ///      holding a second one from moving the close by a band on a whim or from trading
    ///      replacements back and forth until the last word.
    ///
    ///      The EWMA variance moves only on a real step: `day` is the next round's day after the newest
    ///      recorded close (at most `MAX_CLOSE_AGE` days later, with only weekends and skipped or missed
    ///      days in between), the close is recorded inside the window, and the stock token's multiplier is
    ///      the same as at the close before (a split or other corporate action changes it: the close is
    ///      stored without a step). The squared log return is divided by the trading days it spans (one
    ///      plus the skipped or missed weekdays in between, `_span`) and capped at 16 times the variance
    ///      before the step. Any other close is stored, and may become the newest, without touching the
    ///      variance, so nobody can walk the variance by choosing which old days to record. A replacement
    ///      of the newest close redoes its step.
    ///
    ///      `msg.value` pays the oracle's update fee; what the oracle refunds goes back to the caller.
    function recordClose(bytes32 ticker, uint32 day, bytes calldata report) external payable {
        if (_entered) revert Reentrancy();
        _entered = true;
        Ticker storage tk = _tickers[ticker];
        _promoteReseed(ticker, tk);
        if (tk.varWad == 0) revert UnknownTicker();
        if (tk.clock == Clock.NYWeekdays && !NYTime.isWeekday(day)) revert NotTradingDay();
        uint64 closeAt = NYTime.closeTs(day);
        if (block.timestamp < closeAt) revert TooEarly();
        uint32 last = tk.lastCloseDay;
        bool fresh = block.timestamp <= closeAt + CLOSE_RECORD_WINDOW;
        if (msg.sender != owner && (!fresh || day < last)) revert CloseTooOld();
        Close storage cl = _closes[ticker][day];
        if (cl.trustless) revert CloseIsFinal();

        (uint256 price,, bool trustless) = oracle.verifyCloseAt{value: msg.value}(ticker, closeAt, report);
        if (price == 0 || price > type(uint128).max) revert BadPrice();
        uint256 old = cl.price;
        if (old == 0 && block.timestamp > closeAt + MISSED_CLOSE) cl.late = true;
        if (old != 0 && !trustless) {
            uint256 diff = price > old ? price - old : old - price;
            if (
                block.timestamp >= cl.disputeEnd || cl.replaced || diff * BPS <= old * oracle.boundBps(ticker)
            ) revert ReplacementRefused();
            cl.replaced = true;
        }
        cl.price = uint128(price);
        cl.trustless = trustless;
        cl.multiplier = oracle.multiplier(ticker);

        if (day > last) {
            uint256 v = tk.varWad;
            bool stepped;
            if (last != 0 && fresh) (stepped, v) = _step(ticker, tk.clock, last, day, v);
            tk.varBefore = tk.varWad;
            tk.varWad = v;
            tk.prevCloseDay = last;
            tk.lastCloseDay = day;
            tk.lastCloseStepped = stepped;
        } else if (day == last && tk.lastCloseStepped) {
            (tk.lastCloseStepped, tk.varWad) = _step(ticker, tk.clock, tk.prevCloseDay, day, tk.varBefore);
        }
        emit CloseRecorded(ticker, day, price, trustless, tk.varWad);

        _entered = false;
        uint256 left = address(this).balance;
        if (left != 0) SafeTransferLib.safeTransferETH(msg.sender, left);
    }

    /// @notice Disputes the keeper close a round was settled on. Only the guardian, only during that
    ///         round's challenge window, only for a close that is not trustless, and only while the dispute
    ///         window is still ahead: before `DISPUTE_WINDOW` (one hour) after the close's instant. Every
    ///         round on the close (every house of the ticker) then finalizes only from that moment on, and
    ///         until then anyone may replace the close (`recordClose`): with a trustless print, or once
    ///         with another keeper print for the same instant that differs by more than the oracle's bound.
    ///         After that the rounds finalize on the latest close. A dispute moves no funds and decides
    ///         nothing: it only gives a correction time to arrive.
    /// @dev A close settled late (recorded after about 16:45) leaves no window to dispute in: the call
    ///      reverts rather than record a dispute that would hold nothing.
    function dispute(bytes32 roundId) external {
        if (msg.sender != guardian()) revert OnlyGuardian();
        IFallpitHook h = IFallpitHook(hook);
        IFallpitHook.RoundConfig memory c = h.getConfig(roundId);
        IFallpitHook.RoundState memory st = h.getState(roundId);
        Close storage cl = _closes[c.ticker][c.day];
        uint64 until = NYTime.closeTs(c.day) + DISPUTE_WINDOW;
        if (
            st.status != IFallpitHook.Status.Settled || st.settledTrustless || cl.trustless
                || block.timestamp >= uint256(st.settledAt) + c.params.challengeWindow
                || block.timestamp >= until
        ) revert DisputeNotAllowed();
        cl.disputeEnd = until;
        emit CloseDisputed(c.ticker, c.day, roundId, until);
    }

    /// @inheritdoc IPitBook
    /// @dev Keyed by the print's own `ts`, not by the commit's instant t: one print prices every t in
    ///      `(prevTs, ts]`, so after a keeper gap many instants share one print, and they must share its one
    ///      budget too. One slot that reset when ts changed could be bypassed by
    ///      interleaving fills of two prints, so every print has its own slot.
    function takeRisk(bytes32 roundId, uint64 ts, uint256 risk, uint256 budget) external returns (bool) {
        if (msg.sender != hook) revert OnlyHook();
        uint256 used = riskUsed[roundId][ts] + risk;
        if (used > budget) return false;
        riskUsed[roundId][ts] = used;
        return true;
    }

    /// @inheritdoc IPitBook
    /// @dev The bounds, in this order: one update per `SIGMA_EFF_GAP`; within 10% of the sigma in force;
    ///      within [0.8, 1.5] x the round's sigma (the sigma in force is always inside, so the result is
    ///      inside both ranges); and a rise only as far as the round's rise budget allows (the product of
    ///      all its rises at most 1.5). In simulation a 1.5x top keeps most of the mean gain of learning;
    ///      the 0.8x floor and the rise budget are for safety against the vol keeper.
    function stepSigmaEff(address caller, bytes32 roundId, uint256 sigma, uint256 proposed)
        external
        returns (uint256 next)
    {
        if (msg.sender != hook) revert OnlyHook();
        if (caller != volKeeper()) revert IFallpitHook.OnlyVolKeeper();
        SigmaEffState memory cur = sigmaEffState[roundId];
        if (block.timestamp < uint256(cur.at) + SIGMA_EFF_GAP) revert IFallpitHook.SigmaEffTooSoon();
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
            SigmaEffState({sigma: uint96(next), at: uint64(block.timestamp), rise: uint96(rise)});
    }

    /// @notice The risk budget of one print second (WAD chips): `capital * riskCapBps * g / 1e4`, capital in
    ///         the chip's units, g WAD.
    function riskBudgetOf(uint256 capital, uint8 decimals, uint256 riskCapBps, uint256 g)
        public
        pure
        returns (uint256)
    {
        return PitMath.riskBudget(capital, decimals, riskCapBps, g);
    }

    /// @notice Wires the hook whose rounds `dispute` reads: once, by the deployer, and only a hook that
    ///         reads this book.
    function setHook(address hook_) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (hook != address(0)) revert HookAlreadySet();
        if (hook_.code.length == 0 || address(IFallpitHook(hook_).book()) != address(this)) revert BadHook();
        hook = hook_;
        emit HookSet(hook_);
    }

    /// @notice Registers a ticker, or schedules a reseed of one that is registered already. Both take
    ///         effect `OWNER_DELAY` from now (a second call replaces the scheduled one and restarts the
    ///         clock; `pendingReseed` shows what waits, a new ticker included). Until a new ticker is in
    ///         force nothing can be done with it: no close, no round, no house (`supported` is false).
    ///         A reseed replaces the variance, the clock weights, the trading windows and the fill source;
    ///         until it is in force rounds keep opening on the current values. Rounds already open keep
    ///         their frozen sigma and clock either way. The clock is chosen with the first registration
    ///         (a second call before it is in force may change it); a reseed must repeat it.
    /// @param varWad daily variance of close-to-close log returns, WAD, within [0.005^2, 0.15^2]
    /// @param clock `NYWeekdays` for a stock, `EveryDay` for an asset that trades around the clock
    /// @param weights variance weights of the clock's segments, basis points summing to 10000 with at
    ///        least 2500 in the regular session; `EveryDay` takes (0, 0, 0, 10000). All zero: the
    ///        defaults (6%, 14%, 10%, 70% for `NYWeekdays`)
    /// @param windows which windows of a `NYWeekdays` round trade: a mask of 1 after-hours, 2 overnight,
    ///        4 pre-market, 8 regular session, always with the regular session. Zero: the default (13:
    ///        everything but the nights). `EveryDay` trades around the clock and takes zero only
    /// @param fillSource oracle source that prices the fills of future rounds
    function registerTicker(
        bytes32 ticker,
        uint256 varWad,
        Clock clock,
        Weights memory weights,
        uint8 windows,
        FillSource fillSource
    ) external onlyOwner {
        if (uint256(weights.afterHours) + weights.gap + weights.preMarket + weights.regular == 0) {
            weights = defaultWeights(clock);
        }
        if (clock == Clock.EveryDay) {
            if (windows != 0) revert BadParams();
            windows = PitClock.ALL_WINDOWS;
        } else if (windows == 0) {
            windows = PitClock.DEFAULT_WINDOWS;
        }
        if (
            varWad < MIN_VAR || varWad > MAX_VAR
                || uint256(weights.afterHours) + weights.gap + weights.preMarket + weights.regular != BPS
                || weights.regular < (clock == Clock.EveryDay ? BPS : MIN_REGULAR_WEIGHT)
                || windows > PitClock.ALL_WINDOWS || windows & PitClock.REGULAR == 0
        ) {
            revert BadParams();
        }
        if (!oracle.supported(ticker)) revert UnknownTicker();
        Ticker storage tk = _tickers[ticker];
        _promoteReseed(ticker, tk);
        if (tk.varWad == 0) {
            // a first registration (not a second call before the first is in force) joins the list
            if (_reseeds[ticker].eta == 0) _tickerList.push(ticker);
            tk.clock = clock;
        } else if (clock != tk.clock) {
            revert BadParams();
        }
        uint64 eta = uint64(block.timestamp) + OWNER_DELAY;
        _reseeds[ticker] =
            Reseed({varWad: varWad, weights: weights, windows: windows, fillSource: fillSource, eta: eta});
        emit TickerRegistered(ticker, varWad, clock, weights, windows, fillSource, eta);
    }

    /// @notice Marks a day on which no round may open for `ticker` (or clears the mark). Only for a day
    ///         whose close is at least `OWNER_DELAY` away: a skip changes the horizon of the round after
    ///         it, so it comes with the same notice as everything else that prices a round.
    function setSkip(bytes32 ticker, uint32 day, bool skipped) external onlyOwner {
        if (NYTime.closeTs(day) < block.timestamp + OWNER_DELAY) revert SkipTooLate();
        skip[ticker][day] = skipped;
        emit SkipSet(ticker, day, skipped);
    }

    /// @notice Marks a day whose round does not trade in the after-hours of the trading day before.
    ///         Immediate, and read when that round opens: set it before the close of the day before.
    ///         An `EveryDay` ticker has no after-hours window and ignores it.
    function setSkipAfterHours(bytes32 ticker, uint32 day, bool skipped) external onlyOwner {
        skipAfterHours[ticker][day] = skipped;
        emit SkipAfterHoursSet(ticker, day, skipped);
    }

    /// @notice Pauses or resumes opening new rounds.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Names the guardian (zero for none), from `OWNER_DELAY` on. A second call replaces the one
    ///         waiting and restarts the clock.
    function setGuardian(address guardian_) external onlyOwner {
        if (_guardianEta != 0 && block.timestamp >= _guardianEta) _guardian = _pendingGuardian;
        uint64 eta = uint64(block.timestamp) + OWNER_DELAY;
        _pendingGuardian = guardian_;
        _guardianEta = eta;
        emit GuardianSet(guardian_, eta);
    }

    /// @inheritdoc IPitBook
    function guardian() public view returns (address) {
        return _guardianEta != 0 && block.timestamp >= _guardianEta ? _pendingGuardian : _guardian;
    }

    /// @notice The guardian named and not in force yet (`eta` zero when none).
    function pendingGuardian() external view returns (address next, uint64 eta) {
        eta = _guardianEta;
        if (eta == 0 || block.timestamp >= eta) return (address(0), 0);
        next = _pendingGuardian;
    }

    /// @notice Names the vol keeper (zero for none), from `OWNER_DELAY` on. A second call replaces the one
    ///         waiting and restarts the clock.
    function setVolKeeper(address volKeeper_) external onlyOwner {
        if (_volKeeperEta != 0 && block.timestamp >= _volKeeperEta) _volKeeper = _pendingVolKeeper;
        uint64 eta = uint64(block.timestamp) + OWNER_DELAY;
        _pendingVolKeeper = volKeeper_;
        _volKeeperEta = eta;
        emit VolKeeperSet(volKeeper_, eta);
    }

    /// @inheritdoc IPitBook
    function volKeeper() public view returns (address) {
        return _volKeeperEta != 0 && block.timestamp >= _volKeeperEta ? _pendingVolKeeper : _volKeeper;
    }

    /// @notice Names the receiver of the protocol's fee share.
    function setFeeRecipient(address recipient) external onlyOwner {
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice Schedules new parameters for future rounds, within the hard bounds. They apply to rounds
    ///         opened from `OWNER_DELAY` after this call; a second call replaces the scheduled set and
    ///         restarts the clock.
    /// @dev `minCapital` must be large enough for the pricing engine to open a round at this `alpha`: a
    ///      round whose capital passes the hook's `minCapital` check never fails in `openDepths` for being
    ///      too small. `minTrade` must fit under the per-fill cap and under the product cap of a round at
    ///      `minCapital`, so the smallest allowed round can still trade every product. The menu must be
    ///      well formed (`PitMath.validMenu`): 2 to 12 products, each a run of bands `lo <= hi <= 39`.
    function setDefaultParams(Params calldata p) external onlyOwner {
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
        ) revert BadParams();
        if (_pendingDefaultsEta != 0 && block.timestamp >= _pendingDefaultsEta) _defaults = _pendingDefaults;
        uint64 eta = uint64(block.timestamp) + OWNER_DELAY;
        _pendingDefaults = p;
        _pendingDefaultsEta = eta;
        emit DefaultParamsSet(p, eta);
    }

    /// @notice Starts a two-step ownership transfer.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(newOwner);
    }

    /// @notice Completes the transfer; only the pending owner.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert OnlyOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @inheritdoc IPitBook
    /// @dev S0 is the newest recorded close, and it must be the close the round of `day` starts from: at
    ///      most `MAX_CLOSE_AGE` calendar days back, and every day in between that would have had a round
    ///      (a weekday for `NYWeekdays`, every day for `EveryDay`) either skipped or missed (its close not
    ///      recorded `MISSED_CLOSE` after its instant). This also stops anyone from opening a round further
    ///      ahead than the next one.
    ///
    ///      The round spans `1 + k` trading days, k the skipped or missed days in between, and is priced on
    ///      all of them: sigma is the daily sigma times `sqrt(1 + k)`. Weekends are inside the daily EWMA
    ///      already (it is close to close) and are not counted. For `NYWeekdays` the extra `k` days of
    ///      variance sit in the gap: the frozen weights are the ticker's divided by `1 + k`, and the gap
    ///      gets the rest, so the after-hours, the pre-market and the regular session keep one day's share
    ///      each. `EveryDay` needs no change: its rho is one straight line from close to close.
    function openTerms(bytes32 ticker, uint32 day)
        external
        view
        returns (
            uint256 s0,
            uint256 sigma,
            RoundClock memory clock,
            FillSource fillSource,
            Params memory params
        )
    {
        if (paused) revert OpeningPaused();
        Ticker memory tk = getTicker(ticker);
        if (tk.varWad == 0) revert UnknownTicker();
        bool everyDay = tk.clock == Clock.EveryDay;
        if ((!everyDay && !NYTime.isWeekday(day)) || skip[ticker][day]) revert NotTradingDay();
        uint32 last = tk.lastCloseDay;
        if (last >= day || day - last > MAX_CLOSE_AGE) revert NoRecentClose();
        (bool ok, uint256 extra) = _span(ticker, tk.clock, last, day);
        if (!ok) revert NotNextTradingDay();
        uint256 n = 1 + extra;
        Weights memory w = tk.weights;
        if (!everyDay && extra != 0) {
            w.afterHours = uint16(w.afterHours / n);
            w.preMarket = uint16(w.preMarket / n);
            w.regular = uint16(w.regular / n);
            w.gap = uint16(BPS - w.afterHours - w.preMarket - w.regular);
        }
        clock = RoundClock({
            kind: tk.clock,
            skipAfterHours: !everyDay && skipAfterHours[ticker][day],
            windows: tk.windows,
            prevDay: last,
            day: day,
            afterHours: w.afterHours,
            gap: w.gap,
            preMarket: w.preMarket,
            regular: w.regular
        });
        return (_closes[ticker][last].price, (tk.varWad * n).sqrtWad(), clock, tk.fillSource, defaultParams());
    }

    /// @inheritdoc IPitBook
    function clockAt(RoundClock calldata clock, uint64 ts)
        external
        pure
        returns (uint256 rho, bool tradable)
    {
        return PitClock.at(clock, ts);
    }

    /// @notice The weights a ticker registered with all-zero weights gets: 6% after-hours, 14% gap, 10%
    ///         pre-market and 70% regular session for `NYWeekdays`, one segment for `EveryDay`.
    function defaultWeights(Clock clock) public pure returns (Weights memory) {
        return clock == Clock.EveryDay ? Weights(0, 0, 0, uint16(BPS)) : Weights(600, 1400, 1000, 7000);
    }

    /// @inheritdoc IPitBook
    function closeOf(bytes32 ticker, uint32 day) external view returns (uint256 price, bool trustless) {
        Close storage cl = _closes[ticker][day];
        return (cl.price, cl.trustless);
    }

    /// @inheritdoc IPitBook
    function closeState(bytes32 ticker, uint32 day)
        external
        view
        returns (uint256 price, bool trustless, uint64 disputeEnd)
    {
        Close storage cl = _closes[ticker][day];
        if (cl.late) return (0, false, 0);
        return (cl.price, cl.trustless, cl.disputeEnd);
    }

    /// @notice Everything recorded about the close of `ticker` on `day`.
    function closeInfo(bytes32 ticker, uint32 day) external view returns (Close memory) {
        return _closes[ticker][day];
    }

    /// @notice True when houses of `ticker` may be created (the vault's gate): the ticker's registration
    ///         is in force and the oracle supports it.
    function supported(bytes32 ticker) external view returns (bool) {
        return getTicker(ticker).varWad != 0 && oracle.supported(ticker);
    }

    /// @notice Every ticker ever registered, in the order of its first registration, those whose
    ///         registration is not in force yet included (`getTicker` and `pendingReseed` tell which).
    function tickers() external view returns (bytes32[] memory) {
        return _tickerList;
    }

    /// @notice Volatility state, clock and fill source of a ticker as they apply now (a scheduled reseed that
    ///         has come into force included; all zero when not registered).
    function getTicker(bytes32 ticker) public view returns (Ticker memory tk) {
        tk = _tickers[ticker];
        Reseed storage r = _reseeds[ticker];
        if (r.eta != 0 && block.timestamp >= r.eta) {
            tk.varWad = r.varWad;
            tk.varBefore = r.varWad;
            tk.weights = r.weights;
            tk.windows = r.windows;
            tk.fillSource = r.fillSource;
            tk.lastCloseStepped = false;
        }
    }

    /// @notice The reseed of `ticker` that is scheduled and not in force yet, or its registration while it
    ///         is not in force yet (`eta` zero when none).
    function pendingReseed(bytes32 ticker) external view returns (Reseed memory r) {
        r = _reseeds[ticker];
        if (r.eta == 0 || block.timestamp >= r.eta) delete r;
    }

    /// @notice Parameters a round opened now gets.
    function defaultParams() public view returns (Params memory) {
        return
            _pendingDefaultsEta != 0 && block.timestamp >= _pendingDefaultsEta ? _pendingDefaults : _defaults;
    }

    /// @notice Packs band runs into the `menu` word of `Params`: product i is the run `[lo[i], hi[i]]`.
    ///         Reverts unless the result is a menu `setDefaultParams` accepts.
    function packMenu(uint8[] calldata lo, uint8[] calldata hi) external pure returns (uint256 menu) {
        if (lo.length != hi.length || lo.length > PitMath.MAX_PRODUCTS) revert BadParams();
        menu = PitMath.pack(lo, hi);
        if (!PitMath.validMenu(menu)) revert BadParams();
    }

    /// @notice The band runs of a menu word: product i is `[lo[i], hi[i]]`.
    function unpackMenu(uint256 menu) external pure returns (uint8[] memory lo, uint8[] memory hi) {
        uint256 n = PitMath.count(menu);
        lo = new uint8[](n);
        hi = new uint8[](n);
        for (uint256 i; i < n; ++i) {
            (lo[i], hi[i]) = PitMath.run(menu, i);
        }
    }

    /// @notice The scheduled parameters that are not in force yet (`eta` zero when none).
    function pendingDefaultParams() external view returns (Params memory p, uint64 eta) {
        eta = _pendingDefaultsEta;
        if (eta == 0 || block.timestamp >= eta) return (p, 0);
        p = _pendingDefaults;
    }

    /// @dev Writes a reseed that has come into force into the ticker, before the ticker changes.
    function _promoteReseed(bytes32 ticker, Ticker storage tk) private {
        Reseed storage r = _reseeds[ticker];
        if (r.eta == 0 || block.timestamp < r.eta) return;
        tk.varWad = r.varWad;
        tk.varBefore = r.varWad;
        tk.weights = r.weights;
        tk.windows = r.windows;
        tk.fillSource = r.fillSource;
        // the newest close's step was made on the variance the reseed replaced: nothing to redo
        tk.lastCloseStepped = false;
        delete _reseeds[ticker];
    }

    /// @dev Whether the round of `day` may start from the close of `last`, and how many days without a
    ///      close it spans besides its own. Every day strictly between that would have had a round (a
    ///      weekday for `NYWeekdays`, any day for `EveryDay`) must be skipped, or missed: its close not
    ///      recorded `MISSED_CLOSE` after its instant (`last` is the newest close, so a day after it has
    ///      none). Each such day counts in `extra`. At most `MAX_CLOSE_AGE` days.
    function _span(bytes32 ticker, Clock clock, uint32 last, uint32 day)
        private
        view
        returns (bool ok, uint256 extra)
    {
        if (day <= last || day - last > MAX_CLOSE_AGE) return (false, 0);
        for (uint32 d = last + 1; d < day; ++d) {
            if (clock == Clock.NYWeekdays && !NYTime.isWeekday(d)) continue;
            if (!skip[ticker][d] && block.timestamp <= NYTime.closeTs(d) + MISSED_CLOSE) return (false, 0);
            ++extra;
        }
        return (true, extra);
    }

    /// @dev The variance after the close of `day` that follows the close of `prev`: one EWMA step on the
    ///      squared log return divided by the trading days it spans, or no step (`stepped` false) when the
    ///      two closes are not consecutive rounds or the stock token's multiplier changed between them.
    function _step(bytes32 ticker, Clock clock, uint32 prev, uint32 day, uint256 varWad)
        private
        view
        returns (bool stepped, uint256)
    {
        Close storage a = _closes[ticker][prev];
        Close storage b = _closes[ticker][day];
        (bool ok, uint256 extra) = _span(ticker, clock, prev, day);
        if (!ok || a.multiplier != b.multiplier) return (false, varWad);
        return (true, _ewma(varWad, a.price, b.price, 1 + extra));
    }

    /// @dev EWMA of the daily variance with weight 0.94 on the past, clamped to [0.005^2, 0.15^2]. The new
    ///      observation is the squared log return over `periods` trading days divided by `periods`, at most
    ///      `MAX_STEP_IN_VARIANCES` times `varWad`.
    function _ewma(uint256 varWad, uint256 previousClose, uint256 close, uint256 periods)
        private
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
}
