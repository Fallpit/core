// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";

import {IChipGuard} from "./interfaces/IChipGuard.sol";

/// @title ChipGuard
/// @notice Decides which coins may be a chip. See contracts/SPEC.md section 6 and src/vault/DESIGN.md.
/// @dev A chip is allowed when it is not refused, is not flagged as a fee-on-transfer coin, has code,
///      reports at most 18 decimals, has no active Doppler balance limit, and is trusted by one of three
///      routes:
///      1. its `extcodehash` is a trusted template hash (Doppler coins: every coin is the same 44-byte
///         minimal clone of one implementation, so all of them share one hash);
///      2. a trusted launch registry vouches for it (Pons v2 coins: each coin has its own bytecode because
///         of constructor immutables, so the factory is asked instead);
///      3. the owner approved it by address.
///      The owner can only change these lists. The guard holds no funds.
///
///      Fee-on-transfer (tax) coins are never chips: a flagged coin is never allowed, whatever route
///      trusts it. The flag is the owner's knowledge, nothing on chain verifies it; an unflagged tax coin
///      is stopped where it would enter instead (the vault and the router refuse a transfer that delivers
///      another amount than was sent).
contract ChipGuard is IChipGuard, Ownable {
    /// @notice How a trusted registry answers "did you launch this coin?".
    /// @dev `ReturnsChip`: the first return word is the coin's own address (Pons v2
    ///      `getLaunchedToken(address)`, zero for unknown coins). `ReturnsTrue`: the first return word is 1.
    enum RegistryMatch {
        None,
        ReturnsChip,
        ReturnsTrue
    }

    struct Registry {
        address target;
        bytes4 selector;
        RegistryMatch matchKind;
    }

    /// @notice Most registries `check` will ask.
    uint256 public constant MAX_REGISTRIES = 8;

    /// @dev Gas given to each read of a chip or a registry. A failed read must come from the callee, not
    ///      from a caller that sent too little gas, so `check` reverts when it cannot forward this much.
    uint256 internal constant PROBE_GAS = 200_000;

    /// @notice True when coins with this `extcodehash` are trusted.
    mapping(bytes32 codeHash => bool) public trustedCodeHash;
    /// @notice True when the owner approved this coin by address.
    mapping(address chip => bool) public approved;
    /// @notice True when the owner refused this coin. A refusal beats every other route.
    mapping(address chip => bool) public refused;
    /// @notice Owner-set flag: transfers of this coin deliver less than the amount sent. A flagged coin is
    ///         not allowed as a chip.
    mapping(address chip => bool) public feeOnTransfer;

    Registry[] internal _registries;

    event TrustedCodeHashSet(bytes32 indexed codeHash, bool trusted);
    event TrustedRegistrySet(address indexed target, bytes4 selector, RegistryMatch matchKind);
    event Approved(address indexed chip, bool approved);
    event Refused(address indexed chip, bool refused);
    event FeeOnTransferSet(address indexed chip, bool feeOnTransfer);

    error ZeroAddress();
    error TooManyRegistries();
    error InsufficientGas();

    /// @param owner_ the address that manages the lists
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        _initializeOwner(owner_);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------------------------------

    /// @notice Trusts or stops trusting every coin whose `extcodehash` is `codeHash`.
    function setTrustedCodeHash(bytes32 codeHash, bool trusted) external onlyOwner {
        trustedCodeHash[codeHash] = trusted;
        emit TrustedCodeHashSet(codeHash, trusted);
    }

    /// @notice Trusts a launch registry, changes how it is asked, or removes it (`RegistryMatch.None`).
    /// @param target the registry, for example the Pons v2 factory
    /// @param selector a view function taking the coin address
    /// @param matchKind how the answer marks a coin the registry launched
    function setTrustedRegistry(address target, bytes4 selector, RegistryMatch matchKind) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        uint256 n = _registries.length;
        uint256 i;
        while (i < n && _registries[i].target != target) ++i;
        if (matchKind == RegistryMatch.None) {
            if (i < n) {
                _registries[i] = _registries[n - 1];
                _registries.pop();
            }
        } else if (i < n) {
            _registries[i].selector = selector;
            _registries[i].matchKind = matchKind;
        } else {
            if (n == MAX_REGISTRIES) revert TooManyRegistries();
            _registries.push(Registry(target, selector, matchKind));
        }
        emit TrustedRegistrySet(target, selector, matchKind);
    }

    /// @notice Approves one coin by address, or takes the approval back.
    function approve(address chip, bool isApproved) external onlyOwner {
        approved[chip] = isApproved;
        emit Approved(chip, isApproved);
    }

    /// @notice Refuses one coin (for example a rebasing coin), or lifts the refusal.
    function refuse(address chip, bool isRefused) external onlyOwner {
        refused[chip] = isRefused;
        emit Refused(chip, isRefused);
    }

    /// @notice Flags a coin whose transfers deliver less than the amount sent. While flagged it is not
    ///         allowed as a chip.
    function setFeeOnTransfer(address chip, bool isFeeOnTransfer) external onlyOwner {
        feeOnTransfer[chip] = isFeeOnTransfer;
        emit FeeOnTransferSet(chip, isFeeOnTransfer);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IChipGuard
    /// @dev Never reverts on a misbehaving coin; it reverts only when called with too little gas.
    function check(address chip) external view returns (bool allowed, bool isFeeOnTransfer) {
        isFeeOnTransfer = feeOnTransfer[chip];
        if (isFeeOnTransfer || refused[chip] || chip.code.length == 0) return (false, isFeeOnTransfer);

        (bool ok, uint256 word) = _probe(chip, abi.encodeWithSignature("decimals()"));
        if (!ok || word > 18) return (false, isFeeOnTransfer);

        // Doppler coins cap every holder's balance for a while after launch. Coins without the function
        // fail this read and pass.
        (ok, word) = _probe(chip, abi.encodeWithSignature("isBalanceLimitActive()"));
        if (ok && word != 0) return (false, isFeeOnTransfer);

        allowed = approved[chip] || trustedCodeHash[chip.codehash] || _launchedByTrustedRegistry(chip);
    }

    /// @notice The trusted launch registries.
    function registries() external view returns (Registry[] memory) {
        return _registries;
    }

    /// @notice True when a trusted registry vouches for `chip`.
    function launchedByTrustedRegistry(address chip) external view returns (bool) {
        return _launchedByTrustedRegistry(chip);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _launchedByTrustedRegistry(address chip) internal view returns (bool) {
        uint256 n = _registries.length;
        for (uint256 i; i < n; ++i) {
            Registry memory r = _registries[i];
            (bool ok, uint256 word) = _probe(r.target, abi.encodeWithSelector(r.selector, chip));
            if (!ok) continue;
            if (r.matchKind == RegistryMatch.ReturnsChip ? word == uint256(uint160(chip)) : word == 1) {
                return true;
            }
        }
        return false;
    }

    /// @dev Static call with a gas cap that reads at most one return word.
    /// @return ok true when the call succeeded and returned at least 32 bytes
    /// @return word the first return word
    function _probe(address target, bytes memory data) internal view returns (bool ok, uint256 word) {
        // EIP-150 forwards at most 63/64 of the gas left; make sure the callee really gets PROBE_GAS.
        if (gasleft() < PROBE_GAS + PROBE_GAS / 32) revert InsufficientGas();
        assembly ("memory-safe") {
            ok := staticcall(PROBE_GAS, target, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            word := mload(0x00)
        }
    }
}
