#!/usr/bin/env python3
"""Score the 2-year backtest: (a) Timestral alone, (b) cv44 physics (weather track), (c) Timestral +
physics as live (post-sim overlay). Lead 1, SDAC target, D-1 naive. Offline, read-only extract.

Conventions (identical to the physics scorer em-team/results/offline-bf/score.py, so (b) here
reproduces its numbers):
  * actual  = bin/da_target.py hourly_actuals(target="sdac") at the UTC hour t;
  * naive   = the same series at t - 24 h (D-1 same hour; known at the D-1 issue);
  * a cell counts only where actual and naive are finite;
  * MAE / bias = means over cells; rMAE = MAE(model) / MAE(naive) on the SAME cells (ratio of means).
Cell sets:
  own     each arm on all its own cells;
  common  the cells where every arm present in the table has a forecast (the paired comparison;
          (c) and (b) are then on exactly the same hours, (a) too).
Breakdowns: pooled, by month (Athens market day), by region, by zone, before/after the Timestral
release (2026-10-15) and the cv44 freeze (2026-11-15).

  python score_2y.py --tsfm RESULTS_DIR [--phys-dir DIR] [--json OUT.json] [--md OUT.md]
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

HERE = Path(__file__).resolve().parent
BIN = HERE.parents[2] / "bin"
sys.path.insert(0, str(BIN))
sys.path.insert(0, str(HERE))
import da_target  # noqa: E402
from run_tsfm import physics_files  # noqa: E402

REGIONS = {
    "Central-West": ["AT", "BE", "CH", "CZ", "DE_LU", "FR", "NL", "PL", "SK"],
    "Iberia": ["ES", "PT"],
    "Italy": ["IT-CNORTH", "IT-CSOUTH", "IT-Calabria", "IT-NORTH", "IT-SOUTH", "IT-Sardinia", "IT-Sicily"],
    "Nordic": ["DK1", "DK2", "FI", "NO1", "NO2", "NO3", "NO4", "NO5", "SE1", "SE2", "SE3", "SE4"],
    "Baltic": ["EE", "LT", "LV"],
    "SEE": ["BG", "GR", "HR", "HU", "RO", "RS", "SI"],
}
ZONE_REGION = {z: r for r, zs in REGIONS.items() for z in zs}
TIMESTRAL_RELEASE = "2026-10-15"
CV44_FREEZE = "2026-11-15"
ARMS = {"a": "Timestral alone (pre-gate 06:30, prices only)",
        "b": "cv44 physics (weather track)",
        "c": "Timestral + physics, as live (post-sim overlay)"}


def load_tsfm(d, mode):
    fs = sorted(glob.glob(f"{d}/{mode}/20*.csv"))
    if not fs:
        return pd.DataFrame(columns=["zone", "t", "day", "f"])
    x = pd.concat([pd.read_csv(f, usecols=["zone", "market_date", "t_utc", "tsfm_median"]) for f in fs])
    return pd.DataFrame({"zone": x.zone, "t": pd.to_datetime(x.t_utc), "day": x.market_date, "f": x.tsfm_median})


def load_phys(phys_dir):
    rows = []
    for day, f in physics_files(phys_dir).items():
        x = pd.read_csv(f).drop_duplicates(["zone", "time"])
        rows.append(pd.DataFrame({"zone": x.zone, "t": pd.to_datetime(x.time), "day": day, "f": x.price.astype(float)}))
    return pd.concat(rows, ignore_index=True) if rows else pd.DataFrame(columns=["zone", "t", "day", "f"])


def attach_actuals(con, frames):
    allt = pd.concat([f.t for f in frames.values() if len(f)])
    act = da_target.hourly_actuals(con, allt.min() - pd.Timedelta(days=2), allt.max() + pd.Timedelta(hours=1),
                                   target="sdac")
    a = act.rename(columns={"z": "zone", "act": "actual"})[["zone", "t", "actual"]]
    a["t"] = pd.to_datetime(a.t)
    n = a.assign(t=a.t + pd.Timedelta(days=1)).rename(columns={"actual": "naive"})
    out = {}
    for k, f in frames.items():
        g = f.merge(a, on=["zone", "t"], how="left").merge(n, on=["zone", "t"], how="left")
        out[k] = g[np.isfinite(g.actual) & np.isfinite(g.naive) & np.isfinite(g.f)].copy()
    return out


def summarize(g):
    if len(g) == 0:
        return None
    e = (g.f - g.actual).abs()
    en = (g.naive - g.actual).abs()
    return {"cells": int(len(g)), "days": int(g.day.nunique()), "zones": int(g.zone.nunique()),
            "mae": float(e.mean()), "naive_mae": float(en.mean()), "rmae": float(e.mean() / en.mean()),
            "bias": float((g.f - g.actual).mean())}


def breakdowns(g):
    g = g.assign(month=g.day.str[:7], region=g.zone.map(ZONE_REGION).fillna("other"),
                 period=np.where(g.day >= CV44_FREEZE, "after cv44 freeze",
                                 np.where(g.day >= TIMESTRAL_RELEASE, "after Timestral release",
                                          "before Timestral release")))
    return {"pooled": summarize(g),
            "month": {k: summarize(x) for k, x in g.groupby("month")},
            "region": {k: summarize(x) for k, x in g.groupby("region")},
            "zone": {k: summarize(x) for k, x in g.groupby("zone")},
            "period": {k: summarize(x) for k, x in g.groupby("period")}}


def score(frames):
    present = [k for k, f in frames.items() if len(f)]
    res = {"own": {k: breakdowns(frames[k]) for k in present}}
    if len(present) > 1:
        key = ["zone", "t"]
        common = None
        for k in present:
            s = frames[k][key + ["day"]]
            common = s if common is None else common.merge(s, on=key + ["day"])
        res["common_arms"] = present
        res["common"] = {k: breakdowns(frames[k].merge(common, on=key + ["day"])) for k in present}
    return res


def fmt(s):
    return "—" if s is None else f"{s['rmae']:.3f} | {s['mae']:.1f} | {s['bias']:+.1f} | {s['naive_mae']:.1f} | {s['cells']:,} | {s['days']}"


def to_md(res):
    out = []
    for cs in ("common", "own"):
        if cs not in res:
            continue
        arms = list(res[cs])
        title = ("Common cells (every arm present: " + ", ".join(res["common_arms"]) + ")") if cs == "common" \
            else "Each arm on its own cells"
        out.append(f"### {title}\n")
        for part in ("pooled", "period", "region", "month"):
            out.append(f"**{part}** — rMAE | MAE | bias | naive MAE | cells | days\n")
            out.append("| " + " | ".join(["slice"] + [f"({k}) {ARMS[k].split(' (')[0]}" for k in arms]) + " |")
            out.append("|" + "---|" * (len(arms) + 1))
            keys = ["all"] if part == "pooled" else sorted({x for k in arms for x in res[cs][k][part]})
            for key in keys:
                cells = [fmt(res[cs][k]["pooled"] if part == "pooled" else res[cs][k][part].get(key)) for k in arms]
                out.append(f"| {key} | " + " | ".join(cells) + " |")
            out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tsfm", required=True)
    ap.add_argument("--phys-dir", default=os.path.expanduser("~/armada/em-team/results/offline-bf/out"))
    ap.add_argument("--extract", default=os.environ.get("EUPHEMIA_DUCKDB_PATH",
                    os.path.expanduser("~/armada/em-data/euphemia-live-20261115.duckdb")))
    ap.add_argument("--json"); ap.add_argument("--md")
    a = ap.parse_args()
    import duckdb
    con = duckdb.connect(a.extract, read_only=True)
    frames = {"a": load_tsfm(a.tsfm, "pregate0630"), "b": load_phys(a.phys_dir), "c": load_tsfm(a.tsfm, "postsim")}
    frames = attach_actuals(con, {k: f for k, f in frames.items() if len(f)})
    res = score(frames)
    md = to_md(res)
    print(md)
    if a.json:
        Path(a.json).write_text(json.dumps(res, indent=1))
    if a.md:
        Path(a.md).write_text(md)


if __name__ == "__main__":
    main()
