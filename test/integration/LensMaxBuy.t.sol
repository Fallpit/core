// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AttackBase} from "./AttackBase.sol";
import {PitAttacker} from "../hook/mocks/PitAttacker.sol";
import {RefundReason} from "../../src/interfaces/IFallpitHook.sol";
import {IPitBook} from "../../src/hook/IPitBook.sol";

/// @notice `FallpitLens.maxBuy` applies every check the hook makes on a buy (per-fill ceiling, risk budget,
///         product cap, loss limit, trading window), and `quote` agrees with it.
contract LensMaxBuyTest is AttackBase {
    uint256 internal constant LOT = 20_000e18;
    PitAttacker internal whale;

    function _openWith(uint16 lossLimitBps, uint16 maxFillBps, uint16 floorCapBps) internal {
        IPitBook.Params memory p = book.defaultParams();
        p.lossLimitBps = lossLimitBps;
        p.maxFillBps = maxFillBps;
        p.floorCapBps = floorCapBps;
        _setParams(p);
        _open();
        whale = _attacker(hook.getConfig(roundId).chip, 5_000_000e18);
    }

    function _why(uint8 product, uint256 shares, uint256 price) internal view returns (RefundReason why) {
        (,,,,, why) = lens.quote(roundId, product, true, shares, price, clock + 2);
    }

    /// @dev A floor with a product cap of 10% of the capital, 80% of it used: maxBuy is the room left.
    function test_maxBuyRespectsTheProductCap() public {
        _openWith(3000, 2000, 1000);
        for (uint256 i; i < 4; ++i) {
            _trade(whale, F6, true, LOT, S0);
        }
        uint256 most = lens.maxBuy(roundId, F6, S0, clock + 2);
        assertEq(most, HOUSE_CAPITAL / 10 - 4 * LOT, "the room under the cap");
        assertEq(uint8(_why(F6, most, S0)), uint8(RefundReason.None), "the hook takes maxBuy");
        assertEq(
            uint8(_why(F6, most + 1e18, S0)), uint8(RefundReason.ProductCap), "one token more does not fit"
        );
        assertTrue(_tryTrade(whale, F6, true, most, S0), "and it fills");
        assertEq(lens.maxBuy(roundId, F6, S0, clock + 2), 0, "the cap is full");
    }

    /// @dev A loss limit of 10% and a per-fill ceiling of 20%: one big buy of a cheap floor reaches the
    ///      loss limit before the ceiling. maxBuy stops at the loss limit.
    function test_maxBuyRespectsTheLossLimit() public {
        _openWith(1000, 2000, 10_000);
        uint256 ceiling = hook.getConfig(roundId).maxFill;
        uint256 most = lens.maxBuy(roundId, F6, S0, clock + 2);
        assertGt(most, 0);
        assertLt(most, ceiling, "the loss limit binds first");
        assertEq(uint8(_why(F6, most, S0)), uint8(RefundReason.None), "the hook takes maxBuy");
        assertEq(
            uint8(_why(F6, most + 2e18, S0)), uint8(RefundReason.LossLimit), "a little more does not fit"
        );
        assertTrue(_tryTrade(whale, F6, true, most, S0), "and it fills");
    }

    /// @dev Outside a trading window nothing can be bought, and maxBuy says so.
    function test_maxBuyIsZeroOutsideTheWindow() public {
        _openWith(3000, 2000, 10_000);
        (, bool tradable) = lens.clockAt(roundId, hook.getConfig(roundId).closeTs);
        assertFalse(tradable);
        assertEq(lens.maxBuy(roundId, F6, S0, hook.getConfig(roundId).closeTs), 0);
    }
}
