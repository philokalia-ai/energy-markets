#!/usr/bin/env python3
"""Score fixed coupled ablation CSVs, preserving UTC-day coverage explicitly."""
import argparse
import json
import re
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

import collapse_probability as cp


def price_metrics(df):
    if len(df) == 0:
        return {"n": 0}
    err = df.price - df.actual
    actual, pred = df.actual <= 0, df.price <= 0
    tp, fp = int((actual & pred).sum()), int((~actual & pred).sum())
    return {"n": len(df), "mae": float(err.abs().mean()), "bias": float(err.mean()),
            "corr": float(df.price.corr(df.actual)) if df.price.std() > 0 and df.actual.std() > 0 else None,
            "actual_le_zero": int(actual.sum()), "predicted_le_zero": int(pred.sum()),
            "hits": tp, "false_alarms": fp,
            "precision": tp / (tp + fp) if tp + fp else None,
            "hit_rate": tp / int(actual.sum()) if actual.any() else None,
            "false_alarm_rate": fp / int((~actual).sum()) if (~actual).any() else None,
            "cap_prints": int((df.price >= 2999).sum()),
            "near_zero_positive": int(((df.price > 0) & (df.price < 1e-6)).sum())}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--extract", required=True)
    p.add_argument("--input", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--log", nargs="*", default=[])
    args = p.parse_args()
    rows, status = [], []
    timings = {}
    for log in args.log:
        passes = None
        progress = []
        log_text = Path(log).read_text()
        fallback_days = set(re.findall(r"re-clearing ([\d-]+) with fleet_truth_mode=:p95", log_text))
        for line in log_text.splitlines():
            m = re.search(r"24/24 periods \(([\d.]+)s, last=(\w+)(?:, (\d+) non-optimal)?\)", line)
            if m:
                progress.append({"elapsed_seconds": float(m[1]), "nonoptimal_periods": int(m[3] or 0)})
            m = re.search(r"Pass 2 accepted \(status=(\w+), solve=([\d.]+)s; pass 1 was ([\d.]+)s\)", line)
            if m:
                passes = {"pass1_solve_seconds": float(m[3]), "pass2_solve_seconds": float(m[2]),
                          "both_passes_solve_seconds": float(m[3]) + float(m[2])}
            m = re.search(r"COLLAPSE_RESULT day=([\d-]+) arm=(\w+)", line)
            if m:
                if passes:
                    if len(progress) >= 2:
                        passes.update({"pass1_nonoptimal_periods": progress[-2]["nonoptimal_periods"],
                                       "pass2_nonoptimal_periods": progress[-1]["nonoptimal_periods"],
                                       "pass1_decomposition_elapsed_seconds": progress[-2]["elapsed_seconds"],
                                       "pass2_decomposition_elapsed_seconds": progress[-1]["elapsed_seconds"],
                                       "discarded_decomposed_clears": progress[:-2],
                                       "automatic_p95_fleet_fallback": len(progress) > 2 and m[1] in fallback_days})
                    timings[(m[1], m[2])] = passes
                passes = None
                progress = []
    for path in sorted(Path(args.input).glob("*-baseline.csv")) + sorted(Path(args.input).glob("*-res_zero.csv")):
        info = json.loads(path.with_name(path.stem + "-status.json").read_text())
        info.update(timings.get((info["day"], info["arm"]), {}))
        info["solve_seconds_scope"] = "original field is final-pass-only, not full-day solver time"
        status.append(info)
        if info["status"] not in ("optimal", "time_limit"):
            continue
        x = pd.read_csv(path)
        complete = len(x) == 936 and x.zone.nunique() == 39 and (x.groupby("zone").t.nunique() == 24).all()
        info["included_full_price_vector"] = bool(complete)
        if not complete:
            continue
        # Include a full time-limit incumbent explicitly, with a separate
        # wrapper-optimal slice. Never present an incumbent as a proven optimum.
        x["wrapper_status"] = info["status"]
        x["delivery_utc_day"] = path.name[:10]
        # Engine timeslots are yyyymmdd-HHMM, or ISO DateTime in newer adapters.
        if x.t.astype(str).str.match(r"^\d{8}-\d{4}$").all():
            x["t"] = pd.to_datetime(x.t, format="%Y%m%d-%H%M")
        else:
            x["t"] = pd.to_datetime(x.t)
        rows.append(x)
    if not rows:
        raise ValueError("No complete returned coupled price vectors yet")
    prices = pd.concat(rows, ignore_index=True)
    common_days = set(prices.loc[prices.arm == "baseline", "delivery_utc_day"]) & set(
        prices.loc[prices.arm == "res_zero", "delivery_utc_day"])
    unpaired = sorted(set(prices.delivery_utc_day) - common_days)
    prices = prices[prices.delivery_utc_day.isin(common_days)]
    if prices.empty:
        raise ValueError("No completed baseline/treatment day pairs yet")
    con = duckdb.connect(args.extract, read_only=True, config={"threads": 4, "memory_limit": "8GB"})
    # evaluation labels: the target policy (EUPHEMIA_DA_TARGET, default sdac), not the
    # pinned model-input actuals (#431 C2)
    actuals = cp.hourly_actuals(con, "2026-09-01", "2026-11-15", role="target")
    prices = prices.merge(actuals, on=["zone", "t"], how="inner", validate="many_to_one")
    results, tables = {}, []
    for arm, x in prices.groupby("arm"):
        results[arm] = {"all39": price_metrics(x),
                        "excluding_italy": price_metrics(x[~x.zone.str.startswith("IT-")]),
                        "wrapper_optimal_only": price_metrics(x[x.wrapper_status == "optimal"]),
                        "time_limit_cells": int((x.wrapper_status == "time_limit").sum()),
                        "by_zone": {z: price_metrics(s) for z, s in x.groupby("zone")},
                        "by_utc_day": {str(d): price_metrics(s) for d, s in x.groupby("delivery_utc_day")}}
        for z, stats in results[arm]["by_zone"].items():
            tables.append({"arm": arm, "zone": z, **stats})
    paired = prices[prices.arm == "baseline"][["zone", "t", "delivery_utc_day", "price", "actual", "wrapper_status"]].merge(
        prices[prices.arm == "res_zero"][["zone", "t", "price", "wrapper_status"]], on=["zone", "t"], suffixes=("_base", "_candidate"), validate="one_to_one")
    changed = (paired.price_base - paired.price_candidate).abs() > 1e-6
    results["paired_change"] = {"n": len(paired), "changed_cells": int(changed.sum()),
                                "max_abs_change": float((paired.price_base - paired.price_candidate).abs().max()) if len(paired) else None,
                                "changed_actual_le_zero": int((changed & (paired.actual <= 0)).sum()),
                                "both_wrapper_optimal_cells": int(((paired.wrapper_status_base == "optimal") & (paired.wrapper_status_candidate == "optimal")).sum()),
                                "changed_by_zone": paired.assign(changed=changed).groupby("zone").changed.sum().to_dict()}
    optimal = paired[(paired.wrapper_status_base == "optimal") & (paired.wrapper_status_candidate == "optimal")]
    results["same_cells_both_wrapper_optimal"] = {
        arm: price_metrics(optimal.rename(columns={column: "price"}))
        for arm, column in [("baseline", "price_base"), ("res_zero", "price_candidate")]}
    fallback_days = sorted({r["day"] for r in status if r.get("automatic_p95_fleet_fallback")})
    results["automatic_fleet_fallback_days"] = fallback_days
    results["engine_fleet_fallback_audited"] = bool(args.log)
    results["excluding_engine_fleet_fallback"] = {
        arm: {"all39": price_metrics(x[~x.delivery_utc_day.isin(fallback_days)]),
              "excluding_italy": price_metrics(x[~x.delivery_utc_day.isin(fallback_days) & ~x.zone.str.startswith("IT-")])}
        for arm, x in prices.groupby("arm")}
    results["solver_audit"] = {}
    for arm in ["baseline", "res_zero"]:
        runs = [r for r in status if r["arm"] == arm and r["day"] in common_days]
        if not all("pass1_nonoptimal_periods" in r and "both_passes_solve_seconds" in r for r in runs):
            continue  # Price scoring remains usable without optional log files.
        period_count = 48 * len(runs)
        retained_seconds = sum(r["both_passes_solve_seconds"] for r in runs)
        results["solver_audit"][arm] = {
            "retained_periods": period_count,
            "retained_nonoptimal_periods": sum(r["pass1_nonoptimal_periods"] + r["pass2_nonoptimal_periods"] for r in runs),
            "pass2_nonoptimal_periods": sum(r["pass2_nonoptimal_periods"] for r in runs),
            "retained_solve_seconds": retained_seconds,
            "mean_retained_solve_seconds_per_period": retained_seconds / period_count,
            "discarded_decomposed_clears": sum(len(r["discarded_decomposed_clears"]) for r in runs),
            "discarded_decomposition_elapsed_seconds": sum(p["elapsed_seconds"] for r in runs for p in r["discarded_decomposed_clears"]),
            "final_wrapper_time_limit_days": sum(r["status"] == "time_limit" for r in runs)}
    results["status"] = status
    results["unpaired_completed_days_excluded"] = unpaired
    results["coverage_contract"] = "Selected UTC delivery days, not stitched Athens market days; latest-revision ENTSO-E proxy; both arms include analyst ac0ab5bfe079 fleet correction. Full time-limit incumbents are included and counted separately; final wrapper-optimal status does not certify an earlier anchor pass."
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    cp.dump_json(out / "clearing-metrics.json", results)
    pd.DataFrame(tables).to_csv(out / "clearing-by-zone.csv", index=False)
    print(json.dumps({k: {g: v[g] for g in ["all39", "excluding_italy"]} for k, v in results.items() if k in ["baseline", "res_zero"]}, indent=2))


if __name__ == "__main__":
    main()
