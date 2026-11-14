#!/usr/bin/env python3
"""Offline, rolling-origin P(hourly settled day-ahead price <= 0).

No database writes. The 06:30 variant uses calendar, settled prices through
D-1, and timestamp-filtered load forecasts (otherwise persistence). RES in
that variant is persistence from D-2 only, with the entire stored row last
updated before issuance. The 10:00 proxy uses latest-revision D-1 forecasts;
its RES vintage is unverifiable and its metrics are NOT a pre-gate claim.

Usage and feature contract: docs/experiments/collapse-2026-11/README.md.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from datetime import timedelta

import duckdb
import numpy as np
import pandas as pd
from scipy.special import expit
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score

ZONES = sorted("AT BE BG CZ DE_LU DK1 DK2 EE ES FI FR GR HU LT LV NL NO1 NO2 NO3 NO4 NO5 PL PT RO RS SE1 SE2 SE3 SE4 SI SK IT-NORTH IT-CNORTH IT-CSOUTH IT-SOUTH IT-Calabria IT-Sicily IT-Sardinia CH".split())
# Geographic trading neighbours, fixed before evaluation; no fitted weights.
EDGES = "AT:DE_LU,CH,CZ,HU,SI,IT-NORTH;BE:DE_LU,FR,NL;BG:GR,RO,RS;CZ:DE_LU,PL,SK;DE_LU:DK1,DK2,FR,NL,PL,SE4;DK1:DK2,NO2,SE3;DK2:SE4;EE:FI,LV;ES:FR,PT;FI:NO4,SE1,SE3;FR:CH,IT-NORTH;GR:IT-SOUTH;HU:HR,RO,RS,SK,SI;IT-NORTH:CH,SI,IT-CNORTH;IT-CNORTH:IT-CSOUTH,IT-Sardinia;IT-CSOUTH:IT-SOUTH,IT-Sardinia;IT-SOUTH:IT-Calabria;IT-Calabria:IT-Sicily;LT:LV,PL,SE4;NL:NO2;NO1:NO2,NO3,NO5,SE3;NO2:NO5;NO3:NO4,NO5,SE2;NO4:SE1,SE2;PL:SE4,SK;RO:RS;RS:HR;SE1:SE2;SE2:SE3;SE3:SE4"
NEIGHBOURS = {z: set() for z in ZONES}
for edge in EDGES.split(";"):
    a, bs = edge.split(":")
    for b in bs.split(","):
        if a in NEIGHBOURS and b in NEIGHBOURS:
            NEIGHBOURS[a].add(b)
            NEIGHBOURS[b].add(a)


def dump_json(path, value):
    """Strict JSON; undefined metrics are null, never NaN."""
    def clean(x):
        if isinstance(x, dict):
            return {str(k): clean(v) for k, v in x.items()}
        if isinstance(x, (list, tuple)):
            return [clean(v) for v in x]
        if isinstance(x, (np.integer,)):
            return int(x)
        if isinstance(x, (float, np.floating)):
            return float(x) if np.isfinite(x) else None
        return x
    Path(path).write_text(json.dumps(clean(value), indent=2, allow_nan=False) + "\n")


def hourly_actuals(con, start, end):
    # Exactly the shared resolution_aware_actuals policy: latest sequence at
    # each timestamp, then mean across subhours. Never sum PT15M and PT60M.
    return con.execute("""
      WITH dedup AS (
        SELECT map_code AS zone, date_time_utc AS t, price_currency_mwh AS actual
        FROM entsoe.energy_prices
        WHERE contract_type='Day-ahead' AND area_type_code LIKE 'BZN%'
          AND currency='EUR' AND price_currency_mwh IS NOT NULL
          AND date_time_utc >= ?::TIMESTAMP AND date_time_utc < ?::TIMESTAMP
        QUALIFY row_number() OVER (PARTITION BY map_code,date_time_utc
          ORDER BY try_cast(trim(sequence) AS INTEGER) DESC NULLS LAST,
                   update_time_utc DESC, resolution_code, instance_code)=1)
      SELECT zone,date_trunc('hour',t) AS t,round(avg(actual),8) AS actual
      FROM dedup GROUP BY 1,2 ORDER BY 1,2
    """, [start, end]).df()


def hourly_forecasts(con, start, end, *, cutoff_offset=None, snapshots=True):
    """Max covered hours/type, coarser on ties; as-of groups use local days."""
    # For an as-of snapshot, discard unavailable raw revisions BEFORE choosing
    # resolution/coverage. Future publication coverage must not pick a feature.
    local_day = "cast(timezone('Europe/Athens', timezone('UTC', date_time_utc)) AS DATE)"
    if cutoff_offset is None:
        snapshot_filter = ""
        day_group = "cast(date_time_utc AS DATE)"
    else:
        offset = int(cutoff_offset) - 1
        snapshot_filter = f"""AND date_time_utc >= TIMESTAMP '2025-11-01'
          AND update_time_utc < ({local_day} + INTERVAL '{offset} days' + INTERVAL '6 hours 30 minutes')"""
        day_group = local_day
    frames = []
    for table, value, kind in [
        ("day_ahead_total_load_forecast", "total_load_mw", "'load'"),
        ("generation_forecasts_for_wind_and_solar", "day_ahead_generation_forecast_mw", "production_type"),
    ]:
        frames.append(con.execute(f"""
          WITH raw AS (
            SELECT area_map_code AS zone,date_time_utc AS t,
                   {kind} AS kind,resolution_code,{value} AS mw,update_time_utc AS stamp,
                   {day_group} AS delivery_group
            FROM entsoe.{table}
            WHERE area_type_code LIKE 'BZN%' AND {value} IS NOT NULL
              AND date_time_utc >= ?::TIMESTAMP AND date_time_utc < ?::TIMESTAMP
              {snapshot_filter}),
          coverage AS (
            SELECT zone,delivery_group AS d,kind,resolution_code,
                   count(DISTINCT date_trunc('hour',t)) AS nh
            FROM raw GROUP BY 1,2,3,4),
          best AS (
            SELECT * FROM coverage QUALIFY row_number() OVER (
              PARTITION BY zone,d,kind ORDER BY nh DESC,
              CASE resolution_code WHEN 'PT60M' THEN 60 WHEN 'PT30M' THEN 30 ELSE 15 END DESC)=1),
          slots AS (
            SELECT r.zone,r.t,r.kind,avg(r.mw) AS mw,max(r.stamp) AS stamp
            FROM raw r JOIN best b ON r.zone=b.zone AND r.delivery_group=b.d
              AND r.kind=b.kind AND r.resolution_code=b.resolution_code GROUP BY 1,2,3)
          SELECT zone,date_trunc('hour',t) AS t,kind,avg(mw) AS mw,max(stamp) AS stamp
          FROM slots GROUP BY 1,2,3
        """, [start, end]).df())
    raw = pd.concat(frames, ignore_index=True)
    raw = raw[raw.zone.isin(ZONES)]
    raw["kind"] = raw.kind.replace({"Solar": "solar", "Wind Onshore": "wind", "Wind Offshore": "wind"})
    # Sum wind types after hourly averaging, never across resolutions.
    raw = raw.groupby(["zone", "t", "kind"], as_index=False).agg(mw=("mw", "sum"), stamp=("stamp", "max"))
    vals = raw.pivot(index=["zone", "t"], columns="kind", values="mw")
    stamps = raw.pivot(index=["zone", "t"], columns="kind", values="stamp").add_suffix("_stamp")
    out = vals.join(stamps).reset_index()
    for k in ["load", "solar", "wind"]:
        if k not in out:
            out[k] = np.nan
            out[k + "_stamp"] = pd.NaT
    if snapshots and cutoff_offset is None:
        for offset, suffix in [(0, "_pre0630"), (2, "_persist0630")]:
            snap = hourly_forecasts(con, start, end, cutoff_offset=offset, snapshots=False)
            snap = snap.rename(columns={k: k + suffix for k in snap.columns if k not in ["zone", "t"]})
            out = out.merge(snap, on=["zone", "t"], how="outer", validate="one_to_one")
    # No national solar/wind series means unknown, not a silently measured 0.
    return out


def with_calendar(df):
    df = df.copy()
    df["t"] = pd.to_datetime(df.t)
    local = df.t.dt.tz_localize("UTC").dt.tz_convert("Europe/Athens")
    df["market_date"] = pd.to_datetime(local.dt.date)
    df["local_hour"] = local.dt.hour
    df["issue_utc"] = df.market_date - pd.Timedelta(days=1) + pd.Timedelta(hours=6, minutes=30)
    return df


def lag_by_market_day(df, columns, days):
    """Exact local market date lag. DST repeated hour is averaged, never future."""
    old = df.groupby(["zone", "market_date", "local_hour"], as_index=False)[columns].mean()
    old["market_date"] += pd.Timedelta(days=days)
    return df[["zone", "market_date", "local_hour"]].merge(
        old, on=["zone", "market_date", "local_hour"], how="left", validate="many_to_one")[columns].set_axis(df.index)


def build_features(actuals, forecasts, variant, *, settled_lag=1):
    """Never accepts target labels as numeric predictors; labels only enter lags."""
    if settled_lag not in (1, 2):
        raise ValueError("Settled-price history lag must be 1 or 2 market days")
    df = with_calendar(actuals.merge(forecasts, on=["zone", "t"], how="left", validate="one_to_one"))
    df = df.sort_values(["zone", "t"]).reset_index(drop=True)
    f = pd.DataFrame(index=df.index)
    # Calendar is known arbitrarily far before the auction.
    for h in range(24):
        f[f"hour_{h:02}"] = (df.local_hour == h).astype(float)
    dow = df.market_date.dt.dayofweek
    for d in range(7):
        f[f"weekday_{d}"] = (dow == d).astype(float)
    phase = 2 * np.pi * (df.market_date.dt.dayofyear - 1) / 365.25
    f["season_sin"], f["season_cos"] = np.sin(phase), np.cos(phase)
    for days in [settled_lag, 7]:
        lag = lag_by_market_day(df, ["actual"], days).actual
        # Compress extreme spikes without treating negative prices as missing.
        f[f"price_lag{days}"] = np.arcsinh(lag / 50)
        f[f"collapse_lag{days}"] = np.where(lag.notna(), lag <= 0, np.nan)
    daily = df.assign(y=np.where(df.actual.notna(), df.actual <= 0, np.nan)).groupby(
        ["zone", "market_date"]).agg(events=("y", "sum"), n=("y", "count"))
    # Reindex missing days so shifts mean calendar days, not observed rows.
    grid = pd.MultiIndex.from_product([ZONES, pd.date_range(df.market_date.min(), df.market_date.max())], names=["zone", "market_date"])
    daily = daily.reindex(grid)
    for window in [7, 28]:
        numer = daily.events.groupby(level=0).transform(lambda s: s.rolling(window, min_periods=1).sum().shift(settled_lag))
        denom = daily.n.groupby(level=0).transform(lambda s: s.rolling(window, min_periods=1).sum().shift(settled_lag))
        freq = (numer / denom).rename(f"recent_{window}d").reset_index()
        f[f"recent_{window}d"] = df[["zone", "market_date"]].merge(freq, how="left", on=["zone", "market_date"])[f"recent_{window}d"].to_numpy()

    if variant == "pregate_0630":
        # Stored load revision is usable only in its audited genuine-stamp era.
        snapshots_available = "load_pre0630" in df.columns
        load_col = "load_pre0630" if snapshots_available else "load"
        load_stamp_col = "load_stamp_pre0630" if snapshots_available else "load_stamp"
        legal_load = (df.t >= "2025-11-01") & (pd.to_datetime(df[load_stamp_col]) < df.issue_utc)
        physical = pd.DataFrame(index=df.index)
        for k in ["load", "solar", "wind"]:
            # Entire older row last updated by issuance is a sufficient upper
            # bound for persistence; no claim about D-1 RES publication time.
            value_col = k + "_persist0630" if snapshots_available else k
            stamp_col = k + "_stamp_persist0630" if snapshots_available else k + "_stamp"
            prev = df[["zone", "market_date", "local_hour", value_col, stamp_col]].copy()
            prev = prev.rename(columns={value_col: k, stamp_col: k + "_stamp"})
            prev["market_date"] += pd.Timedelta(days=2)
            prev = prev.groupby(["zone", "market_date", "local_hour"], as_index=False).agg(**{
                k: (k, "mean"), k + "_stamp": (k + "_stamp", "max")})
            x = df[["zone", "market_date", "local_hour"]].merge(prev, how="left", on=["zone", "market_date", "local_hour"])
            safe = (x.market_date >= "2025-11-03") & (pd.to_datetime(x[k + "_stamp"]) < df.issue_utc)
            physical[k] = x[k].where(safe)
        physical["load"] = df[load_col].where(legal_load, physical.load)
        f["load_is_direct"] = legal_load.astype(float)
    elif variant == "gate_1000_latest_proxy":
        physical = df[["load", "solar", "wind"]].copy()
    else:
        raise ValueError(variant)
    load = physical.load.where(physical.load > 0)
    f["log_load"] = np.log(load)
    # A missing type is left missing. The model gets explicit missing flags.
    f["solar_share"] = (physical.solar / load).clip(0, 3)
    f["wind_share"] = (physical.wind / load).clip(0, 3)
    f["res_share"] = ((physical.solar + physical.wind) / load).clip(0, 4)
    f["residual_share"] = 1 - f.res_share
    f["weekend_res"] = f.res_share * (dow >= 5)
    # Neighbour averages use only features with the same issuance contract.
    for col in ["recent_7d", "residual_share"]:
        wide = pd.concat([df[["zone", "t"]], f[[col]]], axis=1).pivot(index="t", columns="zone", values=col)
        neighbour = pd.DataFrame({z: wide.reindex(columns=sorted(NEIGHBOURS[z])).mean(axis=1) for z in ZONES})
        stacked = neighbour.rename_axis(index="t", columns="zone").stack(future_stack=True).rename("value").reset_index()
        f["neighbour_" + col] = df[["zone", "t"]].merge(stacked, on=["zone", "t"], how="left").value.to_numpy()
    return df, f.astype(float)


def fit_logistic(x, y):
    """Fixed L2 C=1, no class weighting or tuning (preserves base rates)."""
    x = np.asarray(x, dtype=float)
    missing = ~np.isfinite(x)
    # Fit scaling on this origin's training data only. All-missing columns are
    # inactive; their future appearance is not silently extrapolated.
    count = (~missing).sum(axis=0)
    mean = np.divide(np.where(missing, 0, x).sum(axis=0), count, out=np.zeros(x.shape[1]), where=count > 0)
    filled = np.where(missing, mean, x)
    scale = filled.std(axis=0)
    scale[scale < 1e-8] = 1
    active = count > 0
    design = np.c_[(filled - mean) / scale, missing.astype(float)]
    if len(np.unique(y)) < 2:
        return {"mean": mean, "scale": scale, "active": active, "constant": (np.sum(y) + 1) / (len(y) + 2)}
    model = LogisticRegression(C=1, solver="lbfgs", max_iter=300, tol=1e-6)
    model.fit(design, y)
    if int(model.n_iter_[0]) >= 300:
        raise RuntimeError("Logistic fit did not converge within its fixed budget")
    return {"mean": mean, "scale": scale, "active": active,
            "coef": model.coef_[0], "intercept": float(model.intercept_[0])}


def predict_logistic(model, x):
    x = np.asarray(x, dtype=float)
    if "constant" in model:
        return np.full(len(x), model["constant"])
    mean = np.asarray(model["mean"], dtype=float)
    scale = np.asarray(model["scale"], dtype=float)
    active = np.asarray(model["active"], dtype=bool)
    missing = ~np.isfinite(x)
    x = np.where(missing, mean, x)
    x[:, ~active] = mean[~active]
    missing[:, ~active] = True
    design = np.c_[(x - mean) / scale, missing.astype(float)]
    return expit(design @ model["coef"] + model["intercept"])


def probability_metrics(y, p):
    y, p = np.asarray(y, dtype=int), np.asarray(p, dtype=float)
    if len(y) == 0:
        return {"n": 0}
    q = np.clip(p, 1e-6, 1 - 1e-6)
    pred = p >= 0.5
    hits, fa = int(np.sum(pred & (y == 1))), int(np.sum(pred & (y == 0)))
    positives = int(y.sum())
    return {"n": len(y), "positive": positives, "predicted": int(pred.sum()),
            "brier": float(np.mean((p - y) ** 2)),
            "log_loss": float(-np.mean(y * np.log(q) + (1 - y) * np.log1p(-q))),
            "auc": float(roc_auc_score(y, p)) if 0 < positives < len(y) else None,
            "hits": hits, "false_alarms": fa,
            "precision": hits / (hits + fa) if hits + fa else None,
            "f1": 2 * hits / (positives + hits + fa) if positives + hits + fa else None,
            "hit_rate": hits / positives if positives else None,
            "false_alarm_rate": fa / (len(y) - positives) if positives < len(y) else None}


def evaluate_predictions(predictions):
    out = {}
    for name, p in predictions.groupby("model"):
        non_it = p[~p.zone.str.startswith("IT-")]
        out[name] = {"pooled": probability_metrics(p.y, p.probability),
                     "excluding_italy": probability_metrics(non_it.y, non_it.probability),
                     "by_zone": {z: probability_metrics(s.y, s.probability) for z, s in p.groupby("zone")},
                     "by_origin": {str(z): probability_metrics(s.y, s.probability) for z, s in p.groupby("origin")}}
        bins = np.minimum((p.probability * 10).astype(int), 9)
        out[name]["reliability"] = [{"bin": int(b), "n": len(s), "mean_probability": float(s.probability.mean()),
                                     "event_rate": float(s.y.mean())} for b, s in p.groupby(bins)]
    return out


def rolling_evaluate(df, features, test_start, test_end, train_start="2024-07-01", *, settled_lag=1):
    """Monthly expanding origins; only already-public DA price labels enter."""
    if settled_lag not in (1, 2):
        raise ValueError("Settled-price history lag must be 1 or 2 market days")
    starts = [pd.Timestamp(test_start)]
    starts += list(pd.date_range(pd.Timestamp(test_start) + pd.offsets.MonthBegin(1), test_end, freq="MS"))
    output, artifacts = [], {}
    for origin, stop in zip(starts, starts[1:] + [pd.Timestamp(test_end) + pd.Timedelta(days=1)]):
        # D-1 delivery DA prices were auctioned on D-2; lag 2 is conservative.
        train = (df.market_date >= train_start) & (df.market_date <= origin - pd.Timedelta(days=settled_lag)) & df.actual.notna()
        test = (df.market_date >= origin) & (df.market_date < stop) & df.actual.notna()
        print(f"origin={origin.date()} train={train.sum()} test={test.sum()}", flush=True)
        for zone in ZONES:
            tr, te = train & (df.zone == zone), test & (df.zone == zone)
            if not te.any() or not tr.any():
                continue
            ytrain = (df.loc[tr, "actual"] <= 0).astype(int).to_numpy()
            model = fit_logistic(features.loc[tr], ytrain)
            probability = predict_logistic(model, features.loc[te])
            base = df.loc[te, ["zone", "t", "market_date"]].copy()
            base["origin"] = str(origin.date())
            base["y"] = (df.loc[te, "actual"] <= 0).astype(int)
            for name, p in [("logistic", probability), ("climatology", np.full(te.sum(), (ytrain.sum() + 1) / (len(ytrain) + 2)))]:
                part = base.copy()
                part["model"], part["probability"] = name, p
                output.append(part)
            artifacts[f"{origin.date()}/{zone}"] = {
                k: v.tolist() if isinstance(v, np.ndarray) else v for k, v in model.items()}
    return pd.concat(output, ignore_index=True), artifacts


def live_baseline(live_dir, start, end):
    rows = []
    for path in sorted(Path(live_dir).glob("*.json")):
        doc = json.loads(path.read_text())
        for day in doc["days"]:
            if day["lead_days"] != 1 or day["input_mode"] != "weather" or not start <= day["date"] <= end:
                continue
            for t, sim, actual in zip(day["hours"], day["sim"], day["actual"]):
                if sim is not None and actual is not None:
                    rows.append({"zone": doc["zone"], "t": pd.Timestamp(t).tz_convert(None),
                                 "market_date": day["date"], "sim": sim, "actual_live": round(actual, 8),
                                 "issued": day.get("prediction_made_utc"), "code_version": day["code_version"]})
    return pd.DataFrame(rows).drop_duplicates(["zone", "t"], keep="first")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extract", default=os.environ.get("EUPHEMIA_DUCKDB_PATH"), required=not bool(os.environ.get("EUPHEMIA_DUCKDB_PATH")))
    parser.add_argument("--output", required=True)
    parser.add_argument("--live-dir")
    parser.add_argument("--test-start", default="2026-09-14")
    parser.add_argument("--test-end", default="2026-11-13")
    parser.add_argument("--settled-lag", type=int, choices=[1, 2], default=1)
    parser.add_argument("--variants", nargs="+", default=["pregate_0630", "gate_1000_latest_proxy"],
                        choices=["pregate_0630", "gate_1000_latest_proxy"])
    args = parser.parse_args()
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(args.extract, read_only=True, config={"threads": 4, "memory_limit": "8GB"})
    end = str(pd.Timestamp(args.test_end) + pd.Timedelta(days=2))
    actuals = hourly_actuals(con, "2024-06-01", end)
    actuals = actuals[actuals.zone.isin(ZONES)].reset_index(drop=True)
    forecasts = hourly_forecasts(con, "2024-06-01", end)
    audit = {"actual_rows": len(actuals), "forecast_rows": len(forecasts), "train_start": "2024-07-01",
             "test_start": args.test_start, "test_end": args.test_end, "threshold_eur": 0,
             "target": "hourly mean settled DA price <= 0", "latest_revision_proxy": True,
             "settled_history_lag": args.settled_lag}
    for variant in args.variants:
        print("features", variant, flush=True)
        df, f = build_features(actuals, forecasts, variant, settled_lag=args.settled_lag)
        test = (df.market_date >= args.test_start) & (df.market_date <= args.test_end)
        audit[variant] = {"cells": int(test.sum()), "physical_complete": int(f.loc[test, "res_share"].notna().sum()),
                          "feature_names": list(f.columns)}
        pred, artifacts = rolling_evaluate(df, f, args.test_start, args.test_end, settled_lag=args.settled_lag)
        pred.to_csv(out / f"{variant}-predictions.csv.gz", index=False)
        report = evaluate_predictions(pred)
        if args.live_dir:
            live = live_baseline(args.live_dir, args.test_start, args.test_end)
            paired = pred[pred.model == "logistic"].merge(live, on=["zone", "t"], how="inner", suffixes=("", "_live"))
            report["common_live_cells"] = {
                "logistic": probability_metrics(paired.y, paired.probability),
                "sim_le_zero": probability_metrics(paired.y, (paired.sim <= 0).astype(float)),
                "live_actual_disagreements": int(((paired.actual_live <= 0).astype(int) != paired.y).sum()),
                "after_0630_issued": int((pd.to_datetime(paired.issued, utc=True).dt.tz_localize(None) >
                                          pd.to_datetime(paired.market_date) - pd.Timedelta(days=1) + pd.Timedelta(hours=6, minutes=30)).sum())}
        dump_json(out / f"{variant}-metrics.json", report)
        dump_json(out / f"{variant}-models.json", {"features": list(f.columns), "origins": artifacts})
        print(variant, report["logistic"]["pooled"], flush=True)
    dump_json(out / "audit.json", audit)


if __name__ == "__main__":
    main()
