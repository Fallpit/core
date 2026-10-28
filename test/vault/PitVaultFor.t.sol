// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultBase} from "./VaultBase.sol";
import {PitVault} from "../../src/PitVault.sol";

/// @notice The LP functions for an owner (`depositFor`, `cancelDepositFor`, `requestWithdrawFor`,
///         `claimFor`) with a mock hook that names no router: only the owner and its operators may call
///         them, and every share and chip goes to the owner.
contract PitVaultForTest is VaultBase {
    address internal op = makeAddr("op");

    function setUp() public override {
        super.setUp();
        chip.mint(op, 1_000_000e18);
        vm.prank(op);
        chip.approve(address(vault), type(uint256).max);
    }

    function test_router_isZeroWhenTheHookNamesNone() public view {
        assertEq(vault.router(), address(0));
    }

    function test_for_notOperator_refused() public {
        vm.startPrank(op);
        vm.expectRevert(PitVault.InsufficientPermission.selector);
        vault.depositFor(house, 1e18, alice);
        vm.expectRevert(PitVault.InsufficientPermission.selector);
        vault.cancelDepositFor(house, alice);
        vm.expectRevert(PitVault.InsufficientPermission.selector);
        vault.requestWithdrawFor(house, 1, alice);
        vm.expectRevert(PitVault.InsufficientPermission.selector);
        vault.claimFor(house, alice);
        vm.stopPrank();
    }

    function test_for_operator_allOpsPayTheOwner() public {
        vm.prank(alice);
        vault.setOperator(op, true);
        uint256 aliceChips = chip.balanceOf(alice);

        // unlocked: deposit and withdraw now
        vm.prank(op);
        uint256 shares = vault.depositFor(house, 100e18, alice);
        assertEq(shares, 100e18 * V);
        assertEq(vault.balanceOf(alice, uint256(house)), shares);
        assertEq(vault.balanceOf(op, uint256(house)), 0);
        vm.prank(op);
        uint256 paid = vault.requestWithdrawFor(house, shares / 2, alice);
        assertEq(chip.balanceOf(alice), aliceChips + paid);

        // locked: queue a deposit and cancel it, queue a withdrawal and claim it after the round
        hook.pull(house);
        vm.prank(op);
        assertEq(vault.depositFor(house, 10e18, alice), 0);
        vm.prank(op);
        assertEq(vault.cancelDepositFor(house, alice), 10e18);
        assertEq(chip.balanceOf(alice), aliceChips + paid + 10e18, "the cancelled deposit goes to the owner");

        uint256 rest = vault.balanceOf(alice, uint256(house));
        vm.prank(op);
        vault.requestWithdrawFor(house, rest, alice);
        hook.giveBack(house, address(chip), 50e18);
        vm.prank(op);
        uint256 claimed = vault.claimFor(house, alice);
        assertGt(claimed, 0);
        assertEq(chip.balanceOf(alice), aliceChips + paid + 10e18 + claimed);
        assertEq(chip.balanceOf(op), 1_000_000e18 - 110e18, "the operator paid the deposits and got nothing");
        assertEq(vault.accounted(address(chip)), chip.balanceOf(address(vault)));
    }
}
