# Weather vintages from DuckDB (2026-11-17)

Owner request: score the last 2 years. First make the weather inputs local (the
self-hosted open-meteo, being rebuilt with `<var>_previous_day1` for 2024-11-13 .. now),
then serve them from DuckDB, then run the backfill with 40 workers. This PR does the
middle step. Default behaviour is unchanged; the flag is off unless set.

## What

- `bin/export_weather_vintages.jl`: enumerates every (lat, lon) and hourly variable the
  three weather fetchers request (`weather_vintage_cell_vars`, read from the same pack
  files the fetchers load):

  | fetcher | cells | variables |
  |---|---|---|
  | `fetch_weather` (RES pack) | 1,425 RES-pack cells (v2 = v1) | wind_speed_100m, shortwave_radiation |
  | `fetch_ml_res_weather` (ML RES) | ML geom cells (same 1,425) | + cloud_cover, surface_pressure |
  | `fetch_load_weather` (load) | 175 load-pack / ML geom cities | temperature_2m, shortwave_radiation |

  That is 1,600 cells and 6,050 cell-variables per vintage lag (default lag 1,
  `_previous_day1`; `WEATHER_VINTAGES_LAGS=0,1` adds the plain current-run variables).
  It queries the local instance in ≤50-cell batches with the fetchers' URL shape,
  `models=gfs_seamless`, in 31-day chunks. Each chunk is one transaction: values,
  per-cell coverage and a log row. A rerun skips logged chunks without nulls
  (`WEATHER_VINTAGES_REDO=nulls`, the default), so rerunning after the rebuild fills
  the rest. Output: `~/armada/em-data/weather-vintages.duckdb`
  (`weather_vintages(lat, lon, var, time_utc, value)`, non-null values only,
  `weather_vintages_coverage`, `weather_vintages_chunks`, `weather_vintages_meta`).
- `EUPHEMIA_WEATHER_DUCKDB=<path>` (`bin/weather_duckdb.jl`): `_openmeteo_get` and
  `_load_openmeteo_get` first call `weather_duckdb_answer(url)`. For an open-meteo
  forecast-family URL (`.../v1/forecast`: live or previous-runs, local or public) it
  parses the request and synthesizes the JSON the instance returned: the same locations
  in request order (an object for one, an array otherwise), the requested hours, the
  requested names with their suffix, and `null` where the instance had no value. No
  fetcher logic changes. A request the file does not cover (cell, variable, day), more
  than one model, or a non-UTC timezone is an error, never silent nulls. The ERA5
  archive (`/v1/archive`) still goes to HTTP. Each process opens the file read-only with
  `EUPHEMIA_WEATHER_DUCKDB_MEMORY` (default 1GB) as its memory limit.

The exporter must not run while backfill workers have the file open: DuckDB allows one
writer or many readers.

## Proof

PROOF_PLACEHOLDER
