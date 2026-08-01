#!/usr/bin/env python3
"""Fetch GFS weather from the FREE, PUBLIC open-meteo API (inference-only).

Trimmed from the training-time fetcher (docs/experiments/input-upgrade/fetch_gfs.py
in philokalia-ai/energy-markets). Two honest ex-ante vintage modes:

  * FORECAST (vintage_lag=0): the current `gfs_seamless` run from
    https://api.open-meteo.com/v1/forecast — the right vintage to PREDICT a future
    delivery day (tomorrow) before the gate.
  * PREVIOUS_DAY-N (vintage_lag>=1): the `*_previous_dayN` fields from
    https://previous-runs-api.open-meteo.com/v1/forecast — for a given hour of day
    D, the value predicted by the run issued D-N. `vintage_lag=1` reconstructs
    settled history exactly as the market saw it at the D-1 gate (no lookahead).

Only these two PUBLIC endpoints are used — no private/self-hosted URL. Batched
<=50 locations/call, with 429 backoff. Returns a tidy DataFrame; the model's
zone-hour aggregation lives in predict.py.
"""
import time
import numpy as np
import pandas as pd
import requests

FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
PREVRUNS_URL = "https://previous-runs-api.open-meteo.com/v1/forecast"
UA = {"User-Agent": "euphemia-input-model/1.0 (open reproducibility bundle)"}

RES_VARS = ["wind_speed_100m", "shortwave_radiation", "cloud_cover", "surface_pressure"]
LOAD_VARS = ["temperature_2m", "shortwave_radiation"]


def _get(url, params, tries=8):
    for i in range(tries):
        try:
            r = requests.get(url, params=params, headers=UA, timeout=180)
            if r.status_code == 429:
                raise requests.HTTPError("429 Too Many Requests", response=r)
            r.raise_for_status()
            return r.json()
        except Exception as e:  # noqa: BLE001
            resp = getattr(e, "response", None)
            code = getattr(resp, "status_code", None)
            wait = 30 * (0.75 + 0.5 * np.random.rand()) if code == 429 else 4 * (i + 1)
            print(f"  open-meteo retry {i+1}/{tries} ({e}) wait {wait:.0f}s", flush=True)
            time.sleep(wait)
    raise RuntimeError("open-meteo request failed: " + url)


def fetch(points, base_vars, vintage_lag=0,
          forecast_days=2, past_days=0, start_date=None, end_date=None):
    """Fetch `base_vars` for `points` (list of (lat, lon)).

    vintage_lag=0 -> forecast endpoint (uses forecast_days / past_days);
    vintage_lag>=1 -> previous-runs endpoint with `*_previous_dayN` over
    [start_date, end_date] (ISO 'YYYY-MM-DD').

    Returns a long DataFrame: columns loc (int index into `points`), lat, lon,
    h (naive-UTC hourly timestamp), and one column per base var.
    """
    if vintage_lag == 0:
        url, sfx = FORECAST_URL, ""
    else:
        url, sfx = PREVRUNS_URL, f"_previous_day{vintage_lag}"
    fields = [v + sfx for v in base_vars]
    rows = []
    for bi in range(0, len(points), 50):
        batch = points[bi:bi + 50]
        params = {
            "latitude": ",".join(str(p[0]) for p in batch),
            "longitude": ",".join(str(p[1]) for p in batch),
            "hourly": ",".join(fields),
            "models": "gfs_seamless",
            "timezone": "UTC",
        }
        if vintage_lag == 0:
            params["forecast_days"] = forecast_days
            if past_days:
                params["past_days"] = past_days
        else:
            params["start_date"] = start_date
            params["end_date"] = end_date
        d = _get(url, params)
        locs = d if isinstance(d, list) else [d]
        assert len(locs) == len(batch), f"{len(locs)} vs {len(batch)}"
        for j, (p, loc) in enumerate(zip(batch, locs)):
            hh = loc["hourly"]
            t = hh["time"]
            rec = {"loc": bi + j, "lat": p[0], "lon": p[1], "h": t}
            for bv, fv in zip(base_vars, fields):
                rec[bv] = hh.get(fv, [None] * len(t))
            rows.append(pd.DataFrame(rec))
        time.sleep(1.0)
    out = pd.concat(rows, ignore_index=True)
    out["h"] = pd.to_datetime(out["h"])
    return out
