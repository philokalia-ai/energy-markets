#!/usr/bin/env python3
"""2-year Timestral backtest runner (offline, read-only extract, no DB writes).

Produces the lead-1 Timestral-209M forecasts of every Athens market day in [--start, --end] with the
production code path (`bin/emit_tsfm_overlay.py`: `overlay`, `build_context`, `sim_known`,
`sim_covariate`, CTX_HOURS = 8192, the pinned Hub revision):

  --mode pregate0630  (a) Timestral alone: settled prices strictly before the Athens day D
                          (issue D-1 06:30 UTC), as the 06:30 daily-forecast job publishes it.
  --mode postsim      (c) Timestral + physics as it runs live (bin/emit_tsfm_refresh.sh): the same
                          context plus the lead-1 weather-track physics as a known-future covariate,
                          60 days of sim history, only sim vintages made at or before the D-1 gate.

The physics for (c) is the offline cv44 weather-track backfill (one CSV per market day:
zone,time,price over the market-day hours in UTC; `--phys-dir`). Each day's file stands in for the
lead-1 sim of that day made at its natural instant D-1 06:30 UTC, so `sim_known` sees D's sim and
the previous days' sims only, exactly as live. A day whose physics file is missing is skipped
(re-run once it lands). Duplicate files of one day (several labels) resolve to the first in sorted
order, as the physics scorer (`offline-bf/score.py`) does.

Price context: `prices_duckdb`'s frame (EUPHEMIA_DA_INPUT, default highest_seq), loaded once for the
whole range and cut per day by `build_context` (strictly before the start of D).

Resumable: one CSV per (mode, day) in --out/<mode>/<day>.csv, written atomically; done days skip.
Parallel: --workers processes x --threads torch threads, each pinned by the caller (taskset).

  taskset -c 72-79 python run_tsfm.py --mode pregate0630 --workers 2 --threads 4 --out RESULTS
"""
from __future__ import annotations

import argparse
import glob
import multiprocessing as mp
import os
import re
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

BIN = Path(__file__).resolve().parents[3] / "bin"
sys.path.insert(0, str(BIN))
import emit_tsfm_overlay as eto  # noqa: E402
from collapse_probability import ZONES  # noqa: E402

SIM_HISTORY_DAYS = 60          # sim_from_db(days=60) in the live post-sim run
SIM_MADE_OFFSET = pd.Timedelta(hours=-17, minutes=-30)  # D-1 06:30 UTC relative to D 00:00 UTC (naive)


def physics_files(phys_dir):
    """{market day: csv path} — first file per day in sorted order (the scorer's dedupe)."""
    out = {}
    for f in sorted(glob.glob(f"{phys_dir}/*-20*.csv")):
        if f.endswith("-utc.csv"):
            continue
        m = re.search(r"(20\d\d-\d\d-\d\d)\.csv$", f)
        if m:
            out.setdefault(m.group(1), f)
    return out


def physics_sim(files, delivery, days=SIM_HISTORY_DAYS):
    """(zone, t, sim, made) rows of the physics days in [D - days, D], made = day's D-1 06:30 UTC."""
    d = pd.Timestamp(delivery).normalize()
    rows = []
    for k in range(days, -1, -1):
        day = d - pd.Timedelta(days=k)
        f = files.get(day.date().isoformat())
        if f is None:
            continue
        x = pd.read_csv(f)
        x = x.assign(t=pd.to_datetime(x.time), sim=x.price.astype(float),
                     made=day + SIM_MADE_OFFSET)[["zone", "t", "sim", "made"]]
        rows.append(x.drop_duplicates(["zone", "t"]))
    return pd.concat(rows, ignore_index=True) if rows else pd.DataFrame(columns=["zone", "t", "sim", "made"])


def claim(f: Path) -> bool:
    """Claim day file `f` for this process (several runner instances may share --out).

    A claim is `<day>.lock` holding the owner's host:pid, created exclusively; a lock whose pid is
    gone (killed run) is taken over."""
    lock = f.with_suffix(".lock")
    me = f"{os.uname().nodename}:{os.getpid()}"
    for _ in range(2):
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, me.encode()); os.close(fd)
            return True
        except FileExistsError:
            try:
                host, pid = lock.read_text().split(":")
                if host == os.uname().nodename and not Path(f"/proc/{pid}").exists():
                    lock.unlink(missing_ok=True)      # stale: its owner is dead
                    continue
            except (OSError, ValueError):
                pass
            return False
    return False


def worker(args):
    days, a = args
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    con = eto.open_store("duckdb", a.extract)
    # one price frame for all of this worker's days; build_context cuts it strictly before each D
    first, last = min(days), max(days)
    span = eto.day_start_utc(last) - eto.day_start_utc(first)
    prices = eto.prices_duckdb(con, last, ctx_hours=eto.CTX_HOURS + int(span / pd.Timedelta(hours=1)))
    con.close()
    model = eto.ARMS["timestral-209m"](a.threads)
    files = physics_files(a.phys_dir) if a.mode == "postsim" else {}
    outdir = Path(a.out) / a.mode
    for d in days:
        f = outdir / f"{d}.csv"
        if f.exists() or not claim(f):
            continue
        sim = None
        if a.mode == "postsim":
            if d not in files:
                print(f"{d} skip: no physics", flush=True)
                f.with_suffix(".lock").unlink(missing_ok=True)
                continue
            sim = physics_sim(files, d)
        t0 = time.time()
        try:
            hourly, _ = eto.overlay(model, prices, ZONES, d, a.mode, sim)
        except Exception as e:  # one day never stops the run; it is reported and retried next run
            print(f"{d} FAILED {type(e).__name__}: {e}", flush=True)
            f.with_suffix(".lock").unlink(missing_ok=True)
            continue
        cols = ["zone", "market_date", "t_utc", "issue_utc", "input_mode", "context_end_utc",
                "sim_made_utc", "after_gate", "tsfm_median", "tsfm_q10", "tsfm_q90", "p_le0_tsfm"]
        tmp = f.with_suffix(".tmp")
        hourly[cols].to_csv(tmp, index=False)
        tmp.rename(f)
        f.with_suffix(".lock").unlink(missing_ok=True)
        print(f"{d} done {time.time() - t0:.1f}s", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", choices=["pregate0630", "postsim"], required=True)
    ap.add_argument("--start", default="2024-11-16")
    ap.add_argument("--end", default="2026-11-15")
    ap.add_argument("--extract", default=os.environ.get("EUPHEMIA_DUCKDB_PATH"))
    ap.add_argument("--phys-dir", default=os.path.expanduser("~/armada/em-team/results/offline-bf/out"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--workers", type=int, default=1)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--seed", type=int, default=431)
    a = ap.parse_args()
    if not a.extract:
        raise SystemExit("--extract or EUPHEMIA_DUCKDB_PATH")
    days = [d.date().isoformat() for d in pd.date_range(a.start, a.end, freq="D")]
    # shuffled order: partial results cover the whole period evenly
    order = list(np.random.default_rng(a.seed).permutation(days))
    (Path(a.out) / a.mode).mkdir(parents=True, exist_ok=True)
    chunks = [order[w::a.workers] for w in range(a.workers)]
    if a.workers == 1:
        worker((chunks[0], a))
        return
    with mp.get_context("spawn").Pool(a.workers) as pool:
        pool.map(worker, [(c, a) for c in chunks])


if __name__ == "__main__":
    main()
