"""Write st-impact 96-step price CSVs (runs/st-impact/r2/shape/<arm>/<day>.prices.csv) into one DuckDB per market day
with the record pipeline's table shape — simulations.energy_prices(bidding_zone, date_time_utc, price_eur_mwh,
resolution_code='15M') — so cv46's export_phys.py runs on them unchanged.
usage: python -I csv2db.py ARM_DIR OUT_DIR DAYS.txt"""
import sys
from pathlib import Path
import duckdb, pandas as pd
src, out, days = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]).read_text().split()
out.mkdir(parents=True, exist_ok=True)
missing = [d for d in days if not (src / f"{d}.prices.csv").exists()]
if missing:
    raise SystemExit(f"{len(missing)} days missing, e.g. {missing[:3]}")
for d in days:
    p = pd.read_csv(src / f"{d}.prices.csv", dtype={"period": str})
    p["date_time_utc"] = pd.to_datetime(p.period, format="%Y%m%d-%H%M")
    p = p.rename(columns={"zone": "bidding_zone", "price": "price_eur_mwh"})[["bidding_zone", "date_time_utc", "price_eur_mwh"]]
    p["resolution_code"] = "15M"
    f = out / f"{d}.duckdb"
    f.unlink(missing_ok=True)
    c = duckdb.connect(str(f))
    c.execute("create schema simulations")
    c.execute("create table simulations.energy_prices as select * from p")
    c.close()
print(len(days), "day DBs ->", out)
