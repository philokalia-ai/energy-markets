#!/bin/bash
# Hourly zone wind actuals (Wind Onshore + Offshore, dedup by update_time,
# BZN area filter) for all wind zones, 2024-07-01..2026-07-01; plus the GR
# ENTSO-E D-1 wind forecast for the chain check.
set -e
REPO=$(git rev-parse --show-toplevel)
mkdir -p "${GFS_OUT:-$HOME/.cache/euphemia-gfs-refit}"
cd "${GFS_OUT:-$HOME/.cache/euphemia-gfs-refit}"
set -a; source "$REPO/.env" >/dev/null 2>&1; set +a

ZONES=$(python3 -c "
import json
p = json.load(open('$REPO/bin/res_models_v1.json'))
print(','.join(sorted(z for z,v in p['zones'].items() if 'wind' in v)))")
echo "zones: $ZONES"

psql "$ENERGY_CONN_STR" -c "\copy (
WITH d AS (
  SELECT DISTINCT ON (area_map_code, production_type, date_time_utc)
         area_map_code AS zone, production_type, date_time_utc,
         actual_generation_output_mw AS mw
  FROM entsoe.aggregated_generation_per_type
  WHERE area_map_code = ANY(string_to_array('$ZONES', ','))
    AND production_type IN ('Wind Onshore','Wind Offshore')
    AND area_type_code LIKE 'BZN%'
    AND actual_generation_output_mw IS NOT NULL
    AND date_time_utc >= '2024-07-01 00:00+00'
    AND date_time_utc <  '2026-07-01 00:00+00'
  ORDER BY area_map_code, production_type, date_time_utc, update_time_utc DESC
)
SELECT zone, production_type,
       to_char(date_trunc('hour', date_time_utc AT TIME ZONE 'UTC'), 'YYYY-MM-DD\"T\"HH24:MI') AS h,
       AVG(mw) AS mw
FROM d GROUP BY 1,2,3 ORDER BY 1,2,3
) TO 'wind_actuals.csv' WITH CSV HEADER"
wc -l wind_actuals.csv

psql "$ENERGY_CONN_STR" -c "\copy (
WITH d AS (
  SELECT DISTINCT ON (production_type, date_time_utc)
         production_type, date_time_utc, day_ahead_generation_forecast_mw AS mw
  FROM entsoe.generation_forecasts_for_wind_and_solar
  WHERE area_map_code = 'GR'
    AND production_type LIKE 'Wind%'
    AND area_type_code LIKE 'BZN%'
    AND day_ahead_generation_forecast_mw IS NOT NULL
    AND date_time_utc >= '2024-07-01 00:00+00'
    AND date_time_utc <  '2026-07-01 00:00+00'
  ORDER BY production_type, date_time_utc, update_time_utc DESC
)
SELECT production_type,
       to_char(date_trunc('hour', date_time_utc AT TIME ZONE 'UTC'), 'YYYY-MM-DD\"T\"HH24:MI') AS h,
       AVG(mw) AS mw
FROM d GROUP BY 1,2 ORDER BY 1,2
) TO 'gr_wind_dafc.csv' WITH CSV HEADER"
wc -l gr_wind_dafc.csv
echo TARGETS_DONE
