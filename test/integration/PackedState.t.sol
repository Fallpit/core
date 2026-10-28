// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {ILadderMath} from "../../src/interfaces/ILadderMath.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {PitMath} from "../../src/hook/PitMath.sol";
import {PitVault} from "../../src/PitVault.sol";
import {PackedBands} from "../../src/lib/PackedBands.sol";

/// @dev `PackedBands` on a storage array of its own.
contract PackedBandsHarness {
    uint256[20] internal _packed;

    function roundTrip(int256[40] memory v) external returns (int256[40] memory) {
        PackedBands.store(_packed, v);
        return PackedBands.load(_packed);
    }

    function word(uint256 k) external view returns (uint256) {
        return _packed[k];
    }
}

/// @notice The packed band state round-trips exactly for every value `ILadderMath` allows (|v_j| <= 1e36).
contract PackedBandsTest is Test {
    int256 internal constant MAX = 1e36;
    PackedBandsHarness internal h;

    function setUp() public {
        h = new PackedBandsHarness();
    }

    function _check(int256[40] memory v) internal {
        int256[40] memory w = h.roundTrip(v);
        for (uint256 j; j < 40; ++j) {
            assertEq(w[j], v[j]);
        }
    }

    function test_roundTrip_extremes() public {
        int256[7] memory vals = [MAX, -MAX, int256(0), -1, 1, MAX - 1, -MAX + 1];
        int256[40] memory v;
        // every pair of values in the two halves of a word, in every word
        for (uint256 a; a < vals.length; ++a) {
            for (uint256 b; b < vals.length; ++b) {
                for (uint256 k; k < 20; ++k) {
                    v[2 * k] = vals[(a + k) % vals.length];
                    v[2 * k + 1] = vals[(b + 2 * k) % vals.length];
                }
                _check(v);
            }
        }
        // the layout: band 2k low, band 2k+1 high, two's complement in 128 bits
        v[0] = -1;
        v[1] = 0;
        v[2] = 0;
        v[3] = -1;
        h.roundTrip(v);
        assertEq(h.word(0), type(uint128).max);
        assertEq(h.word(1), uint256(type(uint128).max) << 128);
        // a word written again with smaller values keeps no bits of the old ones
        int256[40] memory zero;
        _check(zero);
        for (uint256 k; k < 20; ++k) {
            assertEq(h.word(k), 0);
        }
    }

    function testFuzz_roundTrip(int256[40] memory v) public {
        for (uint256 j; j < 40; ++j) {
            v[j] = bound(v[j], -MAX, MAX);
        }
        _check(v);
    }
}

/// @notice The stored forms behind the views: the packed band state (`getCurve`), the router's commits
///         without a stored escrow (`getCommit`) and its escrow totals that never go back to a zero slot
///         (`escrowed`, `escrowedTickets`), the vault's `sent` kept after a round (`getHouse`), and the risk
///         budget the hook passes to the book (`takeRisk`).
contract PackedStateTest is IntegrationFixture {
    function setUp() public override {
        super.setUp();
        _fund(alice, 100_000e18);
        _fund(bob, 100_000e18);
    }

    struct Expect {
        ILadderMath.Fill f;
        uint256 gNew;
        uint64 ts;
    }

    /// @dev What `math.fill` returns for commit `id` at `price`, computed here with the hook's inputs
    ///      (warps to the fill instant).
    function _expect(uint256 id, uint256 price) internal returns (Expect memory e) {
        IFallpitRouter.Commit memory c = router.getCommit(id);
        e.ts = c.fillTs;
        if (clock < e.ts) _warp(e.ts);
        IFallpitHook.RoundConfig memory cfg = hook.getConfig(roundId);
        IFallpitHook.RoundState memory st = hook.getState(roundId);
        (int256[40] memory v0, uint256[40] memory b0) = hook.getCurve(roundId);
        (uint256 rho,) = book.clockAt(cfg.clock, e.ts);
        (int256 x, uint256 sd, uint256 gNew) =
            PitMath.context(hook.sigmaEffOf(roundId), rho, cfg.s0, price, st.g);
        (uint8 lo, uint8 hi) = PitMath.run(cfg.params.menu, uint8(c.id & 0xff));
        int256 delta = int256(uint256(c.shares) * 10 ** (18 - cfg.decimals));
        e.f = math.fill(
            v0,
            b0,
            cfg.sigma,
            ILadderMath.Ctx({x: x, sd: sd, gOld: st.g, gNew: gNew}),
            lo,
            hi,
            c.isBuy ? delta : -delta
        );
        e.gNew = gNew;
    }

    function _assertCurve(int256[40] memory want) internal view {
        (int256[40] memory v,) = hook.getCurve(roundId);
        for (uint256 j; j < 40; ++j) {
            assertEq(v[j], want[j], "getCurve is the state math.fill returned");
        }
    }

    /// @notice After each fill `getCurve` returns exactly the state `math.fill` handed back, buys and sells,
    ///         and the book's risk sum grew by the fill's risk under the budget the hook passed.
    function test_getCurve_afterFills_isTheMathState() public {
        _open();
        (int256[40] memory v,) = hook.getCurve(roundId);
        for (uint256 j; j < 40; ++j) {
            assertEq(v[j], 0, "a round starts at zero");
        }
        uint256[4] memory ids;
        ids[0] = _commitBuy(alice, HIGHER, 1_000e18, 10_000e18);
        ids[1] = _commitBuy(bob, F4, 2_000e18, 10_000e18);
        for (uint256 i; i < 4; ++i) {
            if (i == 2) ids[2] = _commitSell(alice, HIGHER, 600e18, 0);
            if (i == 3) ids[3] = _commitBuy(alice, LOWER, 500e18, 10_000e18);
            // the first two share a fill instant and so one print
            uint256 price = i < 2 ? S0 : S0 * (1000 + i) / 1000;
            price -= price % PRICE_GRID;
            Expect memory e = _expect(ids[i], price);
            IFallpitHook.RoundConfig memory cfg = hook.getConfig(roundId);
            uint256 budget = book.riskBudgetOf(cfg.capital, cfg.decimals, cfg.params.riskCapBps, e.gNew);
            (uint256 lensBudget, uint256 usedBefore) = lens.riskBudget(roundId, e.ts);
            assertEq(lensBudget, budget, "the lens and the book agree on the budget");
            assertEq(budget, PitMath.riskBudget(cfg.capital, cfg.decimals, cfg.params.riskCapBps, e.gNew));

            IFallpitRouter.Commit memory c = router.getCommit(ids[i]);
            bytes memory report = _print(e.ts, price);
            vm.prank(keeper);
            assertTrue(router.fill(ids[i], report), "filled");
            _assertCurve(e.f.v);
            uint256 delta = uint256(c.shares);
            uint256 risk = c.isBuy ? (delta > e.f.amount ? delta - e.f.amount : 0) : e.f.amount;
            assertEq(book.riskUsed(roundId, e.ts), usedBefore + risk, "risk taken");
            assertLe(usedBefore + risk, budget);
        }
    }

    /// @notice Only the hook adds to the risk sums.
    function test_takeRisk_onlyHook() public {
        _open();
        vm.expectRevert(IPitBook.OnlyHook.selector);
        book.takeRisk(roundId, clock, 1, type(uint256).max);
    }

    /// @notice The budget formula of `riskBudgetOf` is `capital * 10^(18 - decimals) * riskCapBps / 1e18
    ///         * g / 1e4`, rounded down at each step.
    function testFuzz_riskBudgetOf_formula(uint96 capital, uint8 decimals, uint16 bps, uint64 g) public view {
        decimals = uint8(bound(decimals, 0, 18));
        uint256 want = uint256(capital) * 10 ** (18 - decimals) * bps / 1e18 * g / 10_000;
        assertEq(book.riskBudgetOf(capital, decimals, bps, g), want);
        assertEq(PitMath.riskBudget(capital, decimals, bps, g), want);
    }

    /// @notice `getCommit` returns the escrow `isBuy ? limit : shares` for buys and sells.
    function test_getCommit_escrow() public {
        _open();
        uint256 b = _commitBuy(alice, HIGHER, 1_000e18, 7_000e18);
        IFallpitRouter.Commit memory c = router.getCommit(b);
        assertEq(c.escrow, 7_000e18);
        assertEq(c.escrow, c.limit);
        assertTrue(_fill(b, S0));
        c = router.getCommit(b);
        assertEq(c.escrow, 7_000e18, "the record keeps its escrow after the fill");

        uint256 s = _commitSell(alice, HIGHER, 400e18, 3e18);
        c = router.getCommit(s);
        assertEq(c.escrow, 400e18);
        assertEq(c.escrow, c.shares);
        assertEq(c.limit, 3e18);

        c = router.getCommit(999);
        assertEq(c.escrow, 0, "no commit");
        assertEq(c.user, address(0));
    }

    /// @notice The escrow totals: the sum of the pending commits while they wait, 0 once all are released
    ///         (filled or refunded), and the right sum again for new commits on the same slot.
    function test_escrowTotals_duringAndAfter() public {
        _open();
        assertEq(router.escrowed(address(chip)), 0, "never used");
        uint256 tid = hook.tokenId(roundId, HIGHER);
        assertEq(router.escrowedTickets(tid), 0, "never used");

        uint256 b1 = _commitBuy(alice, HIGHER, 1_000e18, 5_000e18);
        uint256 b2 = _commitBuy(bob, HIGHER, 1_000e18, 3_000e18);
        assertEq(router.escrowed(address(chip)), 8_000e18);
        assertTrue(_fill(b1, S0));
        assertEq(router.escrowed(address(chip)), 3_000e18);
        // b2 is left until its window ends, then refunded
        IFallpitRouter.Commit memory c = router.getCommit(b2);
        _warp(c.fillTs + c.refundDelay + 1);
        router.refund(b2);
        assertEq(router.escrowed(address(chip)), 0, "all released");
        assertEq(chip.balanceOf(address(router)), 0);

        uint256 s1 = _commitSell(alice, HIGHER, 300e18, 0);
        uint256 s2 = _commitSell(alice, HIGHER, 200e18, 0);
        assertEq(router.escrowedTickets(tid), 500e18);
        assertTrue(_fill(s1, S0));
        assertEq(router.escrowedTickets(tid), 200e18);
        c = router.getCommit(s2);
        _warp(c.fillTs + c.refundDelay + 1);
        router.refund(s2);
        assertEq(router.escrowedTickets(tid), 0, "all released");

        uint256 b3 = _commitBuy(alice, LOWER, 1_000e18, 4_000e18);
        assertEq(router.escrowed(address(chip)), 4_000e18, "the slot counts from its new commits");
        // a refund inside the fill (limit too low) releases it too
        IFallpitRouter.Commit memory c3 = router.getCommit(b3);
        assertEq(c3.escrow, 4_000e18);
        uint256 b4 = _commitBuy(alice, LOWER, 1_000e18, 1);
        assertEq(router.escrowed(address(chip)), 4_000e18 + 1);
        assertTrue(_fill(b3, S0));
        assertFalse(_fill(b4, S0), "refunded: limit");
        assertEq(router.escrowed(address(chip)), 0);
    }

    /// @notice `getHouse.sent` is the capital sent while the round runs and 0 once the house is unlocked.
    function test_getHouse_sent_zeroWhenUnlocked() public {
        PitVault.House memory h = vault.getHouse(house);
        assertEq(h.sent, 0);
        assertFalse(h.locked);
        _open();
        h = vault.getHouse(house);
        assertTrue(h.locked);
        assertEq(h.sent, hook.getConfig(roundId).capital);
        assertEq(h.sent, HOUSE_CAPITAL);
        _buy(alice, HIGHER, 1_000e18, S0);
        _closeAndFinalize(S0 * 2);
        h = vault.getHouse(house);
        assertFalse(h.locked);
        assertEq(h.sent, 0, "a house with no round shows nothing sent");
    }
}
