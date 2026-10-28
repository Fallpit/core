// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {HookFixture} from "./HookFixture.sol";
import {MockChip} from "./mocks/MockChips.sol";
import {FallpitHook} from "../../src/FallpitHook.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {PitMath} from "../../src/hook/PitMath.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {Menus} from "../Menus.sol";

/// @notice Lifecycle of a round: open, trade, close, settle, finalize, redeem, void, and the next round.
contract FallpitRoundTest is HookFixture {
    uint256 internal constant STAKE = 100_000e18;

    function setUp() public override {
        super.setUp();
        _fund(alice, STAKE);
        _fund(bob, STAKE);
        _fund(carol, STAKE);
    }

    // --------------------------------------------------------------------------------------------
    // open
    // --------------------------------------------------------------------------------------------

    function test_openRound_freezesConfigAndDeploysTokens() public {
        bytes32 id = hook.openRound(NVDA, address(chip), day);
        roundId = id;
        assertEq(id, hook.roundIdOf(house, day));
        assertEq(hook.houseRound(house), id);
        assertEq(house, vault.houseId(NVDA, address(chip)), "house id matches the vault's");

        IFallpitHook.RoundConfig memory c = hook.getConfig(id);
        assertEq(c.ticker, NVDA);
        assertEq(c.chip, address(chip));
        assertEq(c.day, day);
        assertEq(c.decimals, 18);
        assertEq(c.s0, S0);
        assertEq(c.sigma, 0.02e18);
        assertEq(uint8(c.clock.kind), uint8(IPitBook.Clock.NYWeekdays));
        assertFalse(c.clock.skipAfterHours);
        assertEq(c.clock.prevDay, day0, "the round starts from Monday's close");
        assertEq(c.clock.day, day);
        assertEq(c.clock.afterHours, 600);
        assertEq(c.clock.gap, 1400);
        assertEq(c.clock.preMarket, 1000);
        assertEq(c.clock.regular, 7000);
        assertEq(c.capital, HOUSE_CAPITAL, "L is what arrived in the hook");
        assertEq(c.maxFill, HOUSE_CAPITAL * 200 / 10_000);
        assertEq(c.openTs, clock, "the moment it was opened: a minute after Monday's close");
        assertEq(c.closeTs, NYTime.closeTs(day));
        assertEq(c.cutoff, NYTime.closeTs(day) - 630);
        // the book's defaults: alpha 0.2, no product
        // cap, loss limit 30%
        assertEq(c.params.alpha, 0.2e18);
        assertEq(c.params.lossLimitBps, 3000);
        assertEq(c.params.fillDelay, 2);
        assertEq(c.params.refundDelay, 30);
        assertEq(c.params.minTrade, 1e18);
        assertEq(c.params.floorCapBps, 10_000);
        assertEq(c.params.minPriceWad, 0.02e18);
        assertEq(c.params.menu, Menus.standard(), "the book's default menu, frozen in the round");
        assertEq(c.params.menu, book.DEFAULT_MENU());

        IFallpitHook.RoundState memory st = hook.getState(id);
        assertEq(uint8(st.status), uint8(IFallpitHook.Status.Open));
        assertEq(st.g, 1e18);
        assertEq(st.held, HOUSE_CAPITAL);

        // capital moved from the vault into the hook
        assertTrue(vault.isLocked(house));
        assertEq(chip.balanceOf(address(vault)), 0);
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, HOUSE_CAPITAL);
        assertEq(owed, HOUSE_CAPITAL);
        assertEq(chip.balanceOf(address(pm)), 0, "nothing in the PoolManager");

        // one ticket id per product of the menu: the round id and the index, nothing deployed
        Ticket[12] memory tokens = ticketsOf(hook, id);
        uint8[2][10] memory runs = [
            [0, 11], [12, 15], [16, 17], [18, 19], [20, 21], [22, 23], [24, 27], [28, 39], [0, 19], [20, 39]
        ];
        assertEq(PitMath.count(c.params.menu), PRODUCTS);
        for (uint8 i; i < PRODUCTS; ++i) {
            Ticket memory token = tokens[i];
            assertEq(token.id, _predictToken(house, day, i).id, "known before the open");
            assertEq(token.decimals(), 18);
            (uint8 lo, uint8 hi) = PitMath.run(c.params.menu, i);
            assertEq(lo, runs[i][0]);
            assertEq(hi, runs[i][1]);
            // the price range: the edges of the run, S0 * exp(edge), open at the ends of the ladder
            (uint256 low, uint256 high) = PitMath.bounds(S0, c.sigma, lo, hi);
            assertEq(
                low,
                runs[i][0] == 0
                    ? 0
                    : S0 * uint256(FixedPointMathLib.expWad(math.edge(c.sigma, runs[i][0] - 1))) / 1e18
            );
            assertEq(
                high,
                runs[i][1] == 39
                    ? type(uint256).max
                    : S0 * uint256(FixedPointMathLib.expWad(math.edge(c.sigma, runs[i][1]))) / 1e18
            );
            assertEq(token.totalSupply(), 0);
            (bytes32 ref, uint8 index) = hook.tokenRef(token.id);
            assertEq(ref, id);
            assertEq(index, i);
        }
        assertEq(tokens[10].id, 0, "nothing above the menu");
        assertEq(tokens[11].id, 0);
        // the pair sits at the previous close, and neighbouring floors share their edge
        (uint256 hLow,) = PitMath.bounds(S0, c.sigma, 20, 39);
        (, uint256 lHigh) = PitMath.bounds(S0, c.sigma, 0, 19);
        assertEq(hLow, S0);
        assertEq(lHigh, S0);
        for (uint8 i; i < 7; ++i) {
            (uint8 lo0, uint8 hi0) = PitMath.run(c.params.menu, i);
            (uint8 lo1, uint8 hi1) = PitMath.run(c.params.menu, i + 1);
            (, uint256 high) = PitMath.bounds(S0, c.sigma, lo0, hi0);
            (uint256 low,) = PitMath.bounds(S0, c.sigma, lo1, hi1);
            assertEq(high, low);
        }
    }

    function test_openRound_reverts() public {
        // weekend and skipped days
        vm.expectRevert(IPitBook.NotTradingDay.selector);
        hook.openRound(NVDA, address(chip), day0 + 5); // Saturday
        // (a skip needs 24 hours' notice: the owner set this one the day before)
        vm.warp(clock - 1 days);
        vm.prank(owner);
        book.setSkip(NVDA, day, true);
        vm.warp(clock);
        vm.expectRevert(IPitBook.NotTradingDay.selector);
        hook.openRound(NVDA, address(chip), day);
        // with Tuesday skipped, Wednesday is the next trading day; Thursday is not
        vm.expectRevert(IPitBook.NotNextTradingDay.selector);
        hook.openRound(NVDA, address(chip), day + 2);
        vm.warp(clock - 1 days);
        vm.prank(owner);
        book.setSkip(NVDA, day, false);
        vm.warp(clock);
        vm.expectRevert(IPitBook.NotNextTradingDay.selector);
        hook.openRound(NVDA, address(chip), day + 1);
        vm.expectRevert(IPitBook.NoRecentClose.selector);
        hook.openRound(NVDA, address(chip), day + 6);
        vm.expectRevert(IPitBook.NoRecentClose.selector);
        hook.openRound(NVDA, address(chip), day0);

        vm.expectRevert(IPitBook.UnknownTicker.selector);
        hook.openRound(bytes32("TSLA"), address(chip), day);

        // paused: opening only
        vm.prank(owner);
        book.setPaused(true);
        vm.expectRevert(IPitBook.OpeningPaused.selector);
        hook.openRound(NVDA, address(chip), day);
        vm.prank(owner);
        book.setPaused(false);

        // chip not allowed
        MockChip other = new MockChip(18);
        vm.expectRevert(IFallpitHook.ChipNotAllowed.selector);
        hook.openRound(NVDA, address(other), day);

        // capital below the minimum (1000 whole chips)
        _fundHouse(address(other), 999e18);
        vm.expectRevert(IFallpitHook.CapitalTooLow.selector);
        hook.openRound(NVDA, address(other), day);

        // more than 18 decimals
        MockChip wide = new MockChip(19);
        guard.set(address(wide), true, false);
        vm.expectRevert(IFallpitHook.ChipNotAllowed.selector);
        hook.openRound(NVDA, address(wide), day);

        // twice
        hook.openRound(NVDA, address(chip), day);
        vm.expectRevert(IFallpitHook.PreviousRoundActive.selector);
        hook.openRound(NVDA, address(chip), day);

        // at the cutoff it is too late
        bytes32 otherHouse = vault.houseId(NVDA, address(other));
        MockChip(other).mint(address(this), 1e18);
        MockChip(other).approve(address(vault), 1e18);
        vault.deposit(otherHouse, 1e18);
        _warp(NYTime.closeTs(day) - 630);
        vm.expectRevert(IFallpitHook.TooLate.selector);
        hook.openRound(NVDA, address(other), day);
    }

    // --------------------------------------------------------------------------------------------
    // full round and cash conservation
    // --------------------------------------------------------------------------------------------

    function test_fullRound_cashConservation() public {
        _open();
        uint256 price = S0;
        // buys and sells on every product of the menu while the oracle drifts
        for (uint8 i; i < PRODUCTS; ++i) {
            price = price * (1000 + i) / 1000;
            _buy(alice, i, 4_000e18 + uint256(i) * 100e18, price);
            _buy(bob, i, 2_500e18, price * 999 / 1000);
            _warp(clock + 600);
        }
        for (uint8 i; i < PRODUCTS; ++i) {
            price = price * 998 / 1000;
            _sell(alice, i, 1_000e18, price);
            _sell(bob, i, 2_500e18, price);
            _warp(clock + 300);
        }
        _buy(carol, HIGHER, 10_000e18, S0 * 1005 / 1000);
        _buy(carol, F5, 7_000e18, S0 * 1005 / 1000);
        _assertSupplies();
        _assertHookSolvent(address(chip));

        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        IFallpitHook.RoundState memory open = _state();
        assertGt(open.protocolFees, 0);
        assertEq(chip.balanceOf(address(hook)), open.held, "every chip of the round sits in the hook");
        assertEq(chip.balanceOf(address(router)), 0, "no escrow left behind");

        // close up 1.2%: band 22, so the floor from +0.5 to +1 sigma wins, and HIGHER.
        _recordClose(S0 * 1012 / 1000, TRUSTLESS);
        hook.settleRound(house, day);
        IFallpitHook.RoundState memory settled = _state();
        assertEq(uint8(settled.status), uint8(IFallpitHook.Status.Settled));
        assertEq(settled.closeBand, 22);
        assertEq(settled.winners, uint16(1 << F5 | 1 << HIGHER));
        assertEq(settled.payoutOwed, supply[F5] + supply[HIGHER]);

        hook.finalizeRound(house, day);
        IFallpitHook.RoundState memory fin = _state();
        assertEq(uint8(fin.status), uint8(IFallpitHook.Status.Final));
        assertEq(fin.held, settled.payoutOwed);
        assertFalse(vault.isLocked(house));
        uint256 vaultBack = chip.balanceOf(address(vault));
        assertEq(vaultBack, open.held - settled.payoutOwed - open.protocolFees);
        assertEq(vault.roundCapital(house), vaultBack);
        assertEq(hook.protocolFeesAccrued(address(chip)), open.protocolFees);

        // losers redeem for nothing; winners redeem 1:1, through the router or directly
        uint256 loser = _token(F1).id;
        vm.expectRevert(IFallpitHook.NotWinner.selector);
        vm.prank(alice);
        hook.redeem(loser, alice, 1e18);

        address[3] memory users = [alice, bob, carol];
        uint8[2] memory winners = [F5, HIGHER];
        for (uint256 u; u < 3; ++u) {
            for (uint256 w; w < 2; ++w) {
                Ticket memory token = _token(winners[w]);
                uint256 balance = token.balanceOf(users[u]);
                if (balance == 0) continue;
                uint256 before = chip.balanceOf(users[u]);
                vm.prank(users[u]);
                uint256 payout =
                    u == 0 ? hook.redeem(token.id, users[u], balance) : router.redeem(token.id, balance);
                assertEq(payout, balance, "one chip per winning token");
                assertEq(chip.balanceOf(users[u]) - before, balance);
            }
        }
        assertEq(hook.collectProtocolFees(address(chip)), open.protocolFees);
        assertEq(chip.balanceOf(feeRecipient), open.protocolFees);

        // chips in = chips out + vault return + protocol fees, to the unit
        uint256 usersNow = chip.balanceOf(alice) + chip.balanceOf(bob) + chip.balanceOf(carol);
        assertEq(3 * STAKE + HOUSE_CAPITAL, usersNow + vaultBack + open.protocolFees, "cash conservation");
        assertEq(chip.balanceOf(address(hook)), 0, "nothing stranded in the hook");
        assertEq(chip.balanceOf(address(router)), 0);
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, 0);
        assertEq(owed, 0);
        assertEq(_state().held, 0);
        assertEq(_state().payoutOwed, 0);
        for (uint256 w; w < 2; ++w) {
            assertEq(_token(winners[w]).totalSupply(), 0);
        }
    }
}
