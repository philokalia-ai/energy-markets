#!/usr/bin/env python3
"""Thermal 2×3 sensitivity table: in each (no-load × start-up) cell, the structure PICKED ON CALIBRATION DAYS for
that cell, its evaluation Δ vs hourly_ac (the format value) and vs hourly-at-SRMC. usage: python -I grid_pt.py SCORE.json"""
import json, sys
import pandas as pd
j = json.load(open(sys.argv[1]))
g = pd.DataFrame(j["thermal_grid"])
cp = {tuple(k.split("|")[:2]) + tuple(float(x) for x in k.split("|")[2:]): v for k, v in j["cal_pick"].items()}
cells = [(1.0, 0.5), (1.0, 1.0), (1.0, 1.5), (0.0, 0.5), (0.0, 1.0), (0.0, 1.5)]
AB = {"block": "B", "linked": "L", "exclusive": "X", "mar_full": "M", "block_hac": "BH"}
hdr = " | ".join(f"NL×{nl:g} SU×{su:g}{' (stress)' if su == 1.5 else ''}" for nl, su in cells)
print("Cell: CAL-picked structure (B block, L linked, X exclusive, M mar_full, BH block_hac): Δ vs hourly_ac [90%] / Δ vs hourly-at-SRMC; bold = interval excludes 0.\n")
print(f"| unit | {hdr} |\n|---|" + "---|" * len(cells))
for (ar, z), h in g.groupby(["arch", "zone"]):
    row = []
    for nl, su in cells:
        f = cp[(z, ar, su, nl)]
        r = h[(h.nl == nl) & (h.su == su) & (h.format == f)].iloc[0]
        s = "**" if r.alo > 0 or r.ahi < 0 else ""
        row.append(f"{AB[f]}: {s}{r.dac:+.0f}{s} [{r.alo:+.0f},{r.ahi:+.0f}] / {r.dmc:+.0f}")
    print(f"| {z} {ar} | " + " | ".join(row) + " |")
print("\nhourly-at-SRMC mean profit €/MW-d per cell (negative = loses money on average):")
print(f"| unit | {hdr} |\n|---|" + "---|" * len(cells))
for (ar, z), h in g.groupby(["arch", "zone"]):
    print(f"| {z} {ar} | " + " | ".join(f"{h[(h.nl == nl) & (h.su == su)].iloc[0].pmc:+.0f}" for nl, su in cells) + " |")
