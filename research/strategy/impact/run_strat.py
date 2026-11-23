"""Driver for Part A. usage: python -I run_strat.py <cal|eval> day1 day2 ...
Writes runs/st-impact/strat/<day>_<zone>.csv.gz (all arms x sizes x hours). Eval days get the hedged arm with errors
from all calibration days (< 2026-07-01, every one < D) that have a cached baseline."""
import sys
from multiprocessing import Pool
from pathlib import Path

import duckdb
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
import strat as ST  # noqa: E402

OUT = MV.ROOT / "runs/st-impact/strat"
ZONES = ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]
CAL = (MV.ROOT / "days_cal.txt").read_text().split()


def job(args):
    kind, day, zone, fuel, errors, real = args
    f = OUT / f"{day}_{zone}.csv.gz"
    if f.exists():
        return f"{day} {zone} cached"
    if not (MV.BASE / f"{day}.tagged.csv.gz").exists() or ST.load_rd(day, zone) is None:
        return f"{day} {zone} missing inputs"
    tg = MV.load_tagged(day, [zone], fuel)
    pb = pd.read_csv(MV.BASE / f"{day}.prices.csv")
    rows = ST.run_zone_day(day, zone, tg, pb, real.get((zone, day), {}) and {zone: real[(zone, day)]} or {},
                           errors=errors if kind == "eval" else None)
    pd.DataFrame(rows).to_csv(f, index=False)
    return f"{day} {zone} rows={len(rows)}"


if __name__ == "__main__":
    kind, days = sys.argv[1], sys.argv[2:]
    OUT.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(Path.home() / "armada/em-data/euphemia-live-20261115.duckdb"), read_only=True)
    fuel = MV.registry_fuel(con)
    con.close()
    real = ST.realised_table()
    errors = ST.calib_errors(CAL, ZONES, real) if kind == "eval" else None
    if errors is not None:
        ncal = sum(1 for d in CAL if (MV.BASE / f"{d}.prices.csv").exists())
        print(f"hedge errors from {ncal} calibration days", flush=True)
    jobs = [(kind, d, z, fuel, errors, real) for d in days for z in ZONES]
    with Pool(int(sys.argv[0] and 6)) as p:
        for msg in p.imap_unordered(job, jobs):
            print(msg, flush=True)
