-- load_weighted_price_delta.sql — compare two scenario runs, weighted by load.
--
-- Given two clearing_mode labels (a baseline and a scenario), a bidding zone
-- and a half-open date window [start, end), returns per calendar year and as a
-- TOTAL row:
--   * the load-weighted average price of each run (EUR/MWh),
--   * the load-weighted average price DELTA (EUR/MWh) — "how much more people
--     pay per MWh", weighted by the BASELINE-window load,
--   * the extra cost over the window, sum(load_h * delta_price_h), in EUR m,
--   * the same, annualized (scaled to 8760 h), in EUR m.
--
-- WEIGHTS: the model's own demand series — the hourly average of
-- entsoe.day_ahead_total_load_forecast (BZN-type area codes), i.e. the
-- UNMODIFIED baseline load. Scenario-added MW (data center, ships) is
-- deliberately NOT in the weight: the delta answers what the pre-existing
-- demand pays extra, and both runs are weighted by the same series so the
-- delta of the weighted averages equals the weighted average of the deltas.
--
-- Prices and load are both averaged to the hour before joining, so 15/30/60-min
-- resolutions mix safely. Only hours present in BOTH runs (and with load data)
-- are counted; if reruns left multiple code_versions per hour they are averaged
-- — filter code_version explicitly if you need to pin one.
--
-- DIALECT/SCHEMA: DuckDB, offline layout — the source extract ATTACHed as
-- `src` (READ_ONLY) and the results DB (data/results.duckdb) ATTACHed as
-- `results_db`. Run it via the wrapper:
--
--   julia --project=. bin/scenario_delta.jl <baseline_label> <scenario_label> \
--       <zone> <start_date> <end_date_exclusive> [extract.duckdb] [results.duckdb]
--   e.g.
--   julia --project=. bin/scenario_delta.jl gr_scn_base gr_scn_dc574 GR 2025-07-01 2026-07-01
--
-- Parameters (positional):
--   $1 zone            e.g. 'GR'
--   $2 baseline label  e.g. 'gr_scn_base'
--   $3 scenario label  e.g. 'gr_scn_dc574'
--   $4 window start    DATE, inclusive
--   $5 window end      DATE, exclusive

WITH px AS (
    SELECT date_trunc('hour', date_time_utc) AS h,
           clearing_mode,
           AVG(price_eur_mwh)               AS p
    FROM results_db.simulations.energy_prices
    WHERE bidding_zone = $1
      AND clearing_mode IN ($2, $3)
      AND date_time_utc >= CAST($4 AS DATE)
      AND date_time_utc <  CAST($5 AS DATE)
    GROUP BY 1, 2
),
ld AS (
    SELECT date_trunc('hour', date_time_utc) AS h,
           AVG(total_load_mw)               AS load_mw
    FROM src.entsoe.day_ahead_total_load_forecast
    WHERE area_map_code = $1
      AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
      AND date_time_utc >= CAST($4 AS DATE)
      AND date_time_utc <  CAST($5 AS DATE)
    GROUP BY 1
),
hours AS (
    SELECT b.h, b.p AS p_base, s.p AS p_scn, l.load_mw
    FROM      (SELECT h, p FROM px WHERE clearing_mode = $2) b
    JOIN      (SELECT h, p FROM px WHERE clearing_mode = $3) s USING (h)
    JOIN ld l USING (h)
)
SELECT
    COALESCE(CAST(CAST(EXTRACT(year FROM h) AS INT) AS VARCHAR), 'TOTAL') AS period,
    COUNT(*)                                                    AS hours,
    ROUND(SUM(load_mw * p_base) / SUM(load_mw), 3)              AS lw_price_base_eur_mwh,
    ROUND(SUM(load_mw * p_scn)  / SUM(load_mw), 3)              AS lw_price_scenario_eur_mwh,
    ROUND(SUM(load_mw * (p_scn - p_base)) / SUM(load_mw), 3)    AS lw_delta_eur_mwh,
    ROUND(SUM(load_mw * (p_scn - p_base)) / 1e6, 2)             AS extra_cost_window_meur,
    ROUND(SUM(load_mw * (p_scn - p_base)) / 1e6 * 8760.0 / COUNT(*), 2)
                                                                AS extra_cost_annualized_meur
FROM hours
GROUP BY GROUPING SETS ((EXTRACT(year FROM h)), ())
ORDER BY period;
