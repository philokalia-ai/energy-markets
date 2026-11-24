#!/usr/bin/env python3
"""Absorption round 1 (st-impact, 24-step, runs/st-impact/strat/absorption.csv) vs round 2 (absorption96.py, 96-step
curves averaged to the hour), same days (evaluation fast tier) and zones. Per zone × size S × arm: profit €/MW-day
[90% day-block bootstrap], capture spread, zone spread with/without the battery; the size where the marginal MW earns
half the first 100 MW (st-impact's definition, absorption_summary.s_half)."""
import sys
import numpy as np, pandas as pd
from pathlib import Path
ROOT = Path.home() / "armada/em-team/strategy"
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "impact"))
DAYS = set((ROOT / "days_eval_fast.txt").read_text().split()); ZONES = ["GR", "IT-SOUTH", "NO2"]
r1 = pd.read_csv(ROOT / "runs/st-impact/strat/absorption.csv"); r2 = pd.read_csv(ROOT / "runs/st-blocks/r2/absorption96.csv")
SZ = [100, 250, 500, 1000, 2000, 4000]
def boot(x):
    x = np.asarray(x, float); i = np.random.default_rng(4646).integers(0, len(x), (10000, len(x))); m = x[i].mean(1)
    return x.mean(), np.percentile(m, 5), np.percentile(m, 95)
def s_half(p):
    v0 = p[100] / 100.0; mids, marg = [], []
    for a, b in zip(SZ[:-1], SZ[1:]):
        mids.append((a + b) / 2); marg.append((p[b] - p[a]) / (b - a))
    for i, m in enumerate(marg):
        if m <= 0.5 * v0:
            if i == 0: return mids[0]
            x0, x1, y0, y1 = mids[i - 1], mids[i], marg[i - 1], m
            return x0 + (x1 - x0) * (y0 - 0.5 * v0) / (y0 - y1)
    return np.inf
f = lambda t: f"{t[0]:.0f} [{t[1]:.0f},{t[2]:.0f}]"
print("| zone | arm | S MW | R1 €/MW-d | R2 €/MW-d | R1 capture spread | R2 capture spread | R1 zone spread base→with | R2 zone spread base→with |")
print("|---|---|---|---|---|---|---|---|---|")
half = []
for z in ZONES:
    for arm in ("competitive", "naive"):
        a = r1[(r1.zone == z) & (r1.arm == arm) & r1.day.isin(DAYS)]; b = r2[(r2.zone == z) & (r2.arm == arm) & r2.day.isin(DAYS)]
        days = sorted(set(a.day) & set(b.day))
        a, b = a[a.day.isin(days)], b[b.day.isin(days)]
        for S in SZ:
            x, y = a[a.S == S], b[b.S == S]
            print(f"| {z} | {arm} | {S} | {f(boot(x.per_mw_day))} | {f(boot(y.per_mw_day))} | {x.capture_spread.mean():.0f} | "
                  f"{y.capture_spread.mean():.0f} | {x.zone_spread_base.mean():.0f}→{x.zone_spread.mean():.0f} | "
                  f"{y.zone_spread_base.mean():.0f}→{y.zone_spread.mean():.0f} |")
        half.append((z, arm, len(days), s_half(a.groupby("S").profit.mean()), s_half(b.groupby("S").profit.mean())))
print("\n| zone | arm | days | R1 size where the marginal MW earns half (MW) | R2 |\n|---|---|---|---|---|")
for z, arm, n, h1, h2 in half:
    print(f"| {z} | {arm} | {n} | {h1:.0f} | {h2:.0f} |")
