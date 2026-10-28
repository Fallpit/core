// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {IPitOracle} from "./interfaces/IPitOracle.sol";
import {IPyth} from "./oracle/IPyth.sol";
import {IChainlinkFeed} from "./oracle/IChainlinkFeed.sol";
import {IStockToken} from "./oracle/IStockToken.sol";

/// @title PitOracle
/// @notice Free price verification for stock tickers. See contracts/SPEC.md section 4.
/// @dev `verifyAt(ticker, t, report)` accepts exactly one print per source for an instant `t`: the first
///      print at or after `t` (`prevTs < t <= ts <= t + maxLag`). `verifyCloseAt` is the same with the
///      ticker's `closeMaxLag` instead of `maxLag`: the book uses it for a close, so that a keeper that is
///      down for a few seconds at 16:00:00 still produces the close (the first print after the outage covers
///      16:00:00 and is at most `closeMaxLag` late). The first byte of `report` picks the source:
///
///      - `0x01` Pyth: the rest is a Hermes update blob, verified by the Pyth core contract with
///        `parsePriceFeedUpdatesUnique`. Trustless: the publisher network signed it.
///      - `0x02` keeper: the rest is `abi.encode(Print, bytes[] signatures)`, an EIP-712 print signed by
///        `threshold` members of the signer set, and always bounded by the Chainlink-style push feed of
///        the stock token divided by the token's `uiMultiplier()`. A ticker without such a feed has no
///        keeper source.
///
///      The contract keeps no price and no per-print state, and it holds no funds: `msg.value` pays the Pyth
///      fee and the rest goes back to the caller in the same call. It is not upgradeable.
///
///      What the owner can and cannot do. A ticker's Pyth feed id and its (aggregator, stock token) pair
///      are each set once: afterwards a source can be switched off and on again, never pointed somewhere
///      else. Nothing the owner does can change which close is accepted for a round that is already open:
///      every change that can (the signer set and the threshold, a change of a ticker's configuration that
///      is set already, including the fill-in of a missing source, and switching a source off for closes)
///      waits `SIGNER_DELAY` (24 hours on mainnet, zero on a testnet) before it takes effect, in the open,
///      and can be cancelled. A source switched off for closes refuses only the closes whose instant is
///      `SIGNER_DELAY` or more after the switch: a weekday round opens at most a day before its close, so
///      a switch made after it opened never reaches its close, whenever that close is recorded; and no
///      switch reaches a close whose result is known. Immediate are only: the first configuration of a
///      ticker (nothing verifies for it before), switching a source back on, and the emergency brake: a
///      source switched off stops verifying fills (`verifyAt`) at once. The brake never reaches
///      `verifyCloseAt`, so it cannot stop or pick a close; a stopped fill is never final, and its commit
///      is refunded when its window ends. The signer set and the threshold given at construction are in
///      force at once.
contract PitOracle is IPitOracle, Ownable {
    /// @notice A keeper-signed price print.
    /// @param ticker stock ticker, left-aligned ASCII
    /// @param price price of the underlying stock in USD, WAD
    /// @param ts timestamp of this print, unix seconds
    /// @param prevTs timestamp of the keeper's previous print for the same ticker (strictly before `ts`)
    struct Print {
        bytes32 ticker;
        uint256 price;
        uint64 ts;
        uint64 prevTs;
    }

    /// @notice Per-ticker configuration.
    /// @param pythFeedId Pyth price feed id, zero when the ticker has no Pyth source
    /// @param aggregator Chainlink push feed proxy of the stock token, zero when there is none
    /// @param stockToken token read for `uiMultiplier()`, zero when the feed prices the underlying itself
    /// @param maxLag how far after `t` a print may be, seconds
    /// @param maxConfBps largest Pyth confidence interval accepted, in basis points of the price
    /// @param boundBps largest distance of a keeper print from the Chainlink reference, basis points
    /// @param maxFeedAge oldest Chainlink round accepted as the reference, seconds before the print
    /// @param closeMaxLag how far after `t` a print may be when it is verified as a close (`verifyCloseAt`),
    ///        seconds
    struct TickerConfig {
        bytes32 pythFeedId;
        address aggregator;
        address stockToken;
        uint32 maxLag;
        uint16 maxConfBps;
        uint16 boundBps;
        uint32 maxFeedAge;
        uint32 closeMaxLag;
    }

    uint8 internal constant SOURCE_PYTH = 0x01;
    uint8 internal constant SOURCE_KEEPER = 0x02;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 1e4;

    uint32 public constant DEFAULT_MAX_LAG = 30;
    uint16 public constant DEFAULT_MAX_CONF_BPS = 100;
    /// @dev The floor under this number is the push feed itself: it reports a move of 0.5% or more, so an
    ///      honest price can sit up to about 50 bps from the last round. 60 leaves 10 bps for the feed's
    ///      own lateness and rounding; anything under about 55 would refuse honest prints.
    uint16 public constant DEFAULT_BOUND_BPS = 60;
    /// @dev The push feeds have a 24 hour heartbeat during the 24/5 session and none over a weekend, so a
    ///      healthy round can be three days old on a Monday morning, four after a long weekend.
    uint32 public constant DEFAULT_MAX_FEED_AGE = 5 days;

    /// @dev Five minutes: a keeper restart or a short loss of quorum at the bell still gives a close.
    uint32 public constant DEFAULT_CLOSE_MAX_LAG = 300;

    uint32 public constant MAX_MAX_LAG = 300;
    uint32 public constant MIN_CLOSE_MAX_LAG = 60;
    uint32 public constant MAX_CLOSE_MAX_LAG = 900;
    uint16 public constant MAX_MAX_CONF_BPS = 500;
    uint16 public constant MAX_BOUND_BPS = 100;
    uint256 public constant MAX_SIGNERS = 32;

    /// @notice A Chainlink round that lands at most this long after a print also counts as its reference: the
    ///         push feed reports a 0.5% move some seconds after it happens, so a correct print can lead it.
    uint256 public constant FEED_GRACE = 60;
    /// @notice How many rounds `verifyAt` walks back from the latest one to find those around a print.
    uint256 public constant MAX_ROUND_WALK = 64;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("Fallpit PitOracle");
    bytes32 internal constant VERSION_HASH = keccak256("1");
    /// @notice EIP-712 type hash of `Print`.
    bytes32 public constant PRINT_TYPEHASH =
        keccak256("Print(bytes32 ticker,uint256 price,uint64 ts,uint64 prevTs)");

    /// @dev Half the secp256k1 group order: signatures with a larger `s` are the malleable twin.
    uint256 internal constant SECP256K1_HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @notice How long a change of the signer set or the threshold waits before it takes effect. Fixed at
    ///         deployment: 24 hours on mainnet, zero on a testnet (the constructor takes it).
    uint64 public immutable SIGNER_DELAY;
    /// @notice Least `SIGNER_DELAY` on a mainnet chain (4663, 1, 42161, 8453).
    uint64 public constant MIN_MAINNET_DELAY = 24 hours;

    /// @notice The Pyth core contract.
    IPyth public immutable pyth;

    /// @dev A signer set with its threshold. Sets are never edited: a change writes a new one.
    struct SignerSet {
        address[] members;
        uint256 threshold;
        mapping(address => bool) isMember;
    }

    mapping(uint256 id => SignerSet) internal _sets;
    /// @dev Set in force until `_pendingFrom`; the pending one takes over from that instant on.
    uint64 internal _activeId;
    uint64 internal _pendingId;
    uint64 internal _pendingFrom;
    uint64 internal _lastId;

    /// @dev The configuration in force, unless `TickerState.configFrom` has passed: then `_pendingConfig`.
    mapping(bytes32 ticker => TickerConfig) internal _config;
    /// @dev A configuration change that waits until `TickerState.configFrom`.
    mapping(bytes32 ticker => TickerConfig) internal _pendingConfig;

    /// @dev Per ticker, in one slot: when a queued configuration change takes effect (0: none), and the
    ///      switches of the two sources. A source switched off (`...Off`) verifies no fill at once and no
    ///      close for an instant at or after `...CloseOffFrom` (0: closes on).
    struct TickerState {
        uint64 configFrom;
        uint64 pythCloseOffFrom;
        uint64 keeperCloseOffFrom;
        bool pythOff;
        bool keeperOff;
    }

    mapping(bytes32 ticker => TickerState) internal _state;

    /// @notice A configuration that is in force from now on.
    event TickerSet(bytes32 indexed ticker, TickerConfig config);
    /// @notice A configuration change that takes effect at `activeFrom`.
    event TickerChangeScheduled(bytes32 indexed ticker, TickerConfig config, uint64 activeFrom);
    event TickerChangeCancelled(bytes32 indexed ticker);
    /// @param closesOffFrom the first close instant the source refuses (0 when it was switched back on)
    event SourceDisabledSet(
        bytes32 indexed ticker, uint8 indexed source, bool disabled, uint64 closesOffFrom
    );
    /// @param activeFrom when the set takes effect (the block time itself for the constructor's set)
    event SignersScheduled(address[] signers, uint256 threshold, uint64 activeFrom);
    event SignerChangeCancelled();

    error ZeroAddress();
    error MalformedReport();
    error UnknownSource(uint8 source);
    error UnsupportedTicker(bytes32 ticker);
    error SourceNotConfigured(bytes32 ticker, uint8 source);
    error SourceIsDisabled(bytes32 ticker, uint8 source);
    error SourcePinned();
    error NoPendingChange();
    error InvalidConfig();
    error InvalidSigners();
    error InvalidThreshold();
    error InsufficientFee(uint256 fee, uint256 value);
    error RefundFailed();
    error WrongFeed(bytes32 id);
    error NotThePrintForT(uint64 t, uint64 prevTs, uint64 ts);
    error PrintFromTheFuture(uint64 ts);
    error NonPositivePrice();
    error ConfidenceTooWide(uint256 conf, uint256 price);
    error UnsupportedExpo(int32 expo);
    error WrongTicker(bytes32 ticker);
    error NotEnoughSignatures(uint256 given, uint256 needed);
    error BadSignature();
    error MalleableSignature();
    error SignersNotAscending();
    error NotASigner(address signer);
    error ChainlinkRoundNotFound();
    error ChainlinkBadAnswer();
    error ChainlinkStale(uint256 updatedAt, uint64 ts);
    error OutOfBound(uint256 price, uint256 refPrice);
    /// @dev The constructor on a mainnet chain id with a `SIGNER_DELAY` under 24 hours.
    error DelayTooShort();

    /// @param pyth_ the Pyth core contract (`0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a` on 4663 and 46630)
    /// @param owner_ the account that may configure tickers and the signer set
    /// @param signers_ the first keeper signer set, strictly ascending by address; may be empty
    /// @param threshold_ signatures a keeper print needs (zero only for an empty set)
    /// @param signerDelay_ `SIGNER_DELAY`: 24 hours on mainnet, zero on a testnet. On a mainnet chain id
    ///        (4663, 1, 42161, 8453) anything under 24 hours reverts
    constructor(
        IPyth pyth_,
        address owner_,
        address[] memory signers_,
        uint256 threshold_,
        uint64 signerDelay_
    ) {
        if (address(pyth_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        // Robinhood Chain, Ethereum, Arbitrum One, Base; a testnet (46630) or anvil (31337) takes any delay
        uint256 id = block.chainid;
        if (signerDelay_ < MIN_MAINNET_DELAY && (id == 4663 || id == 1 || id == 42161 || id == 8453)) {
            revert DelayTooShort();
        }
        pyth = pyth_;
        SIGNER_DELAY = signerDelay_;
        _initializeOwner(owner_);
        _activeId = _writeSet(signers_, threshold_);
        emit SignersScheduled(signers_, threshold_, uint64(block.timestamp));
    }

    // ------------------------------------------------------------------------------------------ verify

    /// @inheritdoc IPitOracle
    /// @dev `msg.value` must cover the Pyth update fee (zero today) for a Pyth report; whatever is not spent
    ///      is sent back to the caller, who must accept it.
    function verifyAt(bytes32 ticker, uint64 t, bytes calldata report)
        external
        payable
        returns (uint256 priceWad, uint64 ts, bool trustless)
    {
        return _verify(ticker, t, report, false);
    }

    /// @inheritdoc IPitOracle
    function verifyCloseAt(bytes32 ticker, uint64 t, bytes calldata report)
        external
        payable
        returns (uint256 priceWad, uint64 ts, bool trustless)
    {
        return _verify(ticker, t, report, true);
    }

    /// @inheritdoc IPitOracle
    /// @dev For fills: a source switched off does not count from the moment it was switched off.
    function supported(bytes32 ticker) external view returns (bool) {
        TickerState memory st = _state[ticker];
        return _supported(st, _inForce(ticker, st), 0);
    }

    // ------------------------------------------------------------------------------------------- views

    /// @inheritdoc IPitOracle
    function boundBps(bytes32 ticker) external view returns (uint256) {
        return _inForce(ticker, _state[ticker]).boundBps;
    }

    /// @inheritdoc IPitOracle
    function multiplier(bytes32 ticker) external view returns (uint256) {
        address token = _inForce(ticker, _state[ticker]).stockToken;
        return token == address(0) ? WAD : IStockToken(token).uiMultiplier();
    }

    /// @notice Configuration of `ticker` in force now (all zero when it was never set).
    function config(bytes32 ticker) external view returns (TickerConfig memory) {
        return _inForce(ticker, _state[ticker]);
    }

    /// @notice The configuration change of `ticker` that waits and when it takes effect (`activeFrom` zero
    ///         when none waits).
    function pendingConfig(bytes32 ticker)
        external
        view
        returns (TickerConfig memory cfg, uint64 activeFrom)
    {
        uint64 from = _state[ticker].configFrom;
        if (from == 0 || block.timestamp >= from) return (cfg, 0);
        return (_pendingConfig[ticker], from);
    }

    /// @notice True when the owner switched a source (0x01 Pyth, 0x02 keeper) of `ticker` off: it verifies
    ///         no fill from that moment on, and no close for an instant at or after `closesOffFrom`.
    function sourceDisabled(bytes32 ticker, uint8 source) external view returns (bool) {
        (bool off,) = _switchOf(_state[ticker], source);
        return off;
    }

    /// @notice The first close instant a source of `ticker` refuses: `SIGNER_DELAY` after it was switched
    ///         off (zero when it is on). Closes of earlier instants are still verified.
    function closesOffFrom(bytes32 ticker, uint8 source) external view returns (uint64) {
        (, uint64 from) = _switchOf(_state[ticker], source);
        return from;
    }

    /// @notice The signer set in force now, in ascending address order.
    function signers() external view returns (address[] memory) {
        return _sets[_inForceId()].members;
    }

    /// @notice Number of signatures a keeper print needs now. Zero when there is no signer set.
    function threshold() public view returns (uint256) {
        return _sets[_inForceId()].threshold;
    }

    /// @notice True for members of the signer set in force now.
    function isSigner(address account) external view returns (bool) {
        return _sets[_inForceId()].isMember[account];
    }

    /// @notice The scheduled signer set that is not in force yet (`activeFrom` zero when there is none).
    function pendingSigners()
        external
        view
        returns (address[] memory members, uint256 pendingThreshold, uint64 activeFrom)
    {
        uint64 from = _pendingFrom;
        if (from == 0 || block.timestamp >= from) return (members, 0, 0);
        SignerSet storage set = _sets[_pendingId];
        return (set.members, set.threshold, from);
    }

    /// @notice EIP-712 domain separator: name "Fallpit PitOracle", version "1", this chain, this contract.
    /// @dev Computed on every call, so a print signed for one chain or one deployment is void on another.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    /// @notice The EIP-712 digest a signer signs for `p`.
    function printDigest(Print memory p) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(PRINT_TYPEHASH, p.ticker, p.price, p.ts, p.prevTs));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    // ------------------------------------------------------------------------------------------- owner

    /// @notice Sets the configuration of `ticker`. Zero `maxLag`, `maxConfBps`, `boundBps`, `maxFeedAge` or
    ///         `closeMaxLag` select the defaults (30 s, 100 bps, 60 bps, 5 days, 300 s). `closeMaxLag` is
    ///         60 to 900 s. The first configuration of a ticker is in force at once. Any later one takes
    ///         effect `SIGNER_DELAY` from now (`pendingConfig`); until then the one in force keeps
    ///         verifying. It replaces a change that is still waiting; `cancelTickerChange` drops it.
    /// @dev The Chainlink feed must report at most 18 decimals, and a stock token needs a feed. The Pyth
    ///      feed id, and the aggregator together with its stock token, are each set once: a later call
    ///      must repeat what is in force (or fill in a source that was never set) and can only change the
    ///      numeric limits. To take a source out of use see `setSourceDisabled`.
    function setTicker(bytes32 ticker, TickerConfig calldata cfg) external onlyOwner {
        TickerConfig memory c = cfg;
        if (c.maxLag == 0) c.maxLag = DEFAULT_MAX_LAG;
        if (c.maxConfBps == 0) c.maxConfBps = DEFAULT_MAX_CONF_BPS;
        if (c.boundBps == 0) c.boundBps = DEFAULT_BOUND_BPS;
        if (c.maxFeedAge == 0) c.maxFeedAge = DEFAULT_MAX_FEED_AGE;
        if (c.closeMaxLag == 0) c.closeMaxLag = DEFAULT_CLOSE_MAX_LAG;
        if (ticker == bytes32(0)) revert InvalidConfig();
        if (
            c.maxLag > MAX_MAX_LAG || c.maxConfBps > MAX_MAX_CONF_BPS || c.boundBps > MAX_BOUND_BPS
                || c.closeMaxLag < MIN_CLOSE_MAX_LAG || c.closeMaxLag > MAX_CLOSE_MAX_LAG
        ) {
            revert InvalidConfig();
        }
        if (c.aggregator == address(0)) {
            if (c.stockToken != address(0)) revert InvalidConfig();
        } else {
            if (IChainlinkFeed(c.aggregator).decimals() > 18) revert InvalidConfig();
            if (c.stockToken != address(0) && IStockToken(c.stockToken).uiMultiplier() == 0) {
                revert InvalidConfig();
            }
        }
        _promoteConfig(ticker);
        TickerConfig storage old = _config[ticker];
        if (old.pythFeedId != bytes32(0) && c.pythFeedId != old.pythFeedId) revert SourcePinned();
        if (
            old.aggregator != address(0) && (c.aggregator != old.aggregator || c.stockToken != old.stockToken)
        ) revert SourcePinned();
        TickerState storage st = _state[ticker];
        // `closeMaxLag` is never zero in a configuration that was set
        if (old.closeMaxLag == 0 || SIGNER_DELAY == 0) {
            _config[ticker] = c;
            st.configFrom = 0;
            emit TickerSet(ticker, c);
        } else {
            uint64 from = uint64(block.timestamp) + SIGNER_DELAY;
            _pendingConfig[ticker] = c;
            st.configFrom = from;
            emit TickerChangeScheduled(ticker, c, from);
        }
    }

    /// @notice Drops the configuration change of `ticker` that is still waiting.
    function cancelTickerChange(bytes32 ticker) external onlyOwner {
        _promoteConfig(ticker);
        TickerState storage st = _state[ticker];
        if (st.configFrom == 0) revert NoPendingChange();
        st.configFrom = 0;
        delete _pendingConfig[ticker];
        emit TickerChangeCancelled(ticker);
    }

    /// @notice Switches a source (0x01 Pyth, 0x02 keeper) of `ticker` off or back on. Off: the source
    ///         verifies no fill from now on and does not count towards `supported`, and it verifies no close
    ///         for an instant `SIGNER_DELAY` or more from now (`closesOffFrom`; on a testnet, with no delay,
    ///         no close at all). The close of a round that is open now is still verified. Back on: at once,
    ///         for fills and closes. Switching off a source that is off already keeps its first close instant.
    function setSourceDisabled(bytes32 ticker, uint8 source, bool disabled) external onlyOwner {
        if (source != SOURCE_PYTH && source != SOURCE_KEEPER) revert UnknownSource(source);
        TickerState storage st = _state[ticker];
        (, uint64 from) = _switchOf(st, source);
        if (!disabled) from = 0;
        else if (from == 0) from = SIGNER_DELAY == 0 ? 1 : uint64(block.timestamp) + SIGNER_DELAY;
        if (source == SOURCE_PYTH) {
            st.pythOff = disabled;
            st.pythCloseOffFrom = from;
        } else {
            st.keeperOff = disabled;
            st.keeperCloseOffFrom = from;
        }
        emit SourceDisabledSet(ticker, source, disabled, from);
    }

    /// @notice Schedules a new signer set and threshold. They take effect `SIGNER_DELAY` from now; until
    ///         then the current set keeps verifying. Replaces a change that is still waiting.
    /// @param newSigners the new set, strictly ascending by address (so distinct and non-zero); may be empty
    /// @param newThreshold signatures needed, between 1 and the set size (zero only for an empty set)
    function setSigners(address[] calldata newSigners, uint256 newThreshold) external onlyOwner {
        _promote();
        _schedule(newSigners, newThreshold);
    }

    /// @notice Schedules a new threshold for the newest signer set (the waiting one when there is one,
    ///         otherwise the one in force). Takes effect `SIGNER_DELAY` from now.
    function setThreshold(uint256 newThreshold) external onlyOwner {
        _promote();
        _schedule(_sets[_pendingFrom != 0 ? _pendingId : _activeId].members, newThreshold);
    }

    /// @notice Drops the signer change that is still waiting.
    function cancelSignerChange() external onlyOwner {
        _promote();
        if (_pendingFrom == 0) revert NoPendingChange();
        _pendingFrom = 0;
        emit SignerChangeCancelled();
    }

    // ---------------------------------------------------------------------------------------- internals

    /// @dev Both verifications: `close` picks the ticker's `closeMaxLag` instead of its `maxLag`, and the
    ///      source switches for closes instead of those for fills.
    function _verify(bytes32 ticker, uint64 t, bytes calldata report, bool close)
        internal
        returns (uint256 priceWad, uint64 ts, bool trustless)
    {
        if (report.length < 2) revert MalformedReport();
        TickerState memory st = _state[ticker];
        TickerConfig memory cfg = _inForce(ticker, st);
        if (st.configFrom != 0 && block.timestamp >= st.configFrom) _promoteConfig(ticker);
        // a fill is checked against the fill switches; a close against the close switches at its instant
        uint64 closeAt = close ? t : 0;
        if (!_supported(st, cfg, closeAt)) revert UnsupportedTicker(ticker);
        uint32 lag = close ? cfg.closeMaxLag : cfg.maxLag;

        uint8 source = uint8(report[0]);
        if (_isOff(st, source, closeAt)) revert SourceIsDisabled(ticker, source);
        uint256 spent;
        if (source == SOURCE_PYTH) {
            (priceWad, ts, spent) = _verifyPyth(ticker, cfg, t, lag, report[1:]);
            trustless = true;
        } else if (source == SOURCE_KEEPER) {
            (priceWad, ts) = _verifyKeeper(ticker, cfg, t, lag, report[1:]);
        } else {
            revert UnknownSource(source);
        }

        if (msg.value > spent) {
            (bool ok,) = msg.sender.call{value: msg.value - spent}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @dev Id of the signer set in force at this block.
    function _inForceId() internal view returns (uint64) {
        uint64 from = _pendingFrom;
        return from != 0 && block.timestamp >= from ? _pendingId : _activeId;
    }

    /// @dev Makes a matured pending set the active one, so a new change never skips the delay of an old one.
    function _promote() internal {
        uint64 from = _pendingFrom;
        if (from != 0 && block.timestamp >= from) {
            _activeId = _pendingId;
            _pendingFrom = 0;
        }
    }

    function _schedule(address[] memory newSigners, uint256 newThreshold) internal {
        uint64 from = uint64(block.timestamp) + SIGNER_DELAY;
        _pendingId = _writeSet(newSigners, newThreshold);
        _pendingFrom = from;
        emit SignersScheduled(newSigners, newThreshold, from);
    }

    /// @dev Validates and stores a signer set under a fresh id.
    function _writeSet(address[] memory newSigners, uint256 newThreshold) internal returns (uint64 id) {
        uint256 n = newSigners.length;
        if (n > MAX_SIGNERS) revert InvalidSigners();
        if (n == 0 ? newThreshold != 0 : (newThreshold == 0 || newThreshold > n)) revert InvalidThreshold();
        id = ++_lastId;
        SignerSet storage set = _sets[id];
        address last;
        for (uint256 i; i < n; ++i) {
            address s = newSigners[i];
            if (s <= last) revert InvalidSigners();
            set.isMember[s] = true;
            last = s;
        }
        set.members = newSigners;
        set.threshold = newThreshold;
    }

    /// @dev A ticker is supported when it has an enabled Pyth feed id, or an enabled Chainlink feed and a
    ///      signer set: enabled for the close of instant `closeAt`, or for fills when `closeAt` is zero.
    function _supported(TickerState memory st, TickerConfig memory cfg, uint64 closeAt)
        internal
        view
        returns (bool)
    {
        return (cfg.pythFeedId != bytes32(0) && !_isOff(st, SOURCE_PYTH, closeAt))
            || (cfg.aggregator != address(0) && !_isOff(st, SOURCE_KEEPER, closeAt) && threshold() != 0);
    }

    /// @dev The fill switch of a source and when it stops verifying closes (0: never). Zero for an
    ///      unknown source.
    function _switchOf(TickerState memory st, uint8 source)
        internal
        pure
        returns (bool off, uint64 closeFrom)
    {
        if (source == SOURCE_PYTH) {
            return (st.pythOff, st.pythCloseOffFrom);
        }
        if (source == SOURCE_KEEPER) return (st.keeperOff, st.keeperCloseOffFrom);
    }

    /// @dev True when `source` refuses the close of instant `closeAt` (from its `closesOffFrom` on), or,
    ///      when `closeAt` is zero, a fill (while it is switched off).
    function _isOff(TickerState memory st, uint8 source, uint64 closeAt) internal pure returns (bool) {
        (bool off, uint64 from) = _switchOf(st, source);
        return closeAt != 0 ? from != 0 && closeAt >= from : off;
    }

    /// @dev The configuration of `ticker` in force now.
    function _inForce(bytes32 ticker, TickerState memory st) internal view returns (TickerConfig memory) {
        uint64 from = st.configFrom;
        return from != 0 && block.timestamp >= from ? _pendingConfig[ticker] : _config[ticker];
    }

    /// @dev Writes a configuration change that has come into force into `_config`.
    function _promoteConfig(bytes32 ticker) internal {
        TickerState storage st = _state[ticker];
        uint64 from = st.configFrom;
        if (from == 0 || block.timestamp < from) return;
        _config[ticker] = _pendingConfig[ticker];
        delete _pendingConfig[ticker];
        st.configFrom = 0;
    }

    /// @dev Source 0x01. Pyth itself enforces `prevPublishTime < t <= publishTime <= t + maxLag`.
    function _verifyPyth(bytes32 ticker, TickerConfig memory cfg, uint64 t, uint32 lag, bytes calldata blob)
        internal
        returns (uint256 priceWad, uint64 ts, uint256 fee)
    {
        if (cfg.pythFeedId == bytes32(0)) revert SourceNotConfigured(ticker, SOURCE_PYTH);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = blob;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = cfg.pythFeedId;

        fee = pyth.getUpdateFee(updateData);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);
        IPyth.PriceFeed[] memory feeds =
            pyth.parsePriceFeedUpdatesUnique{value: fee}(updateData, ids, t, t + lag);

        if (feeds.length != 1) revert MalformedReport();
        if (feeds[0].id != cfg.pythFeedId) revert WrongFeed(feeds[0].id);
        IPyth.Price memory p = feeds[0].price;
        // Pyth checked the window; checking it again costs nothing and does not rely on the core contract.
        if (p.publishTime < t || p.publishTime > uint256(t) + lag) {
            revert NotThePrintForT(t, 0, uint64(p.publishTime));
        }
        if (p.price <= 0) revert NonPositivePrice();
        uint256 price = uint256(uint64(p.price));
        if (uint256(p.conf) * BPS > price * cfg.maxConfBps) revert ConfidenceTooWide(p.conf, price);
        if (p.expo > 0 || p.expo < -18) revert UnsupportedExpo(p.expo);

        priceWad = price * 10 ** uint256(uint32(18 + p.expo));
        ts = uint64(p.publishTime);
    }

    /// @dev Source 0x02. `data` is `abi.encode(Print, bytes[] signatures)`.
    function _verifyKeeper(bytes32 ticker, TickerConfig memory cfg, uint64 t, uint32 lag, bytes calldata data)
        internal
        view
        returns (uint256 priceWad, uint64 ts)
    {
        // A keeper print is always bounded: no feed, no keeper source.
        SignerSet storage set = _sets[_inForceId()];
        uint256 needed = set.threshold;
        if (needed == 0 || cfg.aggregator == address(0)) revert SourceNotConfigured(ticker, SOURCE_KEEPER);

        (Print memory p, bytes[] memory signatures) = abi.decode(data, (Print, bytes[]));
        if (p.ticker != ticker) revert WrongTicker(p.ticker);
        if (!(p.prevTs < t && t <= p.ts && p.ts <= uint256(t) + lag)) {
            revert NotThePrintForT(t, p.prevTs, p.ts);
        }
        if (p.ts > block.timestamp) revert PrintFromTheFuture(p.ts);
        if (p.price == 0) revert NonPositivePrice();

        if (signatures.length < needed) revert NotEnoughSignatures(signatures.length, needed);
        bytes32 digest = printDigest(p);
        address last;
        for (uint256 i; i < signatures.length; ++i) {
            address signer = _recover(digest, signatures[i]);
            if (signer <= last) revert SignersNotAscending();
            if (!set.isMember[signer]) revert NotASigner(signer);
            last = signer;
        }

        _checkBound(cfg, p.price, p.ts);

        priceWad = p.price;
        ts = p.ts;
    }

    /// @dev Requires `price` within `boundBps` of a Chainlink round that was current around `ts`: the round
    ///      in force at `ts`, or one that landed within `FEED_GRACE` after it. Rounds are found by walking
    ///      back from the latest one, so a print stays verifiable after the feed has moved on (a 16:00
    ///      close posted after an after-hours move), and the feed's later answers never bound an old print.
    function _checkBound(TickerConfig memory cfg, uint256 price, uint64 ts) internal view {
        IChainlinkFeed feed = IChainlinkFeed(cfg.aggregator);
        uint256 scale = 10 ** (18 - uint256(feed.decimals()));
        uint256 mult = cfg.stockToken == address(0) ? WAD : IStockToken(cfg.stockToken).uiMultiplier();
        if (mult == 0) revert ChainlinkBadAnswer();

        (uint80 roundId, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        uint256 refPrice;
        for (uint256 i;; ++i) {
            if (updatedAt == 0) revert ChainlinkRoundNotFound();
            if (updatedAt <= uint256(ts) + FEED_GRACE) {
                bool inForce = updatedAt <= ts;
                if (inForce && ts - updatedAt > cfg.maxFeedAge) revert ChainlinkStale(updatedAt, ts);
                if (answer <= 0) revert ChainlinkBadAnswer();
                // The feed prices the token; the underlying is the token price over the multiplier.
                refPrice = uint256(answer) * scale * WAD / mult;
                uint256 diff = price > refPrice ? price - refPrice : refPrice - price;
                if (diff * BPS <= refPrice * cfg.boundBps) return;
                // The round in force at `ts` is the last candidate.
                if (inForce) revert OutOfBound(price, refPrice);
            }
            // Step to the previous round of the same phase.
            if (i == MAX_ROUND_WALK || uint64(roundId) <= 1) revert ChainlinkRoundNotFound();
            roundId -= 1;
            (, answer,, updatedAt,) = feed.getRoundData(roundId);
        }
    }

    /// @dev Recovers the signer of a 65-byte `r || s || v` signature. Rejects the high-`s` twin, any `v`
    ///      other than 27 or 28, and the compact 64-byte form, so each signature has one encoding.
    function _recover(bytes32 digest, bytes memory signature) internal pure returns (address signer) {
        if (signature.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (uint256(s) > SECP256K1_HALF_N) revert MalleableSignature();
        if (v != 27 && v != 28) revert BadSignature();
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
    }
}
