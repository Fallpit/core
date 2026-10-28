// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";

import {StackFixture} from "./StackFixture.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice Gas of opening a round, two commits, two fills and recording a close, on the real hook,
///         router, book, math and vault. The oracle is the one-print-per-second stand-in, so verification
///         costs are not in these numbers; `Gas.t.sol` has fills with the real oracle. Printed with `-vv`.
contract GasPathsTest is StackFixture {
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function test_gas_paths() public {
        _lpDeposit(lp, 1_000_000e18);
        _fund(alice, 100_000e18);
        _fund(bob, 100_000e18);

        uint256 g = gasleft();
        bytes32 id = hook.openRound(NVDA, address(chip), day);
        console.log("openRound (default menu, 10 products)", g - gasleft());
        roundId = id;
        _warp(NYTime.openTs(day) + 3600);

        vm.prank(alice);
        g = gasleft();
        uint256 c1 = router.commit{value: FILL_FEE}(roundId, HIGHER, true, 1_000e18, 100_000e18);
        console.log("commit, first of its round", g - gasleft());
        vm.prank(bob);
        g = gasleft();
        uint256 c2 = router.commit{value: FILL_FEE}(roundId, HIGHER, true, 1_000e18, 100_000e18);
        console.log("commit, second in the same second (records prev)", g - gasleft());

        uint64 t = router.getCommit(c1).fillTs;
        _warp(t);
        oracle.set(NVDA, KEEPER, t, S0);
        vm.prank(keeper);
        g = gasleft();
        router.fill(c1, abi.encode(KEEPER));
        console.log("fill, first in its second", g - gasleft());
        vm.prank(keeper);
        g = gasleft();
        router.fill(c2, abi.encode(KEEPER));
        console.log("fill, after the commit before it (one more cold read)", g - gasleft());

        uint64 closeAt = NYTime.closeTs(day);
        _warp(closeAt + 5);
        oracle.set(NVDA, KEEPER, closeAt, S0 * 101 / 100);
        g = gasleft();
        book.recordClose(NVDA, day, abi.encode(KEEPER));
        console.log("recordClose, keeper print, a step", g - gasleft());
        oracle.set(NVDA, TRUSTLESS, closeAt, S0 * 1005 / 1000);
        g = gasleft();
        book.recordClose(NVDA, day, abi.encode(TRUSTLESS));
        console.log("recordClose, trustless replacement, the step redone", g - gasleft());
    }
}
