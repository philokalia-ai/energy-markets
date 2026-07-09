-- 3-case accuracy comparison vs realised ENTSO-E day-ahead prices.
-- Hourly comparison over 2026-04-01..2026-04-14. All series aggregated to
-- hourly means (sim multi_zone* already hourly; single_zone & realised 15-min).
WITH cases(zone, cm) AS (VALUES
  ('GR','single_zone'), ('GR','multi_zone'), ('GR','multi_zone_eu'),
  ('BG','multi_zone'),  ('BG','multi_zone_eu'),
  ('RO','multi_zone'),  ('RO','multi_zone_eu'),
  ('IT-SOUTH','multi_zone_eu'),
  ('FR','multi_zone_eu'),
  ('DE_LU','multi_zone_eu')
),
sim AS (
  SELECT c.zone, c.cm,
         date_trunc('hour', ep.date_time_utc AT TIME ZONE 'UTC') AS h,
         avg(ep.price_eur_mwh) AS p
  FROM cases c
  JOIN simulations.energy_prices ep
    ON ep.bidding_zone = c.zone AND ep.clearing_mode = c.cm
   AND ep.order_method = 'merit_order' AND ep.code_version = 10
   AND ep.date_time_utc >= '2026-04-01' AND ep.date_time_utc < '2026-04-15'
  GROUP BY 1,2,3
),
realp AS (
  SELECT map_code AS zone,
         date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS h,
         avg(price_currency_mwh) AS p
  FROM entsoe.energy_prices
  WHERE contract_type = 'Day-ahead'
    AND date_time_utc >= '2026-04-01' AND date_time_utc < '2026-04-15'
  GROUP BY 1,2
)
SELECT sim.zone, sim.cm AS clearing_mode, count(*) AS n_hours,
       round(avg(sim.p)::numeric,1)          AS sim_mean,
       round(avg(r.p)::numeric,1)            AS real_mean,
       round(avg(abs(sim.p-r.p))::numeric,1) AS mae,
       round(avg(sim.p-r.p)::numeric,1)      AS bias,
       round(corr(sim.p, r.p)::numeric,3)    AS correlation
FROM sim JOIN realp r ON r.zone = sim.zone AND r.h = sim.h
GROUP BY 1,2
ORDER BY 1,2;
