#!/usr/bin/env python3
"""Score fixed coupled ablation CSVs, preserving UTC-day coverage explicitly."""
import argparse
import json
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
            "hit_rate": tp / int(actual.sum()) if actual.any() else None,
            "false_alarm_rate": fp / int((~actual).sum()) if (~actual).any() else None,
            "cap_prints": int((df.price >= 2999).sum()),
            "near_zero_positive": int(((df.price > 0) & (df.price < 1e-6)).sum())}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--extract", required=True)
    p.add_argument("--input", required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()
    rows, status = [], []
    for path in sorted(Path(args.input).glob("*-baseline.csv")) + sorted(Path(args.input).glob("*-res_zero.csv")):
        info = json.loads(path.with_name(path.stem + "-status.json").read_text())
        status.append(info)
        if info["status"] != "optimal":
            continue  # No partial / failed / incumbent scores hidden in aggregate.
        x = pd.read_csv(path)
        x["delivery_utc_day"] = path.name[:10]
        # Engine timeslots are yyyymmdd-HHMM, or ISO DateTime in newer adapters.
        if x.t.astype(str).str.match(r"^\d{8}-\d{4}$").all():
            x["t"] = pd.to_datetime(x.t, format="%Y%m%d-%H%M")
        else:
            x["t"] = pd.to_datetime(x.t)
        rows.append(x)
    if not rows:
        raise ValueError("No complete optimal coupled runs yet")
    prices = pd.concat(rows, ignore_index=True)
    con = duckdb.connect(args.extract, read_only=True, config={"threads": 4, "memory_limit": "8GB"})
    actuals = cp.hourly_actuals(con, "2026-09-01", "2026-11-15")
    prices = prices.merge(actuals, on=["zone", "t"], how="inner", validate="many_to_one")
    results, tables = {}, []
    for arm, x in prices.groupby("arm"):
        results[arm] = {"all39": price_metrics(x),
                        "excluding_italy": price_metrics(x[~x.zone.str.startswith("IT-")]),
                        "by_zone": {z: price_metrics(s) for z, s in x.groupby("zone")},
                        "by_utc_day": {str(d): price_metrics(s) for d, s in x.groupby("delivery_utc_day")}}
        for z, stats in results[arm]["by_zone"].items():
            tables.append({"arm": arm, "zone": z, **stats})
    paired = prices[prices.arm == "baseline"][["zone", "t", "delivery_utc_day", "price", "actual"]].merge(
        prices[prices.arm == "res_zero"][["zone", "t", "price"]], on=["zone", "t"], suffixes=("_base", "_candidate"), validate="one_to_one")
    changed = (paired.price_base - paired.price_candidate).abs() > 1e-6
    results["paired_change"] = {"n": len(paired), "changed_cells": int(changed.sum()),
                                "max_abs_change": float((paired.price_base - paired.price_candidate).abs().max()) if len(paired) else None,
                                "changed_actual_le_zero": int((changed & (paired.actual <= 0)).sum()),
                                "changed_by_zone": paired.assign(changed=changed).groupby("zone").changed.sum().to_dict()}
    results["status"] = status
    results["coverage_contract"] = "Eight selected UTC delivery days, not stitched Athens market days; latest-revision ENTSO-E proxy; both arms include analyst ac0ab5bfe079 fleet correction."
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    cp.dump_json(out / "clearing-metrics.json", results)
    pd.DataFrame(tables).to_csv(out / "clearing-by-zone.csv", index=False)
    print(json.dumps({k: {g: v[g] for g in ["all39", "excluding_italy"]} for k, v in results.items() if k in ["baseline", "res_zero"]}, indent=2))


if __name__ == "__main__":
    main()
