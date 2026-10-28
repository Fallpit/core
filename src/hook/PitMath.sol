// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {RefundReason} from "../interfaces/IFallpitHook.sol";

/// @title PitMath
/// @notice The small pure pieces of a fill that the hook and the lens must compute identically: a round's
///         menu of products, the winners of a close, the pooled worst-case payout, the product cap, the
///         solvency and loss limit check, the pricing context of an oracle print, and the fees. The clock
///         that feeds the context is `PitClock`.
/// @dev A round's **menu** is its list of products, frozen when it opens. Product `i` is one ERC-6909 ticket
///      on a contiguous run of bands `[lo, hi]` (bands 0..39, both ends included) that pays one chip per
///      ticket when the close's band is inside the run and nothing otherwise. Runs may overlap and need not
///      cover the ladder. A menu is one word: its lowest byte is the number of products n (2 to 12), and
///      product i takes the 16 bits from bit `8 + 16 * i`: `lo` in the low byte, `hi` in the high byte.
///      Everything above the n products is zero.
///      All rates are WAD. Every rounding goes against the trader.
library PitMath {
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @dev Depth never decays below 30% of its opening value.
    uint256 internal constant G_FLOOR = 0.3e18;
    uint256 internal constant BANDS = 40;
    uint8 internal constant LAST_BAND = 39;
    /// @dev A product that covers at least this many bands (half the ladder) has no product cap.
    uint256 internal constant HALF_LADDER = 20;
    uint256 internal constant MIN_PRODUCTS = 2;
    uint256 internal constant MAX_PRODUCTS = 12;

    /// @notice The risk budget of one print (WAD chips): `capital * riskCapBps * g / 1e4`, capital in the
    ///         chip's units (`decimals`), g WAD. Rounded down.
    function riskBudget(uint256 capital, uint8 decimals, uint256 riskCapBps, uint256 g)
        internal
        pure
        returns (uint256)
    {
        return capital * 10 ** (18 - decimals) * riskCapBps / WAD * g / BPS;
    }

    /// @notice Number of products of `menu`.
    function count(uint256 menu) internal pure returns (uint256) {
        return menu & 0xff;
    }

    /// @notice Band run `[lo, hi]` of product `index` of `menu` (zeros for an index the menu does not have).
    function run(uint256 menu, uint256 index) internal pure returns (uint8 lo, uint8 hi) {
        uint256 word = menu >> (8 + 16 * index);
        return (uint8(word), uint8(word >> 8));
    }

    /// @notice Packs runs into a menu word. Does not validate: see `validMenu`.
    function pack(uint8[] memory lo, uint8[] memory hi) internal pure returns (uint256 menu) {
        uint256 n = lo.length;
        menu = n;
        for (uint256 i; i < n; ++i) {
            menu |= (uint256(lo[i]) | uint256(hi[i]) << 8) << (8 + 16 * i);
        }
    }

    /// @notice True for a well-formed menu: 2 to 12 products, every run with `lo <= hi <= 39`, and nothing
    ///         stored above the last product.
    function validMenu(uint256 menu) internal pure returns (bool) {
        uint256 n = count(menu);
        if (n < MIN_PRODUCTS || n > MAX_PRODUCTS || menu >> (8 + 16 * n) != 0) return false;
        for (uint256 i; i < n; ++i) {
            (uint8 lo, uint8 hi) = run(menu, i);
            if (lo > hi || hi > LAST_BAND) return false;
        }
        return true;
    }

    /// @notice True when a product on `[lo, hi]` is under the product cap: it is narrower than half the
    ///         ladder (a floor). A product of 20 bands or more (the HIGHER / LOWER pair) is not.
    function capped(uint8 lo, uint8 hi) internal pure returns (bool) {
        return uint256(hi) - lo + 1 < HALF_LADDER;
    }

    /// @notice True when `supply` tokens of a product on `[lo, hi]` are more than its cap allows:
    ///         `capBps` of the round's capital for a capped product, no limit otherwise.
    function overCap(uint8 lo, uint8 hi, uint256 supply, uint256 capital, uint256 capBps)
        internal
        pure
        returns (bool)
    {
        return capped(lo, hi) && supply * BPS > capital * capBps;
    }

    /// @notice Log return of inner edge m (0..38): `(m - 19) * sigma / 4`, as `ILadderMath.edge` rounds it.
    function edge(uint256 sigma, uint256 m) internal pure returns (int256) {
        return (int256(m) - 19) * int256(sigma) / 4;
    }

    /// @notice Price range of a product on `[lo, hi]` of a round that starts from `s0` with `sigma`: the
    ///         product pays when `low <= close < high`, up to rounding (the outcome itself is decided on
    ///         the band of `ln(close / s0)`, not on these two numbers).
    /// @return low price of the run's lower edge, WAD; 0 when the run starts at band 0
    /// @return high price of the run's upper edge, WAD; the largest uint256 when the run ends at band 39
    function bounds(uint256 s0, uint256 sigma, uint8 lo, uint8 hi)
        internal
        pure
        returns (uint256 low, uint256 high)
    {
        if (lo != 0) low = s0.mulWad(uint256(FixedPointMathLib.expWad(edge(sigma, uint256(lo) - 1))));
        high = hi < LAST_BAND
            ? s0.mulWad(uint256(FixedPointMathLib.expWad(edge(sigma, hi))))
            : type(uint256).max;
    }

    /// @notice Bit mask of the products of `menu` that win when the close falls in `band`: bit i is set
    ///         when the run of product i contains the band.
    function winners(uint256 menu, uint8 band) internal pure returns (uint16 mask) {
        uint256 n = count(menu);
        for (uint256 i; i < n; ++i) {
            (uint8 lo, uint8 hi) = run(menu, i);
            if (lo <= band && band <= hi) mask |= uint16(1 << i);
        }
    }

    /// @notice Sum of the supplies of the products in `mask`.
    function payoutOf(uint256[12] memory supply, uint16 mask) internal pure returns (uint256 sum) {
        for (uint256 i; i < MAX_PRODUCTS; ++i) {
            if (mask >> i & 1 == 1) sum += supply[i];
        }
    }

    /// @notice Largest payout over the 40 bands: the payout if the close lands in band j is the sum of
    ///         the supplies of every product whose run contains j.
    /// @dev A difference array over the bands: each product adds its supply at `lo` and takes it off
    ///      after `hi`; the running sum is the payout of each band.
    function maxPayout(uint256[12] memory supply, uint256 menu) internal pure returns (uint256 worst) {
        int256[41] memory step;
        uint256 n = count(menu);
        for (uint256 i; i < n; ++i) {
            (uint8 lo, uint8 hi) = run(menu, i);
            int256 s = int256(supply[i]);
            step[lo] += s;
            step[uint256(hi) + 1] -= s;
        }
        int256 payout;
        for (uint256 j; j < BANDS; ++j) {
            payout += step[j];
            if (uint256(payout) > worst) worst = uint256(payout);
        }
    }

    /// @notice The check a round makes after every fill, on its state with the fill applied. The cushion
    ///         `held - protocolFees - maxPayout(supply, menu)` is what the house has left if the close
    ///         lands in the worst band.
    ///         - Solvency, for every fill: the cushion is not negative.
    ///         - Loss limit, for a buy only: the cushion is at least `capital * (10000 - lossLimitBps) /
    ///           10000`, so buying can put at most `lossLimitBps` of the capital at risk. A sell is
    ///           exempt: a holder can always exit.
    /// @return `RefundReason.None` when the fill may stand, else the reason it is rejected for
    function postFillCheck(
        uint256[12] memory supply,
        uint256 menu,
        uint256 held,
        uint256 protocolFees,
        uint256 capital,
        uint256 lossLimitBps,
        bool isBuy
    ) internal pure returns (RefundReason) {
        uint256 need = maxPayout(supply, menu) + protocolFees;
        if (need > held) return RefundReason.Solvency;
        // cross-multiplied, so the division never rounds in the trader's favour
        if (isBuy && (held - need) * BPS < capital * (BPS - lossLimitBps)) return RefundReason.LossLimit;
        return RefundReason.None;
    }

    /// @notice Pricing context of an oracle print made when `rho` of the round's variance is still ahead
    ///         (`PitClock`).
    /// @return x ln(price / s0)
    /// @return sd remaining standard deviation: sigma * sqrt(rho)
    /// @return gNew depth scale: min(g, max(sqrt(rho), 0.3)), so it never rises
    function context(uint256 sigma, uint256 rho, uint256 s0, uint256 price, uint256 g)
        internal
        pure
        returns (int256 x, uint256 sd, uint256 gNew)
    {
        gNew = rho.sqrtWad();
        sd = sigma.mulWad(gNew);
        if (gNew < G_FLOOR) gNew = G_FLOOR;
        if (gNew > g) gNew = g;
        x = FixedPointMathLib.lnWad(int256(price.divWad(s0)));
    }

    /// @notice Fee rate at `ts`: `baseFee` until `ramp` seconds before the close, then linear to `closeFee`.
    function feeRate(uint256 baseFee, uint256 closeFee, uint256 ramp, uint64 closeTs, uint64 ts)
        internal
        pure
        returns (uint256)
    {
        if (ts >= closeTs) return closeFee;
        uint256 left = closeTs - ts;
        if (left >= ramp) return baseFee;
        return baseFee + (closeFee - baseFee).mulDivUp(ramp - left, ramp);
    }

    /// @notice What a buyer pays: the cost rounded up to a chip unit (at least one unit), never less than
    ///         `minPrice` per share, plus fees.
    /// @param amountWad `ILadderMath.Fill.amount` of the buy
    /// @param scale 10^(18 - chip decimals)
    /// @param vegaPerShare vega fee per share, WAD
    /// @param minPrice least a buyer is charged per share before fees, WAD (the round's `minPriceWad`)
    /// @return total chips the buyer pays
    /// @return fee part of `total` that is fee
    function buyCost(
        uint256 amountWad,
        uint256 scale,
        uint256 shares,
        uint256 rate,
        uint256 vegaPerShare,
        uint256 minPrice
    ) internal pure returns (uint256 total, uint256 fee) {
        uint256 amount = amountWad.divUp(scale);
        uint256 least = shares.mulWadUp(minPrice);
        if (amount < least) amount = least;
        if (amount == 0) amount = 1;
        fee = amount.mulWadUp(rate) + shares.mulWadUp(vegaPerShare);
        total = amount + fee;
    }

    /// @notice What a seller receives: the proceeds rounded down to a chip unit minus fees, floored at 0.
    /// @return net chips the seller receives
    /// @return fee chips kept as fee (at most the proceeds)
    function sellProceeds(
        uint256 amountWad,
        uint256 scale,
        uint256 shares,
        uint256 rate,
        uint256 vegaPerShare
    ) internal pure returns (uint256 net, uint256 fee) {
        uint256 amount = amountWad / scale;
        fee = amount.mulWadUp(rate) + shares.mulWadUp(vegaPerShare);
        if (fee > amount) fee = amount;
        net = amount - fee;
    }
}
