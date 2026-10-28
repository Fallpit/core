// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IntegrationFixture} from "./IntegrationFixture.sol";
import {MockChip} from "../hook/mocks/MockChips.sol";
import {PitAttacker} from "../hook/mocks/PitAttacker.sol";
import {IFallpitHook, RefundReason} from "../../src/interfaces/IFallpitHook.sol";

/// @notice Shared pieces of the attack suite against the real contracts: an attacker contract (`eve`) with
///         chips, two funded honest users, and helpers to trade as the attacker.
abstract contract AttackBase is IntegrationFixture {
    PitAttacker internal eve;
    uint256 internal constant EVE_CHIPS = 200_000e18;
    uint256 internal constant STAKE = 100_000e18;

    event Refunded(uint256 indexed commitId, address indexed user, RefundReason reason);

    function setUp() public virtual override {
        super.setUp();
        eve = _attacker(address(chip), EVE_CHIPS);
        _fund(alice, STAKE);
        _fund(bob, STAKE);
    }

    function _attacker(address chip_, uint256 amount) internal returns (PitAttacker a) {
        a = new PitAttacker{value: 10 ether}(router, hook);
        MockChip(chip_).mint(address(a), amount);
        a.approve(chip_, address(router));
    }

    function _commit(PitAttacker a, uint8 index, bool isBuy, uint256 shares) internal returns (uint256) {
        address asset = hook.getConfig(roundId).chip;
        if (isBuy) a.approve(asset, address(router)); // a sell needs no approval
        return a.commit(roundId, index, isBuy, shares, isBuy ? MockChip(asset).balanceOf(address(a)) : 0);
    }

    /// @dev Commit and fill as attacker `a`; false when the commit was refunded.
    function _tryTrade(PitAttacker a, uint8 index, bool isBuy, uint256 shares, uint256 price)
        internal
        returns (bool)
    {
        uint256 id = _commit(a, index, isBuy, shares);
        return a.fill(id, _printFor(id, price));
    }

    function _trade(PitAttacker a, uint8 index, bool isBuy, uint256 shares, uint256 price) internal {
        require(_tryTrade(a, index, isBuy, shares, price), "trade refunded");
    }

    function _eveBuy(uint8 index, uint256 shares, uint256 price) internal returns (uint256 cost) {
        uint256 before = MockChip(roundChip).balanceOf(address(eve));
        _trade(eve, index, true, shares, price);
        cost = before - MockChip(roundChip).balanceOf(address(eve));
    }

    function _eveSell(uint8 index, uint256 shares, uint256 price) internal returns (uint256 proceeds) {
        uint256 before = MockChip(roundChip).balanceOf(address(eve));
        _trade(eve, index, false, shares, price);
        proceeds = MockChip(roundChip).balanceOf(address(eve)) - before;
    }

    /// @dev The round is exactly as it opened: no supply, no premium, no pricing state, full depth.
    function _assertPristine() internal view {
        IFallpitHook.RoundState memory st = _state();
        assertEq(st.held, hook.getConfig(roundId).capital);
        assertEq(st.g, 1e18);
        assertEq(st.protocolFees, 0);
        (int256[40] memory v,) = hook.getCurve(roundId);
        for (uint256 j; j < 40; ++j) {
            assertEq(v[j], 0);
        }
        (uint256[12] memory supply, uint256[12] memory premium) = hook.getSupplies(roundId);
        for (uint256 i; i < MAX_PRODUCTS; ++i) {
            assertEq(supply[i], 0);
            assertEq(premium[i], 0);
            if (i < PRODUCTS) assertEq(_token(uint8(i)).totalSupply(), 0);
        }
    }
}
