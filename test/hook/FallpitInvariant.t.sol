// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {HookFixture} from "./HookFixture.sol";
import {MockChip} from "./mocks/MockChips.sol";
import {MockPitOracle} from "./mocks/MockPitOracle.sol";
import {RevertingFiller} from "./mocks/Fillers.sol";
import {FallpitHook} from "../../src/FallpitHook.sol";
import {FallpitRouter} from "../../src/FallpitRouter.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {PitMath} from "../../src/hook/PitMath.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {Menus} from "../Menus.sol";

/// @notice Drives one open round with random commits, fills, refunds, time and oracle moves, and keeps
///         ghost totals of what traders paid in and took out. Commits carry the fill fee; they are filled
///         in turn by an account that takes the fee (`keeper`), by this contract and by `grump`, neither
///         of which can receive native coin, so their fees wait in the router until `claim`. The round can
///         have any menu: the handler trades whatever products it has, the live strikes it opens included.
contract PitHandler is Test {
    bytes32 internal constant NVDA = bytes32("NVDA");
    uint8 internal constant KEEPER = 2;
    uint256 internal constant FILL_FEE = 0.000025 ether;
    uint256 public constant ACTOR_ETH = 10 ether;

    FallpitRouter public immutable router;
    FallpitHook public immutable hook;
    MockPitOracle public immutable oracle;
    MockChip public immutable chip;
    bytes32 public immutable roundId;
    uint64 public immutable cutoff;
    uint256 public immutable s0;
    /// @dev Number of products of the round (its menu and the strikes opened so far), and the round's
    ///      minimum price per token.
    uint8 public products;
    uint256 public immutable minPrice;

    address[4] public actors;
    /// @dev Fillers: an EOA, and a contract whose `receive` reverts (this contract, which has no
    ///      `receive` at all, is the third). `sink` is where unclaimed fees are pulled to.
    address public constant keeper = address(0xF111E4);
    address public constant sink = address(0x51CC);
    RevertingFiller public immutable grump;
    uint64 public clock;
    uint256 public price;
    uint256 public lastG = 1e18;

    // ghosts
    uint256 public paidIn;
    uint256 public paidOut;
    uint256 public pendingChipEscrow;
    uint256 public fills;
    uint256 public refunds;
    uint256 public sells;
    uint256 public feesEarned;
    uint256 public feesClaimed;
    uint256 public strikes;
    uint256[] public abandoned;
    mapping(uint64 ts => bytes) internal _reports;
    /// @dev every posted print, in order, and its price: a late strike picks one of them
    uint64[] internal _posted;
    mapping(uint64 ts => uint256) internal _postedPrice;

    constructor(
        FallpitRouter router_,
        FallpitHook hook_,
        MockPitOracle oracle_,
        MockChip chip_,
        bytes32 roundId_,
        uint64 clock_,
        uint256 s0_
    ) {
        router = router_;
        hook = hook_;
        oracle = oracle_;
        chip = chip_;
        roundId = roundId_;
        clock = clock_;
        s0 = s0_;
        price = s0_;
        grump = new RevertingFiller(router_);
        IFallpitHook.RoundConfig memory c = hook_.getConfig(roundId_);
        cutoff = c.cutoff;
        products = uint8(PitMath.count(c.params.menu));
        minPrice = c.params.minPriceWad;
        Ticket[15] memory tokens = ticketsOf(hook_, roundId_);
        for (uint256 i; i < 4; ++i) {
            address actor = address(uint160(0xA11CE000 + i));
            actors[i] = actor;
            chip_.mint(actor, 500_000e18);
            vm.deal(actor, ACTOR_ETH);
            vm.startPrank(actor);
            chip_.approve(address(router_), type(uint256).max);
            for (uint256 k; k < products; ++k) {
                tokens[k].approve(address(router_), type(uint256).max);
            }
            vm.stopPrank();
        }
    }

    function abandonedCount() external view returns (uint256) {
        return abandoned.length;
    }

    /// @dev Time passes and the oracle moves by up to 1% either way, inside +-15% of the previous close.
    function tick(uint256 dt, uint256 drift) public {
        dt = bound(dt, 0, 900);
        drift = bound(drift, 0, 200);
        if (clock + dt + 4 > cutoff) return;
        clock += uint64(dt);
        vm.warp(clock);
        uint256 next = price * (9900 + drift) / 10_000;
        if (next > s0 * 85 / 100 && next < s0 * 115 / 100) price = next;
    }

    function buy(uint256 actorSeed, uint8 index, uint256 shares, uint256 limitSeed, uint256 dt, uint256 drift)
        external
    {
        tick(dt, drift);
        if (clock + 4 > cutoff) return;
        (shares, limitSeed) = _mix(shares, limitSeed);
        address actor = actors[actorSeed % 4];
        index = index % products;
        // sometimes the smallest trade (one token), sometimes above the 20k cap
        shares = limitSeed % 7 == 0 ? bound(shares, 1e18, 1e18 + 1000) : bound(shares, 1e18, 20_500e18);
        uint256 balance = chip.balanceOf(actor);
        if (balance == 0) return;
        // one commit in eight carries a random (often too low) limit
        uint256 limit = limitSeed % 8 == 0 ? bound(limitSeed, 1, balance) : balance;

        vm.prank(actor);
        uint256 id = router.commit{value: FILL_FEE}(roundId, index, true, shares, limit);
        bool filled = _fill(id);
        uint256 spent = balance - chip.balanceOf(actor);
        if (filled) {
            paidIn += spent;
            ++fills;
            assertGe(spent * 1e18, shares * minPrice, "a buy pays at least the minimum price per token");
        } else {
            assertEq(spent, 0, "a refunded buy costs nothing");
            ++refunds;
        }
    }

    function sell(
        uint256 actorSeed,
        uint8 index,
        uint256 shares,
        uint256 limitSeed,
        uint256 dt,
        uint256 drift
    ) external {
        tick(dt, drift);
        if (clock + 4 > cutoff) return;
        (shares, limitSeed) = _mix(shares, limitSeed);
        address actor = actors[actorSeed % 4];
        // the first token at or after `index` that the actor holds
        Ticket memory token;
        uint256 held;
        {
            Ticket[15] memory tokens = ticketsOf(hook, roundId);
            for (uint8 k; k < products && held == 0; ++k) {
                index = (index + (k == 0 ? 0 : 1)) % products;
                token = tokens[index];
                held = token.balanceOf(actor);
            }
        }
        if (held < 1e18) return;
        shares = bound(shares, 1e18, held);
        uint256 balance = chip.balanceOf(actor);
        uint256 id;
        {
            uint256 limit = limitSeed % 8 == 0 ? bound(limitSeed, 0, shares) : 0;
            vm.prank(actor);
            id = router.commit{value: FILL_FEE}(roundId, index, false, shares, limit);
        }
        bool filled = _fill(id);
        uint256 got = chip.balanceOf(actor) - balance;
        if (filled) {
            paidOut += got;
            ++fills;
            ++sells;
            assertEq(token.balanceOf(actor), held - shares);
        } else {
            assertEq(got, 0);
            assertEq(token.balanceOf(actor), held, "a refunded sell returns the tokens");
            ++refunds;
        }
    }

    /// @dev Opens the live strike at the oracle's price now, when the rules allow (anyone may). Only the
    ///      strike rules may refuse it: too early, too close to the pair or an open strike, no room.
    function strike(uint256 dt, uint256 drift) external {
        tick(dt, drift);
        if (clock + 4 > cutoff || _reports[clock].length != 0) return;
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        uint8 m = PitMath.nearestEdge(
            c.sigma, FixedPointMathLib.lnWad(int256(FixedPointMathLib.divWad(price, c.s0)))
        );
        bytes memory report = _post(clock);
        try hook.openStrike(roundId, m, clock, report) {
            ++strikes;
            products = uint8(PitMath.count(hook.getConfig(roundId).params.menu));
        } catch (bytes memory err) {
            bytes4 why = bytes4(err);
            assertTrue(
                why == IFallpitHook.StrikeTooEarly.selector || why == IFallpitHook.StrikeTooClose.selector
                    || why == IFallpitHook.StrikeNotPinned.selector
                    || why == IFallpitHook.StrikeNoRoom.selector,
                "only the strike rules refuse a strike"
            );
        }
    }

    /// @dev Opens a strike with the print of an earlier instant (any posted print of the last two minutes, at
    ///      the price it had), sometimes on a wrong edge. Only the strike rules, the edge rule and the
    ///      instant's age may refuse it, and one that opens used an instant at most STRIKE_MAX_LAG old.
    function strikeLate(uint256 dt, uint256 drift, uint256 pick, uint256 wrong) external {
        tick(dt, drift);
        uint256 n = _posted.length;
        if (n == 0 || clock + 4 > cutoff) return;
        uint64 t = _posted[n - 1 - bound(pick, 0, n - 1 < 8 ? n - 1 : 8)];
        if (clock - t > 120) return;
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        uint8 m = PitMath.nearestEdge(
            c.sigma, FixedPointMathLib.lnWad(int256(FixedPointMathLib.divWad(_postedPrice[t], c.s0)))
        );
        wrong = wrong % 4;
        if (wrong == 1 && m < PitMath.LAST_EDGE) ++m;
        else if (wrong == 2 && m > 0) --m;
        try hook.openStrike(roundId, m, t, _reports[t]) {
            ++strikes;
            products = uint8(PitMath.count(hook.getConfig(roundId).params.menu));
            assertLe(clock - t, PitMath.STRIKE_MAX_LAG, "a strike opens only on a recent instant");
            assertLe(clock - t, c.params.refundDelay);
        } catch (bytes memory err) {
            bytes4 why = bytes4(err);
            assertTrue(
                why == IFallpitHook.StrikeTooEarly.selector || why == IFallpitHook.StrikeTooClose.selector
                    || why == IFallpitHook.StrikeNotPinned.selector
                    || why == IFallpitHook.StrikeNoRoom.selector || why == IFallpitHook.StrikeEdge.selector
                    || why == IFallpitHook.FillExpired.selector || why == IFallpitHook.StrikeWindow.selector,
                "only the strike rules, the edge and the instant's age refuse a late strike"
            );
            if (why == IFallpitHook.FillExpired.selector) {
                assertGt(
                    clock - t,
                    PitMath.STRIKE_MAX_LAG < c.params.refundDelay
                        ? PitMath.STRIKE_MAX_LAG
                        : c.params.refundDelay
                );
            }
        }
    }

    /// @dev Posts the oracle's print of `t` at the current price and keeps it.
    function _post(uint64 t) internal returns (bytes memory report) {
        report = oracle.post(NVDA, KEEPER, price, t);
        _reports[t] = report;
        _posted.push(t);
        _postedPrice[t] = price;
    }

    /// @dev A commit nobody fills: its escrow sits in the router until `refundStale`.
    function abandon(uint256 actorSeed, uint8 index, uint256 shares) external {
        if (clock + 4 > cutoff) return;
        address actor = actors[actorSeed % 4];
        shares = bound(shares, 1e18, 1_000e18);
        uint256 balance = chip.balanceOf(actor);
        if (balance < 2_000e18) return;
        vm.prank(actor);
        uint256 id = router.commit{value: FILL_FEE}(roundId, index % products, true, shares, 2_000e18);
        abandoned.push(id);
        pendingChipEscrow += 2_000e18;
        // a round's commits fill in commit order: the next trade comes once this one's window is over, so
        // this one (never filled) does not hold it
        IFallpitRouter.Commit memory c = router.getCommit(id);
        clock = c.fillTs + c.refundDelay + 1;
        vm.warp(clock);
    }

    function refundStale(uint256 seed) external {
        if (abandoned.length == 0) return;
        uint256 slot = seed % abandoned.length;
        uint256 id = abandoned[slot];
        IFallpitRouter.Commit memory c = router.getCommit(id);
        if (clock <= c.fillTs + c.refundDelay) return;
        router.refund(id);
        pendingChipEscrow -= c.escrow;
        abandoned[slot] = abandoned[abandoned.length - 1];
        abandoned.pop();
    }

    /// @dev A filler that could not be paid in the call pulls what the router holds for it.
    function claim(uint256 seed) external {
        if (seed % 2 == 0) {
            uint256 owed = router.ethOwed(address(this));
            if (owed == 0) return;
            assertEq(router.claimEth(sink), owed);
            feesClaimed += owed;
        } else {
            uint256 owed = router.ethOwed(address(grump));
            if (owed == 0) return;
            assertEq(grump.claim(sink), owed);
            feesClaimed += owed;
        }
    }

    /// @dev Hashes the fuzzer's inputs so its bias towards 0 and max does not decide the branches.
    function _mix(uint256 a, uint256 b) internal pure returns (uint256, uint256) {
        return
            (
                uint256(keccak256(abi.encode(a, b, uint256(1)))),
                uint256(keccak256(abi.encode(a, b, uint256(2))))
            );
    }

    function _fill(uint256 id) internal returns (bool filled) {
        uint64 t = router.getCommit(id).fillTs;
        if (clock < t) {
            clock = t;
            vm.warp(t);
        }
        bytes memory report = _reports[t];
        if (report.length == 0) report = _post(t);
        // whoever fills is paid the commit's fee, whether the fill trades or refunds
        uint256 turn = id % 3;
        if (turn == 0) {
            uint256 before = keeper.balance;
            vm.prank(keeper);
            filled = router.fill(id, report);
            assertEq(keeper.balance - before, FILL_FEE, "the filler was paid in the call");
        } else {
            address filler = turn == 1 ? address(this) : address(grump);
            uint256 before = router.ethOwed(filler);
            filled = turn == 1 ? router.fill(id, report) : grump.fill(id, report);
            assertEq(router.ethOwed(filler) - before, FILL_FEE, "a fee that cannot be delivered is owed");
        }
        feesEarned += FILL_FEE;
        uint256 g = hook.getState(roundId).g;
        assertLe(g, lastG, "depth never rises during a round");
        assertGe(g, 0.3e18);
        lastG = g;
    }
}

/// @notice Stateful fuzz of one round: solvency, supply accounting, the product caps, claims, escrow and
///         conservation hold after every call, and the round then settles and pays out to the unit.
/// @dev This contract runs the book's default menu. The contracts below it run the same campaign on other
///      menus: six floors and the pair, the six-product threshold menu, a menu that does not
///      partition the ladder, and menus drawn at random.
contract FallpitInvariantTest is HookFixture {
    PitHandler internal handler;
    uint256 internal totalChips;
    uint256 internal menu;

    /// @dev The menu of the round under test.
    function _menu() internal view virtual returns (uint256) {
        return book.DEFAULT_MENU();
    }

    function setUp() public override {
        super.setUp();
        menu = _menu();
        _setMenu(menu);
        _open();
        assertEq(hook.getConfig(roundId).params.menu, menu);
        handler = new PitHandler(router, hook, oracle, chip, roundId, clock, S0);
        totalChips = HOUSE_CAPITAL + 4 * 500_000e18;

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = PitHandler.buy.selector;
        selectors[1] = PitHandler.sell.selector;
        selectors[2] = PitHandler.buy.selector;
        selectors[3] = PitHandler.abandon.selector;
        selectors[4] = PitHandler.refundStale.selector;
        selectors[5] = PitHandler.claim.selector;
        selectors[6] = PitHandler.strike.selector;
        selectors[7] = PitHandler.strikeLate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Runs with fail-on-revert: the handler asserts in line (who was paid the fill fee, what a
    ///      refund returns, that depth never rises), and a call that reverts must fail the run instead of
    ///      being discarded.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_roundStaysSolventAndConserved() public view {
        IFallpitHook.RoundState memory st = _state();
        (uint256[15] memory supply, uint256[15] memory premium) = hook.getSupplies(roundId);
        Ticket[15] memory tokens = ticketsOf(hook, roundId);

        // the round's menu: the one it opened with, then the strikes opened since, in pairs on one edge
        uint256 live = hook.getConfig(roundId).params.menu;
        _assertStrikes(live);
        // pooled solvency: the worst band's payout plus the protocol's fees is covered. The worst band is
        // recomputed here band by band, without the hook's difference array.
        uint256 n = PitMath.count(live);
        uint256 worst;
        for (uint256 j; j < 40; ++j) {
            uint256 payout;
            for (uint256 i; i < n; ++i) {
                (uint8 lo, uint8 hi) = PitMath.run(live, i);
                if (lo <= j && j <= hi) payout += supply[i];
            }
            if (payout > worst) worst = payout;
        }
        assertEq(PitMath.maxPayout(supply, live), worst, "the worst band, counted directly");
        assertLe(worst + st.protocolFees, st.held, "solvency");

        // the token is the claim: totalSupply equals the outstanding supply the hook uses
        uint256 costBasis;
        for (uint256 i = n; i < MAX_PRODUCTS; ++i) {
            assertEq(tokens[i].id, 0, "no token above the menu");
            assertEq(supply[i] + premium[i], 0, "no supply above the menu");
        }
        for (uint256 i; i < n; ++i) {
            {
                // a floor never has more than its product cap outstanding (the whole capital at the
                // default of 10000: the cap is off by default)
                (uint8 lo, uint8 hi) = PitMath.run(live, i);
                uint256 capBps = hook.getConfig(roundId).params.floorCapBps;
                if (uint256(hi) - lo + 1 < 20) {
                    assertLe(supply[i] * 10_000, HOUSE_CAPITAL * capBps, "product cap");
                }
            }
            assertEq(tokens[i].totalSupply(), supply[i], "totalSupply equals outstanding");
            assertEq(
                tokens[i].balanceOf(address(router)), router.escrowedTickets(tokens[i].id), "token escrow"
            );
            if (supply[i] == 0) assertEq(premium[i], 0, "no cost basis without supply");
            costBasis += premium[i];
        }
        assertLe(costBasis, handler.paidIn(), "cost basis never exceeds what was paid");

        // no value created: the round holds exactly the capital plus what traders paid minus what they took
        assertEq(
            st.held, HOUSE_CAPITAL + handler.paidIn() - handler.paidOut(), "held is capital plus net premium"
        );
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, owed, "claims equal what the hook owes");
        assertEq(owed, st.held);
        assertEq(chip.balanceOf(address(pm)), 0, "nothing in the PoolManager");

        // escrow and global conservation
        assertEq(chip.balanceOf(address(router)), router.escrowed(address(chip)), "chip escrow");
        assertEq(router.escrowed(address(chip)), handler.pendingChipEscrow());
        uint256 sum =
            chip.balanceOf(address(hook)) + chip.balanceOf(address(router)) + chip.balanceOf(address(vault));
        for (uint256 i; i < 4; ++i) {
            sum += chip.balanceOf(handler.actors(i));
        }
        assertEq(sum, totalChips, "chips are conserved");

        // native coin. The router holds exactly the fill fees of the pending commits plus the fees it
        // could not deliver, and every wei the traders attached is accounted for.
        uint256 unclaimed = router.ethOwed(address(handler)) + router.ethOwed(address(handler.grump()));
        assertEq(
            address(router).balance,
            handler.abandonedCount() * FILL_FEE + unclaimed,
            "router ETH is pending fees plus unclaimed fees"
        );
        assertEq(address(handler).balance + address(handler.grump()).balance, 0);
        assertEq(address(hook).balance, 0);
        assertEq(
            handler.keeper().balance + handler.sink().balance + unclaimed,
            handler.feesEarned(),
            "every fee earned is with its filler, claimed, or owed"
        );
        assertEq(handler.sink().balance, handler.feesClaimed());
        uint256 eth = address(router).balance + handler.keeper().balance + handler.sink().balance;
        for (uint256 i; i < 4; ++i) {
            eth += handler.actors(i).balance;
        }
        assertEq(eth, 4 * handler.ACTOR_ETH(), "native coin is conserved");
    }

    /// @dev The round's live menu is the menu it opened with, then pairs `[0, m]`, `[m + 1, 39]` with each m
    ///      at least two edges from 19 and from the others.
    function _assertStrikes(uint256 live) internal view {
        uint256 base = PitMath.strikeFrom(live);
        assertEq(base, PitMath.count(menu), "the strikes come after the menu");
        for (uint256 i; i < base; ++i) {
            (uint8 a, uint8 b) = PitMath.run(live, i);
            (uint8 c, uint8 d) = PitMath.run(menu, i);
            assertEq(a, c, "the menu is kept");
            assertEq(b, d, "the menu is kept");
        }
        uint256 n = PitMath.count(live);
        assertLe(n, 15);
        assertEq((n - base) % 2, 0, "strikes come in pairs");
        for (uint256 i = base; i < n; i += 2) {
            (uint8 lo, uint8 m) = PitMath.run(live, i);
            (uint8 lo2, uint8 hi2) = PitMath.run(live, i + 1);
            assertEq(lo, 0);
            assertEq(lo2, m + 1);
            assertEq(hi2, 39);
            assertGe(m > 19 ? m - 19 : 19 - m, 2, "two edges from the pair");
            for (uint256 k = base; k < i; k += 2) {
                (, uint8 other) = PitMath.run(live, k);
                assertGe(m > other ? m - other : other - m, 2, "two edges from another strike");
            }
        }
    }

    /// @dev After the random session: close at wherever the oracle ended, settle, finalize, refund what
    ///      is pending, redeem everything, collect fees. The books must close to the unit.
    function afterInvariant() public virtual {
        uint256 closePrice = handler.price();
        clock = handler.clock();
        emit log_named_uint("fills", handler.fills());
        emit log_named_uint("sells", handler.sells());
        emit log_named_uint("refunds", handler.refunds());
        emit log_named_uint("abandoned", handler.abandonedCount());
        emit log_named_decimal_uint("paidIn", handler.paidIn(), 18);
        emit log_named_decimal_uint("paidOut", handler.paidOut(), 18);
        emit log_named_uint("strikes", handler.strikes());
        (uint256[15] memory supply,) = hook.getSupplies(roundId);
        IFallpitHook.RoundState memory open = _state();
        uint256 live = hook.getConfig(roundId).params.menu;

        _closeAndFinalize(closePrice);
        IFallpitHook.RoundState memory fin = _state();
        assertEq(fin.payoutOwed, PitMath.payoutOf(supply, fin.winners));
        assertEq(fin.winners, PitMath.winners(live, fin.closeBand), "the products whose run holds the close");
        emit log_named_uint("products", PitMath.count(live));
        emit log_named_uint("close band", fin.closeBand);
        emit log_named_uint("winners (bit mask)", fin.winners);
        uint256 vaultBack = chip.balanceOf(address(vault));
        assertEq(vaultBack, open.held - fin.payoutOwed - open.protocolFees);

        Ticket[15] memory tokens = ticketsOf(hook, roundId);
        uint256 redeemed;
        for (uint256 a; a < 4; ++a) {
            address actor = handler.actors(a);
            for (uint256 i; i < PitMath.count(live); ++i) {
                uint256 balance = tokens[i].balanceOf(actor);
                if (balance == 0 || fin.winners >> i & 1 == 0) continue;
                vm.prank(actor);
                redeemed += router.redeem(tokens[i].id, balance);
            }
        }
        assertEq(redeemed, fin.payoutOwed, "every winning token was paid one chip");
        uint256 fees = hook.collectProtocolFees(address(chip));
        assertEq(fees, open.protocolFees);
        for (uint256 i = handler.abandonedCount(); i > 0; --i) {
            router.refund(handler.abandoned(i - 1));
        }
        // with nothing pending the router holds only what it owes; once claimed, nothing
        emit log_named_decimal_uint("fill fees earned (ETH)", handler.feesEarned(), 18);
        emit log_named_decimal_uint(
            "of which could not be delivered and were claimed", handler.feesClaimed(), 18
        );
        assertEq(
            address(router).balance,
            router.ethOwed(address(handler)) + router.ethOwed(address(handler.grump()))
        );
        handler.claim(0);
        handler.claim(1);
        assertEq(address(router).balance, 0, "no native coin is left in the router");

        // chips in = chips out + vault return + protocol fees
        assertEq(
            HOUSE_CAPITAL + handler.paidIn(),
            handler.paidOut() + redeemed + vaultBack + fees,
            "cash conservation"
        );
        assertEq(chip.balanceOf(address(hook)), 0, "nothing stranded");
        assertEq(chip.balanceOf(address(router)), 0);
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, 0);
        assertEq(owed, 0);
        uint256 sum = vaultBack + fees;
        for (uint256 i; i < 4; ++i) {
            sum += chip.balanceOf(handler.actors(i));
        }
        assertEq(sum, totalChips);
    }
}

/// @notice The same campaign, then no close is recorded and the round is voided a day after its close, with
///         whatever strikes opened: the house first, then every holder of every product (strikes included)
///         pro rata to its cost, never more than its cost basis, and every chip accounted for.
/// forge-config: default.invariant.runs = 24
contract FallpitInvariantVoidTest is FallpitInvariantTest {
    function afterInvariant() public override {
        emit log_named_uint("strikes", handler.strikes());
        uint256 live = hook.getConfig(roundId).params.menu;
        uint256 n = PitMath.count(live);
        (uint256[15] memory supply, uint256[15] memory premium) = hook.getSupplies(roundId);
        _warp(NYTime.closeTs(day) + 24 hours + 1);
        hook.voidRound(house, day);
        IFallpitHook.RoundState memory v = _state();
        assertEq(uint8(v.status), uint8(IFallpitHook.Status.Void));
        (, uint256[15] memory refund) = hook.getSupplies(roundId);
        for (uint256 i; i < n; ++i) {
            assertLe(refund[i], premium[i], "a product's refund is at most its cost basis");
        }
        uint256 vaultBack = chip.balanceOf(address(vault));

        Ticket[15] memory tokens = ticketsOf(hook, roundId);
        uint256 redeemed;
        uint256[15] memory paidOf;
        for (uint256 a; a < 4; ++a) {
            address actor = handler.actors(a);
            for (uint256 i; i < n; ++i) {
                uint256 balance = tokens[i].balanceOf(actor);
                if (balance == 0) continue;
                vm.prank(actor);
                uint256 paid = router.redeem(tokens[i].id, balance);
                paidOf[i] += paid;
                redeemed += paid;
            }
        }
        for (uint256 i; i < n; ++i) {
            assertLe(paidOf[i], refund[i], "a product's holders share at most its refund");
            if (supply[i] != 0) assertGe(paidOf[i] + 4, refund[i], "and all of it but rounding dust");
        }
        assertLe(redeemed, v.payoutOwed, "never more than the refunds");
        assertLe(v.payoutOwed - redeemed, 4 * n, "the holders get all of it but rounding dust");
        for (uint256 i = handler.abandonedCount(); i > 0; --i) {
            router.refund(handler.abandoned(i - 1));
        }
        uint256 left = chip.balanceOf(address(hook));
        assertEq(
            HOUSE_CAPITAL + handler.paidIn(),
            handler.paidOut() + redeemed + vaultBack + left,
            "cash conservation"
        );
        uint256 sum = vaultBack + left + chip.balanceOf(address(router));
        for (uint256 i; i < 4; ++i) {
            sum += chip.balanceOf(handler.actors(i));
        }
        assertEq(sum, totalChips);
    }
}

/// @notice The same campaign on six floors and the pair.
/// forge-config: default.invariant.runs = 24
contract FallpitInvariantSixFloorsTest is FallpitInvariantTest {
    function _menu() internal pure override returns (uint256) {
        return Menus.sixFloorsAndPair();
    }
}

/// @notice The same campaign on the six-product threshold menu (HIGHER and LOWER at three strikes).
/// forge-config: default.invariant.runs = 24
contract FallpitInvariantThresholdsTest is FallpitInvariantTest {
    function _menu() internal pure override returns (uint256) {
        return Menus.thresholds();
    }
}

/// @notice The same campaign on a menu that does not partition the ladder: some bands belong to no
///         product (a close there pays nobody), some to two.
/// forge-config: default.invariant.runs = 24
contract FallpitInvariantGappyMenuTest is FallpitInvariantTest {
    function _menu() internal pure override returns (uint256) {
        return Menus.gappy();
    }
}

/// @notice The same campaign on a menu drawn at random: 2 to 12 products, each any run of bands. The draw
///         is a function of `SEED`, so a failure can be replayed; the two contracts below draw other menus.
/// forge-config: default.invariant.runs = 24
contract FallpitInvariantRandomMenuTest is FallpitInvariantTest {
    function _seed() internal pure virtual returns (uint256) {
        return 1;
    }

    function _menu() internal pure override returns (uint256) {
        uint256 seed = uint256(keccak256(abi.encode("fallpit menu", _seed())));
        uint256 n = 2 + seed % 11;
        uint8[2][] memory runs = new uint8[2][](n);
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint8 a = uint8(seed % 40);
            uint8 b = uint8((seed >> 8) % 40);
            runs[i] = a < b ? [a, b] : [b, a];
        }
        return Menus.pack(runs);
    }
}

/// forge-config: default.invariant.runs = 24
contract FallpitInvariantRandomMenu2Test is FallpitInvariantRandomMenuTest {
    function _seed() internal pure override returns (uint256) {
        return 2;
    }
}

/// forge-config: default.invariant.runs = 24
contract FallpitInvariantRandomMenu3Test is FallpitInvariantRandomMenuTest {
    function _seed() internal pure override returns (uint256) {
        return 3;
    }
}
