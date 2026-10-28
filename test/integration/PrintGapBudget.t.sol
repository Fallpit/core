// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {AttackBase} from "./AttackBase.sol";
import {PitAttacker} from "../hook/mocks/PitAttacker.sol";

/// @notice The risk budget is keyed by the print's own ts (from `verifyAt`), with g at ts. One print prices
///         every instant in (prevTs, ts], up to maxLag + 1 = 31 of them, and still takes one budget, also
///         after the keeper skipped a few seconds.
contract PrintGapBudgetTest is AttackBase {
    uint256 internal constant LOT = 10_000e18;
    uint256 internal constant GAP = 10; // seconds the keeper did not print
    PitAttacker internal whale;

    function _testRiskCapBps() internal pure override returns (uint16) {
        return 300;
    }

    function setUp() public override {
        super.setUp();
        _open();
        whale = _attacker(hook.getConfig(roundId).chip, 2_000_000e18);
    }

    function test_onePrintAfterAGapTakesOneBudget() public {
        uint64 c0 = clock;
        uint8[4] memory prods = [F5, F6, F7, HIGHER];
        uint256[] memory ids = new uint256[](GAP * 4);
        // one commit per product each second of the gap (the keeper prints nothing in these seconds)
        for (uint256 i; i < GAP; ++i) {
            _warp(c0 + uint64(i));
            for (uint256 k; k < 4; ++k) {
                ids[i * 4 + k] = whale.commit(roundId, prods[k], true, LOT, LOT * 2);
            }
        }
        uint64 tFirst = c0 + 2;
        uint64 tLast = c0 + uint64(GAP - 1) + 2;
        // one bad print, 3.5% off, at the end of the gap: prevTs is the last print before the gap
        uint256 bad = S0 * 1035 / 1000;
        _warp(tLast);
        _mirror(ticker, _grid(bad), tLast);
        bytes memory report = _signedPrint(ticker, _grid(bad), tLast, tFirst - 1);

        // the budget of that print, as the lens shows it before the fills: g at the print's ts
        (uint256 printBudget,) = lens.riskBudget(roundId, tLast);
        uint256 filled;
        for (uint256 i; i < ids.length; ++i) {
            if (whale.fill(ids[i], report)) ++filled;
        }

        uint256 elsewhere;
        for (uint64 t = tFirst; t < tLast; ++t) {
            elsewhere += book.riskUsed(roundId, t);
        }
        uint256 taken = book.riskUsed(roundId, tLast);
        (, uint256 used) = lens.riskBudget(roundId, tLast);
        console.log("one budget (chips)", printBudget / 1e18);
        console.log("risk taken at one print (chips)", taken / 1e18);
        console.log("fills", filled, "of", ids.length);
        assertEq(elsewhere, 0, "nothing is keyed by the commit instants");
        assertEq(used, taken, "the lens reads the same key");
        assertLe(taken, printBudget, "one print takes at most one budget");
        assertGt(filled, 0, "the first lots fit");
        assertLt(filled, ids.length, "the budget stopped the burst");
    }

    /// @dev The lens's view of a future commit instant t is the print of t itself: the budget it shows is
    ///      the one the fill takes from, with the same g.
    function test_lensBudgetOfAFutureInstantIsTheFillsBudget() public {
        uint256 id = whale.commit(roundId, F6, true, LOT, LOT * 2);
        uint64 t = router.getCommit(id).fillTs;
        (uint256 budget, uint256 used0) = lens.riskBudget(roundId, t);
        assertEq(used0, 0);
        assertTrue(whale.fill(id, _printFor(id, S0)));
        (uint256 budgetAfter, uint256 used) = lens.riskBudget(roundId, t);
        assertEq(budgetAfter, budget, "g at ts is the g the hook used");
        assertGt(used, 0);
        assertEq(used, book.riskUsed(roundId, t));
    }
}
