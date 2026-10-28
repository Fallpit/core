// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IPitVault} from "../../../src/interfaces/IPitVault.sol";

/// @notice Minimal vault: one capital figure per house, credited by balance difference, no shares.
contract MockPitVault is IPitVault {
    using SafeTransferLib for address;

    struct House {
        address chip;
        uint256 capital;
        bool locked;
    }

    address public hook;
    mapping(bytes32 house => House) public houses;
    /// @notice Chips of all houses the vault accounts for, per chip.
    mapping(address chip => uint256) public accounted;

    error OnlyHook();
    error Locked();
    error NoHouse();

    /// @dev The LP functions for an owner are not part of this mock.
    function depositFor(bytes32, uint256, address) external pure returns (uint256) {
        revert("mock");
    }

    function cancelDepositFor(bytes32, address) external pure returns (uint256) {
        revert("mock");
    }

    function requestWithdrawFor(bytes32, uint256, address) external pure returns (uint256) {
        revert("mock");
    }

    function claimFor(bytes32, address) external pure returns (uint256) {
        revert("mock");
    }

    function setHook(address hook_) external {
        require(hook == address(0), "hook set");
        hook = hook_;
    }

    function houseId(bytes32 ticker, address chip) public pure returns (bytes32) {
        return keccak256(abi.encode(ticker, chip));
    }

    function createHouse(bytes32 ticker, address chip) external returns (bytes32 house) {
        house = houseId(ticker, chip);
        houses[house].chip = chip;
    }

    /// @dev The hook tests need no lister: anyone may create a house in the mock.
    function lister() external pure returns (address) {
        return address(0);
    }

    function setLister(address) external pure {}

    function depositLocked(bytes32, uint256, address, uint64) external pure returns (uint256) {
        revert("mock: no seed locks");
    }

    function lockOf(bytes32, address) external pure returns (uint256, uint64) {
        return (0, 0);
    }

    /// @notice Adds capital to an unlocked house, credited by balance difference.
    function deposit(bytes32 house, uint256 amount) external {
        House storage h = houses[house];
        if (h.chip == address(0)) revert NoHouse();
        if (h.locked) revert Locked();
        uint256 before = h.chip.balanceOf(address(this));
        h.chip.safeTransferFrom(msg.sender, address(this), amount);
        uint256 got = h.chip.balanceOf(address(this)) - before;
        h.capital += got;
        accounted[h.chip] += got;
    }

    /// @inheritdoc IPitVault
    function pullRoundCapital(bytes32 house, address to) external returns (uint256 sent) {
        if (msg.sender != hook) revert OnlyHook();
        House storage h = houses[house];
        if (h.chip == address(0)) revert NoHouse();
        if (h.locked) revert Locked();
        sent = h.capital;
        h.capital = 0;
        h.locked = true;
        accounted[h.chip] -= sent;
        h.chip.safeTransfer(to, sent);
    }

    /// @inheritdoc IPitVault
    function returnRoundCapital(bytes32 house) external returns (uint256 received) {
        if (msg.sender != hook) revert OnlyHook();
        House storage h = houses[house];
        received = h.chip.balanceOf(address(this)) - accounted[h.chip];
        h.capital = received;
        accounted[h.chip] += received;
        h.locked = false;
    }

    /// @inheritdoc IPitVault
    function donate(bytes32 house, uint256 amount) external returns (uint256 credited) {
        House storage h = houses[house];
        if (h.chip == address(0)) revert NoHouse();
        if (h.locked) revert Locked();
        uint256 before = h.chip.balanceOf(address(this));
        h.chip.safeTransferFrom(msg.sender, address(this), amount);
        credited = h.chip.balanceOf(address(this)) - before;
        h.capital += credited;
        accounted[h.chip] += credited;
    }

    /// @inheritdoc IPitVault
    function chipOf(bytes32 house) external view returns (address) {
        return houses[house].chip;
    }

    function roundCapital(bytes32 house) external view returns (uint256) {
        return houses[house].capital;
    }

    function isLocked(bytes32 house) external view returns (bool) {
        return houses[house].locked;
    }
}
