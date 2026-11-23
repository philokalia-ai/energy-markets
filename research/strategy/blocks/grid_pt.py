#!/usr/bin/env python3
"""Thermal 2×3 sensitivity table for the report: the fixed structure (CCGT exclusive, COAL linked) vs hourly_ac
(the format value) and vs hourly_mc, per (no-load × start-up) cell. usage: python -I grid_pt.py SCORE.json"""
import json, sys
import pandas as pd
g = pd.DataFrame(json.load(open(sys.argv[1]))["thermal_grid"])
g = g[((g.arch == "CCGT") & (g.format == "exclusive")) | ((g.arch == "COAL") & (g.format == "linked"))]
cells = [(1.0, 0.5), (1.0, 1.0), (1.0, 1.5), (0.0, 0.5), (0.0, 1.0), (0.0, 1.5)]
hdr = " | ".join(f"NL×{nl:g} SU×{su:g}{' (stress)' if su == 1.5 else ''}" for nl, su in cells)
print(f"| unit (structure) | {hdr} |\n|---|" + "---|" * len(cells))
sig = lambda lo, hi: "**" if lo > 0 or hi < 0 else ""
for (ar, z), h in g.groupby(["arch", "zone"]):
    row = []
    for nl, su in cells:
        r = h[(h.nl == nl) & (h.su == su)].iloc[0]
        s = sig(r.alo, r.ahi)
        row.append(f"{s}{r.dac:+.0f}{s} [{r.alo:+.0f},{r.ahi:+.0f}] / {r.dmc:+.0f}")
    print(f"| {z} {ar} ({h.format.iloc[0]}) | " + " | ".join(row) + " |")
print("\nhourly-at-SRMC mean profit €/MW-d per cell (negative = loses money on average):")
print(f"| unit | {hdr} |\n|---|" + "---|" * len(cells))
for (ar, z), h in g.groupby(["arch", "zone"]):
    print(f"| {z} {ar} | " + " | ".join(f"{h[(h.nl == nl) & (h.su == su)].iloc[0].pmc:+.0f}" for nl, su in cells) + " |")
