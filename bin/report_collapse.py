#!/usr/bin/env python3
"""Render the fixed probability evaluation artifacts as reviewable CSV/Markdown."""
import argparse
import json
from pathlib import Path

import pandas as pd


def table(rows, columns):
    def cell(value):
        if value is None:
            return "—"
        if isinstance(value, float):
            return f"{value:.4f}"
        return str(value)
    out = ["| " + " | ".join(label for _, label in columns) + " |",
           "| " + " | ".join("---" for _ in columns) + " |"]
    out += ["| " + " | ".join(cell(r.get(k)) for k, _ in columns) + " |" for r in rows]
    return "\n".join(out)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--probability-dir", required=True)
    p.add_argument("--diagnostics-dir", required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()
    source, out = Path(args.diagnostics_dir), Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    read = lambda path: json.loads(path.read_text())
    variants = ["pregate_0630", "gate_1000_latest_proxy"]
    diagnostics = {v: read(source / f"{v}-diagnostics.json") for v in variants}
    hourly = {v: read(source / f"{v}-metrics.json") for v in variants}
    rows, byzone, reliability, thresholds = [], [], [], []
    for variant in variants:
        d = diagnostics[variant]
        for target, data in [("hour", hourly[variant]), ("day", d["daily"])]:
            for model, m in data.items():
                for footprint, key in [("all39", "pooled"), ("excluding_italy", "excluding_italy")]:
                    rows.append(dict(variant=variant, target=target, model=model, footprint=footprint, **m[key]))
                byzone += [dict(variant=variant, target=target, model=model, zone=z, **s) for z, s in m["by_zone"].items()]
                reliability += [dict(variant=variant, target=target, model=model, **r) for r in m["reliability"]]
        for target, key in [("hour", "hourly"), ("day", "daily_thresholds")]:
            for footprint in ["all39", "excluding_italy"]:
                for threshold, metrics in d[key][footprint]["fixed"].items():
                    thresholds.append(dict(variant=variant, target=target, footprint=footprint, choice="fixed_" + threshold, **metrics))
                for choice in ["oracle_test_max_f1", "oracle_test_matched_zero_fpr", "lag2_indicator", "oracle_test_matched_lag2_fpr"]:
                    thresholds.append(dict(variant=variant, target=target, footprint=footprint, choice=choice, **d[key][footprint][choice]))
        thresholds.append(dict(variant=variant, target="hour", footprint="all39", choice="prior_origin_selected_f1",
                               **d["hourly"]["validation_selected_max_f1"]["combined"]))
    for name, data in [("probability-summary", rows), ("probability-by-zone", byzone), ("reliability", reliability), ("thresholds", thresholds)]:
        pd.DataFrame(data).to_csv(out / f"{name}.csv", index=False)
    top = []
    for z, thresholds_z in diagnostics[variants[0]]["hourly_top8"].items():
        a, b = hourly[variants[0]]["logistic"]["by_zone"][z], hourly[variants[1]]["logistic"]["by_zone"][z]
        top.append(dict(zone=z, events=a["positive"], brier=a["brier"], auc=a["auc"],
                        hits=a["hits"], fp=a["false_alarms"], recall=a["hit_rate"], precision=a["precision"],
                        recall_02=thresholds_z["fixed"]["0.2"]["recall"],
                        precision_02=thresholds_z["fixed"]["0.2"]["precision"], proxy_brier=b["brier"], proxy_auc=b["auc"]))
    audit = read(Path(args.probability_dir) / "audit.json")
    text = ["# Held-forward probability results", "",
            "Window: 2026-09-14..2026-11-13; training starts 2024-07-01. Monthly origins 09-14 / 10-01 / 11-01; training labels through origin D−2. Hourly target is the mean SDAC settled price ≤0; daily target is any hourly mean ≤0 in a complete Athens market day. Numeric sequences are ordered before deduplication, and hourly means are rounded to eight decimal places. All classification figures in the first table use threshold 0.5.", "",
            table(rows, [("variant", "Variant"), ("target", "Target"), ("footprint", "Footprint"), ("model", "Model"),
                         ("n", "n"), ("positive", "Events"), ("brier", "Brier"), ("log_loss", "Log-loss"),
                         ("auc", "AUC"), ("hit_rate", "Recall"), ("precision", "Precision"), ("false_alarm_rate", "FP rate")]), "",
            "## Threshold choice", "",
            "No score-driven model search. Test-optimal F1 and matched-FP points are **oracle descriptions of the held-forward ROC/PR curve**, not deployable thresholds. A separate F1 threshold uses previously issued predictions on the 28-day window ending origin D−2. Later test labels never select an earlier threshold.", "",
            table([r for r in thresholds if r["footprint"] == "all39"],
                  [("variant", "Variant"), ("target", "Target"), ("choice", "Choice"), ("threshold", "Threshold"),
                   ("recall", "Recall"), ("precision", "Precision"), ("f1", "F1"), ("hits", "TP"), ("false_alarms", "FP"), ("false_alarm_rate", "FP rate")]), "",
            "## Eight zones with most hourly collapses", "",
            "Ranking is for presentation only; ties use zone name. Each row has 1,465 held-forward hours. The main table gives per-zone precision and recall at 0.5; the adjacent CSVs cover every zone and thresholds 0.2/0.3.", "",
            table(top, [("zone", "Zone"), ("events", "Events"), ("brier", "Pre-gate Brier"), ("auc", "AUC"),
                        ("hits", "TP"), ("fp", "FP"), ("recall", "Recall .5"), ("precision", "Precision .5"),
                        ("recall_02", "Recall .2"), ("precision_02", "Precision .2"), ("proxy_brier", "Proxy Brier"), ("proxy_auc", "Proxy AUC")]), "",
            f"Coverage: 57,111 of 57,135 possible hours (24 missing Sardinia prices); 2,377 of 2,379 complete zone-days (the gap straddles two Athens days). All 39 zones are scored; ex-Italy n=46,880 hours / 1,952 days. Complete physical features: pre-gate {audit['pregate_0630']['physical_complete']:,} hours, proxy {audit['gate_1000_latest_proxy']['physical_complete']:,} hours. Other cells retain calendar/history features and missing indicators.", "",
            "On 54,303 exact common live cells there are **710 canonical collapse labels**, with no disagreement after normalizing both sources to eight decimals. The immutable sim has zero ≤0 predictions. Published lead-1 weather forecasts were frozen 08:16–10:06 UTC D−1, later than 06:30; seven days were a few minutes after the summer auction gate.", "",
            "## Leakage and calibration limits", "",
            "The [timestamp-bound table](stamp-bound.md) prevents a gate-time performance claim: only 877 cells have load+solar+wind stored revisions all before 10:00, containing zero collapse events. Latest-D1 scores measure potential information, not a verified gate-time replay. Pre-gate raw revisions are filtered before resolution selection. No ERA5, target-day observations or future labels enter the 06:30 model.", "",
            "Reliability is imperfect: the pre-gate day model's <0.1 bin predicts about 1.5% risk while observing about 3.7%; higher bins have few samples. This is a candidate for a prospective archived-input pilot, not a claim of calibrated operational alerts. Reliability counts are in reliability.csv; undefined AUC/recall/precision are null. No seasonal-generalization claim or uncertainty interval is inferred from two months.", ""]
    foundation = out / "foundation-comparison.csv"
    if foundation.exists():
        f = pd.read_csv(foundation)
        text += ["## Foundation-model comparator", "",
                 "Chronos-2 prices-only D−2 forecasts match the conservative settled-information cutoff, verified from every context_end_utc. Both models are scored on exactly 57,111 cells; the logistic model additionally uses calendar and accepted load/RES persistence. This compares these pipelines, not model families in isolation. Quantile-interpolated Chronos probabilities are clipped to [0.005, 0.995] by its author.", "",
                 table(f[f.footprint.isin(["all39", "excluding_italy"])].to_dict("records"),
                       [("footprint", "Footprint"), ("model", "Model"), ("n", "n"), ("positive", "Events"),
                        ("brier", "Brier"), ("log_loss", "Log-loss"), ("auc", "AUC"), ("hit_rate", "Recall .5"), ("precision", "Precision .5")]), ""]
    text += ["## Physical-price ablation", "",
             "Corrected-fleet eight-day run pending. It clears UTC delivery days under a 10:00 issuance context (recent-generation latency cutoffs active), with latest-revision ENTSO-E forecasts. Both arms include analyst patch ac0ab5bfe079. It is separate from the Athens market-day probability evaluation.", ""]
    (out / "results.md").write_text("\n".join(text))


if __name__ == "__main__":
    main()
