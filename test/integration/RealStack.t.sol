// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {console} from "forge-std/Test.sol";
import {StackFixture} from "./StackFixture.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {MockChip, MockFeeChip} from "../hook/mocks/MockChips.sol";
import {PitVault} from "../../src/PitVault.sol";

/// @notice Whole rounds on the real stack (FallpitHook, FallpitRouter, PitBook, LadderMath, PitVault): random
///         fills, chip precisions, fee-on-transfer chips, extreme moves and cheap tokens at the prior's
///         floor.
contract RealStackTest is StackFixture {
    address internal lp = makeAddr("lp");
    address internal eve = makeAddr("eve");

    uint256 internal constant CAPITAL = 1_000_000e18;
    uint256 internal constant EVE_CHIPS = 100_000_000e18;

    /// @dev Up to 40 random fills per run (any product of the default menu, any size up to the per-fill
    ///      cap, buys and sells; a buy that would take a floor over its product cap is refunded) while the
    ///      stock random-walks with jumps up to 12 standard deviations and the session runs down to the
    ///      cutoff. Checks: no fill ever reverts (the helpers do not catch), a fill stays under 6M gas,
    ///      the round is solvent after every fill, every chip is accounted for at the end, the hook's
    ///      claims equal what it owes to the unit, and the house unlocks.
    /// forge-config: default.fuzz.runs = 100
    function testFuzz_neverBricks_staysSolvent_conserves(uint256 seed) public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, EVE_CHIPS);
        roundId = hook.openRound(NVDA, address(chip), day);
        _warp(NYTime.openTs(day) + 1 + uint64(seed % 20_000));
        uint64 cutoff = NYTime.closeTs(day) - 630;
        int256 k;
        uint256 maxGas;
        for (uint256 i; i < 40; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            if (clock + 5 > cutoff) break;
            uint8 idx = uint8(seed % PRODUCTS);
            int256 step = int256((seed >> 8) % 2e18) - 1e18;
            if ((seed >> 40) % 10 == 0) step *= 6;
            k += step;
            if (k > 12e18) k = 12e18;
            if (k < -12e18) k = -12e18;
            uint256 px = _priceAtSigmas(k);
            uint256 size = 1 + (seed >> 64) % 20_000e18;
            if ((seed >> 60) % 4 == 0) size = 20_000e18;
            uint256 bal = _token(idx).balanceOf(eve);
            bool sell = bal != 0 && (seed >> 50) % 2 == 0;
            if (sell && size > bal) size = bal;
            // a size under the round's minimum trade cannot be committed at all (BelowMinimumTrade): a dust
            // remainder stays in the wallet until the close, where it redeems if it wins
            (,,,,, uint256 minShares,,) = hook.commitContext(roundId, idx);
            bool dust = size < minShares;
            uint256 g0 = gasleft();
            if (dust) {} else if (sell) {
                _trySell(eve, idx, size, px);
            } else {
                _tryBuy(eve, idx, size, px);
            }
            uint256 used = g0 - gasleft();
            if (used > maxGas) maxGas = used;
            (uint256 worst, uint256 covered) = lens.solvency(roundId);
            assertLe(worst, covered, "solvent after every fill");
            _warp(clock + uint64((seed >> 100) % 900));
        }
        assertLt(maxGas, 6_000_000, "commit plus fill stays far below a block");

        if (clock < NYTime.closeTs(day)) _warp(NYTime.closeTs(day));
        _closeAndFinalize(_priceAtSigmas(k));
        IFallpitHook.RoundState memory st = _state();
        for (uint8 idx; idx < PRODUCTS; ++idx) {
            uint256 bal = _token(idx).balanceOf(eve);
            if (bal != 0 && (st.winners >> idx) & 1 == 1) {
                uint256 token = _token(idx).id;
                vm.prank(eve);
                router.redeem(token, bal);
            }
        }
        hook.collectProtocolFees(address(chip));

        assertEq(_state().held, 0, "nothing left in the round");
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, 0, "no claim left");
        assertEq(owed, 0, "nothing owed");
        assertEq(chip.balanceOf(address(hook)), 0, "the hook holds no chip of the round");
        assertEq(chip.balanceOf(address(router)), 0, "the router holds no escrow");
        assertFalse(vault.isLocked(house), "the house is unlocked");
        assertEq(
            chip.balanceOf(eve) + chip.balanceOf(address(vault)) + chip.balanceOf(feeRecipient),
            CAPITAL + EVE_CHIPS,
            "every chip is with the trader, the vault or the fee recipient"
        );
        assertEq(
            vault.getHouse(house).lpAssets, chip.balanceOf(address(vault)), "the vault booked what came back"
        );
    }

    function _useChip(MockChip c) internal {
        chip = c;
        guard.set(address(c), true, false);
        house = vault.createHouse(NVDA, address(c));
    }

    /// @dev One full round per chip precision (0, 2, 6 and 18 decimals) with the real math: buys and sells
    ///      on every product of the menu, a round trip never profits, settle, finalize, redeem, books
    ///      balanced.
    function test_anyChipDecimals() public {
        uint8[4] memory decs = [uint8(0), 2, 6, 18];
        uint256 snap = vm.snapshotState();
        for (uint256 n; n < 4; ++n) {
            uint256 unit = 10 ** decs[n];
            _useChip(new MockChip(decs[n]));
            _lpDeposit(lp, 1_000_000 * unit);
            _fund(eve, 10_000_000 * unit);
            _open(600);
            for (uint8 idx; idx < PRODUCTS; ++idx) {
                uint256 cost = _buy(eve, idx, 3 * unit, S0);
                uint256 back = _sell(eve, idx, 3 * unit, S0);
                assertLt(back, cost, "a round trip at one price loses");
                _buy(eve, idx, 10_000 * unit, _priceAtSigmas(int256(uint256(idx)) * 2e17 - 9e17));
                // the smallest trade a round takes (one whole token): costs at least one chip
                // unit, sells for no more than it cost
                cost = _buy(eve, idx, unit, S0);
                assertGe(cost, 1);
                back = _sell(eve, idx, unit, S0);
                assertLe(back, cost);
                if (unit > 1) {
                    vm.prank(eve);
                    vm.expectRevert(IFallpitRouter.BelowMinimumTrade.selector);
                    router.commit{value: FILL_FEE}(roundId, idx, true, unit - 1, unit);
                }
            }
            _closeAndFinalize(S0 * 1005 / 1000);
            IFallpitHook.RoundState memory st = _state();
            // up 0.5%: the floor from 0 to +0.5 sigma wins, and HIGHER
            assertEq(st.winners, uint16(1 << F4 | 1 << HIGHER));
            for (uint8 idx; idx < PRODUCTS; ++idx) {
                if ((st.winners >> idx) & 1 == 0) continue;
                uint256 token = _token(idx).id;
                uint256 bal = _token(idx).balanceOf(eve);
                vm.prank(eve);
                assertEq(router.redeem(token, bal), bal, "one chip unit per winning token unit");
            }
            hook.collectProtocolFees(address(chip));
            assertEq(chip.balanceOf(address(hook)), 0);
            assertEq(
                chip.balanceOf(eve) + chip.balanceOf(address(vault)) + chip.balanceOf(feeRecipient),
                11_000_000 * unit
            );
            vm.revertToState(snap);
        }
    }

    /// @dev A chip that burns 1% of every transfer, through the real vault. It is not a chip: the vault
    ///      refuses the LP's deposit and a donation, and the router refuses a buy commit. The two rounds
    ///      are defence in depth, for a chip that starts to tax after its house was funded: the round
    ///      opens with what the hook booked, commits made before the tax fill, winners are paid, the vault books what arrived and
    ///      unlocks, and the next round opens.
    function test_feeOnTransferChip_refused_lateTaxTwoRounds() public {
        MockFeeChip tax = new MockFeeChip();
        _useChip(tax);
        // refused at the vault, whether as a deposit or as a donation
        chip.mint(lp, 2 * CAPITAL);
        vm.startPrank(lp);
        chip.approve(address(vault), 2 * CAPITAL);
        vm.expectRevert(
            abi.encodeWithSelector(PitVault.InexactTransfer.selector, CAPITAL, CAPITAL * 99 / 100)
        );
        vault.deposit(house, CAPITAL);
        vm.expectRevert(
            abi.encodeWithSelector(PitVault.InexactTransfer.selector, CAPITAL, CAPITAL * 99 / 100)
        );
        vault.donate(house, CAPITAL);
        vm.stopPrank();
        assertEq(vault.roundCapital(house), 0);
        vm.expectRevert(IFallpitHook.CapitalTooLow.selector);
        hook.openRound(NVDA, address(chip), day);

        // funded while the chip was plain; the tax starts before the round opens
        tax.setTax(false);
        vm.prank(lp);
        vault.deposit(house, CAPITAL);
        _fund(eve, 10_000_000e18);
        tax.setTax(true);
        _open(600);
        uint256 capital = hook.getConfig(roundId).capital;
        assertEq(capital, CAPITAL * 99 / 100, "taxed on the way into the round: L is what arrived");

        // refused at the router
        vm.prank(eve);
        vm.expectRevert(IFallpitRouter.BadEscrow.selector);
        router.commit{value: FILL_FEE}(roundId, HIGHER, true, 19_000e18, 19_000e18);

        _buyAcrossTheTax(tax, HIGHER, 19_000e18);
        _buyAcrossTheTax(tax, LOWER, 15_000e18);
        _sell(eve, LOWER, 5_000e18, S0);
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, owed, "claims equal what the hook booked");
        assertGe(chip.balanceOf(address(hook)), claims);
        _closeAndFinalize(S0 * 101 / 100);
        uint256 token = _token(HIGHER).id;
        vm.prank(eve);
        router.redeem(token, 19_000e18);
        assertEq(chip.balanceOf(address(hook)), hook.protocolFeesAccrued(address(chip)));
        assertFalse(vault.isLocked(house));
        assertEq(vault.getHouse(house).lpAssets, chip.balanceOf(address(vault)));

        // the next day opens with whatever came back
        _recordCloseOf(day + 1, S0, TRUSTLESS);
        day = day + 2;
        hook.openRound(NVDA, address(chip), day);
    }

    /// @dev A buy committed while the chip is plain and filled after it started to tax.
    function _buyAcrossTheTax(MockFeeChip tax, uint8 index, uint256 shares) internal {
        tax.setTax(false);
        vm.prank(eve);
        uint256 id = router.commit{value: FILL_FEE}(roundId, index, true, shares, shares);
        tax.setTax(true);
        require(_fillAt(id, S0), "buy refunded");
    }

    /// @dev The oracle price is not bounded in units of sigma (sigma can be 0.5% and a stock can gap 10%).
    ///      Buys of every product at 0, 3, 6, 10 and 40 standard deviations either side, ten minutes
    ///      apart, then everything sold at +5: every fill executes, none reverts, none is refunded. The
    ///      pair is bought 20,000 at a time; a floor 10,000
    ///      at a time, so that nine buys stay under its product cap of 100,000.
    function test_fortySigmaMoves_everyFillExecutes() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, EVE_CHIPS);
        _open(60);
        int256[9] memory ks = [int256(0), 3e18, -3e18, 6e18, -6e18, 10e18, -10e18, 40e18, -40e18];
        for (uint256 i; i < ks.length; ++i) {
            uint256 price = _priceAtSigmas(ks[i]);
            for (uint8 idx; idx < PRODUCTS; ++idx) {
                (bool filled,) = _tryBuy(eve, idx, idx < LOWER ? 10_000e18 : 20_000e18, price);
                assertTrue(filled);
            }
            _warp(clock + 600);
        }
        for (uint8 idx; idx < PRODUCTS; ++idx) {
            uint256 lot = idx < LOWER ? 10_000e18 : 20_000e18;
            for (uint256 left = _token(idx).balanceOf(eve); left != 0; left -= lot) {
                (bool filled,) = _trySell(eve, idx, lot, _priceAtSigmas(5e18));
                assertTrue(filled);
            }
        }
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        for (uint256 i; i < MAX_PRODUCTS; ++i) {
            assertEq(supply[i], 0);
        }
        assertGe(_state().held, CAPITAL, "the round trips cost the trader, not the house");
    }

    /// @dev Griefing check: can the solvency headroom be used up with tokens bought at the prior floor?
    ///      With the stock 10 standard deviations up, LOWER starts at the prior's floor. Every token is
    ///      charged at least the minimum price of two hundredths of a chip (the first 100,000 cost about
    ///      5,200 chips at the default alpha 0.2), and it stops being cheap after
    ///      about alpha * L shares; from there every share costs about one chip, which raises `held` as
    ///      fast as the worst-case payout. (This is LOWER of the pair; the same play through a floor is
    ///      below.)
    function test_floorPricedTokens_cannotExhaustSolvencyCheaply() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, EVE_CHIPS);
        _open(3600);
        uint256 price = _priceAtSigmas(10e18);
        uint256 total;
        uint256[3] memory checkpoints;
        for (uint256 i; i < 80; ++i) {
            total += _buy(eve, LOWER, 20_000e18, price);
            if (i == 4) checkpoints[0] = total; // 100,000 shares
            if (i == 9) checkpoints[1] = total; // 200,000
            if (i == 14) checkpoints[2] = total; // 300,000
        }
        console.log("first 100,000 LOWER at +10 sigma: %s chips", checkpoints[0] / 1e18);
        console.log("third 100,000: %s chips", (checkpoints[2] - checkpoints[1]) / 1e18);
        console.log("1,600,000: %s chips", total / 1e18);
        assertGe(checkpoints[0], 2_000e18, "the first 100,000 pay the minimum price: not nearly free");
        assertLt(
            checkpoints[0],
            6_000e18,
            "and not much more: the shallower book of alpha 0.2 lifts the price sooner"
        );
        assertGt(checkpoints[2] - checkpoints[1], 70_000e18, "the third 100,000 cost over 0.7 each");
        assertGt(total, 1_400_000e18, "1,600,000 shares cost over 1,400,000 chips");
        (uint256 worst, uint256 covered) = lens.solvency(roundId);
        assertEq(worst, 1_600_000e18);
        assertGt(covered - worst, 800_000e18, "the headroom is still 80% of the capital");
    }

    /// @dev The same griefing through a floor: with the stock 10 standard deviations up, the floor below
    ///      -2 sigma is at the prior's floor. There is no product cap by default, so
    ///      what bounds the floor is what bounds the pair: the engine. The first 100,000 cost about the
    ///      minimum price, the third 100,000 about one chip a token, and the headroom used up for 300,000
    ///      tokens is less than a fifth of the capital.
    function test_floorPricedFloor_noCap_stopsBeingCheapLikeThePair() public {
        _lpDeposit(lp, CAPITAL);
        _fund(eve, EVE_CHIPS);
        _open(3600);
        uint256 price = _priceAtSigmas(10e18);
        uint256 total;
        uint256[3] memory checkpoints;
        for (uint256 i; i < 15; ++i) {
            total += _buy(eve, F0, 20_000e18, price);
            if (i == 4) checkpoints[0] = total; // 100,000 shares
            if (i == 9) checkpoints[1] = total; // 200,000
            if (i == 14) checkpoints[2] = total; // 300,000
        }
        console.log("first 100,000 of the bottom floor at +10 sigma: %s chips", checkpoints[0] / 1e18);
        console.log("third 100,000: %s chips", (checkpoints[2] - checkpoints[1]) / 1e18);
        assertGe(checkpoints[0], 2_040e18, "the minimum price for every token, and the 2% fee on it");
        assertLt(checkpoints[0], 6_000e18, "and not much more");
        assertGt(checkpoints[2] - checkpoints[1], 70_000e18, "the third 100,000 cost over 0.7 each");
        (bool filled,) = _tryBuy(eve, F0, 1e18, price);
        assertTrue(filled, "no product cap: the floor keeps trading");
        (uint256 worst, uint256 covered) = lens.solvency(roundId);
        assertEq(worst, 300_001e18);
        assertGt(covered - worst, 800_000e18, "the headroom is still over 80% of the capital");
    }
}
