// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {RefundReason} from "./IFallpitHook.sol";
import {IPitLister} from "./IPitLister.sol";

/// @title IFallpitRouter
/// @notice Two-step trading on Fallpit: commit, then fill at the first oracle print after the commit.
///         See contracts/SPEC.md section 7.3.
interface IFallpitRouter {
    enum CommitStatus {
        None,
        Pending,
        Filled,
        Refunded
    }

    /// @param user who committed; receives the tickets, the proceeds and every refund
    /// @param fillTs the instant the fill is priced at: commit time plus the round's fill delay
    /// @param refundDelay seconds after `fillTs` in which the commit can be filled; refundable after
    /// @param fillFee native coin, in wei, held with the commit for whoever fills it
    /// @param id the product's ticket (an ERC-6909 id of the hook, `IFallpitHook.tokenId`)
    /// @param chip chip of the round
    /// @param prev the round's commit made just before this one, when their fill windows overlap (0 when
    ///        there is none): a round's commits are filled in commit order, so this commit fills only once
    ///        `prev` is no longer pending or its fill window has ended
    /// @param shares tickets to buy or sell (at most 2^127 - 1)
    /// @param limit buy: the most chips the user sends in total; sell: the least chips the user accepts
    /// @param escrow what the router holds for this commit: chips (buy) or the product's tickets (sell)
    struct Commit {
        address user;
        uint64 fillTs;
        CommitStatus status;
        bool isBuy;
        uint256 id;
        address chip;
        uint64 fillFee;
        uint32 refundDelay;
        uint128 shares;
        uint96 prev;
        uint256 limit;
        uint256 escrow;
    }

    /// @notice A user's permission for `key` to sign orders for them (see `grantSession`). Signed by the user
    ///         as EIP-712 `SessionGrant(address user,address key,uint64 expiry,uint256 maxPerOrder,
    ///         uint256 maxTotal,uint8 scope,uint256 nonce)` in the domain {name "Fallpit Router", version "1",
    ///         chainId, verifyingContract: this router}.
    /// @param expiry last second the session may be used; at most `MAX_SESSION` after it is granted
    /// @param maxPerOrder most chips one order may put at risk (a buy's `limit`) or tokens it may sell
    ///        (a sell's `shares`), and most chips one vault deposit may take
    /// @param maxTotal most coins of one kind the session may spend in total: the sum of its buys' `limit`s
    ///        and its deposits' amounts, per coin (`sessionSpent`). Nothing is credited back when a commit
    ///        is refunded or spends less. 0: no total cap
    /// @param scope bit 0 (`SCOPE_TRADE`, 1): `commitWithSig`; bit 1 (`SCOPE_VAULT`, 2): `vaultWithSig`. At
    ///        least one bit, no other bits
    /// @param nonce the user's `sessionNonce` when signed; `bumpSessionNonce` ends every session granted before
    struct SessionGrant {
        address user;
        address key;
        uint64 expiry;
        uint256 maxPerOrder;
        uint256 maxTotal;
        uint8 scope;
        uint256 nonce;
    }

    /// @notice One order signed by a session key, as EIP-712 `Order(address user,bytes32 roundId,uint8 product,
    ///         bool isBuy,uint256 shares,uint256 limit,uint64 deadline,uint256 nonce)` in the same domain.
    ///         `nonce` is any number the key has not used for `user` before (a bitmap, so out of order is fine).
    struct Order {
        address user;
        bytes32 roundId;
        uint8 product;
        bool isBuy;
        uint256 shares;
        uint256 limit;
        uint64 deadline;
        uint256 nonce;
    }

    /// @notice One vault action signed by a session key, as EIP-712 `VaultOp(address user,uint8 op,bytes32 house,
    ///         uint256 amount,uint256 minOut,uint64 deadline,uint256 nonce)` in the same domain. `op`: 0 deposit
    ///         `amount` chips (at most the session's `maxPerOrder`, counted in its `maxTotal`), 1 cancel the
    ///         queued deposit, 2 request a withdrawal of `amount` shares, 3 claim; `amount` is ignored by 1
    ///         and 3. `minOut`: op 2, when not zero, the withdrawal must pay at least `minOut` chips now (the
    ///         house must be unlocked: a withdrawal that would queue reverts); op 3, the claim must pay at
    ///         least `minOut`; ignored by 0 and 1. `nonce` comes from the same bitmap as the orders'
    ///         (`orderNonceUsed`).
    struct VaultOp {
        address user;
        uint8 op;
        bytes32 house;
        uint256 amount;
        uint256 minOut;
        uint64 deadline;
        uint256 nonce;
    }

    /// @notice A session listing (EIP-712 `ListOp(address user,address chip,uint256 seed,uint64 deadline,
    ///         uint256 nonce)`): list `chip` with `seed` of the user's coins as the locked seed. `nonce` comes
    ///         from the same bitmap as the orders'.
    struct ListOp {
        address user;
        address chip;
        uint256 seed;
        uint64 deadline;
        uint256 nonce;
    }

    /// @notice A granted session as stored. `expiry` zero: no live session (never granted, or revoked). A
    ///         revoked session keeps its other fields, so its key can still sign `CancelOrder`s.
    /// @param maxTotal 0: no total cap
    /// @param scope `SCOPE_TRADE` and/or `SCOPE_VAULT`; zero only when never granted
    struct Session {
        uint64 expiry;
        uint64 nonce;
        uint128 maxPerOrder;
        uint128 maxTotal;
        uint8 scope;
    }

    event HookSet(address indexed hook);
    event SessionGranted(
        address indexed user,
        address indexed key,
        uint64 expiry,
        uint256 maxPerOrder,
        uint256 maxTotal,
        uint8 scope
    );
    event SessionRevoked(address indexed user, address indexed key);
    event SessionNonceBumped(address indexed user, uint256 nonce);
    /// @param payer who sent the transaction and the fill fee; a refund of an unfilled commit pays it back
    event SessionOrder(
        uint256 indexed commitId, address indexed user, address indexed key, uint256 nonce, address payer
    );
    event Committed(
        uint256 indexed commitId,
        address indexed user,
        bytes32 indexed roundId,
        uint8 product,
        bool isBuy,
        uint256 shares,
        uint256 limit,
        uint256 escrow,
        uint64 fillTs
    );
    /// @param chips chips the user sent (buy, gross of any transfer tax) or was sent (sell)
    event Filled(uint256 indexed commitId, address indexed user, uint256 chips);
    event Refunded(uint256 indexed commitId, address indexed user, RefundReason reason);
    /// @notice The fill fee of a commit left its escrow: to the filler when `fill` ended in a trade or in a
    ///         refund, back to the trader when nobody filled in time. The fee of a session commit that someone
    ///         else paid (`feePayerOf`) goes back to that payer, after a trade or a refund, unless the payer
    ///         filled it.
    /// @param sent false when `to` did not take the transfer; the amount then waits in `ethOwed(to)`
    event FillFeePaid(uint256 indexed commitId, address indexed to, uint256 amount, bool sent);
    event EthClaimed(address indexed account, address indexed to, uint256 amount);
    /// @param relayer who sent the transaction
    /// @param result what the vault call returned: shares minted (deposit) or chips paid to the user
    event SessionVaultOp(
        address indexed user,
        address indexed key,
        uint8 op,
        bytes32 indexed house,
        uint256 amount,
        uint256 nonce,
        address relayer,
        uint256 result
    );
    event SessionListed(
        address indexed user,
        address indexed key,
        address indexed chip,
        bytes32 house,
        uint256 seed,
        uint256 nonce,
        address relayer
    );
    /// @param ethIn native coin the swap took (the value sent less the fill fee, less any ETH sent back)
    /// @param chips chips received and escrowed as the commit's limit
    event BoughtWithEth(uint256 indexed commitId, address indexed user, uint256 ethIn, uint256 chips);
    event EthPoolSet(address indexed chip, uint24 fee, int24 tickSpacing, address hooks);
    /// @notice The deployer gave up its rights: it can never call `setHook` or `setEthPool` again.
    event DeployerRenounced(address indexed deployer);
    /// @notice `key` cancelled the user's order or vault action `nonce` on chain (`cancelWithSig`).
    event OrderCancelled(address indexed user, address indexed key, uint256 nonce, address relayer);
    /// @notice The user used up the nonces `word * 256 + i` for every bit `i` set in `mask` (`useNonces`).
    event NoncesUsed(address indexed user, uint256 word, uint256 mask);

    error OnlyDeployer();
    /// @dev `setEthPool` by an account that is neither the deployer nor the book's owner.
    error OnlyDeployerOrOwner();
    error OnlyPoolManager();
    error HookAlreadySet();
    error HookNotSet();
    error BadHook();
    error Reentrancy();
    error RoundNotOpen();
    /// @dev The round's menu has no product with that index.
    error UnknownProduct();
    error OutsideTradingWindow();
    error ZeroAmount();
    error BelowMinimumTrade();
    error BadEscrow();
    /// @dev The native coin sent with a commit is not exactly the round's fill fee.
    error WrongFillFee();
    error NothingToClaim();
    error CommitNotPending();
    error TooEarly();
    error FillWindowClosed();
    error RefundNotDue();
    error UnexpectedDelta();
    /// @dev `execute` called by anyone but this router during its own `fill`.
    error OnlySelf();
    /// @dev `fill` of a commit while the commit before it with the same round and fill instant is still
    ///      pending: fill that one first.
    error EarlierCommitPending(uint256 prev);
    error ZeroAddress();
    /// @dev A grant whose expiry is in the past or more than `MAX_SESSION` ahead.
    error BadExpiry();
    /// @dev A grant signed under an older `sessionNonce`.
    error StaleNonce();
    /// @dev This exact grant was submitted before (a revoked session cannot be brought back with it).
    error GrantUsed();
    error BadSignature();
    /// @dev The key has no live session for the user: never granted, revoked, expired or ended by a nonce bump.
    error NoSession();
    error OrderExpired();
    error OrderUsed();
    /// @dev The order puts more at risk than the session's `maxPerOrder`.
    error OverSessionCap();
    /// @dev `VaultOp.op` above 3.
    error BadVaultOp();
    /// @dev A vault deposit into a house that does not exist.
    error UnknownHouse();
    /// @dev `commitWithEth`: the swap gave fewer chips than `minChips` (or none).
    error TooFewChips(uint256 chips, uint256 minChips);
    /// @dev A grant whose `scope` is zero or has bits other than `SCOPE_TRADE` and `SCOPE_VAULT`.
    error BadScope();
    /// @dev The session's scope does not cover this call (trade or vault).
    error OutOfScope();
    /// @dev This spend would take the session over its `maxTotal` for the coin.
    error OverSessionTotal(uint256 spent, uint256 maxTotal);
    /// @dev A session vault withdrawal or claim paid less than its `minOut`.
    error MinOutNotMet(uint256 paid, uint256 minOut);
    /// @dev `redeemFor` for the router or the hook.
    error BadHolder();
    /// @dev `setEthPool` with a pool that has hooks.
    error PoolHasHooks();
    /// @dev `cancelWithSig` by a key that was never granted a session for the user under the current
    ///      `sessionNonce`.
    error NotSessionKey();

    /// @notice One-time wiring of the hook, by the deployer. Frozen afterwards.
    function setHook(address hook) external;

    /// @notice The deployer: may call `setHook` once and `setEthPool`, until `renounceDeployer`. Zero after it.
    function deployer() external view returns (address);

    /// @notice Deployer only: gives up the deployer's rights for ever (`setHook` then always reverts, and
    ///         only the book's owner can call `setEthPool`). The deploy calls it once the wiring is done.
    function renounceDeployer() external;

    /// @notice Escrows a trade to be filled at the first oracle print at or after `block.timestamp +
    ///         fillDelay`. A buy escrows `limit` chips; a sell escrows `shares` tickets of the product.
    /// @param product index of the product in the round's menu
    /// @dev `msg.value` must be exactly the round's fill fee (`IFallpitHook.commitContext`, also returned
    ///      by the lens's `quote`). It is held with the commit and paid to whoever fills it.
    function commit(bytes32 roundId, uint8 product, bool isBuy, uint256 shares, uint256 limit)
        external
        payable
        returns (uint256 commitId);

    /// @notice `commit` on the round of house (`ticker`, `chip`) for `day`, opening that round first when
    ///         nobody has yet (`IFallpitHook.openRound`, open to anyone). The first player of a quiet house
    ///         opens its round in the same transaction as their trade, and pays its gas.
    function openAndCommit(
        bytes32 ticker,
        address chip,
        uint32 day,
        uint8 product,
        bool isBuy,
        uint256 shares,
        uint256 limit
    ) external payable returns (uint256 commitId);

    /// @notice Buys with native coin in one call: swaps `msg.value` less the round's fill fee for the round's
    ///         chip on the chip's ETH pool (`ethPoolKey`), then commits a buy of `shares` for the caller with
    ///         the limit `min(limit, chips received)` (escrowed like any buy). Chips received above that limit
    ///         go back to the caller at once. Chips the fill does not spend, and the whole escrow when the
    ///         commit is refunded, go back to the caller as chips.
    /// @param minChips least chips the swap must give (slippage bound on the swap)
    /// @param limit most chips the buy may spend (the price bound of the trade)
    /// @param deadline last second the call may run (`OrderExpired` after it)
    function commitWithEth(
        bytes32 roundId,
        uint8 product,
        uint256 shares,
        uint256 minChips,
        uint256 limit,
        uint64 deadline
    ) external payable returns (uint256 commitId);

    /// @notice Fills a commit with the oracle report for its fill instant, or refunds it when the fill can
    ///         never succeed. Anyone may call. The caller is paid the commit's fill fee, for a trade and for
    ///         a refund; the fee of a session commit that someone else paid for (`feePayerOf`) goes back to
    ///         that payer unless the payer is the caller. The commits of one round are filled in commit
    ///         order: this reverts while `prev` of the commit is pending and its fill window is still open.
    /// @dev `msg.value` is for the oracle's update fee, not for the fill fee.
    /// @return filled false when the commit was refunded
    function fill(uint256 commitId, bytes calldata report) external payable returns (bool filled);

    /// @notice Refunds a commit nobody filled within its fill window, with its fill fee. Anyone may call.
    function refund(uint256 commitId) external;

    /// @notice Native coin the router holds for `account` because a transfer to it failed: a fill fee
    ///         earned, a fill fee refunded, or the oracle fee of a refunded fill.
    function ethOwed(address account) external view returns (uint256);

    /// @notice Sends everything in `ethOwed(msg.sender)` to `to`.
    function claimEth(address to) external returns (uint256 amount);

    /// @notice Burns the caller's `amount` of ticket `id` for what it redeems for (`IFallpitHook.redeem`).
    function redeem(uint256 id, uint256 amount) external returns (uint256 payout);

    function getCommit(uint256 commitId) external view returns (Commit memory);

    // ------------------------------------------------------------------------------------- sessions

    /// @notice Stores a session the user signed (`SessionGrant`). Anyone may submit it, so granting costs
    ///         the user no gas. EOA and ERC-1271 (smart account) signatures are both accepted.
    function grantSession(SessionGrant calldata grant, bytes calldata signature) external;

    /// @notice Ends `key`'s session for the caller at once.
    function revokeSession(address key) external;

    /// @notice Ends every session the caller granted so far (grants signed with the old nonce no longer work).
    function bumpSessionNonce() external;

    /// @notice Commits an order that `key` signed for `order.user` under a live session. Anyone may submit
    ///         it (a relayer); `msg.value` is the round's fill fee, paid by the submitter. The commit is the
    ///         user's: their chips are escrowed through their approval to this router, a sell escrows their
    ///         tickets through `IFallpitHook.pull`, and everything it pays goes to the user. Only the fill
    ///         fee of a commit that ends in a refund (nobody filled it, or the fill was rejected) goes back
    ///         to the submitter. Needs the session's `SCOPE_TRADE`; a buy's `limit` counts in `maxTotal`.
    function commitWithSig(Order calldata order, address key, bytes calldata signature)
        external
        payable
        returns (uint256 commitId);

    /// @notice Marks the user's order or vault action `nonce` used, so it can never be relayed. `key` signs
    ///         EIP-712 `CancelOrder(address user,uint256 nonce)` in the same domain; it must hold, or have held,
    ///         a session for `user` under the user's current `sessionNonce` (the key of a revoked or expired
    ///         session still may cancel). Anyone may submit it. Reverts `OrderUsed` when the nonce is used.
    function cancelWithSig(address user, uint256 nonce, address key, bytes calldata signature) external;

    /// @notice Marks the caller's nonces `word * 256 + i` used for every bit `i` set in `mask` (orders and vault
    ///         actions share them). Nonces used before stay used.
    function useNonces(uint256 word, uint256 mask) external;

    /// @notice Runs a vault action that `key` signed for `op.user` under a live session (`VaultOp`). Anyone may
    ///         submit it. The router acts through the vault's `depositFor`, `cancelDepositFor`,
    ///         `requestWithdrawFor` and `claimFor` with `op.user` as the owner: a deposit's chips come from
    ///         the user's approval to this router, and every share and chip paid out goes to the user. Needs
    ///         the session's `SCOPE_VAULT`; a deposit counts in `maxTotal`; `minOut` bounds ops 2 and 3.
    /// @return result shares minted now (deposit; 0 when queued), chips paid to the user (cancel, a withdrawal
    ///         paid now, claim), 0 for a queued withdrawal
    function vaultWithSig(VaultOp calldata op, address key, bytes calldata signature)
        external
        returns (uint256 result);

    /// @notice Lists a coin for `op.user` under a live session (`ListOp` signed by `key`), through
    ///         `PitLister.listCoinFor`: the seed comes from the user's approval to this router and is locked
    ///         for the user. Needs the session's `SCOPE_VAULT`; the seed counts in `maxPerOrder` and
    ///         `maxTotal`. Anyone may submit it (the keeper relays it).
    /// @param quote the keeper's price of the coin, and `quoteSignature` its signature (see `PitLister`)
    /// @return house the new house
    function listWithSig(
        ListOp calldata op,
        IPitLister.ListingQuote calldata quote,
        bytes calldata quoteSignature,
        address key,
        bytes calldata signature
    ) external returns (bytes32 house);

    /// @notice The deployer (until `renounceDeployer`) or the book's owner: the pool `commitWithEth` swaps on
    ///         for `chip` (always ETH/chip with ETH as currency0, and only a pool with no hooks: `hooks` must
    ///         be zero, or `PoolHasHooks`). `tickSpacing` zero restores the default (fee 10000, tick spacing 200).
    function setEthPool(address chip, uint24 fee, int24 tickSpacing, address hooks) external;

    /// @notice The pool `commitWithEth` swaps on for `chip`.
    function ethPoolKey(address chip) external view returns (PoolKey memory);

    /// @notice Redeems all of `user`'s tickets `id` for them (see `IFallpitHook.redeem`); the payout always
    ///         goes to `user`. Anyone may call (no session needed: it only makes a holder collect what is
    ///         theirs). `user` may not be this router (its balance is the escrow of pending sells) or the
    ///         hook (`BadHolder`).
    function redeemFor(address user, uint256 id) external returns (uint256 payout);

    /// @notice The body of `fill`, called by this router on itself so that a rejection rolls it all back.
    /// @return chips the cost (buy) or the proceeds (sell)
    function execute(uint256 commitId, bytes calldata report) external payable returns (uint256 chips);

    function sessionOf(address user, address key) external view returns (Session memory);

    /// @notice Coins of `coin` that `key`'s current session for `user` has spent (buy limits and deposits),
    ///         counted against `maxTotal`. Starts at zero with each new grant.
    function sessionSpent(address user, address key, address coin) external view returns (uint256);

    function sessionNonce(address user) external view returns (uint256);

    function orderNonceUsed(address user, uint256 nonce) external view returns (bool);

    /// @notice Whoever paid the fill fee of a session commit (zero for a plain commit: the user paid).
    function feePayerOf(uint256 commitId) external view returns (address);

    /// @notice The EIP-712 digests the user and the key sign.
    function grantDigest(SessionGrant calldata grant) external view returns (bytes32);

    function orderDigest(Order calldata order) external view returns (bytes32);

    function vaultOpDigest(VaultOp calldata op) external view returns (bytes32);

    function listOpDigest(ListOp calldata op) external view returns (bytes32);

    function cancelDigest(address user, uint256 nonce) external view returns (bytes32);
}
