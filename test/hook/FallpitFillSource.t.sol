// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {HookFixture} from "./HookFixture.sol";
import {PitAttacker} from "./mocks/PitAttacker.sol";
import {IFallpitHook} from "../../src/interfaces/IFallpitHook.sol";
import {IFallpitRouter} from "../../src/interfaces/IFallpitRouter.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";

/// @notice With two oracle sources, two prints can qualify for one instant (the first trustless print and
///         the first keeper print at or after it). A round that pins one source leaves the filler no choice.
contract FallpitFillSourceTest is HookFixture {
    PitAttacker internal eve;

    function setUp() public override {
        super.setUp();
        eve = new PitAttacker{value: 10 ether}(router, hook);
        chip.mint(address(eve), 100_000e18);
        eve.approve(address(chip), address(router));
    }

    function _twoPrints(uint256 id) internal returns (bytes memory keeperPrint, bytes memory trustlessPrint) {
        uint64 t = router.getCommit(id).fillTs;
        keeperPrint = oracle.post(NVDA, KEEPER, S0, t);
        trustlessPrint = oracle.post(NVDA, TRUSTLESS, S0 * 9995 / 10_000, t + 1); // 5 bps lower
        _warp(t + 2);
    }

    /// @dev If both sources qualified, the filler could choose the cheaper print, which would make
    ///      complete sets cost less than they pay. Every round is pinned to exactly one source, so the
    ///      attempt fills only with the round's own source however the filler orders the prints.
    function test_noEitherSource_theFillerCannotPickThePrint() public {
        _open();
        assertEq(uint8(hook.getConfig(roundId).fillSource), uint8(IPitBook.FillSource.KeeperOnly));
        // the enum has two members and no "either"
        assertEq(uint8(type(IPitBook.FillSource).max), 1);
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, 100_000e18);
        (bytes memory keeperPrint, bytes memory trustlessPrint) = _twoPrints(id);
        bytes[] memory reports = new bytes[](2);
        reports[0] = trustlessPrint; // cheaper for a HIGHER buyer
        reports[1] = keeperPrint;
        assertEq(eve.fillWithAny(id, reports), 1, "the cheaper print of the other source does not fill");
    }

    function test_keeperOnly_leavesNoChoice() public {
        _reseed(
            NVDA,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.KeeperOnly
        );
        _open();
        assertEq(uint8(hook.getConfig(roundId).fillSource), uint8(IPitBook.FillSource.KeeperOnly));
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, 100_000e18);
        (bytes memory keeperPrint, bytes memory trustlessPrint) = _twoPrints(id);

        vm.expectRevert();
        eve.fill(id, trustlessPrint);
        assertEq(uint8(router.getCommit(id).status), uint8(IFallpitRouter.CommitStatus.Pending));
        bytes[] memory reports = new bytes[](2);
        reports[0] = trustlessPrint;
        reports[1] = keeperPrint;
        assertEq(eve.fillWithAny(id, reports), 1, "only the keeper print fills");
    }

    function test_trustlessOnly_leavesNoChoice() public {
        _reseed(
            NVDA,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.TrustlessOnly
        );
        _open();
        uint256 id = eve.commit(roundId, HIGHER, true, 5_000e18, 100_000e18);
        (bytes memory keeperPrint, bytes memory trustlessPrint) = _twoPrints(id);
        bytes[] memory reports = new bytes[](2);
        reports[0] = keeperPrint;
        reports[1] = trustlessPrint;
        assertEq(eve.fillWithAny(id, reports), 1, "only the trustless print fills");

        // the policy of an open round is frozen: changing the ticker's policy does not reach it
        vm.prank(owner);
        book.registerTicker(
            NVDA,
            SEED_VAR,
            IPitBook.Clock.NYWeekdays,
            IPitBook.Weights(0, 0, 0, 0),
            0,
            IPitBook.FillSource.KeeperOnly
        );
        assertEq(uint8(hook.getConfig(roundId).fillSource), uint8(IPitBook.FillSource.TrustlessOnly));
        // closes accept either source whatever the fill policy
        _recordClose(S0, KEEPER);
        hook.settleRound(house, day);
    }
}
