#!/usr/bin/env python3
"""Weak-zone diagnosis (docs/experiments/weak-zone-diagnosis).

Offline analysis of the 730-day eu_scn_base baseline vs settled prices:
  1. per-zone corr / shape / level decomposition + intraday variability
  2. phantom-spike identification (model > 500 while actual ordinary)
  3. corr with spike days excluded
  4. spike-hour import audit: same-day net imports vs the :v2 climatology
  5. hour-of-day bias profiles on non-spike days

Reads data/results.duckdb (clearing_mode='eu_scn_base') and
data/extracts/euphemia-live.duckdb (entsoe.energy_prices, physical_flows).
Writes CSVs next to docs/experiments/weak-zone-diagnosis/evidence/.

Usage: python3 test/scripts/weak_zone_diagnosis.py
Deps:  pip install duckdb pandas pyarrow
"""
import os
from datetime import timedelta

import duckdb
import numpy as np
import pandas as pd

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
RESULTS = os.path.join(REPO, "data", "results.duckdb")
EXTRACT = os.path.join(REPO, "data", "extracts", "euphemia-live.duckdb")
OUTDIR = os.path.join(REPO, "docs", "experiments", "weak-zone-diagnosis", "evidence")
os.makedirs(OUTDIR, exist_ok=True)

TARGETS = ["BE", "CH", "AT", "DK1", "DK2", "SE3", "IT-CNORTH", "SI", "RO", "HU", "RS"]

# ---------------------------------------------------------------------------
# 1. Joined model-vs-actual hourly dataset
# ---------------------------------------------------------------------------
con = duckdb.connect(EXTRACT, read_only=True)
con.execute(f"ATTACH '{RESULTS}' AS res (READ_ONLY)")
df = con.sql("""
with r as (
  select map_code z, date_trunc('hour', date_time_utc) h, resolution_code rc,
         sequence sq, price_currency_mwh p
  from entsoe.energy_prices
  where contract_type='Day-ahead' and currency='EUR'
    and date_time_utc >= '2024-07-01' and date_time_utc < '2026-07-01'
),
best as (select z, h, max(rc) rc from r group by 1,2),
best2 as (select r.z, r.h, r.rc, min(r.sq) sq from r
          join best on r.z=best.z and r.h=best.h and r.rc=best.rc group by 1,2,3),
act as (select r.z, r.h, avg(r.p) actual from r
        join best2 on r.z=best2.z and r.h=best2.h and r.rc=best2.rc and r.sq=best2.sq
        group by 1,2),
model as (select bidding_zone z, date_time_utc h, avg(price_eur_mwh) model
          from res.simulations.energy_prices where clearing_mode='eu_scn_base'
          group by 1,2)
select m.z, m.h, m.model, a.actual from model m
join act a on m.z=a.z and m.h=a.h order by 1,2
""").df()
df["h"] = pd.to_datetime(df["h"])
df["date"] = df["h"].dt.date
print(f"joined dataset: {len(df)} rows, {df.z.nunique()} zones")

# ---------------------------------------------------------------------------
# 2. Per-zone decomposition + spike-excluded corr
# ---------------------------------------------------------------------------
rows = []
for z, g in df.groupby("z"):
    dm_m = g["model"] - g.groupby("date")["model"].transform("mean")
    dm_a = g["actual"] - g.groupby("date")["actual"].transform("mean")
    dd = g.groupby("date")[["model", "actual"]].mean()
    spike_days = set(g.loc[g.model > 500, "date"])
    g2 = g[~g.date.isin(spike_days)]
    rows.append(dict(
        zone=z, corr=g.model.corr(g.actual),
        shape_corr=dm_m.corr(dm_a), level_corr=dd.model.corr(dd.actual),
        mae=(g.model - g.actual).abs().mean(), bias=(g.model - g.actual).mean(),
        sd_shape_model=dm_m.std(), sd_shape_actual=dm_a.std(),
        n_spike_days=len(spike_days),
        corr_no_spike_days=g2.model.corr(g2.actual)))
stats = pd.DataFrame(rows).round(3).sort_values("corr")
stats.to_csv(os.path.join(OUTDIR, "zone_stats.csv"), index=False)
print(stats.to_string(index=False))

# ---------------------------------------------------------------------------
# 3. Spike-hour import audit: same-day flows vs :v2-style climatology
# ---------------------------------------------------------------------------
def border_hourly(zone, day):
    """(hour, counterparty, direction)->avg flow with _IPS dedup (keep max)."""
    q = """
    SELECT EXTRACT(HOUR FROM date_time_utc)::int h,
           in_area_map_code inc, out_area_map_code outc, AVG(flow_mw) f
    FROM entsoe.physical_flows
    WHERE in_area_type_code LIKE 'BZN%' AND out_area_type_code LIKE 'BZN%'
      AND date_time_utc >= ?::timestamp AND date_time_utc < ?::timestamp + interval 1 day
      AND (in_area_map_code = ? OR out_area_map_code = ?)
    GROUP BY 1,2,3"""
    best = {}
    for h, inc, outc, f in con.execute(q, [day, day, zone, zone]).fetchall():
        if f is None:
            continue
        cp, dr = (outc, 1) if inc == zone else (inc, -1)
        cp = cp[:-4] if cp.endswith("_IPS") else cp
        k = (h, cp, dr)
        if k not in best or f > best[k]:
            best[k] = f
    return best


def clim(zone, day, weeks=8):
    acc = {}
    for k in range(1, weeks + 1):
        for key, v in border_hourly(zone, day - timedelta(days=7 * k)).items():
            acc.setdefault(key, []).append(v)
    return {k: float(np.median(v)) for k, v in acc.items()}


def net(bh, hour):
    vals = [dr * v for (h, _, dr), v in bh.items() if h == hour]
    return sum(vals) if vals else np.nan


sp = df[df.model > 500]
recs = []
for z in TARGETS:
    for day, grp in sp[sp.z == z].groupby("date"):
        bh0, bhc = border_hourly(z, day), clim(z, day)
        for _, r in grp.iterrows():
            hh = r["h"].hour
            recs.append(dict(z=z, day=str(day), hod=hh, model=r.model,
                             actual=r.actual, imp_d0=net(bh0, hh),
                             imp_clim=net(bhc, hh)))
audit = pd.DataFrame(recs)
audit.to_csv(os.path.join(OUTDIR, "spike_hour_import_audit.csv"), index=False)
audit["gap"] = audit.imp_d0 - audit.imp_clim
print("\nspike-hour import audit (mean over spike hours):")
print(audit.groupby("z")[["imp_d0", "imp_clim", "gap"]].mean().round(0).to_string())

# ---------------------------------------------------------------------------
# 4. Hour-of-day bias profiles on non-spike days
# ---------------------------------------------------------------------------
prof_rows = []
for z in TARGETS:
    g = df[df.z == z]
    g = g[~g.date.isin(set(g.loc[g.model > 500, "date"]))]
    p = g.groupby(g["h"].dt.hour)[["model", "actual"]].mean()
    for hod, r in p.iterrows():
        prof_rows.append(dict(zone=z, hod=hod, model=r.model, actual=r.actual,
                              bias=r.model - r.actual))
pd.DataFrame(prof_rows).round(1).to_csv(
    os.path.join(OUTDIR, "hod_bias_no_spike_days.csv"), index=False)
print(f"\nwrote {OUTDIR}/{{zone_stats,spike_hour_import_audit,hod_bias_no_spike_days}}.csv")
