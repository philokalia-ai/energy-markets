#!/usr/bin/env python3
"""Round 2: st-impact's robust stepped curves (research/strategy/impact/robust.py, unchanged) re-run on the 96-step
baselines. The curves are hourly (as in round 1), built from the HOURLY MEAN of our 96-step forecast; the calibration
error paths are recomputed from the 96-step baselines of the calibration days. Evaluation + replication days.
usage: python -I robust96.py  -> runs/st-blocks/r2/robust96.csv  (writes hourly-mean copies to runs/st-blocks/r2/base96h)
"""
import sys
from multiprocessing import Pool
from pathlib import Path
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "impact"))
import market_view as MV  # noqa: E402

ROOT = MV.ROOT
B96 = ROOT / "runs/baseline96"
OUT = ROOT / "runs/st-blocks/r2"
H = OUT / "base96h"


def hourly_copy(day):
    f = H / f"{day}.prices.csv"
    if f.exists():
        return True
    src = B96 / f"{day}.prices.csv"
    if not src.exists():
        return False
    p = pd.read_csv(src)
    p.groupby(["zone", "hour_utc"], as_index=False).price.mean().to_csv(f, index=False)
    return True


if __name__ == "__main__":
    H.mkdir(parents=True, exist_ok=True)
    days = {k: (ROOT / f"days_{k}.txt").read_text().split() for k in ("cal", "eval", "rep")}
    missing = [d for k in days for d in days[k] if not hourly_copy(d)]
    assert not missing, f"no 96-step baseline for {missing}"
    MV.BASE = H                      # robust.job reads MV.BASE at call time
    import robust as RB              # noqa: E402  (CAL = days_cal.txt, as in round 1)
    real = RB.ST.realised_table()
    jobs = [(d, z, "bat", real, False) for k in ("eval", "rep") for d in days[k] for z in RB.BAT_ZONES] + \
           [(d, z, "hyd", real, False) for k in ("eval", "rep") for d in days[k] for z in RB.HYD_ZONES]
    with Pool(6) as p:
        rows = [r for rs in p.imap_unordered(RB.job, jobs) for r in rs]
    df = pd.DataFrame(rows)
    df["set"] = df.day.map({d: k for k in days for d in days[k]})
    df.to_csv(OUT / "robust96.csv", index=False)
    print(len(df), df.groupby("set").day.nunique().to_dict())
