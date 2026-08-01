# Documentation index

## Model

- [model-spec-exante.md](model-spec-exante.md) — **Start here.** Standalone spec of the fully ex-ante model: inputs, the six strategy classes, per-zone parameters, and the honest per-regime performance table (frozen 36-day sample).
- [calibration-atlas.md](calibration-atlas.md) — How the EU-wide counterfactual is built: the clearing workflow, per-region strategies, the bid skeleton, mechanism inventory, and the calibration doctrine.
- [ex-ante-flows.md](ex-ante-flows.md) — The `:v2` ex-ante flow rule (climatology + D-7 Norwegian recency): per-border-class evidence, measured alternatives, and the NO1 open problem.
- [ex-ante-audit.md](ex-ante-audit.md) — The D-1-legality audit: every book input classified as ex-ante-legal or a forward-looking leak.
- [scenario-api.md](scenario-api.md) — The counterfactual scenario API (`ZoneScenario`): demand/RES modifiers, extra orders, strategist bid rewrites, fleet edits — with measured multi-zone worked examples.
- [predictions.md](predictions.md) — The **open, reproducible RES/load input model** behind the site's "Predicting RES & loads" page: targets, D-1 GFS vintage discipline, features, LightGBM training protocol, the committed model dumps + Julia scorer, equivalence numbers, and the `v1/inputs/` data plane.

## Calibration history

- [eu-footprint-experiment.md](eu-footprint-experiment.md) — The original 38-zone experiment: does endogenizing cross-border flows remove the forward-looking bias?
- [eu-calibration-iter1.md](eu-calibration-iter1.md) — Iteration 1: generalizing the SEE-validated book to the EU footprint.
- [eu-calibration-iter2.md](eu-calibration-iter2.md) — Iteration 2: France (nuclear opportunity floor) and Norway (export-anchored hydro).
- [eu-calibration-iter3.md](eu-calibration-iter3.md) — Iteration 3: MPCC per-order Big-M root fix, the CH profile, diagnostics.
- [eu-calibration-iter4.md](eu-calibration-iter4.md) — Iteration 4: resolution-aware evaluation methodology, the Hungary border drop, joint CH/AT alpine rollout.
- [eu-calibration-iter5.md](eu-calibration-iter5.md) — Iteration 5: SE3/SE4 flow-based-domain drops, the AT anchor share, Belgium.
- [eu-calibration-iter6.md](eu-calibration-iter6.md) — Iteration 6: full-year seasonal transfer, the SK Core-FBMC blow-up, seasonal reservoir-drawdown water value, the frozen 36-day sample.
- [eu-calibration-iter7.md](eu-calibration-iter7.md) — Iteration 7: installed-capacity-aware fleet truth (`:installed`), Baltics enabled, the DE phantom-nuclear trap.
- [eu-calibration-iter8.md](eu-calibration-iter8.md) — Iteration 8: MPCC false-infeasibility root cause (indicator-constraint retry rung), per-day fallback, continental `:installed` (DE_LU corr → 0.80).
- [research-roadmap.md](research-roadmap.md) — The research program: competitive counterfactual → strategic-bidding detection.
- [phase-b-analysis.md](phase-b-analysis.md) — Statistical attribution of the counterfactual residual (candidate hypotheses, not accusations).
- [phase-b-findings.md](phase-b-findings.md) — Per-unit attribution of counterfactual residuals (working research notes).
- [iterative-uc-mpcc-results.md](iterative-uc-mpcc-results.md) — Results of the (legacy) iterative UC-MPCC feedback-loop approach.
- [uc-interconnection-approaches.md](uc-interconnection-approaches.md) — Design notes on jointly optimizing unit commitment and interconnections.

## Infrastructure

- [reproducibility.md](reproducibility.md) — The public data artifact (parquet + DuckDB), checksum verification, `bin/reproduce.jl` tiers, parallel/pipelined runs, and the two honest caveats (numerics, licensing).

## Data

- [problem-zones-data-issues.md](problem-zones-data-issues.md) — Zones that fail UC due to missing data: root causes.
- [infeasible-zones-analysis.md](infeasible-zones-analysis.md) — Zones that fail UC despite valid data: constraint analysis.
- [unknown-other-generators.md](unknown-other-generators.md) — Generators classified "Other" in ENTSO-E that need manual technology review.
- [weather-data-evaluation.md](weather-data-evaluation.md) — Whether the weather database improves day-ahead price accuracy (measured: it doesn't, yet).

## Result data

- `exante-results/`, `iter6-results/`, `iter7-results/`, `iter8-results/` — per-zone metric CSVs backing the calibration iteration docs.
- `figures/` — figures referenced by the docs.
