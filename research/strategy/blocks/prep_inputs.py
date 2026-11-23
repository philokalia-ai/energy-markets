#!/usr/bin/env python3
"""st-blocks: per-day inputs for the order-format study (read-only on the live DuckDB extract).

usage: ~/armada/em-team/venv-ops431/bin/python -I prep_inputs.py DAYS.txt OUTDIR [--dev-forecast RUNDIR]

Writes, per UTC day D (the record pipeline's day = 24 UTC hours):
  OUTDIR/inputs/D.json   — EX-ANTE inputs (usable by a strategy):
      ttf, eua: last close with date < D-1 (= D-2's close; the repo's cv34 gate rule,
                src/generators/fuel_costs.jl `_gate_lag_days`, TTF ≤ 10 days back, EUA ≤ 10 days back);
      solar_fc[zone][24], load_fc[zone][24]: ENTSO-E D-1 day-ahead forecasts, hourly means (MW);
      dev_forecast[zone][24] (only with --dev-forecast): cv46 A-arm prices, DEVELOPMENT ONLY.
  OUTDIR/realised/D.json — SCORING ONLY (never read by a constructor):
      hourly[zone][24]: SDAC hourly actuals, bin/da_target.py target="sdac" (same as the cv46 scorer);
      q15[zone][96]:    native SDAC PT15M quarters (the scorer's quarter rule), where complete.
"""
import argparse, datetime as dt, json, os, sys

import duckdb
import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "bin"))
import da_target  # noqa: E402

DB = os.path.expanduser("~/armada/em-data/euphemia-live-20261115.duckdb")
STUDY = ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]


def close_before(con, table, day, lookback=10):
    cut = day - dt.timedelta(days=1)  # date < D-1
    r = con.execute(f"SELECT date, close FROM yfinance.{table} WHERE date < ? AND date > ? AND close IS NOT NULL "
                    "ORDER BY date DESC LIMIT 1", [cut, day - dt.timedelta(days=lookback + 1)]).fetchone()
    return (None, None) if r is None else (float(r[1]), str(r[0])[:10])


def fc_hourly(con, table, col, day, extra=""):
    t0, t1 = dt.datetime.combine(day, dt.time()), dt.datetime.combine(day + dt.timedelta(days=1), dt.time())
    df = con.execute(f"""SELECT area_map_code z, date_time_utc t, max(update_time_utc) u, arg_max({col}, update_time_utc) v
        FROM entsoe.{table} WHERE date_time_utc >= ? AND date_time_utc < ? AND area_type_code LIKE 'BZN%' {extra}
        GROUP BY 1, 2""", [t0, t1]).df()
    out = {}
    for z, g in df.groupby("z"):
        g = g.dropna(subset=["v"])
        h = g.groupby(pd.to_datetime(g.t).dt.hour).v.mean()
        if len(h) == 24:
            out[z] = [float(h[i]) for i in range(24)]
    return out


def quarters(con, t0, t1):
    raw = da_target._norm(da_target.raw_rows(con, t0, t1))
    smap = da_target.auction_map(raw)
    want = smap[smap.how != "ambiguous"][["z", "seq"]]
    k = raw.merge(want, on=["z", "seq"])
    k = k[(k.res == "PT15M") & (k.t.dt.minute % 15 == 0) & (k.t.dt.second == 0)]
    k = k.sort_values(["z", "t", "u", "p"], na_position="first", kind="mergesort").drop_duplicates(["z", "t"], keep="last")
    return k


def dev_prices(rundir, day):
    p = os.path.join(rundir, "db", f"{day}.duckdb")
    if not os.path.exists(p):
        return None
    c = duckdb.connect(p, read_only=True)
    df = c.execute("SELECT bidding_zone z, date_time_utc t, avg(price_eur_mwh) p FROM simulations.energy_prices "
                   "WHERE resolution_code='1H' GROUP BY 1, 2").df()
    c.close()
    out = {}
    for z, g in df.groupby("z"):
        h = g.groupby(pd.to_datetime(g.t).dt.hour).p.mean()
        if len(h) == 24:
            out[z] = [float(h[i]) for i in range(24)]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("days"); ap.add_argument("out"); ap.add_argument("--dev-forecast")
    a = ap.parse_args()
    days = [dt.date.fromisoformat(l.strip()) for l in open(a.days) if l.strip() and not l.startswith("#")]
    os.makedirs(os.path.join(a.out, "inputs"), exist_ok=True)
    os.makedirs(os.path.join(a.out, "realised"), exist_ok=True)
    con = duckdb.connect(DB, read_only=True)
    for d in days:
        t0, t1 = dt.datetime.combine(d, dt.time()), dt.datetime.combine(d + dt.timedelta(days=1), dt.time())
        ttf, ttf_d = close_before(con, "ttf_f", d)
        eua, eua_d = close_before(con, "eua_co2", d)
        inp = {"day": str(d), "ttf": ttf, "ttf_date": ttf_d, "eua": eua, "eua_date": eua_d,
               "solar_fc": fc_hourly(con, "generation_forecasts_for_wind_and_solar", "day_ahead_generation_forecast_mw", d,
                                     "AND production_type = 'Solar'"),
               "load_fc": fc_hourly(con, "day_ahead_total_load_forecast", "total_load_mw", d)}
        # A zone whose D forecast is missing takes the latest earlier day's forecast (≤ 10 days back; that one
        # was published before D's gate too). Recorded in *_src.
        for key, tab, col, ex in (("solar_fc", "generation_forecasts_for_wind_and_solar", "day_ahead_generation_forecast_mw",
                                   "AND production_type = 'Solar'"),
                                  ("load_fc", "day_ahead_total_load_forecast", "total_load_mw", "")):
            src = {}
            for z in STUDY:
                if z in inp[key]:
                    continue
                for k in range(1, 11):
                    f = fc_hourly(con, tab, col, d - dt.timedelta(days=k), ex)
                    if z in f:
                        inp[key][z] = f[z]; src[z] = str(d - dt.timedelta(days=k)); break
            inp[key + "_src"] = src
        # PV capacity proxy: the zone's max hourly D-1 solar forecast over the 365 days before D (ex-ante)
        pk = con.execute("""SELECT area_map_code z, max(v) FROM (SELECT area_map_code, date_trunc('hour', date_time_utc) h,
            avg(day_ahead_generation_forecast_mw) v FROM entsoe.generation_forecasts_for_wind_and_solar
            WHERE production_type = 'Solar' AND area_type_code LIKE 'BZN%' AND date_time_utc >= ? AND date_time_utc < ?
            GROUP BY 1, 2) GROUP BY 1""", [t0 - dt.timedelta(days=365), t0]).fetchall()
        inp["solar_peak365"] = {z: float(v) for z, v in pk if z in STUDY and v is not None}
        if a.dev_forecast:
            inp["dev_forecast"] = dev_prices(a.dev_forecast, d)
            inp["dev_forecast_note"] = "cv46 A-arm prices: DEVELOPMENT ONLY, never reported"
        json.dump(inp, open(os.path.join(a.out, "inputs", f"{d}.json"), "w"))
        ha = da_target.hourly_actuals(con, t0, t1, target="sdac")
        zc = "z" if "z" in ha.columns else "zone"
        hourly = {}
        for z, g in ha.groupby(zc):
            s = g.set_index(pd.to_datetime(g.t).dt.hour)[g.columns[-1]]
            if len(s) == 24:
                hourly[z] = [float(s[i]) for i in range(24)]
        q15 = {}
        for z, g in quarters(con, t0, t1).groupby("z"):
            idx = (g.t.dt.hour * 4 + g.t.dt.minute // 15).to_numpy()
            if len(idx) == 96 and len(set(idx)) == 96:
                v = np.empty(96); v[idx] = g.p.to_numpy(); q15[z] = v.tolist()
        json.dump({"day": str(d), "hourly": hourly, "q15": q15,
                   "note": "SCORING ONLY: realised SDAC prices of D; never an input to a strategy"},
                  open(os.path.join(a.out, "realised", f"{d}.json"), "w"))
        miss = [z for z in STUDY if z not in hourly]
        print(f"{d} ttf={ttf}({ttf_d}) eua={eua}({eua_d}) zones_h={len(hourly)} zones_q={len(q15)} "
              f"solar={sorted(inp['solar_fc'].keys() & set(STUDY))} missing_study={miss}", flush=True)


if __name__ == "__main__":
    main()
