#!/usr/bin/env python3
"""One fixed D-1-public-price-history sensitivity; the D-2 benchmark is frozen.

Only known SDAC price history/training-label cutoff changes. Forecast publication
rules, C=1, monthly origins and physical D-2 persistence are identical.
"""
import argparse
from pathlib import Path

import duckdb
import pandas as pd

import collapse_probability as cp
from collapse_diagnostics import daily_dataset, detection


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--extract", required=True)
    p.add_argument("--d2-diagnostics", required=True)
    p.add_argument("--d2-probability")
    p.add_argument("--output", required=True)
    args = p.parse_args()
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(args.extract, read_only=True, config={"threads": 1, "memory_limit": "8GB"})
    actuals = cp.hourly_actuals(con, "2024-06-01", "2026-11-15")
    actuals = actuals[actuals.zone.isin(cp.ZONES)].reset_index(drop=True)
    forecasts = cp.hourly_forecasts(con, "2024-06-01", "2026-11-15")
    df, features = cp.build_features(actuals, forecasts, "pregate_0630", settled_lag=1)
    hourly, models = cp.rolling_evaluate(df, features, "2026-09-14", "2026-11-13", settled_lag=1)
    daily, day_features = daily_dataset(df, features)
    days, day_models = cp.rolling_evaluate(daily, day_features, "2026-09-14", "2026-11-13", settled_lag=1)
    rows = []
    for target, pred, names, fitted in [("hour", hourly, list(features.columns), models),
                                       ("day", days, list(day_features.columns), day_models)]:
        pred.to_csv(out / f"price_L1-{target}-predictions.csv.gz", index=False)
        cp.dump_json(out / f"price_L1-{target}-models.json", {"features": names, "origins": fitted, "settled_lag": 1})
        metrics = cp.evaluate_predictions(pred)
        cp.dump_json(out / f"price_L1-{target}-metrics.json", metrics)
        d2_file = (Path(args.d2_diagnostics) / "pregate_0630-day-predictions.csv.gz" if target == "day" else
                   (Path(args.d2_probability) if args.d2_probability else Path(args.d2_diagnostics).parent / "collapse-probability-final") / "pregate_0630-predictions.csv.gz")
        d2 = pd.read_csv(d2_file, parse_dates=["t"])
        for variant, data in [("price_L1", pred), ("price_L2_frozen", d2)]:
            x = data[data.model == "logistic"]
            for footprint, s in [("all39", x), ("excluding_italy", x[~x.zone.str.startswith("IT-")])]:
                r = dict(variant=variant, target=target, footprint=footprint, **cp.probability_metrics(s.y, s.probability))
                for threshold in [0.2, 0.3]:
                    d = detection(s.y, s.probability, threshold)
                    r[f"recall_{threshold}"] = d["recall"]
                    r[f"precision_{threshold}"] = d["precision"]
                rows.append(r)
    pd.DataFrame(rows).to_csv(out / "price-history-sensitivity.csv", index=False)
    cp.dump_json(out / "contract.json", {"history_lag": 1, "origins": ["2026-09-14", "2026-10-01", "2026-11-01"],
        "source": "https://www.nordpoolgroup.com/en/the-power-market/Day-ahead-market/",
        "availability": "D-1 delivery DA prices are auctioned/published on D-2; only this known price history extends, not actual load/generation",
        "forecast_contract": "unchanged pre-gate raw-row publication filter; physical persistence stays D-2",
        "target_round_decimals": 8, "parameter_search": False})
    print(pd.DataFrame(rows).to_string(index=False))


if __name__ == "__main__":
    main()
