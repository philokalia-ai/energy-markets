#!/usr/bin/env python3
"""Ex-ante feature engineering for the Euphemia input model (inference-only).

This is a trimmed, self-contained copy of the training-time feature builder
(docs/experiments/input-upgrade/features.py in the philokalia-ai/energy-markets
repo). It has NO repo imports and NO database access: it turns open-meteo weather
plus a handful of ex-ante scalars (capacity + autoregressive load lags) into the
exact feature vectors the committed LightGBM boosters were trained on.

Every feature is admissible at the D-1 auction gate (08:00 UTC on D-1):
  * weather = GFS `gfs_seamless` values (current run for a true forecast, or the
    `previous_day1` vintage for reconstructing settled history);
  * solar geometry (sun elevation, clearness) is astronomy — known exactly;
  * calendar / holiday flags are known;
  * cap95 (RES) is the trailing-30d p95 of ENTSO-E actual generation ending D-2;
  * ar1/ar7 (load) are the ENTSO-E D-1 and D-7 day-ahead load forecasts.

TRAIN/SERVE CONSISTENCY: this replicates the trained features INCLUDING their
known imperfections (Western Gregorian Easter for GR's Orthodox holidays; only
GR/ES/DE/SE carry a holiday map; hard-coded degree-hour bases 21.0/16.5 C). Do
NOT "fix" a feature here — a serve-time fix would introduce train/serve skew.
Fixes belong at the next retrain.
"""
import numpy as np
import pandas as pd

S0 = 1361.0  # solar-constant proxy used at train time

# Feature-name order per target (must match models/meta.json feat_cols).
SOLAR_FEATS = ["ghi", "cloud", "pres", "se", "clearness", "hod",
               "doy_s", "doy_c", "doy_s2", "doy_c2", "cap95_solar", "v100m"]
WIND_FEATS = ["v100m", "cloud", "pres", "hod", "dow",
              "doy_s", "doy_c", "doy_s2", "doy_c2", "cap95_wind"]
LOAD_FEATS = ["T", "Tma", "cdh", "hdh", "cdh2", "hdh2", "ghi", "hod", "dow",
              "is_hol", "doy_s", "doy_c", "doy_s2", "doy_c2", "ar1", "ar7"]

# Country a zone's load holidays are keyed on (features.py load_models mapping).
ZONE_HOLIDAY_COUNTRY = {"GR": "GR", "ES": "ES", "DE_LU": "DE", "SE2": "SE", "NL": "NL"}


def sinel(hod, doy, lat0, lon0):
    """Clamped sine of solar elevation (array form), features.py `sinel`."""
    hod = np.asarray(hod, dtype=float); doy = np.asarray(doy, dtype=float)
    dec = 0.409 * np.sin(2 * np.pi * (doy + 284) / 365.0)
    H = (hod + lon0 / 15.0 - 12.0) * 15 * np.pi / 180.0
    return np.maximum(
        np.sin(np.radians(lat0)) * np.sin(dec)
        + np.cos(np.radians(lat0)) * np.cos(dec) * np.cos(H), 0.0)


def zone_centroid(geom, zone):
    """Mean (lat, lon) of a zone's RES cells (the geometry the models expect)."""
    cells = np.array(geom[zone]["cells"], dtype=float)
    return float(cells[:, 0].mean()), float(cells[:, 1].mean())


def add_calendar(df, lat0, lon0):
    """features.py add_cal: hour-of-day, day-of-week, sun elevation, doy Fourier."""
    h = df["h"].dt
    doy = h.dayofyear.values.astype(float)
    hod = h.hour.values.astype(float)
    df = df.copy()
    df["hod"] = hod
    df["dow"] = h.dayofweek.values.astype(float)
    df["se"] = sinel(hod, doy, lat0, lon0)
    df["doy_s"] = np.sin(2 * np.pi * doy / 365.25)
    df["doy_c"] = np.cos(2 * np.pi * doy / 365.25)
    df["doy_s2"] = np.sin(4 * np.pi * doy / 365.25)
    df["doy_c2"] = np.cos(4 * np.pi * doy / 365.25)
    return df


# ---- holidays (exact features.py port, incl. its approximations) ----
def _easter(y):
    a = y % 19; b = y // 100; c = y % 100; d = b // 4; e = b % 4
    f = (b + 8) // 25; g = (b - f + 1) // 3
    hh = (19 * a + b - d - g + 15) % 30; i = c // 4; k = c % 4
    l = (32 + 2 * e + 2 * i - hh - k) % 7
    m = (a + 11 * hh + 22 * l) // 451
    mo = (hh + l - 7 * m + 114) // 31
    da = ((hh + l - 7 * m + 114) % 31) + 1
    return pd.Timestamp(y, mo, da)


def holidays(country, years):
    """Static per-country holiday dates. GR movable feasts use the WESTERN Easter
    (the approximation the models were trained on); only GR/ES/DE/SE have a map."""
    hs = set()
    for y in years:
        E = _easter(y)
        fixed = {
            "GR": [(1, 1), (1, 6), (3, 25), (5, 1), (8, 15), (10, 28), (12, 25), (12, 26)],
            "ES": [(1, 1), (1, 6), (5, 1), (8, 15), (10, 12), (11, 1), (12, 6), (12, 8), (12, 25)],
            "DE": [(1, 1), (5, 1), (10, 3), (12, 25), (12, 26)],
            "SE": [(1, 1), (1, 6), (5, 1), (6, 6), (12, 25), (12, 26)],
        }.get(country, [])
        for md in fixed:
            hs.add(pd.Timestamp(y, md[0], md[1]))
        if country == "GR":
            for o in (-48, -2, 0, 1, 50):
                hs.add(E + pd.Timedelta(days=o))
        elif country == "ES":
            for o in (-2, 0):
                hs.add(E + pd.Timedelta(days=o))
        elif country == "DE":
            for o in (-2, 1, 39, 50):
                hs.add(E + pd.Timedelta(days=o))
        elif country == "SE":
            for o in (-2, 0, 1, 39, 49):
                hs.add(E + pd.Timedelta(days=o))
    return {d.normalize() for d in hs}


def build_res_features(res_agg, lat0, lon0, cap95_solar, cap95_wind):
    """Per-hour RES features from zone-hour weather (columns h, ghi, cloud, pres,
    v100m). `cap95_*` are scalars (or a Series mapped by calendar day). Returns a
    frame with SOLAR_FEATS and WIND_FEATS columns plus `h`, `se`."""
    df = add_calendar(res_agg.sort_values("h").reset_index(drop=True), lat0, lon0)
    df["clearness"] = (df["ghi"] / np.maximum(S0 * df["se"], 1.0)).clip(0, 1.3)
    if np.isscalar(cap95_solar) or cap95_solar is None:
        df["cap95_solar"] = np.nan if cap95_solar is None else float(cap95_solar)
    else:
        df["cap95_solar"] = df["h"].dt.floor("D").map(cap95_solar)
    if np.isscalar(cap95_wind) or cap95_wind is None:
        df["cap95_wind"] = np.nan if cap95_wind is None else float(cap95_wind)
    else:
        df["cap95_wind"] = df["h"].dt.floor("D").map(cap95_wind)
    return df


def build_load_features(load_agg, lat0, lon0, ar1, ar7, holset):
    """Per-hour load features from zone-hour weather (columns h, T, ghi). `ar1`,
    `ar7` are Series indexed by hour timestamp (D-1 / D-7 DA load forecast);
    `holset` is a set of normalized holiday dates. Returns a frame with LOAD_FEATS
    columns plus `h`."""
    df = add_calendar(load_agg.sort_values("h").reset_index(drop=True), lat0, lon0)
    df["Tma"] = df["T"].rolling(48, min_periods=1).mean()
    df["cdh"] = np.maximum(df["T"] - 21.0, 0.0)
    df["hdh"] = np.maximum(16.5 - df["T"], 0.0)
    df["cdh2"] = df["cdh"] ** 2 / 10
    df["hdh2"] = df["hdh"] ** 2 / 10
    df["ar1"] = df["h"].map(lambda t: ar1.get(t, np.nan)) if ar1 is not None else np.nan
    df["ar7"] = df["h"].map(lambda t: ar7.get(t, np.nan)) if ar7 is not None else np.nan
    df["is_hol"] = df["h"].dt.normalize().isin(holset).astype(int)
    return df
