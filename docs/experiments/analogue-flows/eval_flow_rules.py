#!/usr/bin/env python3
"""Flow-rule benchmark: which ex-ante rule best predicts realized hourly
border flows / zone net imports?

Motivation (2026-07 GR diagnosis): the :v2 calendar climatology (median of
same-weekday D-7..D-56) missed the July SEE regime flip — GR went from evening
exporter (May-June) to +0.5..1.5 GW evening importer (July heatwave), and the
8-week median needs >=5/8 weeks in the new regime to flip sign. Result: +60-80
EUR/MWh systematic evening bias in the D-1 price forecast for GR/BG/RO/RS
(93-100% of days), while load & RES inputs were near-perfect.

Rules evaluated, all strictly ex-ante at the D-1 forecast time (candidate
days <= D-2 so their realized load and flows are published):

  v2        median of same-weekday D-7..D-8w flows per (border, hour)
            [+ D-7 recency for Nordic-touching borders — the shipped rule]
  rec3      median of D-7 / D-14 / D-21 (recency, weekday-preserving)
  ana{K}    LOAD-ANALOGUE: the K candidate days (trailing 365, <= D-2) whose
            realized 24h load vector is closest (L2) to the delivery day's
            published D-1 LOAD FORECAST vector; flows = per-(border,hour)
            median over those K days. Load is the ex-ante thermometer: night
            load is a monotone function of night temperature (measured on GR:
            195 MW/degC below 25C, 354 above), it embeds weekday/holiday/
            tourism, and it exists for all 39 zones (weather DB covers GR
            only). A heatwave week finds last summer's analogue days instead
            of dragging this spring's calendar median.
  ana{K}b   50/50 blend of ana{K} and v2 (variance reduction on stable days)

Usage:
  python3 eval_flow_rules.py <border_flows.csv> <zone_load.csv> <out_dir>

Outputs <out_dir>/results_flow_rules.tsv (per zone x rule x period MAE of
hourly NET IMPORTS) and results_flow_rules_borders.tsv (per-border MAE).
Periods: 'all' (2024-07..2026-07 eval window), 'jul26' (2026-07-01..21, the
SEE flip), 'evening' (17-20 UTC), 'jul26_evening'.
"""
import sys
import numpy as np
import pandas as pd

FLOWS_CSV, LOAD_CSV, OUT = sys.argv[1], sys.argv[2], sys.argv[3]

NORDIC = {"NO1", "NO2", "NO3", "NO4", "NO5", "SE1", "SE2", "SE3", "SE4",
          "DK1", "DK2", "FI"}
FOOTPRINT = ["AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI",
             "FR", "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4",
             "NO5", "PL", "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI",
             "SK", "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH",
             "IT-Calabria", "IT-Sicily", "IT-Sardinia", "CH"]
EVAL_START, EVAL_END = "2024-07-01", "2026-07-22"
JUL26_START, JUL26_END = "2026-07-01", "2026-07-22"
EVE_HOURS = (17, 18, 19, 20)
K_LIST = (8, 16)

print("loading flows ...")
fl = pd.read_csv(FLOWS_CSV, header=None, names=["ts", "in_z", "out_z", "mw"])
fl["ts"] = pd.to_datetime(fl.ts, utc=True).dt.tz_convert(None)
fl["d"] = fl.ts.dt.normalize()
fl["h"] = fl.ts.dt.hour

print("loading load ...")
ld = pd.read_csv(LOAD_CSV, header=None, names=["kind", "z", "ts", "mw"])
ld["ts"] = pd.to_datetime(ld.ts, utc=True).dt.tz_convert(None)
ld["d"] = ld.ts.dt.normalize()
ld["h"] = ld.ts.dt.hour

# 24h load matrices per zone: rows=days, cols=hours
def day_matrix(df):
    p = df.pivot_table(index="d", columns="h", values="mw", aggfunc="mean")
    return p.reindex(columns=range(24))

act_load = {z: day_matrix(g) for z, g in ld[ld.kind == "act"].groupby("z")}
fc_load = {z: day_matrix(g) for z, g in ld[ld.kind == "fcst"].groupby("z")}

rows, brows = [], []
for zone in FOOTPRINT:
    zf = fl[(fl.in_z == zone) | (fl.out_z == zone)].copy()
    if zf.empty or zone not in act_load or zone not in fc_load:
        continue
    zf["cp"] = np.where(zf.in_z == zone, zf.out_z, zf.in_z)
    zf["signed"] = np.where(zf.in_z == zone, zf.mw, -zf.mw)
    # per (border=cp, day, hour) signed flow (import-positive)
    per = zf.pivot_table(index=["cp", "d"], columns="h", values="signed",
                         aggfunc="mean").reindex(columns=range(24))
    days_all = per.index.get_level_values("d").unique().sort_values()
    borders = per.index.get_level_values("cp").unique()
    # fast lookup: {cp: DataFrame(day x hour)}
    bmat = {cp: per.xs(cp, level="cp") for cp in borders}

    al, fcl = act_load[zone], fc_load[zone]
    al_v = al.to_numpy()
    al_days = al.index
    eval_days = [d for d in days_all
                 if EVAL_START <= str(d.date()) < EVAL_END and d in fcl.index]

    preds = {}   # rule -> {day -> DataFrame(cp x hour)}
    for d in eval_days:
        cands = {}
        # --- v2: same-weekday D-7..D-56 median (+ Nordic D-7)
        lags = [d - pd.Timedelta(days=7 * k) for k in range(1, 9)]
        v2 = {}
        for cp in borders:
            m = bmat[cp]
            have = [x for x in lags if x in m.index]
            if not have:
                continue
            if zone in NORDIC or cp in NORDIC:
                v2[cp] = m.loc[have[0]] if lags[0] in m.index else \
                    m.loc[have].median()
            else:
                v2[cp] = m.loc[have].median()
        cands["v2"] = v2
        # --- rec3: median of D-7/14/21
        lg3 = [x for x in lags[:3]]
        rec = {}
        for cp in borders:
            m = bmat[cp]
            have = [x for x in lg3 if x in m.index]
            if have:
                rec[cp] = m.loc[have].median()
        cands["rec3"] = rec
        # --- d2: the fastest admissible signal — flows of D-2 (realized and
        # published before the D-1 auction; different weekday, but a NEW
        # regime shows up within 2 days instead of >=7)
        d2day = d - pd.Timedelta(days=2)
        d2 = {}
        for cp in borders:
            m = bmat[cp]
            if d2day in m.index:
                d2[cp] = m.loc[d2day]
        cands["d2"] = d2
        # --- analogue: nearest-load days in trailing 365, <= D-2
        if d in fcl.index:
            fv = fcl.loc[d].to_numpy()
            if not np.isnan(fv).all():
                for pool, tag in ((365, ""), (1200, "w")):
                    lo, hi = d - pd.Timedelta(days=pool), d - pd.Timedelta(days=2)
                    mask = (al_days >= lo) & (al_days <= hi)
                    cd, cv = al_days[mask], al_v[mask]
                    ok = ~np.isnan(cv).any(axis=1)
                    cd, cv = cd[ok], cv[ok]
                    if len(cd) < max(K_LIST):
                        continue
                    fv0 = np.where(np.isnan(fv), np.nanmean(fv), fv)
                    dist = np.sqrt(((cv - fv0) ** 2).mean(axis=1))
                    order = np.argsort(dist)
                    for K in K_LIST:
                        sel = set(cd[order[:K]])
                        ana = {}
                        for cp in borders:
                            m = bmat[cp]
                            have = [x for x in sel if x in m.index]
                            if have:
                                ana[cp] = m.loc[have].median()
                        cands[f"ana{K}{tag}"] = ana
                        blend = {}
                        for cp in set(ana) & set(v2):
                            blend[cp] = 0.5 * ana[cp] + 0.5 * v2[cp]
                        cands[f"ana{K}b"] = blend
                # v3 = class-scoped: Nordic-touching borders keep v2's D-7;
                # all other borders 50/50 analogue(K=16) + calendar median
                for src in ("ana16", "ana16w"):
                    if src in cands and "d2" in cands:
                        ad2 = {}
                        for cp in set(cands[src]) | set(cands["d2"]):
                            vs = [cands[r][cp] for r in (src, "d2") if cp in cands[r]]
                            ad2[cp] = sum(vs) / len(vs)
                        cands["anad2" + ("w" if src.endswith("w") else "")] = ad2
                if "ana16w" in cands:
                    bl = {}
                    for key2, avg2 in v2.items():
                        bl[key2] = 0.5 * cands["ana16w"].get(key2, avg2) + 0.5 * avg2
                    cands["ana16wb"] = bl
                if "ana16" in cands:
                    v3 = {}
                    for cp in borders:
                        if zone in NORDIC or cp in NORDIC:
                            if cp in v2:
                                v3[cp] = v2[cp]
                        else:
                            a, c = cands["ana16"].get(cp), v2.get(cp)
                            if a is not None and c is not None:
                                v3[cp] = 0.5 * a + 0.5 * c
                            elif c is not None:
                                v3[cp] = c
                    cands["v3"] = v3
        for rule, pr in cands.items():
            preds.setdefault(rule, {})[d] = pr

    # --- score: hourly zone net imports (sum over borders present in truth)
    for rule, bydays in preds.items():
        recs = {"all": [], "evening": [], "jul26": [], "jul26_evening": []}
        bmae = {}
        for d, pr in bydays.items():
            in_jul = JUL26_START <= str(d.date()) < JUL26_END
            truth_cps = [cp for cp in borders if d in bmat[cp].index]
            if not truth_cps or not pr:
                continue
            tr = pd.DataFrame({cp: bmat[cp].loc[d] for cp in truth_cps}).T
            prd = pd.DataFrame({cp: pr[cp] for cp in pr if cp in truth_cps}).T
            # borders truth has but rule couldn't predict -> predict 0
            prd = prd.reindex(tr.index).fillna(0.0)
            err = (prd.sum(axis=0) - tr.sum(axis=0)).abs()   # per hour
            for h in range(24):
                if np.isnan(err.get(h, np.nan)):
                    continue
                recs["all"].append(err[h])
                if h in EVE_HOURS:
                    recs["evening"].append(err[h])
                if in_jul:
                    recs["jul26"].append(err[h])
                    if h in EVE_HOURS:
                        recs["jul26_evening"].append(err[h])
            for cp in tr.index:
                e = (prd.loc[cp] - tr.loc[cp]).abs().mean()
                bmae.setdefault(cp, []).append(e)
        for period, v in recs.items():
            if v:
                rows.append((zone, rule, period, len(v),
                             float(np.mean(v)), float(np.median(v))))
        for cp, v in bmae.items():
            brows.append((zone, cp, rule, len(v), float(np.mean(v))))
    print(f"{zone}: {len(eval_days)} eval days, {len(borders)} borders")

res = pd.DataFrame(rows, columns=["zone", "rule", "period", "n_hours",
                                  "mae_mw", "median_ae_mw"])
res.to_csv(f"{OUT}/results_flow_rules.tsv", sep="\t", index=False)
pd.DataFrame(brows, columns=["zone", "cp", "rule", "n_days", "mae_mw"]) \
    .to_csv(f"{OUT}/results_flow_rules_borders.tsv", sep="\t", index=False)

# headline pivot
for period in ("all", "evening", "jul26_evening"):
    p = res[res.period == period].pivot_table(
        index="zone", columns="rule", values="mae_mw")
    print(f"\n=== net-import MAE (MW), period={period} ===")
    print(p.round(0).to_string())
    print("mean:", p.mean().round(1).to_dict())
