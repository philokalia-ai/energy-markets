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
  the rest. Source: `WEATHER_VINTAGES_URL` (else `EUPHEMIA_OPENMETEO_PREVRUNS_URL`;
  required). Output: `WEATHER_VINTAGES_OUT` (default `data/weather-vintages.duckdb`; the
  team's export is `em-data/weather-vintages.duckdb`)
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

**Byte identity, offline retro harness** (`test/scripts/benchmark_retro_backfill.jl`):
- Setup: extract `euphemia-live-20261115.duckdb` read-only, lead 1, `GAPFILL=0`, HiGHS. Weather came either from the local open-meteo over HTTP or with `EUPHEMIA_WEATHER_DUCKDB` pointing at a proof export of 2026-09-10..15 and 2026-11-06..11.
- Each day's two modes ran side by side (cores 60-63 and 64-67), so both saw the same state of the instance while it was being rebuilt.

| market day | file | lines | sha256 (HTTP = DuckDB) | |
|---|---|---|---|---|
| 2026-09-14 | prices (market day) | 937 | `64518c13a5d8aec7…` | identical |
| 2026-09-14 | prices (2 UTC days) | 1,873 | `2387556cd35cab21…` | identical |
| 2026-09-14 | weather inputs (fill_pred, preds, solar_preds) | – | `2ecd2471c11efff7…` | identical |
| 2026-11-10 | prices (market day) | 937 | `16a3ccf52bf90bc7…` | identical |
| 2026-11-10 | prices (2 UTC days) | 1,873 | `30e81ba56ebd5694…` | identical |
| 2026-11-10 | weather inputs | – | `7b6799755143663a…` | identical |

- For 2026-09-14, the load fetch's two-day lookback (09-11/12) is still null on the instance, so this case also covers identical null handling.
- The 09-14 HTTP prices are the same in both rounds (round 1 ran on the code before the memory cap).

**Fetcher Dicts, all cells** (2026-09-14): `fetch_weather` gave 1,425 cells and 34,200 cell-hours, `fetch_ml_res_weather` 1,425 cells, and `fetch_load_weather` 175 cells. HTTP and DuckDB results are `==` for all three.

**Tests:**
- `test/test_weather_duckdb.jl`: 28 + 7 pass. It covers nulls, multi- vs single-location shape, request order, suffixes, sub-ranges, the public URL, and the loud failures: uncovered cell, variable or day, multiple models, timezone. It also checks that archive URLs pass through, and runs the three real fetchers end to end against an unreachable primary URL.
- Existing weather tests: gap-fill 54, RES 201, load 33, ML inputs 130.

**Scale:** on a synthetic file the size of two years (105M rows, 693 MB), the 33 batch requests a market day's three fetches need take 1.2 s once warm (8.4 s on first open, including compilation). In the harness, weather fetching took about 11 s with the DuckDB file vs about 7 s over local HTTP, because of the one-time open and compilation per process. Prep and clearing time are otherwise unchanged (~7.5 min per day on 4 threads). The gain is no dependence on the server and no request load from 40 workers, not raw speed.

**Full export:** `em-data/weather-vintages.duckdb` (the team data directory), 2024-11-13 .. 2026-11-16, lag 1, 24 chunks at 3–9 s each. Only 2026-08-26 onward has data so far: chunks up to 2026-08-25 came back all-null, because the cluster rebuild hasn't reached them yet. Once the rebuild finishes, rerun `bin/export_weather_vintages.jl` with the same `WEATHER_VINTAGES_OUT`/`WEATHER_VINTAGES_URL`. It redoes only chunks with nulls, and no worker may have the file open while it runs.
