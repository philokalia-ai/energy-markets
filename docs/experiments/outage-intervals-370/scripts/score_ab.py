# Score the two #370 arms against settled prices on paired days. Read-only.
import os, sys, psycopg2, pandas as pd, numpy as np
cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"])
arms = sys.argv[1:] or ["ab370_legacy", "ab370_intervals"]
sim = pd.read_sql("""select clearing_mode arm, bidding_zone z, date_time_utc t, price_eur_mwh p
   from simulations.energy_prices where clearing_mode = any(%s) and code_version = %s""", cx,
   params=(arms, int(os.environ.get("CV", "37"))))
sim["t"] = pd.to_datetime(sim.t)   # simulations.* stores naive UTC
t0, t1 = sim.t.min(), sim.t.max() + pd.Timedelta(hours=1)
act = pd.read_sql("""select map_code z, date_trunc('hour', date_time_utc at time zone 'UTC') t, avg(price_currency_mwh) a
   from entsoe.energy_prices where contract_type='Day-ahead' and date_time_utc >= %s and date_time_utc < %s group by 1,2""",
   cx, params=(t0.to_pydatetime(), t1.to_pydatetime()))
act["t"] = pd.to_datetime(act.t)
load = pd.read_sql("""select area_map_code z, date_trunc('hour', date_time_utc at time zone 'UTC') t, avg(total_load_mw) w
   from entsoe.actual_total_load where area_type_code like 'BZN%%' and date_time_utc >= %s and date_time_utc < %s group by 1,2""",
   cx, params=(t0.to_pydatetime(), t1.to_pydatetime()))
load["t"] = pd.to_datetime(load.t)
wide = sim.pivot_table(index=["z", "t"], columns="arm", values="p").dropna().reset_index()
wide["d"] = wide.t.dt.date
# paired cells = zone-hours present in BOTH arms (a zone-day that failed in one arm drops out of the pair)
m = wide.merge(act, on=["z", "t"]).merge(load, on=["z", "t"], how="left")
print(f"paired days: {m.d.nunique()}  zones: {m.z.nunique()}  cells: {len(m)}  (zone-hours present in both arms; per-day zone count min {m.groupby('d').z.nunique().min()})")
def score(g, arm):
    e = g[arm] - g.a
    return pd.Series({f"{arm}_MAE": e.abs().mean(), f"{arm}_bias": e.mean(), f"{arm}_corr": g[arm].corr(g.a)})
rows = []
for z, g in m.groupby("z"):
    r = {"zone": z, "n": len(g)}
    for arm in arms: r.update(score(g, arm).to_dict())
    r["dMAE"] = r[f"{arms[1]}_MAE"] - r[f"{arms[0]}_MAE"]; r["dcorr"] = r[f"{arms[1]}_corr"] - r[f"{arms[0]}_corr"]
    r["diff_cells"] = int((g[arms[0]] != g[arms[1]]).sum())
    rows.append(r)
tab = pd.DataFrame(rows).sort_values("dMAE")
pd.set_option("display.width", 200); pd.set_option("display.max_rows", 100)
print(tab.round(3).to_string(index=False))
w = m.w.fillna(m.w.mean())
for arm in arms:
    e = m[arm] - m.a
    print(f"FOOTPRINT {arm}: MAE={e.abs().mean():.2f} energy-wMAE={(e.abs()*w).sum()/w.sum():.2f} bias={e.mean():+.2f} corr={m[arm].corr(m.a):.3f}")
d = (m[arms[1]] - m[arms[0]])
print(f"arm difference: cells changed {int((d!=0).sum())} of {len(d)} ({100*(d!=0).mean():.1f}%), mean |Δ| where changed {d[d!=0].abs().mean():.2f}, max |Δ| {d.abs().max():.1f}")
