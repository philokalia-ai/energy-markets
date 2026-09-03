# Reading weather data

Hourly weather (temperature, wind, radiation, precipitation, …) for **1,851 Greek
cities**, in a **separate weather database** on the *same* Postgres server as
`energy`, populated nightly (03:00) by the `weather-etl` CronJob into `weather.*`.
Postgres cannot join across databases, so you open a **second connection** (env
`WEATHER_CONN_STR`) and join to `energy` data in Julia/DataFrames, not in SQL.

> **The price model does not read this database.** The production weather path is
> the open-meteo previous-runs fetch ([`bin/weather_vintage.jl`](bin/weather_vintage.jl),
> [`docs/predictions.md`](docs/predictions.md)), which covers all 39 zones with an
> honest D-1 vintage. This DB is GR-only; it feeds the DuckDB extract
> (`bin/extract_common.jl`) and GR-specific experiments.

## 1. Setup — ✅ already done

The `ENERGY_CONN_STR` role has read-only access to the `weather` schema (`CONNECT`
on the database, `USAGE` on the schema, `SELECT` on its tables + default
privileges — applied as postgres; no access to that database's other schemas), and
`.env` carries the second connection string: same host/credentials as
`ENERGY_CONN_STR`, the weather database's **`dbname`** instead of `energy`:

```bash
# .env
WEATHER_CONN_STR=postgresql://<user>:<pw>@<host>:<port>/<weather-db>
```

## 2. Reading it from Julia

`src/dbutils.jl`'s pool (`withdb` / `sql2df`) is bound to `ENERGY_CONN_STR` and
only sees the `energy` DB. Use a separate connection — the repo already has one in
[`bin/extract_common.jl`](bin/extract_common.jl) (`_weather_connect` /
`weather_query`); standalone, the same idiom:

```julia
using LibPQ, DataFrames

"Run SQL against the weather database, returning a DataFrame."
function weather2df(sql, args = [])
    # WEATHER_CONN_STR is a postgres:// URI — pass options as KWARGS. Appending
    # " connect_timeout=30" to a URI is invalid conninfo and libpq rejects it.
    cnx = LibPQ.Connection(ENV["WEATHER_CONN_STR"]; connect_timeout = 30)
    try
        return DataFrame(LibPQ.execute(cnx, sql, args))
    finally
        close(cnx)
    end
end
```

## 3. Schema reference (the `weather` schema)

| Table | Rows (2026-09-03) | What |
|---|---|---|
| `city` | 1,851 | catalogue: `city_id, name, country_code, population, lat, long` (all `GR`) |
| `city_forecast` | ~33 M | forecast hourly values, PK `(city_id, measure_ts)` — each target hour keeps only the **latest** run (upserted in place) |
| `city_forecast_vintage` | ~28 M | the same values **stamped by issue date**, PK `(city_id, run_date, measure_ts)` — one snapshot per ETL run, so lead-N backtests stay honest |
| `city_measure` | ~305 M | ERA5 reanalysis history. Nothing in `src/` or `bin/` reads it; kept for GR history work |
| `unit` | small | `unit_id → name` lookup for the `*_unit_id` columns |

The three hourly tables share the same value columns (`city_forecast_vintage` adds
`run_date date`):

```
city_id, measure_ts (timestamp WITHOUT tz, wall time in ts_timezone), ts_timezone
temperature_2m °C · relative_humidity_2m % · precipitation mm · weather_code (WMO)
wind_speed_10m  km/h · wind_direction_10m  deg
wind_speed_100m km/h · wind_direction_100m deg      ← wind driver
shortwave_radiation W/m² (GHI)                      ← solar driver
direct_radiation W/m² · diffuse_radiation W/m² · cloud_cover %
<var>_unit_id  int  -- FK → weather.unit, per variable
```

### Which variable for what

Use what the models are fitted on: both the linear packs and the LightGBM input
models train on `wind_speed_100m` + `shortwave_radiation` (`bin/ml_inputs.jl`
`ML_RES_VARS`, `bin/weather_res.jl`), so anything scored against them must use the
same columns.

| Euphemia need | Column | Note |
|---|---|---|
| Solar PV output | `shortwave_radiation` | W/m² GHI; pair with sun elevation / clearness |
| Wind output | `wind_speed_100m` | km/h, already near hub height — no 10 m extrapolation |
| Load / demand | `temperature_2m` | heating/cooling degree signal |

`direct_radiation` and `wind_speed_10m` exist but are read nowhere in this repo.

### Freshness
- Forecast horizon reaches ~+7 days; refreshed nightly at 03:00.
- `city_forecast` is **upserted in place** — past hours get overwritten by
  post-delivery runs, so a forecast read back for a past timestamp is really a
  near-analysis. **For backtests use `city_forecast_vintage`** and filter
  `run_date <= delivery_date - 1` yourself. It accumulates one `run_date` per run
  and is trimmed by a retention job — check `min(run_date)` before assuming depth.
- `city_measure` is ERA5, published with a ~1–2 week lag; `max(measure_ts)` sitting
  well behind "now" is normal, not a gap.

## 4. Ready-made queries

**Day-ahead drivers for the GR fleet, one day (live view):**
```sql
SELECT c.city_id, c.name, c.lat, c.long,
       f.measure_ts, f.shortwave_radiation, f.wind_speed_100m, f.temperature_2m
FROM weather.city_forecast f
JOIN weather.city c USING (city_id)
WHERE f.measure_ts >= $1 AND f.measure_ts < $2
ORDER BY c.city_id, f.measure_ts;
```

**The same day as it was seen at the D-1 gate (honest backtest):**
```sql
SELECT city_id, measure_ts, shortwave_radiation, wind_speed_100m, temperature_2m
FROM weather.city_forecast_vintage
WHERE run_date = $1                      -- e.g. delivery_date - 1
  AND measure_ts >= $2 AND measure_ts < $3
ORDER BY city_id, measure_ts;
```

For a zone aggregate, weight cities by population (load) or by capacity near each
wind/solar asset (RES) rather than a flat `avg()` — join to your `energy`-side
coordinates **in Julia** after pulling both DataFrames.

## 5. Gotchas
- **Different database** (not `energy`): no cross-DB SQL joins — join in DataFrames.
- **Collation warnings** on connect are harmless server noise; ignore them.
- **NULLs**: all-missing rows are dropped by the ETL, but a present row can still
  have individual NULL columns — filter per variable.
- **Timestamps are UTC/GMT-naive** — don't assume Europe/Athens.
- **GR only**: `weather.city` carries no non-GR cities; for other zones use the
  open-meteo path above.
