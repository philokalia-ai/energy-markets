#!/usr/bin/env python3
"""§3 tables from score_imp.py --json: per archetype class and size, zone × format with Δp in the zone vs the
benchmark format (what the STRUCTURE moves), Δ profit at simulated prices vs the benchmark [90%], acceptance and
paradoxical-rejection days, the own-price-impact cost (profit at simulated − at our unmoved forecast).
usage: python -I imp_tables.py SCORE.json [SCORE2.json ...]"""
import json, sys
import pandas as pd
t = pd.concat([pd.DataFrame(json.load(open(f))) for f in sys.argv[1:]], ignore_index=True)
f1 = lambda v, n=2: "—" if pd.isna(v) else f"{v:.{n}f}"
for title, archs in (("Thermal (vs hourly at SRMC; thermal replaces the same MW of baseline supply)", ["CCGT", "COAL"]),
                     ("Storage (vs the unpriced hourly schedule; added on top of the book)", ["PSP", "BESS"]),
                     ("Reservoir hydro (vs hourly at water value + dual; replaces baseline supply)", ["HYDRO"])):
    for size in (5.0, 1.0):
        g = t[t.arch.isin(archs) & (t["size"] == size)]
        if g.empty:
            continue
        print(f"\n#### {title} — {size:g}×")
        print("| zone | unit | format | days | Δp zone €/MWh | Δp vs bench | max abs Δp | neighbours (mean abs Δp > 1) | profit sim €/MW-d | own-impact cost | Δ profit vs bench [90%] | accepted | PRB days | MAR ratio |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in g.sort_values(["arch", "zone", "format"]).itertuples():
            print(f"| {r.zone} | {r.arch} | {r.format} | {r.days} | {r.dp:+.2f} | {r.dpf:+.2f} | {r.dpmax:.1f} | {r.neigh} | "
                  f"{r.psim:.1f} | {r.psim - r.pfc:+.1f} | {r.dprof:+.1f} [{r.lo:+.1f},{r.hi:+.1f}] | {f1(r.acc)} | {f1(r.prb)} | {f1(r.mar)} |")
