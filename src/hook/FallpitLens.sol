// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IFallpitHook, RefundReason} from "../interfaces/IFallpitHook.sol";
import {ILadderMath} from "../interfaces/ILadderMath.sol";
import {IPitBook} from "./IPitBook.sol";
import {PitMath} from "./PitMath.sol";
import {PitClock} from "./PitClock.sol";

/// @title FallpitLens
/// @notice Read-only helpers for apps and keepers, kept out of the hook to keep it under the code size
///         limit. Quotes use the same `PitMath`, `PitClock` and `ILadderMath` code as the hook, so a quote
///         for the print a fill will use equals what the fill charges if no other fill lands first.
contract FallpitLens {
    using FixedPointMathLib for uint256;

    /// @notice One product of a round's menu, as `market` returns it.
    /// @param lo first band of the product's run (0..39)
    /// @param hi last band of the run
    /// @param capped true when the product is under the round's product cap (a floor: fewer than 20 bands)
    /// @param won true when the round is settled and the close landed in the run
    /// @param dead true when the engine prices the product under the round's minimum price: a buy is
    ///        charged the minimum, not the model's price, so the multiple shown is the minimum price's and
    ///        not the odds. An app should grey the product out rather than advertise it. False when
    ///        nothing is priced
    /// @param id the product's ticket: an ERC-6909 id of the hook (`IFallpitHook.tokenId`)
    /// @param low price of the run's lower edge, WAD (0: none, the run starts at the bottom)
    /// @param high price of the run's upper edge, WAD (the largest uint256: none)
    /// @param supply outstanding tokens: what the product pays if it wins, in chip units
    /// @param premium cost basis of the outstanding tokens, in chip units
    /// @param cap most tokens that may be outstanding, in chip units (the largest uint256 when not capped)
    /// @param capUsedBps `supply` as a share of `cap`, in basis points (0 when not capped)
    /// @param price what the engine asks for the next token, before fees, WAD: the odds of the product
    /// @param buyPrice what the next token is charged at before fees: `price`, or the round's minimum
    ///        price when that is higher, WAD
    /// @param multiple chips a token pays per chip of `buyPrice` when the product wins, WAD (fees not
    ///        counted; 0 when `buyPrice` is 0)
    struct Product {
        uint8 lo;
        uint8 hi;
        bool capped;
        bool won;
        bool dead;
        uint256 id;
        uint256 low;
        uint256 high;
        uint256 supply;
        uint256 premium;
        uint256 cap;
        uint256 capUsedBps;
        uint256 price;
        uint256 buyPrice;
        uint256 multiple;
    }

    /// @notice A round and its whole menu at one oracle price, as `market` returns it.
    /// @param status the round's status
    /// @param tradable true when a fill may be priced by a print made at the given time
    /// @param rho share of the round's variance still ahead at that time, WAD
    /// @param feeRate the fee rate of a fill at that time, WAD (the vega fee comes on top: `quote`)
    /// @param s0 the close the round starts from, WAD
    /// @param sigma the round's standard deviation, WAD
    /// @param sigmaEff the sigma the remaining sd and the vega use now (house vol learning), WAD
    /// @param capital chips the house brought to the round
    /// @param cushion chips the house has left if the close lands in the worst band
    /// @param floor the smallest cushion a buy may leave (the loss limit)
    /// @param maxFill most tokens in one fill
    /// @param minShares fewest tokens in one commit
    /// @param minPrice least a buy is charged per token before fees, WAD
    /// @param fillFee native coin, in wei, to send with every commit
    /// @param products the menu, in the order of the product indices
    struct Market {
        IFallpitHook.Status status;
        bool tradable;
        uint256 rho;
        uint256 feeRate;
        uint256 s0;
        uint256 sigma;
        uint256 sigmaEff;
        uint256 capital;
        uint256 cushion;
        uint256 floor;
        uint256 maxFill;
        uint256 minShares;
        uint256 minPrice;
        uint256 fillFee;
        Product[] products;
    }

    /// @dev The round's menu has no product with that index.
    error UnknownProduct();
    error ZeroAddress();

    IFallpitHook public immutable hook;
    ILadderMath public immutable math;

    /// @dev solc 0.8.26 under-counts the constructor bytes that write the two immutables into the runtime
    ///      (solidity issue 15004, fixed in 0.8.27) and fails with "Assembly exception for bytecode" when
    ///      the constructor's size sits at the 255-byte boundary. The zero check keeps it well above.
    constructor(IFallpitHook hook_, ILadderMath math_) {
        if (address(hook_) == address(0) || address(math_) == address(0)) revert ZeroAddress();
        hook = hook_;
        math = math_;
    }

    /// @notice Chips a buyer would pay, or a seller would receive, for `shares` of product `product` if the
    ///         fill were priced at oracle `price` (WAD) printed at `ts`, and whether the hook would take
    ///         the fill.
    /// @dev The price is always returned. `rejection` applies the hook's own checks in the hook's order
    ///      (round open, per-fill cap, product cap, trading window, solvency, loss limit) to the round as
    ///      it is now;
    ///      a fill that lands after other fills can still differ. The commit's own limit and fill window
    ///      are the router's and are not known here.
    /// @return chips total paid (buy) or net received (sell), in chip units
    /// @return fee fee inside `chips`
    /// @return pBefore price of the token before the trade, WAD
    /// @return pAfter price of the token after the trade, WAD
    /// @return fillFee native coin, in wei, to send with `FallpitRouter.commit` for this round: the pay
    ///         of whoever fills the commit, returned if nobody does
    /// @return rejection `RefundReason.None` when the hook would take the fill; else why the commit would
    ///         be refunded: `NotOpen`, `Cap`, `ProductCap` (a buy that would take a floor's outstanding
    ///         supply above its cap), `Window`, `Solvency`, or `LossLimit` (a buy that would put more of
    ///         the house's capital at risk than the round allows)
    function quote(bytes32 roundId, uint8 product, bool isBuy, uint256 shares, uint256 price, uint64 ts)
        external
        view
        returns (
            uint256 chips,
            uint256 fee,
            uint256 pBefore,
            uint256 pAfter,
            uint256 fillFee,
            RefundReason rejection
        )
    {
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        IFallpitHook.RoundState memory st = hook.getState(roundId);
        Pricing memory z = _pricing(roundId, c, st, product, price, ts);
        ILadderMath.Fill memory f = _fill(z, isBuy, shares);
        (chips, fee) = isBuy
            ? PitMath.buyCost(f.amount, z.scale, shares, z.rate, z.vegaFee.mulWad(f.vega), z.minPrice)
            : PitMath.sellProceeds(f.amount, z.scale, shares, z.rate, z.vegaFee.mulWad(f.vega));
        (pBefore, pAfter, fillFee) = (f.pBefore, f.pAfter, c.params.fillFee);

        // the round's books with this fill applied, as the hook writes them
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        if (isBuy) supply[product] += shares;
        else supply[product] = supply[product] > shares ? supply[product] - shares : 0;
        if (st.status != IFallpitHook.Status.Open) {
            rejection = RefundReason.NotOpen;
        } else if (
            shares > c.maxFill || _risk(z, isBuy, shares, f.amount) > _riskLeft(roundId, c, z.ctx.gNew, ts)
        ) {
            rejection = RefundReason.Cap;
        } else if (isBuy && PitMath.overCap(z.lo, z.hi, supply[product], c.capital, c.params.floorCapBps)) {
            rejection = RefundReason.ProductCap;
        } else if (!z.tradable) {
            rejection = RefundReason.Window;
        } else if (!isBuy && chips > st.held) {
            rejection = RefundReason.Solvency;
        } else {
            rejection = PitMath.postFillCheck(
                supply,
                c.params.menu,
                isBuy ? st.held + chips : st.held - chips,
                st.protocolFees + fee * c.params.protocolFeeBps / PitMath.BPS,
                c.capital,
                c.params.lossLimitBps,
                isBuy
            );
        }
    }

    /// @notice What a buy of product `product` costs all in, at oracle `price` (WAD) printed at `ts`, at
    ///         three sizes: one token, ten tokens and the round's per-fill cap. `Product.multiple` is the
    ///         next token's; a ticket of size moves the price, and this is what the app shows as "the
    ///         multiple at size". Every cost is `quote`'s for that size: the engine's amount or the minimum
    ///         price, the fee and the vega fee. Nothing here says whether the hook would take the fill
    ///         (`quote` does).
    /// @dev Three pricing calls, about 7M gas: ask it per product, not for a whole menu in one call.
    /// @return shares the three sizes, in chip units (the second may exceed the cap; the third is the cap)
    /// @return cost chips paid all in for each size
    /// @return multiple chips a size pays per chip of its cost when the product wins, WAD (0, with `cost`,
    ///         when nothing is priced: the round is unknown, or `ts` is at or after its close)
    function buyCosts(bytes32 roundId, uint8 product, uint256 price, uint64 ts)
        external
        view
        returns (uint256[3] memory shares, uint256[3] memory cost, uint256[3] memory multiple)
    {
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        IFallpitHook.RoundState memory st = hook.getState(roundId);
        Pricing memory z = _pricing(roundId, c, st, product, price, ts);
        uint256 token = 10 ** c.decimals;
        (shares[0], shares[1], shares[2]) = (token, 10 * token, c.maxFill);
        if (st.status == IFallpitHook.Status.None || z.ctx.sd == 0) return (shares, cost, multiple);
        for (uint256 i; i < 3; ++i) {
            ILadderMath.Fill memory f = _fill(z, true, shares[i]);
            (cost[i],) =
                PitMath.buyCost(f.amount, z.scale, shares[i], z.rate, z.vegaFee.mulWad(f.vega), z.minPrice);
            if (cost[i] != 0) multiple[i] = shares[i] * PitMath.WAD / cost[i];
        }
    }

    /// @dev Everything a fill of one product at one print is priced with: the engine's inputs (the stored
    ///      curve, the context of the print) and the fee terms of the round.
    struct Pricing {
        uint8 lo;
        uint8 hi;
        bool tradable;
        uint256 sigma;
        uint256 scale;
        uint256 rate;
        uint256 vegaFee;
        uint256 minPrice;
        ILadderMath.Ctx ctx;
        int256[40] v;
        uint256[40] b0;
    }

    function _pricing(
        bytes32 roundId,
        IFallpitHook.RoundConfig memory c,
        IFallpitHook.RoundState memory st,
        uint8 product,
        uint256 price,
        uint64 ts
    ) internal view returns (Pricing memory z) {
        if (product >= PitMath.count(c.params.menu)) revert UnknownProduct();
        (z.lo, z.hi) = PitMath.run(c.params.menu, product);
        uint256 rho;
        (rho, z.tradable) = PitClock.at(c.clock, ts);
        (z.ctx.x, z.ctx.sd, z.ctx.gNew) = PitMath.context(hook.sigmaEffOf(roundId), rho, c.s0, price, st.g);
        z.ctx.gOld = st.g;
        z.scale = 10 ** (18 - c.decimals);
        z.rate = PitMath.feeRate(c.params.baseFee, c.params.closeFee, c.params.feeRamp, c.closeTs, ts);
        (z.sigma, z.vegaFee, z.minPrice) = (c.sigma, c.params.vegaFee, c.params.minPriceWad);
        (z.v, z.b0) = hook.getCurve(roundId);
    }

    /// @dev The engine's fill of `shares` on the product of `z`, as the hook would compute it.
    function _fill(Pricing memory z, bool isBuy, uint256 shares)
        internal
        view
        returns (ILadderMath.Fill memory)
    {
        int256 delta = int256(shares * z.scale);
        return math.fill(z.v, z.b0, z.sigma, z.ctx, z.lo, z.hi, isBuy ? delta : -delta);
    }

    /// @notice A round and its whole menu in one call: every product with its band run, its price range in
    ///         dollars, its token, supply and cap usage, and what it costs and pays at oracle `price`
    ///         (WAD) printed at `ts`. Prices are the engine's for the next token, before fees and before
    ///         any other fill; `quote` has the exact cost of a trade.
    /// @dev One pricing call for the whole menu: the price of a product is the sum of the band prices of
    ///      its run. The prices of a partition of the ladder sum to one, within the engine's 1e-12. At and
    ///      after the round's close (and for an unknown round) nothing is priced: `price`, `buyPrice` and
    ///      `multiple` are zero.
    function market(bytes32 roundId, uint256 price, uint64 ts) external view returns (Market memory m) {
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        IFallpitHook.RoundState memory st = hook.getState(roundId);
        (m.rho, m.tradable) = PitClock.at(c.clock, ts);
        m.status = st.status;
        m.feeRate = PitMath.feeRate(c.params.baseFee, c.params.closeFee, c.params.feeRamp, c.closeTs, ts);
        (m.s0, m.sigma, m.capital, m.maxFill) = (c.s0, c.sigma, c.capital, c.maxFill);
        m.sigmaEff = hook.sigmaEffOf(roundId);
        (m.minPrice, m.fillFee) = (c.params.minPriceWad, c.params.fillFee);
        (m.cushion, m.floor) = lossLimit(roundId);
        m.minShares = uint256(c.params.minTrade).divUp(10 ** (18 - c.decimals));
        if (m.minShares == 0) m.minShares = 1;

        uint256[40] memory p;
        bool priced;
        if (st.status != IFallpitHook.Status.None) {
            (int256[40] memory v, uint256[40] memory b0) = hook.getCurve(roundId);
            (int256 x, uint256 sd,) = PitMath.context(m.sigmaEff, m.rho, c.s0, price, st.g);
            // sd is zero at and after the close: the engine has no prior then, and nothing trades
            priced = sd != 0;
            if (priced) {
                p = math.prices(v, b0, c.sigma, ILadderMath.Ctx({x: x, sd: sd, gOld: st.g, gNew: st.g}));
            }
        }
        (uint256[12] memory supply, uint256[12] memory premium) = hook.getSupplies(roundId);
        uint256 n = PitMath.count(c.params.menu);
        m.products = new Product[](n);
        for (uint256 i; i < n; ++i) {
            Product memory q = m.products[i];
            (q.lo, q.hi) = PitMath.run(c.params.menu, i);
            (q.low, q.high) = PitMath.bounds(c.s0, c.sigma, q.lo, q.hi);
            (q.id, q.supply, q.premium) = (hook.tokenId(roundId, uint8(i)), supply[i], premium[i]);
            q.capped = PitMath.capped(q.lo, q.hi);
            q.won = st.status >= IFallpitHook.Status.Settled && st.winners >> i & 1 == 1;
            q.cap = type(uint256).max;
            if (q.capped) {
                q.cap = c.capital * c.params.floorCapBps / PitMath.BPS;
                if (q.cap != 0) q.capUsedBps = q.supply * PitMath.BPS / q.cap;
            }
            if (!priced) continue;
            for (uint256 j = q.lo; j <= q.hi; ++j) {
                q.price += p[j];
            }
            if (q.price > PitMath.WAD) q.price = PitMath.WAD;
            q.dead = q.price < m.minPrice;
            q.buyPrice = q.dead ? m.minPrice : q.price;
            if (q.buyPrice != 0) q.multiple = PitMath.WAD * PitMath.WAD / q.buyPrice;
        }
    }

    /// @notice Pooled solvency of a round: the worst payout over the 40 bands, and the chips that cover
    ///         it (held minus protocol fees).
    function solvency(bytes32 roundId) external view returns (uint256 worstPayout, uint256 covered) {
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        IFallpitHook.RoundState memory st = hook.getState(roundId);
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        return (PitMath.maxPayout(supply, c.params.menu), st.held - st.protocolFees);
    }

    /// @notice What a round owes in each band: `payout[j]` is the sum of the outstanding supplies of the
    ///         products whose run contains band j, the chips winners take if the close lands there.
    function payouts(bytes32 roundId) external view returns (uint256[40] memory payout) {
        uint256 menu = hook.getConfig(roundId).params.menu;
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        uint256 n = PitMath.count(menu);
        for (uint256 i; i < n; ++i) {
            (uint8 lo, uint8 hi) = PitMath.run(menu, i);
            for (uint256 j = lo; j <= hi; ++j) {
                payout[j] += supply[i];
            }
        }
    }

    /// @notice Where a round stands against its loss limit. Buys are refused while a buy would leave
    ///         `cushion` below `floor`; sells are never refused for it.
    /// @return cushion chips the house has left in the worst band: held, minus protocol fees, minus the
    ///         worst payout (zero when that is negative, which the solvency check prevents)
    /// @return floor the smallest cushion a buy may leave: `capital * (10000 - lossLimitBps) / 10000`
    function lossLimit(bytes32 roundId) public view returns (uint256 cushion, uint256 floor) {
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        IFallpitHook.RoundState memory st = hook.getState(roundId);
        (uint256[12] memory supply,) = hook.getSupplies(roundId);
        uint256 need = PitMath.maxPayout(supply, c.params.menu) + st.protocolFees;
        cushion = st.held > need ? st.held - need : 0;
        floor = c.capital * (PitMath.BPS - c.params.lossLimitBps) / PitMath.BPS;
    }

    /// @notice The clock of a round at `ts`: the share of its variance still ahead (WAD) and whether a
    ///         fill may be priced by a print made at `ts`.
    function clockAt(bytes32 roundId, uint64 ts) external view returns (uint256 rho, bool tradable) {
        return PitClock.at(hook.getConfig(roundId).clock, ts);
    }

    /// @notice The instants that bound the trading windows of a round, unix seconds. A `NYWeekdays` round
    ///         trades in `[prevClose, afterHoursEnd)` (unless its clock skips the after-hours) and in
    ///         `[preMarketStart, cutoff]`; an `EveryDay` round in `[prevClose, cutoff]`. No fill is
    ///         priced before the round was opened (`RoundConfig.openTs`).
    function windows(bytes32 roundId) external view returns (PitClock.Times memory) {
        return PitClock.times(hook.getConfig(roundId).clock);
    }

    /// @notice Largest number of shares one fill of a round may trade (a ceiling; the risk budget of the
    ///         print usually binds first, see `maxBuy`).
    function maxFill(bytes32 roundId) external view returns (uint256) {
        return hook.getConfig(roundId).maxFill;
    }

    /// @notice The risk budget of the print of `ts` (WAD chips): capital * riskCapBps * g / 1e4 with g the
    ///         round's depth scale at `ts` (it never rises), and what fills priced by that print already took
    ///         from it. The hook keys the budget by the print's own timestamp (`IPitBook.takeRisk`).
    /// @dev For a commit instant t: the print that prices it is the first print with ts >= t. For a t in
    ///      the future that is a print of t itself (the keeper prints every second), so pass `ts = t`. After
    ///      a keeper gap one later print prices every instant of the gap, and they all share its budget:
    ///      pass that print's ts.
    function riskBudget(bytes32 roundId, uint64 ts) external view returns (uint256 budget, uint256 used) {
        IFallpitHook.RoundConfig memory c = hook.getConfig(roundId);
        (uint256 rho,) = PitClock.at(c.clock, ts);
        // the hook's gNew at the print (`PitMath.context`)
        uint256 g = rho.sqrtWad();
        if (g < PitMath.G_FLOOR) g = PitMath.G_FLOOR;
        uint256 gOld = hook.getState(roundId).g;
        if (g > gOld) g = gOld;
        budget = _budget(c, g);
        used = hook.book().riskUsed(roundId, ts);
    }

    /// @notice The most shares of `product` one buy priced at oracle `price` (WAD) printed at `ts` can take
    ///         now, with every check the hook makes on a buy: the per-fill ceiling, the product cap, the
    ///         trading window, the risk left in the print's budget, solvency and the loss limit. So a buy of
    ///         this size is one the hook takes if no other fill lands first (`quote` agrees). Zero when
    ///         nothing can be bought. Bisection on the engine (view only, about 12 pricing calls).
    /// @dev `ts` keys the risk budget as in `riskBudget`: for a commit made now, pass its fill instant.
    function maxBuy(bytes32 roundId, uint8 product, uint256 price, uint64 ts)
        external
        view
        returns (uint256)
    {
        Probe memory q;
        q.c = hook.getConfig(roundId);
        q.st = hook.getState(roundId);
        if (q.st.status != IFallpitHook.Status.Open) return 0;
        q.z = _pricing(roundId, q.c, q.st, product, price, ts);
        if (q.z.ctx.sd == 0 || !q.z.tradable) return 0;
        q.left = _riskLeft(roundId, q.c, q.z.ctx.gNew, ts);
        (q.supply,) = hook.getSupplies(roundId);
        q.product = product;
        uint256 hi = q.c.maxFill;
        if (PitMath.capped(q.z.lo, q.z.hi)) {
            // the most the product's supply may reach (`PitMath.overCap`)
            uint256 cap = q.c.capital * q.c.params.floorCapBps / PitMath.BPS;
            uint256 room = cap > q.supply[product] ? cap - q.supply[product] : 0;
            if (room < hi) hi = room;
        }
        if (_takes(q, hi)) return hi;
        uint256 lo;
        uint256 unit = 10 ** q.c.decimals;
        while (hi - lo > unit) {
            uint256 mid = (lo + hi) / 2;
            if (_takes(q, mid)) lo = mid;
            else hi = mid;
        }
        lo = lo / unit * unit;
        // a rounded size the hook would refuse (the checks are monotone in size in practice) gives nothing
        return lo != 0 && _takes(q, lo) ? lo : 0;
    }

    /// @dev What `maxBuy` probes a size against: the round, its pricing at the print, its supplies and the
    ///      risk left in the print's budget.
    struct Probe {
        IFallpitHook.RoundConfig c;
        IFallpitHook.RoundState st;
        Pricing z;
        uint256[12] supply;
        uint256 left;
        uint8 product;
    }

    /// @dev True when the hook would take a buy of `shares` (the window is checked once, in `maxBuy`): the
    ///      per-fill cap, the product cap, the print's risk budget, then solvency and the loss limit on the
    ///      round's books with the buy applied, in the hook's order.
    function _takes(Probe memory q, uint256 shares) internal view returns (bool ok) {
        if (shares == 0) return true;
        IFallpitHook.RoundConfig memory c = q.c;
        if (shares > c.maxFill) return false;
        uint256 before = q.supply[q.product];
        uint256 supplied = before + shares;
        if (PitMath.overCap(q.z.lo, q.z.hi, supplied, c.capital, c.params.floorCapBps)) return false;
        ILadderMath.Fill memory f = _fill(q.z, true, shares);
        if (_risk(q.z, true, shares, f.amount) > q.left) return false;
        (uint256 chips, uint256 fee) =
            PitMath.buyCost(f.amount, q.z.scale, shares, q.z.rate, q.z.vegaFee.mulWad(f.vega), q.z.minPrice);
        q.supply[q.product] = supplied;
        ok = PitMath.postFillCheck(
            q.supply,
            c.params.menu,
            q.st.held + chips,
            q.st.protocolFees + fee * c.params.protocolFeeBps / PitMath.BPS,
            c.capital,
            c.params.lossLimitBps,
            true
        ) == RefundReason.None;
        q.supply[q.product] = before;
    }

    /// @dev What a fill risks for the house, as the hook counts it: a buy what it pays beyond the premium,
    ///      a sell the chips it pays out.
    function _risk(Pricing memory z, bool isBuy, uint256 shares, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        if (!isBuy) return amount;
        uint256 s = shares * z.scale;
        return s > amount ? s - amount : 0;
    }

    function _budget(IFallpitHook.RoundConfig memory c, uint256 g) internal pure returns (uint256) {
        return c.capital * 10 ** (18 - c.decimals) * c.params.riskCapBps / PitMath.WAD * g / PitMath.BPS;
    }

    /// @dev Risk left in the budget of the print of `ts` (the hook's key, `IPitBook.takeRisk`).
    function _riskLeft(bytes32 roundId, IFallpitHook.RoundConfig memory c, uint256 g, uint64 ts)
        internal
        view
        returns (uint256)
    {
        uint256 budget = _budget(c, g);
        uint256 used = hook.book().riskUsed(roundId, ts);
        return budget > used ? budget - used : 0;
    }
}
