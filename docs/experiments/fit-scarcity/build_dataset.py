#!/usr/bin/env python3
"""Build the fit-scarcity dataset: hourly markup y = P_actual / SRMC_gas plus
D-1-legal-ish features for GR, BG, ES, DE_LU.

Reads ONLY the read-only DuckDB extract. Writes dataset.tsv.gz in this dir.

Conventions (mirroring src/generators/fuel_costs.jl and src/merit_order/book_build.jl):
  SRMC_gas(day) = TTF_close(last trading day < day) / 0.55
                + 0.202/0.55 * EUA_close(last trading day < day) + 2.0
  d_hat         = within-day min-max normalized net demand (D-1 forecasts)
  margin proxy  = sum over dispatchable types of trailing-30-day p95 of hourly
                  actual generation (window ending the day BEFORE the market
                  day, D-1 legal) / (load_fc - res_fc - net_imports)
                  where net_imports are OBSERVED physical flows (deliberately
                  ex-post: isolates the markup-form question from the flow
                  assumption).
"""
import duckdb
import numpy as np
import pandas as pd

DB = "/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
ZONES = ["GR", "BG", "ES", "DE_LU"]
# Data pull starts early enough for the 30-day trailing p95 warmup.
PULL_START = "2023-05-15"
SAMPLE_START = "2023-07-01"
SAMPLE_END = "2026-06-30"  # inclusive

DISPATCHABLE_TYPES = (
    "Fossil Gas", "Fossil Hard coal", "Fossil Brown coal/Lignite",
    "Fossil Oil", "Fossil Oil shale", "Fossil Peat", "Fossil Coal-derived gas",
    "Nuclear", "Biomass", "Waste", "Other",
    "Hydro Water Reservoir", "Hydro Pumped Storage",
    "Hydro Run-of-river and pondage", "Geothermal", "Energy storage",
)

con = duckdb.connect(DB, read_only=True)
zl = ",".join(f"'{z}'" for z in ZONES)
tl = ",".join(f"'{t}'" for t in DISPATCHABLE_TYPES)

# ---------------------------------------------------------------- prices -----
# Dedup: one row per (map_code, timestamp) by highest sequence then latest
# update_time_utc; Day-ahead only; BZN; then average sub-hourly to hourly.
prices = con.execute(f"""
    WITH dedup AS (
        SELECT map_code AS zone, date_time_utc, price_currency_mwh AS price,
               ROW_NUMBER() OVER (PARTITION BY map_code, date_time_utc
                   ORDER BY sequence DESC, update_time_utc DESC) AS rn
        FROM entsoe.energy_prices
        WHERE map_code IN ({zl}) AND contract_type = 'Day-ahead'
          AND area_type_code LIKE 'BZN%'
          AND date_time_utc >= TIMESTAMP '{PULL_START}'
          AND date_time_utc < TIMESTAMP '{SAMPLE_END}' + INTERVAL 2 DAY
    )
    SELECT zone, date_trunc('hour', date_time_utc) AS ts, AVG(price) AS price
    FROM dedup WHERE rn = 1 GROUP BY 1, 2 ORDER BY 1, 2
""").df()

# ------------------------------------------------------------- fuel costs ----
ttf = con.execute("SELECT date, close FROM yfinance.ttf_f ORDER BY date").df()
eua = con.execute("SELECT date, close FROM yfinance.eua_co2 ORDER BY date").df()

def last_close_before(df, days):
    """Close of the last trading day strictly before each day (no lookahead)."""
    s = df.set_index("date")["close"]
    out = pd.Series(index=days, dtype=float)
    for d in days:
        prior = s.loc[: pd.Timestamp(d) - pd.Timedelta(days=1)]
        out[d] = prior.iloc[-1] if len(prior) else np.nan
    return out

days = pd.date_range(PULL_START, pd.Timestamp(SAMPLE_END) + pd.Timedelta(days=1), freq="D")
ttf_by_day = last_close_before(ttf, days)
eua_by_day = last_close_before(eua, days)
srmc = ttf_by_day / 0.55 + 0.202 / 0.55 * eua_by_day + 2.0
srmc = srmc.rename("srmc_gas").rename_axis("day").reset_index()
srmc["ttf"] = ttf_by_day.values

# ---------------------------------------------------------- load forecast ----
load_fc = con.execute(f"""
    WITH dedup AS (
        SELECT area_map_code AS zone, date_time_utc, total_load_mw,
               ROW_NUMBER() OVER (PARTITION BY area_map_code, date_time_utc
                   ORDER BY update_time_utc DESC) AS rn
        FROM entsoe.day_ahead_total_load_forecast
        WHERE area_map_code IN ({zl}) AND area_type_code LIKE 'BZN%'
          AND date_time_utc >= TIMESTAMP '{PULL_START}'
          AND date_time_utc < TIMESTAMP '{SAMPLE_END}' + INTERVAL 2 DAY
    )
    SELECT zone, date_trunc('hour', date_time_utc) AS ts, AVG(total_load_mw) AS load_fc
    FROM dedup WHERE rn = 1 GROUP BY 1, 2
""").df()

# ----------------------------------------------------------- RES forecast ----
res_fc = con.execute(f"""
    WITH dedup AS (
        SELECT area_map_code AS zone, production_type, date_time_utc,
               day_ahead_generation_forecast_mw AS mw,
               ROW_NUMBER() OVER (PARTITION BY area_map_code, production_type, date_time_utc
                   ORDER BY update_time_utc DESC) AS rn
        FROM entsoe.generation_forecasts_for_wind_and_solar
        WHERE area_map_code IN ({zl}) AND area_type_code LIKE 'BZN%'
          AND date_time_utc >= TIMESTAMP '{PULL_START}'
          AND date_time_utc < TIMESTAMP '{SAMPLE_END}' + INTERVAL 2 DAY
    ),
    hourly AS (
        SELECT zone, production_type, date_trunc('hour', date_time_utc) AS ts,
               AVG(mw) AS mw
        FROM dedup WHERE rn = 1 AND mw IS NOT NULL GROUP BY 1, 2, 3
    )
    SELECT zone, ts, SUM(mw) AS res_fc FROM hourly GROUP BY 1, 2
""").df()

# ------------------------------------------------- observed net imports ------
net_imp = con.execute(f"""
    WITH dedup AS (
        SELECT out_area_map_code AS ozone, in_area_map_code AS izone,
               date_time_utc, flow_mw,
               ROW_NUMBER() OVER (
                   PARTITION BY out_area_code, in_area_code, date_time_utc
                   ORDER BY update_time_utc DESC) AS rn
        FROM entsoe.physical_flows
        WHERE (out_area_map_code IN ({zl}) OR in_area_map_code IN ({zl}))
          AND out_area_type_code LIKE 'BZN%' AND in_area_type_code LIKE 'BZN%'
          AND out_area_map_code <> in_area_map_code
          AND date_time_utc >= TIMESTAMP '{PULL_START}'
          AND date_time_utc < TIMESTAMP '{SAMPLE_END}' + INTERVAL 2 DAY
    ),
    hourly AS (
        SELECT ozone, izone, date_trunc('hour', date_time_utc) AS ts,
               AVG(flow_mw) AS mw
        FROM dedup WHERE rn = 1 GROUP BY 1, 2, 3
    ),
    imports AS (SELECT izone AS zone, ts, SUM(mw) AS mw FROM hourly
                WHERE izone IN ({zl}) GROUP BY 1, 2),
    exports AS (SELECT ozone AS zone, ts, SUM(mw) AS mw FROM hourly
                WHERE ozone IN ({zl}) GROUP BY 1, 2)
    SELECT COALESCE(i.zone, e.zone) AS zone, COALESCE(i.ts, e.ts) AS ts,
           COALESCE(i.mw, 0) - COALESCE(e.mw, 0) AS net_imports
    FROM imports i FULL OUTER JOIN exports e
      ON i.zone = e.zone AND i.ts = e.ts
""").df()

# ------------------------------- dispatchable capacity proxy (trailing p95) --
gen = con.execute(f"""
    SELECT area_map_code AS zone, production_type,
           date_trunc('hour', date_time_utc) AS ts,
           AVG(actual_generation_output_mw) AS mw
    FROM entsoe.aggregated_generation_per_type
    WHERE area_map_code IN ({zl}) AND area_type_code LIKE 'BZN%'
      AND production_type IN ({tl})
      AND actual_generation_output_mw IS NOT NULL
      AND date_time_utc >= TIMESTAMP '{PULL_START}'
      AND date_time_utc < TIMESTAMP '{SAMPLE_END}' + INTERVAL 2 DAY
    GROUP BY 1, 2, 3
""").df()

gen["day"] = gen["ts"].dt.floor("D")
# daily p95 per (zone, type), then trailing 30-day mean-of-... no: p95 over the
# trailing 30 days of HOURLY values. Compute per (zone,type,day) the p95 of the
# hourly values in the window [day-30, day-1] (D-1 legal: excludes market day).
p95_rows = []
for (zone, ptype), g in gen.groupby(["zone", "production_type"]):
    g = g.sort_values("ts").set_index("ts")
    # daily p95 shortcut is biased; do exact rolling on hourly series
    s = g["mw"]
    # rolling window of 30*24 hours, shifted by one day so the market day is excluded
    r = s.rolling("30D").quantile(0.95)
    daily = r.groupby(r.index.floor("D")).last()  # value at end of each day
    daily = daily.shift(1)  # p95 of window ending previous day -> D-1 legal
    p95_rows.append(pd.DataFrame({"zone": zone, "production_type": ptype,
                                  "day": daily.index, "p95": daily.values}))
p95 = pd.concat(p95_rows)
disp_cap = p95.groupby(["zone", "day"])["p95"].sum().rename("disp_cap").reset_index()

# ------------------------------------------------- reservoir filling rate ----
res_fill = con.execute(f"""
    SELECT area_map_code AS zone, year, week, AVG(stored_energy_mwh) AS stored
    FROM entsoe.aggregated_hydro_storage_filling_rate
    WHERE area_map_code IN ({zl})
    GROUP BY 1, 2, 3 ORDER BY 1, 2, 3
""").df()
# normalize per zone by trailing 104-week max -> filling fraction
res_fill["seq"] = res_fill["year"] * 53 + res_fill["week"]
res_fill = res_fill.sort_values(["zone", "seq"])
res_fill["fill_frac"] = res_fill.groupby("zone")["stored"].transform(
    lambda s: s / s.rolling(104, min_periods=10).max())

# ---------------------------------------------------------------- assemble ---
df = prices.merge(load_fc, on=["zone", "ts"], how="inner") \
           .merge(res_fc, on=["zone", "ts"], how="left")
df["res_fc"] = df["res_fc"].fillna(0.0)
df = df.merge(net_imp, on=["zone", "ts"], how="left")
df["net_imports"] = df["net_imports"].fillna(0.0)
df["day"] = df["ts"].dt.floor("D")
df = df.merge(disp_cap, on=["zone", "day"], how="left")
df = df.merge(srmc, on="day", how="left")

# reservoir: map hour -> ISO year/week
iso = df["ts"].dt.isocalendar()
df["year"], df["week"] = iso["year"].astype(int), iso["week"].astype(int)
df = df.merge(res_fill[["zone", "year", "week", "fill_frac"]],
              on=["zone", "year", "week"], how="left")
# forward-fill within zone by time (weekly reporting gaps)
df = df.sort_values(["zone", "ts"])
df["fill_frac"] = df.groupby("zone")["fill_frac"].ffill()

# derived features
df["net_demand"] = df["load_fc"] - df["res_fc"]
nd = df.groupby(["zone", "day"])["net_demand"]
df["d_hat"] = (df["net_demand"] - nd.transform("min")) / \
              (nd.transform("max") - nd.transform("min")).replace(0, np.nan)
resid = df["net_demand"] - df["net_imports"]
df["margin"] = df["disp_cap"] / resid.where(resid > 100.0)  # guard tiny/neg denom
df["res_share"] = df["res_fc"] / df["load_fc"].where(df["load_fc"] > 0)
df["imp_share"] = df["net_imports"] / df["load_fc"].where(df["load_fc"] > 0)
df["hour"] = df["ts"].dt.hour
df["dow"] = df["ts"].dt.dayofweek
df["y"] = df["price"] / df["srmc_gas"]

# sample window + completeness
df = df[(df["day"] >= SAMPLE_START) & (df["day"] <= SAMPLE_END)]
n0 = len(df)
df = df.dropna(subset=["price", "srmc_gas", "load_fc", "d_hat", "margin", "y"])
print(f"rows {n0} -> {len(df)} after dropna "
      f"({100 * (1 - len(df) / n0):.1f}% dropped)")
print(df.groupby("zone").agg(n=("y", "size"), y_med=("y", "median"),
                             margin_med=("margin", "median"),
                             price_med=("price", "median")))

cols = ["zone", "ts", "day", "hour", "dow", "price", "srmc_gas", "ttf", "y",
        "load_fc", "res_fc", "net_demand", "net_imports", "disp_cap",
        "margin", "d_hat", "res_share", "imp_share", "fill_frac"]
df[cols].to_csv("dataset.tsv.gz", sep="\t", index=False, compression="gzip")
print("wrote dataset.tsv.gz")
