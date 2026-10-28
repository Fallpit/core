// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";

/// @notice Gas of a fill with the mock pricing engine, and gas starvation as an attack on the refund path.
contract FallpitGasTest is HookFixture {
    function setUp() public override {
        super.setUp();
        _fund(alice, 100_000e18);
        _open();
    }

    /// @dev With `MockLadderMath` (two Newton solves over 40 bands, about 2.1M gas inside the math call).
    function test_gas_fill() public {
        // first fill of the round writes the 20 pricing slots (40 packed band states) for the first time
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t);
        bytes memory report = _report(t, S0);
        uint256 gasBefore = gasleft();
        router.fill(id, report);
        uint256 first = gasBefore - gasleft();

        id = _commitBuy(alice, LOWER, 1_000e18, 10_000e18);
        t = router.getCommit(id).fillTs;
        _warp(t);
        report = _report(t, S0 * 1001 / 1000);
        gasBefore = gasleft();
        router.fill(id, report);
        uint256 buy = gasBefore - gasleft();

        id = _commitSell(alice, HIGHER, 400e18, 0);
        t = router.getCommit(id).fillTs;
        _warp(t);
        report = _report(t, S0);
        gasBefore = gasleft();
        router.fill(id, report);
        uint256 sell = gasBefore - gasleft();

        emit log_named_uint("fill gas, first buy of a round", first);
        emit log_named_uint("fill gas, buy", buy);
        emit log_named_uint("fill gas, sell", sell);
        assertLt(first, 5_000_000);
        assertLt(buy, 5_000_000);
        assertLt(sell, 5_000_000);
    }

    /// @dev A filler who starves the fill of gas must not be able to turn it into a refund: at every gas
    ///      limit the fill either reverts (the commit stays pending) or executes.
    function test_attack_gasStarvation_neverRefunds() public {
        uint256 id = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t);
        bytes memory report = _report(t, S0);
        uint256 snapshot = vm.snapshotState();
        uint256 executed;
        for (uint256 gasLimit = 60_000; gasLimit <= 4_000_000; gasLimit += 70_000) {
            try router.fill{gas: gasLimit}(id, report) returns (bool filled) {
                assertTrue(filled, "a fill that returns must have executed, never refunded");
                ++executed;
            } catch {
                assertEq(
                    uint8(router.getCommit(id).status),
                    uint8(IFallpitRouter.CommitStatus.Pending),
                    "still pending"
                );
            }
            vm.revertToState(snapshot);
        }
        assertGt(executed, 0);
        assertEq(chip.balanceOf(alice), 90_000e18, "the escrow stayed in the router throughout");
    }
}
