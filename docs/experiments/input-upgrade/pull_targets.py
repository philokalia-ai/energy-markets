#!/usr/bin/env python3
# Pull hourly-aggregated ENTSO-E DA-forecast targets + actual per-type generation
# (capacity signal) from the extract for the 4 pilot zones.
import duckdb, os
SP="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
EXT="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
con=duckdb.connect(EXT, read_only=True)
ZONES="('GR','ES','DE_LU','SE2','NL')"

# LOAD target (hourly mean of BZN DA load forecast)
load=con.execute(f"""
 SELECT area_map_code AS zone, date_trunc('hour', date_time_utc) AS h,
        avg(total_load_mw) AS load_da
 FROM entsoe.day_ahead_total_load_forecast
 WHERE area_map_code IN {ZONES} AND area_type_code LIKE 'BZN%' AND total_load_mw IS NOT NULL
 GROUP BY 1,2 ORDER BY 1,2""").df()
load.to_parquet(f"{SP}/tgt_load.parquet"); print("load", load.shape, load.h.min(), load.h.max())

# SOLAR + WIND targets (DA forecast, hourly mean). Wind = onshore+offshore summed per hour.
res=con.execute(f"""
 WITH agg AS (
   SELECT area_map_code AS zone, production_type AS pt,
          date_trunc('hour', date_time_utc) AS h,
          avg(day_ahead_generation_forecast_mw) AS mw
   FROM entsoe.generation_forecasts_for_wind_and_solar
   WHERE area_map_code IN {ZONES} AND area_type_code LIKE 'BZN%'
     AND day_ahead_generation_forecast_mw IS NOT NULL
   GROUP BY 1,2,3 )
 SELECT zone, h,
        sum(CASE WHEN pt='Solar' THEN mw END) AS solar_da,
        sum(CASE WHEN pt LIKE 'Wind%' THEN mw END) AS wind_da
 FROM agg GROUP BY 1,2 ORDER BY 1,2""").df()
res.to_parquet(f"{SP}/tgt_res.parquet"); print("res", res.shape, res.h.min(), res.h.max())

# CAPACITY signal: actual per-type generation (hourly mean), for trailing p95.
cap=con.execute(f"""
 SELECT area_map_code AS zone, production_type AS pt,
        date_trunc('hour', date_time_utc) AS h,
        avg(actual_generation_output_mw) AS mw
 FROM entsoe.aggregated_generation_per_type
 WHERE area_map_code IN {ZONES} AND (production_type='Solar' OR production_type LIKE 'Wind%')
   AND actual_generation_output_mw IS NOT NULL
 GROUP BY 1,2,3 ORDER BY 1,2,3""").df()
cap.to_parquet(f"{SP}/cap_actual.parquet"); print("cap", cap.shape, cap.h.min(), cap.h.max())
print("PULL_DONE")
