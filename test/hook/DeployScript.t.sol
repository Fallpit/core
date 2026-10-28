// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";

import {DeployTestnet} from "../../script/DeployTestnet.s.sol";
import {FallpitHook} from "../../src/FallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {MockChip} from "./mocks/MockChips.sol";
import {MockLadderMath} from "./mocks/MockLadderMath.sol";
import {MockPitOracle} from "./mocks/MockPitOracle.sol";
import {MockPitVault} from "./mocks/MockPitVault.sol";
import {MockChipGuard} from "./mocks/MockChipGuard.sol";

/// @notice The deploy script's path: create the hook (through the CREATE2 factory with a fixed salt) and
///         wire the router and the book once.
contract DeployScriptTest is Test {
    bytes32 internal constant NVDA = bytes32("NVDA");
    address internal owner = makeAddr("owner");

    function test_deploy_wiresTheRouterAndTheBook() public {
        PoolManager pm = new PoolManager(address(this));
        MockLadderMath math = new MockLadderMath();
        MockPitOracle oracle = new MockPitOracle();
        MockPitVault vault = new MockPitVault();
        MockChipGuard guard = new MockChipGuard();
        DeployTestnet script = new DeployTestnet();

        DeployTestnet.Deployment memory d = script.deploy(
            address(pm), address(math), address(oracle), address(vault), address(guard), owner, 24 hours
        );

        FallpitHook hook = d.hook;
        assertEq(hook.router(), address(d.router));
        assertEq(address(d.router.hook()), address(hook));
        assertEq(address(d.router.poolManager()), address(pm));
        assertEq(address(hook.book()), address(d.book));
        assertEq(address(hook.vault()), address(vault));
        assertEq(d.book.owner(), owner);
        assertEq(address(d.lens.hook()), address(hook));
        // frozen wiring: the router's deployer renounced in the deploy
        assertEq(d.router.deployer(), address(0));
        vm.prank(address(script));
        vm.expectRevert(IFallpitRouter.OnlyDeployer.selector);
        d.router.setHook(address(hook));

        // the deployed stack opens a round
        vault.setHook(address(hook));
        MockChip chip = new MockChip(18);
        guard.set(address(chip), true, false);
        bytes32 house = vault.createHouse(NVDA, address(chip));
        chip.mint(address(this), 10_000e18);
        chip.approve(address(vault), 10_000e18);
        vault.deposit(house, 10_000e18);
        oracle.setSupported(NVDA, true);
        vm.prank(owner);
        d.book
            .registerTicker(
                NVDA,
                0.0004e18,
                IPitBook.Clock.NYWeekdays,
                IPitBook.Weights(0, 0, 0, 0),
                0,
                IPitBook.FillSource.KeeperOnly
            );
        uint32 monday = uint32(NYTime.daysFromCivil(2026, 10, 5));
        vm.warp(NYTime.closeTs(monday) + 1);
        d.book.recordClose(NVDA, monday, oracle.post(NVDA, 1, 180e18, NYTime.closeTs(monday)));
        bytes32 roundId = hook.openRound(NVDA, address(chip), monday + 1);
        assertEq(hook.getConfig(roundId).capital, 10_000e18);
    }
}
