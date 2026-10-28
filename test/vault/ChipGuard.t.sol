// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {ChipGuard} from "../../src/ChipGuard.sol";
import {MockChip, MockDecimalsChip, MockDopplerCoin, HostileChip} from "./mocks/MockChip.sol";
import {MockLaunchRegistry} from "./mocks/MockFeesManager.sol";

contract ChipGuardTest is Test {
    address internal owner = makeAddr("owner");
    ChipGuard internal guard;
    MockDopplerCoin internal dopplerImpl;
    MockChip internal plain;

    function setUp() public {
        guard = new ChipGuard(owner);
        dopplerImpl = new MockDopplerCoin();
        plain = new MockChip("Plain", "PLN", 18);
    }

    function _allowed(address chip) internal view returns (bool allowed) {
        (allowed,) = guard.check(chip);
    }

    // ---------------------------------------------------------------------------------------------
    // Route 1: trusted code hash (Doppler clones)
    // ---------------------------------------------------------------------------------------------

    function test_codeHash_everyCloneOfOneImplementationSharesOneHash() public {
        // Doppler deploys each coin with solady's LibClone: the same 44-byte minimal proxy as on chain.
        address a = LibClone.clone(address(dopplerImpl));
        address b = LibClone.cloneDeterministic(address(dopplerImpl), keccak256("b"));
        assertEq(a.code.length, 44);
        assertEq(a.codehash, b.codehash);
        assertEq(
            a.code,
            abi.encodePacked(
                hex"3d3d3d3d363d3d37363d73", address(dopplerImpl), hex"5af43d3d93803e602a57fd5bf3"
            )
        );
        assertFalse(_allowed(a));

        vm.prank(owner);
        guard.setTrustedCodeHash(a.codehash, true);
        assertTrue(_allowed(a));
        assertTrue(_allowed(b));

        // A clone of another implementation has another hash.
        address other = LibClone.clone(address(new MockDopplerCoin()));
        assertTrue(other.codehash != a.codehash);
        assertFalse(_allowed(other));

        vm.prank(owner);
        guard.setTrustedCodeHash(a.codehash, false);
        assertFalse(_allowed(a));
    }

    function test_balanceLimitActive_blocksTheCoinUntilItEnds() public {
        address coin = LibClone.clone(address(dopplerImpl));
        vm.prank(owner);
        guard.setTrustedCodeHash(coin.codehash, true);
        assertTrue(_allowed(coin));

        MockDopplerCoin(coin).setBalanceLimitActive(true);
        assertFalse(_allowed(coin), "a coin with an active balance limit is not allowed");
        // Not even when the owner approved it by address.
        vm.prank(owner);
        guard.approve(coin, true);
        assertFalse(_allowed(coin));

        MockDopplerCoin(coin).setBalanceLimitActive(false);
        assertTrue(_allowed(coin));
    }

    // ---------------------------------------------------------------------------------------------
    // Route 2: trusted launch registry (Pons v2 coins)
    // ---------------------------------------------------------------------------------------------

    function test_registry_returnsChip_likeThePonsFactory() public {
        MockLaunchRegistry registry = new MockLaunchRegistry();
        registry.setLaunched(address(plain), true);
        MockChip unknown = new MockChip("Unknown", "UNK", 18);
        assertFalse(_allowed(address(plain)));

        vm.prank(owner);
        guard.setTrustedRegistry(
            address(registry),
            MockLaunchRegistry.getLaunchedToken.selector,
            ChipGuard.RegistryMatch.ReturnsChip
        );
        assertTrue(_allowed(address(plain)));
        assertTrue(guard.launchedByTrustedRegistry(address(plain)));
        assertFalse(_allowed(address(unknown)), "the registry returns zero for coins it did not launch");

        registry.setLaunched(address(plain), false);
        assertFalse(_allowed(address(plain)));
    }

    function test_registry_returnsTrue_flavour() public {
        MockLaunchRegistry registry = new MockLaunchRegistry();
        registry.setLaunched(address(plain), true);
        vm.prank(owner);
        guard.setTrustedRegistry(
            address(registry), registry.isLaunched.selector, ChipGuard.RegistryMatch.ReturnsTrue
        );
        assertTrue(_allowed(address(plain)));
        assertFalse(_allowed(address(new MockChip("Unknown", "UNK", 18))));
    }

    function test_registry_updateRemoveAndCap() public {
        MockLaunchRegistry registry = new MockLaunchRegistry();
        registry.setLaunched(address(plain), true);
        vm.startPrank(owner);
        // Wrong match kind for this selector: the bool getter never returns the coin address.
        guard.setTrustedRegistry(
            address(registry), registry.isLaunched.selector, ChipGuard.RegistryMatch.ReturnsChip
        );
        assertFalse(_allowed(address(plain)));
        // Update in place.
        guard.setTrustedRegistry(
            address(registry), registry.isLaunched.selector, ChipGuard.RegistryMatch.ReturnsTrue
        );
        assertEq(guard.registries().length, 1);
        assertTrue(_allowed(address(plain)));
        // Remove.
        guard.setTrustedRegistry(address(registry), bytes4(0), ChipGuard.RegistryMatch.None);
        assertEq(guard.registries().length, 0);
        assertFalse(_allowed(address(plain)));
        // Removing an unknown registry is a no-op.
        guard.setTrustedRegistry(address(registry), bytes4(0), ChipGuard.RegistryMatch.None);

        // An account with no code and a registry that reverts are just "no".
        guard.setTrustedRegistry(makeAddr("eoa"), bytes4(0x12345678), ChipGuard.RegistryMatch.ReturnsTrue);
        guard.setTrustedRegistry(address(plain), bytes4(0x12345678), ChipGuard.RegistryMatch.ReturnsTrue);
        assertFalse(_allowed(address(plain)));

        for (uint256 i = 2; i < guard.MAX_REGISTRIES(); ++i) {
            guard.setTrustedRegistry(
                address(uint160(1000 + i)), bytes4(0), ChipGuard.RegistryMatch.ReturnsTrue
            );
        }
        vm.expectRevert(ChipGuard.TooManyRegistries.selector);
        guard.setTrustedRegistry(address(9999), bytes4(0), ChipGuard.RegistryMatch.ReturnsTrue);
        vm.expectRevert(ChipGuard.ZeroAddress.selector);
        guard.setTrustedRegistry(address(0), bytes4(0), ChipGuard.RegistryMatch.ReturnsTrue);
        vm.stopPrank();

        // A full list of dead registries does not break `check`.
        assertFalse(_allowed(address(plain)));
    }

    // ---------------------------------------------------------------------------------------------
    // Route 3: owner approval, and refusal
    // ---------------------------------------------------------------------------------------------

    function test_approve_and_refuse() public {
        assertFalse(_allowed(address(plain)));
        vm.prank(owner);
        guard.approve(address(plain), true);
        assertTrue(_allowed(address(plain)));

        // A refusal beats every route.
        vm.startPrank(owner);
        guard.refuse(address(plain), true);
        assertFalse(_allowed(address(plain)));
        guard.setTrustedCodeHash(address(plain).codehash, true);
        assertFalse(_allowed(address(plain)));
        guard.refuse(address(plain), false);
        assertTrue(_allowed(address(plain)));
        guard.approve(address(plain), false);
        assertTrue(_allowed(address(plain)), "still trusted by code hash");
        guard.setTrustedCodeHash(address(plain).codehash, false);
        assertFalse(_allowed(address(plain)));
        vm.stopPrank();
    }

    function test_decimals_mustBeAtMost18() public {
        MockDecimalsChip ok = new MockDecimalsChip(6);
        MockDecimalsChip edge = new MockDecimalsChip(18);
        MockDecimalsChip tooMany = new MockDecimalsChip(19);
        MockDecimalsChip absurd = new MockDecimalsChip(type(uint256).max);
        vm.startPrank(owner);
        guard.approve(address(ok), true);
        guard.approve(address(edge), true);
        guard.approve(address(tooMany), true);
        guard.approve(address(absurd), true);
        // Approved accounts that are not tokens at all.
        guard.approve(address(guard), true);
        guard.approve(makeAddr("eoa"), true);
        guard.approve(address(0), true);
        vm.stopPrank();
        assertTrue(_allowed(address(ok)));
        assertTrue(_allowed(address(edge)));
        assertFalse(_allowed(address(tooMany)));
        assertFalse(_allowed(address(absurd)));
        assertFalse(_allowed(address(guard)), "no decimals()");
        assertFalse(_allowed(makeAddr("eoa")), "no code");
        assertFalse(_allowed(address(0)));
    }

    /// @dev The flag is reported whatever the verdict, and a flagged coin is never allowed: not when the
    ///      owner approved it, not when its template or a registry is trusted.
    function test_feeOnTransferFlag_isReported_andBlocksEveryRoute() public {
        (bool allowed, bool fot) = guard.check(address(plain));
        assertFalse(allowed);
        assertFalse(fot);
        vm.prank(owner);
        guard.setFeeOnTransfer(address(plain), true);
        (allowed, fot) = guard.check(address(plain));
        assertFalse(allowed);
        assertTrue(fot);
        vm.startPrank(owner);
        guard.approve(address(plain), true);
        (allowed, fot) = guard.check(address(plain));
        assertFalse(allowed, "approved by address, still a tax coin");
        assertTrue(fot);
        guard.setTrustedCodeHash(address(plain).codehash, true);
        (allowed, fot) = guard.check(address(plain));
        assertFalse(allowed, "trusted template, still a tax coin");
        assertTrue(fot);

        // the flag can be taken back
        guard.setFeeOnTransfer(address(plain), false);
        vm.stopPrank();
        (allowed, fot) = guard.check(address(plain));
        assertTrue(allowed);
        assertFalse(fot);
    }

    // ---------------------------------------------------------------------------------------------
    // Robustness and access
    // ---------------------------------------------------------------------------------------------

    function test_hostileChip_cannotBreakCheck() public {
        // Answers the balance limit probe with a 100 kB blob of zeros: read as "no limit", one word copied.
        HostileChip hostile = new HostileChip();
        assertFalse(_allowed(address(hostile)));
        vm.prank(owner);
        guard.approve(address(hostile), true);
        uint256 gasBefore = gasleft();
        assertTrue(_allowed(address(hostile)));
        assertLt(gasBefore - gasleft(), 500_000);
    }

    function test_check_revertsInsteadOfMisreadingWhenGasIsShort() public {
        address coin = LibClone.clone(address(dopplerImpl));
        MockDopplerCoin(coin).setBalanceLimitActive(true);
        vm.prank(owner);
        guard.setTrustedCodeHash(coin.codehash, true);
        // With too little gas the limit probe could fail and read as "no limit". The guard reverts instead.
        for (uint256 gas = 20_000; gas < 450_000; gas += 10_000) {
            (bool ok, bytes memory ret) =
                address(guard).staticcall{gas: gas}(abi.encodeCall(guard.check, (coin)));
            if (ok) {
                (bool allowed,) = abi.decode(ret, (bool, bool));
                assertFalse(allowed, "never allowed while the limit is active");
            }
        }
        (bool ok2, bytes memory ret2) =
            address(guard).staticcall{gas: 100_000}(abi.encodeCall(guard.check, (coin)));
        assertFalse(ok2);
        assertEq(bytes4(ret2), ChipGuard.InsufficientGas.selector);
    }

    function test_onlyOwner() public {
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        guard.setTrustedCodeHash(bytes32(uint256(1)), true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        guard.setTrustedRegistry(address(1), bytes4(0), ChipGuard.RegistryMatch.ReturnsTrue);
        vm.expectRevert(Ownable.Unauthorized.selector);
        guard.approve(address(plain), true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        guard.refuse(address(plain), true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        guard.setFeeOnTransfer(address(plain), true);
        vm.stopPrank();
        assertEq(guard.owner(), owner);
        vm.expectRevert(ChipGuard.ZeroAddress.selector);
        new ChipGuard(address(0));
    }
}
