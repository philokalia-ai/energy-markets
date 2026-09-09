# Evaluate one code version of the multi_zone_eu record against another on the
# ledger's ladder: paired zone-hours vs settled, per zone MAE/bias/corr, footprint
# pooled corr/MAE, energy-weighted MAE, and energy@corr>=0.7/0.75/0.8 (share of
# footprint settled load energy in zones whose corr clears the bar).
# Usage: CV_A=37 CV_B=38 [W0=2024-07-01 W1=2026-07-01] python eval_cv.py
import os, psycopg2, pandas as pd, numpy as np
cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"])
A, B = int(os.environ.get("CV_A", 37)), int(os.environ.get("CV_B", 38))
W0, W1 = os.environ.get("W0", "2024-07-01"), os.environ.get("W1", "2026-07-01")
sim = pd.read_sql("""select code_version cv, bidding_zone z, date_time_utc t, price_eur_mwh p from simulations.energy_prices
   where clearing_mode='multi_zone_eu' and code_version in (%s,%s) and date_time_utc >= %s and date_time_utc < %s""", cx, params=(A, B, W0, W1))
sim["t"] = pd.to_datetime(sim.t)
act = pd.read_sql("""select map_code z, date_trunc('hour', date_time_utc at time zone 'UTC') t, avg(price_currency_mwh) a
   from entsoe.energy_prices where contract_type='Day-ahead' and date_time_utc >= %s and date_time_utc < %s group by 1,2""", cx, params=(W0, W1))
act["t"] = pd.to_datetime(act.t)
load = pd.read_sql("""select area_map_code z, date_trunc('hour', date_time_utc at time zone 'UTC') t, avg(total_load_mw) w
   from entsoe.actual_total_load where area_type_code like 'BZN%%' and date_time_utc >= %s and date_time_utc < %s group by 1,2""", cx, params=(W0, W1))
load["t"] = pd.to_datetime(load.t)
wide = sim.pivot_table(index=["z", "t"], columns="cv", values="p").dropna().reset_index()
m = wide.merge(act, on=["z", "t"]).merge(load, on=["z", "t"], how="left")
m["w"] = m.w.fillna(m.groupby("z").w.transform("mean")).fillna(m.w.mean())
days = m.t.dt.normalize().nunique()
cov = {cv: sim[sim.cv == cv].t.dt.normalize().nunique() for cv in (A, B)}
print(f"window {W0}..{W1}: cv{A} days {cov[A]}, cv{B} days {cov[B]}, paired days {days}, zones {m.z.nunique()}, paired cells {len(m)}")
def zone_tab(m):
    rows = []
    for z, g in m.groupby("z"):
        r = {"zone": z, "n": len(g), "energy_TWh": g.w.sum() / 1e6}
        for cv in (A, B):
            e = g[cv] - g.a
            r[f"cv{cv}_MAE"] = e.abs().mean(); r[f"cv{cv}_bias"] = e.mean(); r[f"cv{cv}_corr"] = g[cv].corr(g.a)
        r["dMAE"] = r[f"cv{B}_MAE"] - r[f"cv{A}_MAE"]; r["dcorr"] = r[f"cv{B}_corr"] - r[f"cv{A}_corr"]
        rows.append(r)
    return pd.DataFrame(rows)
tab = zone_tab(m)
pd.set_option("display.width", 220); pd.set_option("display.max_rows", 100)
print(tab.sort_values("dMAE").round(3).to_string(index=False))
E = tab.energy_TWh.sum()
print("\n## FOOTPRINT (pooled cells / energy-weighted)")
for cv in (A, B):
    e = m[cv] - m.a
    lad = " ".join(f"E@corr>={th}: {100*tab.loc[tab[f'cv{cv}_corr'] >= th, 'energy_TWh'].sum()/E:.1f}%" for th in (0.7, 0.75, 0.8))
    print(f"cv{cv}: corr={m[cv].corr(m.a):.3f} MAE={e.abs().mean():.2f} ewMAE={(e.abs()*m.w).sum()/m.w.sum():.2f} bias={e.mean():+.2f} | zones corr>=0.7: {(tab[f'cv{cv}_corr']>=0.7).sum()}/{len(tab)} | {lad}")
d = m[B] - m[A]
print(f"cells changed: {int((d != 0).sum())} of {len(d)} ({100*(d != 0).mean():.1f}%), mean |Δ| where changed {d[d != 0].abs().mean():.2f}, max |Δ| {d.abs().max():.1f}")
m["yr"] = m.t.dt.year
print("\n## by calendar year (footprint MAE / corr, cvA -> cvB)")
for yr, g in m.groupby("yr"):
    print(f"  {yr}: n={len(g)}  MAE {(g[A]-g.a).abs().mean():.2f} -> {(g[B]-g.a).abs().mean():.2f}   corr {g[A].corr(g.a):.3f} -> {g[B].corr(g.a):.3f}")
m["h"] = m.t.dt.hour
print("\n## evening 16-19 UTC (footprint MAE / bias, cvA -> cvB)")
g = m[m.h.between(16, 19)]
print(f"  MAE {(g[A]-g.a).abs().mean():.2f} -> {(g[B]-g.a).abs().mean():.2f}   bias {(g[A]-g.a).mean():+.2f} -> {(g[B]-g.a).mean():+.2f}")
