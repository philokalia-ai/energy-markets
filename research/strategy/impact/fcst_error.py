"""Forecast error (realised - baseline) by zone x hour band on CALIBRATION days (as-of source for the hedge).
usage: python -I fcst_error.py  -> runs/st-impact/fcst_error_cal.csv + printed table."""
import sys
from pathlib import Path
import numpy as np, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV, strat as ST  # noqa: E402
Z = ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]
CAL = (MV.ROOT / "days_cal.txt").read_text().split()
real = ST.realised_table()
rows = []
for d in CAL:
    f = MV.BASE / f"{d}.prices.csv"
    if not f.exists():
        continue
    pb = pd.read_csv(f)
    for z in Z:
        for _, r in pb[pb.zone == z].iterrows():
            h = int(r.hour_utc); pr = real.get((z, d), {}).get(h)
            if pr is not None:
                rows.append(dict(day=d, zone=z, hour=h, band=ST.BAND_OF[h], base=r.price, real=pr, err=pr - r.price))
df = pd.DataFrame(rows)
df.to_csv(MV.ROOT / "runs/st-impact/fcst_error_cal.csv", index=False)
g = df.groupby(["zone", "band"]).err
t = pd.DataFrame({"n": g.size(), "days": df.groupby(["zone", "band"]).day.nunique(), "bias": g.mean(),
                  "mae": g.apply(lambda s: s.abs().mean()), "sd": g.std(),
                  "p10": g.quantile(0.1), "p90": g.quantile(0.9)}).round(1)
pd.set_option("display.width", 200)
print(t.to_string())
