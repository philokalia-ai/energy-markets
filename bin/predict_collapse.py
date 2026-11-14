#!/usr/bin/env python3
"""Write experimental 06:30 D-1 collapse probabilities, never market prices.

Uses the same fixed model/feature contract as collapse_probability.py. Future
target labels are not read. No network calls, database writes or publication.
"""
import argparse
import os
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

from collapse_probability import (ZONES, build_features, dump_json, fit_logistic,
                                   hourly_actuals, hourly_forecasts, predict_logistic)
from collapse_diagnostics import daily_dataset


def forecast_date(con, delivery):
    delivery = pd.Timestamp(delivery).normalize()
    # Read past prices only. D-1 partial UTC rows, if any, are excluded by the
    # stricter market-date training cutoff below.
    actuals = hourly_actuals(con, "2024-06-01", str(delivery - pd.Timedelta(days=1)))
    actuals = actuals[actuals.zone.isin(ZONES)]
    start = delivery.tz_localize("Europe/Athens").tz_convert("UTC").tz_localize(None)
    end = (delivery + pd.Timedelta(days=1)).tz_localize("Europe/Athens").tz_convert("UTC").tz_localize(None)
    targets = pd.MultiIndex.from_product([ZONES, pd.date_range(start, end, inclusive="left", freq="h")], names=["zone", "t"]).to_frame(index=False)
    targets["actual"] = np.nan
    actuals = pd.concat([actuals, targets], ignore_index=True)
    forecasts = hourly_forecasts(con, "2024-06-01", str(end + pd.Timedelta(days=1)))
    df, features = build_features(actuals, forecasts, "pregate_0630")
    train = df.actual.notna() & (df.market_date >= "2024-07-01") & (df.market_date <= delivery - pd.Timedelta(days=2))
    output, models = [], {}
    for zone in ZONES:
        tr, te = train & (df.zone == zone), (df.market_date == delivery) & (df.zone == zone)
        if not tr.any():
            raise ValueError(f"No training prices for {zone}")
        model = fit_logistic(features.loc[tr], (df.loc[tr, "actual"] <= 0).astype(int).to_numpy())
        part = df.loc[te, ["zone", "t", "market_date", "issue_utc"]].copy()
        part["collapse_probability"] = predict_logistic(model, features.loc[te])
        part["physical_features_complete"] = features.loc[te, "res_share"].notna()
        output.append(part)
        models[zone] = {k: v.tolist() if isinstance(v, np.ndarray) else v for k, v in model.items()}
    result = pd.concat(output, ignore_index=True)
    result["input_variant"] = "pregate_0630_persistence"
    result["target"] = "hourly_mean_settled_le_zero"
    result["model_version"] = "collapse_logistic_202611_v3"
    metadata = {"delivery": str(delivery.date()), "training_labels_through": str((delivery - pd.Timedelta(days=2)).date()),
                "training_rows": int(train.sum()), "feature_names": list(features.columns), "zones": models,
                "generated_at_utc": pd.Timestamp.now(tz="UTC").isoformat(),
                "status": "offline_asof_reconstruction_not_published"}
    daily, day_features = daily_dataset(df, features)
    day_train = daily.actual.notna() & (daily.market_date >= "2024-07-01") & (daily.market_date <= delivery - pd.Timedelta(days=2))
    daily_rows, day_models = [], {}
    for zone in ZONES:
        tr, te = day_train & (daily.zone == zone), (daily.market_date == delivery) & (daily.zone == zone)
        model = fit_logistic(day_features.loc[tr], (daily.loc[tr, "actual"] <= 0).astype(int).to_numpy())
        part = daily.loc[te, ["zone", "market_date"]].copy()
        part["any_hour_collapse_probability"] = predict_logistic(model, day_features.loc[te])
        daily_rows.append(part)
        day_models[zone] = {k: v.tolist() if isinstance(v, np.ndarray) else v for k, v in model.items()}
    metadata["day_features"] = list(day_features.columns)
    metadata["day_models"] = day_models
    day_result = pd.concat(daily_rows, ignore_index=True)
    day_result["issue_utc"] = delivery - pd.Timedelta(days=1) + pd.Timedelta(hours=6, minutes=30)
    day_result["input_variant"] = "pregate_0630_persistence"
    day_result["model_version"] = "collapse_daily_logistic_202611_v3"
    return result, day_result, metadata


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--extract", default=os.environ.get("EUPHEMIA_DUCKDB_PATH"), required=not bool(os.environ.get("EUPHEMIA_DUCKDB_PATH")))
    p.add_argument("--delivery", required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()
    con = duckdb.connect(args.extract, read_only=True, config={"threads": 4, "memory_limit": "8GB"})
    result, daily, metadata = forecast_date(con, args.delivery)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    result.to_csv(output / f"{args.delivery}-probabilities.csv", index=False)
    daily.to_csv(output / f"{args.delivery}-day-probabilities.csv", index=False)
    dump_json(output / f"{args.delivery}-model.json", metadata)
    print(result.groupby("zone").agg(n=("t", "count"), mean_probability=("collapse_probability", "mean"),
                                     max_probability=("collapse_probability", "max")))
    print(daily.sort_values("any_hour_collapse_probability", ascending=False).to_string(index=False))


if __name__ == "__main__":
    main()
