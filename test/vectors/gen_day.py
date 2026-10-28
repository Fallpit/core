#!/usr/bin/env python3
"""One simulated round for the day-level differential test (numpy only).

Run from anywhere:  python3 contracts/test/vectors/gen_day.py
Writes day.json next to this file. The output is deterministic (fixed seed).

What it is. A reference implementation, in float64, of one whole Fallpit round as the SPEC describes it:

  - the pricing engine is the cost function of test/vectors/ladder_house_sim.py (`cost_fn`,
    `prices`, `solve_lam` are imported from that file and used unchanged),
  - the prior is the simulator's `fair_probs` with sigma as a parameter (the simulator hard-codes 0.035) and
    the contract's vol mix (the normal CDF averaged over three sd nodes) in place of one normal,
  - on top of it the rules the simulator does not have: the round's clock (SPEC 7.2: a stock round runs
    from the previous close to its own close and trades in the after-hours of the day before, in the
    pre-market and in the regular session; the share of its variance still ahead, rho, falls along a
    straight line inside each of four weighted segments), the oracle-anchored re-prior at every fill and
    the depth decay with its price-preserving rescale (SPEC 7.3), the base fee with its ramp into the
    close and the vega fee, on buys and on sells (SPEC 7.4), the minimum price of a buy, the protocol's
    share of the fees, the product cap of a floor, the pooled solvency check over the 40 bands and the
    per-round loss limit on buys (SPEC 7.5) and the settlement on the close's band.

The round has the book's default menu (SPEC 7.2): eight floors that partition the 40 bands and the HIGHER /
LOWER pair at the previous close. A product is a run of bands [lo, hi]; it pays one chip per token when
the close's band is inside the run.

The round is a stock round (`NYWeekdays`) from a Monday close to the Tuesday close with no daylight-saving
switch in between, so its segments have their usual lengths and the clock is written here in seconds since
the previous close.

What it is not. The simulator this engine was validated with only ever traded the
regular session. This file checks that the contracts compute what the SPEC says in the extended hours
too; it says nothing about whether those rules make money there.

The trader's fill fee (SPEC 7.3) is paid in ETH to whoever fills and never touches the chips, so it has no
part in this day.

The script draws an oracle path, a list of timed trades on the ten products (buys and sells, sizes up to
the per-fill cap) in all three trading windows and a close, prices every fill with the reference math, and
records what the trader pays or receives for each fill and what the house is left with at the end. One
floor is popular: it is bought at the per-fill cap again and again and ends the day far above a tenth
of the capital (the defaults have no product cap: `floorCapBps` 10000). Nothing is refused:
with `alpha` 0.2 the engine bounds what one-sided buying can put at risk at about a fifth of the capital,
so the loss limit at 30% never binds inside one day of ordinary flow (the cushion is recorded at every
fill and its lowest value is in the vector); the product cap code stays here, generic, and is never hit.
Buys of the far floors cost less than the minimum price and are charged the minimum price. The Solidity
test test/integration/DaySim.t.sol replays the same day through the real contracts (keeper-signed prints,
router, hook, LadderMath, vault) and compares every fill, the cushion after every fill and the final
house result.

All amounts are written as decimal strings of WAD (1e18) integers so that Foundry parses them exactly.
"""
import importlib.util
import json
import math
import random
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
SIM_PATH = HERE / "ladder_house_sim.py"

spec = importlib.util.spec_from_file_location("ladder_house_sim", SIM_PATH)
sim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sim)

WAD = 10 ** 18
NB = 40
SQ2 = math.sqrt(2.0)
SQRT_2PI = math.sqrt(2.0 * math.pi)

# ---- the round's frozen configuration (the book's defaults; SPEC 7)
SIGMA = 0.02                 # daily standard deviation of the log return
S0 = 180.0                   # previous close
CAPITAL = 1_000_000.0        # chips the house brings
ALPHA = 0.2                  # depth per unit of capital (the book's default)
# the clock's variance weights: after-hours, overnight gap, pre-market, regular session (the book's defaults)
W_AFTER_HOURS = 0.06
W_GAP = 0.14
W_PRE_MARKET = 0.10
W_REGULAR = 0.70
BASE_FEE = 0.02
CLOSE_FEE = 0.05
FEE_RAMP = 7200              # seconds before the close over which the fee rises
VEGA_FEE = 0.10
PROTOCOL_FEE = 0.10          # share of the fees set aside for the protocol
MAX_FILL = CAPITAL * 0.02    # per-fill cap, shares
LOSS_LIMIT = 0.30            # most of its capital the round may put at risk through buys (lossLimitBps 3000)
FLOOR_CAP = 1.00             # most of one floor outstanding, as a share of the capital (floorCapBps 10000: no cap)
TENTH_CAP = 0.10         # a tenth of the capital, which the popular floor must pass
MIN_PRICE = 0.02             # least a buy is charged per token before fees (minPriceWad)
G_FLOOR = 0.3
# the clock, in seconds since the previous close (16:00:00 New York the day before)
AFTER_HOURS_END = 4 * 3600                 # 20:00:00: the after-hours window is [0, AFTER_HOURS_END)
PRE_MARKET_START = 12 * 3600               # 04:00:00
REGULAR_START = 17 * 3600 + 1800           # 09:30:00
CLOSE = 24 * 3600                          # 16:00:00
CUTOFF = CLOSE - 630                       # last second a fill may be priced at (15:49:30)
FLOOR = 1e-4
PRICE_GRID = 1e-5            # oracle prices have five decimals (Pyth's exponent for US equities)

EDGES = [(m - 19) * SIGMA / 4 for m in range(39)]
# the menu: product i is the run of bands [lo, hi]. Eight floors that partition the ladder (below -2
# sigma, -2 to -1, -1 to -0.5, -0.5 to 0, 0 to 0.5, 0.5 to 1, 1 to 2, above 2), then LOWER and HIGHER.
MENU = [(0, 11), (12, 15), (16, 17), (18, 19), (20, 21), (22, 23), (24, 27), (28, 39), (0, 19), (20, 39)]
NP = len(MENU)
# a product narrower than half the ladder is a floor and has the product cap; the pair has none
CAPPED = [hi - lo + 1 < NB // 2 for lo, hi in MENU]
CAP_WEI = int(CAPITAL * FLOOR_CAP) * WAD
POPULAR = 4                  # the floor just above the previous close: bought to its cap during the day
# why the round refuses a fill (the values of RefundReason in IFallpitHook.sol)
REFUSED_NONE, REFUSED_SOLVENCY, REFUSED_WINDOW, REFUSED_LOSS_LIMIT, REFUSED_PRODUCT_CAP = 0, 3, 4, 6, 7


def phi(x):
    return 0.5 * (1.0 + math.erf(x / SQ2))


def pdf(x):
    return math.exp(-0.5 * x * x) / SQRT_2PI


# Vol-mix prior: the contract's sd multipliers (WAD, truncated) and weights over 6.
MIX_MULT = (693218411377872994, 980198673306755302, 1385983729489546675)
MIX_W = (1, 4, 1)


def mix_cdf(e, x, sd):
    """The normal CDF averaged over the vol-mix nodes; each node uses its own sd, drift included."""
    return sum(w * phi((e - x) / (sd * m / WAD) + (sd * m / WAD) / 2) for m, w in zip(MIX_MULT, MIX_W)) / 6


def fair_probs(x, sd):
    """ladder_house_sim.fair_probs with this round's edges and the vol-mix prior, floored and renormalised."""
    cdf = [0.0] + [mix_cdf(e, x, sd) for e in EDGES] + [1.0]
    p = np.maximum(np.diff(cdf), FLOOR)
    return p / p.sum()


def product_mask(i):
    lo, hi = MENU[i]
    mask = np.zeros(NB)
    mask[lo:hi + 1] = 1.0
    return mask, lo, hi


def edge_vega(m, x, sd):
    """Vega(e) = phi(z) * (z - sd), z = (e - x) / sd + sd / 2."""
    z = (EDGES[m] - x) / sd + sd / 2
    return pdf(z) * (z - sd)


def set_vega(lo, hi, x, sd):
    lower = edge_vega(lo - 1, x, sd) if lo > 0 else 0.0
    upper = edge_vega(hi, x, sd) if hi < NB - 1 else 0.0
    return abs(lower - upper)


def rho_at(offset):
    """Share of the round's variance still ahead `offset` seconds after the previous close (PitClock.at)."""
    if offset >= CLOSE:
        return 0.0
    if offset < AFTER_HOURS_END:
        return W_GAP + W_PRE_MARKET + W_REGULAR + W_AFTER_HOURS * (AFTER_HOURS_END - offset) / AFTER_HOURS_END
    if offset < PRE_MARKET_START:
        return W_PRE_MARKET + W_REGULAR + W_GAP * (PRE_MARKET_START - offset) / (PRE_MARKET_START - AFTER_HOURS_END)
    if offset < REGULAR_START:
        return W_REGULAR + W_PRE_MARKET * (REGULAR_START - offset) / (REGULAR_START - PRE_MARKET_START)
    return W_REGULAR * (CLOSE - offset) / (CLOSE - REGULAR_START)


def tradable(offset):
    """The windows a fill may be priced in: [16:00, 20:00) the day before and [04:00, 15:49:30]."""
    return 0 <= offset < AFTER_HOURS_END or PRE_MARKET_START <= offset <= CUTOFF


def fee_rate(offset):
    left = CLOSE - offset
    if left >= FEE_RAMP:
        return BASE_FEE
    return BASE_FEE + (CLOSE_FEE - BASE_FEE) * (FEE_RAMP - left) / FEE_RAMP


def max_payout(s):
    """The worst band: the payout if the close lands in band j is the supply of every product over j."""
    return max(sum(s[i] for i, (lo, hi) in enumerate(MENU) if lo <= j <= hi) for j in range(NB))


class Round:
    def __init__(self):
        pi0 = fair_probs(0.0, SIGMA)
        self.b0 = ALPHA * CAPITAL / np.log(1.0 / pi0)
        self.v = np.zeros(NB)
        self.g = 1.0
        self.supply = [0.0] * NP
        self.supply_wei = [0] * NP  # the same in integer wei, for the product cap (an exact comparison)
        self.held = CAPITAL
        self.protocol_fees = 0.0
        self.lowest_cushion = CAPITAL
        self.cushions = []  # the cushion after every filled trade

    def fill(self, offset, price, product, is_buy, shares_wei):
        """Prices one fill at the oracle print (offset seconds after the previous close, price). Returns
        (why the round refuses it or REFUSED_NONE, chips the trader pays or receives, fee inside them,
        whether the buy was charged the minimum price). A refused fill changes nothing."""
        shares = shares_wei / WAD
        mask, lo, hi = product_mask(product)
        # the product cap comes first, as in the hook: a floor never has more than its cap outstanding
        if is_buy and CAPPED[product] and self.supply_wei[product] + shares_wei > CAP_WEI:
            return REFUSED_PRODUCT_CAP, 0.0, 0.0, False
        if not tradable(offset):
            return REFUSED_WINDOW, 0.0, 0.0, False
        rho = rho_at(offset)
        sd = SIGMA * math.sqrt(rho)
        g_new = min(self.g, max(math.sqrt(rho), G_FLOOR))
        x = math.log(price / S0)
        pi = fair_probs(x, sd)

        # depth decay: rescale the state around lambda at the old depth; no price moves
        v = self.v
        if g_new < self.g:
            lam1 = sim.solve_lam(v, pi, self.b0 * self.g)
            v = lam1 + (v - lam1) * g_new / self.g
        b = self.b0 * g_new
        delta = shares if is_buy else -shares
        v1 = v + mask * delta
        c0 = sim.cost_fn(v, pi, b)
        c1 = sim.cost_fn(v1, pi, b)
        amount = c1 - c0 if is_buy else c0 - c1
        # a buy is charged at least the minimum price per token, before fees
        at_min_price = bool(is_buy and amount < shares * MIN_PRICE)
        if at_min_price:
            amount = shares * MIN_PRICE

        rate = fee_rate(offset)
        vega_per_share = VEGA_FEE * set_vega(lo, hi, x, sd)
        fee = amount * rate + shares * vega_per_share
        supply = list(self.supply)
        if is_buy:
            chips = amount + fee
            held = self.held + chips
            supply[product] += shares
        else:
            fee = min(fee, amount)
            chips = amount - fee
            if chips > self.held:
                return REFUSED_SOLVENCY, 0.0, 0.0, False
            held = self.held - chips
            supply[product] -= shares
        protocol_fees = self.protocol_fees + fee * PROTOCOL_FEE
        cushion = held - protocol_fees - max_payout(supply)
        if cushion < 0:
            return REFUSED_SOLVENCY, 0.0, 0.0, False
        # the loss limit: a buy must leave the house this much in the worst band; a sell is exempt
        if is_buy and cushion < CAPITAL * (1.0 - LOSS_LIMIT):
            return REFUSED_LOSS_LIMIT, 0.0, 0.0, False
        self.lowest_cushion = min(self.lowest_cushion, cushion)
        self.cushions.append(cushion)
        self.v, self.g, self.supply, self.held, self.protocol_fees = v1, g_new, supply, held, protocol_fees
        self.supply_wei[product] += shares_wei if is_buy else -shares_wei
        return REFUSED_NONE, chips, fee, at_min_price


def wad(x):
    return str(int(round(x * WAD)))


def main():
    rng = random.Random(20261006)
    rnd = Round()

    # when the trades happen: in the after-hours of the day before (the round was opened a minute after
    # the previous close), in the pre-market and in the regular session, at least 5 s apart
    windows = [
        ("afterHours", range(120, AFTER_HOURS_END - 5, 5), 17),
        ("preMarket", range(PRE_MARKET_START + 5, REGULAR_START - 5, 5), 17),
        ("regular", range(REGULAR_START + 5, CUTOFF - 5, 5), 58),
    ]
    offsets = []
    counts = {}
    for name, span, n in windows:
        offsets += rng.sample(span, n)
        counts[name] = n
    # the window edges themselves: the last second of the after-hours, the first of the pre-market, the
    # first of the regular session and the cutoff
    offsets += [AFTER_HOURS_END - 1, PRE_MARKET_START, REGULAR_START, CUTOFF]
    counts["afterHours"] += 1
    counts["preMarket"] += 1
    counts["regular"] += 2
    offsets = sorted(set(offsets))
    n_trades = len(offsets)
    assert n_trades == 96, "an edge collided with a drawn trade"

    # the oracle path: a random walk on the round's own clock (the variance between two prints is the
    # rho that ran off between them, the overnight gap included), one print where it is needed
    trades = []
    holdings = [0] * NP  # integer wei of each product's token held by the trader
    x = 0.0
    prev = 0
    vol_true = SIGMA * 1.15  # the day turns out a little more volatile than the house's estimate
    paid = 0.0
    received = 0.0
    for off in offsets:
        x += vol_true * math.sqrt(rho_at(prev) - rho_at(off)) * rng.gauss(0.0, 1.0)
        prev = off
        price = round(S0 * math.exp(x) / PRICE_GRID) * PRICE_GRID
        price_wad = int(round(price / PRICE_GRID)) * 10 ** 13
        price = price_wad / WAD

        held_products = [i for i in range(NP) if holdings[i] >= WAD]
        is_buy = not held_products or rng.random() < 0.62
        if is_buy and rng.random() < 0.2:
            # the popular floor, at the per-fill cap: lot after lot, past a tenth of the capital
            product = POPULAR
            shares_wei = int(MAX_FILL) * WAD
        elif is_buy:
            product = rng.randrange(NP)
            # sizes from one token to the per-fill cap, in steps of 0.001 token
            shares_wei = int(math.exp(rng.uniform(math.log(1.0), math.log(MAX_FILL))) * 1000) * 10 ** 15
        elif holdings[POPULAR] >= int(CAPITAL * TENTH_CAP) * WAD and rng.random() < 0.3:
            # the popular floor is past a tenth of the capital: a holder sells one lot of it
            product = POPULAR
            shares_wei = int(MAX_FILL) * WAD
        else:
            product = rng.choice(held_products)
            most = min(holdings[product], int(MAX_FILL) * WAD)
            frac = rng.choice([1.0, 1.0, 0.5, 0.25, rng.random()])
            shares_wei = max(WAD, int(most * frac) // 10 ** 15 * 10 ** 15)
        refused, chips, fee, at_min_price = rnd.fill(off, price, product, is_buy, shares_wei)
        # nothing is refused: no product cap, and one-sided flow cannot reach the loss limit at alpha 0.2
        assert refused == REFUSED_NONE, "an unexpected refusal: %d" % refused
        if refused == REFUSED_NONE:
            if is_buy:
                holdings[product] += shares_wei
                paid += chips
            else:
                holdings[product] -= shares_wei
                received += chips
        trades.append(dict(offset=off, price=price_wad, product=product, isBuy=is_buy, shares=shares_wei,
                           chips=chips, fee=fee, x=x, refused=refused, atMinPrice=at_min_price))

    # the close: the path runs on to 16:00:00
    x_close = x + vol_true * math.sqrt(rho_at(prev)) * rng.gauss(0.0, 1.0)
    close_wad = int(round(S0 * math.exp(x_close) / PRICE_GRID)) * 10 ** 13
    x_close = math.log(close_wad / WAD / S0)
    band = sum(1 for e in EDGES if x_close >= e)
    winners = 0
    payout_wei = 0
    for i, (lo, hi) in enumerate(MENU):
        if lo <= band <= hi:
            winners |= 1 << i
            payout_wei += holdings[i]
    payout = payout_wei / WAD
    back = rnd.held - payout - rnd.protocol_fees
    house_result = back - CAPITAL

    filled = [t for t in trades if t["refused"] == REFUSED_NONE]
    at_min = [t for t in filled if t["atMinPrice"]]
    by_product = [sum(1 for t in filled if t["product"] == i) for i in range(NP)]
    assert all(n > 0 for n in by_product), "every product must trade"
    assert len(filled) == len(trades), "nothing is refused on this day"
    assert rnd.supply_wei[POPULAR] > int(CAPITAL * TENTH_CAP) * WAD, "the popular floor passes a tenth of the capital"
    assert at_min, "the day must contain a buy charged the minimum price"
    assert rnd.lowest_cushion > CAPITAL * (1.0 - LOSS_LIMIT), "the loss limit never binds on this day"

    day = {
        "sigma": str(2 * 10 ** 16),
        "s0": str(180 * WAD),
        "capital": str(1_000_000 * WAD),
        "weights": [round(w * 10_000) for w in (W_AFTER_HOURS, W_GAP, W_PRE_MARKET, W_REGULAR)],
        "menuLo": [lo for lo, _ in MENU],
        "menuHi": [hi for _, hi in MENU],
        "floorCapBps": round(FLOOR_CAP * 10_000),
        "minPrice": wad(MIN_PRICE),
        "trades": len(trades),
        "afterHoursTrades": counts["afterHours"],
        "preMarketTrades": counts["preMarket"],
        "regularTrades": counts["regular"],
        "lossLimitBps": round(LOSS_LIMIT * 10_000),
        "alpha": wad(ALPHA),
        "refused": 0,
        "atTheMinPrice": len(at_min),
        "offset": [t["offset"] for t in trades],
        "rho": [wad(rho_at(t["offset"])) for t in trades],
        "price": [str(t["price"]) for t in trades],
        "product": [t["product"] for t in trades],
        "isBuy": [t["isBuy"] for t in trades],
        "shares": [str(t["shares"]) for t in trades],
        "minPriced": [t["atMinPrice"] for t in trades],
        "chips": [wad(t["chips"]) for t in trades],
        "fee": [wad(t["fee"]) for t in trades],
        "cushion": [wad(c) for c in rnd.cushions],
        "lowestCushion": wad(rnd.lowest_cushion),
        "closePrice": str(close_wad),
        "closeBand": band,
        "winners": winners,
        "payout": str(payout_wei),
        "supplyAtClose": [str(s) for s in rnd.supply_wei],
        "heldAtClose": wad(rnd.held),
        "protocolFees": wad(rnd.protocol_fees),
        "returned": wad(back),
        "houseResult": wad(house_result),
        "gAtClose": wad(rnd.g),
        "tradersPaid": wad(paid),
        "tradersReceived": wad(received),
    }
    (HERE / "day.json").write_text(json.dumps(day, separators=(",", ":")) + "\n")

    buys = sum(1 for t in filled if t["isBuy"])
    assert rho_at(prev) < G_FLOOR ** 2, "the last fill must be late enough for the depth scale to sit on its floor"
    print("trades: %d (%d buys and %d sells, all filled): %d after-hours, %d pre-market, %d regular; "
          "last fill %d s before the close" % (
              len(trades), buys, len(filled) - buys, counts["afterHours"], counts["preMarket"],
              counts["regular"], CLOSE - prev))
    print("fills per product (floors 0 to 7, LOWER, HIGHER): %s" % by_product)
    print("buys charged the minimum price: %d (products %s)" % (
        len(at_min), sorted(set(t["product"] for t in at_min))))
    print("the popular floor (product %d): %.0f outstanding at the close, %.1f%% of the capital (a tenth: %.0f%%)" % (
        POPULAR, rnd.supply[POPULAR], 100 * rnd.supply[POPULAR] / CAPITAL, 100 * TENTH_CAP))
    print("rho at the first fill %.6f, after the gap %.6f, at the last fill %.6f" % (
        rho_at(trades[0]["offset"]), rho_at(PRE_MARKET_START), rho_at(prev)))
    print("oracle path: min %.4f%%, max %.4f%%, close %.4f%% (band %d, winners %s)" % (
        100 * min(t["x"] for t in trades), 100 * max(t["x"] for t in trades), 100 * x_close, band,
        [i for i in range(NP) if winners >> i & 1]))
    print("traders paid %.6f, received %.6f from sells, winners are owed %.6f" % (paid, received, payout))
    print("protocol fees %.6f, depth scale at the close %.6f" % (rnd.protocol_fees, rnd.g))
    print("lowest worst-case cushion %.6f (%.2f%% of the capital; a buy needs %.0f%%)" % (
        rnd.lowest_cushion, 100 * rnd.lowest_cushion / CAPITAL, 100 * (1.0 - LOSS_LIMIT)))
    print("house result %+.6f chips on %.0f (%.4f%%)" % (house_result, CAPITAL, 100 * house_result / CAPITAL))


if __name__ == "__main__":
    main()
