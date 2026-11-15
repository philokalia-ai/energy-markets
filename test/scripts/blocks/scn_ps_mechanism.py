"""PS mechanism under the GR DC (+574 MW), cv44: how the PS master's allocation moves.
usage: scn_ps_mechanism.py DIR   (output of scn_ps_mechanism.jl)
Per storage family: daily MWh used and budget (binding?), MWh shifted between hours
(sum of |Δalloc|/2), and the share of the family's energy in the DC arm's 6 highest-price
GR hours (base vs DC). Also GR/BG price Δ by hour and the correlation of each family's
Δalloc with the GR price Δ."""
import sys, glob, os, pandas as pd, numpy as np
D = sys.argv[1]
days = sorted({os.path.basename(f).split("_")[1][:10] for f in glob.glob(f"{D}/base_*.alloc.csv")})
days = [d for d in days if os.path.exists(f"{D}/dc574_{d}.alloc.csv")]
A, P = [], []
for d in days:
    for arm in ("base", "dc574"):
        a = pd.read_csv(f"{D}/{arm}_{d}.alloc.csv"); a["arm"] = arm; a["day"] = d; A.append(a)
        p = pd.read_csv(f"{D}/{arm}_{d}.prices.csv"); p["arm"] = arm; p["day"] = d; P.append(p)
A = pd.concat(A); P = pd.concat(P)
A["t"] = pd.to_datetime(A.date_time).dt.floor("h")
P["t"] = pd.to_datetime(P.period.astype(str), format="%Y%m%d-%H%M")
fa = A.groupby(["arm", "day", "family", "t"]).alloc_mw.sum().unstack("arm").fillna(0).reset_index()
fa["d"] = fa.dc574 - fa.base
pp = P.pivot_table(index=["zone", "t"], columns="arm", values="price").reset_index()
pp["dp"] = pp.dc574 - pp.base
gr = pp[pp.zone == "GR"][["t", "base", "dc574", "dp"]].rename(columns={"base": "gr_b", "dc574": "gr_dc"})
fa = fa.merge(gr, on="t")
fa["dayk"] = fa.t.dt.strftime("%Y-%m-%d")
top = fa.assign(top6=fa.groupby(["family", "dayk"]).gr_dc.rank(ascending=False, method="first") <= 6)
bud = A.groupby(["arm", "day", "family"]).agg(budget=("budget_mwh", "first"), used=("used_mwh", "first")).unstack("arm")
print(f"days: {days}")
rows = []
for fam, g in top.groupby("family"):
    eb, ed = g.base.sum(), g.dc574.sum()
    if eb < 1 and ed < 1: continue
    b = bud.xs(fam, level="family")
    rows.append(dict(family=fam, MWh_base=eb, MWh_dc=ed, dMWh=ed - eb,
        budget_binding_base=int((b[("used", "base")] >= b[("budget", "base")] - 1).sum()),
        budget_binding_dc=int((b[("used", "dc574")] >= b[("budget", "dc574")] - 1).sum()),
        shifted_MWh=g.d.abs().sum() / 2,
        top6_share_base=g[g.top6].base.sum() / eb if eb else np.nan,
        top6_share_dc=g[g.top6].dc574.sum() / ed if ed else np.nan,
        corr_dalloc_dpGR=np.corrcoef(g.d, g.dp)[0, 1] if g.d.std() > 1e-6 else np.nan))
pd.set_option("display.width", 220)
print(pd.DataFrame(rows).set_index("family").round(2).to_string())
print("\nGR / BG price Δ (DC − base) by UTC hour, mean over days:")
h = pp[pp.zone.isin(["GR", "BG", "RO", "RS"])].assign(hr=lambda x: x.t.dt.hour).pivot_table(index="hr", columns="zone", values="dp")
print(h.round(2).T.to_string())
gfa = fa[fa.family.isin(["ESTOR:GR", "ESTOR:BG"])].assign(hr=lambda x: x.t.dt.hour).pivot_table(index="hr", columns="family", values="d")
print("\nΔ PS allocation (MW, DC − base) by UTC hour, mean over days:")
print(gfa.round(0).T.to_string())
