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
import {PitBookRules} from "./PitBookRules.sol";
import {PitBookLogic} from "./PitBookLogic.sol";

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
    uint256 private constant MIN_VAR = PitBookRules.MIN_VAR;
    uint256 private constant MAX_VAR = PitBookRules.MAX_VAR;
    /// @dev The close a round starts from is at most this many calendar days back: a Wednesday close
    ///      before two skipped days and a weekend is five days before Monday; six leaves one to spare.
    uint32 private constant MAX_CLOSE_AGE = PitBookLogic.MAX_CLOSE_AGE;
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
    uint64 public constant DISPUTE_WINDOW = PitBookLogic.DISPUTE_WINDOW;
    /// @notice A close not recorded this long after its instant is missed (`PitClock.MISSED_CLOSE`).
    uint64 public constant MISSED_CLOSE = PitClock.MISSED_CLOSE;
    /// @notice Least `OWNER_DELAY` on a mainnet chain (4663, 1, 42161, 8453).
    uint64 public constant MIN_MAINNET_DELAY = 24 hours;

    // bounds of the learned sigma (`stepSigmaEff`; the others are in `PitBookLogic`)
    /// @notice Least time between two updates of one round's learned sigma.
    uint256 public constant SIGMA_EFF_GAP = PitBookLogic.SIGMA_EFF_GAP;

    // defaults (the hard bounds of the owner-set defaults are in `PitBookRules`)
    /// @dev A fill is about 3.5M gas. At Robinhood Chain's 0.02 gwei that is 0.00007 ETH; with a margin of
    ///      30% for a busier chain, 0.000091 ETH, rounded to 0.0001.
    uint64 private constant DEFAULT_FILL_FEE = 0.000025 ether;
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

    /// @dev One recorded close. `multiplier` is the stock token's `uiMultiplier` when it was first recorded
    ///      (a replacement keeps it).
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

    /// @dev The latest print a fill of a round was priced by, and the risk the fills of that print took.
    struct RiskSum {
        uint64 ts;
        uint192 used;
    }

    /// @dev Per round, the latest print a fill was priced by and the risk its fills took (`takeRisk`).
    mapping(bytes32 roundId => RiskSum) internal _riskSum;
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

    /// @notice Accepts the oracle's refund of an unused update fee during `recordClose`, and nothing else:
    ///         ETH from anyone else would have no way out.
    receive() external payable {
        if (msg.sender != address(oracle)) revert EthNotAccepted();
    }

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
        uint256 kept = address(this).balance - msg.value;
        Ticker storage tk = _tickers[ticker];
        PitBookLogic.promote(_reseeds, ticker, tk);
        if (tk.varWad == 0) revert UnknownTicker();
        if (tk.clock == Clock.NYWeekdays && !NYTime.isWeekday(day)) revert NotTradingDay();
        uint64 closeAt = NYTime.closeTs(day);
        if (block.timestamp < closeAt) revert TooEarly();
        uint32 last = tk.lastCloseDay;
        bool fresh = block.timestamp <= closeAt + CLOSE_RECORD_WINDOW;
        if (msg.sender != owner && (!fresh || day < last)) revert CloseTooOld();
        uint256 price;
        bool trustless;
        {
            Close storage cl = _closes[ticker][day];
            if (cl.trustless) revert CloseIsFinal();

            (price,, trustless) = oracle.verifyCloseAt{value: msg.value}(ticker, closeAt, report);
            if (price == 0 || price > type(uint128).max) revert BadPrice();
            _writeClose(ticker, cl, price, trustless, closeAt);
        }
        _stepOnClose(ticker, tk, last, day, fresh);
        emit CloseRecorded(ticker, day, price, trustless, tk.varWad);

        _entered = false;
        // only the caller's ETH that the oracle did not spend goes back
        uint256 left = address(this).balance - kept;
        if (left != 0) SafeTransferLib.safeTransferETH(msg.sender, left);
    }

    /// @dev Writes a verified close into `cl`. A replacement of a keeper close by a keeper print is refused
    ///      after the dispute window, a second time, or within the oracle's bound of the close it replaces.
    function _writeClose(bytes32 ticker, Close storage cl, uint256 price, bool trustless, uint64 closeAt)
        private
    {
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
        // the multiplier of the first write: a replacement moves the price, never the corporate-action test
        if (old == 0) cl.multiplier = oracle.multiplier(ticker);
    }

    /// @dev The variance step of a recorded close on `day` (see `recordClose`); `last` is the newest close
    ///      day before it.
    function _stepOnClose(bytes32 ticker, Ticker storage tk, uint32 last, uint32 day, bool fresh) private {
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
        PitBookLogic.dispute(_closes, hook, roundId);
    }

    /// @inheritdoc IPitBook
    /// @dev Keyed by the print's own `ts`, not by the commit's instant t: one print prices every t in
    ///      `(prevTs, ts]`, so after a keeper gap many instants share one print, and they must share its one
    ///      budget too. One slot per round: the router fills a round's commits in commit order, their
    ///      instants never go back, and the print of an instant is the first at or after it, so a round's
    ///      prints never go back either. A later print starts its own sum. A fill priced by an earlier print
    ///      than the one stored (two keeper prints that cover the same instant) is charged to the stored sum
    ///      and keeps the stored ts: it cannot reset the sum, and a valid fill is never refused for its
    ///      order. Its budget is at most the stored print's (the depth scale never rises).
    function takeRisk(bytes32 roundId, uint64 ts, uint256 risk, uint256 budget) external returns (bool) {
        if (msg.sender != hook) revert OnlyHook();
        RiskSum memory s = _riskSum[roundId];
        if (ts < s.ts) ts = s.ts;
        uint256 used = (ts == s.ts ? s.used : 0) + risk;
        if (used > budget) return false;
        // used <= budget <= capital * riskCapBps / 1e4, capital at most 1e33 wei (the engine's depth check at
        // the open): far below 2^192
        _riskSum[roundId] = RiskSum({ts: ts, used: uint192(used)});
        return true;
    }

    /// @inheritdoc IPitBook
    function riskUsed(bytes32 roundId, uint64 ts) external view returns (uint256) {
        RiskSum memory s = _riskSum[roundId];
        return ts == s.ts ? s.used : 0;
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
        if (block.timestamp < uint256(sigmaEffState[roundId].at) + SIGMA_EFF_GAP) {
            revert IFallpitHook.SigmaEffTooSoon();
        }
        return PitBookLogic.stepSigmaEff(sigmaEffState, roundId, sigma, proposed);
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
        (weights, windows) = PitBookRules.tickerTerms(varWad, clock, weights, windows);
        PitBookLogic.registerTicker(
            _tickers,
            _reseeds,
            _tickerList,
            oracle,
            OWNER_DELAY,
            ticker,
            clock,
            Reseed({varWad: varWad, weights: weights, windows: windows, fillSource: fillSource, eta: 0})
        );
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
        PitBookRules.checkParams(p);
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
        (s0, sigma, clock, fillSource) =
            PitBookLogic.openTerms(_tickers, _reseeds, _closes, skip, skipAfterHours, ticker, day);
        params = defaultParams();
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
        return PitBookRules.defaultWeights(clock);
    }

    /// @inheritdoc IPitBook
    function closeOf(bytes32 ticker, uint32 day) external view returns (uint256 price, bool trustless) {
        Close storage cl = _closes[ticker][day];
        return (cl.price, cl.trustless);
    }

    /// @inheritdoc IPitBook
    function closeMultiplier(bytes32 ticker, uint32 day) external view returns (uint256) {
        return _closes[ticker][day].multiplier;
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
        return PitBookLogic.tickerOf(_tickers, _reseeds, ticker);
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
        return PitBookRules.packMenu(lo, hi);
    }

    /// @notice The band runs of a menu word: product i is `[lo[i], hi[i]]`.
    function unpackMenu(uint256 menu) external pure returns (uint8[] memory lo, uint8[] memory hi) {
        return PitBookRules.unpackMenu(menu);
    }

    /// @notice The scheduled parameters that are not in force yet (`eta` zero when none).
    function pendingDefaultParams() external view returns (Params memory p, uint64 eta) {
        eta = _pendingDefaultsEta;
        if (eta == 0 || block.timestamp >= eta) return (p, 0);
        p = _pendingDefaults;
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
        (bool ok, uint256 extra) = PitBookLogic.span(skip, ticker, clock, prev, day);
        if (!ok || a.multiplier != b.multiplier) return (false, varWad);
        return (true, PitBookRules.ewma(varWad, a.price, b.price, 1 + extra));
    }
}
