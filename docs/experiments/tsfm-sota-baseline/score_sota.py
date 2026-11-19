#!/usr/bin/env python3
"""Score the epftoolbox baselines against the tsfm arms on the same cells.

Cells and conventions are those of em-team/results/offline-bf/score_lago.py:
  * actual y = SDAC (bin/da_target.py hourly_actuals, target="sdac") at UTC hour t;
  * D-1 naive n1 = y(t - 24 h); Lago weekly naive nw = y(t - 7 d) on Mon/Sat/Sun market days,
    y(t - 24 h) otherwise (weekday of the Athens market day);
  * a cell counts only where y, n1, nw and the cv44 record physics exist;
  * rMAE = MAE(model) / MAE(naive) on the same cells, against both naives.

Arms (whichever exist): lear, dnn (epftoolbox), a = Timestral alone, b = cv44 record physics,
c_rec = Timestral + record physics, c_wx = Timestral + weather physics (post-sim overlay).

Two cell sets: "common" (every present arm has a forecast) and "paired" (each arm with LEAR only).

  python score_sota.py --lear DIR [--dnn DIR] --tsfm DIR [--zones ...] --md OUT.md --json OUT.json
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd

BIN = Path(__file__).resolve().parents[3] / "bin"
sys.path.insert(0, str(BIN))
import da_target  # noqa: E402

ARMS = {"lear": "LEAR-Ens (epftoolbox, 4 windows)",
        "lear_gl": "LEAR-Ens gate-clean: load only", "lear_gr": "LEAR-Ens gate-clean: load + RES lag1",
        "dnn": "DNN-Ens (epftoolbox)",
        "a": "(a) Timestral alone", "b": "(b) cv44 RECORD physics",
        "c_rec": "(c) Timestral + RECORD physics", "c_wx": "(c) Timestral + WEATHER physics"}


def read_many(pattern, col, name, zones):
    fs = sorted(glob.glob(pattern))
    if not fs:
        return None
    x = pd.concat([pd.read_csv(f, usecols=["zone", "market_date", "t_utc", col]) for f in fs])
    x = x[x.zone.isin(zones)].drop_duplicates(["zone", "t_utc"])
    return pd.DataFrame({"zone": x.zone, "day": x.market_date, "t": pd.to_datetime(x.t_utc), name: x[col]})


def load(a, zones):
    R = a.tsfm
    arms = {"lear": read_many(f"{a.lear}/*.csv", "lear", "lear", zones),
            "lear_gl": read_many(f"{a.lear_gl}/*.csv", "lear", "lear_gl", zones) if a.lear_gl else None,
            "lear_gr": read_many(f"{a.lear_gr}/*.csv", "lear", "lear_gr", zones) if a.lear_gr else None,
            "dnn": read_many(f"{a.dnn}/*.csv", "dnn", "dnn", zones) if a.dnn else None,
            "a": read_many(f"{R}/pregate0630/*.csv", "tsfm_median", "a", zones),
            "c_rec": read_many(f"{R}/record/postsim/*.csv", "tsfm_median", "c_rec", zones),
            "c_wx": read_many(f"{R}/postsim/*.csv", "tsfm_median", "c_wx", zones)}
    import duckdb
    r = duckdb.connect(a.record, read_only=True).execute(
        "select bidding_zone as zone, date_time_utc as t, avg(price_eur_mwh) as b from simulations.energy_prices "
        "where resolution_code='1H' group by 1,2").df()
    r["t"] = pd.to_datetime(r.t)
    arms["b"] = r[r.zone.isin(zones)]
    return {k: v for k, v in arms.items() if v is not None and len(v)}


def cells(con, arms, start, end):
    base = arms["a"][["zone", "day", "t"]]
    base = base[(base.day >= start) & (base.day <= end)]
    act = da_target.hourly_actuals(con, base.t.min() - pd.Timedelta(days=8), base.t.max() + pd.Timedelta(hours=1),
                                   target="sdac")
    act = act.rename(columns={"z": "zone", "act": "y"})[["zone", "t", "y"]]
    act["t"] = pd.to_datetime(act.t)
    d = base.merge(act, on=["zone", "t"], how="left")
    for k, lag in (("n1", 1), ("n7", 7)):
        d = d.merge(act.assign(t=act.t + pd.Timedelta(days=lag)).rename(columns={"y": k}), on=["zone", "t"], how="left")
    wd = pd.to_datetime(d.day).dt.day_of_week
    d["nw"] = np.where(wd.isin([0, 5, 6]), d.n7, d.n1)
    for k, v in arms.items():
        d = d.merge(v[["zone", "t", k]], on=["zone", "t"], how="left")
    return d.dropna(subset=["y", "n1", "nw", "b"])


def stats(g, k):
    e = (g[k] - g.y).abs().mean()
    return {"rmae_d1": float(e / (g.n1 - g.y).abs().mean()), "rmae_week": float(e / (g.nw - g.y).abs().mean()),
            "mae": float(e), "bias": float((g[k] - g.y).mean()), "cells": int(len(g)), "days": int(g.day.nunique())}


def table(d, arms, title):
    out = {"pooled": {k: stats(d, k) for k in arms}}
    out["zone"] = {z: {k: stats(g, k) for k in arms} for z, g in d.groupby("zone")}
    md = [f"### {title}", "", "rMAE vs D-1 naive / vs Lago weekly naive", "",
          "| zone | cells | days | " + " | ".join(ARMS[k] for k in arms) + " |",
          "|---|---|---|" + "---|" * len(arms)]
    for key, s in [("**pooled**", out["pooled"])] + sorted(out["zone"].items()):
        first = next(iter(s.values()))
        md.append(f"| {key} | {first['cells']:,} | {first['days']} | "
                  + " | ".join(f"{s[k]['rmae_d1']:.3f} / {s[k]['rmae_week']:.3f}" for k in arms) + " |")
    return out, "\n".join(md) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lear", required=True)
    ap.add_argument("--lear-gl", help="gate-clean LEAR, load only (lear_run.py --exog load)")
    ap.add_argument("--lear-gr", help="gate-clean LEAR, load + RES lag1 (lear_run.py --exog load_res_lag1)")
    ap.add_argument("--dnn")
    ap.add_argument("--arms", nargs="+", help="arms of the common-cells table (default: all present)")
    ap.add_argument("--tsfm", default=os.path.expanduser("~/armada/em-team/results/tsfm-2y"))
    ap.add_argument("--record", default=os.path.expanduser("~/armada/em-team/results/record-cv44.duckdb"))
    ap.add_argument("--extract", default=os.path.expanduser("~/armada/em-data/euphemia-live-20261115.duckdb"))
    ap.add_argument("--zones", nargs="+")
    ap.add_argument("--start", default="2024-11-16"); ap.add_argument("--end", default="2026-11-15")
    ap.add_argument("--md"); ap.add_argument("--json")
    a = ap.parse_args()
    import duckdb
    con = duckdb.connect(a.extract, read_only=True)
    zones = a.zones or sorted({os.path.basename(f)[:-4] for f in glob.glob(f"{a.lear}/*.csv")})
    arms = load(a, zones)
    d = cells(con, arms, a.start, a.end)
    order = [k for k in ARMS if k in arms]
    res, md = {}, []
    if a.arms:
        order = [k for k in order if k in a.arms]
    common = d.dropna(subset=order)
    res["common"], m = table(common, order, f"Common cells: every arm present ({', '.join(order)})")
    md.append(m)
    res["paired"] = {}
    for k in order:
        if k == "lear":
            continue
        p = d.dropna(subset=["lear", k])
        res["paired"][k], m = table(p, ["lear", k], f"Paired: LEAR vs {ARMS[k]}")
        md.append(m)
    text = "\n".join(md)
    print(text)
    if a.md:
        Path(a.md).write_text(text)
    if a.json:
        Path(a.json).write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
