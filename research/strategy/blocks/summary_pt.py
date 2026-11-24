#!/usr/bin/env python3
"""§1.1 headline: per zone × archetype the structure PICKED ON CALIBRATION DAYS (cal_pick), its evaluation Δ vs the
fair hourly benchmark first (thermal: hourly offers at average cost `hourly_ac`; storage/PV/FLEX: the unpriced hourly
schedule; hydro: hourly at water value + dual), then vs the second benchmark (thermal hourly-at-SRMC; storage the
dual-priced legs), the pen10 / SU×0.5 sensitivities of the structure picked on CAL in that cell, and the ex-post
evaluation-best structure. usage: python -I summary_pt.py SCORE.json"""
import json, sys
import pandas as pd
j = json.load(open(sys.argv[1]))
J2 = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else None   # optional: replication-day score (same CAL choices)
if J2 is not None:
    assert J2["cal_pick"] == j["cal_pick"] and J2["kmap"] == j["kmap"]
    M2 = pd.DataFrame(J2["main"])
cp = {tuple(k.split("|")[:2]) + tuple(float(x) for x in k.split("|")[2:]): v for k, v in j["cal_pick"].items()}
M, P, S = (pd.DataFrame(j[k]) for k in ("main", "pen10", "su05"))
CAND = {"CCGT": ["block", "linked", "exclusive", "mar_full", "block_hac"], "COAL": ["block", "linked", "exclusive", "mar_full", "block_hac"],
        "HYDRO": ["block", "linked", "exclusive", "mar"], "PSP": ["block", "exclusive"], "BESS": ["block", "exclusive"],
        "PVBAT": ["block", "exclusive"], "FLEX": ["block", "exclusive"]}
THERM = {"CCGT", "COAL"}; SCHED = {"PSP", "BESS", "PVBAT", "FLEX"}
def row(t, z, a, f):
    r = t[(t.zone == z) & (t.arch == a) & (t.format == f)]
    return None if r.empty else r.iloc[0]
def first(r, a):   # (Δ, lo, hi) vs the fair benchmark
    if a in THERM: return r.da, r.alo, r.ahi
    if a in SCHED: return r.ds, r.slo, r.shi
    return r.d, r.lo, r.hi
def second(r, a):
    if a in THERM or a in SCHED: return r.d, r.lo, r.hi
    return None
fmt = lambda v: "—" if v is None or pd.isna(v[0]) else f"{v[0]:+.0f} [{v[1]:+.0f},{v[2]:+.0f}]"
REPH = " REPLICATION Δ vs fair [90%] |" if J2 is not None else ""
print("| zone | unit | structure picked on CAL | Δ vs fair hourly benchmark [90%] |" + REPH + " Δ vs second benchmark | pen10 | SU×0.5 (CAL pick in that cell) | ex-post eval-best (Δ vs fair) |")
print("|---|---|---|---|" + ("---|" if J2 is not None else "") + "---|---|---|---|")
for a in ["CCGT", "COAL", "HYDRO", "PSP", "BESS", "PVBAT", "FLEX"]:
    for z in ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]:
        f = cp.get((z, a, 1.0, 1.0))
        if f is None: continue
        r = row(M, z, a, f); rp = row(P, z, a, f)
        f5 = cp.get((z, a, 0.5, 1.0)); r5 = row(S, z, a, f5) if f5 else None
        cands = M[(M.zone == z) & (M.arch == a) & M.format.isin(CAND[a])]
        eb = max(cands.itertuples(), key=lambda q: first(q, a)[0])
        s5 = "—" if r5 is None else f"{f5}: {fmt(first(r5, a))}"
        repc = f" {fmt(first(row(M2, z, a, f), a))} |" if J2 is not None else ""
        print(f"| {z} | {a} | **{f}** | {fmt(first(r, a))} |{repc} {fmt(second(r, a))} | {fmt(first(rp, a))} | {s5} | "
              f"{eb.format} {first(eb, a)[0]:+.0f}{' (= pick)' if eb.format == f else ''} |")
