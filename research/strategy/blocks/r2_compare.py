#!/usr/bin/env python3
"""Round 2 vs round 1 headline cells (price-taker). Each round uses ITS OWN calibration-day choices (k_su, structure);
a changed pick is flagged. usage: python -I r2_compare.py R1.json R2.json [R2REP.json] [--labels a,b,c]
Round 1 = 24-step baselines (main 8b79087), hourly forecast repeated for 15-min bids; round 2 = 96-step baselines
(main 5fa39e1+: cv46 bundle incl. P1 Nordic water value), 15-min bids from the native 96-step forecast."""
import json, sys
import pandas as pd
J = [json.load(open(f)) for f in sys.argv[1:] if f.endswith(".json")]
names = ["R1 eval", "R2 eval", "R2 rep"][:len(J)]
cps = [{tuple(k.split("|")[:2]) + tuple(float(x) for x in k.split("|")[2:]): v for k, v in j["cal_pick"].items()} for j in J]
ci = lambda m, lo, hi: f"{m:+.0f} [{lo:+.0f},{hi:+.0f}]"
sig = lambda lo, hi: "+" if lo > 0 else ("−" if hi < 0 else "0")
def moved(vals):
    s = [sig(lo, hi) for (_, lo, hi) in vals]
    return "same" if len(set(s)) == 1 else "→".join(s)
print("#### (1) Thermal: CAL-picked structure vs hourly at average cost (base cell and start-up × 0.5), price-taker, €/MW-day [90%]\n")
print("| unit | cell | " + " | ".join(f"{n} (pick)" for n in names) + " | significance R1→R2… |\n|---|---|" + "---|" * len(names) + "---|")
G = [pd.DataFrame(j["thermal_grid"]) for j in J]
for (ar, z) in sorted({(r.arch, r.zone) for r in G[0].itertuples()}):
    for nl, su in ((1.0, 1.0), (1.0, 0.5)):
        cells, vals = [], []
        for g, cp in zip(G, cps):
            f = cp[(z, ar, su, nl)]
            r = g[(g.zone == z) & (g.arch == ar) & (g.nl == nl) & (g.su == su) & (g.format == f)].iloc[0]
            cells.append(f"{ci(r.dac, r.alo, r.ahi)} ({f})"); vals.append((r.dac, r.alo, r.ahi))
        print(f"| {z} {ar} | {'base' if su == 1 else 'SU×0.5'} | " + " | ".join(cells) + f" | {moved(vals)} |")
print("\n#### (2) Storage: exclusive group vs unpriced hourly schedule, price-taker, €/MW-day [90%]\n")
print("| zone | unit | " + " | ".join(names) + " | |\n|---|---|" + "---|" * len(names) + "---|")
M = [pd.DataFrame(j["main"]) for j in J]
for ar in ("PSP", "BESS"):
    for z in ("GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"):
        rs = [m[(m.zone == z) & (m.arch == ar) & (m.format == "exclusive")].iloc[0] for m in M]
        vals = [(r.ds, r.slo, r.shi) for r in rs]
        print(f"| {z} | {ar} | " + " | ".join(ci(*v) for v in vals) + f" | {moved(vals)} |")
print("\n#### (3) Storage exclusive groups: 15-min − 60-min products on realised quarters, price-taker, €/MW-day [90%]\n")
print("| zone | unit | " + " | ".join(names) + " | |\n|---|---|" + "---|" * len(names) + "---|")
Q = [pd.DataFrame(j["q15"]) for j in J]
for ar in ("PSP", "BESS"):
    for z in ("GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"):
        rs = [q[(q.zone == z) & (q.arch == ar) & (q.format == "exclusive")] for q in Q]
        if any(r.empty for r in rs): continue
        vals = [(r.iloc[0].d, r.iloc[0].lo, r.iloc[0].hi) for r in rs]
        print(f"| {z} | {ar} | " + " | ".join(ci(*v) for v in vals) + f" | {moved(vals)} |")
