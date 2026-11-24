#!/usr/bin/env python3
"""Replication: the frozen headline numbers (EVAL days) next to the same numbers on the fresh replication days (REP),
with the structures / k_su chosen on CAL days only (identical in both JSONs). usage: python -I rep_compare.py EVAL.json REP.json"""
import json, sys
import pandas as pd
E, R = (json.load(open(f)) for f in sys.argv[1:3])
assert E["kmap"] == R["kmap"] and E["cal_pick"] == R["cal_pick"], "calibration choices differ"
cp = {tuple(k.split("|")[:2]) + tuple(float(x) for x in k.split("|")[2:]): v for k, v in E["cal_pick"].items()}
ci = lambda m, lo, hi: f"{m:+.0f} [{lo:+.0f},{hi:+.0f}]"
def verdict(e, r):
    if r["lo"] > 0 and e["lo"] > 0: return "replicates (both > 0)"
    if r["hi"] < 0 and e["hi"] < 0: return "replicates (both < 0)"
    if e["lo"] > 0 and r["m"] > 0: return "same sign, REP interval includes 0"
    if e["lo"] > 0 and r["m"] <= 0: return "**DOES NOT REPLICATE**"
    if e["hi"] < 0 and r["m"] >= 0: return "**DOES NOT REPLICATE**"
    return "n.s. in EVAL" + (" and REP" if r["lo"] <= 0 <= r["hi"] else "; REP " + ("> 0" if r["lo"] > 0 else "< 0"))
# (1) thermal grid: CAL-picked structure vs hourly_ac per cell
GE, GR_ = pd.DataFrame(E["thermal_grid"]), pd.DataFrame(R["thermal_grid"])
cells = [(1.0, 1.0), (1.0, 0.5), (1.0, 1.5), (0.0, 0.5), (0.0, 1.0), (0.0, 1.5)]
print("#### (1) Thermal: CAL-picked structure vs hourly offers at average cost (`hourly_ac`), price-taker, €/MW-day [90%]\n")
print("| unit | cell (no-load, start-up) | structure (CAL) | EVAL 23 d | REP 22 d | verdict |\n|---|---|---|---|---|---|")
rows1 = []
for (ar, z) in sorted({(r.arch, r.zone) for r in GE.itertuples()}):
    for nl, su in cells:
        f = cp[(z, ar, su, nl)]
        g = lambda G: G[(G.zone == z) & (G.arch == ar) & (G.nl == nl) & (G.su == su) & (G.format == f)].iloc[0]
        e, r = g(GE), g(GR_)
        ed, rd = dict(m=e.dac, lo=e.alo, hi=e.ahi), dict(m=r.dac, lo=r.alo, hi=r.ahi)
        v = verdict(ed, rd); rows1.append((z, ar, nl, su, v))
        tag = " (base)" if (nl, su) == (1.0, 1.0) else (" (stress)" if su == 1.5 else "")
        print(f"| {z} {ar} | NL×{nl:g} SU×{su:g}{tag} | {f} | {ci(e.dac, e.alo, e.ahi)} | {ci(r.dac, r.alo, r.ahi)} | {v} |")
# (2) storage exclusive vs unpriced schedule
ME, MR = pd.DataFrame(E["main"]), pd.DataFrame(R["main"])
print("\n#### (2) Storage: exclusive group vs the unpriced hourly schedule (and vs dual-priced legs), price-taker, €/MW-day [90%]\n")
print("| zone | unit | EVAL vs schedule | REP vs schedule | verdict | EVAL vs dual-priced legs | REP vs dual-priced legs |\n|---|---|---|---|---|---|---|")
for ar in ["PSP", "BESS"]:
    for z in ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]:
        g = lambda M: M[(M.zone == z) & (M.arch == ar) & (M.format == "exclusive")].iloc[0]
        e, r = g(ME), g(MR)
        v = verdict(dict(m=e.ds, lo=e.slo, hi=e.shi), dict(m=r.ds, lo=r.slo, hi=r.shi))
        print(f"| {z} | {ar} | {ci(e.ds, e.slo, e.shi)} | {ci(r.ds, r.slo, r.shi)} | {v} | {ci(e.d, e.lo, e.hi)} | {ci(r.d, r.lo, r.hi)} |")
# (3) 15-min vs 60-min for storage exclusive
QE, QR = pd.DataFrame(E["q15"]), pd.DataFrame(R["q15"])
print("\n#### (3) Storage exclusive groups: 15-min − 60-min products on realised PT15M quarters, price-taker, €/MW-day [90%]\n")
print("| zone | unit | EVAL | REP | verdict |\n|---|---|---|---|---|")
for ar in ["PSP", "BESS"]:
    for z in ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]:
        g = lambda Q: Q[(Q.zone == z) & (Q.arch == ar) & (Q.format == "exclusive")]
        e, r = g(QE), g(QR)
        if e.empty or r.empty: continue
        e, r = e.iloc[0], r.iloc[0]
        v = verdict(dict(m=e.d, lo=e.lo, hi=e.hi), dict(m=r.d, lo=r.lo, hi=r.hi))
        print(f"| {z} | {ar} | {ci(e.d, e.lo, e.hi)} | {ci(r.d, r.lo, r.hi)} | {v} |")
