"""Inputs for the epftoolbox baselines (LEAR, DNN) on our exact cells, from the read-only extract.

Per zone, an hourly frame on the **Athens market-day grid** (the cells the tsfm backtest scores: market
day D = Athens local day D, 23/25 hours on the EU DST switches), in epftoolbox's layout:

  Price        SDAC day-ahead price (bin/da_target.py hourly_actuals, target="sdac")
  Exogenous 1  ENTSO-E day-ahead total load forecast (6.1.B), hourly mean
  Exogenous 2  ENTSO-E day-ahead wind + solar generation forecast (14.1.D), hourly mean per production
               type, summed over the types the zone publishes

Both forecast tables hold one (the latest) revision per slot: the same feed the record physics reads.

Wall-clock grid (as the epftoolbox datasets): 24 values per local day; the spring-forward missing hour
is interpolated, the autumn duplicated hour is averaged. A forecast for local hour h maps back to every
UTC hour of the market day whose Athens local time is h (both copies on the 25-hour day).

Gaps are filled ex-ante: a missing value takes the same hour 1..7 days earlier (persistence), then the
last earlier value. Counts of filled hours are returned for the report.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

BIN = Path(__file__).resolve().parents[3] / "bin"
sys.path.insert(0, str(BIN))
import da_target  # noqa: E402

TZ = "Europe/Athens"
DATA_START = pd.Timestamp("2022-12-01")   # first hour of prices and both forecast feeds in the extract

LOAD_SQL = """
SELECT z, h, AVG(m) AS v FROM (
  SELECT area_map_code AS z, resolution_code AS r, date_trunc('hour', date_time_utc) AS h,
         AVG(total_load_mw) AS m
  FROM entsoe.day_ahead_total_load_forecast
  WHERE area_type_code LIKE 'BZN%' AND total_load_mw IS NOT NULL AND area_map_code = ?
  GROUP BY 1, 2, 3) GROUP BY 1, 2
"""
RES_SQL = """
SELECT z, h, SUM(m) AS v FROM (
  SELECT z, p, h, AVG(m) AS m FROM (
    SELECT area_map_code AS z, production_type AS p, resolution_code AS r,
           date_trunc('hour', date_time_utc) AS h, AVG(day_ahead_generation_forecast_mw) AS m
    FROM entsoe.generation_forecasts_for_wind_and_solar
    WHERE area_type_code LIKE 'BZN%' AND day_ahead_generation_forecast_mw IS NOT NULL
      AND area_map_code = ?
    GROUP BY 1, 2, 3, 4) GROUP BY 1, 2, 3) GROUP BY 1, 2
"""


def _fill_ex_ante(s: pd.Series) -> tuple[pd.Series, int]:
    """Fill NaNs with the same hour 1..7 days earlier, then the last earlier value (never a later one)."""
    n = int(s.isna().sum())
    for k in range(1, 8):
        if not s.isna().any():
            break
        s = s.fillna(s.shift(24 * k))
    return s.ffill(), n


def to_wallclock(s: pd.Series) -> pd.Series:
    """UTC-indexed hourly series -> naive Athens wall-clock hourly series, 24 values per local day."""
    loc = s.copy()
    loc.index = s.index.tz_localize("UTC").tz_convert(TZ).tz_localize(None)
    loc = loc.groupby(level=0).mean()                     # autumn: duplicated hour averaged
    full = pd.date_range(loc.index.min().normalize(), loc.index.max().normalize() + pd.Timedelta(hours=23),
                         freq="h")
    return loc.reindex(full).interpolate(limit_area="inside")   # spring: missing hour interpolated


def zone_frame(con, zone: str, end: str) -> tuple[pd.DataFrame, dict]:
    """epftoolbox frame (wall-clock index; Price, Exogenous 1, Exogenous 2) up to market day `end`."""
    t_end = pd.Timestamp(end) + pd.Timedelta(days=2)
    act = da_target.hourly_actuals(con, DATA_START, t_end, target="sdac")
    p = act[act.z == zone].set_index("t").act
    p.index = pd.to_datetime(p.index)
    load = con.execute(LOAD_SQL, [zone]).df().set_index("h").v
    res = con.execute(RES_SQL, [zone]).df().set_index("h").v
    grid = pd.date_range(DATA_START, t_end, freq="h", inclusive="left")
    cols, filled = {}, {}
    for name, s in (("Price", p), ("Exogenous 1", load), ("Exogenous 2", res)):
        s = s.groupby(level=0).mean().reindex(grid)
        s, filled[name] = _fill_ex_ante(s)
        cols[name] = to_wallclock(s)
    df = pd.DataFrame(cols).dropna()
    first_midnight = df.index[df.index.hour == 0][0]       # epftoolbox wants the frame to start at 00:00
    return df.loc[first_midnight:], filled


def market_day_cells(day: str) -> pd.DataFrame:
    """UTC hours of Athens market day `day` and their Athens wall-clock hour."""
    lo = pd.Timestamp(day).tz_localize(TZ).tz_convert("UTC")
    hi = (pd.Timestamp(day) + pd.Timedelta(days=1)).tz_localize(TZ).tz_convert("UTC")
    t = pd.date_range(lo, hi, freq="h", inclusive="left")
    return pd.DataFrame({"t_utc": t.tz_localize(None), "hour": t.tz_convert(TZ).hour})
