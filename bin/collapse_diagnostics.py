#!/usr/bin/env python3
"""Threshold diagnostics and a separate direct day-event logistic model.

No probability fitting is tuned to the final test. Test-optimal thresholds are
explicitly labelled oracle diagnostics. A deployable F1 threshold is selected
on the preceding origin's held-forward predictions, never current test labels.
"""
import argparse
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd
from sklearn.metrics import precision_recall_curve

import collapse_probability as cp


def detection(y, p, threshold):
    y, p = np.asarray(y, dtype=int), np.asarray(p, dtype=float)
    predicted = p >= threshold
    tp, fp = int(np.sum(predicted & (y == 1))), int(np.sum(predicted & (y == 0)))
    npos = int(y.sum())
    return {"threshold": float(threshold), "n": len(y), "positive": npos,
            "hits": tp, "false_alarms": fp,
            "recall": tp / npos if npos else None,
            "precision": tp / (tp + fp) if tp + fp else None,
            "f1": 2 * tp / (npos + tp + fp) if npos + tp + fp else None,
            "false_alarm_rate": fp / (len(y) - npos) if npos < len(y) else None}


def best_f1_threshold(y, p):
    if not np.any(y):
        return 1.0
    precision, recall, thresholds = precision_recall_curve(y, p)
    f1 = 2 * precision[:-1] * recall[:-1] / np.maximum(precision[:-1] + recall[:-1], 1e-12)
    # Conservative high-threshold tie-break, fixed before scored comparisons.
    return float(thresholds[np.flatnonzero(f1 == np.max(f1))[-1]])


def matched_fpr_threshold(y, p, target_fpr):
    """Oracle ROC diagnostic: largest recall at FPR <= target on these rows."""
    y, p = np.asarray(y), np.asarray(p)
    negatives = np.sort(p[y == 0])[::-1]
    if not len(negatives):
        return 1.0
    allowed = int(np.floor(target_fpr * len(negatives) + 1e-9))
    if allowed >= len(negatives):
        return 0.0
    return float(np.nextafter(negatives[allowed], np.inf))


def threshold_report(pred, lag2):
    joined = pred.merge(lag2, on=["zone", "t"], how="left", validate="one_to_one")
    y, p = joined.y.to_numpy(), joined.probability.to_numpy()
    valid = joined.lag2.notna()
    base = detection(joined.loc[valid, "y"], joined.loc[valid, "lag2"], 0.5)
    matched = matched_fpr_threshold(joined.loc[valid, "y"], joined.loc[valid, "probability"], base["false_alarm_rate"])
    zero = matched_fpr_threshold(y, p, 0.)
    return {"fixed": {str(t): detection(y, p, t) for t in [0.2, 0.3, 0.5]},
            "oracle_test_max_f1": detection(y, p, best_f1_threshold(y, p)),
            "oracle_test_matched_zero_fpr": detection(y, p, zero),
            "lag2_indicator": base,
            "oracle_test_matched_lag2_fpr": detection(joined.loc[valid, "y"], joined.loc[valid, "probability"], matched)}


def daily_dataset(df, features):
    """One label per COMPLETE market day; direct event, no independence trick."""
    columns = ["season_sin", "season_cos", "price_lag2", "price_lag7",
               "collapse_lag2", "collapse_lag7", "recent_7d", "recent_28d",
               "log_load", "solar_share", "wind_share", "res_share",
               "residual_share", "neighbour_recent_7d", "neighbour_residual_share"]
    x = pd.concat([df[["zone", "market_date"]], features[columns]], axis=1)
    agg = x.groupby(["zone", "market_date"])[columns].agg(["mean", "min", "max"])
    agg.columns = ["_".join(c) for c in agg.columns]
    labels = df.groupby(["zone", "market_date"]).agg(actual=("actual", "min"), n=("actual", "count"))
    # Localized midnight-to-midnight duration accounts for 23/25-hour DST days.
    days = labels.index.get_level_values("market_date")
    lengths = ((days + pd.Timedelta(days=1)).tz_localize("Europe/Athens").tz_convert("UTC") -
               days.tz_localize("Europe/Athens").tz_convert("UTC")) / pd.Timedelta(hours=1)
    labels.loc[labels.n.to_numpy() != lengths, "actual"] = np.nan
    daily = labels.reset_index()
    daily["t"] = daily.market_date
    # Day event probability gets its own day-of-week and same-hour statistics.
    for d in range(7):
        agg[f"weekday_{d}"] = (agg.index.get_level_values("market_date").dayofweek == d).astype(float)
    return daily, agg.reset_index(drop=True).astype(float)


def prior_origin_predictions(df, features, start, end, origin):
    """One fixed origin for pre-test threshold calibration (no tuning loop)."""
    tr_all = df.actual.notna() & (df.market_date >= "2024-07-01") & (df.market_date <= pd.Timestamp(origin) - pd.Timedelta(days=2))
    te_all = df.actual.notna() & (df.market_date >= start) & (df.market_date <= end)
    rows = []
    for zone in cp.ZONES:
        tr, te = tr_all & (df.zone == zone), te_all & (df.zone == zone)
        if not tr.any() or not te.any():
            continue
        model = cp.fit_logistic(features.loc[tr], (df.loc[tr, "actual"] <= 0).astype(int).to_numpy())
        part = df.loc[te, ["zone", "t", "market_date"]].copy()
        part["y"] = (df.loc[te, "actual"] <= 0).astype(int)
        part["probability"] = cp.predict_logistic(model, features.loc[te])
        rows.append(part)
    return pd.concat(rows, ignore_index=True)


def validation_selected_thresholds(test, prior):
    """Pooled F1 threshold from preceding 28 days, ending origin D-2."""
    all_rows = pd.concat([prior, test], ignore_index=True)
    reports, chunks = [], []
    for origin, part in test.groupby("origin"):
        date = pd.Timestamp(origin)
        val = all_rows[(all_rows.market_date >= date - pd.Timedelta(days=29)) &
                       (all_rows.market_date <= date - pd.Timedelta(days=2))]
        threshold = best_f1_threshold(val.y, val.probability)
        reports.append({"origin": str(origin), "validation_n": len(val),
                        "validation_positive": int(val.y.sum()),
                        "test": detection(part.y, part.probability, threshold)})
        chunks.append(pd.DataFrame({"y": part.y, "prediction": (part.probability >= threshold).astype(float)}))
    combined = pd.concat(chunks, ignore_index=True)
    return {"origins": reports, "combined": detection(combined.y, combined.prediction, 0.5)}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--extract", required=True)
    p.add_argument("--probability-dir", required=True)
    p.add_argument("--live-dir", required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(args.extract, read_only=True, config={"threads": 4, "memory_limit": "8GB"})
    actuals = cp.hourly_actuals(con, "2024-06-01", "2026-11-15")
    actuals = actuals[actuals.zone.isin(cp.ZONES)].reset_index(drop=True)
    forecasts = cp.hourly_forecasts(con, "2024-06-01", "2026-11-15")
    live = cp.live_baseline(args.live_dir, "2026-09-14", "2026-11-13")
    for variant in ["pregate_0630", "gate_1000_latest_proxy"]:
        print("diagnostics", variant, flush=True)
        df, features = cp.build_features(actuals, forecasts, variant)
        pred = pd.read_csv(Path(args.probability_dir) / f"{variant}-predictions.csv.gz", parse_dates=["t", "market_date"])
        hourly = pred[pred.model == "logistic"].copy()
        lag2 = df[["zone", "t"]].copy()
        lag2["lag2"] = features.collapse_lag2
        top = hourly.groupby("zone").y.sum().sort_values(ascending=False, kind="stable").head(8).index.tolist()
        summary = {"hourly": {"all39": threshold_report(hourly, lag2),
                               "excluding_italy": threshold_report(hourly[~hourly.zone.str.startswith("IT-")], lag2)},
                   "hourly_top8": {z: threshold_report(hourly[hourly.zone == z], lag2) for z in top}}
        # Rebuild aggregate files from saved predictions; no repeated main fit.
        cp.dump_json(out / f"{variant}-metrics.json", cp.evaluate_predictions(pred))
        print("prior threshold fit", variant, flush=True)
        prior = prior_origin_predictions(df, features, "2026-08-16", "2026-09-12", "2026-08-16")
        summary["hourly"]["validation_selected_max_f1"] = validation_selected_thresholds(hourly, prior)
        daily, day_features = daily_dataset(df, features)
        day_pred, day_models = cp.rolling_evaluate(daily, day_features, "2026-09-14", "2026-11-13")
        day_pred.to_csv(out / f"{variant}-day-predictions.csv.gz", index=False)
        cp.dump_json(out / f"{variant}-day-models.json", {"features": list(day_features.columns), "origins": day_models})
        summary["daily"] = cp.evaluate_predictions(day_pred)
        day_hour = day_pred[day_pred.model == "logistic"]
        day_lag = daily[["zone", "t"]].copy()
        day_lag["lag2"] = day_features.collapse_lag2_max
        summary["daily_thresholds"] = {"all39": threshold_report(day_hour, day_lag),
                                       "excluding_italy": threshold_report(day_hour[~day_hour.zone.str.startswith("IT-")], day_lag)}
        summary["daily_top8"] = {z: cp.probability_metrics(s.y, s.probability) for z, s in day_hour[day_hour.zone.isin(top)].groupby("zone")}
        # Exact common-live comparators, hourly and daily, all39 and ex-Italy.
        common = hourly.merge(live, on=["zone", "t"], how="inner", suffixes=("", "_live"))
        common_clim = pred[pred.model == "climatology"][["zone", "t", "probability"]].rename(columns={"probability": "climatology"})
        common = common.merge(common_clim, on=["zone", "t"], validate="one_to_one")
        summary["common_live_hourly"] = {}
        for group, x in [("all39", common), ("excluding_italy", common[~common.zone.str.startswith("IT-")])]:
            summary["common_live_hourly"][group] = {
                "logistic": cp.probability_metrics(x.y, x.probability),
                "climatology": cp.probability_metrics(x.y, x.climatology),
                "sim_le_zero": cp.probability_metrics(x.y, (x.sim <= 0).astype(float))}
        common_day = live.groupby(["zone", "market_date"]).agg(sim=("sim", "min"), n=("sim", "count")).reset_index()
        common_day["market_date"] = pd.to_datetime(common_day.market_date)
        common_day = day_hour.merge(common_day, on=["zone", "market_date"])
        # Complete live days only; 25-hour DST Sunday is supported.
        dd = common_day.market_date
        expected = ((dd + pd.Timedelta(days=1)).dt.tz_localize("Europe/Athens").dt.tz_convert("UTC") -
                    dd.dt.tz_localize("Europe/Athens").dt.tz_convert("UTC")) / pd.Timedelta(hours=1)
        common_day = common_day[common_day.n.to_numpy() == expected.to_numpy()]
        summary["common_live_daily"] = {
            "logistic": cp.probability_metrics(common_day.y, common_day.probability),
            "sim_any_le_zero": cp.probability_metrics(common_day.y, (common_day.sim <= 0).astype(float))}
        cp.dump_json(out / f"{variant}-diagnostics.json", summary)
        print(variant, "day", summary["daily"]["logistic"]["pooled"], flush=True)


if __name__ == "__main__":
    main()
