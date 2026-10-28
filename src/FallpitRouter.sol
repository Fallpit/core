// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

import {IFallpitHook, RefundReason} from "./interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "./interfaces/IFallpitRouter.sol";
import {IPitVault} from "./interfaces/IPitVault.sol";
import {IPitLister} from "./interfaces/IPitLister.sol";

/// @dev The views of the hook the router reads to find the vault and the book.
interface IVaultOf {
    function vault() external view returns (IPitVault);
    function book() external view returns (address);
}

/// @dev The book's owner (the owner multisig), who may set the ETH pools.
interface IOwnerOf {
    function owner() external view returns (address);
}

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
    uint256 public constant MAX_SESSION = 7 days;

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("Fallpit Router");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes32 private constant GRANT_TYPEHASH = keccak256(
        "SessionGrant(address user,address key,uint64 expiry,uint256 maxPerOrder,uint256 maxTotal,uint8 scope,uint256 nonce)"
    );
    bytes32 private constant ORDER_TYPEHASH = keccak256(
        "Order(address user,bytes32 roundId,uint8 product,bool isBuy,uint256 shares,uint256 limit,uint64 deadline,uint256 nonce)"
    );
    bytes32 private constant VAULT_OP_TYPEHASH = keccak256(
        "VaultOp(address user,uint8 op,bytes32 house,uint256 amount,uint256 minOut,uint64 deadline,uint256 nonce)"
    );
    bytes32 private constant CANCEL_TYPEHASH = keccak256("CancelOrder(address user,uint256 nonce)");
    bytes32 private constant LIST_OP_TYPEHASH =
        keccak256("ListOp(address user,address chip,uint256 seed,uint64 deadline,uint256 nonce)");

    /// @notice `SessionGrant.scope` bits: trade (`commitWithSig`) and vault (`vaultWithSig`).
    uint8 public constant SCOPE_TRADE = 1;
    uint8 public constant SCOPE_VAULT = 2;

    /// @notice `VaultOp.op` values.
    uint8 public constant VAULT_DEPOSIT = 0;
    uint8 public constant VAULT_CANCEL_DEPOSIT = 1;
    uint8 public constant VAULT_REQUEST_WITHDRAW = 2;
    uint8 public constant VAULT_CLAIM = 3;

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

    mapping(address user => mapping(address key => Session)) internal _sessions;
    /// @inheritdoc IFallpitRouter
    mapping(address user => uint256) public sessionNonce;
    /// @notice Grants already submitted, by digest: a revoked session cannot be revived with its old grant.
    mapping(bytes32 digest => bool) public grantUsed;
    mapping(address user => mapping(uint256 word => uint256 bits)) internal _orderBits;
    /// @inheritdoc IFallpitRouter
    mapping(uint256 commitId => address) public feePayerOf;
    /// @dev Pool overrides per chip for `commitWithEth`; `tickSpacing` zero: the default pool.
    mapping(address chip => EthPool) internal _ethPools;
    /// @dev Grants submitted per (user, key): `sessionSpent` counts per grant, so a new grant starts at zero.
    mapping(address user => mapping(address key => uint256)) internal _grantCount;
    mapping(
        address user => mapping(address key => mapping(uint256 grant => mapping(address coin => uint256)))
    ) internal _spent;

    /// @dev A commit as stored: `IFallpitRouter.Commit` without `escrow`, which is always
    ///      `isBuy ? limit : shares` (`_escrowOf`), plus `relayed` (true when `feePayerOf` is set, so a fill
    ///      reads `feePayerOf` only then). Five slots.
    struct StoredCommit {
        address user;
        uint64 fillTs;
        CommitStatus status;
        bool isBuy;
        bool relayed;
        uint256 id;
        address chip;
        uint64 fillFee;
        uint32 refundDelay;
        uint128 shares;
        uint96 prev;
        uint256 limit;
    }

    struct EthPool {
        uint24 fee;
        int24 tickSpacing;
        address hooks;
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
        IFallpitHook hook_ = hook;
        if (address(hook_) == address(0)) revert HookNotSet();
        (uint256 id, address chip,,,,, uint64 fillFee,) = hook_.commitContext(roundId, product);
        if (id == 0) revert UnknownProduct();
        if (msg.value <= fillFee) revert WrongFillFee();
        uint256 ethIn = msg.value - fillFee;

        uint256 before = chip.balanceOf(address(this));
        uint256 ethLeft =
            abi.decode(poolManager.unlock(abi.encode(uint256(0), abi.encode(chip), ethIn)), (uint256));
        uint256 chips = chip.balanceOf(address(this)) - before;
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
        IFallpitHook hook_ = hook;
        if (address(hook_) == address(0)) revert HookNotSet();
        (
            uint256 id,
            address chip,
            bool tradable,
            uint32 fillDelay,
            uint32 refundDelay,
            uint256 minShares,
            uint64 fillFee,
            bool isOpen
        ) = hook_.commitContext(roundId, product);
        if (!isOpen) revert RoundNotOpen();
        if (id == 0) revert UnknownProduct();
        // The filler's pay travels with the commit: exactly the round's fee, no more and no less.
        if (feeIn != fillFee) revert WrongFillFee();
        // The instant the commit is priced at must be inside a trading window of the round's clock.
        if (!tradable) revert OutsideTradingWindow();
        if (shares == 0 || shares > uint128(type(int128).max)) revert ZeroAmount();
        // Dust costs its sender little and whoever fills it a full pricing run.
        if (shares < minShares) revert BelowMinimumTrade();

        // Escrow. Chips by balance difference, and it must be exactly what was sent: a chip that taxes its
        // transfers cannot trade. Tickets move inside the hook, exactly.
        uint256 escrow = isBuy ? limit : shares;
        if (escrow == 0) revert ZeroAmount();
        if (!isBuy) {
            hook_.pull(user, id, shares);
            _escrowedTickets[id] = _orOne(_escrowedTickets[id]) + shares;
        } else {
            if (source != FROM_HERE) {
                uint256 before = chip.balanceOf(address(this));
                chip.safeTransferFrom(user, address(this), limit);
                if (chip.balanceOf(address(this)) - before != limit) revert BadEscrow();
            }
            _escrowed[chip] = _orOne(_escrowed[chip]) + escrow;
        }

        commitId = nextCommitId++;
        uint64 fillTs = uint64(block.timestamp) + fillDelay;
        LastCommit memory lc = _lastCommit[roundId];
        _lastCommit[roundId] = LastCommit({fillTs: fillTs, id: uint192(commitId)});
        _commits[commitId] = StoredCommit({
            user: user,
            fillTs: fillTs,
            status: CommitStatus.Pending,
            isBuy: isBuy,
            id: id,
            chip: chip,
            fillFee: fillFee,
            refundDelay: refundDelay,
            relayed: false,
            shares: uint128(shares),
            // the round's previous commit, while its fill window overlaps this one's (fill instants only grow)
            prev: uint256(lc.fillTs) + refundDelay >= fillTs ? uint96(lc.id) : 0,
            limit: limit
        });
        emit Committed(commitId, user, roundId, product, isBuy, shares, limit, escrow, fillTs);
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
        StoredCommit storage c = _commits[commitId];
        if (c.status != CommitStatus.Pending) revert CommitNotPending();
        if (block.timestamp < c.fillTs) revert TooEarly();
        if (block.timestamp > uint256(c.fillTs) + c.refundDelay) revert FillWindowClosed();
        uint256 prev = c.prev;
        if (prev != 0) {
            // The earlier commit holds this one while it is pending and can still be filled. Its window
            // ends first (same round: same `refundDelay`, an earlier or equal fill instant); after that
            // it can only be refunded and holds nobody.
            StoredCommit storage p = _commits[prev];
            if (p.status == CommitStatus.Pending && block.timestamp <= uint256(p.fillTs) + c.refundDelay) {
                revert EarlierCommitPending(prev);
            }
        }

        address user = c.user;
        uint256 escrow = _escrowOf(c);
        uint256 fee = c.fillFee;
        // A relayed commit's fee goes back to its payer, unless the payer fills: else anyone (the user
        // too) could fill relayed commits first and take the relayer's fees.
        address payer = c.relayed ? feePayerOf[commitId] : address(0);
        if (payer == msg.sender) payer = address(0);
        c.status = CommitStatus.Filled;
        _release(c, escrow);

        try this.execute{value: msg.value}(commitId, report) returns (uint256 chips) {
            emit Filled(commitId, user, chips);
            _payFillFee(commitId, payer == address(0) ? msg.sender : payer, fee, 0);
            return true;
        } catch (bytes memory err) {
            // Everything inside `execute` was rolled back; the escrow is still here.
            RefundReason reason = _refundReason(err);
            if (reason == RefundReason.None) {
                assembly ("memory-safe") {
                    revert(add(err, 0x20), mload(err))
                }
            }
            c.status = CommitStatus.Refunded;
            _returnEscrow(c, user, escrow);
            emit Refunded(commitId, user, reason);
            // The filler did the work of a fill that could never succeed: the fee is theirs, and the
            // ETH they sent for the oracle comes back with it. A relayed commit's fee goes back to its
            // payer instead (see above).
            if (payer == address(0)) {
                _payFillFee(commitId, msg.sender, fee, msg.value);
            } else {
                _payFillFee(commitId, payer, fee, 0);
                _payFillFee(commitId, msg.sender, 0, msg.value);
            }
            return false;
        }
    }

    /// @inheritdoc IFallpitRouter
    function refund(uint256 commitId) external nonReentrant {
        StoredCommit storage c = _commits[commitId];
        if (c.status != CommitStatus.Pending) revert CommitNotPending();
        if (block.timestamp <= uint256(c.fillTs) + c.refundDelay) revert RefundNotDue();
        address user = c.user;
        uint256 escrow = _escrowOf(c);
        uint256 fee = c.fillFee;
        c.status = CommitStatus.Refunded;
        _release(c, escrow);
        _returnEscrow(c, user, escrow);
        emit Refunded(commitId, user, RefundReason.Expired);
        // Nobody filled: the fill fee goes back to whoever paid it (the trader, or a session's relayer),
        // the escrow to the trader.
        address payer = c.relayed ? feePayerOf[commitId] : address(0);
        _payFillFee(commitId, payer == address(0) ? user : payer, fee, 0);
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
        if (grant.user == address(0) || grant.key == address(0)) revert ZeroAddress();
        if (grant.expiry <= block.timestamp || grant.expiry > block.timestamp + MAX_SESSION) {
            revert BadExpiry();
        }
        if (grant.maxPerOrder == 0) revert ZeroAmount();
        if (grant.scope == 0 || grant.scope > (SCOPE_TRADE | SCOPE_VAULT)) revert BadScope();
        if (grant.nonce != sessionNonce[grant.user]) revert StaleNonce();
        bytes32 digest = grantDigest(grant);
        if (grantUsed[digest]) revert GrantUsed();
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(grant.user, digest, signature)) {
            revert BadSignature();
        }
        grantUsed[digest] = true;
        _sessions[grant.user][grant.key] = Session({
            expiry: grant.expiry,
            nonce: uint64(grant.nonce),
            maxPerOrder: uint128(FixedPointMathLib.min(grant.maxPerOrder, type(uint128).max)),
            maxTotal: uint128(FixedPointMathLib.min(grant.maxTotal, type(uint128).max)),
            scope: grant.scope
        });
        // a new grant counts its spending from zero
        ++_grantCount[grant.user][grant.key];
        emit SessionGranted(
            grant.user, grant.key, grant.expiry, grant.maxPerOrder, grant.maxTotal, grant.scope
        );
    }

    /// @inheritdoc IFallpitRouter
    /// @dev Only the expiry is cleared: the session is dead, and its key can still sign `CancelOrder`s.
    function revokeSession(address key) external {
        _sessions[msg.sender][key].expiry = 0;
        emit SessionRevoked(msg.sender, key);
    }

    /// @inheritdoc IFallpitRouter
    function cancelWithSig(address user, uint256 nonce, address key, bytes calldata signature) external {
        Session memory s = _sessions[user][key];
        if (s.scope == 0 || s.nonce != sessionNonce[user]) revert NotSessionKey();
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(key, cancelDigest(user, nonce), signature)) {
            revert BadSignature();
        }
        _useNonce(user, nonce);
        emit OrderCancelled(user, key, nonce, msg.sender);
    }

    /// @inheritdoc IFallpitRouter
    function useNonces(uint256 word, uint256 mask) external {
        _orderBits[msg.sender][word] |= mask;
        emit NoncesUsed(msg.sender, word, mask);
    }

    /// @inheritdoc IFallpitRouter
    function bumpSessionNonce() external {
        uint256 n = ++sessionNonce[msg.sender];
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
        Session memory s = _useSession(
            user,
            key,
            SCOPE_TRADE,
            order.isBuy ? order.limit : order.shares,
            order.deadline,
            order.nonce,
            orderDigest(order),
            signature
        );
        commitId = _commit(
            user, order.roundId, order.product, order.isBuy, order.shares, order.limit, FROM_USER, msg.value
        );
        if (order.isBuy) _spend(user, key, s, _commits[commitId].chip, order.limit);
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
        address user = op.user;
        uint8 kind = op.op;
        if (kind > VAULT_CLAIM) revert BadVaultOp();
        Session memory s = _useSession(
            user,
            key,
            SCOPE_VAULT,
            kind == VAULT_DEPOSIT ? op.amount : 0,
            op.deadline,
            op.nonce,
            vaultOpDigest(op),
            signature
        );
        if (address(hook) == address(0)) revert HookNotSet();
        IPitVault vault = IVaultOf(address(hook)).vault();
        bytes32 house = op.house;
        if (kind == VAULT_DEPOSIT) {
            address chip = vault.chipOf(house);
            if (chip == address(0)) revert UnknownHouse();
            uint256 amount = op.amount;
            _spend(user, key, s, chip, amount);
            uint256 before = chip.balanceOf(address(this));
            chip.safeTransferFrom(user, address(this), amount);
            if (chip.balanceOf(address(this)) - before != amount) revert BadEscrow();
            chip.safeApprove(address(vault), amount);
            // the vault pulls exactly `amount` or reverts, so the router ends with what it held before
            result = vault.depositFor(house, amount, user);
        } else if (kind == VAULT_CANCEL_DEPOSIT) {
            result = vault.cancelDepositFor(house, user);
        } else if (kind == VAULT_REQUEST_WITHDRAW) {
            result = vault.requestWithdrawFor(house, op.amount, user);
        } else {
            result = vault.claimFor(house, user);
        }
        // A withdrawal with `minOut` must pay that much now (a queued one pays 0); a claim at least `minOut`.
        if (kind >= VAULT_REQUEST_WITHDRAW && result < op.minOut) revert MinOutNotMet(result, op.minOut);
        emit SessionVaultOp(user, key, kind, house, op.amount, op.nonce, msg.sender, result);
    }

    /// @inheritdoc IFallpitRouter
    function listWithSig(
        ListOp calldata op,
        IPitLister.ListingQuote calldata quote,
        bytes calldata quoteSignature,
        address key,
        bytes calldata signature
    ) external nonReentrant returns (bytes32 house) {
        address user = op.user;
        Session memory s =
            _useSession(user, key, SCOPE_VAULT, op.seed, op.deadline, op.nonce, listOpDigest(op), signature);
        if (address(hook) == address(0)) revert HookNotSet();
        IPitLister lister = IPitLister(IVaultOf(address(hook)).vault().lister());
        address chip = op.chip;
        uint256 seed = op.seed;
        _spend(user, key, s, chip, seed);
        uint256 before = chip.balanceOf(address(this));
        chip.safeTransferFrom(user, address(this), seed);
        if (chip.balanceOf(address(this)) - before != seed) revert BadEscrow();
        chip.safeApprove(address(lister), seed);
        // the lister pulls exactly `seed` or reverts, so the router ends with what it held before
        house = lister.listCoinFor(user, chip, seed, quote, quoteSignature);
        emit SessionListed(user, key, chip, house, seed, op.nonce, msg.sender);
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

    /// @dev Checks `key`'s live session for `user`, its scope, the deadline, the amount against
    ///      `maxPerOrder`, the key's signature over `digest`, and uses up `nonce` in the user's bitmap
    ///      (shared by orders, vault actions and cancels). Returns the session for `_spend`.
    function _useSession(
        address user,
        address key,
        uint8 scope,
        uint256 atRisk,
        uint64 deadline,
        uint256 nonce,
        bytes32 digest,
        bytes calldata signature
    ) private returns (Session memory s) {
        s = _sessions[user][key];
        if (s.expiry < block.timestamp || s.nonce != sessionNonce[user]) revert NoSession();
        if (s.scope & scope == 0) revert OutOfScope();
        if (block.timestamp > deadline) revert OrderExpired();
        if (atRisk > s.maxPerOrder) revert OverSessionCap();
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(key, digest, signature)) revert BadSignature();
        _useNonce(user, nonce);
    }

    /// @dev Adds `amount` of `coin` to what the current session of (`user`, `key`) spent; reverts over its
    ///      `maxTotal` (0: no cap). Nothing is ever taken off again (refunds included): a safe upper bound.
    function _spend(address user, address key, Session memory s, address coin, uint256 amount) private {
        uint256 spent = _spent[user][key][_grantCount[user][key]][coin] += amount;
        if (s.maxTotal != 0 && spent > s.maxTotal) revert OverSessionTotal(spent, s.maxTotal);
    }

    /// @dev Uses up `nonce` in `user`'s bitmap, or reverts `OrderUsed`.
    function _useNonce(address user, uint256 nonce) private {
        uint256 word = nonce >> 8;
        uint256 bit = 1 << (nonce & 0xff);
        uint256 bits = _orderBits[user][word];
        if (bits & bit != 0) revert OrderUsed();
        _orderBits[user][word] = bits | bit;
    }

    /// @inheritdoc IFallpitRouter
    function sessionOf(address user, address key) external view returns (Session memory) {
        return _sessions[user][key];
    }

    /// @inheritdoc IFallpitRouter
    function sessionSpent(address user, address key, address coin) external view returns (uint256) {
        return _spent[user][key][_grantCount[user][key]][coin];
    }

    /// @inheritdoc IFallpitRouter
    function orderNonceUsed(address user, uint256 nonce) external view returns (bool) {
        return _orderBits[user][nonce >> 8] & (1 << (nonce & 0xff)) != 0;
    }

    /// @inheritdoc IFallpitRouter
    function grantDigest(SessionGrant calldata g) public view returns (bytes32) {
        return _typed(
            keccak256(
                abi.encode(
                    GRANT_TYPEHASH, g.user, g.key, g.expiry, g.maxPerOrder, g.maxTotal, g.scope, g.nonce
                )
            )
        );
    }

    /// @inheritdoc IFallpitRouter
    function orderDigest(Order calldata o) public view returns (bytes32) {
        return _typed(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    o.user,
                    o.roundId,
                    o.product,
                    o.isBuy,
                    o.shares,
                    o.limit,
                    o.deadline,
                    o.nonce
                )
            )
        );
    }

    /// @inheritdoc IFallpitRouter
    function vaultOpDigest(VaultOp calldata v) public view returns (bytes32) {
        return _typed(
            keccak256(
                abi.encode(VAULT_OP_TYPEHASH, v.user, v.op, v.house, v.amount, v.minOut, v.deadline, v.nonce)
            )
        );
    }

    /// @inheritdoc IFallpitRouter
    function listOpDigest(ListOp calldata op) public view returns (bytes32) {
        return
            _typed(keccak256(abi.encode(LIST_OP_TYPEHASH, op.user, op.chip, op.seed, op.deadline, op.nonce)));
    }

    /// @inheritdoc IFallpitRouter
    function cancelDigest(address user, uint256 nonce) public view returns (bytes32) {
        return _typed(keccak256(abi.encode(CANCEL_TYPEHASH, user, nonce)));
    }

    // ------------------------------------------------------------------------------------- ETH pools

    /// @inheritdoc IFallpitRouter
    /// @dev Only pools with no hooks: a hook on the ETH pool could take each buy down to `minChips`. The
    ///      book's owner is read through the hook, so the right follows the book's ownership.
    function setEthPool(address chip, uint24 fee, int24 tickSpacing, address hooks) external {
        if (msg.sender != deployer && !_isBookOwner(msg.sender)) revert OnlyDeployerOrOwner();
        if (hooks != address(0)) revert PoolHasHooks();
        _ethPools[chip] = EthPool({fee: fee, tickSpacing: tickSpacing, hooks: hooks});
        emit EthPoolSet(chip, fee, tickSpacing, hooks);
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

    /// @dev True when `account` is the owner of the hook's book (false while the hook is not set).
    function _isBookOwner(address account) private view returns (bool) {
        address hook_ = address(hook);
        return hook_ != address(0) && account == IOwnerOf(IVaultOf(hook_).book()).owner();
    }

    /// @dev EIP-712 digest in this router's domain. The domain separator is computed each time (no
    ///      immutables: solc 0.8.26 via-IR fails with a second immutable here).
    function _typed(bytes32 structHash) private view returns (bytes32) {
        bytes32 domain =
            keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
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
            // a buy spends at most what reaches the hook: all of the escrow (a buy's escrow is its limit),
            // unless the chip started to tax its transfers after the commit (then the cost must fit in what
            // arrived)
            uint256 before = c.chip.balanceOf(address(hook_));
            c.chip.safeTransfer(address(hook_), limit);
            limit = c.chip.balanceOf(address(hook_)) - before;
        }
        (bytes32 roundId, uint8 product) = hook_.tokenRef(c.id);
        chips = hook_.fill{value: msg.value}(
            roundId, product, c.isBuy, c.shares, limit, c.user, c.fillTs, report
        );
    }

    /// @inheritdoc IFallpitRouter
    function getCommit(uint256 commitId) external view returns (Commit memory) {
        StoredCommit storage c = _commits[commitId];
        return Commit({
            user: c.user,
            fillTs: c.fillTs,
            status: c.status,
            isBuy: c.isBuy,
            id: c.id,
            chip: c.chip,
            fillFee: c.fillFee,
            refundDelay: c.refundDelay,
            shares: c.shares,
            prev: c.prev,
            limit: c.limit,
            escrow: _escrowOf(c)
        });
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
    function _release(StoredCommit storage c, uint256 escrow) private {
        if (c.isBuy) _escrowed[c.chip] -= escrow;
        else _escrowedTickets[c.id] -= escrow;
    }

    /// @dev Sends a refunded commit's escrow back to its user.
    function _returnEscrow(StoredCommit storage c, address user, uint256 escrow) private {
        if (c.isBuy) c.chip.safeTransfer(user, escrow);
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
        if (code < uint256(RefundReason.Limit) || code > uint256(RefundReason.ProductCap)) {
            return RefundReason.None;
        }
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
