#!/usr/bin/env python3
"""Files-only, explicit-contract point forecast benchmarks for #431.

No model fitting or production imports. See README.md for the estimators.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np
import pandas as pd

VERSION = "benchmark-431-v1"
KEY = ["zone", "t"]
NAIVES = ("d1", "d7", "epf")


def sha256_file(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def read_frame(path):
    path = Path(path)
    if path.suffix == ".parquet":
        import duckdb  # Optional for CSV-only synthetic tests.
        with duckdb.connect(":memory:", config={"threads": 2}) as cx:
            return cx.execute("SELECT * FROM read_parquet(?)", [str(path)]).df()
    return pd.read_csv(path)


def calendar(frame, timezone):
    out = frame.copy()
    out["t"] = pd.to_datetime(out.t, utc=True)
    if not out.t.eq(out.t.dt.floor("h")).all():
        raise ValueError("Hourly benchmark rejects subhourly input; aggregate explicitly first")
    local = out.t.dt.tz_convert(timezone)
    out["market_date"] = local.dt.tz_localize(None).dt.normalize()
    out["local_hour"] = local.dt.hour
    return out


def expected_hours(days, timezone):
    days = pd.DatetimeIndex(days)
    return np.asarray(((days + pd.Timedelta(days=1)).tz_localize(timezone).tz_convert("UTC")
                       - days.tz_localize(timezone).tz_convert("UTC")) / pd.Timedelta(hours=1), dtype=int)


def make_grid(zones, start, end, timezone):
    begin = pd.Timestamp(start).tz_localize(timezone).tz_convert("UTC")
    stop = (pd.Timestamp(end) + pd.Timedelta(days=1)).tz_localize(timezone).tz_convert("UTC")
    return calendar(pd.MultiIndex.from_product(
        [sorted(zones), pd.date_range(begin, stop, freq="h", inclusive="left")], names=KEY).to_frame(index=False), timezone)


def naive_forecasts(actuals, targets, timezone="Europe/Athens"):
    """Backward local-date/hour joins. A repeated SOURCE hour is averaged.

    Both repeated target hours get that same source-hour value. A nonexistent
    spring source hour stays missing. Leads 2..7 receive D-7 only, including
    suppression of the weekday rule even on days when it would choose D-7.
    Optional `available_utc` is authenticated source availability, not an ETL
    update stamp. If supplied, missing/late stamps fail closed.
    """
    if actuals.duplicated(KEY).any():
        raise ValueError("Actual history must have unique zone/UTC-hour keys")
    if not targets.lead.isin(range(1, 8)).all():
        raise ValueError("Declared admissibility rule supports leads 1 through 7")
    history = calendar(actuals, timezone)
    history["actual"] = pd.to_numeric(history.actual, errors="coerce").astype(float).round(8)
    target = calendar(targets, timezone)
    grouped = history.groupby(["zone", "market_date", "local_hour"], sort=True)
    prices = grouped.actual.mean()
    stamps = None
    if "available_utc" in history:
        history["available_utc"] = pd.to_datetime(history.available_utc, utc=True, errors="coerce")
        grouped = history.groupby(["zone", "market_date", "local_hour"], sort=True)
        stamps = grouped.available_utc.max()
        complete_stamp = grouped.available_utc.count().eq(grouped.size())
        stamps = stamps.where(complete_stamp)
    issues = pd.to_datetime(target.get("issue_utc", pd.Series(pd.NaT, index=target.index)), utc=True)
    for lag in [1, 7]:
        keys = pd.MultiIndex.from_arrays([target.zone, target.market_date - pd.Timedelta(days=lag), target.local_hour])
        value = prices.reindex(keys).to_numpy()
        if stamps is not None:
            published = pd.Series(stamps.reindex(keys).to_numpy(), index=target.index)
            published = pd.to_datetime(published, utc=True)
            value = np.where(published.notna() & issues.notna() & published.le(issues), value, np.nan)
        target[f"naive_d{lag}"] = value
    weekday = target.market_date.dt.day_of_week
    target["naive_epf"] = np.where(weekday.isin([0, 5, 6]), target.naive_d7, target.naive_d1)
    target.loc[target.lead != 1, ["naive_d1", "naive_epf"]] = np.nan
    return target


def mask_hash(frame, lead):
    """Hash the sorted cell keys, not a row offset or rounded metric."""
    keys = frame[KEY].sort_values(KEY)
    text = "".join(f"{z}\t{pd.Timestamp(t).isoformat()}\t{int(lead)}\n" for z, t in keys.itertuples(index=False, name=None))
    return hashlib.sha256(text.encode()).hexdigest()


def dm_daily_vectors(model_loss, naive_loss, dates=None, *, lead=1, min_days=30, hac_lag=7):
    """One-sided daily-vector DM, L1 loss, calendar-lag Bartlett HAC.

    Positive statistic favors the model. Each input row is a complete 24-hour
    loss vector. DST days are excluded by the caller. Gaps are not compressed
    into adjacent days for HAC. No epftoolbox dependency or copied code.
    """
    model_loss, naive_loss = np.asarray(model_loss, float), np.asarray(naive_loss, float)
    if model_loss.shape != naive_loss.shape or model_loss.ndim != 2 or model_loss.shape[1] != 24:
        raise ValueError("DM requires equally shaped (days,24) loss vectors")
    if not (np.isfinite(model_loss).all() and np.isfinite(naive_loss).all()):
        raise ValueError("DM loss vectors must be finite")
    n = len(model_loss)
    out = {"n_days": n, "status": "insufficient data", "statistic": None, "p_model_better": None}
    if n < min_days:
        return out
    difference = (naive_loss - model_loss).mean(axis=1)
    if np.array_equal(difference, np.zeros(n)):
        return dict(out, status="identical daily loss", statistic=0., p_model_better=1.)
    if dates is None:
        dates = pd.date_range("2000-01-01", periods=n)
    series = pd.Series(difference, index=pd.DatetimeIndex(dates))
    if series.index.has_duplicates:
        raise ValueError("DM needs one vector per calendar day")
    series = series.sort_index().reindex(pd.date_range(series.index.min(), series.index.max()))
    centered = series - difference.mean()
    bandwidth = min(max(hac_lag, lead - 1), n - 1)
    variance = float(centered.pow(2).sum() / n)
    for k in range(1, bandwidth + 1):
        variance += 2 * (1 - k / (bandwidth + 1)) * float((centered * centered.shift(k)).sum() / n)
    if variance <= 1e-15:
        return dict(out, status="undefined zero loss-differential variance", hac_lag=bandwidth)
    statistic = float(difference.mean() / math.sqrt(variance / n))
    return dict(out, status="ok", statistic=statistic,
                p_model_better=0.5 * math.erfc(statistic / math.sqrt(2)),
                mean_naive_minus_model_loss=float(difference.mean()), hac_lag=bandwidth)


def summarize(frame, aggregation):
    """Ratio of matched aggregate errors; never a mean of daily ratios."""
    if frame.empty:
        return dict(n=0, n_zone_days=0, n_market_days=0, mae=None, bias=None, naive_mae=None,
                    rmae=None, mean_price=None, mae_over_mean_price=None, share_le_zero=None)
    x = frame.assign(error=frame.prediction - frame.actual,
                     abs_error=(frame.prediction - frame.actual).abs(),
                     naive_abs_error=(frame.naive - frame.actual).abs(), nonpositive=frame.actual.le(0).astype(float))
    values = x[["abs_error", "error", "naive_abs_error", "actual", "nonpositive"]]
    if aggregation == "mean_daily":
        values = x.groupby(["zone", "market_date"])[values.columns].mean()
    elif aggregation != "pooled_cell":
        raise ValueError("Unknown aggregation: " + aggregation)
    means = values.mean()
    denominator, mean_price = float(means.naive_abs_error), float(means.actual)
    return dict(n=len(x), n_zone_days=x[["zone", "market_date"]].drop_duplicates().shape[0],
                n_market_days=int(x.market_date.nunique()),
                mae=float(means.abs_error), bias=float(means.error), naive_mae=denominator,
                rmae=float(means.abs_error / denominator) if denominator > 0 else None,
                mean_price=mean_price, mae_over_mean_price=float(means.abs_error / mean_price) if mean_price != 0 else None,
                share_le_zero=float(means.nonpositive))


def complete_day_mask(frame, timezone):
    count = frame.groupby(["zone", "market_date"]).t.transform("nunique")
    needed = pd.Series(expected_hours(frame.market_date, timezone), index=frame.index)
    return count.eq(needed)


def dm_for_group(frame, zones, timezone, lead, min_days, expected_dates=None):
    """Footprints require every declared zone on each retained 24h date.

    Absolute errors are calculated BEFORE averaging zones; there is no
    cancellation from comparing average zone prices.
    """
    if frame.empty:
        return dict(n_days=0, status="insufficient data", statistic=None, p_model_better=None,
                    dst_or_incomplete_days=len(expected_dates) if expected_dates is not None else 0)
    counts = frame.groupby(["market_date", "zone"]).t.nunique().unstack("zone").reindex(columns=zones)
    dates = expected_dates if expected_dates is not None else pd.date_range(counts.index.min(), counts.index.max())
    counts = counts.reindex(index=dates)
    normal = expected_hours(counts.index, timezone) == 24
    good = counts.index[normal & counts.eq(24).all(axis=1)]
    x = frame[frame.market_date.isin(good)].copy()
    x["model_loss"] = (x.prediction - x.actual).abs()
    x["naive_loss"] = (x.naive - x.actual).abs()
    losses = x.groupby(["market_date", "local_hour"])[["model_loss", "naive_loss"]].mean()
    model = losses.model_loss.unstack("local_hour").reindex(index=good, columns=range(24)).to_numpy()
    naive = losses.naive_loss.unstack("local_hour").reindex(index=good, columns=range(24)).to_numpy()
    result = dm_daily_vectors(model, naive, good, lead=lead, min_days=min_days)
    return dict(result, dst_or_incomplete_days=int(len(counts) - len(good)))


def evaluate(actuals, forecasts, *, start, end, zones=None, timezone="Europe/Athens",
             intersection=False, min_dm_days=30, save_masks=None):
    """Return metrics/mask/exclusion/DM tables for a declared saved panel.

    Required actual columns: zone,t,actual. Forecast: zone,t,model,lead,prediction.
    `eligible=False` marks a declared cohort exclusion, not a missing forecast.
    """
    actuals = calendar(actuals, timezone)
    if actuals[KEY].isna().any().any():
        raise ValueError("Actual cell keys must be present")
    actuals["actual"] = pd.to_numeric(actuals.actual, errors="coerce").astype(float).round(8)
    if actuals.duplicated(KEY).any():
        raise ValueError("Duplicate actual keys")
    forecasts = calendar(forecasts, timezone)
    if forecasts[["model", "lead"] + KEY].isna().any().any():
        raise ValueError("Forecast cell keys must be present")
    if forecasts.duplicated(["model", "lead"] + KEY).any():
        raise ValueError("Duplicate model/lead/zone/hour forecast keys")
    if not forecasts.lead.isin(range(1, 8)).all():
        raise ValueError("Only leads 1..7 are supported")
    forecasts["prediction"] = pd.to_numeric(forecasts.prediction, errors="coerce").astype(float)
    forecasts["eligible"] = forecasts.get("eligible", True)
    zones = sorted(zones or forecasts.zone.unique().tolist())
    forecasts = forecasts[forecasts.zone.isin(zones)]
    base_grid = make_grid(zones, start, end, timezone)
    base_grid = base_grid.merge(actuals[KEY + ["actual"]], on=KEY, how="left", validate="one_to_one")
    metrics, masks, excluded, significance = [], [], [], []
    if save_masks:
        Path(save_masks).mkdir(parents=True, exist_ok=True)
    for lead, lead_fc in forecasts.groupby("lead", sort=True):
        grid = base_grid.assign(lead=int(lead))
        # Issue time is optional. Calendar-only histories are labelled as such
        # in the manifest; authenticated availability requires explicit stamps.
        stamp_fields = [c for c in ["available_utc"] if c in actuals]
        if not stamp_fields:
            grid = naive_forecasts(actuals[KEY + ["actual"]], grid, timezone)
        # Materialize the final pairwise masks before intersecting. Naive
        # availability depends on each model's issue time, so forecast validity
        # alone cannot define a shared comparison cohort.
        comparisons = []
        common_keys = {}
        for model, model_fc in lead_fc.groupby("model", sort=True):
            fields = KEY + ["prediction", "eligible"] + (["issue_utc"] if "issue_utc" in model_fc else [])
            x = grid.merge(model_fc[fields], on=KEY, how="left", validate="one_to_one")
            if stamp_fields:
                x = naive_forecasts(actuals[KEY + ["actual"] + stamp_fields], x, timezone)
            for naive in NAIVES:
                if lead != 1 and naive != "d7":
                    for zone, count in x.groupby("zone").size().items():
                        excluded.append(dict(model=str(model), lead=int(lead), naive=naive,
                                             mask_family="not_evaluated", zone=zone,
                                             reason="naive_unavailable_at_issue_for_lead", n=int(count)))
                    continue
                conditions = {
                    "missing_or_nonfinite_actual": ~np.isfinite(x.actual),
                    "missing_or_nonfinite_forecast": ~np.isfinite(x.prediction),
                    "excluded_by_declared_cohort": x.eligible.eq(False),
                    "unknown_eligibility": x.eligible.isna() & np.isfinite(x.prediction),
                    "missing_or_nonfinite_naive": ~np.isfinite(x["naive_" + naive]),
                    "naive_unavailable_at_issue_for_lead": pd.Series(False, index=x.index),
                }
                pair_ok = ~pd.DataFrame(conditions).any(axis=1)
                comparisons.append((model, naive, x, conditions, pair_ok))
                if intersection:
                    keys = pd.MultiIndex.from_frame(x.loc[pair_ok, KEY])
                    common_keys[naive] = (keys if naive not in common_keys
                                          else common_keys[naive].intersection(keys))
        for model, naive, x, conditions, pair_ok in comparisons:
            families = {"pairwise": pair_ok}
            if intersection:
                in_common = pd.MultiIndex.from_frame(x[KEY]).isin(common_keys[naive])
                families["all_models"] = pair_ok & in_common
            for family, mask in families.items():
                identity = dict(model=str(model), lead=int(lead), naive=naive, mask_family=family)
                sub = x[mask].copy()
                sub["naive"] = sub["naive_" + naive]
                digest = mask_hash(sub, lead)
                complete = sub[complete_day_mask(sub, timezone)]
                masks.append(dict(identity, mask_sha256=digest, n=len(sub), expected=len(grid),
                                  complete_day_n=len(complete), partial_day_n=len(sub) - len(complete),
                                  complete_day_mask_sha256=mask_hash(complete, lead), excluded_union=len(grid) - len(sub)))
                if save_masks:
                    name = hashlib.sha256((json.dumps(identity, sort_keys=True) + digest).encode()).hexdigest()[:24] + ".csv.gz"
                    sub[KEY].sort_values(KEY).to_csv(Path(save_masks) / name, index=False)
                    masks[-1]["mask_file"] = name
                local_conditions = dict(conditions)
                if family == "all_models":
                    local_conditions["outside_all_model_intersection"] = ~pd.MultiIndex.from_frame(x[KEY]).isin(common_keys[naive])
                for reason, lost in local_conditions.items():
                    for zone, n in x[lost].groupby("zone").size().items():
                        excluded.append(dict(identity, zone=zone, reason=reason, n=int(n)))
                groups = [(z, [z]) for z in zones] + [("all", zones)]
                non_it = [z for z in zones if not z.startswith("IT-")]
                if non_it and len(non_it) < len(zones):
                    groups.append(("excluding_italy", non_it))
                for group, group_zones in groups:
                    selection = sub[sub.zone.isin(group_zones)]
                    for coverage, subset in [("all_paired_cells", selection),
                                             ("complete_zone_days", selection[complete_day_mask(selection, timezone)])]:
                        for aggregation in ["pooled_cell", "mean_daily"]:
                            metrics.append(dict(identity, group=group, coverage=coverage, aggregation=aggregation,
                                                mask_sha256=mask_hash(subset, lead), **summarize(subset, aggregation)))
                    significance.append(dict(identity, group=group,
                                             **dm_for_group(selection, group_zones, timezone, lead, min_dm_days,
                                                            expected_dates=pd.date_range(start, end))))
    return {"metrics": pd.DataFrame(metrics), "masks": pd.DataFrame(masks),
            "exclusions": pd.DataFrame(excluded), "dm": pd.DataFrame(significance)}


def validate_manifest(manifest):
    required = ["source", "target_policy", "resolution", "market_day_timezone", "models",
                "fit_end", "cutoff_publication_class", "window", "missingness", "aggregation", "mask_sha256"]
    absent = [key for key in required if key not in manifest]
    if absent:
        raise ValueError("Missing contract fields: " + ", ".join(absent))
    if manifest["target_policy"] not in ["highest_seq", "sdac"] or manifest["resolution"] != "PT60M":
        raise ValueError("Explicit highest_seq/sdac hourly contract required")
    if set(manifest["aggregation"]) != {"pooled_cell", "mean_daily"}:
        raise ValueError("This contract emits pooled_cell and mean_daily; declare both exactly")
    if not manifest["models"] or len({m["id"] for m in manifest["models"]}) != len(manifest["models"]):
        raise ValueError("Declare distinct model IDs")
    if pd.Timestamp(manifest["window"]["start"]) > pd.Timestamp(manifest["window"]["end"]):
        raise ValueError("Window end precedes start")
    return manifest


def write_outputs(tables, manifest, output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    for name, table in tables.items():
        table.to_csv(output / (name + ".csv"), index=False)
    manifest = dict(manifest)
    manifest["mask_sha256"] = sha256_file(output / "masks.csv")
    manifest["evaluator_sha256"] = sha256_file(__file__)
    manifest["output_sha256"] = {name: sha256_file(output / (name + ".csv")) for name in tables}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--actuals", required=True)
    p.add_argument("--forecasts", required=True)
    p.add_argument("--manifest", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--save-masks")
    args = p.parse_args()
    manifest = validate_manifest(json.loads(Path(args.manifest).read_text()))
    for key, path in [("actuals", args.actuals), ("forecasts", args.forecasts)]:
        expected = manifest["source"].get(key, {}).get("sha256")
        if not expected or expected != sha256_file(path):
            raise ValueError("Source hash mismatch or missing: " + key)
    forecasts = read_frame(args.forecasts)
    if set(forecasts.model) != {m["id"] for m in manifest["models"]}:
        raise ValueError("Observed models differ from declared model IDs")
    tables = evaluate(read_frame(args.actuals), forecasts,
                      **manifest["window"], zones=manifest.get("zones"),
                      timezone=manifest["market_day_timezone"],
                      intersection=manifest.get("all_model_intersection", False), save_masks=args.save_masks)
    write_outputs(tables, manifest, args.output)


if __name__ == "__main__":
    main()
