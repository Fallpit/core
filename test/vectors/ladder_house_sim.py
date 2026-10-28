"""Reference model of the ladder: path-independent per-bucket depth (weighted-entropy cost function) + LP ranges.

Cost function (dual of R(p) = sum_j b_j (p_j ln(p_j/pi_j) - p_j + pi_j)):
    p_j(q) = pi_j * exp((q_j - lam) / b_j),  lam such that sum p_j = 1
    C(q)   = lam + sum_j b_j (p_j - pi_j)
dp_i/dq_j = -p_i p_j / (b_i b_j H) is symmetric, so the price field is conservative:
the cost of a position does not depend on the order it was built in, even with unequal b_j.

Depth sizing: b_j = alpha * L_j / ln(1/pi0_j): each bucket's own worst case ~ its own capital,
so depth concentrates where the opening odds are high (near the open) and LP capital that
chose the centre buys ~4x the depth of capital spread for the tails.

LPs choose a set of buckets. Premium of each trade is attributed to the buckets it bought
(split by mid-trade price, normalised to the exact cost). When bucket w wins, LPs covering w
pay q_w pro rata to stake; every other bucket keeps its premium. A trade is refused if any
bucket could owe more than its own capital: q_j - prem_j <= L_j.
"""
import math, random, sys
import numpy as np

SIG = 0.035                                   # TSLA-like daily sd
W = SIG / 4                                   # band width sigma/4
EDGES = [round(W * (i - 19), 6) for i in range(39)]   # +-~4.75 sigma, edge at the open
NB = len(EDGES) + 1                           # 40 bands
CENTERS = np.array([EDGES[0] - W / 2] + [(EDGES[i] + EDGES[i + 1]) / 2 for i in range(len(EDGES) - 1)] + [EDGES[-1] + W / 2])
VOL_NOISE = 0.3                               # day-to-day error of the house's vol estimate
FLOOR = 1e-4                                  # prior floor: tails never quoted below 0.01 cents
SQ2 = math.sqrt(2)


def phi(x):
    return 0.5 * (1 + math.erf(x / SQ2))


def fair_probs(r_now, tau_sd):
    if tau_sd < 1e-9:
        p = np.full(NB, FLOOR); p[sum(1 for e in EDGES if r_now >= e)] = 1.0
        return p / p.sum()
    m = r_now - 0.5 * tau_sd ** 2
    cdf = [0.0] + [phi((e - m) / tau_sd) for e in EDGES] + [1.0]
    p = np.maximum(np.diff(cdf), FLOOR)
    return p / p.sum()


def _g(lam, q, lpi, b):
    """g(lam) = ln sum exp(ln pi + (q - lam)/b), computed without overflow; root g = 0."""
    u = lpi + (q - lam) / b
    m = u.max()
    e = np.exp(u - m)
    S = e.sum()
    return m + math.log(S), -(e / b).sum() / S


def solve_lam(q, pi, b):
    lpi = np.log(pi)
    lo = float(np.min(q + b * lpi))            # g(lo) >= 0
    hi = float(np.max(q))                      # g(hi) <= 0
    lam = hi
    for _ in range(300):
        g, gp = _g(lam, q, lpi, b)
        if abs(g) < 1e-14:
            break
        if g > 0: lo = lam
        else: hi = lam
        nxt = lam - g / gp
        lam = nxt if lo < nxt < hi else 0.5 * (lo + hi)
        if hi - lo < 1e-12 * max(1.0, abs(lam)):
            break
    return lam


def prices(q, pi, b):
    lam = solve_lam(q, pi, b)
    u = np.log(pi) + (q - lam) / b
    return np.exp(np.minimum(u, 0.0)), lam


def cost_fn(q, pi, b):
    p, lam = prices(q, pi, b)
    return lam + (b * (p - pi)).sum()


class Round:
    def __init__(self, lps, pi0, fee, alpha=1.0, single_b=False):
        self.lps = lps
        self.L = np.zeros(NB)
        for _, c, mask in lps:
            self.L += c * mask
        if single_b:                     # one b, sized for the cheapest bucket
            D = self.L.max()
            self.b = np.full(NB, alpha * D / math.log(1 / pi0.min()))
        else:
            self.b = np.maximum(alpha * self.L / np.log(1 / pi0), 1e-6)
        self.q = np.zeros(NB)
        self.prem = np.zeros(NB)
        self.fee = fee
        self.volume = 0.0
        self.trades = 0
        self.rejected = 0

    def price_set(self, pi, mask):
        p, _ = prices(self.q, pi, self.b)
        return float((p * mask).sum())

    def buy(self, pi, mask, size, max_cost=None):
        """max_cost: the trader's slippage limit on total paid (cost + fee)."""
        self.trades += 1
        # no bucket can take more shares than its capital plus what it has already collected
        room = np.where(mask > 0, self.L + self.prem - self.q, np.inf)
        size = min(size, float(room.min()) * 1.5)
        if size <= 1e-6:
            self.rejected += 1
            return None
        for _ in range(14):
            q1 = self.q + mask * size
            cost = cost_fn(q1, pi, self.b) - cost_fn(self.q, pi, self.b)
            if max_cost is not None and cost * (1 + self.fee) > max_cost:
                size *= 0.5
                continue
            p0, _ = prices(self.q, pi, self.b)
            p1, _ = prices(q1, pi, self.b)
            w = (p0 + p1) * mask
            per = w / w.sum() * cost * (1 + self.fee)
            prem1 = self.prem + per
            if np.isfinite(cost) and cost > 0 and np.all(q1 - prem1 <= self.L + 1e-9):
                self.q, self.prem = q1, prem1
                self.volume += cost * (1 + self.fee)
                return cost
            size *= 0.5
        self.rejected += 1
        return None

    def settle(self, w):
        out = {}
        for name, c, mask in self.lps:
            share = c * mask / np.where(self.L > 0, self.L, 1)
            out[name] = float((share * self.prem).sum() - share[w] * self.q[w]) / c
            assert out[name] >= -1 - 1e-6, (name, out[name])     # nobody loses more than their stake
        return out


def mask_between(lo, hi):
    return ((CENTERS >= lo) & (CENTERS <= hi)).astype(float)


def setmask(i, up):
    return np.array([1.0 if (j > i) == up else 0.0 for j in range(NB)])


SETS = [(i, up, setmask(i, up)) for i in range(len(EDGES)) for up in (True, False)]


def sim_day(rng, oracle, lps, fee=0.02, sigma=0.035, steps=390, cutoff=380, n_noise=60,
            n_lotto=15, arb=True, dev=0.005, single_b=False, alpha=1.0, vol_noise=None, arb_k=0.5):
    if vol_noise is None:
        vol_noise = VOL_NOISE
    dt = 1.0 / steps
    path = [0.0]
    r = 0.0
    # the day's realised vol differs from the house's estimate; the arbitrageur knows it
    sig_true = sigma * math.exp(rng.gauss(0, vol_noise) - vol_noise ** 2 / 2)
    for _ in range(steps):
        r += -0.5 * sig_true ** 2 * dt + sig_true * math.sqrt(dt) * rng.gauss(0, 1)
        path.append(r)
    pi0 = fair_probs(0.0, sigma)
    rnd = Round(lps, pi0, fee, alpha=alpha, single_b=single_b)
    oracle_r = 0.0
    for t in range(cutoff):
        r_true = path[t]
        tau_sd = sigma * math.sqrt(1 - t * dt)
        if oracle == 'pull':
            oracle_r = r_true
        elif oracle == 'dev' and abs(r_true - oracle_r) >= dev:
            oracle_r = r_true
        if oracle == 'none':
            pi = pi0
        else:
            pi = fair_probs(oracle_r, tau_sd)
        if rng.random() < n_noise / cutoff:
            k = r_true + rng.gauss(0, 0.012)
            i = int(np.argmin([abs(e - k) for e in EDGES]))
            m = setmask(i, rng.random() < 0.5)
            sz = rng.lognormvariate(math.log(25), 0.8)
            pset = rnd.price_set(pi, m)
            rnd.buy(pi, m, sz, max_cost=sz * (pset + 0.03) * (1 + fee))
        if rng.random() < n_lotto / cutoff:
            far = [j for j in range(NB) if 0.02 < abs(CENTERS[j] - r_true) < 0.10]
            if far:
                j = rng.choice(far)
                m = np.zeros(NB); m[j] = 1
                p, _ = prices(rnd.q, pi, rnd.b)
                spend = rng.lognormvariate(math.log(5), 0.6)       # $5 lottery ticket
                rnd.buy(pi, m, spend / max(p[j], 1e-6), max_cost=spend)
        if arb and t % 5 == 0:
            # arbitrageur: may buy ANY contiguous run of bands [i, k), which also covers
            # "selling" an overpriced side (buying its complement)
            sig_arb = sigma ** (1 - arb_k) * sig_true ** arb_k     # half-informed about today's vol
            fair_t = fair_probs(r_true, sig_arb * math.sqrt(1 - t * dt))
            cf = np.concatenate([[0.0], np.cumsum(fair_t)])
            for _ in range(4):
                p, _ = prices(rnd.q, pi, rnd.b)
                cp = np.concatenate([[0.0], np.cumsum(p)])
                edge = (cf[None, :] - cf[:, None]) - (cp[None, :] - cp[:, None]) * (1 + fee)
                edge[np.tril_indices(NB + 1)] = -1
                i, k = np.unravel_index(np.argmax(edge), edge.shape)
                if edge[i, k] < 0.01:
                    break
                m = np.zeros(NB); m[i:k] = 1
                rnd.buy(pi, m, 50, max_cost=50 * (cf[k] - cf[i] - 0.005))
    w = sum(1 for e in EDGES if path[-1] >= e)
    return rnd, rnd.settle(w), path[-1]


def run(oracle, lps, days, seed=1, **kw):
    rng = random.Random(seed)
    res = {name: [] for name, _, _ in lps}
    closes, vol, rej, tr = [], 0.0, 0, 0
    for _ in range(days):
        rnd, out, close = sim_day(rng, oracle, lps, **kw)
        for k, v in out.items():
            res[k].append(v)
        closes.append(close); vol += rnd.volume; rej += rnd.rejected; tr += rnd.trades
    return res, np.array(closes), vol / days, rej / max(tr, 1)


def report(title, res, closes, vol, rej, out):
    absr = np.abs(closes)
    bands = [(0, 0.01), (0.01, 0.02), (0.02, 0.04), (0.04, 1)]
    lines = [f"\n== {title}   avg volume/day {vol:,.0f}   refused {rej:.1%}",
             "LP        mean/day   sd      p5      worst    " + "  ".join(f"|move| {lo*100:.0f}-{hi*100:.0f}%" for lo, hi in bands)]
    for k, v in res.items():
        v = np.array(v)
        cond = []
        for lo, hi in bands:
            sel = (absr >= lo) & (absr < hi)
            cond.append(f"{v[sel].mean()*100:+8.2f}%   " if sel.any() else "     n/a    ")
        lines.append(f"{k:<10}{v.mean()*100:+7.2f}%  {v.std()*100:6.2f}% {np.percentile(v,5)*100:+7.2f}% {v.min()*100:+8.2f}%   " + " ".join(cond))
    txt = "\n".join(lines)
    print(txt); out.write(txt + "\n"); out.flush()


def path_test(out):
    """Order test: buy 200 of bucket A then B, vs B then A."""
    pi = fair_probs(0.0, 0.035)
    A, B = 9, 13
    lines = ["\n== path independence (buy 200 on A then B vs B then A)"]
    for label, L in [("uniform depth", np.full(NB, 5000.0)),
                     ("B at 4x depth", np.where(np.arange(NB) == B, 20000.0, 5000.0)),
                     ("depth = L/ln(1/pi0)", np.full(NB, 5000.0))]:
        b = L / np.log(1 / pi) if "ln" in label else L / 5
        ea = np.zeros(NB); ea[A] = 200
        eb = np.zeros(NB); eb[B] = 200
        ab = (cost_fn(ea, pi, b) - cost_fn(np.zeros(NB), pi, b)) + (cost_fn(ea + eb, pi, b) - cost_fn(ea, pi, b))
        ba = (cost_fn(eb, pi, b) - cost_fn(np.zeros(NB), pi, b)) + (cost_fn(ea + eb, pi, b) - cost_fn(eb, pi, b))
        # naive p ~ pi e^{q/b} integrated along the path, the path-dependent formula
        def naive(order):
            q = np.zeros(NB); tot = 0.0
            for k in order:
                for _ in range(2000):
                    w = pi * np.exp(q / b); p = w / w.sum()
                    tot += p[k] * 0.1; q[k] += 0.1
            return tot
        lines.append(f"{label:<22} conservative A>B {ab:9.4f}  B>A {ba:9.4f}  diff {ab-ba:+.2e}   |  naive diff {naive([A,B])-naive([B,A]):+.4f}")
    txt = "\n".join(lines); print(txt); out.write(txt + "\n")


def depth_test(out):
    """price move of a 50-share HIGHER at the open strike, single-b vs per-bucket depth, same capital"""
    pi = fair_probs(0.0, 0.035)
    m = setmask(19, True)
    D = 20000.0
    lines = ["\n== depth: price move of a 50-share HIGHER@open, 20,000 capital"]
    for label, b in [("single b", np.full(NB, D / math.log(1 / pi.min()))),
                     ("per-bucket L/ln(1/pi0)", D / np.log(1 / pi)),
                     ("2k seed + 18k on +-2sd", (2000.0 + 18000.0 * mask_between(-0.07, 0.07)) / np.log(1 / pi)),
                     ("2k seed + 18k on +-1sd", (2000.0 + 18000.0 * mask_between(-0.035, 0.035)) / np.log(1 / pi))]:
        p0 = (prices(np.zeros(NB), pi, b)[0] * m).sum()
        p1 = (prices(m * 50, pi, b)[0] * m).sum()
        lines.append(f"{label:<26} {p0:.4f} -> {p1:.4f}  (+{(p1-p0)*100:.2f} cents)")
    txt = "\n".join(lines); print(txt); out.write(txt + "\n")


if __name__ == '__main__':
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    out = open(sys.argv[2] if len(sys.argv) > 2 else "results_v2.txt", "w")
    if len(sys.argv) > 3:
        VOL_NOISE = float(sys.argv[3])
    out.write(f"days={days} vol_noise={VOL_NOISE}\n")
    path_test(out)
    depth_test(out)
    full = np.ones(NB)
    core = mask_between(-0.035, 0.035)        # +-1 sd around the open (~68% of closes)
    wings = 1 - core
    house = [("house", 20000.0, full)]
    mix = [("full", 10000.0, full), ("core", 5000.0, core), ("wings", 5000.0, wings)]
    conc = [("seed", 2000.0, full), ("core2sd", 18000.0, mask_between(-0.07, 0.07))]
    SC = {
        "A": ("A. one b, prior fixed at open, no oracle", 'none', house, dict(single_b=True)),
        "B": ("B. one b, oracle-anchored prior (pull)", 'pull', house, dict(single_b=True)),
        "C": ("C. per-band depth, one full-range LP, oracle=pull", 'pull', house, {}),
        "D": ("D. per-band depth, range LPs, oracle=pull", 'pull', mix, {}),
        "E": ("E. per-band depth, range LPs, oracle=0.5% deviation push feed", 'dev', mix, {}),
        "F": ("F. per-band depth, range LPs, oracle=pull, no arbitrageur", 'pull', mix, dict(arb=False)),
        "G": ("G. per-band depth, 2k full seed + 18k on +-2sd, oracle=pull", 'pull', conc, {}),
    }
    for k in (sys.argv[4] if len(sys.argv) > 4 else "ABCDEFG"):
        t, o, l, kw = SC[k]
        report(t, *run(o, l, days, **kw), out)
