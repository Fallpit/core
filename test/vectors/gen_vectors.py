#!/usr/bin/env python3
"""Test vectors for LadderMath and Gaussian (Python 3.9, numpy only, no scipy, no mpmath).

Run from anywhere:  python3 contracts/test/vectors/gen_vectors.py
Writes gaussian.json, exp.json, prior.json, sim.json, fill.json and margin.json next to this file.
The output is deterministic (fixed seeds).

Two engines live here.

1. The float64 reference ("sim" below): a line-for-line port of fair_probs, _g, solve_lam, prices and
   cost_fn from test/vectors/ladder_house_sim.py, with sigma as a parameter instead of the module
   constant 0.035 and the vol-mix prior (the normal CDF averaged over sd_i = sd * exp(0.2 x_i - 0.02),
   x = -sqrt3, 0, sqrt3, weights 1/6, 2/3, 1/6) in place of its single normal. When that file is
   present, the port's solver and cost are checked against it at sigma = 0.035 before anything is written.
   sim.json comes from this engine.

2. A high-precision engine on `decimal` (90 digits) with its own normal CDF (the series
   Phi(z) - 1/2 = phi(z) * sum z^(2n+1) / (2n+1)!!). It is checked against math.erf and against the float
   engine before anything is written. gaussian.json, exp.json, prior.json, fill.json and margin.json come
   from it. margin.json feeds the contract exact integer inputs (prior, depths, state) and records the true
   cost to the wei, which is how the tests prove that the house is never under-charged.

All numbers are written as decimal strings of WAD (1e18) integers so that Foundry parses them exactly.
"""
import importlib.util
import json
import math
import random
from decimal import Decimal as D, getcontext, ROUND_FLOOR, ROUND_CEILING, ROUND_HALF_EVEN
from pathlib import Path

import numpy as np

getcontext().prec = 90

HERE = Path(__file__).resolve().parent
SIM_PATH = HERE / "ladder_house_sim.py"

WAD = 10 ** 18
DW = D(WAD)
NB = 40
NE = 39
FLOOR = 1e-4
FLOOR_D = D("0.0001")
PI_D = D("3.14159265358979323846264338327950288419716939937510582097494459230781640628620899862803482534211706798")
SQRT_2PI = (2 * PI_D).sqrt()
SQ2 = math.sqrt(2)
# Vol-mix prior: the normal CDF averaged over sd_i = sd * exp(0.2 x_i - 0.02), x = -sqrt3, 0,
# sqrt3, weights 1/6, 2/3, 1/6. The node multipliers are the contract's WAD constants (truncated).
MIX_MULT = (693218411377872994, 980198673306755302, 1385983729489546675)
MIX_W = (1, 4, 1)  # over 6


# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------

def tdiv(a, b):
    """Integer division truncated toward zero, like Solidity."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def edges_wad(sigma_wad):
    """Inner edges exactly as the contract rounds them: (m - 19) * sigma / 4, truncated."""
    return [tdiv((m - 19) * sigma_wad, 4) for m in range(NE)]


def to_int(d, mode=ROUND_HALF_EVEN):
    return int(d.to_integral_value(rounding=mode))


def wad(d, mode=ROUND_HALF_EVEN):
    return to_int(D(d) * DW, mode)


def strs(xs):
    return [str(int(x)) for x in xs]


def log_uniform(rng, lo, hi):
    return math.exp(rng.uniform(math.log(lo), math.log(hi)))


# ---------------------------------------------------------------------------------------------------
# engine 1: float64 port of the simulation reference
# ---------------------------------------------------------------------------------------------------

def sim_phi(x):
    return 0.5 * (1 + math.erf(x / SQ2))


def sim_mix_cdf(e, r_now, tau_sd):
    """The vol-mix CDF at edge e: each node uses its own sd, drift included."""
    total = 0.0
    for mult, w in zip(MIX_MULT, MIX_W):
        sd = tau_sd * mult / WAD
        total += w * sim_phi((e - r_now) / sd + sd / 2)
    return total / 6


def sim_fair_probs(edges, r_now, tau_sd):
    cdf = [0.0] + [sim_mix_cdf(e, r_now, tau_sd) for e in edges] + [1.0]
    p = np.maximum(np.diff(cdf), FLOOR)
    return p / p.sum()


def sim_g(lam, q, lpi, b):
    u = lpi + (q - lam) / b
    m = u.max()
    e = np.exp(u - m)
    S = e.sum()
    return m + math.log(S), -(e / b).sum() / S


def sim_solve_lam(q, pi, b):
    lpi = np.log(pi)
    lo = float(np.min(q + b * lpi))
    hi = float(np.max(q))
    lam = hi
    for _ in range(300):
        g, gp = sim_g(lam, q, lpi, b)
        if abs(g) < 1e-14:
            break
        if g > 0:
            lo = lam
        else:
            hi = lam
        nxt = lam - g / gp
        lam = nxt if lo < nxt < hi else 0.5 * (lo + hi)
        if hi - lo < 1e-12 * max(1.0, abs(lam)):
            break
    return lam


def sim_prices(q, pi, b):
    lam = sim_solve_lam(q, pi, b)
    u = np.log(pi) + (q - lam) / b
    return np.exp(np.minimum(u, 0.0)), lam


def sim_cost_fn(q, pi, b):
    p, lam = sim_prices(q, pi, b)
    return lam + (b * (p - pi)).sum()


def check_port_against_sim():
    """The port's solver and cost must agree with the committed simulation at its own sigma. The prior is
    not compared: the simulation's is a plain normal, the port's is the vol mix. Both sides get one prior."""
    if not SIM_PATH.exists():
        print("note: %s not found, skipping the port check" % SIM_PATH)
        return
    spec = importlib.util.spec_from_file_location("ladder_house_sim", SIM_PATH)
    sim = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sim)
    assert sim.NB == NB and abs(sim.SIG - 0.035) < 1e-15
    edges = [(m - 19) * 0.035 / 4 for m in range(NE)]
    assert max(abs(a - b) for a, b in zip(edges, sim.EDGES)) < 1e-15
    rng = random.Random(11)
    for _ in range(200):
        r_now = rng.uniform(-0.2, 0.2)
        sd = rng.uniform(0.002, 0.05)
        pi_a = sim_fair_probs(sim.EDGES, r_now, sd)
        b = 0.3 * 20000.0 / np.log(1 / sim.fair_probs(0.0, 0.035))
        q = np.array([rng.uniform(0, 3000) if rng.random() < 0.3 else 0.0 for _ in range(NB)])
        pa, la = sim.prices(q, pi_a, b)
        pb, lb = sim_prices(q, pi_a, b)
        assert la == lb and np.max(np.abs(pa - pb)) == 0.0
        assert sim.cost_fn(q, pi_a, b) == sim_cost_fn(q, pi_a, b)
    print("port check against ladder_house_sim.py (solver and cost): ok")


# ---------------------------------------------------------------------------------------------------
# engine 2: high precision
# ---------------------------------------------------------------------------------------------------

def hp_pdf(z):
    return (-(z * z) / 2).exp() / SQRT_2PI


def hp_cdf(z):
    a = abs(z)
    if a >= 12:  # the tail is below 1.8e-33
        h = D("0.5")
    else:
        z2 = a * a
        term = a
        s = a
        k = 3
        while term > s * D("1e-85"):
            term = term * z2 / k
            s += term
            k += 2
        h = hp_pdf(a) * s
    return D("0.5") + h if z >= 0 else D("0.5") - h


def hp_z(edge_wad, x_wad, sd_wad):
    return D(edge_wad - x_wad) / D(sd_wad) + D(sd_wad) / (2 * DW)


def hp_mix_cdf(edge_wad, x_wad, sd_wad):
    """The vol-mix CDF at one edge, with each node's sd rounded to the wei as the contract rounds it."""
    total = D(0)
    for mult, w in zip(MIX_MULT, MIX_W):
        sd_i = max(sd_wad * mult // WAD, 1)
        total += w * hp_cdf(hp_z(edge_wad, x_wad, sd_i))
    return total / 6


def hp_prior(sigma_wad, x_wad, sd_wad):
    cdf = [D(0)] + [hp_mix_cdf(e, x_wad, sd_wad) for e in edges_wad(sigma_wad)] + [D(1)]
    raw = [max(cdf[j + 1] - cdf[j], FLOOR_D) for j in range(NB)]
    total = sum(raw)
    return [r / total for r in raw]


def hp_solve(v, lpi, b):
    """Root of ln sum exp(ln pi + (v - lam) / b). Newton from the left end, monotone and quadratic."""
    lam = max(vj + bj * lj for vj, bj, lj in zip(v, b, lpi))
    for _ in range(400):
        a = [lj + (vj - lam) / bj for vj, bj, lj in zip(v, b, lpi)]
        m = max(a)
        e = [(aj - m).exp() for aj in a]
        S = sum(e)
        g = m + S.ln()
        if abs(g) < D("1e-70"):
            return lam
        lam += g * S / sum(ej / bj for ej, bj in zip(e, b))
    raise RuntimeError("hp_solve did not converge")


def hp_state(v, pi, b):
    """(prices, cost) of a pricing state."""
    lpi = [p.ln() for p in pi]
    lam = hp_solve(v, lpi, b)
    p = [pj * ((vj - lam) / bj).exp() for vj, bj, pj in zip(v, b, pi)]
    assert abs(sum(p) - 1) < D("1e-60")
    return p, lam + sum(bj * (pj - qj) for bj, pj, qj in zip(b, p, pi))


def hp_vega(sigma_wad, x_wad, sd_wad, lo, hi):
    ed = edges_wad(sigma_wad)
    sd = D(sd_wad) / DW

    def at(m):
        z = hp_z(ed[m], x_wad, sd_wad)
        return hp_pdf(z) * (z - sd)

    lower = at(lo - 1) if lo > 0 else D(0)
    upper = at(hi) if hi < NB - 1 else D(0)
    return abs(lower - upper)


def hp_open_depths(sigma_wad, capital_wad, alpha_wad):
    pi0 = hp_prior(sigma_wad, 0, sigma_wad)
    return [D(alpha_wad) * D(capital_wad) / DW / (1 / p).ln() for p in pi0]


def check_hp_engine():
    """The high-precision CDF against math.erf, and the high-precision cost against the float engine."""
    rng = random.Random(5)
    for _ in range(2000):
        z = rng.uniform(-8.5, 8.5)
        assert abs(float(hp_cdf(D(z))) - sim_phi(z)) < 2e-16
    for _ in range(40):
        sigma = rng.randint(5, 150) * WAD // 1000
        x = int(rng.uniform(-3, 3) * sigma)
        sd = int(rng.uniform(0.2, 1.5) * sigma)
        ed = [e / WAD for e in edges_wad(sigma)]
        pf = sim_fair_probs(ed, x / WAD, sd / WAD)
        ph = hp_prior(sigma, x, sd)
        assert max(abs(float(a) - b) / b for a, b in zip(ph, pf)) < 1e-10
        b0 = hp_open_depths(sigma, 20000 * WAD, 3 * WAD // 10)
        v = [D(rng.uniform(0, 3000)) * DW if rng.random() < 0.3 else D(0) for _ in range(NB)]
        ch = hp_state(v, ph, b0)[1]
        cf = sim_cost_fn(np.array([float(a) for a in v]), pf, np.array([float(a) for a in b0]))
        assert abs(float(ch) - cf) <= 1e-9 * abs(cf) + 1e-10 * 20000 * WAD
    print("high-precision engine check: ok")


# ---------------------------------------------------------------------------------------------------
# vector files
# ---------------------------------------------------------------------------------------------------

def gen_gaussian():
    rng = random.Random(101)
    zs = [0, 1, -1, 10 ** 9, -10 ** 9, 9 * WAD - 1, -(9 * WAD - 1), 9 * WAD, -9 * WAD, 92 * WAD // 10 - 1,
          92 * WAD // 10, 20 * WAD, -20 * WAD, 255 * WAD, -255 * WAD, 10 ** 36, -10 ** 36]
    zs += [tdiv(k * WAD, 16) for k in range(-152, 153)]
    zs += [rng.randint(-9 * WAD, 9 * WAD) for _ in range(300)]
    zs += [rng.randint(-WAD // 100, WAD // 100) for _ in range(40)]
    out = {"z": strs(zs), "cdf": [], "cdfErf": [], "pdf": []}
    for z in zs:
        zd = D(z) / DW
        out["cdf"].append(str(wad(hp_cdf(zd))))
        out["pdf"].append(str(wad(hp_pdf(zd)) if abs(zd) < 40 else 0))
        zf = max(min(z / WAD, 40.0), -40.0)
        out["cdfErf"].append(str(int(round(sim_phi(zf) * WAD))))
    return out


def gen_exp():
    rng = random.Random(102)
    xs = [0, 1, -1, 40 * WAD, 60 * WAD, -41 * WAD, -41446531673892822312]
    xs += [rng.randint(-42 * WAD, 60 * WAD) for _ in range(300)]
    xs += [rng.randint(-WAD, 10 * WAD) for _ in range(200)]
    return {"x": strs(xs), "floor": [str(to_int((D(x) / DW).exp() * DW, ROUND_FLOOR)) for x in xs]}


def random_anchor(rng, sigma):
    """(x, sd) inside the fuzz domain of the spec: |x| <= 8 sigma, sd in [0.05, 1.5] sigma."""
    kind = rng.random()
    if kind < 0.6:
        x = int(rng.uniform(-2.5, 2.5) * sigma)
    else:
        x = int(rng.uniform(-8, 8) * sigma)
    sd = int(rng.uniform(0.05, 1.5) * sigma)
    return x, sd


def gen_prior():
    rng = random.Random(103)
    cases = [(35 * WAD // 1000, 0, 35 * WAD // 1000), (5 * WAD // 1000, 0, 5 * WAD // 1000),
             (15 * WAD // 100, 0, 15 * WAD // 100), (35 * WAD // 1000, 8 * 35 * WAD // 1000, 35 * WAD // 20000),
             (35 * WAD // 1000, -8 * 35 * WAD // 1000, 35 * WAD // 20000)]
    for _ in range(115):
        sigma = rng.randint(5 * WAD // 1000, 15 * WAD // 100)
        cases.append((sigma,) + random_anchor(rng, sigma))
    out = {"sigma": [], "x": [], "sd": [], "piSim": [], "pi": [], "b0": [], "capital": [], "alpha": []}
    for sigma, x, sd in cases:
        ed = [e / WAD for e in edges_wad(sigma)]
        out["sigma"].append(str(sigma))
        out["x"].append(str(x))
        out["sd"].append(str(sd))
        out["piSim"] += [str(int(round(p * WAD))) for p in sim_fair_probs(ed, x / WAD, sd / WAD)]
        out["pi"] += [str(wad(p)) for p in hp_prior(sigma, x, sd)]
        capital = int(log_uniform(rng, 1, 1e12) * WAD)
        alpha = rng.randint(WAD // 100, 79 * WAD // 100)
        out["capital"].append(str(capital))
        out["alpha"].append(str(alpha))
        out["b0"] += [str(to_int(b, ROUND_FLOOR)) for b in hp_open_depths(sigma, capital, alpha)]
    return out


SIM_STEPS = 6
SIM_EDGES = [15, 19, 23]


def gen_sim():
    """Buys of the six strike sets through the float reference, as Round.buy does (no depth decay)."""
    rng = random.Random(104)
    out = {"steps": SIM_STEPS, "sigma": [], "capital": [], "alpha": [], "x": [], "sd": [], "lo": [], "hi": [],
           "delta": [], "cost": [], "pBefore": [], "pAfter": [], "prices": []}
    for case in range(40):
        sigma = 35 * WAD // 1000 if case < 10 else rng.randint(5, 150) * WAD // 1000
        capital = 20000 * WAD if case < 10 else int(log_uniform(rng, 1, 1e12) * WAD)
        alpha = 3 * WAD // 10 if case < 10 else rng.randint(10, 79) * WAD // 100
        ed = [e / WAD for e in edges_wad(sigma)]
        pi0 = sim_fair_probs(ed, 0.0, sigma / WAD)
        b = (alpha / WAD) * (capital / WAD) / np.log(1 / pi0)
        q = np.zeros(NB)
        out["sigma"].append(str(sigma))
        out["capital"].append(str(capital))
        out["alpha"].append(str(alpha))
        for _ in range(SIM_STEPS):
            x = int(rng.uniform(-1.5, 1.5) * sigma)
            sd = int(rng.uniform(0.3, 1.2) * sigma)
            pi = sim_fair_probs(ed, x / WAD, sd / WAD)
            m = rng.choice(SIM_EDGES)
            lo, hi = (m + 1, NB - 1) if rng.random() < 0.5 else (0, m)
            delta = int(log_uniform(rng, 1e-3, 5e-2) * capital)
            mask = np.zeros(NB)
            mask[lo:hi + 1] = 1.0
            q1 = q + mask * (delta / WAD)
            p0, _ = sim_prices(q, pi, b)
            p1, _ = sim_prices(q1, pi, b)
            cost = sim_cost_fn(q1, pi, b) - sim_cost_fn(q, pi, b)
            q = q1
            out["x"].append(str(x))
            out["sd"].append(str(sd))
            out["lo"].append(str(lo))
            out["hi"].append(str(hi))
            out["delta"].append(str(delta))
            out["cost"].append(str(int(round(cost * WAD))))
            out["pBefore"].append(str(int(round(float((p0 * mask).sum()) * WAD))))
            out["pAfter"].append(str(int(round(float((p1 * mask).sum()) * WAD))))
        out["prices"] += [str(int(round(p * WAD))) for p in p1]
    return out


FILL_STEPS = 8


def gen_fill():
    """Full `fill` sequences (re-anchor, depth rescale, buys and sells of any set) in high precision."""
    rng = random.Random(105)
    out = {"steps": FILL_STEPS, "sigma": [], "capital": [], "alpha": [], "x": [], "sd": [], "gOld": [], "gNew": [],
           "lo": [], "hi": [], "delta": [], "amount": [], "pBefore": [], "pAfter": [], "vega": [], "prices": []}
    for case in range(48):
        sigma = rng.randint(5 * WAD // 1000, 15 * WAD // 100)
        capital = int(log_uniform(rng, 0.1, 1e12) * WAD)
        alpha = rng.randint(5 * WAD // 100, 79 * WAD // 100)
        b0 = hp_open_depths(sigma, capital, alpha)
        v = [D(0)] * NB
        g = WAD
        out["sigma"].append(str(sigma))
        out["capital"].append(str(capital))
        out["alpha"].append(str(alpha))
        for _ in range(FILL_STEPS):
            x, sd = random_anchor(rng, sigma)
            g_old = g
            if rng.random() < 0.6:
                g = max(3 * WAD // 10, int(g * rng.uniform(0.7, 1.0)))
            pi = hp_prior(sigma, x, sd)
            if g < g_old:
                lam1 = hp_solve(v, [p.ln() for p in pi], [b * g_old / DW for b in b0])
                v = [lam1 + (vj - lam1) * g / g_old for vj in v]
            b = [bj * g / DW for bj in b0]
            if rng.random() < 0.5:
                m = rng.choice(SIM_EDGES)
                lo, hi = (m + 1, NB - 1) if rng.random() < 0.5 else (0, m)
            else:
                lo = rng.randint(0, NB - 1)
                hi = rng.randint(lo, NB - 1)
            delta = int(log_uniform(rng, 1e-4, 0.5) * capital) * (1 if rng.random() < 0.65 else -1)
            p0, c0 = hp_state(v, pi, b)
            v = [vj + delta if lo <= j <= hi else vj for j, vj in enumerate(v)]
            p1, c1 = hp_state(v, pi, b)
            out["x"].append(str(x))
            out["sd"].append(str(sd))
            out["gOld"].append(str(g_old))
            out["gNew"].append(str(g))
            out["lo"].append(str(lo))
            out["hi"].append(str(hi))
            out["delta"].append(str(delta))
            out["amount"].append(str(to_int(abs(c1 - c0))))
            out["pBefore"].append(str(wad(sum(p0[lo:hi + 1]))))
            out["pAfter"].append(str(wad(sum(p1[lo:hi + 1]))))
            out["vega"].append(str(wad(hp_vega(sigma, x, sd, lo, hi), ROUND_FLOOR)))
        out["prices"] += [str(wad(p)) for p in p1]
    return out


def int_prior(sigma, x, sd):
    """A prior as the contract holds it: 40 integers that sum to exactly 1e18."""
    pi = [to_int(p * DW, ROUND_FLOOR) for p in hp_prior(sigma, x, sd)]
    pi[pi.index(max(pi))] += WAD - sum(pi)
    return pi


def gen_margin():
    """Exact integer inputs and the true cost to the wei, for the never-under-charged proof."""
    rng = random.Random(106)
    out = {"pi": [], "b0": [], "g": [], "v": [], "lo": [], "hi": [], "delta": [], "c0Floor": [], "c1Floor": [],
           "diffFloor": [], "diffCeil": []}
    for case in range(320):
        sigma = rng.randint(5 * WAD // 1000, 15 * WAD // 100)
        capital = int(log_uniform(rng, 0.1, 1e12) * WAD)
        alpha = rng.randint(5 * WAD // 100, 79 * WAD // 100)
        b0 = [to_int(b, ROUND_FLOOR) for b in hp_open_depths(sigma, capital, alpha)]
        g = rng.choice([WAD, 3 * WAD // 10, rng.randint(3 * WAD // 10, WAD)])
        pi = int_prior(sigma, *random_anchor(rng, sigma))
        v = [0] * NB
        for _ in range(rng.randint(0, 6)):
            a = rng.randint(0, NB - 1)
            c = rng.randint(a, NB - 1)
            size = int(log_uniform(rng, 1e-6, 1.0) * capital) * (1 if rng.random() < 0.7 else -1)
            v = [vj + size if a <= j <= c else vj for j, vj in enumerate(v)]
        if rng.random() < 0.3:  # an arbitrary common shift changes no price and no cost difference
            shift = rng.randint(-capital, capital)
            v = [vj + shift for vj in v]
        lo = rng.randint(0, NB - 1)
        hi = rng.randint(lo, NB - 1)
        if case % 8 == 0:
            lo, hi = 0, NB - 1
        kind = rng.random()
        if kind < 0.15:
            size = rng.randint(1, 1000)
        elif kind < 0.3:
            size = capital
        else:
            size = int(log_uniform(rng, 1e-12, 1.0) * capital) + 1
        delta = size if rng.random() < 0.6 else -size
        pid = [D(p) / DW for p in pi]
        bd = [D(bj * g) / DW for bj in b0]
        c0 = hp_state([D(vj) for vj in v], pid, bd)[1]
        c1 = hp_state([D(vj + delta) if lo <= j <= hi else D(vj) for j, vj in enumerate(v)], pid, bd)[1]
        diff = abs(c1 - c0)
        out["pi"] += strs(pi)
        out["b0"] += strs(b0)
        out["g"].append(str(g))
        out["v"] += strs(v)
        out["lo"].append(str(lo))
        out["hi"].append(str(hi))
        out["delta"].append(str(delta))
        out["c0Floor"].append(str(to_int(c0, ROUND_FLOOR)))
        out["c1Floor"].append(str(to_int(c1, ROUND_FLOOR)))
        out["diffFloor"].append(str(to_int(diff, ROUND_FLOOR)))
        out["diffCeil"].append(str(to_int(diff, ROUND_CEILING)))
    return out


def main():
    check_port_against_sim()
    check_hp_engine()
    for name, fn in [("gaussian", gen_gaussian), ("exp", gen_exp), ("prior", gen_prior), ("sim", gen_sim),
                     ("fill", gen_fill), ("margin", gen_margin)]:
        data = fn()
        (HERE / (name + ".json")).write_text(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n")
        print("wrote %s.json" % name)


if __name__ == "__main__":
    main()
