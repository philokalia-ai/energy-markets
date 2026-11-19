#!/usr/bin/env python3
"""epftoolbox DNN-Ens (Lago et al. 2021) on the tsfm backtest cells: lead 1, Athens market days, daily
recalibration, the mean of four DNNs. The four are the authors' published hyperparameter sets for a
market, shipped in epftoolbox's `examples/experimental_files`:
DNN_hyperparameters_nl2_dat<M>_YT2_<SF|SF_SF>[_DA]_CW4_1, i.e. shuffle_train in {1, 2} x
data_augmentation in {0, 1}, 2 hidden layers, 4-year calibration window.

Published sets exist for DE, FR, BE (and NP, PJM). Zone -> set: DE_LU -> DE, FR -> FR, BE -> BE;
NL and AT have none, so they use DE's (the neighbouring, interconnected market with the same
exogenous inputs: load + wind/solar forecast). No hyperparameter search is run here.

Model code is epftoolbox's own `DNN.recalibrate_and_forecast_next_day`; the input frame is the one
`lear_run.py` builds (epf_data.zone_frame; paper inputs: load 6.1.B + wind/solar 14.1.D for D, see the
14.1.D gate caveat there). The calibration window (4 x 364 days) is capped by the extract's history
(2022-12-01).

Keras: epftoolbox's DNN is written for Keras 2 (`batch_input_shape`, ...). It runs unchanged on the
tf-keras package (Keras 2 for TF 2.x, same version as TF) via TF_USE_LEGACY_KERAS=1.

Cost (measured, 1 core per process): ~80 s per day for a plain DNN, ~540 s with data augmentation
(24x the training rows), ~0.9 GB RSS. Scheduling: the 730 days are walked in one seeded random order,
cut into BLOCKS blocks; a task is (zone, DNN, block) for the augmented DNNs and (zone, DNN, 6 blocks)
for the plain ones (~1-2 h each), queued block by block, so at any time the finished days are a uniform
sample of the window with all four DNNs present. Each task appends to its own
<out>/parts/<zone>__<cfg>__b<k>.csv (resumable); `--merge` writes <out>/<zone>.csv (dnn = mean of the
four, only for cells all four have).

  python dnn_run.py --zones DE_LU FR BE NL AT --frames DIR/lear/frames --out DIR/dnn --procs 20 --threads 2
"""
from __future__ import annotations

import argparse
import os
import sys
import time
import warnings
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import epf_data  # noqa: E402

HYPER_SET = {"DE_LU": "DE", "FR": "FR", "BE": "BE", "NL": "DE", "AT": "DE"}
CFGS = {"sf1": (1, 0), "sf1_da": (1, 1), "sf2": (2, 0), "sf2_da": (2, 1)}   # (shuffle_train, data_augmentation)
BLOCKS, PLAIN_GROUP = 60, 6


def run_task(zone, cfg, days, part, a):
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
    os.environ["TF_USE_LEGACY_KERAS"] = "1"   # epftoolbox's DNN is Keras-2 code: tensorflow.keras -> tf_keras
    import tensorflow as tf
    tf.config.threading.set_intra_op_parallelism_threads(a.threads)
    tf.config.threading.set_inter_op_parallelism_threads(1)
    from epftoolbox.models import DNN
    warnings.filterwarnings("ignore")
    sf, da = CFGS[cfg]
    out = Path(a.out) / "parts" / f"{zone}__{cfg}__{part}.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    done = set(pd.read_csv(out, usecols=["market_date"]).market_date) if out.exists() else set()
    df = pd.read_parquet(Path(a.frames) / f"{zone}.parquet")
    model = DNN(experiment_id=1, path_hyperparameter_folder=a.hyper_dir, nlayers=2, dataset=HYPER_SET[zone],
                years_test=2, shuffle_train=sf, data_augmentation=da, calibration_window=4)
    print(f"{zone} {cfg} {part}: set {HYPER_SET[zone]}, {len(done)}/{len(days)} days done", flush=True)
    for d in days:
        if d in done:
            continue
        t0 = time.time()
        D = pd.Timestamp(d)
        x = df.loc[:D + pd.Timedelta(hours=23)].copy()
        x.loc[D:, "Price"] = np.nan                       # day D's price is not known at the gate
        fc = np.asarray(model.recalibrate_and_forecast_next_day(df=x, next_day_date=D)).ravel()
        rows = epf_data.market_day_cells(d).assign(zone=zone, market_date=d, cfg=cfg)
        rows["dnn"] = fc[rows.hour.values]
        rows = rows[["zone", "market_date", "t_utc", "hour", "cfg", "dnn"]]
        rows.to_csv(out, mode="a", header=not out.exists(), index=False)
        print(f"{zone} {cfg} {d} done {time.time() - t0:.1f}s", flush=True)


def merge(a):
    for z in a.zones:
        parts = sorted((Path(a.out) / "parts").glob(f"{z}__*.csv"))
        if not parts:
            print(f"{z}: no parts, skipped")
            continue
        x = pd.concat([pd.read_csv(p) for p in parts]).drop_duplicates(["t_utc", "cfg"])
        w = x.pivot_table(index=["zone", "market_date", "t_utc", "hour"], columns="cfg", values="dnn").dropna()
        w.columns = [f"dnn_{c}" for c in w.columns]
        w["dnn"] = w.mean(axis=1)
        w.reset_index().to_csv(Path(a.out) / f"{z}.csv", index=False)
        print(f"{z}: {w.reset_index().market_date.nunique()} days with all four DNNs")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zones", nargs="+", required=True)
    ap.add_argument("--cfgs", nargs="+", default=list(CFGS), choices=list(CFGS))
    ap.add_argument("--start", default="2024-11-16")
    ap.add_argument("--end", default="2026-11-15")
    ap.add_argument("--frames", required=True, help="the parquet frames lear_run.py wrote (<lear out>/frames)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=431)
    ap.add_argument("--hyper-dir", default=os.path.expanduser("~/armada/em-team/src/epftoolbox/examples/experimental_files"),
                    help="epftoolbox's examples/experimental_files (the published trials)")
    ap.add_argument("--procs", type=int, default=1, help="(zone, DNN) tasks in parallel")
    ap.add_argument("--threads", type=int, default=2, help="TF intra-op threads per task")
    ap.add_argument("--merge", action="store_true", help="only merge the parts into <out>/<zone>.csv")
    a = ap.parse_args()
    if a.merge:
        return merge(a)
    days = [d.date().isoformat() for d in pd.date_range(a.start, a.end, freq="D")]
    days = [str(d) for d in np.random.default_rng(a.seed).permutation(days)]
    blocks = np.array_split(np.array(days, dtype=object), BLOCKS)
    tasks = []
    for b in range(BLOCKS):                   # block by block: all four DNNs finish the same days together
        for z in a.zones:
            for c in a.cfgs:
                if CFGS[c][1]:
                    tasks.append((z, c, list(blocks[b]), f"b{b:02d}", a))
                elif b % PLAIN_GROUP == 0:
                    tasks.append((z, c, [d for k in range(b, b + PLAIN_GROUP) for d in blocks[k]], f"g{b:02d}", a))
    if a.procs == 1:
        for t in tasks:
            run_task(*t)
        return
    import multiprocessing as mp
    with mp.get_context("spawn").Pool(a.procs, maxtasksperchild=1) as pool:
        for r in [pool.apply_async(run_task, t) for t in tasks]:
            try:
                r.get()
            except Exception as e:   # one task failing does not stop the others
                print(f"TASK FAILED {type(e).__name__}: {e}", flush=True)


if __name__ == "__main__":
    main()
