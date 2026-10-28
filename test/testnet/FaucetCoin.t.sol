// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FaucetCoin} from "../../src/testnet/FaucetCoin.sol";
import {ChipGuard} from "../../src/ChipGuard.sol";

contract FaucetCoinTest is Test {
    uint64 internal constant START = 1_791_000_000;

    FaucetCoin internal coin;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(START);
        vm.prank(deployer);
        coin = new FaucetCoin("Pit Rat", "RAT", 5_000_000e18);
    }

    function test_metadata_andInitialSupply() public view {
        assertEq(coin.name(), "Pit Rat");
        assertEq(coin.symbol(), "RAT");
        assertEq(coin.decimals(), 18);
        assertEq(coin.totalSupply(), 5_000_000e18);
        assertEq(coin.balanceOf(deployer), 5_000_000e18, "the initial supply goes to the deployer");
        assertEq(coin.FAUCET_AMOUNT(), 1_000e18);
        assertEq(coin.FAUCET_INTERVAL(), 24 hours);
    }

    function test_faucet_oncePerAddressPer24Hours() public {
        vm.prank(alice);
        coin.faucet();
        assertEq(coin.balanceOf(alice), 1_000e18);
        assertEq(coin.nextFaucetAt(alice), START + 24 hours);

        // not again inside the 24 hours, not even one second early
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FaucetCoin.FaucetNotReady.selector, START + 24 hours));
        coin.faucet();
        vm.warp(START + 24 hours - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FaucetCoin.FaucetNotReady.selector, START + 24 hours));
        coin.faucet();

        // another address has its own clock
        vm.prank(bob);
        coin.faucet();
        assertEq(coin.balanceOf(bob), 1_000e18);

        vm.warp(START + 24 hours);
        vm.prank(alice);
        coin.faucet();
        assertEq(coin.balanceOf(alice), 2_000e18);
        assertEq(coin.totalSupply(), 5_003_000e18);
    }

    function test_faucet_movingTheCoinsAwayDoesNotResetTheClock() public {
        vm.startPrank(alice);
        coin.faucet();
        coin.transfer(bob, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(FaucetCoin.FaucetNotReady.selector, START + 24 hours));
        coin.faucet();
        vm.stopPrank();
    }

    function test_burn_onlyTheCallersOwnBalance() public {
        vm.prank(alice);
        coin.faucet();
        vm.prank(alice);
        coin.burn(400e18);
        assertEq(coin.balanceOf(alice), 600e18);
        assertEq(coin.totalSupply(), 5_000_600e18);
        // more than the caller holds reverts
        vm.prank(alice);
        vm.expectRevert();
        coin.burn(601e18);
        // a holder with nothing burns nothing, and nobody's balance but the caller's can move
        vm.prank(bob);
        vm.expectRevert();
        coin.burn(1);
        assertEq(coin.balanceOf(alice), 600e18);
        assertEq(coin.balanceOf(deployer), 5_000_000e18);
    }

    /// @dev The demo node's Mock USDG had `burn(from, amount)` open to anyone, and a public mint. Neither
    ///      exists here, under any of the usual names: the calls hit no function and revert.
    function test_noBurnFrom_noMint_noOwner() public {
        vm.startPrank(bob);
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeWithSignature("burn(address,uint256)", alice, 1);
        calls[1] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1);
        calls[2] = abi.encodeWithSignature("mint(address,uint256)", bob, 1);
        calls[3] = abi.encodeWithSignature("mint(uint256)", 1);
        calls[4] = abi.encodeWithSignature("owner()");
        calls[5] = abi.encodeWithSignature("transferOwnership(address)", bob);
        calls[6] = abi.encodeWithSignature("faucet(address)", bob);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(coin).call(calls[i]);
            assertFalse(ok, "no such function");
        }
        vm.stopPrank();
        // the deployer has no special power either
        vm.prank(deployer);
        (bool minted,) = address(coin).call(abi.encodeWithSignature("mint(address,uint256)", deployer, 1));
        assertFalse(minted);
        assertEq(coin.totalSupply(), 5_000_000e18);
    }

    function test_noImplicitAllowance_forPermit2() public {
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        assertEq(coin.allowance(deployer, permit2), 0);
        vm.prank(permit2);
        vm.expectRevert();
        coin.transferFrom(deployer, bob, 1);
    }

    function test_chipGuard_approvesItPerCoin() public {
        ChipGuard guard = new ChipGuard(address(this));
        (bool allowed, bool taxed) = guard.check(address(coin));
        assertFalse(allowed, "not trusted until the owner approves this very coin");
        guard.approve(address(coin), true);
        (allowed, taxed) = guard.check(address(coin));
        assertTrue(allowed);
        assertFalse(taxed);
        // a second FaucetCoin is a different address: the approval does not carry over
        FaucetCoin other = new FaucetCoin("Siren", "SIREN", 0);
        (allowed,) = guard.check(address(other));
        assertFalse(allowed);
        assertEq(other.totalSupply(), 0);
    }

    function testFuzz_supplyOnlyMovesByFaucetAndOwnBurn(uint8 calls, uint256 seed) public {
        uint256 expected = 5_000_000e18;
        uint64 time = START;
        for (uint256 i; i < calls % 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            address who = address(uint160(0xF00 + seed % 4));
            time += uint64((seed >> 8) % 20 hours);
            vm.warp(time);
            if ((seed >> 40) % 3 == 0) {
                uint256 amount = (seed >> 48) % (coin.balanceOf(who) + 1);
                vm.prank(who);
                coin.burn(amount);
                expected -= amount;
            } else {
                bool ready = time >= coin.nextFaucetAt(who);
                vm.prank(who);
                if (!ready) vm.expectRevert();
                coin.faucet();
                if (ready) expected += 1_000e18;
            }
            assertEq(coin.totalSupply(), expected);
        }
    }
}
