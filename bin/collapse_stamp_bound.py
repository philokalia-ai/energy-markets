#!/usr/bin/env python3
"""One fixed table bounding latest-revision gate-time proxy leakage."""
import argparse
from pathlib import Path

import duckdb
import pandas as pd

import collapse_probability as cp
from collapse_diagnostics import detection


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--extract", required=True)
    p.add_argument("--probability-dir", required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()
    con = duckdb.connect(args.extract, read_only=True, config={"threads": 4, "memory_limit": "8GB"})
    forecasts = cp.hourly_forecasts(con, "2026-09-13", "2026-11-15")
    base = None
    for variant, name in [("pregate_0630", "pre-gate 06:30"), ("gate_1000_latest_proxy", "gate latest proxy")]:
        pred = pd.read_csv(Path(args.probability_dir) / f"{variant}-predictions.csv.gz", parse_dates=["t", "market_date"])
        pred = pred[pred.model == "logistic"].rename(columns={"probability": name})
        if base is None:
            base = pred[["zone", "t", "market_date", "y", name]]
        else:
            base = base.merge(pred[["zone", "t", name]], on=["zone", "t"], validate="one_to_one")
    base = base.merge(forecasts, on=["zone", "t"], how="left", validate="one_to_one")
    gate = base.market_date - pd.Timedelta(days=1) + pd.Timedelta(hours=10)
    genuine = (base.t >= "2025-11-01") & base.load_stamp.notna()
    load = genuine & (base.load_stamp < gate)
    complete = base[["load", "solar", "wind"]].notna().all(axis=1)
    all_stamped = load & complete & (base.solar_stamp < gate) & (base.wind_stamp < gate)
    cases = [("All test cells", pd.Series(True, index=base.index)),
             ("Genuine load-stamp era", genuine),
             ("Load stored revision <10:00", load),
             ("Load+solar+wind stored revisions <10:00", all_stamped)]
    rows = []
    for subset, mask in cases:
        for group, groupmask in [("all39", pd.Series(True, index=base.index)),
                                 ("excluding_italy", ~base.zone.str.startswith("IT-"))]:
            data = base[mask & groupmask]
            for name in ["pre-gate 06:30", "gate latest proxy"]:
                row = {"subset": subset, "footprint": group, "model": name,
                       **cp.probability_metrics(data.y, data[name])}
                row["threshold_03"] = detection(data.y, data[name], 0.3) if len(data) else None
                rows.append(row)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    cp.dump_json(output / "stamp-bound.json", rows)
    def fmt(x):
        return "—" if x is None else f"{x:.4f}"
    lines = ["# Gate-time proxy: timestamp-qualified bound", "",
             "Fixed held-forward predictions, 2026-09-14..11-13. Subsets are selected by source timing only; no refit or threshold tuning. All probabilities below use the same 0.5 threshold. All test delivery dates are already after the audited genuine-load-stamp seam, so the era restriction alone removes no time leakage. The strict row requires load, solar and wind all present and their entire latest stored revisions strictly before 10:00 UTC D−1.", "",
             "| Subset | Model | n | ≤0 | Brier | Log-loss | AUC | Recall | Precision | FP rate |", "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in rows:
        if r["footprint"] != "all39":
            continue
        lines.append("| " + " | ".join([r["subset"], r["model"], str(r["n"]), str(r.get("positive", 0))] +
                                     [fmt(r.get(k)) for k in ["brier", "log_loss", "auc", "hit_rate", "precision", "false_alarm_rate"]]) + " |")
    lines += ["", "RES update_time belongs to the combined D−1/intraday/current row. A late stamp cannot recover the earlier D−1 value. A whole row already last updated before issuance is a conservative sufficient availability bound, not a D−1 publication timestamp. This table bounds test-feature timing; the original latest-revision training history is not refit here, and full historical source-version proof remains unavailable. Ex-Italy results and threshold-0.3 counts are retained in stamp-bound.json.", ""]
    (output / "stamp-bound.md").write_text("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
