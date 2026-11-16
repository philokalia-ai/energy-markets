"""Julia vs Python agreement for the DA target policy (#431 PR C).

usage: python compare_python.py --extract EXTRACT.duckdb --julia-dir DIR
DIR holds identity_check.jl's actuals_default.csv / actuals_sdac.csv. Recomputes the same
market-day windows with bin/da_target.py (highest_seq_hourly / sdac_hourly) and reports the
row-set and value agreement per policy."""
import argparse, sys
from pathlib import Path
import duckdb, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "bin"))
import da_target as dt  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--extract", required=True)
ap.add_argument("--julia-dir", required=True)
a = ap.parse_args()
cx = duckdb.connect(a.extract, read_only=True)
for name, fn in [("default", dt.highest_seq_hourly), ("sdac", lambda r: dt.sdac_hourly(r)[0])]:
    jl = pd.read_csv(f"{a.julia_dir}/actuals_{name}.csv", parse_dates=["t"])
    py = []
    for d in sorted(jl.market_date.unique()):
        d0 = pd.Timestamp(d) - pd.Timedelta(days=1)
        x = fn(dt.raw_rows(cx, d0, pd.Timestamp(d) + pd.Timedelta(days=1)))
        py.append(x.assign(market_date=d))
    py = pd.concat(py)
    m = jl.merge(py, on=["market_date", "z", "t"], how="outer", suffixes=("_jl", "_py"), indicator=True)
    both = m[m._merge == "both"]
    print(f"{name}: julia {len(jl)} rows, python {len(py)} rows, only-julia {int((m._merge == 'left_only').sum())}, "
          f"only-python {int((m._merge == 'right_only').sum())}, max |diff| {(both.act_jl - both.act_py).abs().max():.2e}")
