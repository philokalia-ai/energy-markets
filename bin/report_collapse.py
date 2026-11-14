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


def physical_report(data, out):
    """Preserve paired coverage and the bounded solver's incumbent status."""
    summary, days, runs = [], [], []
    statuses = {(r["day"], r["arm"]): r for r in data["status"]}
    for arm in ["baseline", "res_zero"]:
        for footprint in ["all39", "excluding_italy"]:
            summary.append(dict(arm=arm, footprint=footprint, **data[arm][footprint]))
        for day, metrics in sorted(data[arm]["by_utc_day"].items()):
            status = statuses[(day, arm)]
            days.append(dict(day=day, arm=arm, status=status["status"], **metrics))
        for status in sorted((r for r in data["status"] if r["arm"] == arm), key=lambda r: r["day"]):
            runs.append({k: status.get(k) for k in ["day", "arm", "status", "n", "wall_seconds", "pass1_solve_seconds", "pass2_solve_seconds", "both_passes_solve_seconds", "pass1_nonoptimal_periods", "pass2_nonoptimal_periods", "automatic_p95_fleet_fallback"]})
    days.sort(key=lambda row: (row["day"], row["arm"]))
    pd.DataFrame(summary).to_csv(out / "clearing-summary.csv", index=False)
    pd.DataFrame(days).to_csv(out / "clearing-by-day.csv", index=False)
    pd.DataFrame(runs).to_csv(out / "clearing-runs.csv", index=False)
    solver = [dict(arm=arm, **metrics) for arm, metrics in data["solver_audit"].items()]
    pd.DataFrame(solver).to_csv(out / "clearing-solver-audit.csv", index=False)
    change = data["paired_change"]
    cols = [("n", "n"), ("mae", "MAE"), ("bias", "Bias"), ("corr", "Corr"),
            ("actual_le_zero", "Events"), ("hits", "TP"), ("false_alarms", "FP"),
            ("hit_rate", "Recall"), ("precision", "Precision"), ("false_alarm_rate", "FP rate"), ("cap_prints", "Caps")]
    optimal = [dict(arm=arm, **metrics) for arm, metrics in data["same_cells_both_wrapper_optimal"].items()]
    return ["## Physical-price ablation", "",
            "One fixed zero-cost RES candidate, with supported-share overrides unset, on the eight prescribed UTC delivery days. Both arms include analyst fleet correction ac0ab5bfe079 and use the same 10:00 issuance context, HiGHS, two passes and latest-revision ENTSO-E forecasts. This is separate from the Athens-day probability evaluation. The per-period solver limit is 120 seconds (production default 900); full returned time-limit incumbents are included explicitly, without a repeat-solve or parameter search. September20/October19 used eight Julia threads; other dates used four. Each same-date pair shared its worker/settings. Incumbents can depend on solver scheduling.", "",
            table(summary, [("arm", "Arm"), ("footprint", "Footprint")] + cols), "",
            f"Paired coverage: {change['n']:,} cells per arm; two Sardinia actual UTC hours on September20 are missing. **Six of eight baseline days and four of eight RES days hit solver time limits on the old HiGHS stack** (Julia1.12.7, HiGHS.jl1.24.0/native1.15.0). Baseline time-limit cells: {data['baseline']['time_limit_cells']:,}; candidate: {data['res_zero']['time_limit_cells']:,}. The MAE verdict is **low confidence**, and is not a certified economic comparison. Final-wrapper-optimal status does not certify an earlier anchor pass. The two arms' individual optimal-only slices have different coverage and should not be compared directly. On exactly the same cells where both final wrappers are optimal:", "",
            table(optimal, [("arm", "Arm")] + cols), "",
            "### Every prescribed day", "",
            table(days, [("day", "UTC day"), ("arm", "Arm"), ("status", "Final wrapper")] + cols), "",
            "### Existing-log solver audit", "",
            table(solver, [("arm", "Arm"), ("retained_periods", "Retained periods"), ("retained_nonoptimal_periods", "Nonoptimal"), ("pass2_nonoptimal_periods", "Pass2 nonoptimal"), ("retained_solve_seconds", "Retained solve seconds"), ("mean_retained_solve_seconds_per_period", "Mean seconds/period"), ("discarded_decomposed_clears", "Discarded clears")]), "",
            "Counts come from each 24-period progress summary in the original logs. Timing is the engine's summed retained solve_time, not individual native HiGHS timers; per-hour timing quantiles were not logged. This aggregate does not show a uniform RES slowdown, while individual hard hours remain possible. November2 baseline discarded an incomplete first pass (773.2 seconds decomposition elapsed) and automatically rebuilt with p95 fleet books; the RES arm did not take that fallback. Its paired MAE delta is therefore confounded by a different effective fleet, and most previously unattributed baseline wall time is explained. Existing per-period retry rungs also remained enabled; no additional arm or manual score-driven rerun was made. Excluding that date from the existing outputs leaves 6,550 cells, MAE54.3966→54.3119 (−0.0847 €/MWh), a diagnostic slice rather than a new independent test.", "",
            f"{change['changed_cells']:,} paired prices change by more than 1e-6 €/MWh; {change['changed_actual_le_zero']} of these are actual collapse hours. Largest absolute change: {change['max_abs_change']:.4f} €/MWh. Per-zone MAE/bias/correlation and event counts are in clearing-by-zone.csv; exact run statuses and both-pass timings are in clearing-runs.csv. The engine's solve_time field alone is final-pass-only.", "",
            "The direct RES offer change does not alter thermal/hydro/must-run bidding rules, but coupling and the endogenous second-pass anchors can transmit its effect. On September20, the existing cv31 solar gate already fires in the offline TSO-input run; DE_LU still clears above zero because neighbours' positive supply sets the coupled margin. A zero RES offer alone does not remove that wall. These bounded incumbent diagnostics do not establish a general collapse-price cure; keep the RES flag off pending review and fuller solver validation.", "",
            "Independent second measurement: blocks' RES-only arm on September27 + November2, with its Italy + in-merit base, reports MAE delta −0.01 €/MWh, hits 1→10 and false alarms 1→13. A later seven-day relay excludes cap/floor cells and reports 6,523 cells, MAE delta+0.30, hits1→27 and false alarms1→16; its September20 RES pass2 had 2/24 time-limit periods and a 12:00 all-zone 3000 €/MWh cap incumbent. Its legacy/no-context contract differs from this experiment; its paired deltas are not pooled here. See the [archived report excerpt and relay](independent-res.md), sourced from em-team/reports/blocks.md at20:55UTC and the leader's subsequent message. Together these limited measurements support leaving the default unchanged, rather than a confident MAE verdict about the RES mechanism.", ""]


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
    audit = read(Path(args.probability_dir) / "audit.json")
    history_lag = audit.get("settled_history_lag", 2)
    history_description = ("The headline/default uses already-public D−1 delivery prices. The [D−2 conservative benchmark](conservative-lag2/results.md) is retained separately."
                           if history_lag == 1 else "This table is the labelled conservative D−2 price-history variant; the CLI default is D−1.")
    rows, byzone, reliability, thresholds, top_thresholds, selected_origins = [], [], [], [], [], []
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
                lag = d.get("settled_history_lag", history_lag)
                for choice in ["oracle_test_max_f1", "oracle_test_matched_zero_fpr", f"lag{lag}_indicator", f"oracle_test_matched_lag{lag}_fpr"]:
                    thresholds.append(dict(variant=variant, target=target, footprint=footprint, choice=choice, **d[key][footprint][choice]))
        selected = dict(d["hourly"]["validation_selected_max_f1"]["combined"])
        selected["threshold"] = None  # Each origin has its own preceding-window threshold.
        thresholds.append(dict(variant=variant, target="hour", footprint="all39", choice="prior_origin_selected_f1", **selected))
        for origin in d["hourly"]["validation_selected_max_f1"]["origins"]:
            selected_origins.append(dict(variant=variant, origin=origin["origin"],
                                         validation_n=origin["validation_n"],
                                         validation_positive=origin["validation_positive"], **origin["test"]))
        for zone, data in d["hourly_top8"].items():
            for threshold, metrics in data["fixed"].items():
                top_thresholds.append(dict(variant=variant, zone=zone, choice="fixed_" + threshold, **metrics))
    for name, data in [("probability-summary", rows), ("probability-by-zone", byzone), ("reliability", reliability), ("thresholds", thresholds), ("top8-thresholds", top_thresholds), ("selected-thresholds-by-origin", selected_origins)]:
        pd.DataFrame(data).to_csv(out / f"{name}.csv", index=False)
    top = []
    for z, thresholds_z in diagnostics[variants[0]]["hourly_top8"].items():
        a, b = hourly[variants[0]]["logistic"]["by_zone"][z], hourly[variants[1]]["logistic"]["by_zone"][z]
        top.append(dict(zone=z, events=a["positive"], brier=a["brier"], auc=a["auc"],
                        hits=a["hits"], fp=a["false_alarms"], recall=a["hit_rate"], precision=a["precision"],
                        recall_02=thresholds_z["fixed"]["0.2"]["recall"],
                        precision_02=thresholds_z["fixed"]["0.2"]["precision"], proxy_brier=b["brier"], proxy_auc=b["auc"]))
    first_bin = diagnostics[variants[0]]["daily"]["logistic"]["reliability"][0]
    text = ["# Held-forward probability results", "",
            f"Window: 2026-09-14..2026-11-13; training starts 2024-07-01. Monthly origins 09-14 / 10-01 / 11-01; training labels through origin D−{history_lag}. {history_description} Hourly target is the mean SDAC settled price ≤0; daily target is any hourly mean ≤0 in a complete Athens market day. Numeric sequences are ordered before deduplication, and hourly means are rounded to eight decimal places. All classification figures in the first table use threshold 0.5.", "",
            table(rows, [("variant", "Variant"), ("target", "Target"), ("footprint", "Footprint"), ("model", "Model"),
                         ("n", "n"), ("positive", "Events"), ("brier", "Brier"), ("log_loss", "Log-loss"),
                         ("auc", "AUC"), ("hit_rate", "Recall"), ("precision", "Precision"), ("false_alarm_rate", "FP rate")]), "",
            "## Threshold choice", "",
            f"No score-driven model search. Test-optimal F1 and matched-FP points are **oracle descriptions of the held-forward ROC/PR curve**, not deployable thresholds. A separate F1 threshold uses previously issued predictions on the 28-day window ending origin D−{history_lag}. Later test labels never select an earlier threshold.", "",
            table([r for r in thresholds if r["footprint"] == "all39"],
                  [("variant", "Variant"), ("target", "Target"), ("choice", "Choice"), ("threshold", "Threshold"),
                   ("recall", "Recall"), ("precision", "Precision"), ("f1", "F1"), ("hits", "TP"), ("false_alarms", "FP"), ("false_alarm_rate", "FP rate")]), "",
            "## Eight zones with most hourly collapses", "",
            "Ranking is for presentation only; ties use zone name. Each row has 1,465 held-forward hours. The main table gives per-zone precision and recall at 0.5; probability-by-zone.csv covers every zone, top8-thresholds.csv adds 0.2/0.3/0.5 for these eight zones, and selected-thresholds-by-origin.csv records the preceding-window F1 thresholds.", "",
            table(top, [("zone", "Zone"), ("events", "Events"), ("brier", "Pre-gate Brier"), ("auc", "AUC"),
                        ("hits", "TP"), ("fp", "FP"), ("recall", "Recall .5"), ("precision", "Precision .5"),
                        ("recall_02", "Recall .2"), ("precision_02", "Precision .2"), ("proxy_brier", "Proxy Brier"), ("proxy_auc", "Proxy AUC")]), "",
            f"Coverage: 57,111 of 57,135 possible hours (24 missing Sardinia prices); 2,377 of 2,379 complete zone-days (the gap straddles two Athens days). All 39 zones are scored; ex-Italy n=46,880 hours / 1,952 days. Complete physical features: pre-gate {audit['pregate_0630']['physical_complete']:,} hours, proxy {audit['gate_1000_latest_proxy']['physical_complete']:,} hours. Other cells retain calendar/history features and missing indicators.", "",
            "On 54,303 exact common live cells there are **710 canonical collapse labels**, with no disagreement after normalizing both sources to eight decimals. The immutable sim has zero ≤0 predictions. Published lead-1 weather forecasts were frozen 08:16–10:06 UTC D−1, later than 06:30; seven days were a few minutes after the summer auction gate.", "",
            "## Leakage and calibration limits", "",
            "The [timestamp-bound table](stamp-bound.md) prevents a gate-time performance claim: only 877 cells have load+solar+wind stored revisions all before 10:00, containing zero collapse events. Latest-D1 scores measure potential information, not a verified gate-time replay. Pre-gate raw revisions are filtered before resolution selection. No ERA5, target-day observations or future labels enter the 06:30 model.", "",
            f"Reliability is imperfect: the pre-gate day model's lowest bin averages {100*first_bin['mean_probability']:.1f}% risk while observing {100*first_bin['event_rate']:.1f}% over {first_bin['n']} zone-days; higher bins have few samples. This is a candidate for a prospective archived-input pilot, not a claim of calibrated operational alerts. Reliability counts are in reliability.csv; undefined AUC/recall/precision are null. No seasonal-generalization claim or uncertainty interval is inferred from two months.", ""]
    foundation = out / "foundation-comparison.csv"
    if foundation.exists():
        f = pd.read_csv(foundation)
        text += ["## Foundation-model comparator", "",
                 f"Chronos-2 prices-only D−{history_lag} forecasts match the headline settled-information cutoff, verified from every context_end_utc and the prior auction's price availability. Both models are scored on exactly 57,111 cells; the logistic model additionally uses calendar and accepted load/RES persistence. This compares these pipelines, not model families in isolation. Quantile-interpolated Chronos probabilities are clipped to [0.005, 0.995] by its author.", "",
                 table(f[f.footprint.isin(["all39", "excluding_italy"])].to_dict("records"),
                       [("footprint", "Footprint"), ("model", "Model"), ("n", "n"), ("positive", "Events"),
                        ("brier", "Brier"), ("log_loss", "Log-loss"), ("auc", "AUC"), ("hit_rate", "Recall .5"), ("precision", "Precision .5")]), ""]
    history = out / "price-history-sensitivity.csv"
    if history.exists():
        h = pd.read_csv(history)
        text += ["## Default D−1 history and conservative D−2 comparison", "",
                 "D−1 delivery day-ahead prices are auctioned/published on D−2, so they are normally known by the D−1 morning issue ([Nord Pool daily process](https://www.nordpoolgroup.com/en/the-power-market/Day-ahead-market/)). The default uses this price history, recent price-event frequencies and training labels through D−1. Forecast-publication rules and physical D−2 forecast persistence stay unchanged. C=1 and monthly origins are identical in the labelled conservative D−2 benchmark. This is additional public information, with no model-parameter search. Initial price revisions are not archived in the extract.", "",
                 table(h.to_dict("records"), [("variant", "Price history"), ("target", "Target"), ("footprint", "Footprint"),
                       ("n", "n"), ("positive", "Events"), ("brier", "Brier"), ("log_loss", "Log-loss"), ("auc", "AUC"),
                       ("hit_rate", "Recall .5"), ("precision", "Precision .5"), ("false_alarm_rate", "FP rate .5")]), "",
                 "The inference CLI defaults to --settled-lag 1 and writes priceL1 artifacts. Use --settled-lag 2 for the labelled conservative variant. Threshold-0.2/0.3 metrics are in price-history-sensitivity.csv; every zone is in price-history-by-zone.csv.", ""]
    clearing = out / "clearing-metrics.json"
    if clearing.exists():
        text += physical_report(read(clearing), out)
    else:
        text += ["## Physical-price ablation", "",
                 "Corrected-fleet eight-day run pending. It clears UTC delivery days under a 10:00 issuance context (recent-generation latency cutoffs active), with latest-revision ENTSO-E forecasts. Both arms include analyst patch ac0ab5bfe079. It is separate from the Athens market-day probability evaluation.", ""]
    (out / "results.md").write_text("\n".join(text))


if __name__ == "__main__":
    main()
