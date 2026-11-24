#!/usr/bin/env python3
"""Round 2: st-impact's storage absorption (research/strategy/impact/absorption.py, job() unchanged) on the 96-step
baselines. Residual-demand curves come from rd96.jl (96 periods, 11-point grid); absorption's battery is dispatched
hourly as in round 1, on HOURLY curves = the mean over the hour's 4 quarters of the price at each grid point (stated
approximation), with the hourly mean of our 96-step forecast as the baseline price.
usage: python -I absorption96.py DAYS.txt ZONES  -> runs/st-blocks/r2/absorption96.csv
"""
import sys
from multiprocessing import Pool
from pathlib import Path
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "impact"))
import market_view as MV  # noqa: E402
import strat as ST  # noqa: E402

OUT = MV.ROOT / "runs/st-blocks/r2"
RD96, RDH = OUT / "rd96", OUT / "rd96h"


def hourly_rd(day, zone):
    src, dst = RD96 / f"{day}_{zone}.csv", RDH / f"{day}_{zone}.csv"
    if not src.exists():
        return False
    if not dst.exists():
        d = pd.read_csv(src)
        d.groupby(["hour_utc", "q"], as_index=False).price.mean().assign(period=lambda x: x.hour_utc + 1)[
            ["period", "hour_utc", "q", "price"]].to_csv(dst, index=False)
    return True


if __name__ == "__main__":
    days = Path(sys.argv[1]).read_text().split(); zones = sys.argv[2].split(",")
    RDH.mkdir(parents=True, exist_ok=True)
    have = [(d, z) for d in days for z in zones if hourly_rd(d, z)]
    print(f"curves: {len(have)} of {len(days) * len(zones)}")
    ST.RD_DIR = RDH
    MV.BASE = OUT / "base96h"        # hourly-mean copies written by robust96.py
    import absorption as AB          # noqa: E402
    real = ST.realised_table()
    with Pool(6) as p:
        rows = [r for rs in p.imap_unordered(AB.job, [(d, z, real, 2.0) for d, z in have]) for r in rs]
    pd.DataFrame(rows).to_csv(OUT / "absorption96.csv", index=False)
    print(len(rows))
