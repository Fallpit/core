// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PitVault} from "../../src/PitVault.sol";
import {ITickerGate} from "../../src/interfaces/IPitVault.sol";
import {ChipGuard} from "../../src/ChipGuard.sol";
import {IPitVault} from "../../src/interfaces/IPitVault.sol";
import {MockChip, MockFeeChip} from "./mocks/MockChip.sol";
import {MockHook, MockOracle} from "./mocks/MockHook.sol";

/// @notice Shared setup: a vault with a mock hook, the real ChipGuard, a plain chip and a 1% tax chip. The
///         tax chip is approved but not flagged in the guard (the case the guard cannot see), so its house
///         exists; the vault itself must refuse its deposits and donations.
abstract contract VaultBase is Test {
    bytes32 internal constant NVDA = bytes32("NVDA");
    bytes32 internal constant TSLA = bytes32("TSLA");
    uint256 internal constant V = 1e6; // shares minted per chip unit in a fresh house

    address internal guardOwner = makeAddr("guardOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    PitVault internal vault;
    ChipGuard internal guard;
    MockOracle internal oracle;
    MockHook internal hook;
    MockChip internal chip;
    MockFeeChip internal taxChip;

    bytes32 internal house; // (NVDA, chip)
    bytes32 internal taxHouse; // (NVDA, taxChip)

    function setUp() public virtual {
        hook = new MockHook();
        guard = new ChipGuard(guardOwner);
        oracle = new MockOracle();
        vault = new PitVault(address(hook), guard, ITickerGate(address(oracle)));
        vault.setLister(address(this));
        hook.setVault(IPitVault(address(vault)));

        chip = new MockChip("Chip", "CHIP", 18);
        taxChip = new MockFeeChip();
        vm.startPrank(guardOwner);
        guard.approve(address(chip), true);
        guard.approve(address(taxChip), true);
        vm.stopPrank();
        oracle.setSupported(NVDA, true);
        oracle.setSupported(TSLA, true);

        house = vault.createHouse(NVDA, address(chip));
        taxHouse = vault.createHouse(NVDA, address(taxChip));

        address[4] memory users = [alice, bob, carol, dave];
        for (uint256 i; i < users.length; ++i) {
            chip.mint(users[i], 1_000_000e18);
            taxChip.mint(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            chip.approve(address(vault), type(uint256).max);
            taxChip.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _deposit(address who, bytes32 h, uint256 amount) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(h, amount);
    }

    function _withdraw(address who, bytes32 h, uint256 shares) internal returns (uint256 assets) {
        vm.prank(who);
        assets = vault.requestWithdraw(h, shares);
    }

    function _claim(address who, bytes32 h) internal returns (uint256 assets) {
        vm.prank(who);
        assets = vault.claim(h);
    }

    function _donate(address who, bytes32 h, uint256 amount) internal returns (uint256 credited) {
        vm.prank(who);
        credited = vault.donate(h, amount);
    }

    /// @dev Runs one round on `h` that ends with `back` chips sent home. Mints or burns the difference in
    ///      the hook, like traders' net result would.
    function _round(bytes32 h, MockChip c, uint256 back) internal returns (uint256 sent) {
        sent = hook.pull(h);
        _finish(h, c, back);
    }

    function _finish(bytes32 h, MockChip c, uint256 back) internal {
        uint256 has = c.balanceOf(address(hook));
        if (back > has) {
            c.mint(address(hook), back - has);
        } else if (has > back) {
            vm.prank(address(hook));
            c.burn(has - back);
        }
        hook.giveBack(h, address(c), back);
    }

    function _shares(address who, bytes32 h) internal view returns (uint256) {
        return vault.balanceOf(who, uint256(h));
    }

    function _h(bytes32 h) internal view returns (PitVault.House memory) {
        return vault.getHouse(h);
    }

    /// @dev Books of the two houses in this base must match the vault's balance exactly, unless chips were
    ///      sent straight to the vault (those wait for the next return).
    function _assertBooks(MockChip c, bytes32 h) internal view {
        assertEq(vault.heldFor(h), vault.accounted(address(c)), "house books != chip books");
        assertLe(vault.accounted(address(c)), c.balanceOf(address(vault)), "books exceed balance");
    }
}
