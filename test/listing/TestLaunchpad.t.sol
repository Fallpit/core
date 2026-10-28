// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ChipGuard} from "../../src/ChipGuard.sol";
import {AnchorRegistry} from "../../src/listing/AnchorRegistry.sol";
import {LaunchRecordSource} from "../../src/listing/LaunchRecordSource.sol";
import {FaucetCoin} from "../../src/testnet/FaucetCoin.sol";
import {TestLaunchpad} from "../../src/testnet/TestLaunchpad.sol";

/// @notice The testnet launchpad as `DeployTestnet.setUpListing` wires it: read in the Pons v2 shape by a
///         `LaunchRecordSource` and trusted by ChipGuard.
contract TestLaunchpadTest is Test {
    TestLaunchpad internal pad;
    AnchorRegistry internal registry;
    ChipGuard internal guard;
    LaunchRecordSource internal source;
    address internal constant NVDA_TOKEN = address(0x5150);
    address internal alice = makeAddr("alice");

    function setUp() public {
        pad = new TestLaunchpad();
        registry = new AnchorRegistry(address(this));
        guard = new ChipGuard(address(this));
        source = new LaunchRecordSource(
            address(pad), TestLaunchpad.getLaunchedToken.selector, 0, LaunchRecordSource.KnownBy.Self, 4
        );
        registry.addSource(source);
        guard.setTrustedRegistry(
            address(pad), TestLaunchpad.getLaunchedToken.selector, ChipGuard.RegistryMatch.ReturnsChip
        );
        registry.nameTicker(NVDA_TOKEN, "NVDA");
        registry.nameTicker(address(0), "ETH");
    }

    function test_launch_sendsTheSupplyAndRecordsTheAnchor() public {
        vm.prank(alice);
        address coin = pad.launch("Test Coin", "TEST", 1e27, NVDA_TOKEN);
        assertEq(FaucetCoin(coin).balanceOf(alice), 1e27);
        assertEq(FaucetCoin(coin).balanceOf(address(pad)), 0);
        (address token, address creator,, uint256 supply, address anchor) = pad.getLaunchedToken(coin);
        assertEq(token, coin);
        assertEq(creator, alice);
        assertEq(supply, 1e27);
        assertEq(anchor, NVDA_TOKEN);
        assertEq(pad.tokenCount(), 1);
    }

    function test_registry_resolvesALaunchedCoin_andTheGuardTrustsIt() public {
        address nvdaCoin = pad.launch("N", "N", 1e24, NVDA_TOKEN);
        address ethCoin = pad.launch("E", "E", 1e24, address(0));
        (bytes32 t1, address a1, address s1) = registry.resolve(nvdaCoin);
        assertEq(t1, bytes32("NVDA"));
        assertEq(a1, NVDA_TOKEN);
        assertEq(s1, address(source));
        (bytes32 t2, address a2,) = registry.resolve(ethCoin);
        assertEq(t2, bytes32("ETH"));
        assertEq(a2, address(0));
        (bool allowed, bool taxed) = guard.check(nvdaCoin);
        assertTrue(allowed);
        assertFalse(taxed);
    }

    function test_aCoinItDidNotLaunch_isUnknown() public {
        FaucetCoin other = new FaucetCoin("O", "O", 1e24);
        (AnchorRegistry.Status status,,,) = registry.inspect(address(other));
        assertEq(uint8(status), uint8(AnchorRegistry.Status.UnknownLaunch));
        (bool allowed,) = guard.check(address(other));
        assertFalse(allowed);
    }

    function test_launch_zeroSupplyReverts() public {
        vm.expectRevert(TestLaunchpad.ZeroSupply.selector);
        pad.launch("Z", "Z", 0, NVDA_TOKEN);
    }
}
