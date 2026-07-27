using Euphemia, CSV, DataFrames, Dates
D = "docs/experiments/norwegian-hydro/data"
zones = ["NO1","NO2","NO3","NO4","NO5","SE1","SE2","SE3","SE4","DE_LU","NL","DK1"]
lo = Date(2025,7,25); hi = Date(2026,7,25)  # [lo, hi)

# 1. simulated cv22 (multi_zone_eu)
sim = Euphemia.sql2df_with_retry("""
  SELECT to_char(date_time_utc AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:00') slot,
         bidding_zone zone, price_eur_mwh price
  FROM simulations.energy_prices
  WHERE clearing_mode='multi_zone_eu' AND code_version=22 AND order_method='merit_order'
    AND bidding_zone = ANY(\$1)
    AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
    AND date_time_utc <  (\$3::date::timestamp AT TIME ZONE 'UTC')
""", [zones, lo, hi])
CSV.write("$D/sim_cv22.csv", sim); println("sim_cv22 ", nrow(sim))

# 1b. simulated cv19 (NO zones + SE, overlap window only up to 2026-06-30)
sim19 = Euphemia.sql2df_with_retry("""
  SELECT to_char(date_time_utc AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:00') slot,
         bidding_zone zone, price_eur_mwh price
  FROM simulations.energy_prices
  WHERE clearing_mode='multi_zone_eu' AND code_version=19 AND order_method='merit_order'
    AND bidding_zone = ANY(\$1)
    AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
    AND date_time_utc <  (\$3::date::timestamp AT TIME ZONE 'UTC')
""", [["NO1","NO2","NO3","NO4","NO5","SE1","SE2","SE3","SE4"], lo, hi])
CSV.write("$D/sim_cv19.csv", sim19); println("sim_cv19 ", nrow(sim19))

# 2. realized day-ahead
act = Euphemia.sql2df_with_retry("""
  SELECT to_char(date_time_utc AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:00') slot,
         map_code zone, AVG(price_currency_mwh) price
  FROM entsoe.energy_prices
  WHERE contract_type='Day-ahead' AND map_code = ANY(\$1)
    AND price_currency_mwh IS NOT NULL
    AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
    AND date_time_utc <  (\$3::date::timestamp AT TIME ZONE 'UTC')
  GROUP BY 1,2
""", [zones, lo, hi])
CSV.write("$D/actual.csv", act); println("actual ", nrow(act))

# 3. reservoir filling (weekly, full history, small)
res = Euphemia.sql2df_with_retry("""
  SELECT area_map_code zone, year, week, stored_energy_mwh
  FROM entsoe.aggregated_hydro_storage_filling_rate
  WHERE area_map_code = ANY(\$1) AND area_type_code LIKE 'BZN%'
    AND stored_energy_mwh IS NOT NULL
""", [["NO1","NO2","NO3","NO4","NO5","SE1","SE2","SE3","SE4"]])
CSV.write("$D/reservoir.csv", res); println("reservoir ", nrow(res))

# 4. daily net imports per NO zone (avg MW over day), from physical flows
flows = Euphemia.sql2df_with_retry("""
  WITH b AS (
    SELECT (date_time_utc AT TIME ZONE 'UTC')::date d,
           EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int h,
           in_area_map_code inc, out_area_map_code outc, AVG(flow_mw) f
    FROM entsoe.physical_flows
    WHERE in_area_type_code LIKE 'BZN%' AND out_area_type_code LIKE 'BZN%'
      AND (in_area_map_code = ANY(\$1) OR out_area_map_code = ANY(\$1))
      AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
      AND date_time_utc <  (\$3::date::timestamp AT TIME ZONE 'UTC')
    GROUP BY 1,2,in_area_map_code,out_area_map_code
  )
  SELECT d, zone, AVG(net) net_mw FROM (
    SELECT d, h, inc zone, SUM(f) net FROM b WHERE inc = ANY(\$1) GROUP BY d,h,inc
    UNION ALL
    SELECT d, h, outc zone, -SUM(f) net FROM b WHERE outc = ANY(\$1) GROUP BY d,h,outc
  ) x GROUP BY d, zone
""", [["NO1","NO2","NO3","NO4","NO5"], lo, hi])
CSV.write("$D/flows_daily.csv", flows); println("flows_daily ", nrow(flows))
println("DONE")
