-- iter9 scoping: data completeness audit for AL / MK / ME / HR
-- Window: 2024-07-01 .. 2026-07-01 (2 years = 17544 hours)
-- READ-ONLY. Run: psql "$ENERGY_CONN_STR" -f audit.sql
\pset format aligned
\set win_start '''2024-07-01'''
\set win_end   '''2026-07-01'''

\echo '=== 1. DA prices (entsoe.energy_prices) per zone ==='
SELECT map_code, contract_type, currency, source,
       count(*) AS rows,
       count(DISTINCT date_time_utc) AS distinct_ts,
       min(date_time_utc)::date AS first, max(date_time_utc)::date AS last,
       round(100.0 * count(DISTINCT date_time_utc)
             FILTER (WHERE date_time_utc >= :win_start AND date_time_utc < :win_end)
             / 17544, 1) AS cov_pct_win
FROM entsoe.energy_prices
WHERE map_code IN ('AL','MK','ME','HR')
GROUP BY 1,2,3,4 ORDER BY 1,2;

\echo '=== 1b. DA price resolutions / area_type ==='
SELECT map_code, resolution_code, area_type_code, count(*) AS rows,
       min(date_time_utc)::date AS first, max(date_time_utc)::date AS last
FROM entsoe.energy_prices
WHERE map_code IN ('AL','MK','ME','HR') AND contract_type='Day-ahead'
GROUP BY 1,2,3 ORDER BY 1,2;

\echo '=== 2. DA load forecast coverage (BZN-filtered, as Loads.jl) ==='
SELECT area_map_code, count(*) AS rows,
       count(DISTINCT date_time_utc) AS distinct_ts,
       array_agg(DISTINCT resolution_code) AS resolutions,
       min(date_time_utc)::date AS first, max(date_time_utc)::date AS last,
       round(100.0 * count(DISTINCT date_time_utc)
             FILTER (WHERE date_time_utc >= :win_start AND date_time_utc < :win_end)
             / 17544, 1) AS cov_pct_win_hourly_basis
FROM entsoe.day_ahead_total_load_forecast
WHERE area_map_code IN ('AL','MK','ME','HR')
  AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
GROUP BY 1 ORDER BY 1;

\echo '=== 3. Wind/solar DA forecast coverage (BZN-filtered, as Renewables.jl) ==='
SELECT area_map_code, production_type, count(*) AS rows,
       count(*) FILTER (WHERE day_ahead_generation_forecast_mw IS NULL) AS null_da_fcst,
       count(DISTINCT date_time_utc) AS distinct_ts,
       min(date_time_utc)::date AS first, max(date_time_utc)::date AS last,
       round(100.0 * count(DISTINCT date_time_utc)
             FILTER (WHERE date_time_utc >= :win_start AND date_time_utc < :win_end)
             / 17544, 1) AS cov_pct_win_hourly_basis
FROM entsoe.generation_forecasts_for_wind_and_solar
WHERE area_map_code IN ('AL','MK','ME','HR')
  AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
GROUP BY 1,2 ORDER BY 1,2;

\echo '=== 4. Unit registry (production_and_generation_units) — fuel mix ==='
SELECT area_map_code, generation_unit_type,
       count(DISTINCT generation_unit_code) AS units,
       sum(cap) AS mw
FROM (
  SELECT DISTINCT ON (generation_unit_code)
         area_map_code, generation_unit_type, generation_unit_code,
         generation_unit_installed_capacity_mw AS cap
  FROM entsoe.production_and_generation_units
  WHERE area_map_code IN ('AL','MK','ME','HR')
  ORDER BY generation_unit_code, valid_from DESC NULLS LAST,
           generation_unit_installed_capacity_mw DESC NULLS LAST
) u
GROUP BY 1,2 ORDER BY 1,4 DESC;

\echo '=== 4b. Unit registry status breakdown ==='
SELECT area_map_code, generation_unit_status, count(DISTINCT generation_unit_code) AS units
FROM entsoe.production_and_generation_units
WHERE area_map_code IN ('AL','MK','ME','HR')
GROUP BY 1,2 ORDER BY 1,2;

\echo '=== 4c. Registry area_type / any HR-relevant alias codes? ==='
SELECT area_map_code, area_type_code, count(*) FROM entsoe.production_and_generation_units
WHERE area_map_code IN ('AL','MK','ME','HR') GROUP BY 1,2 ORDER BY 1;

\echo '=== 5. Per-type aggregate output (aggregated_generation_per_type) ==='
SELECT area_map_code, production_type, count(*) AS rows,
       count(DISTINCT date_time_utc) AS distinct_ts,
       min(date_time_utc)::date AS first, max(date_time_utc)::date AS last,
       round(avg(actual_generation_output_mw)::numeric,0) AS avg_mw,
       round((percentile_cont(0.95) WITHIN GROUP (ORDER BY actual_generation_output_mw))::numeric,0) AS p95_mw
FROM entsoe.aggregated_generation_per_type
WHERE area_map_code IN ('AL','MK','ME','HR')
  AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
  AND date_time_utc >= :win_start
GROUP BY 1,2 ORDER BY 1,7 DESC;

\echo '=== 6a. Implicit offered ATC borders touching AL/MK/ME/HR (2024-07 →) ==='
SELECT out_map_code, in_map_code, contract_type, count(*) AS rows,
       min(date_time_utc)::date AS first, max(date_time_utc)::date AS last,
       round(avg(capacity_mw)::numeric,0) AS avg_mw,
       round((percentile_cont(0.10) WITHIN GROUP (ORDER BY capacity_mw))::numeric,0) AS p10_mw,
       max(capacity_mw) AS max_mw
FROM entsoe.offered_transfer_capacities_implicit
WHERE (out_map_code IN ('AL','MK','ME','HR') OR in_map_code IN ('AL','MK','ME','HR'))
  AND date_time_utc >= :win_start
GROUP BY 1,2,3 ORDER BY 1,2;

\echo '=== 6b. Explicit offered ATC borders touching AL/MK/ME/HR (Day-ahead, 2024-07 →) ==='
SELECT out_map_code, in_map_code, count(*) AS rows,
       min(date_time_utc)::date AS first, max(date_time_utc)::date AS last,
       round(avg(capacity_mw)::numeric,0) AS avg_mw,
       round((percentile_cont(0.10) WITHIN GROUP (ORDER BY capacity_mw))::numeric,0) AS p10_mw,
       max(capacity_mw) AS max_mw
FROM entsoe.offered_transfer_capacities_explicit
WHERE (out_map_code IN ('AL','MK','ME','HR') OR in_map_code IN ('AL','MK','ME','HR'))
  AND contract_type = 'Day-ahead'
  AND date_time_utc >= :win_start
GROUP BY 1,2 ORDER BY 1,2;

\echo '=== 7. Physical flows per border (BZN both sides, 2024-07 →) ==='
SELECT out_area_map_code AS o, in_area_map_code AS i, count(*) AS rows,
       min(date_time_utc)::date AS first, max(date_time_utc)::date AS last,
       round(avg(flow_mw)::numeric,0) AS avg_mw, max(flow_mw) AS max_mw
FROM entsoe.physical_flows
WHERE (out_area_map_code IN ('AL','MK','ME','HR') OR in_area_map_code IN ('AL','MK','ME','HR'))
  AND out_area_type_code LIKE 'BZN%' AND in_area_type_code LIKE 'BZN%'
  AND date_time_utc >= :win_start
GROUP BY 1,2 ORDER BY 1,2;

\echo '=== 8. Hydro reservoir filling (weekly) for the hydro zones ==='
SELECT area_map_code, count(*) AS rows, min(date_time_utc)::date AS first,
       max(date_time_utc)::date AS last
FROM entsoe.aggregated_hydro_storage_filling_rate
WHERE area_map_code IN ('AL','MK','ME','HR')
GROUP BY 1 ORDER BY 1;

\echo '=== 9. Actual total load (for eval only) ==='
SELECT area_map_code, count(*) AS rows, min(date_time_utc)::date AS first,
       max(date_time_utc)::date AS last
FROM entsoe.actual_total_load
WHERE area_map_code IN ('AL','MK','ME','HR')
  AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
  AND date_time_utc >= :win_start
GROUP BY 1 ORDER BY 1;

\echo '=== 10. Per-unit actual generation output (UC/inference only) ==='
SELECT p.area_map_code, count(DISTINCT a.generation_unit_code) AS units_with_output
FROM entsoe.production_and_generation_units p
JOIN entsoe.actual_generation_output_per_generation_unit a
  ON a.generation_unit_code = p.generation_unit_code
WHERE p.area_map_code IN ('AL','MK','ME','HR')
  AND a.date_time_utc >= '2026-05-01'
GROUP BY 1 ORDER BY 1;
