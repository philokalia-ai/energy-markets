#!/usr/bin/env python3
"""epftoolbox LEAR (Lago et al. 2021) on the tsfm backtest cells: lead 1, Athens market days, daily
recalibration, ensemble of the four calibration windows 56/84/1092/1456 days (the paper's LEAR-Ens:
the mean of the four).

Model code is epftoolbox's own `LEAR.recalibrate_and_forecast_next_day`; the one change is the
AIC noise variance of the paper's scikit-learn (see paper_lear). This file only
builds its input frame (epf_data.py) and maps the 24 wall-clock forecasts back onto our UTC cells.

Ex-ante: for day D the frame holds prices up to the end of D-1 (D's price masked) and the ENTSO-E
day-ahead load and wind+solar forecasts up to the end of D, all known at the D-1 gate.

Data limit: the extract starts 2022-12-01, so a window longer than the available history uses all of
it (1456 always; 1092 until ~2025-12). The output records the days each window actually used.

One process per zone (single-threaded BLAS), resumable: <out>/<zone>.csv gains one block of rows per
finished day; done days are skipped on restart.

  OMP_NUM_THREADS=1 python lear_run.py --zones DE_LU FR --out DIR [--start ... --end ...]
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

WINDOWS = (56, 84, 1092, 1456)


def paper_lear():
    """epftoolbox's LEAR with one change: LassoLarsIC gets noise_variance = var(y), the AIC of the
    scikit-learn the paper ran on (< 1.1: criterion = RSS / var(y) + 2 df). scikit-learn >= 1.1
    estimates the noise variance by OLS instead and refuses n_samples <= n_features, i.e. the 56- and
    84-day windows (49/77 days vs 247 features). The new criterion with that variance differs from the
    old one by a constant, so the selected lambda is the paper's."""
    import types
    import epftoolbox
    if "epftoolbox.models" not in sys.modules:   # skip models/__init__ (it imports the DNN -> TensorFlow)
        pkg = types.ModuleType("epftoolbox.models")
        pkg.__path__ = [os.path.join(os.path.dirname(epftoolbox.__file__), "models")]
        sys.modules["epftoolbox.models"] = pkg
    from epftoolbox.models._lear import LEAR
    from epftoolbox.data import scaling
    from sklearn.linear_model import Lasso, LassoLarsIC

    class PaperLEAR(LEAR):
        def recalibrate(self, Xtrain, Ytrain):
            [Ytrain], self.scalerY = scaling([Ytrain], 'Invariant')
            [Xtrain_no_dummies], self.scalerX = scaling([Xtrain[:, :-7]], 'Invariant')
            Xtrain[:, :-7] = Xtrain_no_dummies
            self.models = {}
            for h in range(24):
                y = Ytrain[:, h]
                param = LassoLarsIC(criterion='aic', max_iter=2500,
                                    noise_variance=float(np.var(y))).fit(Xtrain, y).alpha_
                self.models[h] = Lasso(max_iter=2500, alpha=param).fit(Xtrain, y)

        def predict(self, X):
            # epftoolbox's predict, with the 1-element prediction taken as a scalar (current NumPy
            # refuses to assign a size-1 array into a scalar slot); identical arithmetic
            X = X.copy()
            X[:, :-7] = self.scalerX.transform(X[:, :-7])
            Yp = np.array([float(self.models[h].predict(X)[0]) for h in range(24)])
            return self.scalerY.inverse_transform(Yp.reshape(1, -1))
    return PaperLEAR


def run_zone(zone, a):
    LEAR = paper_lear()
    warnings.filterwarnings("ignore")
    out = Path(a.out) / f"{zone}.csv"
    done = set(pd.read_csv(out, usecols=["market_date"]).market_date) if out.exists() else set()
    df = pd.read_parquet(Path(a.out) / "frames" / f"{zone}.parquet")
    print(f"{zone}: frame {df.index[0]} .. {df.index[-1]}, {len(done)} days already done", flush=True)
    days = [d.date().isoformat() for d in pd.date_range(a.start, a.end, freq="D")]
    days = list(np.random.default_rng(a.seed).permutation(days))
    models = {w: LEAR(calibration_window=w) for w in WINDOWS}
    for d in days:
        if d in done:
            continue
        t0 = time.time()
        D = pd.Timestamp(d)
        x = df.loc[:D + pd.Timedelta(hours=23)].copy()
        x.loc[D:, "Price"] = np.nan                       # day D's price is not known at the gate
        avail = (D - x.index[0]).days
        fc = {}
        for w in WINDOWS:
            fc[w] = np.asarray(models[w].recalibrate_and_forecast_next_day(
                df=x, calibration_window=w, next_day_date=D)).ravel()
        cells = epf_data.market_day_cells(d)
        rows = cells.assign(zone=zone, market_date=d)
        for w in WINDOWS:
            rows[f"lear_{w}"] = fc[w][rows.hour.values]
            rows[f"days_{w}"] = min(w, avail)
        rows["lear"] = rows[[f"lear_{w}" for w in WINDOWS]].mean(axis=1)
        rows = rows[["zone", "market_date", "t_utc", "hour", "lear"] + [f"lear_{w}" for w in WINDOWS]
                    + [f"days_{w}" for w in WINDOWS]]
        rows.to_csv(out, mode="a", header=not out.exists(), index=False)
        print(f"{zone} {d} done {time.time() - t0:.1f}s", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zones", nargs="+", required=True)
    ap.add_argument("--start", default="2024-11-16")
    ap.add_argument("--end", default="2026-11-15")
    ap.add_argument("--extract", default=os.environ.get("EUPHEMIA_DUCKDB_PATH",
                    os.path.expanduser("~/armada/em-data/euphemia-live-20261115.duckdb")))
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=431)
    ap.add_argument("--procs", type=int, default=1, help="zones run in parallel (one process each)")
    a = ap.parse_args()
    fdir = Path(a.out) / "frames"
    fdir.mkdir(parents=True, exist_ok=True)
    import duckdb
    con = duckdb.connect(a.extract, read_only=True)
    for z in a.zones:                       # one DuckDB pass in the parent; workers read a parquet
        if not (fdir / f"{z}.parquet").exists():
            df, filled = epf_data.zone_frame(con, z, a.end)
            df.to_parquet(fdir / f"{z}.parquet")
            print(f"{z}: frame {df.index[0]} .. {df.index[-1]}, ex-ante filled hours {filled}", flush=True)
            with open(fdir / "filled.csv", "a") as fh:
                fh.write(f"{z},{filled['Price']},{filled['Exogenous 1']},{filled['Exogenous 2']}\n")
    con.close()
    if a.procs == 1:
        for z in a.zones:
            run_zone(z, a)
        return
    import multiprocessing as mp
    with mp.get_context("spawn").Pool(a.procs, maxtasksperchild=1) as pool:
        pool.starmap(run_zone, [(z, a) for z in a.zones], chunksize=1)


if __name__ == "__main__":
    main()
