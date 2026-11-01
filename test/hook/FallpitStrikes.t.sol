// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {HookFixture} from "./HookFixture.sol";
import {Menus} from "../Menus.sol";
import {Ticket} from "../Ticket.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {FallpitLens} from "../../src/hook/FallpitLens.sol";
import {MockPitOracle} from "./mocks/MockPitOracle.sol";
import {PitMath} from "../../src/hook/PitMath.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice Live strikes (`openStrike`): a second HIGHER / LOWER pair on the round's grid, at the edge nearest
///         to the print, opened by anyone once at most half of the round's variance is ahead. The fixture's
///         grid: sigma 2%, so inner edge m is at log return (m - 19) * 0.5%.
contract FallpitStrikesTest is HookFixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant SIGMA = 0.02e18;
    int256 internal constant STEP = 0.005e18;

    event StrikeOpened(
        bytes32 indexed roundId, uint8 m, uint8 indexLow, uint8 indexHigh, uint256 price, uint64 ts
    );

    function setUp() public override {
        super.setUp();
        _fund(alice, 1_000_000e18);
        _fund(bob, 1_000_000e18);
    }

    // --------------------------------------------------------------------------------------------
    // helpers
    // --------------------------------------------------------------------------------------------

    /// @dev Log return of inner edge m on the fixture's grid.
    function _edge(uint8 m) internal pure returns (int256) {
        return (int256(uint256(m)) - 19) * STEP;
    }

    /// @dev The price at log return x from S0.
    function _priceAt(int256 x) internal pure returns (uint256) {
        return S0.mulWad(uint256(FixedPointMathLib.expWad(x)));
    }

    /// @dev A price a fifth of a step above edge m: m is the nearest edge.
    function _near(uint8 m) internal pure returns (uint256) {
        return _priceAt(_edge(m) + STEP / 5);
    }

    /// @dev Opens Tuesday's round and moves to 15:00, when less than half of its variance is ahead.
    function _openLate() internal {
        _open();
        _warp(NYTime.at(day, 15 hours));
        (uint256 rho, bool tradable) = lens.clockAt(roundId, clock);
        assertTrue(tradable);
        assertLe(rho, 0.5e18, "precondition: half the variance or less ahead");
    }

    /// @dev Opens the strike on edge m at a print of `price` made now.
    function _strike(uint8 m, uint256 price) internal {
        hook.openStrike(roundId, m, clock, _report(clock, price));
    }

    function _menu() internal view returns (uint256) {
        return hook.getConfig(roundId).params.menu;
    }

    // --------------------------------------------------------------------------------------------
    // opening
    // --------------------------------------------------------------------------------------------

    function test_openStrike_appendsThePairAtTheEdge() public {
        _openLate();
        uint256 price = _near(23);
        bytes memory report = _report(clock, price);
        vm.expectEmit(address(hook));
        emit StrikeOpened(roundId, 23, 10, 11, price, clock);
        vm.prank(carol); // anyone
        hook.openStrike(roundId, 23, clock, report);

        uint256 menu = _menu();
        assertEq(PitMath.count(menu), 12);
        assertEq(PitMath.strikeFrom(menu), 10, "the round's own ten products come first");
        (uint8 lo, uint8 hi) = PitMath.run(menu, 10);
        assertEq(lo, 0);
        assertEq(hi, 23);
        (lo, hi) = PitMath.run(menu, 11);
        assertEq(lo, 24);
        assertEq(hi, 39);
        // the base menu is untouched
        for (uint256 i; i < 10; ++i) {
            (uint8 a, uint8 b) = PitMath.run(menu, i);
            (uint8 c, uint8 d) = PitMath.run(Menus.standard(), i);
            assertEq(a, c);
            assertEq(b, d);
        }
        // the new tickets exist and trade
        (uint256 id,,,,,,,) = hook.commitContext(roundId, 11);
        assertEq(id, hook.tokenId(roundId, 11));
        (id,,,,,,,) = hook.commitContext(roundId, 12);
        assertEq(id, 0, "no product 12 yet");
    }

    function test_openStrike_refusesBeforeHalfTheVariance() public {
        _open();
        _warp(NYTime.at(day, 10 hours));
        (uint256 rho,) = lens.clockAt(roundId, clock);
        assertGt(rho, 0.5e18);
        uint256 price = _near(23);
        bytes memory report = _report(clock, price);
        vm.expectRevert(IFallpitHook.StrikeTooEarly.selector);
        hook.openStrike(roundId, 23, clock, report);
    }

    function test_openStrike_refusesAnEdgeThatIsNotTheNearest() public {
        _openLate();
        uint256 price = _near(23);
        bytes memory report = _report(clock, price);
        vm.expectRevert(IFallpitHook.StrikeEdge.selector);
        hook.openStrike(roundId, 22, clock, report);
        vm.expectRevert(IFallpitHook.StrikeEdge.selector);
        hook.openStrike(roundId, 24, clock, report);
        vm.expectRevert(IFallpitHook.StrikeEdge.selector);
        hook.openStrike(roundId, 39, clock, report);
        hook.openStrike(roundId, 23, clock, report);
    }

    function test_openStrike_keepsTwoEdgesFromThePair() public {
        _openLate();
        bytes memory report = _report(clock, _near(20));
        vm.expectRevert(IFallpitHook.StrikeTooClose.selector);
        hook.openStrike(roundId, 20, clock, report);
        _warp(clock + 1);
        report = _report(clock, _near(18));
        vm.expectRevert(IFallpitHook.StrikeTooClose.selector);
        hook.openStrike(roundId, 18, clock, report);
        _warp(clock + 1);
        report = _report(clock, _near(19));
        vm.expectRevert(IFallpitHook.StrikeTooClose.selector);
        hook.openStrike(roundId, 19, clock, report);
        _warp(clock + 1);
        _strike(21, _near(21));
        _warp(clock + 1);
        _strike(17, _near(17));
        assertEq(PitMath.count(_menu()), 14);
    }

    function test_openStrike_keepsTwoEdgesFromAnOpenStrike() public {
        _openLate();
        _strike(23, _near(23));
        _warp(clock + 1);
        bytes memory report = _report(clock, _near(24));
        vm.expectRevert(IFallpitHook.StrikeTooClose.selector);
        hook.openStrike(roundId, 24, clock, report);
        _warp(clock + 1);
        report = _report(clock, _near(22));
        vm.expectRevert(IFallpitHook.StrikeTooClose.selector);
        hook.openStrike(roundId, 22, clock, report);
        _warp(clock + 1);
        report = _report(clock, _near(23));
        vm.expectRevert(IFallpitHook.StrikeTooClose.selector);
        hook.openStrike(roundId, 23, clock, report);
        _warp(clock + 1);
        _strike(25, _near(25));
    }

    function test_openStrike_defaultMenuHasRoomForTwo() public {
        _openLate();
        _strike(23, _near(23));
        _warp(clock + 1);
        _strike(26, _near(26));
        assertEq(PitMath.count(_menu()), 14);
        _warp(clock + 1);
        bytes memory report = _report(clock, _near(30));
        vm.expectRevert(IFallpitHook.StrikeNoRoom.selector);
        hook.openStrike(roundId, 30, clock, report);
    }

    function test_openStrike_twelveProductMenuHasRoomForOne() public {
        uint8[2][] memory runs = new uint8[2][](12);
        for (uint8 i; i < 12; ++i) {
            runs[i] = [i * 3, i * 3 + 6];
        }
        _setMenu(Menus.pack(runs));
        _openLate();
        _strike(23, _near(23));
        assertEq(PitMath.count(_menu()), 14);
        assertEq(PitMath.strikeFrom(_menu()), 12);
        _warp(clock + 1);
        bytes memory report = _report(clock, _near(28));
        vm.expectRevert(IFallpitHook.StrikeNoRoom.selector);
        hook.openStrike(roundId, 28, clock, report);
    }

    function test_openStrike_refusesARoundThatIsNotOpen() public {
        bytes32 unknown = hook.roundIdOf(house, day + 7);
        bytes memory report = _report(clock, _near(23));
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        hook.openStrike(unknown, 23, clock, report);

        _openLate();
        _recordClose(_near(23), TRUSTLESS);
        hook.settleRound(house, day);
        report = _report(clock, _near(23));
        vm.expectRevert(IFallpitHook.WrongStatus.selector);
        hook.openStrike(roundId, 23, clock, report);
    }

    function test_openStrike_refusesAStaleOrFutureInstant() public {
        _openLate();
        uint64 t = clock;
        bytes memory report = _report(t, _near(23));
        uint32 refundDelay = hook.getConfig(roundId).params.refundDelay;
        _warp(t + refundDelay + 1);
        vm.expectRevert(IFallpitHook.FillExpired.selector);
        hook.openStrike(roundId, 23, t, report);
        bytes memory later = _report(clock + 10, _near(23));
        vm.expectRevert(IFallpitHook.FillExpired.selector);
        hook.openStrike(roundId, 23, clock + 10, later);
    }

    /// @dev With a refund window of 120 seconds the strike still takes only an instant of the last 30.
    function test_openStrike_takesOnlyARecentInstant() public {
        IPitBook.Params memory p = book.defaultParams();
        p.refundDelay = 120;
        _setParams(p);
        _openLate();
        uint64 t = clock;
        bytes memory report = _report(t, _near(23));
        _warp(t + 31);
        vm.expectRevert(IFallpitHook.FillExpired.selector);
        hook.openStrike(roundId, 23, t, report);
        t = clock;
        report = _report(t, _near(23));
        _warp(t + 30);
        hook.openStrike(roundId, 23, t, report);
        assertEq(PitMath.count(_menu()), 12);
    }

    /// @dev The time of the round at which at most half of its variance is ahead for the first time, and
    ///      the remaining sd there (the fixture has no learned sigma).
    function _halfVariance() internal returns (uint256 sd) {
        _open();
        uint64 t = NYTime.at(day, 11 hours);
        uint256 rho = 1e18;
        while (rho > 0.5e18) {
            t += 60;
            (rho,) = lens.clockAt(roundId, t);
        }
        _warp(t);
        sd = SIGMA.mulWad(rho.sqrtWad());
    }

    function test_openStrike_refusesWhileThePairIsNotPinned() public {
        uint256 pin = _halfVariance().mulWad(PitMath.STRIKE_PIN_Z);
        // two edges from the pair, but nearer to the pair's edge than 0.84 remaining sd
        int256 x = _edge(21) + 1e14;
        assertLt(uint256(x), pin, "precondition: not pinned");
        bytes memory report = _report(clock, _priceAt(x));
        vm.expectRevert(IFallpitHook.StrikeNotPinned.selector);
        hook.openStrike(roundId, 21, clock, report);
        (uint8 m, bool ok) = lens.strikeEdgeAt(roundId, _priceAt(x), clock);
        assertEq(m, 21);
        assertFalse(ok, "the lens says the same");
    }

    function test_openStrike_refusesWhileAnOpenStrikeIsNotPinned() public {
        uint256 pin = _halfVariance().mulWad(PitMath.STRIKE_PIN_Z);
        assertGt(uint256(_edge(23) + STEP / 5), pin, "precondition: the pair is pinned at edge 23");
        _strike(23, _near(23));
        _warp(clock + 1);
        // two edges from the strike, but nearer to its edge than 0.84 remaining sd
        int256 x = _edge(25) - 1e14;
        assertLt(uint256(x - _edge(23)), pin, "precondition: the strike is not pinned");
        bytes memory report = _report(clock, _priceAt(x));
        vm.expectRevert(IFallpitHook.StrikeNotPinned.selector);
        hook.openStrike(roundId, 25, clock, report);
    }

    /// @dev The caller pays the oracle's fee: ETH the hook holds is never sent with a strike's print.
    function test_openStrike_neverSpendsTheHooksEth() public {
        _openLate();
        oracle.setFee(1 ether);
        vm.deal(address(hook), 5 ether);
        bytes memory report = _report(clock, _near(23));
        vm.expectRevert(MockPitOracle.FeeNotPaid.selector);
        hook.openStrike(roundId, 23, clock, report);
        assertEq(address(hook).balance, 5 ether);
        // an overpaid fee goes back to the caller, not into the hook
        vm.deal(carol, 3 ether);
        vm.prank(carol);
        hook.openStrike{value: 3 ether}(roundId, 23, clock, report);
        assertEq(address(hook).balance, 5 ether, "the hook's ETH is untouched");
        assertEq(carol.balance, 2 ether, "the caller pays only the fee");
        assertEq(PitMath.count(_menu()), 12);
    }

    function test_openStrike_refusesOutsideTheTradingWindows() public {
        _open();
        // past the round's cutoff the clock no longer trades
        _warp(hook.getConfig(roundId).cutoff + 5);
        bytes memory report = _report(clock, _near(23));
        vm.expectRevert(IFallpitHook.StrikeWindow.selector);
        hook.openStrike(roundId, 23, clock, report);
    }

    function test_openStrike_refusesThePrintOfTheOtherSource() public {
        _openLate();
        bytes memory report = oracle.post(NVDA, TRUSTLESS, _near(23), clock);
        vm.expectRevert(IFallpitHook.WrongFillSource.selector);
        hook.openStrike(roundId, 23, clock, report);
    }

    function test_openStrike_onAPythSourceRound() public {
        _reseed(
            NVDA,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        _openLate();
        bytes memory keeperPrint = oracle.post(NVDA, KEEPER, _near(23), clock);
        vm.expectRevert(IFallpitHook.WrongFillSource.selector);
        hook.openStrike(roundId, 23, clock, keeperPrint);
        _warp(clock + 1);
        bytes memory pythPrint = oracle.post(NVDA, TRUSTLESS, _near(23), clock);
        hook.openStrike{value: 0}(roundId, 23, clock, pythPrint);
        assertEq(PitMath.count(_menu()), 12);
    }

    // --------------------------------------------------------------------------------------------
    // the nearest edge
    // --------------------------------------------------------------------------------------------

    function test_nearestEdge_onBothSidesAndAtTheEnds() public pure {
        for (uint8 m; m <= 38; ++m) {
            assertEq(PitMath.nearestEdge(SIGMA, _edge(m)), m, "on the edge");
            assertEq(PitMath.nearestEdge(SIGMA, _edge(m) + STEP / 5), m, "a fifth above");
            assertEq(PitMath.nearestEdge(SIGMA, _edge(m) - STEP / 5), m, "a fifth below");
        }
        // beyond the grid: its last edges
        assertEq(PitMath.nearestEdge(SIGMA, _edge(38) + 10 * STEP), 38);
        assertEq(PitMath.nearestEdge(SIGMA, _edge(0) - 10 * STEP), 0);
        assertEq(PitMath.nearestEdge(SIGMA, 1e18), 38);
        assertEq(PitMath.nearestEdge(SIGMA, -1e18), 0);
        // half way between two edges: the lower one; just past it: the upper one
        assertEq(PitMath.nearestEdge(SIGMA, _edge(23) + STEP / 2), 23);
        assertEq(PitMath.nearestEdge(SIGMA, _edge(23) + STEP / 2 + 1), 24);
        assertEq(PitMath.nearestEdge(SIGMA, _edge(10) - STEP / 2), 9);
        assertEq(PitMath.nearestEdge(SIGMA, _edge(10) - STEP / 2 + 1), 10);
    }

    function testFuzz_nearestEdge_isTheClosest(int256 x, uint256 sigma) public pure {
        sigma = bound(sigma, 0.001e18, 1e18);
        x = bound(x, -10e18, 10e18);
        uint8 m = PitMath.nearestEdge(sigma, x);
        assertLe(m, 38);
        uint256 gap = FixedPointMathLib.dist(PitMath.edge(sigma, m), x);
        for (uint256 k; k <= 38; ++k) {
            uint256 other = FixedPointMathLib.dist(PitMath.edge(sigma, k), x);
            assertLe(gap, other, "no edge is nearer");
            if (other == gap) assertLe(m, k, "the lower one on a tie");
        }
    }

    // --------------------------------------------------------------------------------------------
    // trading, settling, voiding
    // --------------------------------------------------------------------------------------------

    /// @dev Strikes on 23 (products 10, 11) and 15 (12, 13), each bought by both players and partly sold.
    function _tradedStrikes() internal {
        _openLate();
        _strike(23, _near(23));
        _warp(clock + 1);
        _strike(15, _near(15));
        _warp(clock + 10);
        for (uint8 i = 10; i < 14; ++i) {
            _buy(alice, i, 4_000e18 + uint256(i) * 100e18, S0);
            _buy(bob, i, 1_500e18, S0 * 1001 / 1000);
            _warp(clock + 10);
        }
        _buy(alice, HIGHER, 2_000e18, S0);
        _warp(clock + 10);
        for (uint8 i = 10; i < 14; ++i) {
            _sell(alice, i, 1_000e18, S0);
            _warp(clock + 10);
        }
        _assertSupplies();
        _assertHookSolvent(address(chip));
        (uint256 worst, uint256 covered) = lens.solvency(roundId);
        assertLe(worst, covered);
    }

    function _settleOn(int256 x, uint16 expected) internal {
        _tradedStrikes();
        uint256 menu = _menu();
        (uint256[15] memory supply,) = hook.getSupplies(roundId);
        _recordClose(_priceAt(x), TRUSTLESS);
        hook.settleRound(house, day);
        IFallpitHook.RoundState memory st = _state();
        assertEq(st.winners & uint16(0x3c00), expected, "the strike sides over the close's band");
        assertEq(st.winners, PitMath.winners(menu, st.closeBand));
        assertEq(st.payoutOwed, PitMath.payoutOf(supply, st.winners), "one chip per winning ticket");
        hook.finalizeRound(house, day);
        _assertHookSolvent(address(chip));
        // every winning strike ticket pays one chip, a losing one nothing
        for (uint8 i = 10; i < 14; ++i) {
            Ticket memory t = _token(i);
            uint256 held = t.balanceOf(alice);
            uint256 before = chip.balanceOf(alice);
            if (expected >> i & 1 == 1) {
                vm.prank(alice);
                hook.redeem(t.id, alice, held);
                assertEq(chip.balanceOf(alice) - before, held);
            } else {
                vm.prank(alice);
                vm.expectRevert(IFallpitHook.NotWinner.selector);
                hook.redeem(t.id, alice, held);
            }
        }
        _assertHookSolvent(address(chip));
    }

    function test_strikes_closeBelowBoth() public {
        // band 15: LOWER-15 (12) and LOWER-23 (10)
        _settleOn(_edge(15) - STEP / 2, uint16(1 << 10 | 1 << 12));
    }

    function test_strikes_closeBetween() public {
        // band 20: LOWER-23 (10) and HIGHER-15 (13)
        _settleOn(STEP / 2, uint16(1 << 10 | 1 << 13));
    }

    function test_strikes_closeAboveBoth() public {
        // band 24: HIGHER-23 (11) and HIGHER-15 (13)
        _settleOn(_edge(23) + STEP / 2, uint16(1 << 11 | 1 << 13));
    }

    function test_strikes_voidRefundsTheirHolders() public {
        _tradedStrikes();
        (, uint256[15] memory premium) = hook.getSupplies(roundId);
        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        (uint256[15] memory supply, uint256[15] memory refund) = hook.getSupplies(roundId);
        for (uint8 i = 10; i < 14; ++i) {
            assertGt(refund[i], 0, "a strike's holders share the refund");
            assertLe(refund[i], premium[i], "never more than its cost basis");
            Ticket memory t = _token(i);
            uint256 held = t.balanceOf(bob);
            uint256 before = chip.balanceOf(bob);
            vm.prank(bob);
            uint256 paid = hook.redeem(t.id, bob, held);
            assertEq(paid, refund[i] * held / supply[i]);
            assertEq(chip.balanceOf(bob) - before, paid);
        }
        _assertHookSolvent(address(chip));
    }

    function test_strikes_countInThePooledWorstCase() public {
        _openLate();
        _strike(23, _near(23));
        _warp(clock + 10);
        // HIGHER (bands 20..39), HIGHER-23 (24..39) and the floor 24..27 all pay in band 24
        _buy(alice, HIGHER, 3_000e18, S0);
        _buy(alice, 11, 5_000e18, S0);
        _buy(bob, F6, 2_000e18, S0);
        uint256[40] memory pay = lens.payouts(roundId);
        assertEq(pay[24], 10_000e18);
        assertEq(pay[23], 3_000e18, "HIGHER-23 does not pay in band 23");
        (uint256 worst,) = lens.solvency(roundId);
        assertEq(worst, 10_000e18);
        (uint256 cushion,) = lens.lossLimit(roundId);
        IFallpitHook.RoundState memory st = _state();
        assertEq(cushion, st.held - st.protocolFees - worst);
    }

    function test_strikes_buysStopAtTheLossLimit() public {
        IPitBook.Params memory p = book.defaultParams();
        p.lossLimitBps = 1000; // 10% of the capital, the least the book allows
        p.maxFillBps = 2000;
        _setParams(p);
        _openLate();
        _strike(23, _near(23));
        _warp(clock + 10);
        chip.mint(alice, 2_000_000e18);
        // buys of a strike side pile up in its bands until one would cross the loss limit
        bool refused;
        for (uint256 k; k < 10 && !refused; ++k) {
            uint256 supplyBefore = _token(11).totalSupply();
            uint256 id = _commitBuy(alice, 11, 150_000e18, 200_000e18);
            uint256 before = chip.balanceOf(alice);
            refused = !_fill(id, S0);
            if (refused) {
                assertEq(chip.balanceOf(alice), before + 200_000e18, "the escrow came back");
                assertEq(_token(11).totalSupply(), supplyBefore, "nothing minted");
            }
            (uint256 cushion, uint256 floor) = lens.lossLimit(roundId);
            assertGe(cushion, floor, "the cushion never goes under the limit");
            _warp(clock + 10);
        }
        assertTrue(refused, "the loss limit stopped the strike's buys");
        // a holder can always sell
        _sell(alice, 11, 50_000e18, S0);
    }

    // --------------------------------------------------------------------------------------------
    // the lens
    // --------------------------------------------------------------------------------------------

    function test_lens_marksStrikesAndTheEdgeToOpen() public {
        _open();
        uint256 price = _near(23);
        (uint8 m, bool ok) = lens.strikeEdgeAt(roundId, price, clock);
        assertEq(m, 23);
        assertFalse(ok, "too early in the round");
        _warp(NYTime.at(day, 15 hours));
        (m, ok) = lens.strikeEdgeAt(roundId, price, clock);
        assertEq(m, 23);
        assertTrue(ok);
        (m, ok) = lens.strikeEdgeAt(roundId, _near(20), clock);
        assertEq(m, 20);
        assertFalse(ok, "too close to the pair");

        _strike(23, price);
        (, ok) = lens.strikeEdgeAt(roundId, price, clock);
        assertFalse(ok, "already open");
        FallpitLens.Market memory mk = lens.market(roundId, price, clock);
        assertEq(mk.products.length, 12);
        for (uint256 i; i < 12; ++i) {
            assertEq(mk.products[i].strike, i >= 10);
        }
        assertEq(mk.products[10].hi, 23);
        assertEq(mk.products[11].lo, 24);
        // a strike at the price is near even odds; its two sides sum to one
        assertApproxEqAbs(mk.products[10].price + mk.products[11].price, 1e18, 1e12);
    }
}
