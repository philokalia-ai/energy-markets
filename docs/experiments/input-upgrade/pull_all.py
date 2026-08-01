#!/usr/bin/env python3
"""Pull DA-forecast targets (load/solar/wind) + actual per-type generation
(capacity signal) for ALL 39 zones from the extract. Rollout-39."""
import duckdb, json
SP="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
EXT="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
con=duckdb.connect(EXT, read_only=True)

load=con.execute("""
 SELECT area_map_code AS zone, date_trunc('hour', date_time_utc) AS h,
        avg(total_load_mw) AS load_da
 FROM entsoe.day_ahead_total_load_forecast
 WHERE area_type_code LIKE 'BZN%' AND total_load_mw IS NOT NULL
   AND date_time_utc >= TIMESTAMP '2024-07-01'
 GROUP BY 1,2 ORDER BY 1,2""").df()
load.to_parquet(f"{SP}/tgt_load39.parquet"); print("load",load.shape)

res=con.execute("""
 WITH agg AS (
   SELECT area_map_code AS zone, production_type AS pt,
          date_trunc('hour', date_time_utc) AS h,
          avg(day_ahead_generation_forecast_mw) AS mw
   FROM entsoe.generation_forecasts_for_wind_and_solar
   WHERE area_type_code LIKE 'BZN%' AND day_ahead_generation_forecast_mw IS NOT NULL
     AND date_time_utc >= TIMESTAMP '2024-07-01'
   GROUP BY 1,2,3 )
 SELECT zone, h,
        sum(CASE WHEN pt='Solar' THEN mw END) AS solar_da,
        sum(CASE WHEN pt LIKE 'Wind%' THEN mw END) AS wind_da
 FROM agg GROUP BY 1,2 ORDER BY 1,2""").df()
res.to_parquet(f"{SP}/tgt_res39.parquet"); print("res",res.shape)

cap=con.execute("""
 SELECT area_map_code AS zone, production_type AS pt,
        date_trunc('hour', date_time_utc) AS h,
        avg(actual_generation_output_mw) AS mw
 FROM entsoe.aggregated_generation_per_type
 WHERE (production_type='Solar' OR production_type LIKE 'Wind%')
   AND actual_generation_output_mw IS NOT NULL
   AND date_time_utc >= TIMESTAMP '2024-06-01'
 GROUP BY 1,2,3 ORDER BY 1,2,3""").df()
cap.to_parquet(f"{SP}/cap_all39.parquet"); print("cap",cap.shape)
print("PULL_ALL_DONE")
