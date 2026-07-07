-- Phase B — Analysis D support table: simulations.phase_b_firm_dark
-- Firm x day panel of dark_share for GR firms with >= 2 mapped units.
--
-- dark_share(f,d) = (sum of strong unfiled-dark p_max for firm f on day d)
--                   / (firm f mapped installed capacity)
-- Days with no dark units for a firm get dark_share = 0 (firm was fully offered
-- or simply not withholding). Panel spans 2022-01-01 .. 2026-06-30.
--
-- Firm mapped capacity = sum of installed cap over the firm's units that match
-- the deduped GR generation fleet. Firms restricted to >= 2 mapped units, and
-- excluding the 'unknown' bucket (not a real firm).
--
-- Reproducible: DROP + CREATE + INSERT. Safe to re-run.

DROP TABLE IF EXISTS simulations.phase_b_firm_dark;

CREATE TABLE simulations.phase_b_firm_dark AS
WITH
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
firm_cap AS (   -- firms with >= 2 mapped units (exclude 'unknown')
  SELECT uf.firm, COUNT(*) AS n_units, SUM(f.cap) AS firm_capacity
  FROM simulations.unit_firms uf
  JOIN fleet f ON f.code = uf.unit_code
  WHERE uf.zone = 'GR' AND uf.firm <> 'unknown'
  GROUP BY uf.firm
  HAVING COUNT(*) >= 2
),
days AS (
  SELECT d::date AS day
  FROM generate_series('2022-01-01'::date,'2026-06-30'::date,'1 day') d
),
firm_day AS (
  SELECT fc.firm, d.day, fc.firm_capacity
  FROM firm_cap fc CROSS JOIN days d
),
dark_fd AS (   -- strong dark MW per firm-day
  SELECT uf.firm, du.day, SUM(du.p_max) AS dark_mw
  FROM simulations.unfiled_dark_units du
  JOIN simulations.unit_firms uf ON uf.zone = du.zone AND uf.unit_code = du.unit_code
  WHERE du.zone = 'GR' AND du.strong AND uf.firm <> 'unknown'
  GROUP BY uf.firm, du.day
)
SELECT fd.firm, fd.day,
       COALESCE(dk.dark_mw, 0)                         AS dark_mw,
       fd.firm_capacity,
       COALESCE(dk.dark_mw, 0) / fd.firm_capacity      AS dark_share
FROM firm_day fd
LEFT JOIN dark_fd dk ON dk.firm = fd.firm AND dk.day = fd.day
ORDER BY fd.firm, fd.day;

CREATE INDEX ON simulations.phase_b_firm_dark (firm, day);
