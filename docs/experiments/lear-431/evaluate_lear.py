"""Score the LEAR pilot through the #431 benchmark contract (collapse's benchmark-431/evaluate.py).

The evaluator is imported by path (`BENCH_EVAL`); nothing in production is imported. Target:
SDAC hourly actuals from `lear.py prices`. Market day: Europe/Athens. Naives d1/d7/epf come from
the evaluator; rMAE is the ratio of matched aggregate MAEs.

Windows:
  test       2024-07-01..2026-11-13  the whole locked test period
  emz        2024-07-01..2025-01-14  the overlap with El Mahtout & Ziel's test (sanity band:
                                     DE_LU rMAE vs the epf naive ~ 0.4-0.6)
  record     2024-07-01..2026-06-30
  rolling    2025-07-01..2026-06-30  the rolling-origin GBM window (LEAR only; see README)
  live       2026-09-14..2026-11-13  LEAR vs the live lead-1 weather physics, gbm and stats rows,
                                     and the Timestral backtest arms, on the intersection of cells

Usage: python evaluate_lear.py --out DIR --live LIVE_SNAPSHOT_DIR --tsfm TSFM_OUT
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path

import numpy as np
import pandas as pd

BENCH_EVAL = os.environ.get(
    "BENCH_EVAL", "/home/pgeorgakopoulos/armada/em-team/worktrees/collapse-431/docs/experiments/benchmark-431/evaluate.py")
ZONES = ["DE_LU", "GR"]
WINDOWS = {"test": ("2024-07-01", "2026-11-13"), "emz": ("2024-07-01", "2025-01-14"),
           "record": ("2024-07-01", "2026-06-30"), "rolling": ("2025-07-01", "2026-06-30"),
           "live": ("2026-09-14", "2026-11-13")}


def load_bench():
    spec = importlib.util.spec_from_file_location("bench431", BENCH_EVAL)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def live_rows(live_dir, zones=ZONES):
    """Lead-1 weather-track rows (sim, gbm, stats) from the public zone JSON snapshot.

    One row per (zone, hour): if a market day has several lead-1 weather rows, the latest
    prediction_made_utc is kept and the count is reported."""
    rows, dup_days = [], 0
    for z in zones:
        js = json.loads(Path(live_dir, f"{z}.json").read_text())
        days = [d for d in js["days"] if d["lead_days"] == 1 and d["input_mode"] == "weather"]
        by = {}
        for d in days:
            if d["date"] in by:
                dup_days += 1
                if d["prediction_made_utc"] <= by[d["date"]]["prediction_made_utc"]:
                    continue
            by[d["date"]] = d
        for d in by.values():
            for i, h in enumerate(d["hours"]):
                for model in ("sim", "gbm", "stats"):
                    v = (d.get(model) or [None] * len(d["hours"]))[i]
                    rows.append(dict(zone=z, t=pd.Timestamp(h).tz_localize(None), model=f"live_{model}",
                                     prediction=v, lead=1, issue_utc=pd.Timestamp(d["prediction_made_utc"]).tz_localize(None),
                                     code_version=d["code_version"]))
    df = pd.DataFrame(rows).dropna(subset=["prediction"])
    return df, dup_days


def tsfm_rows(tsfm_out, zones=ZONES):
    out = []
    for fn, name in (("fc_t209_uni_L1", "tsfm_t209_uni"), ("fc_t209_sim_L1", "tsfm_t209_sim")):
        f = pd.read_parquet(f"{tsfm_out}/{fn}.parquet")
        f = f[f.zone.isin(zones)]
        out.append(pd.DataFrame({"zone": f.zone, "t": f.t, "model": name, "prediction": f["median"],
                                 "lead": 1, "issue_utc": f.issued_utc}))
    return pd.concat(out, ignore_index=True)


def pick(metrics, group, naive, coverage="all_paired_cells", aggregation="pooled_cell", family=None):
    m = metrics[(metrics.group == group) & (metrics.naive == naive) & (metrics.coverage == coverage)
                & (metrics.aggregation == aggregation)]
    return m if family is None else m[m.mask_family == family]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--live", required=True)
    ap.add_argument("--tsfm", required=True)
    ap.add_argument("--tag", default="test")
    a = ap.parse_args()
    bench = load_bench()
    act = pd.read_parquet(f"{a.out}/sdac_hourly.parquet").rename(columns={"price": "actual"})[["zone", "t", "actual"]]
    lear = pd.read_parquet(f"{a.out}/lear_forecasts_{a.tag}.parquet")[["zone", "t", "model", "prediction", "lead", "issue_utc"]]
    live, dup = live_rows(a.live)
    tsfm = tsfm_rows(a.tsfm)
    print(f"evaluator {BENCH_EVAL} ({bench.VERSION}); live lead-1 weather days with >1 row: {dup}")
    res = {}
    pd.set_option("display.width", 250, "display.max_columns", 30)
    cols = ["window", "model", "group", "naive", "mask_family", "n", "n_zone_days", "mae", "bias", "naive_mae", "rmae",
            "mean_price", "share_le_zero"]
    allm, alld = [], []
    for w, (s, e) in WINDOWS.items():
        runs = [("lear", lear, False)]
        if w == "live":
            runs = [("live_core", pd.concat([lear, live[live.model == "live_sim"], tsfm]), True),
                    ("live_gbm", pd.concat([lear, live[live.model == "live_gbm"]]), True),
                    ("live_stats", pd.concat([lear, live[live.model == "live_stats"]]), True)]
        for run, fc, inter in runs:
            t = bench.evaluate(act, fc, start=s, end=e, zones=ZONES, timezone="Europe/Athens", intersection=inter)
            fam = "all_models" if inter else "pairwise"
            mt = t["metrics"].assign(window=w, run=run)
            mt = mt[mt.mask_family == fam]
            dm = t["dm"].assign(window=w, run=run)
            dm = dm[dm.mask_family == fam]
            allm.append(mt); alld.append(dm)
    M, D = pd.concat(allm), pd.concat(alld)
    M.to_csv(f"{a.out}/bench_metrics.csv", index=False)
    D.to_csv(f"{a.out}/bench_dm.csv", index=False)
    show = M[(M.coverage == "all_paired_cells") & (M.aggregation == "pooled_cell")]
    for w in WINDOWS:
        x = show[show.window == w]
        print(f"\n== {w} {WINDOWS[w]} (pooled cells; rmae = MAE / naive MAE on the same cells)")
        print(x.pivot_table(index=["run", "model", "group"], columns="naive", values="rmae").round(3).to_string())
        print(x[x.naive == "epf"][["run", "model", "group", "n", "n_zone_days", "mae", "bias", "naive_mae", "mean_price",
                                   "share_le_zero", "mask_sha256"]].round(3).to_string(index=False))
    dd = D[["window", "run", "model", "group", "naive", "n_days", "status", "statistic", "p_model_better",
            "dst_or_incomplete_days"]]
    print("\n== DM (daily 24-h vectors, L1, one-sided: model better than naive)")
    print(dd.round(4).to_string(index=False))


if __name__ == "__main__":
    main()
