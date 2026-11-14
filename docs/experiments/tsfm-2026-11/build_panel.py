"""Build the hourly panel used by the TSFM experiments (read-only on the extract).

Output (outside the repo): $TSFM_OUT/panel.parquet with one row per (zone, UTC hour):
  price      settled day-ahead, resolution-aware hourly mean (highest `sequence` wins,
             tie-break latest update_time_utc) — same convention as test/scripts/eu_eval_metrics.jl
  load_fc    ENTSO-E day-ahead total load forecast, hourly mean
  load_upd   max(update_time_utc) of the load rows in that hour (publication audit)
  wind_fc    ENTSO-E day-ahead wind (onshore+offshore) forecast, hourly mean per type then summed
  solar_fc   ENTSO-E day-ahead solar forecast, hourly mean
  res_upd    max(update_time_utc) of the RES rows in that hour
and $TSFM_OUT/live_lead1.parquet: live published lead-1 rows (all input modes) from em-team/live/*.json.
"""
import json, os, glob
import duckdb, pandas as pd

DB = os.environ.get("EUPHEMIA_DUCKDB_PATH", "/home/pgeorgakopoulos/armada/em-data/euphemia-live-20261114.duckdb")
LIVE = os.environ.get("TSFM_LIVE", "/home/pgeorgakopoulos/armada/em-team/live")
OUT = os.environ.get("TSFM_OUT", "/home/pgeorgakopoulos/armada/em-team/results/tsfm")

zones = sorted(os.path.basename(p)[:-5] for p in glob.glob(f"{LIVE}/*.json"))
c = duckdb.connect(DB, read_only=True)
zl = ",".join(f"'{z}'" for z in zones)

price = c.execute(f"""
WITH d AS (
  SELECT map_code, date_time_utc, price_currency_mwh,
         row_number() OVER (PARTITION BY map_code, date_time_utc
            ORDER BY TRY_CAST(trim(sequence) AS INTEGER) DESC NULLS LAST, update_time_utc DESC) rn
  FROM entsoe.energy_prices
  WHERE contract_type='Day-ahead' AND area_type_code LIKE 'BZN%' AND price_currency_mwh IS NOT NULL
    AND map_code IN ({zl}))
SELECT map_code zone, date_trunc('hour', date_time_utc) t, avg(price_currency_mwh) price
FROM d WHERE rn=1 GROUP BY 1,2""").df()

load = c.execute(f"""
SELECT area_map_code zone, date_trunc('hour', date_time_utc) t, avg(total_load_mw) load_fc,
       max(update_time_utc) load_upd
FROM entsoe.day_ahead_total_load_forecast WHERE area_map_code IN ({zl}) GROUP BY 1,2""").df()

res = c.execute(f"""
WITH h AS (
  SELECT area_map_code zone, date_trunc('hour', date_time_utc) t, production_type pt,
         avg(day_ahead_generation_forecast_mw) mw, max(update_time_utc) upd
  FROM entsoe.generation_forecasts_for_wind_and_solar
  WHERE area_map_code IN ({zl}) AND day_ahead_generation_forecast_mw IS NOT NULL
  GROUP BY 1,2,3)
SELECT zone, t,
  sum(CASE WHEN pt LIKE 'Wind%' THEN mw END) wind_fc,
  sum(CASE WHEN pt='Solar' THEN mw END) solar_fc,
  max(upd) res_upd
FROM h GROUP BY 1,2""").df()

panel = price.merge(load, on=["zone", "t"], how="outer").merge(res, on=["zone", "t"], how="outer")
panel = panel.sort_values(["zone", "t"]).reset_index(drop=True)
panel.to_parquet(f"{OUT}/panel.parquet")
print("panel", panel.shape, panel.t.min(), panel.t.max())

rows = []
for z in zones:
    d = json.load(open(f"{LIVE}/{z}.json"))
    for day in d["days"]:
        if day["lead_days"] != 1:
            continue
        for i, h in enumerate(day["hours"]):
            rows.append(dict(zone=z, date=day["date"], input_mode=day["input_mode"],
                             code_version=day["code_version"], made=day["prediction_made_utc"],
                             t=pd.Timestamp(h).tz_localize(None), sim=day["sim"][i],
                             actual_json=day["actual"][i],
                             gbm=(day.get("gbm") or [None] * 24)[i], stats=(day.get("stats") or [None] * 24)[i]))
live = pd.DataFrame(rows)
live.to_parquet(f"{OUT}/live_lead1.parquet")
print("live", live.shape, live.input_mode.value_counts().to_dict())
