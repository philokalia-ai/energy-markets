#!/usr/bin/env python3
"""MAR with impact at 5×: round 1 (24-step, per-period capped re-entry of a partial MAR block; imp/thermal.csv) vs
round 2 (96-step, single acceptance ratio + marginal-block move; r2/mar96/mar96.csv), same days (the rows present in
round 2). Per zone × unit: share of days with a paradoxically rejected family (PRB) for block vs mar_full, accepted
share, partial-acceptance share, Δp vs hourly-at-SRMC (€/MWh), Δ profit mar_full − block at simulated prices
(€/MW-day, day-block bootstrap 90%); then the per-day MAR counters of round 2 (mar_moved, mar_partial, cap hit)."""
import numpy as np, pandas as pd
from pathlib import Path
ROOT = Path.home() / "armada/em-team/strategy/runs/st-blocks"
r1 = pd.read_csv(ROOT / "imp/thermal.csv"); r1 = r1[r1["size"] == 5]
r2 = pd.read_csv(ROOT / "r2/mar96/mar96.csv"); r2 = r2[r2["size"] == 5]
DAYS = sorted(set(r2.day)); r1 = r1[r1.day.isin(DAYS)]
def boot(x):
    x = np.asarray(x, float); i = np.random.default_rng(4646).integers(0, len(x), (10000, len(x))); m = x[i].mean(1)
    return x.mean(), np.percentile(m, 5), np.percentile(m, 95)
f = lambda t: f"{t[0]:+.0f} [{t[1]:+.0f},{t[2]:+.0f}]"
part = lambda s: pd.to_numeric(s, errors="coerce").between(1e-9, 0.999)
print(f"Days: {len(DAYS)} ({DAYS[0]} … {DAYS[-1]}); 5× the archetype (CCGT 2 GW, coal 2.5 GW).\n")
print("| zone | unit | round | PRB days block | PRB days mar_full | accepted block / mar_full | partial mar_full days | Δp vs hourly_mc block / mar_full €/MWh | Δ profit mar_full − block €/MW-d [90%] |")
print("|---|---|---|---|---|---|---|---|---|")
for (z, a), _ in r2.groupby(["zone", "arch"]):
    for name, d in (("R1 (per-period re-entry)", r1), ("R2 (single ratio)", r2)):
        g = d[(d.zone == z) & (d.arch == a)]
        v = {fm: g[g.format == fm].set_index("day") for fm in ("hourly_mc", "block", "mar_full")}
        days = sorted(set.intersection(*[set(x.index) for x in v.values()]))
        if not days: continue
        b, m, h = (v[k].loc[days] for k in ("block", "mar_full", "hourly_mc"))
        cap = float(b.cap_mw.iloc[0])
        print(f"| {z} | {a} | {name} | {(b.prb > 0).mean():.0%} | {(m.prb > 0).mean():.0%} | {(b.n_fam_acc > 0).mean():.0%} / "
              f"{(m.n_fam_acc > 0).mean():.0%} | {part(m.mar_ratio).mean():.0%} | {(b.dp_mean - h.dp_mean).mean():+.1f} / "
              f"{(m.dp_mean - h.dp_mean).mean():+.1f} | {f(boot((m.profit_sim - b.profit_sim) / cap))} |")
print("\n**Round 2 MAR counters per day** (mar_full rows, 5×; summed over units): partial blocks that the marginal-block rule"
      " moved to all-or-nothing, MAR blocks still partial in the final clear, rows where the 3-round cap was hit.\n")
m2 = r2[r2.format == "mar_full"]
c = m2.groupby("day").agg(rows=("zone", "size"), mar_moved=("mar_moved", "sum"), mar_partial=("mar_partial", "sum"),
                          cap_hit=("mar_cap_hit", lambda s: int((s.astype(str).str.lower() == "true").sum())))
print("| day | units | mar_moved | mar_partial (final) | cap hit |\n|---|---|---|---|---|")
for d, r in c.iterrows():
    print(f"| {d} | {r.rows} | {r.mar_moved} | {r.mar_partial} | {r.cap_hit} |")
print(f"| **total** | {c.rows.sum()} | {c.mar_moved.sum()} | {c.mar_partial.sum()} | {c.cap_hit.sum()} |")
