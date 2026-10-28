// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StackFixture} from "./StackFixture.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {PitBook} from "../../src/hook/PitBook.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice The book keeps the stock token's multiplier with every close and does not step the variance across
///         a change of it (the close is stored, the step is skipped). Any daily squared return enters the
///         EWMA at most at (4 sigma)^2, so a move the multiplier does not explain moves the variance by a
///         bounded factor.
contract CorporateActionsTest is StackFixture {
    address internal lp = makeAddr("lp");

    function test_split_storesTheCloseWithoutAStep() public {
        _lpDeposit(lp, 1_000_000e18);
        uint256 varBefore = book.getTicker(NVDA).varWad;
        assertEq(varBefore, SEED_VAR);

        // Tuesday: the split. The issuer doubles the stock token's multiplier; the keeper records Tuesday's
        // close as usual, at half of Monday's.
        uint32 splitDay = day;
        oracle.setMultiplier(NVDA, 2e18);
        _recordCloseOf(splitDay, S0 / 2, KEEPER);
        PitBook.Close memory cl = book.closeInfo(NVDA, splitDay);
        assertEq(cl.multiplier, 2e18, "the multiplier is kept with the close");
        IPitBook.Ticker memory tk = book.getTicker(NVDA);
        assertEq(tk.varWad, SEED_VAR, "no step across the split");
        assertFalse(tk.lastCloseStepped);
        console.log("variance after the split close (WAD)", tk.varWad, "before", varBefore);

        // Wednesday, flat after the split: an ordinary step again.
        _recordCloseOf(splitDay + 1, S0 / 2, KEEPER);
        assertEq(book.getTicker(NVDA).varWad, SEED_VAR * 94 / 100, "back to normal steps");
    }

    /// @dev The split day skipped and its close never recorded. Wednesday's close is
    ///      compared with Monday's, the multipliers differ, no step.
    function test_split_skippedDayWithoutClose_noStepEither() public {
        _lpDeposit(lp, 1_000_000e18);
        uint32 splitDay = day;
        vm.warp(clock - 2 days);
        vm.prank(owner);
        book.setSkip(NVDA, splitDay, true);
        vm.warp(clock);
        oracle.setMultiplier(NVDA, 2e18);
        _recordCloseOf(splitDay + 1, S0 / 2, KEEPER);
        assertEq(book.getTicker(NVDA).varWad, SEED_VAR);
    }

    function test_split_theRoundAfterItOpensOnTheOldSigma() public {
        _lpDeposit(lp, 1_000_000e18);
        uint32 splitDay = day;
        oracle.setMultiplier(NVDA, 2e18);
        _recordCloseOf(splitDay, S0 / 2, KEEPER);

        // Wednesday's round opens from Tuesday's (post-split) close with the sigma of the stock.
        uint32 wednesday = splitDay + 1;
        day = wednesday;
        _warp(NYTime.closeTs(splitDay) + 1000);
        roundId = hook.openRound(NVDA, address(chip), wednesday);
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        console.log("S0 of the next round", c.s0);
        console.log("sigma of the next round (WAD)", c.sigma);
        assertEq(c.s0, S0 / 2);
        assertEq(c.sigma, 0.02e18, "2%, not 15%");
    }

    /// @dev A jump the multiplier does not explain (a crash, a corporate action the token missed): the
    ///      squared return is capped at 16 variances, so the variance at most about doubles in one step.
    function test_hugeMove_entersTheEwmaAtFourSigmaAtMost() public {
        _lpDeposit(lp, 1_000_000e18);
        _recordCloseOf(day, S0 / 2, KEEPER); // -69% in log terms, no multiplier change
        uint256 v = book.getTicker(NVDA).varWad;
        assertEq(v, (94 * SEED_VAR + 6 * 16 * SEED_VAR) / 100, "0.94 v + 0.06 * 16 v");
        console.log("sigma after a -50% day (bps)", FixedPointMathLib.sqrt(v * 1e18) / 1e14);
        // a normal day is not capped
        _recordCloseOf(day + 1, S0 / 2 * 1015 / 1000, KEEPER);
        int256 ret = FixedPointMathLib.lnWad(1.015e18);
        assertApproxEqAbs(book.getTicker(NVDA).varWad, (94 * v + 6 * (uint256(ret * ret) / 1e18)) / 100, 1e6);
    }
}
