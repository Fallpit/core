// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AttackBase} from "./AttackBase.sol";
import {PitAttacker} from "../hook/mocks/PitAttacker.sol";
import {RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";
import {NYTime} from "../../src/lib/NYTime.sol";

/// @notice The risk budget per print second. Every fill of a round priced
///         at one instant t shares `capital * riskCapBps * g / 1e4` of house risk: a buy risks what
///         the house pays beyond the premium (shares minus the engine's amount), a sell the chips it pays
///         out. Many commits for one print cannot each take a full per-fill cap.
contract RiskBudgetTest is AttackBase {
    uint256 internal constant LOT = 10_000e18;

    PitAttacker internal whale;

    /// @dev This suite tests the budget at its real value.
    function _testRiskCapBps() internal pure override returns (uint16) {
        return 300;
    }

    function setUp() public override {
        super.setUp();
        _open();
        whale = _attacker(hook.getConfig(roundId).chip, 2_000_000e18);
    }

    /// @dev Commits `n` buys of `lot` of product `index` as `a`, all for the same fill instant.
    function _commitMany(PitAttacker a, uint8 index, uint256 lot, uint256 n)
        internal
        returns (uint256[] memory ids)
    {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = a.commit(roundId, index, true, lot, lot * 2);
        }
    }

    /// @dev Fills every commit of `ids` at `price`; returns how many filled.
    function _fillAll(PitAttacker a, uint256[] memory ids, uint256 price) internal returns (uint256 filled) {
        for (uint256 i; i < ids.length; ++i) {
            if (a.fill(ids[i], _printFor(ids[i], price))) ++filled;
        }
    }

    function test_manyCommitsAtOnePrintTakeAtMostTheBudget() public {
        uint256[] memory ids = _commitMany(whale, F6, LOT, 20);
        uint64 t = router.getCommit(ids[0]).fillTs;
        (uint256 budget,) = lens.riskBudget(roundId, t);
        assertGt(budget, 0);
        // a print far above the open: F6 (1 to 2 sigma) is now nearly certain, so each lot risks almost
        // all its shares; without the budget all 20 would fill at the stale curve
        uint256 filled = _fillAll(whale, ids, S0 * 1035 / 1000);
        (, uint256 used) = lens.riskBudget(roundId, t);
        assertLe(used, budget, "the fills of one instant never take more than its budget");
        assertLt(filled, 20, "the budget stopped the burst");
        assertGt(filled, 0, "the first lots fit");
        assertEq(book.riskUsed(roundId, t), used);
    }

    function test_theNextInstantHasItsOwnBudget() public {
        uint256[] memory ids = _commitMany(whale, F6, LOT, 20);
        _fillAll(whale, ids, S0);
        uint64 t = router.getCommit(ids[0]).fillTs;
        // one second on: a fresh budget
        vm.warp(clock + 1);
        clock = uint64(block.timestamp);
        uint256 id = whale.commit(roundId, F6, true, LOT, LOT * 2);
        assertGt(router.getCommit(id).fillTs, t, "a later instant");
        assertTrue(whale.fill(id, _printFor(id, S0)), "a new instant fills");
    }

    function test_interleavingInstantsResetsNothing() public {
        uint256[] memory early = _commitMany(whale, F6, LOT, 20);
        uint64 t = router.getCommit(early[0]).fillTs;
        vm.warp(clock + 1);
        clock = uint64(block.timestamp);
        uint256 later = whale.commit(roundId, F6, true, LOT, LOT * 2);
        (uint256 budget,) = lens.riskBudget(roundId, t);
        // the one at t + 1 cannot go between the fills at t (the round's fills go in commit order), and
        // the budget of t binds the commits at t
        vm.warp(t);
        clock = t;
        assertTrue(whale.fill(early[0], _print(t, S0)));
        bytes memory laterPrint = _printFor(later, S0);
        vm.expectRevert(
            abi.encodeWithSelector(IFallpitRouter.EarlierCommitPending.selector, early[early.length - 1])
        );
        whale.fill(later, laterPrint);
        for (uint256 i = 1; i < early.length; ++i) {
            whale.fill(early[i], _print(t, S0));
        }
        assertLe(book.riskUsed(roundId, t), budget, "a fill at another instant does not reset t");
        whale.fill(later, laterPrint);
    }

    function test_aRefusedFillIsRefundedAsCapAndTheLensForesawIt() public {
        uint256[] memory ids = _commitMany(whale, F6, LOT, 20);
        uint64 t = router.getCommit(ids[0]).fillTs;
        vm.warp(t);
        clock = t;
        for (uint256 i; i < ids.length; ++i) {
            (,,,,, RefundReason why) = lens.quote(roundId, F6, true, LOT, S0, t);
            bool filled = whale.fill(ids[i], _print(t, S0));
            assertEq(filled, why == RefundReason.None, "the lens foresaw the fill");
            if (!filled) {
                assertEq(uint8(why), uint8(RefundReason.Cap), "refused for the budget");
                break;
            }
        }
    }

    function test_maxBuyFitsAndOneTokenMoreDoesNot() public {
        uint64 t = clock + 2;
        uint256 most = lens.maxBuy(roundId, F6, S0, t);
        assertGt(most, 0);
        (,,,,, RefundReason ok) = lens.quote(roundId, F6, true, most, S0, t);
        assertEq(uint8(ok), uint8(RefundReason.None), "maxBuy fits");
        IPitBook.Params memory p = hook.getConfig(roundId).params;
        uint256 ceiling = hook.getConfig(roundId).maxFill;
        if (most < ceiling) {
            (,,,,, RefundReason over) = lens.quote(roundId, F6, true, most + 2e18, S0, t);
            assertEq(uint8(over), uint8(RefundReason.Cap), "a little more is over the budget");
        }
        assertEq(p.riskCapBps, 300);
    }

    function test_theBudgetShrinksTowardTheClose() public {
        (uint256 early,) = lens.riskBudget(roundId, clock);
        uint64 late = NYTime.closeTs(day) - 10 minutes;
        (uint256 atClose,) = lens.riskBudget(roundId, late);
        assertLt(atClose, early, "less room late in the day");
        // g never falls under 0.3: the budget never falls under 30% of its value at g = 1
        uint256 floorBudget = HOUSE_CAPITAL * 300 / 10_000 * 3 / 10;
        assertGe(atClose, floorBudget - 1e18);
    }

    function test_paramsBoundsAreChecked() public {
        IPitBook.Params memory p = book.defaultParams();
        p.riskCapBps = 5;
        vm.prank(owner);
        vm.expectRevert();
        book.setDefaultParams(p);
        p.riskCapBps = 10_001;
        vm.prank(owner);
        vm.expectRevert();
        book.setDefaultParams(p);
    }
}
