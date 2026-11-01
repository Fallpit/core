// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IFallpitHook, RefundReason} from "./interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "./interfaces/IFallpitRouter.sol";
import {IPitVault} from "./interfaces/IPitVault.sol";
import {IPitLister} from "./interfaces/IPitLister.sol";
import {EthPool, SessionLogic, SessionStore} from "./router/SessionLogic.sol";

/// @dev The hook's ERC-6909 tickets, as the router uses them.
interface IERC6909Balance {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function transfer(address to, uint256 id, uint256 amount) external returns (bool);
}

/// @title FallpitRouter
/// @notice The only contract the Fallpit hook accepts fills from. A trade is two steps: `commit` escrows
///         the chips or the product's tickets, and `fill` executes it at the one oracle print that counts for the
///         instant `commit time + fillDelay`. Nobody picks the price: not the user, not the filler.
/// @dev Fill fee. Every commit carries the round's `fillFee` in native coin. It is paid to whoever calls
///      `fill` for that commit, when the fill ends in a trade and when it ends in a refund (the filler did
///      the work both times), and it goes back to the trader when nobody fills in time. One exception: when
///      someone other than the user paid the fee (a session relayer, `feePayerOf`), the fee goes back to
///      that payer unless the payer fills the commit itself, after a trade and after a refund; otherwise a
///      user (or anyone) could fill relayed commits first and take the relayer's fees. The router's native
///      balance is always the fees of the pending commits plus `ethOwed`.
///
///      The user of a fill comes only from the commit record. A commit cannot be cancelled; it is filled
///      inside its fill window, refunded by `fill` when the hook rejects it for good (limit, cap, solvency,
///      loss limit, product cap, trading window), or refunded by `refund` once the window has passed without a fill.
///      Fill and refund windows never overlap, so an unfilled commit is not an option on later prices.
///      Fee-on-transfer chips are not supported: a commit whose escrow arrives short is refused. Chips are
///      still credited by balance difference everywhere, so a chip that starts to tax its transfers later
///      cannot make the books wrong (the hook refuses such a fill with `ChipShort`, which is not final: the
///      commit refunds when its window ends).
///
///      A fill is one call of this router on itself (`execute`): a buy sends the escrow to the hook,
///      which keeps the cost and sends the rest to the user; a sell leaves the escrowed tickets here and
///      the hook burns them and pays the user. When the hook rejects the fill for good, everything inside
///      `execute` is rolled back and the escrow is refunded from here.
///
///      Fill order. The fills of one round are made in commit order, not in the filler's order. One print
///      can price many instants (after a gap in the prints, every instant it covers), so the order of the
///      fills decides who pays whose price impact, also across instants. Every commit records the round's
///      commit before it (`prev`) when the fill windows of the two overlap, and `fill` waits while that
///      one is pending and its window is still open. A sandwich around a commit then needs a commit placed
///      before it. A prior commit that cannot fill is refunded by `fill` (a rejection), or its window ends:
///      fill instants only grow in a round and all its commits have one `refundDelay`, so a stuck commit's
///      window ends first, and from then on it holds nobody (it waits for `refund`). A later commit keeps
///      at least the seconds between the two fill instants to fill in.
///
///      Sessions (SPEC 7.3.1). A user may let a key sign orders for them for at most `MAX_SESSION`: one
///      EIP-712 grant, submitted by anyone, then each order is one EIP-712 signature of the key, also
///      submitted by anyone (the keeper relays them and pays the fill fee, which it earns back by filling).
///      A session commit is the user's own commit in every way (escrow from the user, tickets and proceeds
///      to the user, the same fill order and windows), with one difference: the fill fee of a commit that
///      ends in a refund goes back to whoever paid it. (Every sell escrows the user's tickets through
///      `IFallpitHook.pull`, a session's or not: no approval is needed.) A grant has a scope (trade, vault, or both), a cap per order
///      (`maxPerOrder`) and a total cap per coin (`maxTotal`, the sum of buy limits and deposits, see
///      `sessionSpent`). The router itself only pays the user, but a leaked key is not harmless: until the
///      session ends it can make the user trade at bad prices (each buy at most `maxPerOrder`, all buys and
///      deposits together at most `maxTotal`), for example as the victim of a sandwich that moves the
///      user's chips to the thief through the AMM, sell the user's tickets at limit 0, and withdraw the
///      user's LP shares. Grant short sessions with real caps.
///
///      Cancels. A signed order or vault action that is not used yet can be cancelled on chain: the key
///      signs `CancelOrder(user, nonce)` (`cancelWithSig`, which also works after the session was revoked
///      or expired, as long as `sessionNonce` is the same), or the user burns nonces directly
///      (`useNonces`).
///
///      Vault actions by session. The same key may also sign `VaultOp`s (deposit, cancel a queued deposit,
///      request a withdrawal, claim) in the user's houses, relayed by anyone through `vaultWithSig`, when
///      the grant has the vault scope. The router acts for the user through the vault's `...For`
///      functions, which accept this router because the hook pins it (`PitVault.router()`). A deposit
///      pulls the user's chips through their approval to this router (at most `maxPerOrder` per action,
///      counted in `maxTotal`); shares, cancelled deposits, withdrawals and claims are booked and paid to
///      the user by the vault, never to the relayer or the router. A withdrawal or claim may carry a
///      `minOut` (for a withdrawal: only if it pays that much now). Orders, vault actions and cancels share
///      one nonce bitmap per user (`orderNonceUsed`): a nonce works once, for one of them.
///
///      Buy with ETH. `commitWithEth` swaps the native coin sent, less the round's fill fee, for the
///      round's chip on the chip's ETH pool (`ethPoolKey`, always a pool with no hooks) inside one
///      PoolManager unlock, and commits a buy for the caller with the limit `min(limit, chips received)`;
///      chips above the limit go back to the caller at once. The escrow is like any buy's: what the fill
///      does not spend, or the whole escrow on a refund, goes back to the caller in chips.
contract FallpitRouter is IFallpitRouter, IUnlockCallback {
    using SafeTransferLib for address;

    /// @dev Transient slot of the reentrancy lock ("FallpitRouterLock").
    uint256 private constant LOCK_SLOT = 0x46616c6c706974526f757465724c6f636b;
    /// @dev Gas a receiver of native coin gets (enough for a smart wallet). A receiver that needs more, or
    ///      reverts, is not paid in the call: its coin waits in `ethOwed`.
    uint256 private constant ETH_GAS = 100_000;
    /// @notice Longest session a user can grant.
    uint256 public constant MAX_SESSION = SessionLogic.MAX_SESSION;

    /// @notice `SessionGrant.scope` bits: trade (`commitWithSig`) and vault (`vaultWithSig`).
    uint8 public constant SCOPE_TRADE = SessionLogic.SCOPE_TRADE;
    uint8 public constant SCOPE_VAULT = SessionLogic.SCOPE_VAULT;

    /// @notice `VaultOp.op` values.
    uint8 public constant VAULT_DEPOSIT = SessionLogic.VAULT_DEPOSIT;
    uint8 public constant VAULT_CANCEL_DEPOSIT = SessionLogic.VAULT_CANCEL_DEPOSIT;
    uint8 public constant VAULT_REQUEST_WITHDRAW = SessionLogic.VAULT_REQUEST_WITHDRAW;
    uint8 public constant VAULT_CLAIM = SessionLogic.VAULT_CLAIM;

    /// @dev Where the escrow of a commit comes from.
    uint8 private constant FROM_USER = 0; // a buy: the user's approval to this router; a sell: `hook.pull`
    uint8 private constant FROM_HERE = 2; // already in the router (the chips of `commitWithEth`)

    /// @dev The default chip/ETH pool: native coin as currency0, 1% fee, tick spacing 200, no hooks.
    uint24 private constant ETH_POOL_FEE = 10_000;
    int24 private constant ETH_POOL_TICK_SPACING = 200;

    IPoolManager public immutable poolManager;
    /// @notice May call `setHook` once and `setEthPool`, until it calls `renounceDeployer` (then zero, for
    ///         ever). Set at construction; no other change. The deploy renounces it once the wiring is done.
    /// @dev Kept in storage: solc 0.8.26 with via-IR hits an internal error with a second immutable here.
    address public deployer;
    /// @notice The Fallpit hook. Set once, then frozen.
    IFallpitHook public hook;

    /// @notice Id the next commit gets.
    uint256 public nextCommitId = 1;
    mapping(uint256 commitId => StoredCommit) internal _commits;
    /// @dev Total chip escrow of pending buy commits per chip, plus 1 once the chip had a commit (so the
    ///      slot never goes back to zero). Read it through `escrowed`.
    mapping(address asset => uint256) internal _escrowed;
    /// @dev Total ticket escrow of pending sell commits per ticket id, plus 1 once the id had a commit.
    ///      Read it through `escrowedTickets`.
    mapping(uint256 id => uint256) internal _escrowedTickets;
    /// @inheritdoc IFallpitRouter
    mapping(address account => uint256) public ethOwed;
    /// @dev The newest commit of a round and its fill instant: the `prev` of the round's next commit.
    mapping(bytes32 roundId => LastCommit) internal _lastCommit;
    /// @dev The chip, fill fee and refund window of each round with a commit (`RoundTerms`).
    mapping(bytes32 roundId => RoundTerms) internal _terms;

    /// @dev Sessions, their nonces, grants and spending, and the order nonce bitmaps (`SessionLogic`).
    SessionStore internal _ss;
    /// @inheritdoc IFallpitRouter
    mapping(uint256 commitId => address) public feePayerOf;
    /// @dev Pool overrides per chip for `commitWithEth`; `tickSpacing` zero: the default pool.
    mapping(address chip => EthPool) internal _ethPools;

    /// @dev A commit as stored: `IFallpitRouter.Commit` without `escrow`, which is always
    ///      `isBuy ? limit : shares` (`_escrowOf`), and without what its round fixes for all its commits
    ///      (`RoundTerms`), plus `relayed` (true when `feePayerOf` is set, so a fill reads `feePayerOf` only
    ///      then). Three slots: the fill instant in 40 bits (seconds, enough for thousands of years), the
    ///      earlier commit as its distance back in commit ids (`prevGap`, 0 for none; commits that can hold
    ///      each other are seconds apart, far fewer than 2^32 ids), and the limit in 128 bits (a commit
    ///      with a larger limit is refused).
    struct StoredCommit {
        address user;
        uint40 fillTs;
        CommitStatus status;
        bool isBuy;
        bool relayed;
        uint32 prevGap;
        uint256 id;
        uint128 shares;
        uint128 limit;
    }

    /// @dev What a round fixes for every commit on it (frozen in the round's config: `commitContext`),
    ///      stored once by the round's first commit: its chip, fill fee and refund window.
    struct RoundTerms {
        address chip;
        uint64 fillFee;
        uint32 refundDelay;
    }

    /// @dev What `_commit` needs from the hook about a commit's round and product (`commitContext`), and
    ///      the commit's fill instant once stored.
    struct CommitContext {
        IFallpitHook hook;
        uint256 id;
        address chip;
        bool tradable;
        uint32 fillDelay;
        uint32 refundDelay;
        uint256 minShares;
        uint64 fillFee;
        bool isOpen;
        uint64 fillTs;
    }

    struct LastCommit {
        uint64 fillTs;
        uint192 id;
    }

    modifier nonReentrant() {
        if (_locked()) revert Reentrancy();
        _setLock(1);
        _;
        _setLock(0);
    }

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
        deployer = msg.sender;
    }

    /// @notice Only the hook sends ETH here: what the oracle did not spend of a filler's ETH, which `fill`
    ///         passes on to the filler.
    receive() external payable {
        if (msg.sender != address(hook)) revert EthNotAccepted();
    }

    /// @inheritdoc IFallpitRouter
    /// @dev The hook's router address is immutable and must be this contract, which closes the circular
    ///      dependency: deploy the router, deploy the hook with the router's address, then call this.
    function setHook(address hook_) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (address(hook) != address(0)) revert HookAlreadySet();
        if (hook_.code.length == 0 || IFallpitHook(hook_).router() != address(this)) revert BadHook();
        hook = IFallpitHook(hook_);
        emit HookSet(hook_);
    }

    /// @inheritdoc IFallpitRouter
    function renounceDeployer() external {
        if (msg.sender != deployer) revert OnlyDeployer();
        deployer = address(0);
        emit DeployerRenounced(msg.sender);
    }

    /// @inheritdoc IFallpitRouter
    function commit(bytes32 roundId, uint8 product, bool isBuy, uint256 shares, uint256 limit)
        external
        payable
        nonReentrant
        returns (uint256 commitId)
    {
        return _commit(msg.sender, roundId, product, isBuy, shares, limit, FROM_USER, msg.value);
    }

    /// @inheritdoc IFallpitRouter
    function openAndCommit(
        bytes32 ticker,
        address chip,
        uint32 day,
        uint8 product,
        bool isBuy,
        uint256 shares,
        uint256 limit
    ) external payable nonReentrant returns (uint256 commitId) {
        IFallpitHook hook_ = hook;
        if (address(hook_) == address(0)) revert HookNotSet();
        bytes32 roundId = hook_.roundIdOf(hook_.houseOf(ticker, chip), day);
        if (hook_.getState(roundId).status == IFallpitHook.Status.None) hook_.openRound(ticker, chip, day);
        return _commit(msg.sender, roundId, product, isBuy, shares, limit, FROM_USER, msg.value);
    }

    /// @inheritdoc IFallpitRouter
    /// @dev The swap is exact-in at any price (no price limit): `minChips` is the caller's slippage bound.
    ///      Should the pool run out of liquidity, the ETH it did not take goes back to the caller.
    function commitWithEth(
        bytes32 roundId,
        uint8 product,
        uint256 shares,
        uint256 minChips,
        uint256 limit,
        uint64 deadline
    ) external payable nonReentrant returns (uint256 commitId) {
        if (block.timestamp > deadline) revert OrderExpired();
        address chip;
        uint64 fillFee;
        uint256 ethIn;
        {
            IFallpitHook hook_ = hook;
            if (address(hook_) == address(0)) revert HookNotSet();
            uint256 id;
            (id, chip,,,,, fillFee,) = hook_.commitContext(roundId, product);
            if (id == 0) revert UnknownProduct();
            if (msg.value <= fillFee) revert WrongFillFee();
            ethIn = msg.value - fillFee;
        }

        uint256 ethLeft;
        uint256 chips;
        {
            uint256 before = chip.balanceOf(address(this));
            ethLeft =
                abi.decode(poolManager.unlock(abi.encode(uint256(0), abi.encode(chip), ethIn)), (uint256));
            chips = chip.balanceOf(address(this)) - before;
        }
        if (chips == 0 || chips < minChips) revert TooFewChips(chips, minChips);

        // The buy spends at most `limit`; the chips above it are the caller's at once.
        uint256 escrow = FixedPointMathLib.min(chips, limit);
        commitId = _commit(msg.sender, roundId, product, true, shares, escrow, FROM_HERE, fillFee);
        emit BoughtWithEth(commitId, msg.sender, ethIn - ethLeft, chips);
        if (chips > escrow) chip.safeTransfer(msg.sender, chips - escrow);
        if (ethLeft != 0) msg.sender.safeTransferETH(ethLeft);
    }

    /// @dev The commit of `user`, carrying `feeIn` wei of fill fee. `source`: `FROM_USER`, a buy's chips come
    ///      through the user's own approval to this router and a sell's tickets through `hook.pull` (the
    ///      caller is the user, or checked the session and the key's signature); `FROM_HERE`, the caller
    ///      already brought exactly `limit` chips of a buy
    ///      into the router and measured them.
    function _commit(
        address user,
        bytes32 roundId,
        uint8 product,
        bool isBuy,
        uint256 shares,
        uint256 limit,
        uint8 source,
        uint256 feeIn
    ) private returns (uint256 commitId) {
        CommitContext memory k = _commitContext(roundId, product, shares, feeIn);

        // Escrow. Chips by balance difference, and it must be exactly what was sent: a chip that taxes its
        // transfers cannot trade. Tickets move inside the hook, exactly.
        uint256 escrow = isBuy ? limit : shares;
        if (escrow == 0) revert ZeroAmount();
        _escrowIn(user, k, isBuy, shares, limit, source, escrow);

        commitId = _store(user, roundId, isBuy, shares, limit, k);
        emit Committed(commitId, user, roundId, product, isBuy, shares, limit, escrow, k.fillTs);
    }

    /// @dev The hook's context of a commit to `product` of `roundId`, checked: the round is open and
    ///      trades now, the product exists, `feeIn` is the round's fill fee, and `shares` is in range.
    function _commitContext(bytes32 roundId, uint8 product, uint256 shares, uint256 feeIn)
        private
        view
        returns (CommitContext memory k)
    {
        k.hook = hook;
        if (address(k.hook) == address(0)) revert HookNotSet();
        (k.id, k.chip, k.tradable, k.fillDelay, k.refundDelay, k.minShares, k.fillFee, k.isOpen) =
            k.hook.commitContext(roundId, product);
        if (!k.isOpen) revert RoundNotOpen();
        if (k.id == 0) revert UnknownProduct();
        // The filler's pay travels with the commit: exactly the round's fee, no more and no less.
        if (feeIn != k.fillFee) revert WrongFillFee();
        // The instant the commit is priced at must be inside a trading window of the round's clock.
        if (!k.tradable) revert OutsideTradingWindow();
        if (shares == 0 || shares > uint128(type(int128).max)) revert ZeroAmount();
        // Dust costs its sender little and whoever fills it a full pricing run.
        if (shares < k.minShares) revert BelowMinimumTrade();
    }

    /// @dev Takes a commit's escrow: a sell's tickets through `hook.pull`, a buy's chips from `user` unless
    ///      `source` is `FROM_HERE`.
    function _escrowIn(
        address user,
        CommitContext memory k,
        bool isBuy,
        uint256 shares,
        uint256 limit,
        uint8 source,
        uint256 escrow
    ) private {
        if (!isBuy) {
            k.hook.pull(user, k.id, shares);
            _escrowedTickets[k.id] = _orOne(_escrowedTickets[k.id]) + shares;
        } else {
            address chip = k.chip;
            if (source != FROM_HERE) {
                uint256 before = chip.balanceOf(address(this));
                chip.safeTransferFrom(user, address(this), limit);
                if (chip.balanceOf(address(this)) - before != limit) revert BadEscrow();
            }
            _escrowed[chip] = _orOne(_escrowed[chip]) + escrow;
        }
    }

    /// @dev Stores a new pending commit and links it to the round's previous one. Sets `k.fillTs`.
    function _store(
        address user,
        bytes32 roundId,
        bool isBuy,
        uint256 shares,
        uint256 limit,
        CommitContext memory k
    ) private returns (uint256 commitId) {
        commitId = nextCommitId++;
        uint64 fillTs = uint64(block.timestamp) + k.fillDelay;
        k.fillTs = fillTs;
        LastCommit memory lc = _lastCommit[roundId];
        _lastCommit[roundId] = LastCommit({fillTs: fillTs, id: uint192(commitId)});
        StoredCommit memory c;
        c.user = user;
        c.fillTs = uint40(fillTs);
        c.status = CommitStatus.Pending;
        c.isBuy = isBuy;
        c.id = k.id;
        c.relayed = false;
        RoundTerms storage tm = _terms[roundId];
        if (tm.chip == address(0)) {
            (tm.chip, tm.fillFee, tm.refundDelay) = (k.chip, k.fillFee, k.refundDelay);
        }
        c.shares = uint128(shares);
        // the round's previous commit, while its fill window overlaps this one's (fill instants only grow)
        if (uint256(lc.fillTs) + k.refundDelay >= fillTs) c.prevGap = SafeCastLib.toUint32(commitId - lc.id);
        if (limit > type(uint128).max) revert LimitTooLarge();
        c.limit = uint128(limit);
        _commits[commitId] = c;
    }

    /// @inheritdoc IFallpitRouter
    /// @dev Any ETH sent is forwarded to the hook inside the fill, and the hook pays the oracle's update
    ///      fee from its balance. When the commit is refunded instead, the fill was rolled back and the
    ///      ETH goes back to the caller. Reverts (and leaves the commit pending) on anything that is not a
    ///      final rejection, for example a report that is not the print for the commit's fill instant.
    ///
    ///      The caller earns the commit's fill fee when the fill ends in a trade and when it ends in a
    ///      refund, except for a commit whose fee another payer sent (`feePayerOf`): that fee goes back to
    ///      the payer unless the payer is the caller. The commit is closed before any coin moves, and the
    ///      payment never reverts: a receiver that does not take it is credited in `ethOwed`.
    function fill(uint256 commitId, bytes calldata report)
        external
        payable
        nonReentrant
        returns (bool filled)
    {
        return _fillOne(commitId, report, msg.value, false);
    }

    /// @inheritdoc IFallpitRouter
    /// @dev The commits run in the order given, each exactly as `fill` with no ETH: the same checks, the
    ///      same events, the same fee and refund. A commit that is not pending, not due yet, past its
    ///      window, held by an earlier pending commit, or whose fill fails with an error that is not a final
    ///      rejection is skipped (false, and the commit stays as it was) instead of reverting the batch.
    ///      Later fills of a round in the same transaction read warm storage, so a batch costs less than
    ///      the fills one by one.
    function fillBatch(uint256[] calldata commitIds, bytes[] calldata reports)
        external
        nonReentrant
        returns (bool[] memory filled)
    {
        uint256 n = commitIds.length;
        if (reports.length != n) revert LengthMismatch();
        filled = new bool[](n);
        for (uint256 i; i < n; ++i) {
            filled[i] = _fillOne(commitIds[i], reports[i], 0, true);
        }
    }

    /// @dev One fill (`fill`, or one entry of `fillBatch` when `soft`: then every reason not to fill or
    ///      a fill error that is not final returns false and leaves the commit pending).
    function _fillOne(uint256 commitId, bytes calldata report, uint256 value, bool soft)
        private
        returns (bool)
    {
        StoredCommit storage c = _commits[commitId];
        RoundTerms storage tm = _termsOf(c.id);
        if (!_due(c, tm, commitId, soft)) return false;

        uint256 escrow = _escrowOf(c);
        // A relayed commit's fee goes back to its payer, unless the payer fills: else anyone (the user
        // too) could fill relayed commits first and take the relayer's fees.
        address payer = c.relayed ? feePayerOf[commitId] : address(0);
        if (payer == msg.sender) payer = address(0);
        c.status = CommitStatus.Filled;

        // the router's ETH without the filler's: what the hook sends back above it is the filler's
        uint256 base = address(this).balance - value;
        try this.execute{value: value}(commitId, report) returns (uint256 chips) {
            // the escrow counters are read by views only, so they move after the call (a skipped commit
            // in a batch then needs no undo)
            _release(c, tm, escrow);
            emit Filled(commitId, c.user, chips);
            _payFiller(commitId, payer, tm.fillFee, address(this).balance - base);
            return true;
        } catch (bytes memory err) {
            // Everything inside `execute` was rolled back; the escrow is still here.
            RefundReason reason = _refundReason(err);
            if (reason == RefundReason.None) {
                if (soft) {
                    // a batch skips it: the commit is pending again
                    c.status = CommitStatus.Pending;
                    return false;
                }
                assembly ("memory-safe") {
                    revert(add(err, 0x20), mload(err))
                }
            }
            c.status = CommitStatus.Refunded;
            _release(c, tm, escrow);
            _returnEscrow(c, tm, c.user, escrow);
            emit Refunded(commitId, c.user, reason);
            // The filler did the work of a fill that could never succeed: the fee is theirs, and the
            // ETH they sent for the oracle comes back with it. A relayed commit's fee goes back to its
            // payer instead (see above).
            _payFiller(commitId, payer, tm.fillFee, value);
            return false;
        }
    }

    /// @dev True when the commit may be filled now; otherwise false when `soft`, else the reason as a
    ///      revert.
    function _due(StoredCommit storage c, RoundTerms storage tm, uint256 commitId, bool soft)
        private
        view
        returns (bool)
    {
        bytes4 why;
        uint256 prev;
        if (c.status != CommitStatus.Pending) {
            why = CommitNotPending.selector;
        } else if (block.timestamp < c.fillTs) {
            why = TooEarly.selector;
        } else if (block.timestamp > uint256(c.fillTs) + tm.refundDelay) {
            why = FillWindowClosed.selector;
        } else if ((prev = _prevOf(c, commitId)) != 0) {
            // The earlier commit holds this one while it is pending and can still be filled. Its window
            // ends first (same round: same `refundDelay`, an earlier or equal fill instant); after that it
            // can only be refunded and holds nobody.
            StoredCommit storage p = _commits[prev];
            if (p.status == CommitStatus.Pending && block.timestamp <= uint256(p.fillTs) + tm.refundDelay) {
                why = EarlierCommitPending.selector;
            }
        }
        if (why == 0) return true;
        if (soft) return false;
        if (why == EarlierCommitPending.selector) revert EarlierCommitPending(prev);
        assembly ("memory-safe") {
            mstore(0, why)
            revert(0, 4)
        }
    }

    /// @dev The fill fee to the filler (or to the relayed commit's payer) and `back`, the filler's own ETH,
    ///      to the filler.
    function _payFiller(uint256 commitId, address payer, uint256 fee, uint256 back) private {
        if (payer != address(0)) {
            _payFillFee(commitId, payer, fee, 0);
            fee = 0;
        }
        _payFillFee(commitId, msg.sender, fee, back);
    }

    /// @inheritdoc IFallpitRouter
    function refund(uint256 commitId) external nonReentrant {
        StoredCommit storage c = _commits[commitId];
        RoundTerms storage tm = _termsOf(c.id);
        if (c.status != CommitStatus.Pending) revert CommitNotPending();
        if (block.timestamp <= uint256(c.fillTs) + tm.refundDelay) revert RefundNotDue();
        address user = c.user;
        uint256 escrow = _escrowOf(c);
        uint256 fee = tm.fillFee;
        c.status = CommitStatus.Refunded;
        _release(c, tm, escrow);
        _returnEscrow(c, tm, user, escrow);
        emit Refunded(commitId, user, RefundReason.Expired);
        // Nobody filled: the fill fee goes back to whoever paid it (the trader, or a session's relayer),
        // the escrow to the trader.
        _payFillFee(commitId, c.relayed ? feePayerOf[commitId] : user, fee, 0);
    }

    /// @inheritdoc IFallpitRouter
    function claimEth(address to) external nonReentrant returns (uint256 amount) {
        amount = ethOwed[msg.sender];
        if (amount == 0) revert NothingToClaim();
        ethOwed[msg.sender] = 0;
        to.safeTransferETH(amount);
        emit EthClaimed(msg.sender, to, amount);
    }

    /// @inheritdoc IFallpitRouter
    function redeem(uint256 id, uint256 amount) external nonReentrant returns (uint256 payout) {
        return hook.redeem(id, msg.sender, amount);
    }

    // ------------------------------------------------------------------------------------- sessions

    /// @inheritdoc IFallpitRouter
    function grantSession(SessionGrant calldata grant, bytes calldata signature) external nonReentrant {
        SessionLogic.grant(_ss, grant, signature);
    }

    /// @inheritdoc IFallpitRouter
    /// @dev Only the expiry is cleared: the session is dead, and its key can still sign `CancelOrder`s. A
    ///      grant for this key now needs a nonce past the user's current one (`bumpSessionNonce`), so no
    ///      grant signed before the revocation, relayed or not, can restart the session.
    function revokeSession(address key) external {
        _ss.sessions[msg.sender][key].expiry = 0;
        _ss.grantFloor[msg.sender][key] = _ss.nonce[msg.sender] + 1;
        emit SessionRevoked(msg.sender, key);
    }

    /// @inheritdoc IFallpitRouter
    function cancelWithSig(address user, uint256 nonce, address key, bytes calldata signature) external {
        SessionLogic.cancel(_ss, user, nonce, key, signature);
    }

    /// @inheritdoc IFallpitRouter
    function useNonces(uint256 word, uint256 mask) external {
        _ss.orderBits[msg.sender][word] |= mask;
        emit NoncesUsed(msg.sender, word, mask);
    }

    /// @inheritdoc IFallpitRouter
    function bumpSessionNonce() external {
        uint256 n = ++_ss.nonce[msg.sender];
        emit SessionNonceBumped(msg.sender, n);
    }

    /// @inheritdoc IFallpitRouter
    function commitWithSig(Order calldata order, address key, bytes calldata signature)
        external
        payable
        nonReentrant
        returns (uint256 commitId)
    {
        address user = order.user;
        uint128 maxTotal = SessionLogic.orderSession(_ss, order, key, signature);
        commitId = _commit(
            user, order.roundId, order.product, order.isBuy, order.shares, order.limit, FROM_USER, msg.value
        );
        if (order.isBuy) {
            SessionLogic.spend(_ss, user, key, maxTotal, _terms[order.roundId].chip, order.limit);
        }
        if (msg.sender != user) {
            feePayerOf[commitId] = msg.sender;
            _commits[commitId].relayed = true;
        }
        emit SessionOrder(commitId, user, key, order.nonce, msg.sender);
    }

    /// @inheritdoc IFallpitRouter
    /// @dev The vault books and pays everything to `user`: the router passes `user` as the owner of every
    ///      call and keeps nothing (a deposit's chips pass through it in the same call).
    function vaultWithSig(VaultOp calldata op, address key, bytes calldata signature)
        external
        nonReentrant
        returns (uint256 result)
    {
        return SessionLogic.vaultOp(_ss, op, key, signature, address(hook));
    }

    /// @inheritdoc IFallpitRouter
    function listWithSig(
        ListOp calldata op,
        IPitLister.ListingQuote calldata quote,
        bytes calldata quoteSignature,
        address key,
        bytes calldata signature
    ) external nonReentrant returns (bytes32 house) {
        return SessionLogic.list(_ss, op, quote, quoteSignature, key, signature, address(hook));
    }

    /// @inheritdoc IFallpitRouter
    /// @dev The hook pays the holder it is given and accepts this router on any holder's behalf; here the
    ///      holder is always `user` and the amount is all they hold, so a caller can only make a user collect
    ///      what is theirs (a losing token reverts in the hook). Not session-gated (it needs no consent of
    ///      the holder). Holders that are not users are refused: the router (its balance is the escrow of
    ///      pending sell commits) and the hook.
    function redeemFor(address user, uint256 id) external nonReentrant returns (uint256 payout) {
        IFallpitHook hook_ = hook;
        if (user == address(this) || user == address(hook_)) revert BadHolder();
        return hook_.redeem(id, user, IERC6909Balance(address(hook_)).balanceOf(user, id));
    }

    /// @inheritdoc IFallpitRouter
    function sessionOf(address user, address key) external view returns (Session memory) {
        return _ss.sessions[user][key];
    }

    /// @inheritdoc IFallpitRouter
    function sessionSpent(address user, address key, address coin) external view returns (uint256) {
        return _ss.spent[user][key][_ss.grantCount[user][key]][coin];
    }

    /// @inheritdoc IFallpitRouter
    function orderNonceUsed(address user, uint256 nonce) external view returns (bool) {
        return _ss.orderBits[user][nonce >> 8] & (1 << (nonce & 0xff)) != 0;
    }

    /// @inheritdoc IFallpitRouter
    function sessionNonce(address user) external view returns (uint256) {
        return _ss.nonce[user];
    }

    /// @notice Grants already submitted, by digest: a revoked session cannot be revived with its old grant.
    function grantUsed(bytes32 digest) external view returns (bool) {
        return _ss.grantUsed[digest];
    }

    /// @inheritdoc IFallpitRouter
    function grantDigest(SessionGrant calldata g) external view returns (bytes32) {
        return SessionLogic.grantDigest(g);
    }

    /// @inheritdoc IFallpitRouter
    function orderDigest(Order calldata o) external view returns (bytes32) {
        return SessionLogic.orderDigest(o);
    }

    /// @inheritdoc IFallpitRouter
    function vaultOpDigest(VaultOp calldata v) external view returns (bytes32) {
        return SessionLogic.vaultOpDigest(v);
    }

    /// @inheritdoc IFallpitRouter
    function listOpDigest(ListOp calldata op) external view returns (bytes32) {
        return SessionLogic.listOpDigest(op);
    }

    /// @inheritdoc IFallpitRouter
    function cancelDigest(address user, uint256 nonce) external view returns (bytes32) {
        return SessionLogic.cancelDigest(user, nonce);
    }

    // ------------------------------------------------------------------------------------- ETH pools

    /// @inheritdoc IFallpitRouter
    /// @dev Only pools with no hooks: a hook on the ETH pool could take each buy down to `minChips`. The
    ///      book's owner is read through the hook, so the right follows the book's ownership. In
    ///      `SessionLogic.setEthPool`.
    function setEthPool(address chip, uint24 fee, int24 tickSpacing, address hooks) external {
        SessionLogic.setEthPool(_ethPools, deployer, address(hook), chip, fee, tickSpacing, hooks);
    }

    /// @inheritdoc IFallpitRouter
    function ethPoolKey(address chip) public view returns (PoolKey memory key) {
        EthPool memory p = _ethPools[chip];
        bool custom = p.tickSpacing != 0;
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(chip),
            fee: custom ? p.fee : ETH_POOL_FEE,
            tickSpacing: custom ? p.tickSpacing : ETH_POOL_TICK_SPACING,
            hooks: IHooks(custom ? p.hooks : address(0))
        });
    }

    /// @notice The ETH swap of `commitWithEth`, inside the PoolManager's unlock.
    /// @dev Only this router starts an unlock that calls back here, and only under its lock. The data is
    ///      (0, the chip, the ETH to swap); the first word is not read.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (!_locked()) revert OnlySelf();
        (, bytes memory chip, uint256 ethIn) = abi.decode(data, (uint256, bytes, uint256));
        return abi.encode(_swapEth(abi.decode(chip, (address)), ethIn));
    }

    /// @inheritdoc IFallpitRouter
    /// @dev Only from this router's own `fill`, under its lock. A buy sends the escrow to the hook, which
    ///      keeps the cost and sends the rest to the user (the buy's limit is what arrived: less than the
    ///      escrow only for a chip that started to tax after the commit); a sell leaves the escrowed tickets here for the
    ///      hook to burn, and the hook pays the user. The ETH sent is the filler's, for the oracle fee.
    function execute(uint256 commitId, bytes calldata report) external payable returns (uint256 chips) {
        if (msg.sender != address(this) || !_locked()) revert OnlySelf();
        StoredCommit memory c = _commits[commitId];
        IFallpitHook hook_ = hook;
        uint256 limit = c.limit;
        if (c.isBuy) {
            address chip = _termsOf(c.id).chip;
            // a buy spends at most what reaches the hook: all of the escrow (a buy's escrow is its limit),
            // unless the chip started to tax its transfers after the commit (then the cost must fit in what
            // arrived)
            uint256 before = chip.balanceOf(address(hook_));
            chip.safeTransfer(address(hook_), limit);
            limit = chip.balanceOf(address(hook_)) - before;
        }
        (bytes32 roundId, uint8 product) = hook_.tokenRef(c.id);
        chips = _hookFill(hook_, roundId, product, c, limit, report);
    }

    /// @dev The hook's fill of commit `c` with the buy limit `limit`, forwarding the ETH sent.
    function _hookFill(
        IFallpitHook hook_,
        bytes32 roundId,
        uint8 product,
        StoredCommit memory c,
        uint256 limit,
        bytes calldata report
    ) private returns (uint256) {
        return hook_.fill{value: msg.value}(
            roundId, product, c.isBuy, c.shares, limit, c.user, c.fillTs, report
        );
    }

    /// @inheritdoc IFallpitRouter
    function getCommit(uint256 commitId) external view returns (Commit memory m) {
        StoredCommit storage c = _commits[commitId];
        RoundTerms storage tm = _termsOf(c.id);
        m.user = c.user;
        m.fillTs = c.fillTs;
        m.status = c.status;
        m.isBuy = c.isBuy;
        m.id = c.id;
        m.chip = tm.chip;
        m.fillFee = tm.fillFee;
        m.refundDelay = tm.refundDelay;
        m.shares = c.shares;
        m.prev = uint96(_prevOf(c, commitId));
        m.limit = c.limit;
        m.escrow = _escrowOf(c);
    }

    /// @notice Total chip escrow of pending buy commits in `asset`; the router's balance always covers it.
    function escrowed(address asset) external view returns (uint256) {
        return _total(_escrowed[asset]);
    }

    /// @notice Total ticket escrow of pending sell commits of ticket `id`; the router's balance covers it.
    function escrowedTickets(uint256 id) external view returns (uint256) {
        return _total(_escrowedTickets[id]);
    }

    /// @dev Exact-input swap of `ethIn` native coin for `chip` on the chip's ETH pool; the chips go to this
    ///      router. Returns the ETH the pool did not take (only when it ran out of liquidity).
    function _swapEth(address chip, uint256 ethIn) private returns (uint256 ethLeft) {
        BalanceDelta delta = poolManager.swap(
            ethPoolKey(chip),
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        int128 ethDelta = delta.amount0();
        int128 chipDelta = delta.amount1();
        if (ethDelta > 0 || chipDelta < 0 || uint128(-ethDelta) > ethIn) revert UnexpectedDelta();
        uint256 paid = uint128(-ethDelta);
        if (paid != 0) poolManager.settle{value: paid}();
        if (chipDelta != 0) poolManager.take(Currency.wrap(chip), address(this), uint128(chipDelta));
        ethLeft = ethIn - paid;
    }

    /// @dev The commit before `c` (id `commitId`) that holds it, 0 for none.
    function _prevOf(StoredCommit storage c, uint256 commitId) private view returns (uint256) {
        uint256 gap = c.prevGap;
        return gap == 0 ? 0 : commitId - gap;
    }

    /// @dev The terms of the round of ticket `id` (a ticket id is its round id with the product in the low
    ///      byte).
    function _termsOf(uint256 id) private view returns (RoundTerms storage) {
        return _terms[bytes32(id & ~uint256(0xff))];
    }

    /// @dev The escrow of a commit: a buy escrows its limit in chips, a sell its shares in tickets.
    function _escrowOf(StoredCommit storage c) private view returns (uint256) {
        return c.isBuy ? c.limit : c.shares;
    }

    /// @dev A stored escrow total (total + 1 once used, 0 never used) as the total.
    function _total(uint256 raw) private pure returns (uint256) {
        return raw == 0 ? 0 : raw - 1;
    }

    /// @dev A stored escrow total with its first use marked: 1 for a slot never used, else unchanged.
    function _orOne(uint256 raw) private pure returns (uint256) {
        return raw == 0 ? 1 : raw;
    }

    /// @dev Takes a commit's escrow off the totals (the fill or the refund then moves it). The stored total
    ///      is the pending escrow plus 1, so it stays at 1 or above.
    function _release(StoredCommit storage c, RoundTerms storage tm, uint256 escrow) private {
        if (c.isBuy) _escrowed[tm.chip] -= escrow;
        else _escrowedTickets[c.id] -= escrow;
    }

    /// @dev Sends a refunded commit's escrow back to its user.
    function _returnEscrow(StoredCommit storage c, RoundTerms storage tm, address user, uint256 escrow)
        private
    {
        if (c.isBuy) tm.chip.safeTransfer(user, escrow);
        else IERC6909Balance(address(hook)).transfer(user, c.id, escrow);
    }

    /// @dev Pays a commit's fill fee to `to`, plus `extra` wei that are `to`'s own (the oracle fee of a
    ///      refunded fill). Called last, with the commit already closed and under the reentrancy lock.
    ///      It never reverts: the receiver gets `ETH_GAS` gas, no return data is copied, and when the
    ///      transfer fails the amount is credited in `ethOwed` for `claimEth`. So a receiver that reverts
    ///      or burns its gas cannot block a fill or a refund, and reentering gains it nothing.
    function _payFillFee(uint256 commitId, address to, uint256 fee, uint256 extra) private {
        uint256 amount = fee + extra;
        if (amount == 0) return;
        bool sent = to.trySafeTransferETH(amount, ETH_GAS);
        if (!sent) ethOwed[to] += amount;
        if (fee != 0) emit FillFeePaid(commitId, to, fee, sent);
    }

    /// @dev Classifies the revert data of a failed fill. The one final rejection is the hook's
    ///      `FillRejected(reason)` with a reason from 1 (`Limit`) to 7 (`ProductCap`). Only the hook reverts
    ///      with it: the coins it calls are checked by the chip guard, the oracle and the book are ours.
    function _refundReason(bytes memory err) private pure returns (RefundReason) {
        if (err.length != 0x24 || bytes4(err) != IFallpitHook.FillRejected.selector) {
            return RefundReason.None;
        }
        uint256 code;
        assembly ("memory-safe") {
            code := mload(add(err, 0x24))
        }
        // code 0 is None itself
        if (code > uint256(RefundReason.ProductCap)) return RefundReason.None;
        return RefundReason(code);
    }

    function _locked() private view returns (bool locked) {
        assembly ("memory-safe") {
            locked := tload(LOCK_SLOT)
        }
    }

    function _setLock(uint256 value) private {
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, value)
        }
    }
}
