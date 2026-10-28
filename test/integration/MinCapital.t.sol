// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";
import {LadderMath} from "../../src/LadderMath.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice The book's `minCapital` is never below the smallest capital the real pricing engine opens a
///         round with: `LadderMath.openDepths` refuses a depth below 1e14 wei, which needs
///         `alpha * capital >= ln(1 / pi_min) * 1e14`, about 9.3e32 with both in WAD.
contract MinCapitalTest is IntegrationFixture {
    using FixedPointMathLib for uint256;

    uint256 internal constant MIN_VAR = 0.005e18 * 0.005e18 / 1e18;
    uint256 internal constant MAX_VAR = 0.15e18 * 0.15e18 / 1e18;

    function test_book_refusesAMinCapitalTheMathCannotOpen() public {
        IPitBook.Params memory p = book.defaultParams();
        assertEq(p.alpha, 0.2e18, "the default alpha");
        assertEq(p.minCapital, 1000, "the defaults are far inside the bound: alpha * minCapital = 2e20");
        // take the book's other rule about small rounds (the smallest trade must fit under the per-fill
        // cap of the smallest round) out of the way, so that only the engine's limit decides below
        p.minTrade = 1e12;
        p.maxFillBps = 10_000;
        vm.startPrank(owner);

        // alpha * minCapital below 1e15 is refused, whichever of the two is small
        p.alpha = 0.001e18 - 1;
        p.minCapital = 1;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.alpha = 1e13;
        p.minCapital = 99;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        p.alpha = 1;
        p.minCapital = 1e15 - 1;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);

        // exactly at the bound is accepted
        p.alpha = 0.001e18;
        p.minCapital = 1;
        book.setDefaultParams(p);
        p.alpha = 1e13;
        p.minCapital = 100;
        book.setDefaultParams(p);
        p.alpha = 1;
        p.minCapital = 1e15;
        book.setDefaultParams(p);

        // a minCapital above the largest capital the math accepts (1e15 whole chips) is refused too
        p.alpha = 0.3e18;
        p.minCapital = 1e15 + 1;
        vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        vm.stopPrank();
    }

    /// @dev Why the bound exists: just under it the real engine refuses to open.
    function test_math_refusesACapitalBelowItsLimit() public {
        // alpha * capital = 9e32: the tail bands (ln(1 / pi) about 9.2) get a depth below 1e14 wei
        vm.expectRevert(LadderMath.InvalidDepth.selector);
        math.openDepths(0.02e18, 0.9e18, 0.001e18);
        vm.expectRevert(LadderMath.InvalidDepth.selector);
        math.openDepths(0.02e18, 3e15, 0.3e18);
        // and at the book's bound it opens
        math.openDepths(0.02e18, 1e18, 0.001e18);
    }

    /// @dev Every (alpha, minCapital) the book accepts opens in the real engine at exactly minCapital, for
    ///      every volatility the book can hold.
    function testFuzz_everyAcceptedMinCapital_opensInTheRealMath(
        uint256 alpha,
        uint256 minCapital,
        uint256 variance
    ) public view {
        alpha = bound(alpha, 1, 0.79e18);
        uint256 least = (1e15 + alpha - 1) / alpha;
        minCapital = bound(minCapital, least, 1e15);
        variance = bound(variance, MIN_VAR, MAX_VAR);
        uint256 sigma = variance.sqrtWad();

        uint256[40] memory b0 = math.openDepths(sigma, minCapital * 1e18, alpha);
        for (uint256 j; j < 40; ++j) {
            assertGe(b0[j], 1e14, "every band is inside the engine's precision domain");
        }
    }

    function testFuzz_everyAcceptedMinCapital_isAcceptedByTheBook(uint64 alpha, uint96 minCapital) public {
        IPitBook.Params memory p = book.defaultParams();
        p.minTrade = 1e12;
        p.maxFillBps = 10_000;
        p.alpha = alpha;
        p.minCapital = minCapital;
        bool ok = alpha != 0 && alpha <= 0.79e18 && minCapital != 0 && minCapital <= 1e15
            && uint256(alpha) * minCapital >= 1e15;
        vm.prank(owner);
        if (!ok) vm.expectRevert(IPitBook.BadParams.selector);
        book.setDefaultParams(p);
        if (ok) math.openDepths(0.02e18, uint256(minCapital) * 1e18, alpha);
    }

    /// @dev The defaults as shipped (alpha 0.2, minCapital 1000, the default menu
    ///      of eight floors and the pair) open a round on a house holding exactly `minCapital` whole
    ///      chips, every band inside the engine's precision domain, and the smallest round trades every
    ///      product at the per-fill cap. One chip less is refused by the hook's own check.
    function test_defaults_theDefaultMenuOpensARoundOnMinCapital() public {
        IPitBook.Params memory p = book.defaultParams();
        assertEq(p.alpha, 0.2e18);
        assertEq(p.minCapital, 1000);
        assertEq(p.menu, book.DEFAULT_MENU());
        assertGe(uint256(p.alpha) * p.minCapital, 1e15, "the book's bound holds with room to spare");

        MockChip coin = new MockChip(18);
        vm.prank(owner);
        guard.approve(address(coin), true);
        _use(NVDA, address(coin));
        _lpDeposit(lp, house, 1000e18 - 1);
        vm.expectRevert(IFallpitHook.CapitalTooLow.selector);
        hook.openRound(NVDA, address(coin), day);
        _lpDeposit(lp, house, 1);
        roundId = hook.openRound(NVDA, address(coin), day);
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(c.capital, 1000e18);
        assertEq(c.params.alpha, 0.2e18);
        assertEq(c.maxFill, 20e18, "2% of 1,000 chips");
        (, uint256[40] memory b0) = hook.getCurve(roundId);
        for (uint256 j; j < 40; ++j) {
            assertGe(b0[j], 1e14, "every band is inside the engine's precision domain");
        }
        if (clock < NYTime.openTs(day) + 60) _warp(NYTime.openTs(day) + 60);
        _fund(alice, 1000e18);
        for (uint8 i; i < PRODUCTS; ++i) {
            uint256 cost = _buy(alice, i, c.maxFill, S0);
            assertGt(cost, 0);
            uint256 proceeds = _sell(alice, i, c.maxFill, S0);
            assertLt(proceeds, cost);
        }
        _assertSupplies();
        _assertHookSolvent(address(coin));
    }

    /// @dev End to end at the bound, for an 18-decimal and a 6-decimal chip: a house holding exactly
    ///      `minCapital` opens and trades; one unit less is refused by the hook's own check, with its own
    ///      error, before the engine is asked.
    function test_roundAtTheSmallestCapital_opensAndTrades() public {
        IPitBook.Params memory p = book.defaultParams();
        p.alpha = 0.001e18;
        p.minCapital = 1;
        p.minTrade = 0.02e18; // the per-fill cap of a one-chip round
        _setParams(p);

        _atTheBound(new MockChip(18), 1e18);
        _atTheBound(new MockChip(6), 1e6);
    }

    function _atTheBound(MockChip coin, uint256 oneChip) internal {
        vm.prank(owner);
        guard.approve(address(coin), true);
        _use(NVDA, address(coin));

        _lpDeposit(lp, house, oneChip - 1);
        vm.expectRevert(IFallpitHook.CapitalTooLow.selector);
        hook.openRound(NVDA, address(coin), day);

        _lpDeposit(lp, house, 1);
        roundId = hook.openRound(NVDA, address(coin), day);
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        assertEq(c.capital, oneChip);
        (, uint256[40] memory b0) = hook.getCurve(roundId);
        for (uint256 j; j < 40; ++j) {
            assertGe(b0[j], 1e14);
        }

        // trades at the per-fill cap in both directions
        if (clock < NYTime.openTs(day) + 60) _warp(NYTime.openTs(day) + 60);
        _fund(alice, oneChip);
        uint256 cost = _buy(alice, HIGHER, c.maxFill, S0);
        assertGt(cost, 0);
        uint256 proceeds = _sell(alice, HIGHER, c.maxFill, S0);
        assertLt(proceeds, cost);
        _assertSupplies();
        _assertHookSolvent(address(coin));
    }
}
