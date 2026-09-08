# Control for domain_probe.py: the same test on REALISED Core net positions
# (ENTSO-E physical flows, hourly, BZN both sides). Physical != commercial
# (loop flows), so a small violation share is expected; the model's 96 % is not.
# Also: model vs realised net position error per hub.
import os, psycopg2, pandas as pd, numpy as np
cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"])
CORE = ["AT","BE","CZ","DE_LU","FR","HR","HU","NL","PL","RO","SI","SK"]
W0, W1 = "2026-01-01", "2026-02-10"
ph = pd.read_sql("""select date_trunc('hour', date_time_utc at time zone 'UTC') t, out_area_map_code s, in_area_map_code k, avg(flow_mw) f
   from entsoe.physical_flows where date_time_utc >= %s and date_time_utc < %s
   and out_area_type_code like 'BZN%%' and in_area_type_code like 'BZN%%'
   and out_area_map_code = any(%s) and in_area_map_code = any(%s) group by 1,2,3""", cx, params=(W0, W1, CORE, CORE))
ph["t"] = pd.to_datetime(ph.t)
print("physical Core-internal border-hours:", len(ph), " directed borders:", ph.groupby(["s","k"]).ngroups)
npp = pd.concat([ph.assign(h=ph.s, v=ph.f), ph.assign(h=ph.k, v=-ph.f)]).groupby(["t","h"]).v.sum().unstack(fill_value=0.0)
for z in CORE:
    if z not in npp.columns: npp[z] = 0.0
bede = ph[(ph.s=="BE")&(ph.k=="DE_LU")].set_index("t").f.reindex(npp.index).fillna(0) - ph[(ph.s=="DE_LU")&(ph.k=="BE")].set_index("t").f.reindex(npp.index).fillna(0)
npp["ALBE"] = -bede.values; npp["ALDE"] = bede.values
fl = pd.read_sql("""select date_time_utc t, source_zone s, sink_zone k, flow_mw::float8 f from simulations.transmission_flows
   where code_version=37 and clearing_mode='multi_zone_eu' and date_time_utc >= %s and date_time_utc < %s""", cx, params=(W0, W1))
fl = fl[fl.s.isin(CORE) & fl.k.isin(CORE)]
npm = pd.concat([fl.assign(h=fl.s, v=fl.f), fl.assign(h=fl.k, v=-fl.f)]).groupby(["t","h"]).v.sum().unstack(fill_value=0.0)
for z in CORE:
    if z not in npm.columns: npm[z] = 0.0
common = npm.index.intersection(npp.index)
print(f"\n## net-position error, model (cv37) vs realised physical, {len(common)} hours (MW):")
err = (npm.loc[common, CORE] - npp.loc[common, CORE])
print(pd.DataFrame({"model_mean": npm.loc[common, CORE].mean(), "phys_mean": npp.loc[common, CORE].mean(), "MAE": err.abs().mean(), "bias": err.mean(), "corr": [round(npm.loc[common, z].corr(npp.loc[common, z]), 2) for z in CORE]}).round(2).to_string())
dom = pd.read_sql("""select (mtu at time zone 'UTC') t, cne_name, ram,
   ptdf_at, ptdf_be, ptdf_cz, ptdf_de, ptdf_fr, ptdf_hr, ptdf_hu, ptdf_nl, ptdf_pl, ptdf_ro, ptdf_si, ptdf_sk, ptdf_albe, ptdf_alde
   from jao.final_domain where mtu >= %s and mtu < %s and presolved""", cx, params=(W0, W1))
dom["t"] = pd.to_datetime(dom.t); dom = dom[~dom.cne_name.str.contains("Equality Constraint")]
cols = {"ptdf_at":"AT","ptdf_be":"BE","ptdf_cz":"CZ","ptdf_de":"DE_LU","ptdf_fr":"FR","ptdf_hr":"HR","ptdf_hu":"HU","ptdf_nl":"NL","ptdf_pl":"PL","ptdf_ro":"RO","ptdf_si":"SI","ptdf_sk":"SK","ptdf_albe":"ALBE","ptdf_alde":"ALDE"}
P = dom[list(cols)].fillna(0).values
for name, NP in (("realised physical", npp), ("model cv37", npm.assign(ALBE=0.0, ALDE=0.0) if "ALBE" not in npm else npm)):
    N = NP.reindex(dom.t)[list(cols.values())].fillna(0).values
    m = dom.ram.values - (P*N).sum(axis=1)
    per = pd.Series(m).groupby(dom.t.values).min()
    print(f"\n{name}: violated rows {int((m<0).sum())} of {len(m)} ({100*(m<0).mean():.1f}%); MTUs with a violation {int((per<0).sum())} of {len(per)} ({100*(per<0).mean():.1f}%); median worst margin {per.median():.0f} MW; p05 {per.quantile(0.05):.0f}")
    print(f"   share of MTUs with worst margin below -100/-300/-500/-1000 MW: " + " / ".join(f"{100*(per< -k).mean():.0f}%" for k in (100,300,500,1000)))
