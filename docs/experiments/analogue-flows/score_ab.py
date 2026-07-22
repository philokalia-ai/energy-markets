#!/usr/bin/env python3
"""Score the :v2 vs :v3 price A/B (ab_price_v3.jl outputs) against realized
day-ahead prices. Reports per zone x window: bias, MAE, corr, and the evening
(17-20 UTC) bias — the metric the July-2026 diagnosis is about.

  python3 score_ab.py out_v2.tsv out_v3.tsv windows.json

windows.json: {"name": ["YYYY-MM-DD", ...], ...} — day lists per window.
Realized prices come from ENERGY_CONN_STR (entsoe.energy_prices).
"""
import json
import os
import subprocess
import sys

import numpy as np
import pandas as pd

V2, V3, WINDOWS = sys.argv[1], sys.argv[2], sys.argv[3]
EVE_HOURS = {17, 18, 19, 20}

def load_arm(path, name):
    df = pd.read_csv(path, sep="\t")
    df["ts"] = pd.to_datetime(df.timeslot, format="%Y%m%d-%H%M")
    df = df.groupby(["day", "zone", df.ts.dt.floor("h")]).price.mean().rename(name)
    return df

v2 = load_arm(V2, "v2")
v3 = load_arm(V3, "v3")
sim = pd.concat([v2, v3], axis=1).reset_index()
days = sorted(sim.day.unique())

# realized prices via psql (ENERGY_CONN_STR from .env)
em = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
dlist = ",".join(f"'{d}'" for d in days)
sql = f"""SELECT map_code, date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') h,
AVG(price_currency_mwh) p FROM entsoe.energy_prices
WHERE contract_type='Day-ahead' AND (date_time_utc AT TIME ZONE 'UTC')::date IN ({dlist})
GROUP BY 1,2"""
r = subprocess.run(
    f"set -a && . {em}/.env >/dev/null 2>&1 && set +a && "
    f"psql \"$ENERGY_CONN_STR\" -tA -F'\t' -c \"{sql}\"",
    shell=True, capture_output=True, text=True, check=True)
act = pd.DataFrame([l.split("\t") for l in r.stdout.strip().split("\n")],
                   columns=["zone", "ts", "act"])
act["ts"] = pd.to_datetime(act.ts)
act["act"] = act.act.astype(float)

m = sim.merge(act, on=["zone", "ts"], how="inner")
m["hour"] = m.ts.dt.hour
m["eve"] = m.hour.isin(EVE_HOURS)
windows = {k: set(v) for k, v in json.load(open(WINDOWS)).items()}

rows = []
for wname, wdays in windows.items():
    w = m[m.day.isin(wdays)]
    for z, g in w.groupby("zone"):
        for arm in ("v2", "v3"):
            e = g[arm] - g.act
            ev = g[g.eve][arm] - g[g.eve].act
            rows.append((wname, z, arm, len(g),
                         e.mean(), e.abs().mean(), g[arm].corr(g.act),
                         ev.mean(), ev.abs().mean()))
res = pd.DataFrame(rows, columns=["window", "zone", "arm", "n", "bias", "mae",
                                  "corr", "eve_bias", "eve_mae"])
res.to_csv(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "results_price_ab.tsv"), sep="\t", index=False,
           float_format="%.2f")

for wname in windows:
    p = res[res.window == wname].pivot_table(
        index="zone", columns="arm", values=["eve_bias", "mae", "corr"])
    print(f"\n=== {wname} ===")
    print(p.round(2).to_string())
    d = res[res.window == wname]
    for met, better in (("mae", "lower"), ("eve_mae", "lower")):
        a = d[d.arm == "v2"].set_index("zone")[met]
        b = d[d.arm == "v3"].set_index("zone")[met]
        imp = (b - a).dropna()
        print(f"{met}: mean v2 {a.mean():.2f} -> v3 {b.mean():.2f}; "
              f"zones better/worse: {(imp<0).sum()}/{(imp>0).sum()}")
