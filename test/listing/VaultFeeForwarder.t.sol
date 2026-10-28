// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationFixture} from "../integration/IntegrationFixture.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";
import {PitVault} from "../../src/PitVault.sol";
import {IPitVault} from "../../src/interfaces/IPitVault.sol";
import {VaultFeeForwarder, VaultFeeForwarderFactory} from "../../src/listing/VaultFeeForwarder.sol";

/// @notice Launchpad fees into a house: the forwarder donates the chip to the house and sends the rest to
///         its recipient.
contract VaultFeeForwarderTest is IntegrationFixture {
    VaultFeeForwarderFactory internal factory;
    address internal team = makeAddr("team");
    address internal anyone = makeAddr("anyone");

    function setUp() public override {
        super.setUp();
        factory = new VaultFeeForwarderFactory(IPitVault(address(vault)));
    }

    function _endowment() internal view returns (uint256) {
        return vault.getHouse(house).endowment;
    }

    function test_addressIsKnownFirst_feesSentBeforeCreationArePushed() public {
        address at = factory.forwarderOf(house, team);
        assertEq(at.code.length, 0);
        chip.mint(at, 500e18); // a launchpad paid fees before anyone created the forwarder
        vm.prank(anyone);
        address f = factory.create(house, team);
        assertEq(f, at);
        (IPitVault v, bytes32 h, address c, address r) = VaultFeeForwarder(payable(f)).config();
        assertEq(address(v), address(vault));
        assertEq(h, house);
        assertEq(c, address(chip));
        assertEq(r, team);

        uint256 before = _endowment();
        vm.prank(anyone);
        assertEq(VaultFeeForwarder(payable(f)).push(), 500e18);
        assertEq(_endowment() - before, 500e18, "the house's own stake grows");
        assertEq(chip.balanceOf(f), 0);
        vm.prank(anyone);
        assertEq(VaultFeeForwarder(payable(f)).push(), 0, "nothing left");
    }

    function test_push_whileARoundRuns_waitsForTheResult() public {
        address f = factory.create(house, team);
        _open();
        chip.mint(f, 100e18);
        VaultFeeForwarder(payable(f)).push();
        PitVault.House memory h = vault.getHouse(house);
        assertTrue(h.locked);
        assertEq(h.pendingDonations, 100e18);
    }

    function test_forward_otherTokensAndEth_toTheRecipient_notTheChip() public {
        address f = factory.create(house, team);
        MockChip pair = new MockChip(18); // for example the pair token a launchpad pays fees in
        pair.mint(f, 7e18);
        vm.deal(f, 1 ether);
        vm.startPrank(anyone);
        assertEq(VaultFeeForwarder(payable(f)).forward(address(pair)), 7e18);
        assertEq(VaultFeeForwarder(payable(f)).forward(address(0)), 1 ether);
        vm.expectRevert(VaultFeeForwarder.IsTheChip.selector);
        VaultFeeForwarder(payable(f)).forward(address(chip));
        vm.stopPrank();
        assertEq(pair.balanceOf(team), 7e18);
        assertEq(team.balance, 1 ether);
        // ETH sent to it later can be forwarded too
        (bool ok,) = f.call{value: 0.5 ether}("");
        assertTrue(ok);
        VaultFeeForwarder(payable(f)).forward(address(0));
        assertEq(team.balance, 1.5 ether);
    }

    function test_create_onceEach_andChecks() public {
        address f = factory.create(house, team);
        assertEq(factory.create(house, team), f, "a second create returns the same forwarder");
        address g = factory.create(house, carol);
        assertTrue(g != f, "one forwarder per recipient");
        vm.expectRevert(VaultFeeForwarderFactory.ZeroAddress.selector);
        factory.create(house, address(0));
        bytes32 nope = keccak256("no such house");
        vm.expectRevert(VaultFeeForwarderFactory.UnknownHouse.selector);
        factory.create(nope, team);
        vm.expectRevert(VaultFeeForwarderFactory.ZeroAddress.selector);
        new VaultFeeForwarderFactory(IPitVault(address(0)));
        // the list, in pages
        assertEq(factory.forwarderCount(), 2);
        address[] memory page = factory.forwarders(0, 10);
        assertEq(page.length, 2);
        assertEq(page[0], f);
        assertEq(page[1], g);
        assertEq(factory.forwarders(1, 1)[0], g);
        assertEq(factory.forwarders(5, 1).length, 0);
    }
}
