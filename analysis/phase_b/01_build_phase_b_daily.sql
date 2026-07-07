-- Phase B — Analysis A support table: simulations.phase_b_daily
-- One row per GR day, 2022-01-01 .. 2026-06-30.
--
-- Timezone discipline (see CLAUDE.md gotcha):
--   entsoe.* date_time_utc are `timestamp WITH time zone` (true UTC instants).
--   simulations.* timestamps are naive UTC.
--   We group everything by the UTC calendar date. For entsoe columns that
--   means `(date_time_utc AT TIME ZONE 'UTC')::date`; for simulations columns
--   the value is already naive UTC so `date_time_utc::date` is the UTC date.
--   unfiled_dark_units.day is the market/local day; we join it directly to the
--   UTC date (a <=1h boundary approximation on a daily aggregate; documented).
--
-- Reproducible: DROP + CREATE + INSERT. Safe to re-run.

DROP TABLE IF EXISTS simulations.phase_b_daily;

CREATE TABLE simulations.phase_b_daily AS
WITH
-- ------------------------------------------------------------------ calendar
days AS (
  SELECT d::date AS day
  FROM generate_series('2022-01-01'::date, '2026-06-30'::date, '1 day') d
),
-- ---------------------------------------------------------------- actuals (GR)
actual AS (
  SELECT (date_time_utc AT TIME ZONE 'UTC')::date AS day,
         AVG(price_currency_mwh)::numeric AS avg_actual_price
  FROM entsoe.energy_prices
  WHERE map_code = 'GR' AND contract_type = 'Day-ahead'
    AND (date_time_utc AT TIME ZONE 'UTC')::date
        BETWEEN '2022-01-01' AND '2026-06-30'
  GROUP BY 1
),
-- ------------------------------------------- counterfactual (v10 multi-zone GR)
sim AS (
  SELECT date_time_utc::date AS day,
         AVG(price_eur_mwh)::numeric AS avg_sim_price
  FROM simulations.energy_prices
  WHERE bidding_zone = 'GR' AND code_version = 10
    AND order_method = 'merit_order' AND clearing_mode = 'multi_zone'
    AND date_time_utc::date BETWEEN '2022-01-01' AND '2026-06-30'
  GROUP BY 1
),
-- ------------------------------------------------- unfiled dark capacity (GR)
dark AS (
  SELECT day,
         SUM(p_max) FILTER (WHERE strong)      AS dark_mw,
         SUM(p_max)                             AS dark_mw_all
  FROM simulations.unfiled_dark_units
  WHERE zone = 'GR'
  GROUP BY day
),
-- ------------------------------ hourly load & RES forecast (GR), UTC hour bucket
-- Power (MW): average within the hour bucket is robust to mixed PT15M/PT60M.
load_h AS (
  SELECT date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS hour_utc,
         AVG(total_load_mw) AS load_mw
  FROM entsoe.day_ahead_total_load_forecast
  WHERE area_map_code = 'GR'
    AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
    AND (date_time_utc AT TIME ZONE 'UTC')::date
        BETWEEN '2022-01-01' AND '2026-06-30'
  GROUP BY 1
),
res_h AS (
  SELECT hour_utc, SUM(res_mw) AS res_mw FROM (
    SELECT date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS hour_utc,
           production_type,
           AVG(day_ahead_generation_forecast_mw) AS res_mw
    FROM entsoe.generation_forecasts_for_wind_and_solar
    WHERE area_map_code = 'GR'
      AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
      AND (date_time_utc AT TIME ZONE 'UTC')::date
          BETWEEN '2022-01-01' AND '2026-06-30'
    GROUP BY 1,2
  ) s
  GROUP BY hour_utc
),
netdem_h AS (
  SELECT l.hour_utc, l.hour_utc::date AS day,
         l.load_mw,
         COALESCE(r.res_mw,0)                    AS res_mw,
         l.load_mw - COALESCE(r.res_mw,0)        AS net_demand_mw
  FROM load_h l LEFT JOIN res_h r USING (hour_utc)
),
netdem_daily AS (
  SELECT day,
         MAX(net_demand_mw)                      AS peak_net_demand,
         CASE WHEN SUM(load_mw) > 0
              THEN SUM(res_mw) / SUM(load_mw) END AS res_share
  FROM netdem_h
  GROUP BY day
),
-- ------------------------------------------------------- TTF (5-trading-day chg)
ttf_ord AS (
  SELECT date::date AS d, close,
         LAG(close,5) OVER (ORDER BY date) AS close_5ago
  FROM yfinance.ttf_f
),
ttf_day AS (   -- for each calendar day: last trading close strictly before it
  SELECT dd.day,
         t.close                     AS ttf_dm1,
         t.close - t.close_5ago       AS ttf_change_5d
  FROM days dd
  CROSS JOIN LATERAL (
    SELECT close, close_5ago FROM ttf_ord
    WHERE d < dd.day ORDER BY d DESC LIMIT 1
  ) t
),
-- ------------------------------------------------------- EUA (D-1 close)
eua_day AS (
  SELECT dd.day, e.close AS eua_dm1
  FROM days dd
  CROSS JOIN LATERAL (
    SELECT close FROM yfinance.eua_co2 WHERE date::date < dd.day
    ORDER BY date DESC LIMIT 1
  ) e
),
-- ------------------------------------------- reservoir filling % + deviation (GR)
res_max AS (
  SELECT MAX(stored_energy_mwh) AS gmax
  FROM entsoe.aggregated_hydro_storage_filling_rate WHERE area_map_code = 'GR'
),
res_weekly AS (
  SELECT year, week,
         to_date(year::text || ' ' || lpad(week::text,2,'0'), 'IYYY IW') AS week_start,
         stored_energy_mwh / (SELECT gmax FROM res_max) * 100.0 AS fill_pct
  FROM entsoe.aggregated_hydro_storage_filling_rate
  WHERE area_map_code = 'GR'
),
res_dev AS (   -- deviation from same-ISO-week median of PRIOR years
  SELECT a.year, a.week, a.week_start, a.fill_pct,
         a.fill_pct - (
           SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY b.fill_pct)
           FROM res_weekly b WHERE b.week = a.week AND b.year < a.year
         ) AS reservoir_deviation
  FROM res_weekly a
),
reservoir_day AS (   -- latest weekly obs at or before the day
  SELECT dd.day, rr.fill_pct AS reservoir_pct, rr.reservoir_deviation
  FROM days dd
  CROSS JOIN LATERAL (
    SELECT fill_pct, reservoir_deviation FROM res_dev
    WHERE week_start <= dd.day ORDER BY week_start DESC LIMIT 1
  ) rr
),
-- --------------------------------- Active-outage derated MW for GR that day
-- unit installed capacity from fleet (generation- and production-level codes),
-- DISTINCT ON dedup (most recent valid_from, then largest capacity).
fleet AS (   -- union; prefer generation-level cap when a code exists in both
  SELECT code, MAX(cap) AS cap FROM (
    (SELECT DISTINCT ON (generation_unit_code)
            generation_unit_code AS code,
            generation_unit_installed_capacity_mw AS cap
     FROM entsoe.production_and_generation_units
     WHERE area_map_code = 'GR' AND generation_unit_code IS NOT NULL
     ORDER BY generation_unit_code, valid_from DESC NULLS LAST,
              generation_unit_installed_capacity_mw DESC NULLS LAST)
    UNION ALL
    (SELECT DISTINCT ON (production_unit_code)
            production_unit_code AS code,
            production_unit_installed_capacity_mw AS cap
     FROM entsoe.production_and_generation_units
     WHERE area_map_code = 'GR' AND production_unit_code IS NOT NULL
     ORDER BY production_unit_code, valid_from DESC NULLS LAST,
              production_unit_installed_capacity_mw DESC NULLS LAST)
  ) u GROUP BY code
),
-- one row per (asset, day): expand each outage over its days (LATERAL is fast),
-- keep the most conservative (min available => max derate) per unit-day.
outage_unit_day AS (
  SELECT u.asset_code,
         gs.day::date               AS day,
         MIN(u.available_capacity_mw) AS avail_min,
         MAX(f.cap)                   AS cap
  FROM entsoe.unavailability_of_production_and_generation_units u
  LEFT JOIN fleet f ON f.code = u.asset_code
  CROSS JOIN LATERAL generate_series(
        (u.start_outage_utc)::timestamp::date,
        (u.end_outage_utc)::timestamp::date, '1 day') gs(day)
  WHERE u.area_map_code = 'GR' AND u.status = 'Active'
    AND gs.day::date BETWEEN '2022-01-01' AND '2026-06-30'
  GROUP BY u.asset_code, gs.day
),
outage_day AS (
  SELECT day,
         SUM(GREATEST(COALESCE(cap,0) - COALESCE(avail_min,0), 0)) AS outage_mw
  FROM outage_unit_day
  GROUP BY day
)
-- ------------------------------------------------------------------ assemble
SELECT
  dd.day,
  a.avg_actual_price,
  s.avg_sim_price,
  (a.avg_actual_price - s.avg_sim_price)          AS residual,
  COALESCE(dk.dark_mw, 0)                          AS dark_mw,
  COALESCE(dk.dark_mw_all, 0)                      AS dark_mw_all,
  nd.peak_net_demand,
  nd.res_share,
  tt.ttf_dm1,
  tt.ttf_change_5d,
  eu.eua_dm1,
  rv.reservoir_pct,
  rv.reservoir_deviation,
  COALESCE(od.outage_mw, 0)                        AS outage_mw,
  (dd.day BETWEEN '2022-07-01' AND '2022-12-31')  AS regulated_dummy,
  EXTRACT(isodow FROM dd.day)::int                 AS weekday,
  EXTRACT(month  FROM dd.day)::int                 AS month,
  EXTRACT(year   FROM dd.day)::int                 AS year
FROM days dd
LEFT JOIN actual        a  ON a.day  = dd.day
LEFT JOIN sim           s  ON s.day  = dd.day
LEFT JOIN dark          dk ON dk.day = dd.day
LEFT JOIN netdem_daily  nd ON nd.day = dd.day
LEFT JOIN ttf_day       tt ON tt.day = dd.day
LEFT JOIN eua_day       eu ON eu.day = dd.day
LEFT JOIN reservoir_day rv ON rv.day = dd.day
LEFT JOIN outage_day    od ON od.day = dd.day
ORDER BY dd.day;

CREATE INDEX ON simulations.phase_b_daily (day);
