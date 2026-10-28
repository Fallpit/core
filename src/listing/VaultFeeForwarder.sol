// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {LibClone} from "solady/utils/LibClone.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IPitVault} from "../interfaces/IPitVault.sol";

/// @title VaultFeeForwarder
/// @notice A launchpad fee recipient for one house. Coins of the house's chip that reach it go to the house
///         (`PitVault.donate`, the vault's own stake: a deeper market). Any other token, and native ETH,
///         go to `recipient`, the address its creator chose (most often the coin team). Anyone may push.
/// @dev A clone with immutable args (vault, house, chip, recipient), made by `VaultFeeForwarderFactory`. It
///      has no owner and keeps coins only between pushes. Donations go to the endowment, not to the
///      depositors' share price: a share price that jumps at a known push could be taken by a deposit just
///      before it and a withdrawal just after.
contract VaultFeeForwarder {
    event Pushed(bytes32 indexed house, uint256 amount);
    event Forwarded(address indexed token, address indexed recipient, uint256 amount);

    error IsTheChip();

    receive() external payable {}

    /// @notice The vault, the house, its chip and the recipient of everything else.
    function config() public view returns (IPitVault vault, bytes32 house, address chip, address recipient) {
        (vault, house, chip, recipient) =
            abi.decode(LibClone.argsOnClone(address(this)), (IPitVault, bytes32, address, address));
    }

    /// @notice Donates every chip coin held to the house. Anyone may call it.
    /// @return amount the coins donated (0 when none)
    function push() external returns (uint256 amount) {
        (IPitVault vault, bytes32 house, address chip,) = config();
        amount = SafeTransferLib.balanceOf(chip, address(this));
        if (amount == 0) return 0;
        SafeTransferLib.safeApprove(chip, address(vault), amount);
        vault.donate(house, amount);
        emit Pushed(house, amount);
    }

    /// @notice Sends all of `token` held (address(0): native ETH) to the recipient. Anyone may call it. The
    ///         chip itself only goes to the house (`push`).
    function forward(address token) external returns (uint256 amount) {
        (,, address chip, address recipient) = config();
        if (token == chip) revert IsTheChip();
        if (token == address(0)) {
            amount = address(this).balance;
            if (amount != 0) SafeTransferLib.safeTransferAllETH(recipient);
        } else {
            amount = SafeTransferLib.balanceOf(token, address(this));
            if (amount != 0) SafeTransferLib.safeTransfer(token, recipient, amount);
        }
        if (amount != 0) emit Forwarded(token, recipient, amount);
    }
}

/// @title VaultFeeForwarderFactory
/// @notice Makes one `VaultFeeForwarder` per (house, recipient), at an address known before it exists, so a
///         team can point its launchpad fees at it first and create it later. The address is known once the
///         house is listed (it commits to the house's chip): before that `forwarderOf` reverts, so no fees
///         go to an address that can never hold code. Anyone may create one.
contract VaultFeeForwarderFactory {
    IPitVault public immutable vault;
    address public immutable implementation;

    /// @dev Every forwarder created, in order: the keeper reads them in pages to push each one.
    address[] internal _forwarders;

    event ForwarderCreated(bytes32 indexed house, address indexed recipient, address forwarder);

    error ZeroAddress();
    error UnknownHouse();

    constructor(IPitVault vault_) {
        if (address(vault_) == address(0)) revert ZeroAddress();
        vault = vault_;
        implementation = address(new VaultFeeForwarder());
    }

    /// @notice The forwarder of `house` for `recipient`, created or not. Reverts `UnknownHouse` while the
    ///         house is not listed in the vault.
    function forwarderOf(bytes32 house, address recipient) public view returns (address) {
        if (vault.chipOf(house) == address(0)) revert UnknownHouse();
        return LibClone.predictDeterministicAddress(
            implementation, _args(house, recipient), _salt(house, recipient), address(this)
        );
    }

    /// @notice Creates the forwarder of `house` for `recipient`; returns it if it exists already.
    function create(bytes32 house, address recipient) external returns (address forwarder) {
        if (recipient == address(0)) revert ZeroAddress();
        forwarder = forwarderOf(house, recipient);
        if (forwarder.code.length != 0) return forwarder;
        LibClone.cloneDeterministic(implementation, _args(house, recipient), _salt(house, recipient));
        _forwarders.push(forwarder);
        emit ForwarderCreated(house, recipient, forwarder);
    }

    /// @notice How many forwarders exist.
    function forwarderCount() external view returns (uint256) {
        return _forwarders.length;
    }

    /// @notice Forwarders `start` to `start + count - 1` (fewer at the end of the list).
    function forwarders(uint256 start, uint256 count) external view returns (address[] memory list) {
        uint256 n = _forwarders.length;
        if (start >= n) return list;
        uint256 end = start + count > n ? n : start + count;
        list = new address[](end - start);
        for (uint256 i = start; i < end; ++i) {
            list[i - start] = _forwarders[i];
        }
    }

    function _args(bytes32 house, address recipient) internal view returns (bytes memory) {
        return abi.encode(vault, house, vault.chipOf(house), recipient);
    }

    function _salt(bytes32 house, address recipient) internal pure returns (bytes32) {
        return keccak256(abi.encode(house, recipient));
    }
}
