// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice The first player of a house opens its round with their trade (`router.openAndCommit`), and the
///         next day's open writes the house's open depths over used slots.
contract FallpitOpenAndCommitTest is HookFixture {
    function setUp() public override {
        super.setUp();
        _fund(alice, 100_000e18);
        _fund(bob, 100_000e18);
    }

    function test_openAndCommit_opensTheRoundAndCommits_thenJustCommits() public {
        bytes32 rid = hook.roundIdOf(house, day);
        assertEq(uint8(hook.getState(rid).status), uint8(IFallpitHook.Status.None));
        vm.prank(alice);
        uint256 a = router.openAndCommit{value: FILL_FEE}(
            NVDA, address(chip), day, HIGHER, true, 1_000e18, 10_000e18
        );
        roundId = rid;
        assertEq(uint8(_state().status), uint8(IFallpitHook.Status.Open), "the trade opened the round");
        assertEq(hook.getConfig(rid).capital, HOUSE_CAPITAL);
        // a second player the same day: the round is open, so it only commits
        vm.prank(bob);
        uint256 b =
            router.openAndCommit{value: FILL_FEE}(NVDA, address(chip), day, LOWER, true, 1_000e18, 10_000e18);
        assertTrue(_fill(a, S0));
        assertTrue(_fill(b, S0));
        assertEq(_token(HIGHER).balanceOf(alice), 1_000e18);
        assertEq(_token(LOWER).balanceOf(bob), 1_000e18);
    }

    function test_openAndCommit_refusedWhenTheRoundCannotOpen() public {
        // Wednesday's round cannot open before Tuesday's close
        vm.prank(alice);
        vm.expectRevert();
        router.openAndCommit{value: FILL_FEE}(NVDA, address(chip), day + 1, HIGHER, true, 1_000e18, 10_000e18);
        // a product the menu does not have
        vm.prank(alice);
        vm.expectRevert(IFallpitRouter.UnknownProduct.selector);
        router.openAndCommit{value: FILL_FEE}(NVDA, address(chip), day, 11, true, 1_000e18, 10_000e18);
    }

    /// @dev The next day's open writes over the slots of the day before.
    function test_gas_secondOpen_writesOverUsedSlots() public {
        uint256 g = gasleft();
        _open();
        uint256 first = g - gasleft();
        _closeAndFinalize(S0);
        _warp(NYTime.closeTs(day) + 120);
        g = gasleft();
        hook.openRound(NVDA, address(chip), day + 1);
        uint256 second = g - gasleft();
        emit log_named_uint("openRound, first open of a house", first);
        emit log_named_uint("openRound, next day", second);
        assertLt(second, first);
    }
}
