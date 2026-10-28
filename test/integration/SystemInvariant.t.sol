// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Accounting} from "../Accounting.sol";

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";
import {Ticket, ticketsOf, ticketOf} from "../Ticket.sol";
import {PitVault} from "../../src/PitVault.sol";
import {FallpitHook} from "../../src/FallpitHook.sol";
import {FallpitRouter} from "../../src/FallpitRouter.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {PitMath} from "../../src/hook/PitMath.sol";
import {NYTime} from "../../src/lib/NYTime.sol";
import {Menus} from "../Menus.sol";

/// @notice Drives the whole real system: two houses in one chip (NVDA on keeper-signed prints, TSLA on
///         Pyth), four traders on every product of whatever menu a round has, three LPs who deposit,
///         withdraw, cancel and claim at any time, a donor, abandoned commits, and days that roll: closes
///         from either source, trustless replacement, the challenge window, guardian voids, days without a
///         close. A round is opened as soon as the one before it is over and is traded in all three
///         windows of its clock: the after-hours of the day before, the pre-market and the regular
///         session. Every day the owner's menu for the next rounds is drawn again: the default (half the
///         days), six floors and the pair, the six-product threshold menu, a menu that does not
///         partition the ladder, the pair alone, or 2 to 12 runs of bands drawn at random.
/// @dev It owns the deployment (it is the fixture) and keeps ghost totals. Every call must succeed: the
///      invariant test runs with fail-on-revert, so a fill, a queue or a settlement that bricks fails it.
contract SystemHandler is IntegrationFixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant TRADER_STAKE = 500_000e18;
    uint256 internal constant LP_STAKE = 1_500_000e18;
    /// @dev Native coin each trader starts with, for the fill fees of its commits.
    uint256 public constant TRADER_ETH = 10 ether;
    /// @dev Where this contract pulls the fill fees it earned and could not be paid in the call (it has
    ///      no `receive`). The other filler, the keeper, is an EOA and is paid directly.
    address public constant feeSink = address(0x51CC);

    address[4] public traders;
    address[3] public lps;
    address public donor = address(0xD0D0);
    bytes32[2] public tickers;
    bytes32[2] public houses;
    uint256[2] public prices;
    bytes32[] public rounds;
    uint256 public minted;

    // ghosts, per round
    mapping(bytes32 roundId => uint256) public paidIn;
    mapping(bytes32 roundId => uint256) public paidOut;
    mapping(bytes32 roundId => uint256) public redeemed;
    // ghosts, global
    uint256 public pendingChipEscrow;
    uint256 public feesCollected;
    uint256[] public abandoned;
    uint256 public fills;
    uint256 public sells;
    uint256 public refunds;
    uint256 public daysRolled;
    uint256 public voids;
    uint256 public disputes;
    uint256 public keeperCloses;
    uint256 public replacedCloses;
    uint256 public lpMoves;
    uint256 public houseLosses;
    uint256 public houseWins;
    uint256 public feesEarned;
    uint256 public feesClaimed;
    /// @dev Commits per trading window: after-hours, pre-market, regular session.
    uint256[3] public tradesByWindow;
    /// @dev Rounds opened on a menu other than the default, and buys refused for a product cap.
    uint256 public otherMenus;
    uint256 public capRefusals;

    /// @dev Number of products of the round the helpers point at.
    function _products() internal view returns (uint8) {
        return uint8(PitMath.count(hook.getConfig(roundId).params.menu));
    }

    /// @dev The menu the owner announces for the next rounds, drawn from `seed`.
    function _drawMenu(uint256 seed) internal view returns (uint256) {
        uint256 kind = seed % 10;
        if (kind < 5) return book.DEFAULT_MENU();
        if (kind == 5) return Menus.sixFloorsAndPair();
        if (kind == 6) return Menus.thresholds();
        if (kind == 7) return Menus.gappy();
        if (kind == 8) return Menus.pairOnly();
        seed = uint256(keccak256(abi.encode(seed)));
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

    function init() external {
        tickers = [NVDA, TSLA];
        houses[0] = house;
        houses[1] = _createHouse(TSLA, address(chip));
        prices = [S0, TSLA_S0];
        minted = HOUSE_CAPITAL; // the fixture's LP deposit into the NVDA house
        for (uint256 i; i < 4; ++i) {
            traders[i] = address(uint160(0xA11CE000 + i));
            vm.deal(traders[i], TRADER_ETH);
            chip.mint(traders[i], TRADER_STAKE);
            minted += TRADER_STAKE;
            vm.prank(traders[i]);
            chip.approve(address(router), type(uint256).max);
        }
        for (uint256 i; i < 3; ++i) {
            lps[i] = address(uint160(0x11900000 + i));
            chip.mint(lps[i], LP_STAKE);
            minted += LP_STAKE;
            vm.prank(lps[i]);
            chip.approve(address(vault), type(uint256).max);
        }
        chip.mint(donor, 300_000e18);
        minted += 300_000e18;
        vm.prank(donor);
        chip.approve(address(vault), type(uint256).max);
        vm.prank(lps[0]);
        vault.deposit(houses[1], 800_000e18);
        _openRounds();
    }

    function system() external view returns (MockChip, FallpitHook, FallpitRouter, PitVault, address) {
        return (chip, hook, router, vault, address(pm));
    }

    function feeRecipientAddress() external view returns (address) {
        return feeRecipient;
    }

    function keeperAddress() external view returns (address) {
        return keeper;
    }

    function fixtureLp() external view returns (address) {
        return lp;
    }

    function roundCount() external view returns (uint256) {
        return rounds.length;
    }

    function abandonedCount() external view returns (uint256) {
        return abandoned.length;
    }

    // ------------------------------------------------------------------------------------------ trades

    /// @dev Time passes and one stock moves by up to 1% either way, inside +-12% of its last close. Nothing
    ///      trades overnight: when the clock would stop between the after-hours and the pre-market it
    ///      runs on to 04:00 New York (over the weekend too).
    function _tick(uint256 h, uint256 dt, uint256 drift) internal {
        uint64 cutoff = NYTime.closeTs(day) - 630;
        uint64 to = clock + uint64(bound(dt, 0, 9000));
        IFallpitHook.RoundConfig memory c = hook.getConfig(hook.houseRound(houses[h]));
        if (c.day == day) {
            uint64 preMarket = NYTime.at(day, 4 hours);
            // (a commit made at `to` is priced two seconds later)
            if (to + 2 >= NYTime.at(c.clock.prevDay, 20 hours) && to + 2 < preMarket) to = preMarket - 2;
        }
        if (to + 4 <= cutoff) _warp(to);
        drift = bound(drift, 0, 200);
        uint256 s0 = c.s0;
        uint256 next = _grid(prices[h] * (9900 + drift) / 10_000);
        if (s0 == 0 || (next > s0 * 88 / 100 && next < s0 * 112 / 100)) prices[h] = next;
    }

    /// @dev Points the fixture's helpers at house `h`; false when its round is not open for trading now.
    function _select(uint256 h) internal returns (bool tradable) {
        _use(tickers[h], address(chip));
        if (roundId == bytes32(0)) return false;
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        if (hook.getState(roundId).status != IFallpitHook.Status.Open || c.day != day) return false;
        // a commit made now is priced at the print two seconds from now
        (, tradable) = lens.clockAt(roundId, clock + 2);
        if (tradable) ++tradesByWindow[_window(c, clock + 2)];
        return tradable && clock + 4 <= c.cutoff;
    }

    /// @dev 0 the after-hours of the day before, 1 the pre-market, 2 the regular session.
    function _window(IFallpitHook.RoundConfig memory c, uint64 ts) internal pure returns (uint256) {
        if (ts < NYTime.at(c.clock.prevDay, 20 hours)) return 0;
        return ts < NYTime.openTs(c.day) ? 1 : 2;
    }

    function _mix(uint256 a, uint256 b) internal pure returns (uint256, uint256) {
        return
            (
                uint256(keccak256(abi.encode(a, b, uint256(1)))),
                uint256(keccak256(abi.encode(a, b, uint256(2))))
            );
    }

    function _fillNow(uint256 id, uint256 h) internal returns (bool filled) {
        bytes memory report = _printFor(id, prices[h]);
        uint256 gBefore = hook.getState(roundId).g;
        uint256 fee = router.getCommit(id).fillFee;
        // The filler earns the commit's fee whether the fill trades or refunds. Fills alternate between
        // the keeper, who is paid in the call, and this contract, which cannot receive native coin.
        if (id % 2 == 0) {
            uint256 before = keeper.balance;
            vm.prank(keeper);
            filled = router.fill(id, report);
            assertEq(keeper.balance - before, fee, "the filler was paid in the call");
        } else {
            uint256 before = router.ethOwed(address(this));
            filled = router.fill(id, report);
            assertEq(router.ethOwed(address(this)) - before, fee, "an undeliverable fee is owed");
        }
        feesEarned += fee;
        uint256 g = hook.getState(roundId).g;
        assertLe(g, gBefore, "depth never rises during a round");
        assertGe(g, 0.3e18);
    }

    function buy(
        uint256 actorSeed,
        uint256 houseSeed,
        uint8 index,
        uint256 shares,
        uint256 limitSeed,
        uint256 dt,
        uint256 drift
    ) external {
        uint256 h = houseSeed % 2;
        _tick(h, dt, drift);
        if (!_select(h)) return;
        (shares, limitSeed) = _mix(shares, limitSeed);
        address actor = traders[actorSeed % 4];
        uint256 cap = hook.getConfig(roundId).maxFill;
        // sometimes the smallest trade there is (one token), sometimes just above the cap
        shares = limitSeed % 7 == 0 ? bound(shares, 1e18, 1e18 + 1000) : bound(shares, 1e18, cap + cap / 40);
        uint256 balance = chip.balanceOf(actor);
        if (balance == 0) return;
        // one commit in eight carries a random (often too low) limit
        uint256 limit = limitSeed % 8 == 0 ? bound(limitSeed, 1, balance) : balance;

        index = index % _products();
        (,,,,, RefundReason verdict) = lens.quote(roundId, index, true, shares, prices[h], clock + 2);
        vm.prank(actor);
        uint256 id = router.commit{value: FILL_FEE}(roundId, index, true, shares, limit);
        bool filled = _fillNow(id, h);
        uint256 spent = balance - chip.balanceOf(actor);
        // the lens foresaw the refusals that do not depend on the print (another commit of this second
        // may have fixed the print at another price, so the price-dependent verdicts are not compared)
        if (verdict == RefundReason.ProductCap || verdict == RefundReason.Cap) {
            assertFalse(filled, "the lens refused it, the hook must too");
        }
        if (verdict == RefundReason.ProductCap) ++capRefusals;
        if (filled) {
            paidIn[roundId] += spent;
            ++fills;
            // the minimum price: every token bought was charged at least that, before any fee
            assertGe(
                spent * 1e18,
                shares * hook.getConfig(roundId).params.minPriceWad,
                "a buy pays at least the minimum price per token"
            );
            // the loss limit: no buy fills that leaves the house less than its floor in the worst outcome
            (uint256 cushion, uint256 floor) = lens.lossLimit(roundId);
            assertGe(cushion, floor, "a buy that fills leaves the cushion at or above the floor");
        } else {
            assertEq(spent, 0, "a refunded buy costs nothing");
            ++refunds;
        }
    }

    function sell(
        uint256 actorSeed,
        uint256 houseSeed,
        uint8 index,
        uint256 shares,
        uint256 limitSeed,
        uint256 dt,
        uint256 drift
    ) external {
        uint256 h = houseSeed % 2;
        _tick(h, dt, drift);
        if (!_select(h)) return;
        (shares, limitSeed) = _mix(shares, limitSeed);
        address actor = traders[actorSeed % 4];
        // the first token at or after `index` that the actor holds
        Ticket[12] memory tokens = ticketsOf(hook, roundId);
        Ticket memory token;
        uint256 held;
        uint8 n = _products();
        index = index % n;
        for (uint8 k; k < n && held == 0; ++k) {
            index = (index + (k == 0 ? 0 : 1)) % n;
            token = tokens[index];
            held = token.balanceOf(actor);
        }
        if (held < 1e18) return; // below the minimum trade: held to settlement
        shares = bound(shares, 1e18, held);
        uint256 limit = limitSeed % 8 == 0 ? bound(limitSeed, 0, shares) : 0;
        uint256 balance = chip.balanceOf(actor);

        vm.startPrank(actor);
        token.approve(address(router), shares);
        uint256 id = router.commit{value: FILL_FEE}(roundId, index, false, shares, limit);
        vm.stopPrank();
        bool filled = _fillNow(id, h);
        uint256 got = chip.balanceOf(actor) - balance;
        if (filled) {
            paidOut[roundId] += got;
            ++fills;
            ++sells;
            assertEq(token.balanceOf(actor), held - shares);
        } else {
            assertEq(got, 0);
            assertEq(token.balanceOf(actor), held, "a refunded sell returns the tokens");
            ++refunds;
        }
    }

    /// @dev A commit nobody fills: its escrow sits in the router until `refundStale`.
    function abandon(uint256 actorSeed, uint256 houseSeed, uint8 index, uint256 shares) external {
        uint256 h = houseSeed % 2;
        if (!_select(h)) return;
        address actor = traders[actorSeed % 4];
        shares = bound(shares, 1e18, 1_000e18);
        if (chip.balanceOf(actor) < 2_000e18) return;
        index = index % _products();
        vm.prank(actor);
        uint256 id = router.commit{value: FILL_FEE}(roundId, index, true, shares, 2_000e18);
        abandoned.push(id);
        pendingChipEscrow += 2_000e18;
        // a round's commits fill in commit order: the next trade comes once this one's window is over, so
        // this one (never filled) does not hold it
        IFallpitRouter.Commit memory c = router.getCommit(id);
        _warp(c.fillTs + c.refundDelay + 1);
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

    /// @dev Pulls the fill fees the router holds for this contract.
    function claimFees() public {
        uint256 owed = router.ethOwed(address(this));
        if (owed == 0) return;
        assertEq(router.claimEth(feeSink), owed);
        feesClaimed += owed;
    }

    /// @dev Redeems one actor's tokens of one past round: one chip per winning token after Final, the
    ///      average cost after Void, nothing for a loser.
    function redeem(uint256 actorSeed, uint256 roundSeed) public {
        if (rounds.length == 0) return;
        bytes32 id = rounds[roundSeed % rounds.length];
        IFallpitHook.RoundState memory st = hook.getState(id);
        if (st.status != IFallpitHook.Status.Final && st.status != IFallpitHook.Status.Void) return;
        address actor = traders[actorSeed % 4];
        Ticket[12] memory tokens = ticketsOf(hook, id);
        uint256 n = PitMath.count(hook.getConfig(id).params.menu);
        for (uint256 i; i < n; ++i) {
            uint256 balance = tokens[i].balanceOf(actor);
            if (balance == 0) continue;
            bool isFinal = st.status == IFallpitHook.Status.Final;
            if (isFinal && st.winners >> i & 1 == 0) continue;
            uint256 before = chip.balanceOf(actor);
            vm.prank(actor);
            uint256 payout =
                i % 2 == 0 ? router.redeem(tokens[i].id, balance) : hook.redeem(tokens[i].id, actor, balance);
            assertEq(chip.balanceOf(actor) - before, payout);
            if (isFinal) assertEq(payout, balance, "a winning token pays exactly one chip");
            redeemed[id] += payout;
        }
    }

    function collectFees() external {
        feesCollected += hook.collectProtocolFees(address(chip));
    }

    // -------------------------------------------------------------------------------------------- LPs

    function lpDeposit(uint256 lpSeed, uint256 houseSeed, uint256 amount) external {
        address who = lps[lpSeed % 3];
        uint256 balance = chip.balanceOf(who);
        if (balance < 1e18) return;
        amount = bound(amount, 1e18, balance > 300_000e18 ? 300_000e18 : balance);
        vm.prank(who);
        vault.deposit(houses[houseSeed % 2], amount);
        ++lpMoves;
    }

    function lpWithdraw(uint256 lpSeed, uint256 houseSeed, uint256 fraction) external {
        address who = lps[lpSeed % 3];
        bytes32 h = houses[houseSeed % 2];
        vault.settle(h, who);
        uint256 shares = vault.balanceOf(who, uint256(h));
        shares = shares * bound(fraction, 1, 100) / 100;
        if (shares == 0) return;
        uint256 before = chip.balanceOf(who);
        bool locked = vault.isLocked(h);
        vm.prank(who);
        uint256 paid = vault.requestWithdraw(h, shares);
        assertEq(chip.balanceOf(who) - before, paid);
        if (locked) assertEq(paid, 0, "a withdrawal during a round pays nothing yet");
        ++lpMoves;
    }

    function lpClaim(uint256 lpSeed, uint256 houseSeed) external {
        address who = lps[lpSeed % 3];
        bytes32 h = houses[houseSeed % 2];
        // unlocked houses run their queue on the way in, so ask after it ran
        if (!vault.isLocked(h)) vault.processQueues(h);
        (,,, uint256 claimable) = vault.positionOf(h, who);
        if (claimable == 0) return;
        uint256 before = chip.balanceOf(who);
        vm.prank(who);
        assertEq(vault.claim(h), claimable);
        assertEq(chip.balanceOf(who) - before, claimable);
        ++lpMoves;
    }

    function lpCancel(uint256 lpSeed, uint256 houseSeed) external {
        address who = lps[lpSeed % 3];
        bytes32 h = houses[houseSeed % 2];
        if (!vault.isLocked(h)) return;
        (, uint256 queued,,) = vault.positionOf(h, who);
        if (queued == 0) return;
        vm.prank(who);
        assertEq(vault.cancelDeposit(h), queued, "a queued deposit comes back whole");
        ++lpMoves;
    }

    function donate(uint256 houseSeed, uint256 amount) external {
        uint256 balance = chip.balanceOf(donor);
        if (balance < 1e18) return;
        amount = bound(amount, 1e18, balance > 40_000e18 ? 40_000e18 : balance);
        vm.prank(donor);
        vault.donate(houses[houseSeed % 2], amount);
    }

    // ------------------------------------------------------------------------------------------- days

    /// @dev Ends the trading day for both houses and opens the next one.
    function rollDay(uint256 seed) external {
        closeDay(seed);
        // the next trading day whose cutoff is still ahead; closes of days skipped on the way are recorded
        uint32 next = _nextTradingDay(day);
        while (clock >= NYTime.closeTs(next) - 630) {
            day = next;
            // (a dispute may have taken the clock past this close already)
            if (clock < NYTime.closeTs(next) + 5) _warp(NYTime.closeTs(next) + 5);
            for (uint256 h; h < 2; ++h) {
                _use(tickers[h], address(chip));
                _recordClose(prices[h], PYTH_SOURCE);
            }
            next = _nextTradingDay(next);
        }
        day = next;
        // the owner's menu for the rounds that open now (announced a day ago, as the book demands)
        _setMenu(_drawMenu(uint256(keccak256(abi.encode(seed, "menu")))));
        _openRounds();
    }

    /// @dev Ends the trading day for both houses: closes, settlement, finalization or void.
    function closeDay(uint256 seed) public {
        uint64 closeAt = NYTime.closeTs(day);
        if (clock < closeAt + 5) _warp(closeAt + 5);
        bool lateVoid;
        for (uint256 h; h < 2; ++h) {
            seed = uint256(keccak256(abi.encode(seed, h)));
            _use(tickers[h], address(chip));
            bool live = roundId != bytes32(0) && hook.getState(roundId).status == IFallpitHook.Status.Open;
            uint256 mode = seed % 16;
            if (live && mode == 0) {
                lateVoid = true; // no close today for this ticker: the round is voided after 24 hours
                continue;
            }
            // the close: from the keeper set or from Pyth
            bool keeperClose = (seed >> 8) % 2 == 0;
            _recordClose(prices[h], keeperClose ? KEEPER_SOURCE : PYTH_SOURCE);
            if (!live) continue;
            hook.settleRound(house, day);
            if (keeperClose) {
                ++keeperCloses;
                if (mode == 1 && clock < closeAt + book.DISPUTE_WINDOW()) {
                    // the guardian disputes inside the challenge window (it cannot void): nobody
                    // replaces the close, and the round finalizes on it an hour after the close. (The
                    // other house's close, settled after that hour, cannot be disputed.)
                    vm.prank(guardian);
                    book.dispute(roundId);
                    ++disputes;
                    if (clock < closeAt + book.DISPUTE_WINDOW()) _warp(closeAt + book.DISPUTE_WINDOW());
                    _snapshotHouse(h);
                    hook.finalizeRound(house, day);
                    _checkReturn(h, false);
                    continue;
                }
                if (mode < 8) {
                    // a Pyth print for 16:00:00 replaces the keeper's close, at a slightly different price
                    prices[h] = _grid(prices[h] * (9990 + (seed >> 16) % 21) / 10_000);
                    _recordClose(prices[h], PYTH_SOURCE);
                    hook.settleRound(house, day);
                    ++replacedCloses;
                } else {
                    _warp(hook.getState(roundId).settledAt + 900);
                }
            }
            _snapshotHouse(h);
            hook.finalizeRound(house, day);
            _checkReturn(h, false);
        }
        if (lateVoid) {
            _warp(closeAt + 24 hours + 1);
            for (uint256 h; h < 2; ++h) {
                _use(tickers[h], address(chip));
                if (roundId == bytes32(0) || hook.getState(roundId).status != IFallpitHook.Status.Open) {
                    continue;
                }
                _snapshotHouse(h);
                hook.voidRound(house, day);
                _checkReturn(h, true);
                ++voids;
                // the oracle is back: the missed close goes on the books so the house can roll on
                _recordClose(prices[h], PYTH_SOURCE);
            }
        }
        ++daysRolled;
    }

    function _nextTradingDay(uint32 d) internal pure returns (uint32) {
        do {
            ++d;
        } while (!NYTime.isWeekday(d));
        return d;
    }

    function _openRounds() internal {
        for (uint256 h; h < 2; ++h) {
            if (vault.roundCapital(houses[h]) < 1000e18) continue;
            bytes32 id = hook.openRound(tickers[h], address(chip), day);
            rounds.push(id);
            assertEq(hook.getConfig(id).s0, prices[h], "the round starts from the last close");
            uint256 menu = hook.getConfig(id).params.menu;
            assertEq(menu, book.defaultParams().menu, "the round froze the book's menu");
            if (menu != book.DEFAULT_MENU()) ++otherMenus;
        }
        // the rounds trade from here on: in the after-hours when the day before closed in good time
    }

    // what the vault and the hook looked like just before a round's capital returns
    PitVault.House internal _before;
    IFallpitHook.RoundState internal _stBefore;
    uint256 internal _vaultBalanceBefore;
    uint256 internal _refundsBefore;

    function _snapshotHouse(uint256 h) internal {
        _before = vault.getHouse(houses[h]);
        _stBefore = hook.getState(roundId);
        _vaultBalanceBefore = chip.balanceOf(address(vault));
        (, uint256[12] memory premium) = hook.getSupplies(roundId);
        _refundsBefore = 0;
        for (uint256 i; i < MAX_PRODUCTS; ++i) {
            _refundsBefore += premium[i];
        }
    }

    /// @dev The round's result lands in the vault and is split pro rata: traders keep their claims in
    ///      full, the protocol keeps its fees, and the endowment and the shares take the house's result,
    ///      good or bad, in proportion to their capital. On a void the house gets its capital back first.
    function _checkReturn(uint256 h, bool voided) internal {
        IFallpitHook.RoundState memory st = hook.getState(roundId);
        uint256 owedToTraders;
        if (voided) {
            // holders share what the round holds above the house's capital, never more than their cost
            uint256 capital = hook.getConfig(roundId).capital;
            uint256 refundable = _stBefore.held > capital ? _stBefore.held - capital : 0;
            owedToTraders = st.payoutOwed;
            if (_refundsBefore <= refundable) {
                assertEq(owedToTraders, _refundsBefore, "every holder's full cost basis");
            } else {
                assertLe(owedToTraders, refundable, "never out of the house's capital");
                assertGe(owedToTraders + MAX_PRODUCTS, refundable, "all of what is above it, up to rounding");
            }
        } else {
            (uint256[12] memory supply,) = hook.getSupplies(roundId);
            owedToTraders = PitMath.payoutOf(supply, st.winners);
            assertEq(st.payoutOwed, owedToTraders, "every winning token is owed one chip");
        }
        assertEq(st.held, owedToTraders, "and the round keeps exactly that");
        uint256 fees = voided ? 0 : _stBefore.protocolFees;
        uint256 back = _stBefore.held - owedToTraders - fees;
        assertEq(chip.balanceOf(address(vault)) - _vaultBalanceBefore, back, "the rest went to the vault");

        PitVault.House memory a = vault.getHouse(houses[h]);
        assertFalse(a.locked);
        uint256 sent = _before.sent;
        assertEq(sent, _before.lpAssets + _before.endowment);
        assertEq(a.lpAssets + a.endowment, back + _before.pendingDonations, "the vault booked what arrived");
        if (back >= sent) ++houseWins;
        else ++houseLosses;
        // the shares keep their fraction of the capital, win or lose (unless the dust rule moved a
        // wiped-out remainder to the endowment); the endowment has the rest
        uint256 lpPart = back.fullMulDiv(_before.lpAssets, sent);
        if (a.lpAssets != 0) {
            assertEq(a.lpAssets, lpPart, "shares: pro rata");
            assertEq(a.endowment, back - lpPart + _before.pendingDonations, "endowment: pro rata");
        }
    }
}

/// @notice Stateful fuzz of the whole real system. After every call: every open round is solvent and
///         conserved (the worst of its 40 bands is covered, on whatever menu it has, and no floor is over
///         its product cap), every ticket's `totalSupply` is the supply the hook pays out on, the
///         chips the hook holds equal what it owes, the vault's books never exceed its balance, router
///         escrow matches, and every chip ever minted is accounted for.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 80
contract SystemInvariantTest is Test {
    SystemHandler internal handler;
    MockChip internal chip;
    FallpitHook internal hook;
    FallpitRouter internal router;
    PitVault internal vault;
    address internal pm;

    function setUp() public {
        handler = new SystemHandler();
        handler.setUp();
        handler.init();
        (chip, hook, router, vault, pm) = handler.system();

        bytes4[] memory selectors = new bytes4[](21);
        for (uint256 i; i < 6; ++i) {
            selectors[i] = SystemHandler.buy.selector;
        }
        for (uint256 i = 6; i < 11; ++i) {
            selectors[i] = SystemHandler.sell.selector;
        }
        selectors[11] = SystemHandler.abandon.selector;
        selectors[12] = SystemHandler.refundStale.selector;
        selectors[13] = SystemHandler.redeem.selector;
        selectors[14] = SystemHandler.lpDeposit.selector;
        selectors[15] = SystemHandler.lpWithdraw.selector;
        selectors[16] = SystemHandler.lpClaim.selector;
        selectors[17] = SystemHandler.lpCancel.selector;
        selectors[18] = SystemHandler.donate.selector;
        selectors[19] = SystemHandler.rollDay.selector;
        selectors[20] = SystemHandler.claimFees.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_theWholeSystemStaysSolventAndConserved() public view {
        uint256 owedByRounds;
        uint256 n = handler.roundCount();
        for (uint256 r; r < n; ++r) {
            bytes32 id = handler.rounds(r);
            IFallpitHook.RoundState memory st = hook.getState(id);
            (uint256[12] memory supply, uint256[12] memory premium) = hook.getSupplies(id);
            Ticket[12] memory tokens = ticketsOf(hook, id);
            uint256 costBasis;
            IFallpitHook.RoundConfig memory c = hook.getConfig(id);
            uint256 menu = c.params.menu;
            uint256 products = PitMath.count(menu);
            for (uint256 i = products; i < 12; ++i) {
                assertEq(tokens[i].id, 0, "no token above the menu");
                assertEq(supply[i] + premium[i], 0, "no supply above the menu");
            }
            for (uint256 i; i < products; ++i) {
                // the token is the claim
                assertEq(tokens[i].totalSupply(), supply[i], "totalSupply equals outstanding");
                assertEq(tokens[i].balanceOf(address(router)), 0, "no token escrow left behind");
                costBasis += premium[i];
                // a floor never has more outstanding than its product cap
                (uint8 lo, uint8 hi) = PitMath.run(menu, i);
                if (uint256(hi) - lo + 1 < 20) {
                    assertLe(supply[i] * 10_000, c.capital * c.params.floorCapBps, "product cap");
                }
            }
            if (st.status == IFallpitHook.Status.Open) {
                uint256 capital = c.capital;
                // the worst band, counted band by band without the hook's difference array
                uint256 worst;
                for (uint256 j; j < 40; ++j) {
                    uint256 payout;
                    for (uint256 i; i < products; ++i) {
                        (uint8 lo, uint8 hi) = PitMath.run(menu, i);
                        if (lo <= j && j <= hi) payout += supply[i];
                    }
                    if (payout > worst) worst = payout;
                }
                assertEq(PitMath.maxPayout(supply, menu), worst, "the worst band");
                assertLe(worst + st.protocolFees, st.held, "pooled solvency");
                assertEq(
                    st.held,
                    capital + handler.paidIn(id) - handler.paidOut(id),
                    "held = capital + net premium"
                );
                // A token's cost basis never exceeds what was paid for it. (It can exceed the traders' NET
                // cash in once the oracle has moved: a holder who sold at a profit took more out than its
                // tokens' cost, and a void does not claw that back. The house bears it, as any loss.)
                assertLe(costBasis, handler.paidIn(id), "cost basis <= what traders paid");
            } else if (st.status == IFallpitHook.Status.Final) {
                assertEq(
                    st.held, PitMath.payoutOf(supply, st.winners), "a final round holds its winners' chips"
                );
                assertEq(st.held, st.payoutOwed);
            } else if (st.status == IFallpitHook.Status.Void) {
                assertEq(st.held, costBasis, "a void round holds its refunds");
                assertEq(st.held, st.payoutOwed);
            } else {
                assertEq(uint8(st.status), uint8(IFallpitHook.Status.Settled), "unexpected status");
            }
            owedByRounds += st.held;
        }

        // the hook: the chips it holds in its own balance equal what it owes, none are in the PoolManager
        (uint256 claims, uint256 owed) = Accounting.read(address(hook), address(chip));
        assertEq(claims, owed, "claims equal what the hook owes");
        assertEq(owed, owedByRounds + hook.protocolFeesAccrued(address(chip)), "owed = rounds + accrued fees");
        assertEq(chip.balanceOf(pm), 0, "nothing in the PoolManager");

        // the router: escrow of pending commits, nothing else
        assertEq(chip.balanceOf(address(router)), router.escrowed(address(chip)), "chip escrow");
        assertEq(router.escrowed(address(chip)), handler.pendingChipEscrow());

        // the vault: its books per house add up to its books per chip, which never exceed its balance
        uint256 heldForHouses = vault.heldFor(handler.houses(0)) + vault.heldFor(handler.houses(1));
        assertEq(heldForHouses, vault.accounted(address(chip)), "house books = chip books");
        assertEq(
            vault.accounted(address(chip)), chip.balanceOf(address(vault)), "vault books = vault balance"
        );

        // conservation: every chip ever minted is with someone we know
        uint256 sum = chip.balanceOf(address(hook)) + chip.balanceOf(address(router))
            + chip.balanceOf(address(vault)) + chip.balanceOf(handler.donor())
            + chip.balanceOf(handler.feeRecipientAddress()) + chip.balanceOf(handler.fixtureLp());
        for (uint256 i; i < 4; ++i) {
            sum += chip.balanceOf(handler.traders(i));
        }
        for (uint256 i; i < 3; ++i) {
            sum += chip.balanceOf(handler.lps(i));
        }
        assertEq(sum, handler.minted(), "chips are conserved");
        assertEq(chip.totalSupply(), handler.minted());

        // native coin: the router holds the fill fees of the pending commits plus the fees it could not
        // deliver, the hook and the handler hold none, and every wei the traders attached is accounted for
        uint256 unclaimed = router.ethOwed(address(handler));
        assertEq(
            address(router).balance,
            handler.abandonedCount() * 0.0001 ether + unclaimed,
            "router ETH is pending fees plus unclaimed fees"
        );
        assertEq(address(hook).balance, 0);
        assertEq(address(handler).balance, 0);
        address keeper = handler.keeperAddress();
        assertEq(
            keeper.balance + handler.feeSink().balance + unclaimed,
            handler.feesEarned(),
            "every fee earned is with its filler, claimed, or owed"
        );
        assertEq(handler.feeSink().balance, handler.feesClaimed());
        uint256 eth = address(router).balance + keeper.balance + handler.feeSink().balance;
        for (uint256 i; i < 4; ++i) {
            eth += handler.traders(i).balance;
        }
        assertEq(eth, 4 * handler.TRADER_ETH(), "native coin is conserved");
    }

    /// @dev After the random session: one more day rolls, everybody redeems and refunds everything, the
    ///      fees are collected. The traders' total result must equal, to the unit, what the rounds paid
    ///      and took: nothing was created or lost on the way.
    function afterInvariant() public {
        handler.closeDay(uint256(keccak256("last day")));
        uint256 n = handler.roundCount();
        for (uint256 r; r < n; ++r) {
            for (uint256 a; a < 4; ++a) {
                handler.redeem(a, r);
            }
        }
        handler.collectFees();
        handler.claimFees();
        assertEq(router.ethOwed(address(handler)), 0);
        emit log_named_decimal_uint("fill fees earned by the fillers (ETH)", handler.feesEarned(), 18);
        emit log_named_decimal_uint("of which claimed after a failed delivery", handler.feesClaimed(), 18);
        emit log_named_uint("days rolled", handler.daysRolled());
        emit log_named_uint("rounds", n);
        emit log_named_uint("of which on a menu other than the default", handler.otherMenus());
        emit log_named_uint("buys refused for a product cap", handler.capRefusals());
        emit log_named_uint("commits made in the after-hours", handler.tradesByWindow(0));
        emit log_named_uint("commits made in the pre-market", handler.tradesByWindow(1));
        emit log_named_uint("commits made in the regular session", handler.tradesByWindow(2));
        emit log_named_uint("fills", handler.fills());
        emit log_named_uint("sells", handler.sells());
        emit log_named_uint("refunds", handler.refunds());
        emit log_named_uint("LP moves", handler.lpMoves());
        emit log_named_uint("keeper closes", handler.keeperCloses());
        emit log_named_uint("closes replaced by Pyth", handler.replacedCloses());
        emit log_named_uint("voids", handler.voids());
        emit log_named_uint("disputes", handler.disputes());
        emit log_named_uint("house winning rounds", handler.houseWins());
        emit log_named_uint("house losing rounds", handler.houseLosses());

        int256 tradersResult;
        for (uint256 i; i < 4; ++i) {
            tradersResult += int256(chip.balanceOf(handler.traders(i))) - 500_000e18;
        }
        int256 roundsResult;
        for (uint256 r; r < n; ++r) {
            bytes32 id = handler.rounds(r);
            roundsResult += int256(handler.paidOut(id)) + int256(handler.redeemed(id))
            - int256(handler.paidIn(id));
            IFallpitHook.Status s = hook.getState(id).status;
            assertTrue(s == IFallpitHook.Status.Final || s == IFallpitHook.Status.Void, "every round ended");
        }
        assertEq(
            tradersResult + int256(handler.pendingChipEscrow()),
            roundsResult,
            "the traders' result is exactly what the rounds paid and took"
        );
    }
}
