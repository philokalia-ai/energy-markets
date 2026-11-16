"""Publication audit of the D-1 load/RES forecasts for DE_LU and GR (why the exogenous arm is dropped).

For each forecast row, D is its Europe/Athens market day (the pilot's day convention). The row
counts as pre-gate when update_time_utc <= D-1 10:00 UTC, the earliest SDAC gate (12:00 CEST).
Share per zone and calendar year of D. Reads the extract read-only.

Usage: python audit_vintages.py EXTRACT
"""
import sys

import duckdb

SQL = """
WITH r AS (
  SELECT area_map_code z, update_time_utc u,
         CAST(timezone('Europe/Athens', date_time_utc::TIMESTAMPTZ) AS DATE) d
  FROM {tab} WHERE area_map_code IN ('DE_LU', 'GR') {extra})
SELECT z, year(d) y, count(*) n,
       round(100 * avg(CASE WHEN u <= d - INTERVAL 1 DAY + INTERVAL 10 HOUR THEN 1 ELSE 0 END), 3) pct_pre_gate
FROM r GROUP BY 1, 2 ORDER BY 1, 2"""


def main(extract):
    c = duckdb.connect(extract, read_only=True)
    c.execute("SET TimeZone = 'UTC'")
    for name, tab, extra in (("load", "entsoe.day_ahead_total_load_forecast", ""),
                             ("RES", "entsoe.generation_forecasts_for_wind_and_solar",
                              "AND day_ahead_generation_forecast_mw IS NOT NULL")):
        print(f"== {name}: % of rows stamped <= D-1 10:00 UTC (D = Athens market day)")
        print(c.execute(SQL.format(tab=tab, extra=extra)).df().to_string(index=False))


if __name__ == "__main__":
    main(sys.argv[1])
