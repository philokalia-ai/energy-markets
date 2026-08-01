#!/usr/bin/env python3
"""Predict GR wind & solar for tomorrow, from PUBLIC open-meteo weather only.

Run (from a venv with ../python/requirements.txt installed):
    python examples/predict_gr_tomorrow.py

No database, no repo, no credentials. Solar & wind need only weather + the slow-
moving `cap95` capacity scalar (below). Load additionally needs the D-1/D-7 ENTSO-E
day-ahead load forecasts (ar1/ar7) — see the bundle README.
"""
import os
import sys
import pandas as pd

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))
import fetch_gfs as G          # noqa: E402
import features as F           # noqa: E402
import predict as P            # noqa: E402

ZONE = "GR"
# cap95 = trailing-30d p95 of ENTSO-E actual generation ending D-2 (a slow-moving
# fleet-capacity scalar; MW). Recent GR values — refresh from ENTSO-E for live use.
CAP95_SOLAR, CAP95_WIND = 7319.9, 2900.9

meta, geom, boosters = P.load_bundle()
lat0, lon0 = F.zone_centroid(geom, ZONE)
cells = [(c[0], c[1]) for c in geom[ZONE]["cells"]]

# 1) Fetch tomorrow's GFS run for GR's RES cells (vintage_lag=0 = current run).
wx = G.fetch(cells, G.RES_VARS, vintage_lag=0, forecast_days=2)
res_agg = P.res_zone_hours(wx)

# 2) Build the ex-ante features and score the LightGBM boosters.
feats = F.build_res_features(res_agg, lat0, lon0, CAP95_SOLAR, CAP95_WIND)
feats["solar_mw"] = P.predict_solar(ZONE, feats, meta, boosters)
feats["wind_mw"] = P.predict_wind(ZONE, feats, meta, boosters)

# 3) Print tomorrow's hourly forecast.
tomorrow = (pd.Timestamp.utcnow().normalize() + pd.Timedelta(days=1)).tz_localize(None)
out = feats[feats["h"].dt.floor("D") == tomorrow][["h", "solar_mw", "wind_mw"]]
print(f"{ZONE} predicted RES for {tomorrow.date()} (MW, ex-ante from public GFS):")
print(out.to_string(index=False, float_format=lambda v: f"{v:8.1f}"))
print(f"\nmidday (10-15 UTC) solar mean: "
      f"{out[out['h'].dt.hour.between(10, 15)]['solar_mw'].mean():.0f} MW  "
      f"(GR solar = ML winner; GR wind ships the linear pack in production)")
