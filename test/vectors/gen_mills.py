#!/usr/bin/env python3
"""The Mills ratio table of src/lib/Gaussian.sol (its normal CDF), and its check in exact integer arithmetic.

Run:  python3 contracts/test/vectors/gen_mills.py contracts/test/vectors/gaussian.json > mills_body.txt
Needs mpmath. Prints the body of Gaussian._mills (Solidity) on stdout and the error check on stderr.

M(a) = sqrt(pi/2) * erfc(a / sqrt 2) * exp(a^2 / 2), so 1 - Phi(a) = phi(a) * M(a). On each of 18 intervals
[0.5 k, 0.5 (k + 1)] M is a degree-14 Chebyshev fit in t in [-1, 1], power basis, coefficients rounded to
1e36. The check emulates the contract (truncating signed division, expWad floored) against the 90-digit
vectors and 20,000 random points.
"""
import json
import random
import sys

import mpmath as mp

mp.mp.dps = 60
W = mp.mpf("0.5")
N = 18
DEG = 14
S = 10**36
WAD = 10**18
E40 = 590023365285237066961937924728842176883135759177089817  # e^40 sqrt(2 pi) 1e36, as in Gaussian.sol


def mills(a):
    return mp.sqrt(mp.pi / 2) * mp.erfc(a / mp.sqrt(2)) * mp.exp(a * a / 2)


tables = []
worst_fit = 0
for k in range(N):
    lo, hi = W * k, W * (k + 1)
    poly, err = mp.chebyfit(lambda t, lo=lo, hi=hi: mills(lo + (hi - lo) * (t + 1) / 2), [-1, 1], DEG + 1, error=True)
    worst_fit = max(worst_fit, err)
    tables.append([int(mp.nint(c * S)) for c in poly])


def tdiv(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def cdf(z):
    a = abs(z)
    if a >= 9 * WAD:
        return 0 if z < 0 else WAD
    if a == 0:
        return WAD // 2
    k = a // (WAD // 2)
    t = (a - (k * WAD // 2 + WAD // 4)) * 4 * WAD
    c = tables[k]
    acc = c[0]
    for ci in c[1:]:
        acc = tdiv(acc * t, S) + ci
    e = int(mp.floor(mp.exp(mp.mpf(40 * WAD - a * a // (2 * WAD)) / WAD) * WAD))
    h = min(e * acc // E40, WAD // 2)
    return h if z < 0 else WAD - h


vec = json.load(open(sys.argv[1]))
worst = max(abs(cdf(int(z)) - int(c)) for z, c in zip(vec["z"], vec["cdf"]))
random.seed(1)
worst_rand = 0
for _ in range(20000):
    z = random.randint(-9 * WAD, 9 * WAD)
    worst_rand = max(worst_rand, abs(cdf(z) - int(mp.nint(mp.ncdf(mp.mpf(z) / WAD) * WAD))))
print(f"fit error {mp.nstr(worst_fit, 3)}; worst vs vectors {worst} wei; worst on 20000 random {worst_rand} wei", file=sys.stderr)


def horner(c, ind):
    out = [f"{ind}acc = {c[0]};"]
    for ci in c[1:]:
        out.append(f"{ind}acc = acc * t / S {'-' if ci < 0 else '+'} {abs(ci)};")
    return "\n".join(out)


def tree(lo, hi, ind):
    if lo == hi:
        return horner(tables[lo], ind)
    mid = (lo + hi) // 2
    return f"{ind}if (k <= {mid}) {{\n{tree(lo, mid, ind + '    ')}\n{ind}}} else {{\n{tree(mid + 1, hi, ind + '    ')}\n{ind}}}"


print(tree(0, N - 1, " " * 12))
