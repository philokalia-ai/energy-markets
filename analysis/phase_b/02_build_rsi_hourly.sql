-- Phase B — Analysis B support table: simulations.rsi_hourly
-- Hourly Residual Supplier Index for GR, 2022-01-01 .. 2026-06-30.
--
-- RSI_firm(h) = (total_available(day) - firm_available(day) + max(net_import(h),0))
--               / net_demand(h)
-- Computed for PPC (the GR incumbent). RSI < 1 => firm is pivotal.
--
-- Universe conventions (documented in docs/phase-b-analysis.md):
--   total_available = full GR generation fleet (DISTINCT ON generation_unit_code)
--     with each unit reduced to its Active-outage available_capacity_mw that day
--     (MIN per unit-day = most conservative; clamped to [0, installed]).
--   firm_available  = PPC-mapped units (simulations.unit_firms) under the same rule.
--   Outages matched asset_code = generation_unit_code (project convention); a
--   handful of production-level-only outages are not applied (minor undercount).
--   net_import(h)   = physical_flows GR imports - exports, per-hour AVG per raw
--     border, counterparties normalised by alpha prefix (IT/IT-SOUTH/IT_GR/..->IT,
--     strips any _IPS-style suffix), one row per (hour,counterparty,dir) keeping
--     the larger |flow|, then summed with sign.
--
-- Reproducible: DROP + CREATE + INSERT. Safe to re-run.

DROP TABLE IF EXISTS simulations.rsi_hourly;

CREATE TABLE simulations.rsi_hourly AS
WITH
-- ------------------------------------------------------- full GR fleet (deduped)
fleet AS (
  SELECT DISTINCT ON (generation_unit_code)
         generation_unit_code AS code,
         generation_unit_installed_capacity_mw AS cap
  FROM entsoe.production_and_generation_units
  WHERE area_map_code = 'GR' AND generation_unit_code IS NOT NULL
    AND generation_unit_installed_capacity_mw IS NOT NULL
  ORDER BY generation_unit_code, valid_from DESC NULLS LAST,
           generation_unit_installed_capacity_mw DESC NULLS LAST
),
-- ------------------------------------- Active-outage available cap per unit-day
outage_ud AS (
  SELECT u.asset_code AS code, gs.day::date AS day,
         MIN(u.available_capacity_mw) AS avail_out
  FROM entsoe.unavailability_of_production_and_generation_units u
  CROSS JOIN LATERAL generate_series(
        (u.start_outage_utc)::timestamp::date,
        (u.end_outage_utc)::timestamp::date, '1 day') gs(day)
  WHERE u.area_map_code = 'GR' AND u.status = 'Active'
    AND gs.day::date BETWEEN '2022-01-01' AND '2026-06-30'
  GROUP BY u.asset_code, gs.day
),
-- ------------------------------------------- per unit-day available capacity
unit_avail AS (
  SELECT d.day, f.code,
         CASE WHEN o.avail_out IS NULL THEN f.cap
              ELSE LEAST(f.cap, GREATEST(o.avail_out, 0)) END AS avail,
         f.cap
  FROM (SELECT generate_series('2022-01-01'::date,'2026-06-30'::date,'1 day')::date AS day) d
  CROSS JOIN fleet f
  LEFT JOIN outage_ud o ON o.code = f.code AND o.day = d.day
),
ppc_units AS (
  SELECT unit_code AS code FROM simulations.unit_firms
  WHERE zone = 'GR' AND firm = 'PPC'
),
avail_daily AS (
  SELECT day,
         SUM(avail)                                             AS total_available,
         SUM(avail) FILTER (WHERE code IN (SELECT code FROM ppc_units)) AS ppc_available
  FROM unit_avail
  GROUP BY day
),
-- --------------------------------------------- hourly net demand (load - RES)
load_h AS (
  SELECT date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS hour_utc,
         AVG(total_load_mw) AS load_mw
  FROM entsoe.day_ahead_total_load_forecast
  WHERE area_map_code = 'GR'
    AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
    AND (date_time_utc AT TIME ZONE 'UTC')::date BETWEEN '2022-01-01' AND '2026-06-30'
  GROUP BY 1
),
res_h AS (
  SELECT hour_utc, SUM(res_mw) AS res_mw FROM (
    SELECT date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS hour_utc,
           production_type, AVG(day_ahead_generation_forecast_mw) AS res_mw
    FROM entsoe.generation_forecasts_for_wind_and_solar
    WHERE area_map_code = 'GR'
      AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
      AND (date_time_utc AT TIME ZONE 'UTC')::date BETWEEN '2022-01-01' AND '2026-06-30'
    GROUP BY 1,2
  ) s GROUP BY hour_utc
),
netdem_h AS (
  SELECT l.hour_utc, l.load_mw - COALESCE(r.res_mw,0) AS net_demand_mw
  FROM load_h l LEFT JOIN res_h r USING (hour_utc)
),
-- --------------------------------------------------- hourly net imports (GR)
flow_raw AS (
  SELECT date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS hour_utc,
         CASE WHEN out_area_map_code='GR' THEN 'export' ELSE 'import' END AS dir,
         CASE WHEN out_area_map_code='GR' THEN in_area_map_code
              ELSE out_area_map_code END AS raw_cp,
         AVG(flow_mw) AS flow_mw
  FROM entsoe.physical_flows
  WHERE (out_area_map_code='GR' OR in_area_map_code='GR')
    AND (date_time_utc AT TIME ZONE 'UTC')::date BETWEEN '2022-01-01' AND '2026-06-30'
  GROUP BY 1,2,3
),
flow_dedup AS (
  SELECT DISTINCT ON (hour_utc, dir, substring(raw_cp from '^[A-Za-z]+'))
         hour_utc, dir,
         substring(raw_cp from '^[A-Za-z]+') AS cp, flow_mw
  FROM flow_raw
  ORDER BY hour_utc, dir, substring(raw_cp from '^[A-Za-z]+'), abs(flow_mw) DESC
),
net_import_h AS (
  SELECT hour_utc,
         SUM(CASE WHEN dir='import' THEN flow_mw ELSE -flow_mw END) AS net_import_mw
  FROM flow_dedup GROUP BY hour_utc
),
-- ------------------------------------------------- hourly actual & sim prices
act_h AS (
  SELECT date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS hour_utc,
         AVG(price_currency_mwh) AS act_price
  FROM entsoe.energy_prices
  WHERE map_code='GR' AND contract_type='Day-ahead'
    AND (date_time_utc AT TIME ZONE 'UTC')::date BETWEEN '2022-01-01' AND '2026-06-30'
  GROUP BY 1
),
sim_h AS (
  SELECT date_trunc('hour', date_time_utc) AS hour_utc,
         AVG(price_eur_mwh) AS sim_price
  FROM simulations.energy_prices
  WHERE bidding_zone='GR' AND code_version=10 AND order_method='merit_order'
    AND clearing_mode='multi_zone'
    AND date_time_utc::date BETWEEN '2022-01-01' AND '2026-06-30'
  GROUP BY 1
)
-- ------------------------------------------------------------------ assemble
SELECT
  nd.hour_utc,
  nd.hour_utc::date                                   AS day,
  nd.net_demand_mw,
  COALESCE(ni.net_import_mw, 0)                       AS net_import_mw,
  ad.total_available,
  ad.ppc_available,
  CASE WHEN nd.net_demand_mw > 0
       THEN (ad.total_available - ad.ppc_available
             + GREATEST(COALESCE(ni.net_import_mw,0),0)) / nd.net_demand_mw
  END                                                 AS rsi_ppc,
  ah.act_price,
  sh.sim_price,
  (ah.act_price - sh.sim_price)                       AS residual
FROM netdem_h nd
LEFT JOIN net_import_h ni ON ni.hour_utc = nd.hour_utc
LEFT JOIN avail_daily  ad ON ad.day = nd.hour_utc::date
LEFT JOIN act_h        ah ON ah.hour_utc = nd.hour_utc
LEFT JOIN sim_h        sh ON sh.hour_utc = nd.hour_utc
ORDER BY nd.hour_utc;

CREATE INDEX ON simulations.rsi_hourly (hour_utc);
CREATE INDEX ON simulations.rsi_hourly (day);
