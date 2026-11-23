#!/usr/bin/env python3
"""§1.1 summary: per zone × archetype the best cost-reflective format by mean Δ vs the benchmark (the flagged
min-ratio-priced `mar` excluded; storage/PV/FLEX vs the unpriced hourly schedule), with its bootstrap interval and
the two sensitivities. usage: python -I summary_pt.py SCORE.json"""
import json, sys
import pandas as pd
j = json.load(open(sys.argv[1]))
key = ["zone", "arch", "format"]
m = pd.DataFrame(j["main"])
for k, n in (("pen10", "P_"), ("su05", "S_")):
    t = pd.DataFrame(j[k])[key + ["d", "lo", "hi", "ds", "slo", "shi"]]
    m = m.merge(t.rename(columns={c: n + c for c in ["d", "lo", "hi", "ds", "slo", "shi"]}), on=key, how="left")
ZONES = ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]
SCHED = {"PSP", "BESS", "PVBAT", "FLEX"}
print("| archetype | " + " | ".join(ZONES) + " |\n|---|" + "---|" * len(ZONES))
for ar in ["CCGT", "COAL", "HYDRO", "PSP", "BESS", "PVBAT", "FLEX"]:
    cells = []
    for z in ZONES:
        g = m[(m.arch == ar) & (m.zone == z) & (m.format != "mar") & ~m.format.isin(["hourly_mc", "hourly_oc", "hourly_sched"])]
        if g.empty:
            cells.append("—"); continue
        col, lo, hi, pc, sc = ("ds", "slo", "shi", "P_ds", "S_ds") if ar in SCHED else ("d", "lo", "hi", "P_d", "S_d")
        b = g.loc[g[col].idxmax()]
        txt = f"**{b.format}** {b[col]:+.0f} [{b[lo]:+.0f},{b[hi]:+.0f}]; pen10 {b[pc]:+.0f}"
        if ar in ("CCGT", "COAL"):
            txt += f"; SU×0.5 {b[sc]:+.0f}"
        if b[col] < 0:
            txt += " (benchmark best)"
        cells.append(txt)
    bench = "vs unpriced hourly schedule" if ar in SCHED else ("vs hourly-MC" if ar in ("CCGT", "COAL") else "vs hourly WV+dual")
    print(f"| {ar} ({bench}) | " + " | ".join(cells) + " |")
