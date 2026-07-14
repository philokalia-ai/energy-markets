#!/usr/bin/env python3
"""Evaluate weak-zone prototype variants against the stored baseline + actuals.

Usage: python3 test/scripts/weak_zone_eval.py v1 v2
Expects docs/experiments/weak-zone-diagnosis/evidence/prices_<variant>.csv produced
by test/scripts/weak_zone_prototypes.jl, and the same DBs as
weak_zone_diagnosis.py. Prints corr/MAE/bias per target + guard zone on the
28-day benchmark (all days and the 16 spike days), plus cap-hour counts, and
writes variant_metrics.csv.
"""
import os
import sys

import duckdb
import numpy as np
import pandas as pd

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
RESULTS = os.path.join(REPO, "data", "results.duckdb")
EXTRACT = os.path.join(REPO, "data", "extracts", "euphemia-live.duckdb")
DATADIR = os.path.join(REPO, "docs", "experiments", "weak-zone-diagnosis", "evidence")

SPIKE_DAYS = ["2024-08-22", "2024-10-14", "2024-12-11", "2025-01-01", "2025-01-14",
              "2025-02-11", "2025-04-08", "2025-07-03", "2025-08-27", "2025-10-05",
              "2025-11-18", "2025-12-01", "2026-01-13", "2026-01-28", "2026-02-18",
              "2026-06-20"]
NORMAL_DAYS = ["2024-07-10", "2024-09-14", "2024-10-22", "2024-11-24", "2025-02-25",
               "2025-03-26", "2025-05-14", "2025-06-21", "2025-09-16", "2025-12-14",
               "2026-03-10", "2026-05-20"]
BENCH = SPIKE_DAYS + NORMAL_DAYS
TARGETS = ["AT", "BE", "CH", "DK1", "DK2", "SE3", "IT-CNORTH", "SI", "RO", "HU", "RS"]
GUARDS = ["GR", "DE_LU", "ES", "PT"]

variants = sys.argv[1:] or ["v1", "v2"]

con = duckdb.connect(EXTRACT, read_only=True)
con.execute(f"ATTACH '{RESULTS}' AS res (READ_ONLY)")
day_list = ",".join(f"'{d}'" for d in BENCH)
m = con.sql(f"""
with r as (
  select map_code z, date_trunc('hour', date_time_utc) h, resolution_code rc,
         sequence sq, price_currency_mwh p
  from entsoe.energy_prices
  where contract_type='Day-ahead' and currency='EUR'
    and date_time_utc::date in ({day_list})
),
best as (select z, h, max(rc) rc from r group by 1,2),
best2 as (select r.z, r.h, r.rc, min(r.sq) sq from r
          join best on r.z=best.z and r.h=best.h and r.rc=best.rc group by 1,2,3),
act as (select r.z, r.h, avg(r.p) actual from r
        join best2 on r.z=best2.z and r.h=best2.h and r.rc=best2.rc and r.sq=best2.sq
        group by 1,2),
model as (select bidding_zone z, date_time_utc h, avg(price_eur_mwh) p_base
          from res.simulations.energy_prices where clearing_mode='eu_scn_base'
          and date_time_utc::date in ({day_list}) group by 1,2)
select m.z, m.h, m.p_base, a.actual from model m
join act a on m.z=a.z and m.h=a.h
""").df()
m["h"] = pd.to_datetime(m["h"])
m["date"] = m["h"].dt.strftime("%Y-%m-%d")

for v in variants:
    f = pd.read_csv(os.path.join(DATADIR, f"prices_{v}.csv"))
    f["h"] = pd.to_datetime(f.ts, format="%Y%m%d-%H%M")
    f = f.rename(columns={"zone": "z", "price": f"p_{v}"})[["z", "h", f"p_{v}"]]
    m = m.merge(f, on=["z", "h"], how="left")

cols = ["p_base"] + [f"p_{v}" for v in variants]


def met(g, col):
    ok = g[col].notna()
    if ok.sum() == 0:
        return (np.nan,) * 3
    return (g.loc[ok, col].corr(g.loc[ok, "actual"]),
            (g.loc[ok, col] - g.loc[ok, "actual"]).abs().mean(),
            (g.loc[ok, col] - g.loc[ok, "actual"]).mean())


rows = []
for z in TARGETS + GUARDS:
    for label, sel in [("all28", m[m.z == z]),
                       ("spike16", m[(m.z == z) & m.date.isin(SPIKE_DAYS)])]:
        r = {"zone": z, "set": label}
        for c in cols:
            r[f"{c[2:]}_corr"], r[f"{c[2:]}_mae"], r[f"{c[2:]}_bias"] = met(sel, c)
        rows.append(r)
out = pd.DataFrame(rows).round(2)
pd.set_option("display.width", 250)
for s in ["all28", "spike16"]:
    print(f"\n===== {s} =====")
    print(out[out.set == s].drop(columns="set").to_string(index=False))

print("\n===== hours with price > 500 on the 28 benchmark days =====")
for c in cols:
    cnt = m[m[c] > 500].groupby("z").size().to_dict()
    print(f"{c[2:]:6s} total={sum(cnt.values())}  {cnt}")

out.to_csv(os.path.join(DATADIR, "variant_metrics.csv"), index=False)
print(f"\nwrote {DATADIR}/variant_metrics.csv")
