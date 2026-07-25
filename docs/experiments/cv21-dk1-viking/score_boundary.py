#!/usr/bin/env python3
"""Score the boundary-zone A/B/C (ab_boundary.jl outputs) against realized
day-ahead prices. Per zone x window: bias, MAE, corr, evening (17-20 UTC)
bias/MAE — the July-2026 diagnosis metric.

  python3 score_boundary.py base=out_base.tsv mecha=out_mecha.tsv mechb=out_mechb.tsv windows_ab.json

Realized prices from ENERGY_CONN_STR (entsoe.energy_prices), hourly AVG.
Writes results_price_ab.tsv next to itself.
"""
import json
import os
import subprocess
import sys

import pandas as pd

args = sys.argv[1:]
WINDOWS = args[-1]
ARMS = [a.split("=", 1) for a in args[:-1]]
EVE_HOURS = {17, 18, 19, 20}
HERE = os.path.dirname(os.path.abspath(__file__))
EM = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))


def load_arm(path, name):
    df = pd.read_csv(path, sep="\t")
    df["ts"] = pd.to_datetime(df.timeslot, format="%Y%m%d-%H%M")
    return df.groupby(["day", "zone", df.ts.dt.floor("h")]).price.mean().rename(name)


sim = pd.concat([load_arm(p, n) for n, p in ARMS], axis=1).reset_index()
days = sorted(sim.day.unique())

dlist = ",".join(f"'{d}'" for d in days)
sql = f"""SELECT map_code, date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') h,
AVG(price_currency_mwh) p FROM entsoe.energy_prices
WHERE contract_type='Day-ahead' AND (date_time_utc AT TIME ZONE 'UTC')::date IN ({dlist})
GROUP BY 1,2"""
r = subprocess.run(
    f"set -a && . {EM}/.env >/dev/null 2>&1 && set +a && "
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
        for arm, _ in ARMS:
            gg = g.dropna(subset=[arm])
            if not len(gg):
                continue
            e = gg[arm] - gg.act
            ge = gg[gg.eve]
            ev = ge[arm] - ge.act
            rows.append((wname, z, arm, len(gg),
                         e.mean(), e.abs().mean(), gg[arm].corr(gg.act),
                         ev.mean(), ev.abs().mean()))
res = pd.DataFrame(rows, columns=["window", "zone", "arm", "n", "bias", "mae",
                                  "corr", "eve_bias", "eve_mae"])
res.to_csv(os.path.join(HERE, "results_price_ab.tsv"), sep="\t", index=False,
           float_format="%.2f")

arm_names = [n for n, _ in ARMS]
for wname in windows:
    d = res[res.window == wname]
    p = d.pivot_table(index="zone", columns="arm",
                      values=["eve_bias", "mae", "corr"])
    p = p.reindex(columns=pd.MultiIndex.from_product(
        [["corr", "mae", "eve_bias"], arm_names]))
    print(f"\n=== {wname} ===")
    print(p.round(2).to_string())
    base = d[d.arm == arm_names[0]].set_index("zone")
    for arm in arm_names[1:]:
        b = d[d.arm == arm].set_index("zone")
        for met in ("mae", "eve_mae"):
            imp = (b[met] - base[met]).dropna()
            print(f"{arm} vs {arm_names[0]} {met}: mean "
                  f"{base[met].mean():.2f} -> {b[met].mean():.2f}; "
                  f"zones better/worse: {(imp<0).sum()}/{(imp>0).sum()}")
