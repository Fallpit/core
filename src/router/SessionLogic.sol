// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

import {IFallpitRouter} from "../interfaces/IFallpitRouter.sol";
import {IPitVault} from "../interfaces/IPitVault.sol";
import {IPitLister} from "../interfaces/IPitLister.sol";

/// @dev The views of the hook the router reads to find the vault and the book.
interface IVaultOf {
    function vault() external view returns (IPitVault);
    function book() external view returns (address);
}

/// @dev The router's session state (`FallpitRouter`), one struct so the library takes one pointer.
/// @param sessions the live session of each (user, key)
/// @param nonce each user's `sessionNonce`: `bumpSessionNonce` ends every session granted before
/// @param grantUsed grants already submitted, by digest: a revoked session cannot be revived with its old
///        grant
/// @param orderBits each user's used order nonces, a bitmap of 256 a word (orders, vault actions, cancels)
/// @param grantCount grants submitted per (user, key): `sessionSpent` counts per grant, so a new grant
///        starts at zero
/// @param spent what each grant of (user, key) spent, per coin
struct SessionStore {
    mapping(address user => mapping(address key => IFallpitRouter.Session)) sessions;
    mapping(address user => uint256) nonce;
    mapping(bytes32 digest => bool) grantUsed;
    mapping(address user => mapping(uint256 word => uint256 bits)) orderBits;
    mapping(address user => mapping(address key => uint256)) grantCount;
    mapping(
        address user => mapping(address key => mapping(uint256 grant => mapping(address coin => uint256)))
    ) spent;
    /// @dev A grant for (user, key) needs a nonce at least this: `revokeSession` sets it past the user's
    ///      nonce, so no other grant for that key signed before the revocation can restart the session.
    mapping(address user => mapping(address key => uint256)) grantFloor;
}

/// @dev A chip's ETH pool for `commitWithEth` (`FallpitRouter.setEthPool`); tickSpacing zero is the default.
struct EthPool {
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev The book's owner (the owner multisig), who may set the ETH pools.
interface IOwnerOf {
    function owner() external view returns (address);
}

/// @title SessionLogic
/// @notice The session paths of `FallpitRouter`: granting a session, the session key's signed orders,
///         vault actions, listings and cancels, the spending caps, and the EIP-712 digests they are signed
///         over. An external library linked into the router (it runs in the router's context, on the
///         router's storage, and its events come from the router): these are not on the commit and fill
///         path, and keeping them out of the router keeps it under the contract size limit. The rules are
///         on the router's functions (`IFallpitRouter`); the router keeps its reentrancy lock around every
///         call here.
library SessionLogic {
    using SafeTransferLib for address;

    uint256 internal constant MAX_SESSION = 7 days;

    /// @notice `FallpitRouter.setEthPool`: the deployer, or the owner of the hook's book (read through the
    ///         hook, so the right follows the book's ownership; nobody while the hook is not set). Only
    ///         pools with no hooks: a hook on the ETH pool could take each buy down to `minChips`. Cold, so
    ///         it lives here.
    function setEthPool(
        mapping(address chip => EthPool) storage pools,
        address deployer,
        address hook,
        address chip,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) external {
        if (
            msg.sender != deployer
                && (hook == address(0) || msg.sender != IOwnerOf(IVaultOf(hook).book()).owner())
        ) revert IFallpitRouter.OnlyDeployerOrOwner();
        if (hooks != address(0)) revert IFallpitRouter.PoolHasHooks();
        pools[chip] = EthPool({fee: fee, tickSpacing: tickSpacing, hooks: hooks});
        emit IFallpitRouter.EthPoolSet(chip, fee, tickSpacing, hooks);
    }

    uint8 internal constant SCOPE_TRADE = 1;
    uint8 internal constant SCOPE_VAULT = 2;

    uint8 internal constant VAULT_DEPOSIT = 0;
    uint8 internal constant VAULT_CANCEL_DEPOSIT = 1;
    uint8 internal constant VAULT_REQUEST_WITHDRAW = 2;
    uint8 internal constant VAULT_CLAIM = 3;

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

    /// @dev What a session key's signed action asks for (`_useSession`).
    struct Ask {
        address user;
        address key;
        uint8 scope;
        uint256 atRisk;
        uint64 deadline;
        uint256 nonce;
        bytes32 digest;
    }

    // ------------------------------------------------------------------------------------- grants

    /// @notice `FallpitRouter.grantSession`.
    function grant(SessionStore storage ss, IFallpitRouter.SessionGrant calldata g, bytes calldata signature)
        external
    {
        if (g.user == address(0) || g.key == address(0)) revert IFallpitRouter.ZeroAddress();
        if (g.expiry <= block.timestamp || g.expiry > block.timestamp + MAX_SESSION) {
            revert IFallpitRouter.BadExpiry();
        }
        if (g.maxPerOrder == 0) revert IFallpitRouter.ZeroAmount();
        if (g.scope == 0 || g.scope > (SCOPE_TRADE | SCOPE_VAULT)) revert IFallpitRouter.BadScope();
        if (g.nonce != ss.nonce[g.user]) revert IFallpitRouter.StaleNonce();
        bytes32 digest = grantDigest(g);
        if (ss.grantUsed[digest]) revert IFallpitRouter.GrantUsed();
        if (g.nonce < ss.grantFloor[g.user][g.key]) revert IFallpitRouter.StaleNonce();
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(g.user, digest, signature)) {
            revert IFallpitRouter.BadSignature();
        }
        ss.grantUsed[digest] = true;
        ss.sessions[g.user][g.key] = IFallpitRouter.Session({
            expiry: g.expiry,
            nonce: uint64(g.nonce),
            maxPerOrder: uint128(FixedPointMathLib.min(g.maxPerOrder, type(uint128).max)),
            maxTotal: uint128(FixedPointMathLib.min(g.maxTotal, type(uint128).max)),
            scope: g.scope
        });
        // a new grant counts its spending from zero
        ++ss.grantCount[g.user][g.key];
        emit IFallpitRouter.SessionGranted(g.user, g.key, g.expiry, g.maxPerOrder, g.maxTotal, g.scope);
    }

    /// @notice `FallpitRouter.cancelWithSig`.
    function cancel(
        SessionStore storage ss,
        address user,
        uint256 nonce,
        address key,
        bytes calldata signature
    ) external {
        IFallpitRouter.Session memory s = ss.sessions[user][key];
        if (s.scope == 0 || s.nonce != ss.nonce[user]) revert IFallpitRouter.NotSessionKey();
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(key, cancelDigest(user, nonce), signature)) {
            revert IFallpitRouter.BadSignature();
        }
        _useNonce(ss, user, nonce);
        emit IFallpitRouter.OrderCancelled(user, key, nonce, msg.sender);
    }

    // ------------------------------------------------------------------------------------- signed actions

    /// @notice The session checks of `FallpitRouter.commitWithSig`. Returns the session's `maxTotal`, for
    ///         `spend` once the commit knows its chip. Internal: a session commit is on the commit path, so
    ///         this code is compiled into the router and makes no library call.
    function orderSession(
        SessionStore storage ss,
        IFallpitRouter.Order calldata order,
        address key,
        bytes calldata signature
    ) internal returns (uint128 maxTotal) {
        return _useSession(
            ss,
            Ask({
                user: order.user,
                key: key,
                scope: SCOPE_TRADE,
                atRisk: order.isBuy ? order.limit : order.shares,
                deadline: order.deadline,
                nonce: order.nonce,
                digest: _orderDigest(order)
            }),
            signature
        )
        .maxTotal;
    }

    /// @notice `FallpitRouter.vaultWithSig`. The vault books and pays everything to `user`: the router
    ///         passes `user` as the owner of every call and keeps nothing (a deposit's chips pass through it
    ///         in the same call).
    function vaultOp(
        SessionStore storage ss,
        IFallpitRouter.VaultOp calldata op,
        address key,
        bytes calldata signature,
        address hook
    ) external returns (uint256 result) {
        uint8 kind = op.op;
        if (kind > VAULT_CLAIM) revert IFallpitRouter.BadVaultOp();
        IFallpitRouter.Session memory s = _useSession(
            ss,
            Ask({
                user: op.user,
                key: key,
                scope: SCOPE_VAULT,
                atRisk: kind == VAULT_DEPOSIT ? op.amount : 0,
                deadline: op.deadline,
                nonce: op.nonce,
                digest: vaultOpDigest(op)
            }),
            signature
        );
        if (hook == address(0)) revert IFallpitRouter.HookNotSet();
        IPitVault vault = IVaultOf(hook).vault();
        if (kind == VAULT_DEPOSIT) {
            result = _deposit(ss, op, key, s.maxTotal, vault);
        } else if (kind == VAULT_CANCEL_DEPOSIT) {
            result = vault.cancelDepositFor(op.house, op.user);
        } else if (kind == VAULT_REQUEST_WITHDRAW) {
            result = vault.requestWithdrawFor(op.house, op.amount, op.user);
        } else {
            result = vault.claimFor(op.house, op.user);
        }
        // A withdrawal with `minOut` must pay that much now (a queued one pays 0); a claim at least `minOut`.
        if (kind >= VAULT_REQUEST_WITHDRAW && result < op.minOut) {
            revert IFallpitRouter.MinOutNotMet(result, op.minOut);
        }
        emit IFallpitRouter.SessionVaultOp(
            op.user, key, kind, op.house, op.amount, op.nonce, msg.sender, result
        );
    }

    /// @notice `FallpitRouter.listWithSig`.
    function list(
        SessionStore storage ss,
        IFallpitRouter.ListOp calldata op,
        IPitLister.ListingQuote calldata quote,
        bytes calldata quoteSignature,
        address key,
        bytes calldata signature,
        address hook
    ) external returns (bytes32 house) {
        IPitLister lister = _listSession(ss, op, key, signature, hook);
        {
            address chip = op.chip;
            uint256 seed = op.seed;
            uint256 before = chip.balanceOf(address(this));
            chip.safeTransferFrom(op.user, address(this), seed);
            if (chip.balanceOf(address(this)) - before != seed) revert IFallpitRouter.BadEscrow();
            chip.safeApprove(address(lister), seed);
        }
        // the lister pulls exactly `seed` or reverts, so the router ends with what it held before
        house = lister.listCoinFor(op.user, op.chip, op.seed, quote, quoteSignature);
        emit IFallpitRouter.SessionListed(op.user, key, op.chip, house, op.seed, op.nonce, msg.sender);
    }

    /// @notice Adds `amount` of `coin` to what the current session of (`user`, `key`) spent; reverts over
    ///         its `maxTotal` (0: no cap). Nothing is ever taken off again (refunds included): a safe upper
    ///         bound. Internal, for the same reason as `orderSession`.
    function spend(
        SessionStore storage ss,
        address user,
        address key,
        uint128 maxTotal,
        address coin,
        uint256 amount
    ) internal {
        uint256 spent = ss.spent[user][key][ss.grantCount[user][key]][coin] += amount;
        if (maxTotal != 0 && spent > maxTotal) revert IFallpitRouter.OverSessionTotal(spent, maxTotal);
    }

    // ------------------------------------------------------------------------------------- digests

    /// @notice `FallpitRouter.grantDigest`.
    function grantDigest(IFallpitRouter.SessionGrant calldata g) public view returns (bytes32) {
        return _typed(
            keccak256(
                abi.encode(
                    GRANT_TYPEHASH, g.user, g.key, g.expiry, g.maxPerOrder, g.maxTotal, g.scope, g.nonce
                )
            )
        );
    }

    /// @notice `FallpitRouter.orderDigest`.
    function orderDigest(IFallpitRouter.Order calldata o) external view returns (bytes32) {
        return _orderDigest(o);
    }

    function _orderDigest(IFallpitRouter.Order calldata o) private view returns (bytes32) {
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

    /// @notice `FallpitRouter.vaultOpDigest`.
    function vaultOpDigest(IFallpitRouter.VaultOp calldata v) public view returns (bytes32) {
        return _typed(
            keccak256(
                abi.encode(VAULT_OP_TYPEHASH, v.user, v.op, v.house, v.amount, v.minOut, v.deadline, v.nonce)
            )
        );
    }

    /// @notice `FallpitRouter.listOpDigest`.
    function listOpDigest(IFallpitRouter.ListOp calldata op) public view returns (bytes32) {
        return
            _typed(keccak256(abi.encode(LIST_OP_TYPEHASH, op.user, op.chip, op.seed, op.deadline, op.nonce)));
    }

    /// @notice `FallpitRouter.cancelDigest`.
    function cancelDigest(address user, uint256 nonce) public view returns (bytes32) {
        return _typed(keccak256(abi.encode(CANCEL_TYPEHASH, user, nonce)));
    }

    // ------------------------------------------------------------------------------------- internals

    /// @dev A deposit of `vaultOp`: counts in the session's `maxTotal`, pulls the chips from the user and has
    ///      the vault take exactly that much for the user.
    function _deposit(
        SessionStore storage ss,
        IFallpitRouter.VaultOp calldata op,
        address key,
        uint128 maxTotal,
        IPitVault vault
    ) private returns (uint256) {
        bytes32 house = op.house;
        address chip = vault.chipOf(house);
        if (chip == address(0)) revert IFallpitRouter.UnknownHouse();
        uint256 amount = op.amount;
        spend(ss, op.user, key, maxTotal, chip, amount);
        uint256 before = chip.balanceOf(address(this));
        chip.safeTransferFrom(op.user, address(this), amount);
        if (chip.balanceOf(address(this)) - before != amount) revert IFallpitRouter.BadEscrow();
        chip.safeApprove(address(vault), amount);
        // the vault pulls exactly `amount` or reverts, so the router ends with what it held before
        return vault.depositFor(house, amount, op.user);
    }

    /// @dev The session checks of `list` and the seed's spend. Returns the lister.
    function _listSession(
        SessionStore storage ss,
        IFallpitRouter.ListOp calldata op,
        address key,
        bytes calldata signature,
        address hook
    ) private returns (IPitLister lister) {
        IFallpitRouter.Session memory s = _useSession(
            ss,
            Ask({
                user: op.user,
                key: key,
                scope: SCOPE_VAULT,
                atRisk: op.seed,
                deadline: op.deadline,
                nonce: op.nonce,
                digest: listOpDigest(op)
            }),
            signature
        );
        if (hook == address(0)) revert IFallpitRouter.HookNotSet();
        lister = IPitLister(IVaultOf(hook).vault().lister());
        spend(ss, op.user, key, s.maxTotal, op.chip, op.seed);
    }

    /// @dev Checks `a.key`'s live session for `a.user`, its scope, the deadline, the amount against
    ///      `maxPerOrder`, the key's signature over `a.digest`, and uses up `a.nonce` in the user's bitmap
    ///      (shared by orders, vault actions and cancels). Returns the session.
    function _useSession(SessionStore storage ss, Ask memory a, bytes calldata signature)
        private
        returns (IFallpitRouter.Session memory s)
    {
        s = ss.sessions[a.user][a.key];
        if (s.expiry < block.timestamp || s.nonce != ss.nonce[a.user]) revert IFallpitRouter.NoSession();
        if (s.scope & a.scope == 0) revert IFallpitRouter.OutOfScope();
        if (block.timestamp > a.deadline) revert IFallpitRouter.OrderExpired();
        if (a.atRisk > s.maxPerOrder) revert IFallpitRouter.OverSessionCap();
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(a.key, a.digest, signature)) {
            revert IFallpitRouter.BadSignature();
        }
        _useNonce(ss, a.user, a.nonce);
    }

    /// @dev Uses up `nonce` in `user`'s bitmap, or reverts `OrderUsed`.
    function _useNonce(SessionStore storage ss, address user, uint256 nonce) private {
        uint256 word = nonce >> 8;
        uint256 bit = 1 << (nonce & 0xff);
        uint256 bits = ss.orderBits[user][word];
        if (bits & bit != 0) revert IFallpitRouter.OrderUsed();
        ss.orderBits[user][word] = bits | bit;
    }

    /// @dev EIP-712 digest in the router's domain (`address(this)` is the router: the library runs in its
    ///      context). The domain separator is computed each time.
    function _typed(bytes32 structHash) private view returns (bytes32) {
        bytes32 domain =
            keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }
}
