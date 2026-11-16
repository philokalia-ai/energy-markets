#!/usr/bin/env python3
"""Prepare explicit, hashed saved-file cohorts. Source DuckDB is read-only.

No model fitting, production DB connections, credential use or source writes.
Raw prepared panels live outside the checkout; only aggregate outputs commit.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess

import duckdb
import numpy as np
import pandas as pd

from evaluate import VERSION, calendar, naive_forecasts, read_frame, sha256_file
from targets import ROOT, helper


def write_frame(frame, path):
    frame.to_csv(path, index=False, compression={"method": "gzip", "mtime": 0})
    return {"path": str(path), "sha256": sha256_file(path), "n": len(frame)}


def snapshot_sources(folder):
    return [{"path": str(path), "sha256": sha256_file(path)} for path in sorted(folder.glob("*.json"))
            if path.name != "snapshot-manifest.json"]


def saved_live(folder, start, end, min_cv=None):
    rows = []
    fields = {"sim": "physics", "gbm": "gbm_overlay", "stats": "stats_overlay", "tsfm": "tsfm_live"}
    for path in sorted(folder.glob("*.json")):
        if path.name == "snapshot-manifest.json":
            continue
        payload = json.loads(path.read_text())
        if payload.get("market_day_tz") != "Europe/Athens":
            raise ValueError("Unexpected market-day timezone: " + str(path))
        zone = payload["zone"]
        for day in payload["days"]:
            if not start <= day["date"] <= end or day["input_mode"] != "weather":
                continue
            if min_cv is not None and day["code_version"] < min_cv:
                continue
            for field, model in fields.items():
                values = day.get(field)
                values = [None] * len(day["hours"]) if values is None else values
                if len(values) != len(day["hours"]):
                    raise ValueError("Mismatched saved arrays")
                for t, value in zip(day["hours"], values):
                    rows.append(dict(zone=zone, t=t, model=model, lead=day["lead_days"],
                                     prediction=value,
                                     issue_utc=(day.get("prediction_made_utc") if field == "sim" else day.get("tsfm_issue_utc") if field == "tsfm" else None),
                                     base_cv=day["code_version"], saved_market_date=day["date"]))
    out = pd.DataFrame(rows)
    out["t"] = pd.to_datetime(out.t, utc=True)
    out["prediction"] = pd.to_numeric(out.prediction, errors="coerce")
    cal = calendar(out, "Europe/Athens")
    if not cal.market_date.dt.strftime("%Y-%m-%d").eq(out.saved_market_date).all():
        raise ValueError("JSON market-date / UTC-hour disagreement")
    # Do not create phantom multi-lead overlays when every saved value is null.
    available_groups = out.groupby(["model", "lead"]).prediction.transform(lambda x: np.isfinite(x).any())
    out = out[available_groups].copy()
    if out.duplicated(["model", "lead", "zone", "t"]).any():
        raise ValueError("Snapshot contains duplicate forecast vintages; explicit selection required")
    return out.drop(columns="saved_market_date")


def public_actual_history(folder):
    rows = []
    for path in sorted(folder.glob("*.json")):
        if path.name == "snapshot-manifest.json":
            continue
        payload = json.loads(path.read_text())
        cells = {}
        for day in payload["days"]:
            for t, value in zip(day["hours"], day["actual"]):
                if value is None:
                    continue
                value = round(float(value), 8)
                if t in cells and abs(cells[t] - value) > 1e-7:
                    raise ValueError("Inconsistent JSON actual across vintages")
                cells[t] = value
        rows.extend(dict(zone=payload["zone"], t=t, actual=value) for t, value in cells.items())
    return pd.DataFrame(rows)


def tsfm_forecasts(folder):
    """Freeze the original on-time cohort, including its historical D-2 mask.

    No D-2 benchmark is evaluated: its availability was part of the original
    47,679-cell cohort and is preserved only for that reconciliation.
    """
    old = read_frame(folder / "live_lead1.parquet")
    old = old[(old.input_mode == "weather") & old.date.between("2026-09-14", "2026-11-13")].copy()
    old["t"] = pd.to_datetime(old.t, utc=True)
    panel = read_frame(folder / "panel.parquet")[["zone", "t", "price"]].rename(columns={"price": "actual"})
    panel["t"] = pd.to_datetime(panel.t, utc=True)
    target = old[["zone", "t"]].assign(lead=1)
    lagged = naive_forecasts(panel, target)
    local = calendar(panel, "Europe/Athens")
    history = local.groupby(["zone", "market_date", "local_hour"]).actual.mean()
    keys = pd.MultiIndex.from_arrays([lagged.zone, lagged.market_date - pd.Timedelta(days=2), lagged.local_hour])
    lagged["naive_d2"] = history.reindex(keys).to_numpy()
    joined = old.merge(panel, on=["zone", "t"], validate="one_to_one").merge(
        lagged[["zone", "t", "naive_d1", "naive_d2", "naive_d7"]], on=["zone", "t"], validate="one_to_one")
    files = {"timestral_0630_prices": "fc_t209_uni_L1.parquet",
             "timestral_prices_matched_context": "fc_t209_uni_L1_c2048.parquet",
             "timestral_postsim": "fc_t209_sim_L1.parquet"}
    sources, rows = [], []
    for name, filename in files.items():
        path = folder / filename
        f = read_frame(path)
        f["t"] = pd.to_datetime(f.t, utc=True)
        joined = joined.merge(f[["zone", "t", "median"]].rename(columns={"median": name}),
                              on=["zone", "t"], validate="one_to_one")
        sources.append({"path": str(path), "sha256": sha256_file(path)})
    needed = ["actual", "sim", "naive_d1", "naive_d2", "naive_d7"] + list(files)
    eligible = np.isfinite(joined[needed]).all(axis=1)
    made = pd.to_datetime(joined.made, utc=True)
    cutoff = pd.to_datetime(joined.date, utc=True) - pd.Timedelta(days=1) + pd.Timedelta(hours=10)
    eligible &= made.le(cutoff)
    for model, column in [("physics", "sim")] + [(name, name) for name in files]:
        rows.append(joined[["zone", "t"]].assign(model=model, prediction=joined[column], lead=1,
                                                 eligible=eligible, issue_utc=cutoff))
    control = joined[eligible]
    reconciliation = [{"model": name, "n": len(control),
                       "mae": float((control[column] - control.actual).abs().mean())}
                      for name, column in [("physics", "sim")] + [(name, name) for name in files]]
    sources += [{"path": str(folder / f), "sha256": sha256_file(folder / f)}
                for f in ["live_lead1.parquet", "panel.parquet"]]
    return pd.concat(rows, ignore_index=True), sources, reconciliation


def historical_reconciliation(output):
    source = ROOT / "docs/experiments/forecast-eval-2026-08/full_model_metrics.csv"
    frame = pd.read_csv(source)
    weights = frame.energy / frame.energy.sum()
    rows = []
    for model, suffix, expected_mae, expected_rmae in [
        ("physics_cv37", "phys", 23.082, .814), ("hybrid_groupkfold_cv37", "full", 14.933, .516),
        ("stats_groupkfold_cv37", "stats", 14.494, .489)]:
        mae = float((frame["MAE_" + suffix] * weights).sum())
        rmae = float((frame["rMAE_" + suffix] * weights).sum())
        rows.append(dict(window="record", model=model, status="replayed rounded zone summaries",
                         original_target="saved original target; raw auction mix unavailable",
                         aggregation="energy-weighted mean of zone MAE and zone rMAE, after original row-shift mask",
                         mae=mae, expected_mae=expected_mae, rmae=rmae, expected_rmae=expected_rmae,
                         mae_difference=mae - expected_mae, rmae_difference=rmae - expected_rmae,
                         source=str(source.relative_to(ROOT)), source_sha256=sha256_file(source)))
    source = ROOT / "docs/experiments/model-lines-rolling-origin/output/rolling_origin.txt"
    text = source.read_text()
    pattern = r"^\s*(.+?)\s+n=([\d,]+) MAE\s+([\d.]+) bias\s+([+\-\d.]+)"
    for match in re.finditer(pattern, text, re.MULTILINE):
        rows.append(dict(window="rolling_cv39", model=match[1], status="original reported summary only",
                         original_target="canonical SDAC", aggregation="pooled unweighted cells",
                         n_reported=int(match[2].replace(",", "")), mae=float(match[3]), bias=float(match[4]),
                         source=str(source.relative_to(ROOT)), source_sha256=sha256_file(source)))
    pd.DataFrame(rows).to_csv(output / "historical-reconciliation.csv", index=False)
    unavailable = []
    for window in ["record", "rolling_cv39"]:
        for target in ["highest_seq", "sdac"]:
            unavailable.append(dict(window=window, target_policy=target, status="raw-cell reconciliation unavailable",
                                    n_scored=0, mask_sha256=None,
                                    reason="saved probe/OOS/rolling prediction parquet absent; confirmed by leader"))
    pd.DataFrame(unavailable).to_csv(output / "historical-availability.csv", index=False)


def model_metadata(model, frame):
    base = (sorted(frame.base_cv.dropna().astype(int).unique().tolist()) if "base_cv" in frame
            else None if "prices" in model else [40, 42])
    return {"id": model, "model_cv": base if model == "physics" else None,
            "model_id": "mistralai/Timestral-209M" if model.startswith("timestral_") else model,
            "artifact_cv": None, "artifact_sha256": None,
            "artifact_missing_reason": "rule engine; no serialized learned artifact" if model == "physics" else "checkpoint/artifact not identified by saved predictions",
            "base_cv": base,
            "model_input_price_policy": ("highest_seq saved context; unchanged by evaluation retarget" if model.startswith("timestral_")
                                         else "not established from snapshot" if model != "physics"
                                         else "no direct settled-price lag context; calibration overlap remains"),
            "leads": sorted(frame.lead.unique().astype(int).tolist()), "fit_end": None,
            "fit_end_class": ("no single fit cutoff; calibration overlaps evaluation" if model == "physics"
                              else "pretraining cutoff unknown" if model.startswith("timestral_")
                              else "unverifiable from saved overlays; no retraining here"),
            "publication_class": ("physics made-time in saved snapshot; first publication unverified" if model == "physics"
                                  else "reconstructed overlay, independent issuance unavailable" if model in ["gbm_overlay", "stats_overlay"]
                                  else "saved reconstruction; input cutoff is not first publication")}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--extract", type=Path, required=True)
    p.add_argument("--live", type=Path, required=True)
    p.add_argument("--fresh-live", type=Path, required=True)
    p.add_argument("--tsfm", type=Path, required=True)
    p.add_argument("--cache", type=Path, required=True)
    p.add_argument("--outputs", type=Path, required=True)
    args = p.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    args.outputs.mkdir(parents=True, exist_ok=True)
    print("hash source extract", flush=True)
    extract_hash = sha256_file(args.extract)
    with duckdb.connect(str(args.extract), read_only=True, config={"threads": 4, "memory_limit": "8GB"}) as cx:
        raw = helper.raw_rows(cx, "2024-06-01", "2026-11-18")
    print("source rows", len(raw), flush=True)
    targets = {"highest_seq": helper.highest_seq_hourly(raw)}
    targets["sdac"], target_exclusions, sequence_map = helper.sdac_hourly(raw)
    target_exclusions.groupby(["z", "reason"]).size().rename("n").reset_index().to_csv(
        args.outputs / "target-exclusions.csv", index=False)
    sequence_map.to_csv(args.outputs / "auction-map.csv", index=False)
    actual_sources = {}
    actual_frames = {}
    for target, data in targets.items():
        frame = data.rename(columns={"z": "zone", "act": "actual"})
        frame["t"] = pd.to_datetime(frame.t, utc=True)
        frame["actual"] = frame.actual.round(8)
        actual_frames[target] = frame
        actual_sources[target] = write_frame(frame, args.cache / (target + "-actuals.csv.gz"))
    public = public_actual_history(args.fresh_live)
    public["t"] = pd.to_datetime(public.t, utc=True)
    public = pd.concat([actual_frames["highest_seq"], public], ignore_index=True).drop_duplicates(["zone", "t"], keep="last")
    fresh_actual = write_frame(public, args.cache / "public-highest_seq-actuals.csv.gz")
    del raw, targets, actual_frames, public
    old_live = saved_live(args.live, "2026-09-14", "2026-11-13")
    fresh = saved_live(args.fresh_live, "2026-11-15", "2026-11-23", min_cv=43)
    # Only auction-settled dates, including tomorrow if already published.
    labeled = public_actual_history(args.fresh_live)
    labeled = labeled.assign(t=pd.to_datetime(labeled.t, utc=True))
    labeled = calendar(labeled, "Europe/Athens")
    fetched = json.loads((args.fresh_live / "snapshot-manifest.json").read_text())
    fetch_day = pd.Timestamp(fetched["fetch_finished_utc"]).tz_convert("Europe/Athens").tz_localize(None).normalize()
    # Day-ahead prices can already settle tomorrow. Do not extend the window
    # to a later, partially represented Athens date from UTC boundary hours.
    end = str(min(labeled.market_date.max(), fetch_day + pd.Timedelta(days=1)).date())
    fresh = fresh[calendar(fresh, "Europe/Athens").market_date.le(end)]
    tsfm, tsfm_sources, reconciliation = tsfm_forecasts(args.tsfm)
    pd.DataFrame(reconciliation).to_csv(args.outputs / "timestral-original-reconciliation.csv", index=False)
    windows = {"live_saved": (old_live, "2026-09-14", "2026-11-13", snapshot_sources(args.live)),
               "live_since_cv43": (fresh, "2026-11-15", end, snapshot_sources(args.fresh_live)),
               "timestral_ontime": (tsfm, "2026-09-14", "2026-11-13", tsfm_sources)}
    specifications = []
    for name, (forecasts, start, end, files) in windows.items():
        print("prepare", name, forecasts.shape, start, end, flush=True)
        source = write_frame(forecasts, args.cache / (name + "-forecasts.csv.gz"))
        models = [model_metadata(model, m) for model, m in forecasts.groupby("model")]
        for target in ["highest_seq", "sdac"]:
            act = fresh_actual if name == "live_since_cv43" and target == "highest_seq" else actual_sources[target]
            manifest = {
                "contract_version": VERSION, "name": name, "target_policy": target,
                "source": {"extract": {"path": str(args.extract), "sha256": extract_hash},
                           "actuals": act, "forecasts": source, "saved_sources": files,
                           "target_helper": {"path": str(helper.__file__), "sha256": sha256_file(helper.__file__)}},
                "resolution": "PT60M", "market_day_timezone": "Europe/Athens",
                "saved_predictions_changed": False,
                "models": models, "fit_end": None,
                "fit_end_reason": "not authenticated for saved overlays; foundation pretraining cutoff unknown",
                "cutoff_publication_class": ("offline reconstruction on original on-time physics subset; not authenticated first publication" if name == "timestral_ontime" else
                                             "saved public snapshot; made-time is not immutable first-publication proof; overlays may be retrospectively rewritten"),
                "naive_availability": "D1 and weekday: lead1 only; D7: leads1..7; source auction prices normally known by morning issue, initial revisions not archived",
                "target_history": ("fresh public highest-sequence JSON overrides older extract, including later dates" if name == "live_since_cv43" and target == "highest_seq" else "latest-revised read-only extract"),
                "window": {"start": start, "end": end}, "zones": sorted(forecasts.zone.unique().tolist()),
                "missingness": "no imputation; pairwise finite actual/forecast/naive; complete zone-days primary, partial cells separate; unknown SDAC auctions fail closed",
                "mask_sha256": None, "all_model_intersection": name == "timestral_ontime",
                "aggregation": ["pooled_cell", "mean_daily"],
                "aggregation_definition": "mean_daily weights each paired zone-day equally; no energy weights in new cohorts",
                "rmae": "ratio of paired aggregate absolute errors, never mean daily ratios; zero naive error undefined",
                "dst": "all23/25 UTC hours retained in point scores; source repeated local hour averaged; DM drops23/25-hour days",
                "dm": {"loss": "daily24h L1 vector", "hac": "Bartlett calendar lags max(7,lead-1)", "minimum_days": 30, "p_values": "one-sided model better; exploratory, unadjusted"},
                "prepared_utc": datetime.now(timezone.utc).isoformat(),
                "source_git_commit": subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip(),
            }
            snapshot = args.fresh_live / "snapshot-manifest.json"
            if name == "live_since_cv43":
                manifest["public_fetch"] = json.loads(snapshot.read_text())
            filename = name + "-" + target + ".json"
            (args.cache / filename).write_text(json.dumps(manifest, indent=2) + "\n")
            specifications.append(str(args.cache / filename))
    (args.cache / "pack.json").write_text(json.dumps(specifications, indent=2) + "\n")
    historical_reconciliation(args.outputs)
    print("pack ready", specifications, flush=True)


if __name__ == "__main__":
    main()
