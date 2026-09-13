import os, sys, psycopg2, pandas as pd, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from settlement_view import canonical_settlement
cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"])
A, B = sys.argv[1], sys.argv[2]
sim = pd.read_sql("""select clearing_mode arm, bidding_zone z, date_time_utc t, price_eur_mwh p
   from simulations.energy_prices where clearing_mode = any(%s) and code_version = 39""", cx, params=([A, B],))
sim["t"] = pd.to_datetime(sim.t)
w = sim.pivot_table(index=["z","t"], columns="arm", values="p").dropna().reset_index()
t0, t1 = w.t.min().date().isoformat(), (w.t.max() + pd.Timedelta(hours=1)).date().isoformat()
act = canonical_settlement(cx, t0, t1)
load = pd.read_sql("""select area_map_code z, date_trunc('hour', date_time_utc at time zone 'UTC') t, avg(total_load_mw) wt
   from entsoe.actual_total_load where area_type_code like 'BZN%%' and date_time_utc >= %s and date_time_utc < %s group by 1,2""", cx, params=(t0, t1))
load["t"] = pd.to_datetime(load.t)
m = w.merge(act, on=["z","t"]).merge(load, on=["z","t"], how="left")
m["wt"] = m.wt.fillna(m.wt.mean())
print(f"paired days {m.t.dt.normalize().nunique()}  zones {m.z.nunique()}  cells {len(m):,}  (target: canonical SDAC per zone)")
rows=[]
for z,g in m.groupby("z"):
    r={"zone":z,"n":len(g)}
    for arm in (A,B):
        e=g[arm]-g.a; r[f"{arm}_MAE"]=e.abs().mean(); r[f"{arm}_bias"]=e.mean(); r[f"{arm}_corr"]=g[arm].corr(g.a)
    r["dMAE"]=r[f"{B}_MAE"]-r[f"{A}_MAE"]; r["dcorr"]=r[f"{B}_corr"]-r[f"{A}_corr"]
    r["diff_cells"]=int((g[A]!=g[B]).sum()); rows.append(r)
tab=pd.DataFrame(rows).sort_values("dMAE")
pd.set_option("display.width",200); pd.set_option("display.max_rows",60)
print(tab.round(3).to_string(index=False))
for arm in (A,B):
    e=m[arm]-m.a
    print(f"FOOTPRINT {arm}: MAE={e.abs().mean():.2f} ewMAE={(e.abs()*m.wt).sum()/m.wt.sum():.2f} bias={e.mean():+.2f} corr={m[arm].corr(m.a):.3f}")
d=m[B]-m[A]
print(f"cells changed {int((d!=0).sum()):,} of {len(d):,} ({100*(d!=0).mean():.1f}%), mean |Δ| where changed {d[d!=0].abs().mean():.2f}, max |Δ| {d.abs().max():.1f}")
nc=lambda s: int(((s>=500)).sum())
print(f"cells >= 500 EUR/MWh: {A} {nc(m[A])}, {B} {nc(m[B])}")
low=m.a<=5
for arm in (A,B):
    print(f"collapse (settled<=5, n={int(low.sum())}) {arm}: recall {((m[arm]<=5)&low).sum()/max(low.sum(),1):.3f} FA {int(((m[arm]<=5)&~low).sum())}")
