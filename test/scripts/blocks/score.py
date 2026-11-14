"""Score blocks-experiment arms against settled day-ahead (resolution-aware hourly mean,
latest sequence) from the read-only extract. usage: score.py BASE_LABEL TREAT_LABEL [days...]"""
import sys, os, glob, duckdb, pandas as pd, numpy as np
R = "/home/pgeorgakopoulos/armada/em-team/results/blocks"
EXTRACT = "/home/pgeorgakopoulos/armada/em-data/euphemia-live-20261114.duckdb"
base, treat = sys.argv[1], sys.argv[2]
def load(label):
    fs = sorted(glob.glob(f"{R}/{label}/2026-*-??.csv"))
    out = []
    for f in fs:
        df = pd.read_csv(f)
        df["t"] = pd.to_datetime(df.period.astype(str), format="%Y%m%d-%H%M")
        df["day"] = os.path.basename(f)[:10]
        out.append(df[["zone", "t", "day", "price"]])
    return pd.concat(out) if out else pd.DataFrame(columns=["zone","t","day","price"])
b, t = load(base), load(treat)
days = sorted(set(b.day) & set(t.day))
if len(sys.argv) > 3: days = [d for d in days if d in sys.argv[3:]]
b, t = b[b.day.isin(days)], t[t.day.isin(days)]
con = duckdb.connect(EXTRACT, read_only=True)
act = con.sql(f"""
 with dedup as (select distinct on (map_code, date_time_utc) map_code, date_time_utc, price_currency_mwh
   from entsoe.energy_prices where contract_type='Day-ahead' and area_type_code like 'BZN%'
   and price_currency_mwh is not null and date_time_utc >= '{min(days)}' and date_time_utc < cast('{max(days)}' as date) + 1
   order by map_code, date_time_utc, try_cast(trim(sequence) as int) desc nulls last, update_time_utc desc)
 select map_code as zone, date_trunc('hour', date_time_utc) as t, avg(price_currency_mwh) as act from dedup group by 1,2""").df()
m = b.merge(t, on=["zone","t","day"], suffixes=("_b","_t")).merge(act, on=["zone","t"])
m["IT"] = m.zone.str.startswith("IT-")
def stats(g, col):
    e = g[col] - g.act
    c = np.corrcoef(g[col], g.act)[0,1] if g[col].std() > 1e-9 and g.act.std() > 1e-9 else np.nan
    hit = ((g[col] <= 0) & (g.act <= 0)).sum(); fa = ((g[col] <= 0) & (g.act > 0)).sum()
    return pd.Series({"mae": e.abs().mean(), "bias": e.mean(), "corr": c, "hit0": hit, "fa0": fa})
def both(g):
    s1, s2 = stats(g, "price_b"), stats(g, "price_t")
    return pd.Series({"n": len(g), "act_le0": int((g.act<=0).sum()), "mae_b": s1.mae, "mae_t": s2.mae, "dmae": s2.mae-s1.mae,
        "bias_b": s1.bias, "bias_t": s2.bias, "corr_b": s1["corr"], "corr_t": s2["corr"],
        "hit0_b": s1.hit0, "hit0_t": s2.hit0, "fa0_b": s1.fa0, "fa0_t": s2.fa0,
        "cells_moved": int(((g.price_t-g.price_b).abs() > 0.5).sum())})
pd.set_option("display.width", 250); pd.set_option("display.max_rows", 200)
fmt = lambda df: df.round(2).to_string()
print(f"days: {days}  cells paired with actuals: {len(m)}  (base {len(b)}, treat {len(t)})")
print("\n== footprint ==")
print(fmt(pd.DataFrame({"all39": both(m), "exIT": both(m[~m.IT])}).T))
print("\n== per day (all / exIT) ==")
print(fmt(m.groupby("day").apply(both)))
print(fmt(m[~m.IT].groupby("day").apply(both)))
print("\n== per zone ==")
print(fmt(m.groupby("zone").apply(both).sort_values("dmae")))
# where the mechanism acts: capped slots
cf = []
for d in days:
    f = f"{R}/{treat}/{d}.complex.csv"
    if os.path.exists(f):
        c = pd.read_csv(f); c = c[c.status == "optimal"]
        if len(c): c["zone"] = c.family.str.split(":").str[1]; c["t"] = pd.to_datetime(c.date_time); c["day"] = d; cf.append(c)
if cf:
    c = pd.concat(cf)
    c["binding"] = c.alloc_mw < c.offered_mw - 0.1
    fam = c.groupby(["day","family"]).agg(budget=("budget_mwh","first"), used=("used_mwh","first"), capped_slots=("binding","sum"), master_s=("master_s","first"))
    print("\n== families (capped slots per day) =="); print(fmt(fam.groupby("family").agg({"budget":"mean","used":"mean","capped_slots":"mean"})))
    print("master LP seconds per day (pass-2 call):", c.groupby("day").master_s.first().round(1).to_dict())
    acts = m.merge(c[["zone","t"]].drop_duplicates(), on=["zone","t"], how="inner")
    rest = m.merge(c[["zone","t"]].drop_duplicates(), on=["zone","t"], how="left", indicator=True); rest = rest[rest._merge=="left_only"]
    print("\n== where it acts: zone-hours whose PS offer was capped by the budget ==")
    print(fmt(pd.DataFrame({"capped_cells": both(acts), "capped_exIT": both(acts[~acts.IT]), "other_cells": both(rest)}).T))
    print(fmt(acts.groupby("zone").apply(both).sort_values("dmae")))
