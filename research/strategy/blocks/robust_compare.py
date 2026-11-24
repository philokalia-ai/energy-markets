#!/usr/bin/env python3
"""Robust curves: round 1 (st-impact, 24-step baselines, runs/st-impact/strat/robust.csv, eval days) vs round 2
(robust96.py: 96-step baselines, hourly means; eval and rep days). Per asset × zone × pen: robust − unpriced and
robust − point (€/MW-day; battery/hydro archetypes are 1 MW in robust.py), day-block bootstrap 90% (10,000, seed 4646)."""
import numpy as np, pandas as pd
from pathlib import Path
ROOT = Path.home() / "armada/em-team/strategy"
EV = set((ROOT / "days_eval.txt").read_text().split())
r1 = pd.read_csv(ROOT / "runs/st-impact/strat/robust.csv"); r1 = r1[r1.day.isin(EV)].assign(set="R1 eval")
r2 = pd.read_csv(ROOT / "runs/st-blocks/r2/robust96.csv"); r2["set"] = r2["set"].map({"eval": "R2 eval", "rep": "R2 rep"})
d = pd.concat([r1, r2], ignore_index=True)
def boot(x):
    x = np.asarray(x, float); i = np.random.default_rng(4646).integers(0, len(x), (10000, len(x))); m = x[i].mean(1)
    return x.mean(), np.percentile(m, 5), np.percentile(m, 95)
f = lambda t: f"{t[0]:+.1f} [{t[1]:+.1f},{t[2]:+.1f}]"
print("| asset | zone | pen | " + " | ".join(f"{s}: robust − unpriced | {s}: robust − point" for s in ("R1 eval", "R2 eval", "R2 rep")) + " |")
print("|---|---|---|" + "---|" * 6)
for (a, z, pen), g in d.groupby(["asset", "zone", "pen"]):
    cells = []
    for s in ("R1 eval", "R2 eval", "R2 rep"):
        p = g[g.set == s].pivot(index="day", columns="arm", values="profit")
        cells += ["—", "—"] if p.empty else [f(boot(p.robust - p.unpriced)), f(boot(p.robust - p.point))]
    print(f"| {a} | {z} | {pen:.0f} | " + " | ".join(cells) + " |")
