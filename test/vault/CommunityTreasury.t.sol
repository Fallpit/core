// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";

import {CommunityTreasury, PitFeeInbox} from "../../src/CommunityTreasury.sol";
import {PitVault} from "../../src/PitVault.sol";
import {VaultBase} from "./VaultBase.sol";
import {MockChip} from "./mocks/MockChip.sol";
import {MockFeesManager, HostileFeesManager} from "./mocks/MockFeesManager.sol";

contract CommunityTreasuryTest is VaultBase {
    bytes32 internal constant POOL = keccak256("AI/NVDA pool");
    bytes32 internal constant TAX_POOL = keccak256("TAX/NVDA pool");

    address internal treasuryOwner = makeAddr("treasuryOwner");
    address internal creator = makeAddr("creator"); // holds 95% of the pool's fees
    address internal protocol = makeAddr("protocol"); // holds 5%
    address internal trader = makeAddr("trader");

    CommunityTreasury internal treasury;
    MockFeesManager internal fees;
    MockChip internal stock;
    address internal inbox;

    function setUp() public override {
        super.setUp();
        treasury = new CommunityTreasury(address(vault), treasuryOwner);
        fees = new MockFeesManager(false); // as deployed on Robinhood Chain
        stock = new MockChip("NVDA stock token", "NVDA", 18);
        inbox = treasury.inboxOf(house);

        address[] memory who = new address[](2);
        uint96[] memory shares = new uint96[](2);
        (who[0], who[1]) = (creator, protocol);
        (shares[0], shares[1]) = (0.95e18, 0.05e18);
        fees.initPool(POOL, address(chip), address(stock), who, shares);
        fees.initPool(TAX_POOL, address(stock), address(taxChip), who, shares);

        chip.mint(trader, 1_000_000e18);
        taxChip.mint(trader, 1_000_000e18);
        stock.mint(trader, 1_000_000e18);
        vm.startPrank(trader);
        chip.approve(address(fees), type(uint256).max);
        taxChip.approve(address(fees), type(uint256).max);
        stock.approve(address(fees), type(uint256).max);
        vm.stopPrank();
    }

    function _accrue(bytes32 pool, uint128 fees0, uint128 fees1) internal {
        vm.prank(trader);
        fees.accrue(pool, fees0, fees1);
    }

    // ---------------------------------------------------------------------------------------------
    // Inbox
    // ---------------------------------------------------------------------------------------------

    function test_inboxOf_isTheSameBeforeAndAfterDeployment_andOnePerHouse() public {
        assertEq(inbox.code.length, 0);
        assertEq(treasury.createInbox(house), inbox);
        assertGt(inbox.code.length, 0);
        assertEq(treasury.inboxOf(house), inbox);
        assertEq(PitFeeInbox(payable(inbox)).treasury(), address(treasury));
        assertTrue(treasury.inboxOf(taxHouse) != inbox);
        // Idempotent.
        assertEq(treasury.createInbox(house), inbox);

        vm.expectRevert(CommunityTreasury.UnknownHouse.selector);
        treasury.createInbox(keccak256("nope"));
    }

    function test_inbox_onlyObeysItsTreasury() public {
        treasury.createInbox(house);
        PitFeeInbox box = PitFeeInbox(payable(inbox));
        vm.startPrank(treasuryOwner);
        vm.expectRevert(PitFeeInbox.OnlyTreasury.selector);
        box.collect(address(fees), POOL);
        vm.expectRevert(PitFeeInbox.OnlyTreasury.selector);
        box.donate(address(vault), house, address(chip));
        vm.expectRevert(PitFeeInbox.OnlyTreasury.selector);
        box.release(address(chip), treasuryOwner, 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // Harvest
    // ---------------------------------------------------------------------------------------------

    function test_harvest_afterUpdateBeneficiary_donatesChipLeg_holdsStockLeg() public {
        _accrue(POOL, 10e18, 1e18); // fees before the community moves its share
        // The creator points its 95% at the house's inbox. Doppler pays it what it earned so far.
        vm.prank(creator);
        fees.updateBeneficiary(POOL, inbox);
        assertEq(fees.getShares(POOL, inbox), 0.95e18);
        assertEq(fees.getShares(POOL, creator), 0);

        _accrue(POOL, 100e18, 2e18);
        // Anyone can harvest.
        vm.prank(dave);
        (uint256 donated, uint256 held) = treasury.harvest(address(fees), POOL, house);

        // The first 10 were collected after the update too (nobody had collected them), so the inbox
        // gets 95% of everything the pool earned and not yet collected.
        assertEq(donated, 110e18 * 95 / 100);
        assertEq(held, 3e18 * 95 / 100);
        assertEq(_h(house).endowment, donated, "chip leg is in the house's endowment");
        assertEq(vault.totalSupply(uint256(house)), 0, "no shares minted");
        assertEq(stock.balanceOf(inbox), held, "stock leg waits in the inbox");
        assertEq(chip.balanceOf(inbox), 0);
        assertEq(chip.balanceOf(address(treasury)), 0);
        assertEq(stock.balanceOf(address(treasury)), 0);
        assertEq(chip.balanceOf(dave), 1_000_000e18, "the caller gets nothing");
        _assertBooks(chip, house);

        // Nothing new: harvest is a no-op, not a revert.
        (donated, held) = treasury.harvest(address(fees), POOL, house);
        assertEq(donated, 0);
        assertEq(held, 0);
    }

    function test_harvest_worksWithBothDopplerVersions() public {
        // Repo HEAD rejects `updateBeneficiary` from a caller without shares; the deployed version lets it
        // pass as a no-op. Neither changes the path the treasury uses.
        MockFeesManager head = new MockFeesManager(true);
        address[] memory who = new address[](1);
        uint96[] memory shares = new uint96[](1);
        (who[0], shares[0]) = (creator, 1e18);
        head.initPool(POOL, address(chip), address(stock), who, shares);
        vm.prank(trader);
        chip.approve(address(head), type(uint256).max);

        vm.prank(dave);
        vm.expectRevert(MockFeesManager.CallerNotBeneficiary.selector);
        head.updateBeneficiary(POOL, inbox);
        vm.prank(dave);
        fees.updateBeneficiary(POOL, inbox); // deployed version: no revert, nothing moves
        assertEq(fees.getShares(POOL, inbox), 0);

        vm.prank(creator);
        head.updateBeneficiary(POOL, inbox);
        vm.prank(trader);
        head.accrue(POOL, 40e18, 0);
        (uint256 donated,) = treasury.harvest(address(head), POOL, house);
        assertEq(donated, 40e18);
    }

    function test_harvest_inboxListedAtLaunch() public {
        address[] memory who = new address[](2);
        uint96[] memory shares = new uint96[](2);
        (who[0], who[1]) = (inbox, protocol);
        (shares[0], shares[1]) = (0.95e18, 0.05e18);
        bytes32 pool = keccak256("launched with the inbox");
        fees.initPool(pool, address(stock), address(chip), who, shares);
        _accrue(pool, 4e18, 200e18);
        (uint256 donated, uint256 held) = treasury.harvest(address(fees), pool, house);
        assertEq(donated, 190e18);
        assertEq(held, 3.8e18);
        assertEq(_h(house).endowment, 190e18);
    }

    function test_harvest_whenInboxIsNotABeneficiary_movesNothing() public {
        _accrue(POOL, 100e18, 2e18);
        (uint256 donated, uint256 held) = treasury.harvest(address(fees), POOL, house);
        assertEq(donated, 0);
        assertEq(held, 0);
        assertEq(_h(house).endowment, 0);
        // The fees are still there for the real beneficiaries.
        vm.prank(creator);
        fees.collectFees(POOL);
        assertEq(chip.balanceOf(creator), 95e18);
    }

    function test_harvest_feesRoutedToOneHouseCannotBeSentToAnother() public {
        bytes32 tsla = vault.createHouse(TSLA, address(chip));
        vm.prank(creator);
        fees.updateBeneficiary(POOL, inbox); // the community chose the NVDA house
        _accrue(POOL, 100e18, 0);
        // A caller who prefers the TSLA house gets nothing moved there.
        (uint256 donated,) = treasury.harvest(address(fees), POOL, tsla);
        assertEq(donated, 0);
        assertEq(_h(tsla).endowment, 0);
        (donated,) = treasury.harvest(address(fees), POOL, house);
        assertEq(donated, 95e18);
        assertEq(_h(house).endowment, 95e18);
    }

    function test_harvest_whileTheHouseIsLocked_joinsAfterTheRound() public {
        _deposit(alice, house, 100e18);
        vm.prank(creator);
        fees.updateBeneficiary(POOL, inbox);
        hook.pull(house);
        _accrue(POOL, 100e18, 0);
        (uint256 donated,) = treasury.harvest(address(fees), POOL, house);
        assertEq(donated, 95e18);
        assertEq(_h(house).endowment, 0);
        assertEq(_h(house).pendingDonations, 95e18);
        _finish(house, chip, 90e18);
        assertEq(_h(house).endowment, 95e18, "fees harvested mid-round take no part in its loss");
        assertEq(_h(house).lpAssets, 90e18);
    }

    /// @dev A taxed chip is not a chip: the vault refuses the donation, so the harvest and the sweep
    ///      revert and move nothing. Once the chip stops taxing, the same harvest goes through.
    function test_harvest_feeOnTransferChip_isRefused() public {
        address taxInbox = treasury.inboxOf(taxHouse);
        vm.prank(creator);
        fees.updateBeneficiary(TAX_POOL, taxInbox);
        _accrue(TAX_POOL, 2e18, 100e18); // the manager books 100 and holds 99 after the tax

        // 95 leave the manager, 94.05 reach the inbox, and the vault would receive 93.1095 of them
        uint256 inInbox = uint256(95e18) * 99 / 100;
        vm.expectRevert(
            abi.encodeWithSelector(PitVault.InexactTransfer.selector, inInbox, inInbox * 99 / 100)
        );
        treasury.harvest(address(fees), TAX_POOL, taxHouse);
        assertEq(taxChip.balanceOf(taxInbox), 0, "the harvest was undone: the fees are still in the manager");
        assertEq(_h(taxHouse).endowment, 0);

        // chips that reached the inbox any other way cannot be swept in either
        taxChip.mint(taxInbox, 10e18);
        vm.expectRevert(abi.encodeWithSelector(PitVault.InexactTransfer.selector, 10e18, 9.9e18));
        treasury.sweep(taxHouse);
        assertEq(taxChip.balanceOf(taxInbox), 10e18);
        assertEq(vault.accounted(address(taxChip)), 0);

        // without the tax the same calls donate everything
        taxChip.setTax(false);
        (uint256 donated, uint256 held) = treasury.harvest(address(fees), TAX_POOL, taxHouse);
        assertEq(donated, 95e18 + 10e18);
        assertEq(held, 1.9e18);
        assertEq(_h(taxHouse).endowment, donated);
        assertEq(taxChip.balanceOf(taxInbox), 0);
        _assertBooks(taxChip, taxHouse);
    }

    function test_harvest_reverts_forUnknownHouse_orPoolWithoutTheChip() public {
        vm.expectRevert(CommunityTreasury.UnknownHouse.selector);
        treasury.harvest(address(fees), POOL, keccak256("nope"));
        // TAX_POOL pairs the stock with the tax chip; `house` plays in the plain chip.
        vm.expectRevert(CommunityTreasury.ChipNotInPool.selector);
        treasury.harvest(address(fees), TAX_POOL, house);
    }

    // ---------------------------------------------------------------------------------------------
    // Chips that reach the inbox outside a harvest
    // ---------------------------------------------------------------------------------------------

    function test_sweep_donatesChipsReleasedDuringUpdateBeneficiary_andPlainTransfers() public {
        // The inbox already holds 5% (it took over the protocol's share); fees accrue and are collected
        // by someone else; then the creator merges its 95% in. Doppler releases the inbox's pending 5%
        // during that call, outside any harvest.
        vm.prank(protocol);
        fees.updateBeneficiary(POOL, inbox);
        _accrue(POOL, 100e18, 2e18);
        vm.prank(creator);
        fees.collectFees(POOL);
        vm.prank(creator);
        fees.updateBeneficiary(POOL, inbox);
        assertEq(chip.balanceOf(inbox), 5e18);
        assertEq(stock.balanceOf(inbox), 0.1e18);

        // A fee hook pushing chips straight to the inbox looks the same.
        vm.prank(trader);
        chip.transfer(inbox, 7e18);

        vm.prank(dave);
        uint256 donated = treasury.sweep(house);
        assertEq(donated, 12e18);
        assertEq(_h(house).endowment, 12e18);
        assertEq(chip.balanceOf(inbox), 0);
        assertEq(stock.balanceOf(inbox), 0.1e18, "sweep leaves the other leg alone");
        assertEq(treasury.sweep(house), 0);
        vm.expectRevert(CommunityTreasury.UnknownHouse.selector);
        treasury.sweep(keccak256("nope"));
    }

    // ---------------------------------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------------------------------

    function test_owner_cannotMoveTheChipLeg() public {
        vm.prank(trader);
        chip.transfer(inbox, 50e18);
        vm.prank(treasuryOwner);
        vm.expectRevert(CommunityTreasury.ChipLegLocked.selector);
        treasury.releaseOtherLeg(house, address(chip), treasuryOwner, 50e18);
        // The only way out for those chips is into the house.
        assertEq(treasury.sweep(house), 50e18);
        assertEq(_h(house).endowment, 50e18);
    }

    function test_owner_canReleaseTheOtherLeg_nobodyElseCan() public {
        vm.prank(creator);
        fees.updateBeneficiary(POOL, inbox);
        _accrue(POOL, 100e18, 2e18);
        treasury.harvest(address(fees), POOL, house);
        assertEq(stock.balanceOf(inbox), 1.9e18);

        vm.prank(dave);
        vm.expectRevert(Ownable.Unauthorized.selector);
        treasury.releaseOtherLeg(house, address(stock), dave, 1.9e18);

        vm.startPrank(treasuryOwner);
        vm.expectRevert(CommunityTreasury.ZeroAddress.selector);
        treasury.releaseOtherLeg(house, address(stock), address(0), 1);
        vm.expectRevert(CommunityTreasury.UnknownHouse.selector);
        treasury.releaseOtherLeg(keccak256("nope"), address(stock), treasuryOwner, 1);
        treasury.releaseOtherLeg(house, address(stock), treasuryOwner, 1.9e18);
        vm.stopPrank();
        assertEq(stock.balanceOf(treasuryOwner), 1.9e18);
        assertEq(_h(house).endowment, 95e18, "the chip leg is untouched");
    }

    function test_nativeLeg_isAcceptedAndReleasable() public {
        treasury.createInbox(house);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        (bool ok,) = inbox.call{value: 1 ether}("");
        assertTrue(ok);
        address to = makeAddr("to");
        vm.prank(treasuryOwner);
        treasury.releaseOtherLeg(house, address(0), to, 1 ether);
        assertEq(to.balance, 1 ether);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(CommunityTreasury.ZeroAddress.selector);
        new CommunityTreasury(address(0), treasuryOwner);
        vm.expectRevert(CommunityTreasury.ZeroAddress.selector);
        new CommunityTreasury(address(vault), address(0));
    }

    // ---------------------------------------------------------------------------------------------
    // Hostile fees manager
    // ---------------------------------------------------------------------------------------------

    function test_hostileFeesManager_canOnlyHelpTheHouse() public {
        HostileFeesManager hostile = new HostileFeesManager();
        hostile.setKey(address(chip), address(stock));
        // The inbox holds a stock leg and some chips.
        vm.startPrank(trader);
        stock.transfer(inbox, 3e18);
        chip.transfer(inbox, 5e18);
        vm.stopPrank();

        // Reentering the treasury from inside collectFees is shut.
        bytes[3] memory payloads = [
            abi.encodeCall(CommunityTreasury.sweep, (house)),
            abi.encodeCall(CommunityTreasury.harvest, (address(fees), POOL, house)),
            abi.encodeCall(CommunityTreasury.createInbox, (house))
        ];
        for (uint256 i; i < payloads.length; ++i) {
            hostile.arm(address(treasury), payloads[i]);
            vm.expectRevert(bytes4(keccak256("Reentrancy()")));
            treasury.harvest(address(hostile), POOL, house);
        }

        // It cannot drive the inbox itself either.
        hostile.arm(inbox, abi.encodeCall(PitFeeInbox.release, (address(stock), address(hostile), 3e18)));
        vm.expectRevert(PitFeeInbox.OnlyTreasury.selector);
        treasury.harvest(address(hostile), POOL, house);

        // Unarmed, a fake manager changes nothing: the chips in the inbox go to the house, the stock stays.
        hostile.arm(address(0), "");
        (uint256 donated, uint256 held) = treasury.harvest(address(hostile), POOL, house);
        assertEq(donated, 5e18);
        assertEq(held, 0);
        assertEq(_h(house).endowment, 5e18);
        assertEq(stock.balanceOf(inbox), 3e18);

        // A manager that lies about the pool key cannot make the stock leg count as the chip.
        hostile.setKey(address(stock), address(stock));
        vm.expectRevert(CommunityTreasury.ChipNotInPool.selector);
        treasury.harvest(address(hostile), POOL, house);
    }
}
