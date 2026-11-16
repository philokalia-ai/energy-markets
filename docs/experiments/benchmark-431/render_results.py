#!/usr/bin/env python3
"""Render the committed benchmark outputs; no data access beyond these files."""
import argparse
import json
from pathlib import Path

import pandas as pd


def table(frame, columns):
    def cell(value):
        if pd.isna(value):
            return "—"
        if isinstance(value, float):
            return f"{value:.6g}"
        return str(value)
    text = ["| " + " | ".join(label for _, label in columns) + " |",
            "| " + " | ".join("---" for _ in columns) + " |"]
    for row in frame.to_dict("records"):
        text.append("| " + " | ".join(cell(row.get(key)) for key, _ in columns) + " |")
    return "\n".join(text)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--outputs", type=Path, required=True)
    args = p.parse_args()
    root = args.outputs
    scores = pd.read_csv(root / "headlines.csv")
    base = scores[(scores.group == "all") & (scores.lead == 1) &
                  (scores.naive == "epf") & (scores.mask_family == "pairwise")]
    primary = base[(base.coverage == "complete_zone_days") & (base.aggregation == "mean_daily")]
    partial = base[(base.coverage == "all_paired_cells") & (base.aggregation == "pooled_cell")]
    primary.to_csv(root / "primary-lead1-epf.csv", index=False)
    all_naives = scores[(scores.group == "all") & (scores.lead == 1) &
                        (scores.mask_family == "pairwise") & (scores.coverage == "complete_zone_days") &
                        (scores.aggregation == "mean_daily")]
    all_naives.to_csv(root / "primary-three-naives.csv", index=False)
    columns = [("target_policy", "Target"), ("model", "Saved line"), ("n", "n"),
               ("n_market_days", "Dates"), ("mae", "MAE"), ("bias", "Bias"),
               ("naive_mae", "EPF MAE"), ("rmae", "rMAE EPF"),
               ("mean_price", "Mean price"), ("mae_over_mean_price", "MAE/mean"),
               ("share_le_zero", "Share≤0")]
    text = ["# #431 saved-file benchmark results", "",
            "All prices/errors are EUR/MWh; ratios/shares are fractions. Primary tables use complete paired Athens zone-days and the site's equal-zone-day mean estimator. Each saved line is compared with the weekday naive on **its own paired mask**. Rows with different masks do not rank models against each other; source publication classes remain those in the manifests. Both targets are shown explicitly.", "",
            "The [three-naive table](primary-three-naives.csv) gives D−1/D−7/weekday comparisons with each denominator and n. All per-zone, per-lead, both-aggregation and partial-cell outputs are in the six contract directories. Leads2–7 emit D−7 only. The [mask index](mask-index.csv) pins every paired cohort; `all_models` is a separate optional cohort, demonstrated on Timestral.", ""]
    for window in ["live_saved", "live_since_cv43", "timestral_ontime"]:
        text += ["## " + window, "", table(primary[primary.window == window], columns), ""]
        if window == "live_saved":
            text += ["Window: 2026-09-14..11-13. GBM/stats are reconstructed overlays with missing independent issuance/fit metadata; especially higher-lead values are not authenticated multi-day forecasts. Their much smaller masks cannot be used to rank them directly against all-cell physics. No 06:30 publication claim is inferred.", ""]
        elif window == "live_since_cv43":
            text += ["Only two complete highest-sequence lead1 dates, November16/17, mixed cv43/44. November17's DA prices were already in the fetched public snapshot; physical delivery need not be complete for a settled DA-price target. The older raw extract supplies only39 partial SDAC cells (one hour per zone), so **zero complete SDAC zone-days** are scored. Their secondary partial-cell MAE below is not a comparable two-day estimate. Both DM cohorts are insufficient data; no new-cv generalization claim.", ""]
        else:
            provenance = json.loads((root / "timestral_ontime-highest_seq/manifest.json").read_text())
            physics = next(model for model in provenance["models"] if model["id"] == "physics")
            versions = ", ".join(f"{count:,} cv{version}" for version, count in physics["base_cv_counts"].items())
            text += [f"Saved physics provenance in the eligible original cohort: {versions}. The physics model and post-sim base share these versions; prices-only models have no physics base. These counts precede target-policy and complete-zone-day restrictions.", ""]
            text += ["The original on-time cohort has exactly47,679 paired cells. Highest-sequence all-paired MAE is25.2647108 for post-sim versus28.8190692 for its matched-context prices-only control; replay is exact. Complete paired zone-days leave47,631 cells, hence slightly different primary estimates. The SDAC retarget also changes the targets, while saved model contexts stay unchanged. On-time refers to the physics-input cutoff, not authenticated first public release.", ""]
    text += ["## Secondary: all paired cells, pooled estimator", "",
             "Partial zone-days and DST hours are retained here. Mean-daily values on this same partial cohort are also present in headlines.csv, so estimator and coverage changes can be separated.", "",
             table(partial, [("window", "Window")] + columns), "",
             "## Original historical estimators; raw-cell reconciliation unavailable", "",
             "These are separately labelled original protocols, not new comparable cell scores. The record's rounded zone metrics reproduce the original energy-weighted summary to its printed precision. Its rMAE is a weighted mean of zone ratios after a row-offset weekly mask; this pack's new rMAE is a ratio of paired aggregate errors using keyed lags. GroupKFold ML rows are nonchronological. Rolling-origin values are read from the committed report, not recalculated from absent predictions.", "",
             table(pd.read_csv(root / "historical-reconciliation.csv"),
                   [("window", "Window"), ("model", "Model"), ("status", "Evidence"),
                    ("mae", "MAE"), ("rmae", "rMAE"), ("n_reported", "Original n"),
                    ("aggregation", "Original estimator")]), "",
             table(pd.read_csv(root / "historical-availability.csv"),
                   [("window", "Window"), ("target_policy", "Requested target"),
                    ("n_scored", "New cells scored"), ("status", "Status")]), "",
             "A keyed local-hour lag can differ from a row168 shift around gaps/DST; SDAC retargets AT/DE_LU and applies complete-hour rules. Their new numerical effect cannot be recovered without the raw historical predictions. No invented masks, naive denominators, per-zone new targets or DM p-values are attached to the summary-only windows.", "",
             "## Daily-vector DM versus the weekday naive", "",
             "One-sided p favors the saved model; it is exploratory and unadjusted. Require30 complete, non-DST, balanced24-hour daily vectors. Footprints use absolute errors before zone averaging. Daily HAC keeps calendar gaps, bandwidth max(7,lead−1). Missing/short windows say insufficient data rather than manufacturing significance.", ""]
    dm = pd.read_csv(root / "footprint-dm.csv")
    dm = dm[(dm.group == "all") & (dm.lead == 1) & (dm.naive == "epf") & (dm.mask_family == "pairwise")]
    text += [table(dm, [("window", "Window"), ("target_policy", "Target"), ("model", "Saved line"),
                       ("n_days", "Balanced dates"), ("statistic", "DM"), ("p_model_better", "p(model better)"),
                       ("status", "Status")]), "",
             "The six per-contract manifests identify source/helper/evaluator hashes, fit/cutoff limitations and every output hash. Public snapshot fetch times span2026-11-16T19:28..19:29UTC. The overlap audit records differences from the older extract; it is not an issue-time revision archive. See the parent README for the contract, exact filenames, reproducibility and licence check. No external paper scores are placed beside these results.", ""]
    (root / "RESULTS.md").write_text("\n".join(text))


if __name__ == "__main__":
    main()
