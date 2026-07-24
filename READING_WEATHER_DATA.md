# Reading weather data

Weather (temperature, wind, solar radiation, precipitation, …) for **1,851 Greek
cities**, hourly, from **2007 → today** plus a short forecast horizon. It's the
RES/load driver referenced in the README ("Load – Renewable Energy Sources Output:
Weather"). This doc is how a Euphemia agent pulls it.

> **TL;DR** — the weather data is **not** in the `energy` database. It's in a
> **separate weather database** on the *same* Postgres server
> (host/port as in your `.env`). Postgres can't join across databases, so you open a
> **second connection** to it (env `WEATHER_CONN_STR`) and join to
> `energy` data in Julia/DataFrames, not in SQL.

The pipeline runs as a nightly `weather-etl` CronJob (03:00), upserting into
the weather database's `weather.*` schema.

---

## 1. One-time setup

### a) Grant read access — ✅ already done
The `ENERGY_CONN_STR` role has been granted read-only access to the `weather`
schema in the weather database:

```sql
-- (already applied) as postgres, connected to the weather database
-- (<weather-db> = its name, <role> = the ENERGY_CONN_STR role):
GRANT CONNECT ON DATABASE <weather-db> TO <role>;
GRANT USAGE  ON SCHEMA weather        TO <role>;
GRANT SELECT ON ALL TABLES IN SCHEMA weather TO <role>;
ALTER DEFAULT PRIVILEGES IN SCHEMA weather GRANT SELECT ON TABLES TO <role>;
```

Scoped to the `weather` schema only — no access to the other schemas of that
database.

### b) Connection string — ✅ already in `.env`
`WEATHER_CONN_STR` has been added: same host/credentials as `ENERGY_CONN_STR`,
just with the weather database's **`dbname`** instead of `energy`:

```bash
# .env
WEATHER_CONN_STR=postgresql://<user>:<pw>@<host>:<port>/<weather-db>
```

---

## 2. Reading it from Julia

`src/dbutils.jl`'s pool (`withdb` / `sql2df`) is bound to `ENERGY_CONN_STR`, so it
only sees the `energy` DB. Use a **separate** connection for weather — same
`LibPQ` + `DataFrames` idiom:

```julia
using LibPQ, DataFrames

"Run SQL against the weather database, returning a DataFrame."
function weather2df(sql, args = [])
    cnx = LibPQ.Connection(ENV["WEATHER_CONN_STR"] * " connect_timeout=30")
    try
        return DataFrame(LibPQ.execute(cnx, sql, args))
    finally
        close(cnx)
    end
end
```

For repeated calls, wrap it in a small pool exactly like `cnxpool` in
`dbutils.jl`; for occasional reads the above is enough.

```julia
df = weather2df("""
    SELECT c.name, m.measure_ts, m.temperature_2m, m.direct_radiation, m.wind_speed_10m
    FROM weather.city_measure m
    JOIN weather.city c USING (city_id)
    WHERE c.name = \$1 AND m.measure_ts >= \$2 AND m.measure_ts < \$3
    ORDER BY m.measure_ts
""", ["Athens", "2024-06-15", "2024-06-16"])
```

---

## 3. Schema reference (the `weather` schema)

| Table | Rows | What |
|---|---|---|
| `city` | 1,851 | city catalogue: `city_id, name, country_code, population, lat, long` (all `GR`) |
| `city_measure` | ~316 M | **historical** hourly observations (reanalysis) |
| `city_forecast` | ~31 M | **forecast** hourly values (rolling) |
| `unit` | small | `unit_id → name` lookup for the `*_unit_id` columns |

`city_measure` and `city_forecast` share the same columns:

```
city_id                integer      -- FK → weather.city
measure_ts             timestamp    -- WITHOUT time zone; the wall time in ts_timezone
ts_timezone            text         -- API timezone (currently 'GMT'/UTC)
temperature_2m         float        -- °C
relative_humidity_2m   int          -- %
precipitation          float        -- mm
weather_code           int          -- WMO code
wind_speed_10m         float        -- km/h  (open-meteo default)
wind_direction_10m     int          -- degrees
direct_radiation       float        -- W/m²  ← solar PV driver
<var>_unit_id          int          -- FK → weather.unit, per variable
PRIMARY KEY (city_id, measure_ts)
```

Units are stored by id; resolve the exact string with the `unit` table if you
don't want to hardcode the defaults above:

```sql
SELECT u.name FROM weather.unit u
JOIN weather.city_measure m ON m.wind_speed_10m_unit_id = u.unit_id
LIMIT 1;
```

### Which variable for what
| Euphemia need | Column | Note |
|---|---|---|
| Solar PV output | `direct_radiation` | W/m²; pair with panel area/efficiency |
| Wind output | `wind_speed_10m` (+ `wind_direction_10m`) | hub-height correction is on you (10 m → ~80–120 m) |
| Load / demand | `temperature_2m` (+ humidity) | heating/cooling degree signal |

### Freshness & cadence — read this
- Updated **nightly (03:00)** by the k3s `weather-etl` CronJob.
- **`city_measure` legitimately lags ~5–6 days.** It's ERA5 reanalysis
  (`copernicus_era5`), which is only published with that delay — so
  `max(measure_ts)` sitting a few days behind "now" is normal, not a gap.
- **Use `city_forecast` for the recent past + next few days** (day-ahead
  horizon). It overlaps the measure lag window.
- `measure_ts` is a naive timestamp; interpret it in `ts_timezone` (GMT/UTC).
  Convert to Europe/Athens yourself if aligning to local market hours.

---

## 4. Ready-made queries

**Day-ahead solar & wind for the whole GR fleet (forecast), one day:**
```sql
SELECT c.city_id, c.name, c.lat, c.long,
       f.measure_ts, f.direct_radiation, f.wind_speed_10m, f.temperature_2m
FROM weather.city_forecast f
JOIN weather.city c USING (city_id)
WHERE f.measure_ts >= $1 AND f.measure_ts < $2
ORDER BY c.city_id, f.measure_ts;
```

**National hourly average (simple zone proxy) over a period, historical:**
```sql
SELECT measure_ts,
       avg(temperature_2m)  AS temp_c,
       avg(direct_radiation) AS ghi_wm2,
       avg(wind_speed_10m)  AS wind_kmh
FROM weather.city_measure
WHERE measure_ts >= $1 AND measure_ts < $2
GROUP BY measure_ts
ORDER BY measure_ts;
```

**Cities inside a bounding box (e.g. a bidding-zone footprint):**
```sql
SELECT city_id, name, lat, long FROM weather.city
WHERE lat BETWEEN $1 AND $2 AND long BETWEEN $3 AND $4;
```

For a proper zone aggregate, weight cities by capacity/population near each
wind/solar asset rather than a flat `avg()` — join to your `energy`-side asset
coordinates **in Julia** after pulling both DataFrames.

---

## 5. Gotchas
- **Different database** (the weather DB, not `energy`): no cross-DB SQL joins —
  join in DataFrames.
- **Collation warnings** (`database ... has a collation version
  mismatch …`) on connect are harmless noise from the server; ignore them.
- **Historical vs forecast overlap**: both tables can cover the same timestamps;
  pick one deliberately (measure = authoritative but lagged, forecast = fresh).
- **NULLs**: rows where every variable was missing are dropped by the ETL; a
  present row can still have individual NULL columns — filter per variable.
- **Timestamps are UTC/GMT-naive** — don't assume Europe/Athens.
```
