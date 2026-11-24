#!/usr/bin/env python3
"""Round 2 absorption: evaluation fast tier vs replication (every other replication day), GR / IT-SOUTH / NO2.
Per zone × arm × S: €/MW-day [90% day-block bootstrap] and the half-value size (st-impact's definition).
usage: python -I absorption_rep.py EVAL.csv REP.csv"""
import sys
import numpy as np, pandas as pd
SZ = [100, 250, 500, 1000, 2000, 4000]
def boot(x):
    x = np.asarray(x, float); i = np.random.default_rng(4646).integers(0, len(x), (10000, len(x))); m = x[i].mean(1)
    return x.mean(), np.percentile(m, 5), np.percentile(m, 95)
def s_half(p):   # st-impact's absorption_summary.s_half (as in absorption_compare.py)
    v0 = p[100] / 100.0; mids, marg = [], []
    for a, b in zip(SZ[:-1], SZ[1:]):
        mids.append((a + b) / 2); marg.append((p[b] - p[a]) / (b - a))
    for i, m in enumerate(marg):
        if m <= 0.5 * v0:
            if i == 0: return mids[0]
            x0, x1, y0, y1 = mids[i - 1], mids[i], marg[i - 1], m
            return x0 + (x1 - x0) * (y0 - 0.5 * v0) / (y0 - y1)
    return np.inf
e, r = pd.read_csv(sys.argv[1]), pd.read_csv(sys.argv[2])
f = lambda t: f"{t[0]:.0f} [{t[1]:.0f},{t[2]:.0f}]"
print(f"days: eval {e.day.nunique()}, rep {r.day.nunique()}\n")
print("| zone | arm | " + " | ".join(f"S={S}: eval / rep €/MW-d" for S in (100, 1000, 4000)) + " | half-value size eval / rep (MW) |")
print("|---|---|" + "---|" * 4)
for z in ("GR", "IT-SOUTH", "NO2"):
    for arm in ("competitive", "naive"):
        a, b = e[(e.zone == z) & (e.arm == arm)], r[(r.zone == z) & (r.arm == arm)]
        cells = [f"{f(boot(a[a.S == S].per_mw_day))} / {f(boot(b[b.S == S].per_mw_day))}" for S in (100, 1000, 4000)]
        print(f"| {z} | {arm} | " + " | ".join(cells) +
              f" | {s_half(a.groupby('S').profit.mean()):.0f} / {s_half(b.groupby('S').profit.mean()):.0f} |")
