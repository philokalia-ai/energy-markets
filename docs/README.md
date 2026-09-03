# Documentation index

## Start here

- [code-map.md](code-map.md) — what lives where in `src/`, what calls what, and
  where to start per task.
- [model-spec-exante.md](model-spec-exante.md) — standalone spec of the ex-ante
  model: inputs, the strategy classes, per-zone parameters. (Its performance
  table is a frozen pre-cv19 sample — for current numbers use the ledger and
  the README.)
- [calibration-atlas.md](calibration-atlas.md) — how the EU-wide counterfactual
  is built: clearing workflow, per-region strategies, bid skeleton, mechanism
  inventory, calibration doctrine.
- [code-version-ledger.md](code-version-ledger.md) — the `simulations.*` schema
  and the full per-version history: what shipped, what was measured and
  rejected, and the kill-switch for each mechanism. **Check this before
  proposing a mechanism** — many have already been tried.

## Model & method

- [ex-ante-flows.md](ex-ante-flows.md) — the ex-ante flow rule for
  out-of-footprint borders (documents `:v2`; `:v3` superseded it in cv19, see
  `experiments/analogue-flows/`).
- [ex-ante-audit.md](ex-ante-audit.md) — the D-1-legality audit: every book
  input classified as ex-ante-legal or a leak.
- [period-decomposition.md](period-decomposition.md) — the canonical
  per-period-decomposed clear and its solver-invariance proof (cv20).
- [15min-clearing.md](15min-clearing.md) — opt-in native 15-minute clearing and
  the reduces-to-hourly bit-identity proof.
- [predictions.md](predictions.md) — the open, reproducible RES/load input
  model behind the site's "Predicting RES & loads" page.
- [scenario-api.md](scenario-api.md) — the counterfactual scenario API
  (`ZoneScenario`), with measured multi-zone worked examples.
- [reproducibility.md](reproducibility.md) — the public data artifact, checksum
  verification, `bin/reproduce.jl` tiers, and the honest caveats.
- [backfill-architecture.md](backfill-architecture.md) — the pipelined
  multi-zone backfill runner.

## The experiment record

[experiments/](experiments/) holds one directory or note per package —
mechanism, protocol, measured result, ship/no-ship. The load-bearing ones:

- [experiments/jao-maxbex-atc.md](experiments/jao-maxbex-atc.md) — flow-based
  capacity from JAO (cv35), the largest single version step.
- [experiments/cv36-graded-tranche/](experiments/cv36-graded-tranche/README.md)
  and [experiments/cv37-nordic-wet/](experiments/cv37-nordic-wet/README.md) —
  the current model version, with the ratified two-year ladder.
- [experiments/pregate-7lead.md](experiments/pregate-7lead.md) — the pre-gate
  forecast schedule.
- [experiments/conduct-probe-2026-08/](experiments/conduct-probe-2026-08/README.md)
  — where the residual is a tightness-priced premium rather than a model gap.
- [experiments/pubbooks-clearing/REPRODUCE.md](experiments/pubbooks-clearing/REPRODUCE.md)
  — the solver validated against real published GME/OMIE auctions.
- [complex-orders-investigation.md](complex-orders-investigation.md) — block
  orders, UC inside the clearing and endogenous must-run, tested three ways and
  rejected as always-on mechanisms.

## Research program

- [research-roadmap.md](research-roadmap.md) — competitive counterfactual →
  strategic-bidding detection.
- [phase-b-analysis.md](phase-b-analysis.md) /
  [phase-b-findings.md](phase-b-findings.md) — statistical and per-unit
  attribution of the residual (candidate hypotheses, not accusations).
- [pillars/](pillars/) — the six-pillars site/program plans.

## Data

- [data-dictionary.md](data-dictionary.md) — column-level documentation of the
  published artifact, with per-table provenance and the ENTSO-E column
  gotchas.
- [problem-zones-data-issues.md](problem-zones-data-issues.md),
  [infeasible-zones-analysis.md](infeasible-zones-analysis.md),
  [unknown-other-generators.md](unknown-other-generators.md),
  [weather-data-evaluation.md](weather-data-evaluation.md).

## History (kept as written, not maintained)

Superseded by the ledger, but preserved because the reasoning is the record:
the calibration iterations [iter1](eu-calibration-iter1.md) …
[iter8](eu-calibration-iter8.md) and
[eu-footprint-experiment.md](eu-footprint-experiment.md); the cv25–cv30
preregistrations (`cv2*-prereg.md`, [cv25-plan.md](cv25-plan.md),
[nordic-wetness-prereg.md](nordic-wetness-prereg.md)); the legacy
unit-commitment notes
([iterative-uc-mpcc-results.md](iterative-uc-mpcc-results.md),
[uc-interconnection-approaches.md](uc-interconnection-approaches.md)) — that
path was deleted in cv25.

Per-zone metric CSVs backing the iteration docs live in `exante-results/`,
`iter6-results/`, `iter7-results/`, `iter8-results/`; figures in `figures/`.
