#!/usr/bin/env python3
"""§3 summary: per unit × size, zone columns; each cell = Δp in the zone vs the hourly benchmark (€/MWh, what the
STRUCTURE moves) / Δ profit at simulated prices vs the benchmark (€/MW-d) / share of days with a paradoxically
rejected family. usage: python -I imp_summary.py OUT.md SCORE.json [...]"""
import json, sys
import pandas as pd
t = pd.concat([pd.DataFrame(json.load(open(f))) for f in sys.argv[2:]], ignore_index=True)
ZONES = ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]
ROWS = [("CCGT", ["linked", "exclusive", "block", "mar_full", "block_hac"]), ("COAL", ["linked", "block", "mar_full", "block_hac"]),
        ("HYDRO", ["block", "mar"]), ("PSP", ["exclusive", "block", "hourly_oc"]), ("BESS", ["exclusive", "block", "hourly_oc"])]
out = []
for size in (5.0, 1.0):
    out.append(f"\n**{size:g}× the archetype** — cell: Δp zone vs benchmark €/MWh · Δ profit (sim) €/MW-d [90%] · PRB days\n")
    out.append("| unit | format | benchmark Δp zone | " + " | ".join(ZONES) + " |")
    out.append("|---|---|---|" + "---|" * len(ZONES))
    for arch, fmts in ROWS:
        g = t[(t.arch == arch) & (t["size"] == size)]
        if g.empty:
            continue
        bench = g.bench.iloc[0]
        bz = {z: g[(g.zone == z) & (g.format == bench)] for z in ZONES}
        bstr = ", ".join(f"{z} {r.dp.iloc[0]:+.1f}" for z, r in bz.items() if not r.empty)
        for f in fmts:
            cells = []
            for z in ZONES:
                r = g[(g.zone == z) & (g.format == f)]
                if r.empty:
                    cells.append("—"); continue
                r = r.iloc[0]
                prb = "" if pd.isna(r.prb) else f" · {r.prb:.0%}"
                cells.append(f"{r.dpf:+.1f} · {r.dprof:+.0f} [{r.lo:+.0f},{r.hi:+.0f}]{prb}")
            out.append(f"| {arch} | {f} | {bench}: {bstr} | " + " | ".join(cells) + " |")
open(sys.argv[1], "w").write("\n".join(out) + "\n")
print("\n".join(out))
