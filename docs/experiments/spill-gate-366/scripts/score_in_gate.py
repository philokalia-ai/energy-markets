# Where the gate acts: zone-days whose ex-ante fill ratio >= 0.95 (the reader's
# own rule: latest week before D vs prior-years' same-week max), base vs spill.
import os, psycopg2, pandas as pd, numpy as np
cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"])
Z = ["NO1","NO2","NO3","NO4","NO5","SE1","SE2","SE3","SE4","FI","DK1","DK2"]
r = pd.read_sql("""select area_map_code z, year, week, avg(stored_energy_mwh) e from entsoe.aggregated_hydro_storage_filling_rate
   where area_type_code like 'BZN%%' and area_map_code = any(%s) and stored_energy_mwh is not null group by 1,2,3""", cx, params=(Z,))
sim = pd.read_sql("""select clearing_mode arm, bidding_zone z, date_time_utc t, price_eur_mwh p from simulations.energy_prices
   where clearing_mode in ('ab366_base','ab366_spill') and code_version=37 and bidding_zone = any(%s)""", cx, params=(Z,))
sim["t"] = pd.to_datetime(sim.t)
act = pd.read_sql("""select map_code z, date_trunc('hour', date_time_utc at time zone 'UTC') t, avg(price_currency_mwh) a from entsoe.energy_prices
   where contract_type='Day-ahead' and map_code = any(%s) and date_time_utc >= '2024-09-01' and date_time_utc < '2026-09-01' group by 1,2""", cx, params=(Z,))
act["t"] = pd.to_datetime(act.t)
w = sim.pivot_table(index=["z","t"], columns="arm", values="p").dropna().reset_index().merge(act, on=["z","t"])
w["d"] = w.t.dt.date
def ratio(z, d):
    d = pd.Timestamp(d); iso = d.isocalendar(); y, wk = int(iso[0]), int(iso[1])
    g = r[r.z == z]
    cur = g[(g.year < y) | ((g.year == y) & (g.week < wk))].sort_values(["year","week"]).tail(1)
    wks = [((wk + k - 1) % 52) + 1 for k in range(-2, 3)]
    prior = g[(g.year < y) & g.week.isin(wks)]
    if cur.empty or len(prior) < 5: return np.nan
    return float(cur.e.iloc[0]) / prior.e.max()
zd = w[["z","d"]].drop_duplicates(); zd["ratio"] = [ratio(z, d) for z, d in zip(zd.z, zd.d)]
w = w.merge(zd, on=["z","d"])
w["gate"] = w.ratio >= 0.95
def blk(g):
    eb, es = g.ab366_base - g.a, g.ab366_spill - g.a
    low = g.a <= 5
    return pd.Series({"cells": len(g), "base_MAE": eb.abs().mean(), "spill_MAE": es.abs().mean(), "dMAE": es.abs().mean() - eb.abs().mean(),
        "base_bias": eb.mean(), "spill_bias": es.mean(), "base_corr": g.ab366_base.corr(g.a), "spill_corr": g.ab366_spill.corr(g.a),
        "settled<=5_h": int(low.sum()), "recall_base": ((g.ab366_base <= 5) & low).sum() / max(low.sum(), 1), "recall_spill": ((g.ab366_spill <= 5) & low).sum() / max(low.sum(), 1),
        "FA_base": int(((g.ab366_base <= 5) & ~low).sum()), "FA_spill": int(((g.ab366_spill <= 5) & ~low).sum()),
        "p10_base": g.ab366_base.quantile(0.1), "p10_spill": g.ab366_spill.quantile(0.1)})
pd.set_option("display.width", 220)
print("## IN-GATE zone-days (ratio >= 0.95) per zone:")
print(w[w.gate].groupby("z").apply(blk).round(3).to_string())
print("\n## IN-GATE pooled:"); print(blk(w[w.gate]).round(3).to_string())
print("\n## OUT-OF-GATE pooled (guard — must be unchanged):"); print(blk(w[~w.gate]).round(3).to_string())
print("\n## in-gate cells by ratio bin (pooled): dMAE, recall base→spill")
w["bin"] = pd.cut(w.ratio, [0.95, 1.0, 1.05, 9], right=False, labels=["0.95-1.0","1.0-1.05",">=1.05"])
print(w[w.gate].groupby("bin", observed=True).apply(blk)[["cells","base_MAE","spill_MAE","dMAE","base_bias","spill_bias","recall_base","recall_spill"]].round(3).to_string())
