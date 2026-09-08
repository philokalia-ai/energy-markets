# #365 first experiment: do cv37's Core net positions violate the published
# flow-based domain? No re-clear. Window = the only recent domain coverage,
# 2026-01-01..2026-02-09. Read-only.
import os, psycopg2, pandas as pd, numpy as np
cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"])
CORE = {"AT":"at","BE":"be","CZ":"cz","DE_LU":"de","FR":"fr","HR":"hr","HU":"hu","NL":"nl","PL":"pl","RO":"ro","SI":"si","SK":"sk"}
W0, W1 = "2026-01-01", "2026-02-10"
fl = pd.read_sql("""select date_time_utc t, source_zone s, sink_zone k, flow_mw::float8 f from simulations.transmission_flows
   where code_version=37 and clearing_mode='multi_zone_eu' and date_time_utc >= %s and date_time_utc < %s""", cx, params=(W0, W1))
fl = fl[fl.s.isin(CORE) & fl.k.isin(CORE)]           # Core-internal exchanges only
print("Core-internal model flows:", len(fl), "rows; borders:", sorted(set(zip(fl.s, fl.k)))[:40])
# net position per hub: + export. flow_mw sign: positive = source->sink (checked: AT->BE mixed signs -> signed flow)
np_ = pd.concat([fl.assign(h=fl.s, v=fl.f), fl.assign(h=fl.k, v=-fl.f)]).groupby(["t","h"]).v.sum().unstack(fill_value=0.0)
for z in CORE:
    if z not in np_.columns: np_[z] = 0.0
# ALEGrO: BE<->DE exchange = the DC link; JAO carries it on virtual hubs ALBE/ALDE
be_de = fl[(fl.s=="BE")&(fl.k=="DE_LU")].set_index("t").f.reindex(np_.index).fillna(0) - fl[(fl.s=="DE_LU")&(fl.k=="BE")].set_index("t").f.reindex(np_.index).fillna(0)
np_["ALBE"] = -be_de.values; np_["ALDE"] = be_de.values
print("hub NP stats (MW, export +):"); print(np_.describe().loc[["mean","min","max"]].round(0).to_string())
dom = pd.read_sql("""select (mtu at time zone 'UTC') t, cne_name, direction, cont_name, tso, ram, fmax, fref, presolved,
   ptdf_at, ptdf_be, ptdf_cz, ptdf_de, ptdf_fr, ptdf_hr, ptdf_hu, ptdf_nl, ptdf_pl, ptdf_ro, ptdf_si, ptdf_sk, ptdf_albe, ptdf_alde
   from jao.final_domain where mtu >= %s and mtu < %s and presolved""", cx, params=(W0, W1))
dom["t"] = pd.to_datetime(dom.t)
print("presolved domain rows:", len(dom), "MTUs:", dom.t.nunique())
cols = {"ptdf_at":"AT","ptdf_be":"BE","ptdf_cz":"CZ","ptdf_de":"DE_LU","ptdf_fr":"FR","ptdf_hr":"HR","ptdf_hu":"HU","ptdf_nl":"NL","ptdf_pl":"PL","ptdf_ro":"RO","ptdf_si":"SI","ptdf_sk":"SK","ptdf_albe":"ALBE","ptdf_alde":"ALDE"}
P = dom[list(cols)].fillna(0).values
N = np_.reindex(dom.t)[list(cols.values())].fillna(0).values
dom["flow"] = (P * N).sum(axis=1)               # zone-to-slack PTDF · NP  (JAO convention: F = Fref + PTDF·(NP - NP_ref); RAM already nets Fref)
dom["margin"] = dom.ram - dom.flow
cnec = dom[dom.cne_name.str.contains("Equality Constraint")==False]
eq = dom[dom.cne_name.str.contains("Equality Constraint")]
print("\n## Equality constraints (sum of hub NPs): |PTDF·NP| stats -> how far the model's Core NPs are from summing to zero (HR missing, non-Core exports leak in):")
print(eq.groupby("cne_name").flow.describe()[["mean","50%","max"]].round(0).to_string())
viol = cnec[cnec.margin < 0]
per_mtu = cnec.groupby("t").agg(n=("margin","size"), nviol=("margin", lambda m: (m<0).sum()), worst=("margin","min"))
print(f"\n## CNEC/allocation constraints: {len(cnec)} rows over {cnec.t.nunique()} MTUs")
print(f"violated rows: {len(viol)} ({100*len(viol)/len(cnec):.1f}%); MTUs with >=1 violation: {(per_mtu.nviol>0).sum()} of {len(per_mtu)} ({100*(per_mtu.nviol>0).mean():.1f}%)")
print("worst margin (MW) quantiles over MTUs:", per_mtu.worst.quantile([0.05,0.25,0.5,0.75,0.95]).round(0).to_dict())
print("violation depth (MW) quantiles over violated rows:", (-viol.margin).quantile([0.5,0.9,0.99]).round(0).to_dict(), " max:", round(-viol.margin.min()))
print("\n## by hour of day: share of MTUs violated, median worst margin")
h = per_mtu.copy(); h["hour"] = h.index.hour
print(h.groupby("hour").agg(share_viol=("nviol", lambda x: (x>0).mean()), med_worst=("worst","median")).round(2).T.to_string())
print("\n## most-violated constraints (rows violated, mean depth MW):")
top = viol.groupby(["cne_name","direction","cont_name","tso"]).agg(n=("margin","size"), depth=("margin", lambda m: -m.mean())).sort_values("n", ascending=False).head(12)
print(top.round(0).to_string())
print("\n## which hubs drive violations: mean PTDF·NP contribution on violated rows (MW)")
contrib = pd.DataFrame(P[viol.index] * N[viol.index], columns=list(cols.values())).mean().round(0)
print(contrib.sort_values(ascending=False).to_string())
# sensitivity: ALEGrO on BE/DE hubs instead of virtual hubs
N2 = N.copy(); ia, ib = list(cols.values()).index("ALBE"), list(cols.values()).index("ALDE"); N2[:, ia] = 0; N2[:, ib] = 0
m2 = dom.ram.values - (P*N2).sum(axis=1); m2 = m2[~dom.cne_name.str.contains("Equality Constraint").values]
print(f"\nsensitivity — ALEGrO folded into BE/DE hubs: violated rows {int((m2<0).sum())} ({100*(m2<0).mean():.1f}%)")
