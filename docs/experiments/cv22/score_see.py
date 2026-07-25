#!/usr/bin/env python3
"""SEE-delta scorer (bug 2). Compares out_see_base.tsv vs out_see_cv22.tsv
against realized DA prices from the offline extract's entsoe.energy_prices.
Per (mode, zone): MAE(base) vs MAE(cv22) and the max |Δprice| between arms.

  python3 score_see.py                       # reads the two TSVs next to it
"""
import os
import duckdb
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
EXTRACT = os.path.join(HERE, "..", "..", "..", "data", "extracts", "euphemia-live.duckdb")


def load(arm):
    df = pd.read_csv(os.path.join(HERE, f"out_see_{arm}.tsv"), sep="\t")
    df["ts"] = pd.to_datetime(df.timeslot, format="%Y%m%d-%H%M").dt.floor("h")
    return df.groupby(["mode", "day", "zone", "ts"]).price.mean().rename(arm)


base, cv22 = load("base"), load("cv22")
sim = pd.concat([base, cv22], axis=1).reset_index()
days = sorted(sim.day.unique())
c = duckdb.connect(os.path.abspath(EXTRACT), read_only=True)
dl = ",".join(f"'{d}'" for d in days)
act = c.execute(f"""
  SELECT map_code AS zone, date_trunc('hour', date_time_utc) AS ts,
         AVG(price_currency_mwh) AS act
  FROM entsoe.energy_prices
  WHERE contract_type='Day-ahead' AND CAST(date_time_utc AS DATE) IN ({dl})
  GROUP BY map_code, date_trunc('hour', date_time_utc)""").df()
act["ts"] = pd.to_datetime(act.ts)
m = sim.merge(act, on=["zone", "ts"], how="inner")

print(f"{'mode':5} {'zone':4} {'n':>4} {'MAE_base':>9} {'MAE_cv22':>9} {'dMAE':>7} {'max|Δsim|':>9}")
worst = 0.0
for (mode, z), g in m.groupby(["mode", "zone"]):
    mb = (g.base - g.act).abs().mean()
    mc = (g.cv22 - g.act).abs().mean()
    dd = (g.base - g.cv22).abs().max()
    worst = max(worst, mc - mb)
    print(f"{mode:5} {z:4} {len(g):>4} {mb:>9.3f} {mc:>9.3f} {mc-mb:>+7.3f} {dd:>9.4f}")
print(f"\nWORST dMAE (cv22 - base) = {worst:+.3f}  (gate: <= +0.5)")
