# Marginal-block attribution of the level gap.
# usage: python attribute.py RUNDIR DAY [DAY...]
# For every zone-hour: model price, settled, gas SRMC (the model's own TTF/EUA
# rule: latest close strictly before D-1), the price-setting block (own zone or
# a zone in the same price-coupled group), and model dispatch by class vs the
# ENTSO-E actual generation per type (ex-post diagnostic only).
import sys, duckdb, pandas as pd, numpy as np
run, days = sys.argv[1], sys.argv[2:]
EX = "/home/pgeorgakopoulos/armada/em-data/euphemia-live-20261114.duckdb"
con = duckdb.connect(); con.execute(f"ATTACH '{EX}' AS ex (READ_ONLY)")

def gas_srmc(day):
    q = lambda t: con.execute(f"select close from ex.yfinance.{t} where date < cast('{day}' as date) - interval 1 day and date > cast('{day}' as date) - interval 11 day order by date desc limit 1").fetchone()[0]
    ttf, eua = q("ttf_f"), q("eua_co2")
    return ttf / 0.55 + 0.202 / 0.55 * eua + 2.0, ttf, eua

def cls(strategy, fuel):
    s = strategy
    if s.startswith("water_value"): return "hydro_" + ("PS" if "Pumped" in fuel else "res") + "_" + s.replace("water_value_", "")
    if s in ("must_run_deep", "must_run_rest", "srmc_base") or s.startswith("peak_tranche"):
        f = {"Fossil Gas": "gas", "Nuclear": "nuclear", "Fossil Brown coal/Lignite": "lignite",
             "Fossil Hard coal": "coal", "Hydro Run-of-river and pondage": "ror", "Biomass": "biomass",
             "Fossil Oil": "oil", "Energy storage": "storage", "Hydro Pumped Storage": "PS", "Waste": "waste", "Other": "other", "": "unk"}.get(fuel, "other_th")
        tier = "mr" if s.startswith("must_run") else ("base" if s == "srmc_base" else "peak")
        return f"{f}_{tier}"
    return s

settled = pd.read_csv("/home/pgeorgakopoulos/armada/em-team/results/level/settled.csv", parse_dates=["t"])
allz = []
for day in days:
    g, ttf, eua = gas_srmc(day)
    P = pd.read_csv(f"{run}/{day}.csv")
    P["t"] = pd.to_datetime(P.period.astype(str), format="%Y%m%d-%H%M")
    P = P.groupby(["zone", pd.Grouper(key="t", freq="h")]).price.mean().reset_index().rename(columns={"price": "sim"})
    B = pd.read_csv(f"{run}/{day}.book.csv", keep_default_na=False)
    B["t"] = pd.to_datetime(B.ts).dt.floor("h")
    # fleet-completion (AGG-<zone>-<fuel>) and outage-tranche (OUT-<zone>-<fuel>) owners carry the fuel in the tag
    for pre in ("AGG-", "OUT-"):
        m = (B.fuel == "") & B.owner.str.startswith(pre)
        B.loc[m, "fuel"] = [o[len(pre) + len(z) + 1:].replace("_", " ") for o, z in zip(B.owner[m], B.zone[m])]
        B.loc[m, "owner_kind"] = pre[:3]
    B["cls"] = [cls(s, f) for s, f in zip(B.strategy, B.fuel)]
    B = B.merge(P, on=["zone", "t"])
    sup = B[B.side == "supply"]
    # marginal: own-zone block within 0.02 €/MWh of the clearing price
    near = B[(B.price - B.sim).abs() <= 0.02]
    own = near.groupby(["zone", "t"]).apply(lambda d: d.loc[d.mw.idxmax(), "cls"] + ("" if d.side.iloc[0] == "supply" else "(D)"), include_groups=False).rename("marg_own")
    # coupled: same-ts zones with equal price
    rows = []
    Pi = P.set_index(["zone", "t"]).sim
    ownd = own.to_dict()
    for (z, t), p in Pi.items():
        if (z, t) in ownd:
            rows.append((z, t, ownd[(z, t)], z)); continue
        cand = [(zz, ownd[(zz, t)]) for zz in Pi.xs(t, level="t").index if zz != z and abs(Pi[(zz, t)] - p) <= 0.02 and (zz, t) in ownd]
        rows.append((z, t, cand[0][1] if cand else "none", cand[0][0] if cand else ""))
    M = pd.DataFrame(rows, columns=["zone", "t", "marg", "marg_zone"])
    acc = sup[sup.price < sup.sim - 0.02].groupby(["zone", "t", "cls"]).mw.sum().unstack(fill_value=0)
    below = sup[sup.price < 0.85 * g].groupby(["zone", "t"]).mw.sum().rename("offered_below_gas")
    D = P.merge(M, on=["zone", "t"]).merge(settled, on=["zone", "t"], how="left")
    D = D.merge(below.reset_index(), on=["zone", "t"], how="left")
    D["gas"] = g; D["day"] = day; D["ttf"] = ttf
    allz.append(D)
    acc.reset_index().assign(day=day).to_csv(f"{run}/{day}.accepted.csv", index=False)
A = pd.concat(allz, ignore_index=True)
A.to_csv(f"{run}/attrib.csv", index=False)
A["err"] = A.sim - A.act
print("gas SRMC by day:", A.groupby("day").gas.first().round(1).to_dict())
gas_real = A.act >= 0.85 * A.gas
under = gas_real & (A.sim < 0.85 * A.gas)
print(f"cells {len(A)} settled {A.act.notna().sum()}; settled>=0.85*gas {gas_real.sum()}; of which sim<0.85*gas {under.sum()}")
Z = A.groupby("zone").agg(n=("sim", "size"), act=("act", "mean"), sim=("sim", "mean"), gas=("gas", "mean"),
                          mae=("err", lambda e: e.abs().mean()), bias=("err", "mean"),
                          gas_set_real=("act", lambda a: (a >= 0.85 * A.loc[a.index, "gas"]).mean()),
                          gas_set_sim=("sim", lambda s: (s >= 0.85 * A.loc[s.index, "gas"]).mean()))
pd.set_option("display.width", 250); pd.set_option("display.max_rows", 200)
print(Z.round(2).sort_values("bias").to_string())
print("\nMarginal class in UNDER cells (settled gas-set, model below gas), all zones:")
print(A[under].marg.value_counts().head(25).to_string())
print("\nMarginal class, UNDER cells, by zone (top 3):")
for z, d in A[under].groupby("zone"):
    vc = d.marg.value_counts()
    print(f"  {z:12s} n={len(d):3d}  " + "; ".join(f"{k} {v}" for k, v in vc.head(4).items()) + f"  | marg_zone: " + ",".join(d.marg_zone.value_counts().head(3).index))
