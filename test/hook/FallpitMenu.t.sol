// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {HookFixture} from "./HookFixture.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {LadderMath} from "../../src/LadderMath.sol";
import {FallpitLens} from "../../src/hook/FallpitLens.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {PitMath} from "../../src/hook/PitMath.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {Menus} from "../Menus.sol";

/// @notice The menu of a round: how it is encoded and bounded, that the owner's menu waits 24 hours and is
///         frozen in a round, what tokens it deploys, and rounds on menus other than the default (with
///         the mock pricing engine; `test/integration/Floors.t.sol` has the real one).
contract FallpitMenuTest is HookFixture {
    uint256 internal constant STAKE = 200_000e18;

    event Refunded(uint256 indexed commitId, address indexed user, RefundReason reason);

    function setUp() public override {
        super.setUp();
        _fund(alice, STAKE);
        _fund(bob, STAKE);
        _fund(carol, STAKE);
    }

    // --------------------------------------------------------------------------------------------
    // the menu word
    // --------------------------------------------------------------------------------------------

    function test_menu_defaultIsEightFloorsAndThePair() public view {
        uint256 menu = book.DEFAULT_MENU();
        assertEq(menu, Menus.standard(), "the constant in the book is the list written out");
        assertEq(book.defaultParams().menu, menu);
        assertTrue(PitMath.validMenu(menu));
        assertEq(PitMath.count(menu), 10);
        (uint8[] memory lo, uint8[] memory hi) = book.unpackMenu(menu);
        assertEq(lo.length, 10);
        // the eight floors partition the ladder: each starts where the one before ended
        assertEq(lo[0], 0);
        for (uint256 i = 1; i < 8; ++i) {
            assertEq(lo[i], hi[i - 1] + 1);
        }
        assertEq(hi[7], 39);
        // their edges, in quarter sigmas from the previous close (edge m is (m - 19) / 4 sigma): -2, -1,
        // -0.5, 0, 0.5, 1, 2
        uint8[7] memory edges = [11, 15, 17, 19, 21, 23, 27];
        for (uint256 i; i < 7; ++i) {
            assertEq(hi[i], edges[i]);
        }
        // the pair: the two halves of the ladder, at the previous close
        assertEq(lo[LOWER], 0);
        assertEq(hi[LOWER], 19);
        assertEq(lo[HIGHER], 20);
        assertEq(hi[HIGHER], 39);
        // a floor has the product cap, the pair has none
        for (uint256 i; i < 10; ++i) {
            assertEq(PitMath.capped(lo[i], hi[i]), i < 8);
        }
        assertEq(book.packMenu(lo, hi), menu, "pack and unpack are inverse");
    }

    function test_menu_bounds() public {
        IPitBook.Params memory p = book.defaultParams();
        uint8[] memory lo = new uint8[](1);
        uint8[] memory hi = new uint8[](1);
        (lo[0], hi[0]) = (0, 39);
        // fewer than two products
        vm.expectRevert(IPitBook.BadParams.selector);
        book.packMenu(lo, hi);
        p.menu = PitMath.pack(lo, hi);
        vm.prank(owner);
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.menu = 0;
        vm.prank(owner);
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);

        // two is the least, twelve the most
        assertTrue(PitMath.validMenu(Menus.pairOnly()));
        lo = new uint8[](12);
        hi = new uint8[](12);
        for (uint8 i; i < 12; ++i) {
            (lo[i], hi[i]) = (i, 39 - i);
        }
        p.menu = book.packMenu(lo, hi);
        vm.prank(owner);
        book.setDefaultParams(p);
        lo = new uint8[](13);
        hi = new uint8[](13);
        for (uint8 i; i < 13; ++i) {
            (lo[i], hi[i]) = (i, 39 - i);
        }
        vm.expectRevert(IPitBook.BadParams.selector);
        book.packMenu(lo, hi);
        assertFalse(PitMath.validMenu(PitMath.pack(lo, hi)));
        // (a count that does not fit the count byte cannot pass as a small one)
        lo = new uint8[](258);
        hi = new uint8[](258);
        vm.expectRevert(IPitBook.BadParams.selector);
        book.packMenu(lo, hi);
        // arrays of different lengths
        vm.expectRevert(IPitBook.BadParams.selector);
        book.packMenu(new uint8[](3), new uint8[](2));

        // a run must be inside the ladder and not reversed
        lo = new uint8[](2);
        hi = new uint8[](2);
        (lo[0], hi[0], lo[1], hi[1]) = (0, 19, 20, 40);
        vm.expectRevert(IPitBook.BadParams.selector);
        book.packMenu(lo, hi);
        (lo[1], hi[1]) = (21, 20);
        vm.expectRevert(IPitBook.BadParams.selector);
        book.packMenu(lo, hi);
        p.menu = PitMath.pack(lo, hi);
        vm.prank(owner);
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        // one band is a run; so are the whole ladder, two equal runs, and runs that overlap or leave gaps
        (lo[0], hi[0], lo[1], hi[1]) = (7, 7, 0, 39);
        assertTrue(PitMath.validMenu(book.packMenu(lo, hi)));
        (lo[0], hi[0], lo[1], hi[1]) = (5, 9, 5, 9);
        assertTrue(PitMath.validMenu(book.packMenu(lo, hi)));
        assertTrue(PitMath.validMenu(Menus.gappy()));

        // nothing may sit above the last product
        uint256 dirty = Menus.pairOnly() | (uint256(1) << (8 + 16 * 2));
        assertFalse(PitMath.validMenu(dirty));
        p.menu = dirty;
        vm.prank(owner);
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        assertFalse(PitMath.validMenu(Menus.pairOnly() | (uint256(1) << 255)));
    }

    function testFuzz_menu_packAndReadBack(uint256 seed) public pure {
        uint256 n = 2 + seed % 11;
        uint8[] memory lo = new uint8[](n);
        uint8[] memory hi = new uint8[](n);
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint8 a = uint8(seed % 40);
            uint8 b = uint8((seed >> 8) % 40);
            (lo[i], hi[i]) = a < b ? (a, b) : (b, a);
        }
        uint256 menu = PitMath.pack(lo, hi);
        assertTrue(PitMath.validMenu(menu));
        assertEq(PitMath.count(menu), n);
        uint256[12] memory supply;
        for (uint256 i; i < n; ++i) {
            (uint8 a, uint8 b) = PitMath.run(menu, i);
            assertEq(a, lo[i]);
            assertEq(b, hi[i]);
            supply[i] = uint256(keccak256(abi.encode(seed, i))) % 1e24;
        }
        // nothing above the last product
        for (uint256 i = n; i < 12; ++i) {
            (uint8 a, uint8 b) = PitMath.run(menu, i);
            assertEq(uint256(a) + b, 0);
        }
        // winners and the worst band, against a band-by-band count
        uint256 worst;
        for (uint8 j; j < 40; ++j) {
            uint256 payout;
            uint16 mask;
            for (uint256 i; i < n; ++i) {
                if (lo[i] <= j && j <= hi[i]) {
                    payout += supply[i];
                    mask |= uint16(1 << i);
                }
            }
            assertEq(PitMath.winners(menu, j), mask);
            assertEq(PitMath.payoutOf(supply, mask), payout);
            if (payout > worst) worst = payout;
        }
        assertEq(PitMath.maxPayout(supply, menu), worst);
    }

    /// @dev The token and the lens compute a product's price range with `PitMath.edge`; the hook settles
    ///      on the engine's `bandOf`. The two must use the same edges, to the wei.
    function testFuzz_menu_edgesAreTheEngines(uint256 sigma, uint8 m) public {
        LadderMath real = new LadderMath();
        sigma = bound(sigma, 0.005e18, 0.15e18);
        m = uint8(bound(m, 0, 38));
        assertEq(PitMath.edge(sigma, m), real.edge(sigma, m));
        assertEq(PitMath.edge(sigma, m), math.edge(sigma, m), "and the mock's");
        assertEq(real.bandOf(sigma, PitMath.edge(sigma, m)), m + 1, "an edge belongs to the band above it");
        assertEq(real.bandOf(sigma, PitMath.edge(sigma, m) - 1), m);
    }

    // --------------------------------------------------------------------------------------------
    // the owner's menu: 24 hours ahead, frozen in a round
    // --------------------------------------------------------------------------------------------

    function test_menu_ownerChange_waits24Hours_andNeverReachesAnOpenRound() public {
        IPitBook.Params memory p = book.defaultParams();
        p.menu = Menus.sixFloorsAndPair();
        p.floorCapBps = 500;
        p.minPriceWad = 0.05e18;
        vm.prank(alice);
        vm.expectRevert(IPitBook.OnlyOwner.selector);
        book.setDefaultParams(p);
        vm.prank(owner);
        book.setDefaultParams(p);
        (IPitBook.Params memory pending, uint64 eta) = book.pendingDefaultParams();
        assertEq(pending.menu, Menus.sixFloorsAndPair());
        assertEq(eta, clock + 24 hours);
        assertEq(book.defaultParams().menu, book.DEFAULT_MENU(), "not yet");

        // Tuesday's round opens before the 24 hours are over: on the old menu, cap and minimum price
        _open();
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(c.params.menu, book.DEFAULT_MENU());
        assertEq(c.params.floorCapBps, 10_000, "the default: no product cap");
        assertEq(c.params.minPriceWad, 0.02e18);
        assertEq(PitMath.count(c.params.menu), 10);

        // the day passes; the new menu is in force, and the open round keeps its own
        _buy(alice, F7, 1_000e18, S0);
        _closeAndFinalize(S0);
        assertEq(book.defaultParams().menu, book.DEFAULT_MENU(), "23 hours 59 minutes: still not");
        _warp(clock + 60);
        assertEq(book.defaultParams().menu, Menus.sixFloorsAndPair());
        assertEq(hook.getConfig(roundId).params.menu, book.DEFAULT_MENU());
        bytes32 tuesday = roundId;
        day += 1;
        roundId = hook.openRound(NVDA, address(chip), day);
        c = hook.getConfig(roundId);
        assertEq(c.params.menu, Menus.sixFloorsAndPair());
        assertEq(c.params.floorCapBps, 500);
        assertEq(c.params.minPriceWad, 0.05e18);
        Ticket[12] memory tokens = ticketsOf(hook, roundId);
        for (uint256 i; i < 12; ++i) {
            assertEq(tokens[i].id != 0, i < 8, "eight products, eight tickets");
        }
        // the two rounds have their own tickets
        assertTrue(tokens[0].id != ticketsOf(hook, tuesday)[0].id);
        assertEq(tokens[7].id, _predictToken(house, day, 7).id);
    }

    // --------------------------------------------------------------------------------------------
    // tokens of other menus
    // --------------------------------------------------------------------------------------------

    function test_menu_tokenNames_everyShapeOfRun() public {
        uint8[2][] memory r = new uint8[2][](8);
        r[0] = [0, 39]; // the whole ladder
        r[1] = [0, 19]; // exactly the lower half: LOWER
        r[2] = [20, 39]; // exactly the upper half: HIGHER
        r[3] = [0, 15]; // reaches the bottom, not a half
        r[4] = [24, 39]; // reaches the top, not a half
        r[5] = [19, 19]; // one band
        r[6] = [0, 20]; // reaches the bottom, one band more than a half
        r[7] = [19, 39]; // reaches the top, one band more than a half
        _setMenu(Menus.pack(r));
        _open();
        // a ticket has no name of its own: the lens tells the run and its prices; the id is the round id
        // and the index
        Ticket[12] memory t = ticketsOf(hook, roundId);
        uint256 menu = hook.getConfig(roundId).params.menu;
        for (uint256 i; i < 8; ++i) {
            (uint8 lo, uint8 hi) = PitMath.run(menu, i);
            assertEq(lo, r[i][0]);
            assertEq(hi, r[i][1]);
            assertEq(t[i].id, _predictToken(house, day, uint8(i)).id);
            assertEq(t[i].id, uint256(roundId) | i);
        }
        (uint256 low0, uint256 high0) = PitMath.bounds(S0, 0.02e18, 0, 39);
        assertEq(low0, 0);
        assertEq(high0, type(uint256).max);
        // a product of the whole ladder always pays: it costs a chip and is not capped
        uint256 cost = _buy(alice, 0, 1_000e18, S0);
        assertGe(cost, 1_000e18);
        // the two products that are one band off a half: 21 bands has no product cap, as 20 has none
        assertFalse(PitMath.capped(0, 20));
        assertFalse(PitMath.capped(19, 39));
        assertTrue(PitMath.capped(0, 18));
        assertTrue(PitMath.capped(21, 39));
    }

    function test_menu_floorTokenMetadata() public {
        _open();
        Ticket memory token = _token(F2);
        assertEq(token.decimals(), 18);
        assertEq(hook.name(token.id), "Fallpit ticket");
        // -1 to -0.5 sigma of 2% from 180: 180 * e^-0.02 to 180 * e^-0.01
        (uint8 lo, uint8 hi) = PitMath.run(hook.getConfig(roundId).params.menu, F2);
        (uint256 low, uint256 high) = PitMath.bounds(S0, 0.02e18, lo, hi);
        assertEq(low, S0 * uint256(FixedPointMathLib.expWad(-0.02e18)) / 1e18);
        assertEq(high, S0 * uint256(FixedPointMathLib.expWad(-0.01e18)) / 1e18);
    }

    // --------------------------------------------------------------------------------------------
    // the product cap and the minimum price (mock engine)
    // --------------------------------------------------------------------------------------------

    function test_cap_isPerProduct_buysOnly_refundsInFull() public {
        // a product cap of a tenth of the capital per floor: the default has no
        // product cap (10000), and this test keeps the mechanism covered at a tenth
        IPitBook.Params memory p = book.defaultParams();
        p.floorCapBps = 1000;
        _setParams(p);
        _open();
        uint256 cap = HOUSE_CAPITAL / 10;
        // alice and bob together fill the floor's cap: the cap is the product's, not a trader's
        for (uint256 i; i < 3; ++i) {
            _buy(alice, F5, 20_000e18, S0);
        }
        _buy(bob, F5, 20_000e18, S0 * 1001 / 1000);
        _buy(bob, F5, 19_999e18, S0 * 1001 / 1000);
        assertEq(_token(F5).totalSupply(), cap - 1e18);
        // one token fits, the next does not
        uint256 before = chip.balanceOf(carol);
        uint256 id = _commitBuy(carol, F5, 1e18 + 1, before);
        uint64 t = router.getCommit(id).fillTs;
        _warp(t);
        bytes memory report = _report(t, S0);
        uint256 keeperBefore = keeper.balance;
        vm.expectEmit(true, true, false, true, address(router));
        emit Refunded(id, carol, RefundReason.ProductCap);
        vm.prank(keeper);
        assertFalse(router.fill(id, report));
        assertEq(chip.balanceOf(carol), before, "the whole escrow came back");
        assertEq(
            keeper.balance - keeperBefore, FILL_FEE, "the filler earned the fill fee of the refused commit"
        );
        assertEq(uint8(router.getCommit(id).status), uint8(IFallpitRouter.CommitStatus.Refunded));
        _buy(carol, F5, 1e18, S0);
        assertEq(_token(F5).totalSupply(), cap, "exactly at the cap");
        (,,,,, RefundReason rejection) = lens.quote(roundId, F5, true, 1e18, S0, clock + 2);
        assertEq(uint8(rejection), uint8(RefundReason.ProductCap));

        // the cap does not reach the other floors, nor the pair over the same bands
        _buy(carol, F4, 20_000e18, S0);
        _buy(carol, F6, 20_000e18, S0);
        for (uint256 i; i < 8; ++i) {
            _buy(carol, HIGHER, 20_000e18, S0);
        }
        assertEq(_token(HIGHER).totalSupply(), 160_000e18, "the pair has no product cap");

        // a sell is never refused for the cap, and makes room for exactly what it took off
        _sell(bob, F5, 10_000e18, S0);
        id = _commitBuy(carol, F5, 10_000e18 + 1, chip.balanceOf(carol));
        assertFalse(_fill(id, S0));
        _buy(carol, F5, 10_000e18, S0);
        assertEq(_token(F5).totalSupply(), cap);
        _assertSupplies();
        _assertHookSolvent(address(chip));
    }

    function test_cap_isAShareOfTheRoundsCapital_andFollowsTheOwnersBps() public {
        IPitBook.Params memory p = book.defaultParams();
        p.floorCapBps = 250; // 2.5% of the capital: 25,000 tokens
        _setParams(p);
        _open();
        _buy(alice, F3, 20_000e18, S0);
        _buy(alice, F3, 5_000e18, S0);
        uint256 id = _commitBuy(alice, F3, 1e18, 1_000e18);
        assertFalse(_fill(id, S0));
        FallpitLens.Market memory m = lens.market(roundId, S0, clock);
        assertEq(m.products[F3].cap, 25_000e18);
        assertEq(m.products[F3].capUsedBps, 10_000);
        assertTrue(m.products[F3].capped);
        assertFalse(m.products[HIGHER].capped);
        assertEq(m.products[HIGHER].cap, type(uint256).max);
        assertEq(m.products[HIGHER].capUsedBps, 0);
    }

    /// @dev With the mock engine a far floor's price is known to be far under two hundredths: a buy is
    ///      charged exactly the minimum price plus fees, a sell gets the engine's (lower) price, and with
    ///      the minimum price switched off the same buy costs what the engine asks.
    function test_minPrice_chargedOnBuysOnly_extraStaysInTheRound() public {
        _open();
        uint256 shares = 10_000e18;
        (uint256 quoted, uint256 fee, uint256 pBefore,,, RefundReason rejection) =
            lens.quote(roundId, F0, true, shares, S0 * 103 / 100, clock + 2);
        assertEq(uint8(rejection), uint8(RefundReason.None));
        assertLt(pBefore, 0.02e18, "the engine asks less than the minimum");
        uint256 minimum = shares * 2 / 100;
        uint256 vegaFee = shares / 10 * math.VEGA() / 1e18;
        assertEq(fee, minimum * 2 / 100 + vegaFee, "the fee is taken on the minimum price");
        assertEq(quoted, minimum + fee);
        uint256 heldBefore = _state().held;
        uint256 cost = _buy(alice, F0, shares, S0 * 103 / 100);
        assertEq(cost, quoted);
        assertEq(_state().held - heldBefore, cost, "all of it is in the round");
        (, uint256[12] memory premium) = hook.getSupplies(roundId);
        assertEq(premium[F0], cost, "and in the token's cost basis");

        // a sell is paid the engine's price, not the minimum
        (uint256 net,,,,,) = lens.quote(roundId, F0, false, shares, S0 * 103 / 100, clock + 2);
        assertLt(net, minimum / 2);
        assertEq(_sell(alice, F0, shares, S0 * 103 / 100), net);

        // a product priced above the minimum is not touched by it
        (uint256 chips, uint256 pairFee, uint256 pairPrice,,,) =
            lens.quote(roundId, HIGHER, true, shares, S0, clock + 2);
        assertGt(pairPrice, 0.3e18);
        assertGt(chips - pairFee, shares * 3 / 10);
    }

    function test_minPrice_zero_switchesItOff() public {
        IPitBook.Params memory p = book.defaultParams();
        p.minPriceWad = 0;
        _setParams(p);
        _open();
        uint256 shares = 10_000e18;
        (uint256 quoted, uint256 fee,,,,) = lens.quote(roundId, F0, true, shares, S0 * 103 / 100, clock + 2);
        assertLt(quoted - fee, shares * 2 / 100, "the engine's own price, under two hundredths");
        assertEq(_buy(alice, F0, shares, S0 * 103 / 100), quoted);
    }

    // --------------------------------------------------------------------------------------------
    // whole rounds on other menus (mock engine)
    // --------------------------------------------------------------------------------------------

    /// @dev One round per menu: every product is bought and partly sold, the close lands in a band, the
    ///      winners are the products over that band, everybody is paid and the books close to the unit.
    function _roundOn(uint256 menu, uint256 closePrice, uint8 band, uint16 winners) internal {
        _setMenu(menu);
        _open();
        uint256 n = PitMath.count(menu);
        assertEq(hook.getConfig(roundId).params.menu, menu);
        uint256 price = S0;
        for (uint8 i; i < n; ++i) {
            price = price * (1000 + i) / 1000;
            _buy(alice, i, 3_000e18 + uint256(i) * 100e18, price);
            _buy(bob, i, 1_500e18, price * 999 / 1000);
            _warp(clock + 300);
        }
        for (uint8 i; i < n; ++i) {
            price = price * 998 / 1000;
            _sell(alice, i, 1_000e18, price);
            _warp(clock + 200);
        }
        _assertSupplies();
        _assertHookSolvent(address(chip));
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        IFallpitHook.RoundState memory open = _state();
        (uint256 worst, uint256 covered) = lens.solvency(roundId);
        assertLe(worst, covered);

        _recordClose(closePrice, TRUSTLESS);
        hook.settleRound(house, day);
        IFallpitHook.RoundState memory settled = _state();
        assertEq(settled.closeBand, band, "band of the close");
        assertEq(settled.winners, winners, "the products over that band");
        uint256 owed;
        for (uint256 i; i < n; ++i) {
            if (winners >> i & 1 == 1) owed += supply[i];
        }
        assertEq(settled.payoutOwed, owed);
        assertLe(owed, worst, "never more than the worst band the round was checked against");
        hook.finalizeRound(house, day);

        uint256 paid;
        address[2] memory users = [alice, bob];
        for (uint256 u; u < 2; ++u) {
            for (uint8 i; i < n; ++i) {
                Ticket memory token = _token(i);
                uint256 balance = token.balanceOf(users[u]);
                if (balance == 0) continue;
                vm.prank(users[u]);
                if (winners >> i & 1 == 0) {
                    vm.expectRevert(IFallpitHook.NotWinner.selector);
                    router.redeem(token.id, balance);
                    continue;
                }
                paid += router.redeem(token.id, balance);
            }
        }
        assertEq(paid, owed, "every winning token paid one chip");
        uint256 fees = hook.collectProtocolFees(address(chip));
        assertEq(fees, open.protocolFees);
        assertEq(
            chip.balanceOf(alice) + chip.balanceOf(bob) + chip.balanceOf(address(vault)) + fees,
            2 * STAKE + HOUSE_CAPITAL,
            "cash conservation"
        );
        assertEq(chip.balanceOf(address(hook)), 0, "nothing stranded");
    }

    function test_round_sixFloorsAndPair() public {
        // up 1.2%: band 22, the floor from +0.5 to +1.5 sigma (index 4) and HIGHER (index 7)
        _roundOn(Menus.sixFloorsAndPair(), S0 * 1012 / 1000, 22, uint16(1 << 4 | 1 << 7));
    }

    function test_round_theSixProductsOfTheFirstVersion() public {
        // up 1.2%: HIGHER@15, HIGHER@19 and LOWER@23 win
        _roundOn(Menus.thresholds(), S0 * 1012 / 1000, 22, uint16(1 | 4 | 32));
    }

    function test_round_pairOnly() public {
        // down 0.5%: band 18, LOWER (index 0)
        _roundOn(Menus.pairOnly(), S0 * 995 / 1000, 18, uint16(1));
    }

    /// @dev A menu that does not partition: the close lands in a band two products share, both are paid.
    function test_round_menuThatDoesNotPartition_overlapBothPaid() public {
        // down 0.3%: band 19, in the floor [15, 19] (index 1) and in the straddle [18, 21] (index 3)
        _roundOn(Menus.gappy(), S0 * 997 / 1000, 19, uint16(1 << 1 | 1 << 3));
    }

    /// @dev The same menu, and the close lands in a band that belongs to no product (above +2.5 sigma):
    ///      nobody wins, every token is worthless, and the house keeps the whole premium.
    function test_round_menuThatDoesNotPartition_gapPaysNobody() public {
        _roundOn(Menus.gappy(), S0 * 106 / 100, 31, 0);
        assertEq(_state().payoutOwed, 0);
        assertGt(chip.balanceOf(address(vault)), HOUSE_CAPITAL, "the house kept every chip of premium");
    }

    function test_round_twelveProducts() public {
        uint8[2][] memory runs = new uint8[2][](12);
        for (uint8 i; i < 12; ++i) {
            runs[i] = [i * 3, i * 3 + 6]; // overlapping runs of seven bands, from 0 to 39
        }
        // up 0.7%: band 21, inside the runs that start at 15, 18 and 21 (indices 5, 6, 7)
        _roundOn(Menus.pack(runs), S0 * 1007 / 1000, 21, uint16(1 << 5 | 1 << 6 | 1 << 7));
    }

    // --------------------------------------------------------------------------------------------
    // the lens: a round's whole menu in one call
    // --------------------------------------------------------------------------------------------

    function test_lens_market_theWholeMenuInOneCall() public {
        _open();
        _buy(alice, F4, 5_000e18, S0);
        _buy(bob, HIGHER, 2_000e18, S0);
        _buy(bob, F7, 1_000e18, S0);
        FallpitLens.Market memory m = lens.market(roundId, S0, clock);
        assertEq(uint8(m.status), uint8(IFallpitHook.Status.Open));
        assertTrue(m.tradable);
        (uint256 rho,) = lens.clockAt(roundId, clock);
        assertEq(m.rho, rho);
        assertEq(m.feeRate, 0.02e18);
        assertEq(m.s0, S0);
        assertEq(m.sigma, 0.02e18);
        assertEq(m.capital, HOUSE_CAPITAL);
        assertEq(m.maxFill, HOUSE_CAPITAL / 50);
        assertEq(m.minShares, 1e18);
        assertEq(m.minPrice, 0.02e18);
        assertEq(m.fillFee, FILL_FEE);
        (uint256 cushion, uint256 floor) = lens.lossLimit(roundId);
        assertEq(m.cushion, cushion);
        assertEq(m.floor, floor);

        assertEq(m.products.length, 10);
        Ticket[12] memory tokens = ticketsOf(hook, roundId);
        (uint256[12] memory supply, uint256[12] memory premium) = hook.getSupplies(roundId);
        uint256 floorsSum;
        for (uint256 i; i < 10; ++i) {
            FallpitLens.Product memory q = m.products[i];
            assertEq(q.id, tokens[i].id);
            (uint8 lo, uint8 hi) = PitMath.run(hook.getConfig(roundId).params.menu, i);
            assertEq(q.lo, lo);
            assertEq(q.hi, hi);
            (uint256 low, uint256 high) = PitMath.bounds(S0, 0.02e18, lo, hi);
            assertEq(q.low, low, "the product's price range");
            assertEq(q.high, high);
            assertEq(q.supply, supply[i]);
            assertEq(q.premium, premium[i]);
            assertEq(q.capped, i < 8);
            // the default product cap is off (10000): a floor's
            // cap is the whole capital, the pair has none
            assertEq(q.cap, i < 8 ? HOUSE_CAPITAL : type(uint256).max);
            assertEq(q.capUsedBps, i < 8 ? supply[i] * 10_000 / HOUSE_CAPITAL : 0);
            assertFalse(q.won);
            // dead: the engine prices the product under the minimum price, so the multiple shown is the
            // minimum price's, not the odds
            assertEq(q.dead, q.price < 0.02e18, "dead when the engine's price is under the minimum");
            // the price is the one a quote for the same print starts from
            (,, uint256 pBefore,,,) = lens.quote(roundId, uint8(i), true, 1e18, S0, clock);
            assertApproxEqAbs(q.price, pBefore, 1e6, "the price before a trade");
            assertEq(q.buyPrice, q.price > 0.02e18 ? q.price : 0.02e18);
            assertEq(q.multiple, 1e36 / q.buyPrice);
            if (i < 8) floorsSum += q.price;
        }
        assertEq(m.products[F4].capUsedBps, 50, "5,000 of 1,000,000");
        assertEq(m.products[F7].buyPrice, 0.02e18, "the far floor sits at the minimum price");
        assertEq(m.products[F7].multiple, 50e18, "which caps what a token can pay at 50 times its price");
        assertTrue(m.products[F7].dead, "and the lens says so: an app greys it out");
        assertFalse(m.products[F4].dead);
        assertFalse(m.products[HIGHER].dead);
        // the floors partition the ladder: their prices sum to one, and so do the pair's
        assertApproxEqAbs(floorsSum, 1e18, 1e9);
        assertApproxEqAbs(m.products[LOWER].price + m.products[HIGHER].price, 1e18, 1e9);
        // what the round owes in every band
        uint256[40] memory payout = lens.payouts(roundId);
        assertEq(payout[20], 5_000e18 + 2_000e18, "the floor and HIGHER over it");
        assertEq(payout[22], 2_000e18);
        assertEq(payout[30], 2_000e18 + 1_000e18);
        assertEq(payout[19], 0);
        (uint256 worst,) = lens.solvency(roundId);
        assertEq(worst, 7_000e18);

        // outside the trading windows the prices are still shown, and the flag says so
        m = lens.market(roundId, S0, NYTime.at(day0, 21 hours));
        assertFalse(m.tradable);
        assertGt(m.products[HIGHER].price, 0);

        // settled: the winners are marked; at and after the close nothing is priced
        _recordClose(S0 * 1002 / 1000, TRUSTLESS);
        hook.settleRound(house, day);
        m = lens.market(roundId, S0, clock);
        assertEq(uint8(m.status), uint8(IFallpitHook.Status.Settled));
        assertFalse(m.tradable);
        for (uint256 i; i < 10; ++i) {
            assertEq(m.products[i].won, i == F4 || i == HIGHER);
            assertEq(m.products[i].price + m.products[i].buyPrice + m.products[i].multiple, 0);
            assertFalse(m.products[i].dead, "nothing priced, nothing dead");
        }
        // an unknown round: an empty menu, nothing reverts
        m = lens.market(bytes32(uint256(1)), S0, clock);
        assertEq(m.products.length, 0);
        assertEq(uint8(m.status), uint8(IFallpitHook.Status.None));
        // a quote for a product the menu does not have
        vm.expectRevert(FallpitLens.UnknownProduct.selector);
        lens.quote(roundId, 10, true, 1e18, S0, clock);
        vm.expectRevert(FallpitLens.UnknownProduct.selector);
        lens.quote(roundId, 200, true, 1e18, S0, clock);
    }
}
