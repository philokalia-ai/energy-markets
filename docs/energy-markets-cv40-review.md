# cv40 review and refined implementation plan

13 September 2026 · Energy markets · Noon collapses, external countries and data/model quality

**cv40 is a useful repair candidate, but I would revise it before shipping.** The Germany hub-name correction and moving transmission-outage caps after capacity assembly are sensible. The zero-limit change needs a net-flow formulation; release identity and model-artifact binding remain unsafe; and the evaluation documentation overstates the evidence. Prioritise these small release repairs, then #387 and a bounded Sicily attribution experiment. Do not make a full flow-based implementation a prerequisite for every useful improvement.

Reviewed [PR #386](https://github.com/philokalia-ai/energy-markets/pull/386), head `476308667e6f06d9bae5eaffb16d39ec08146e60`, and [issue #387](https://github.com/philokalia-ai/energy-markets/issues/387), through WSL/SSH. The main server checkout remains at `0747bf3`; the candidate is in the `feat/cv40-review-fixes` worktree. Both PR and issue were open at inspection. The candidate still declares `ENERGY_PRICES_CODE_VERSION = 39`. Read-only database checks found the two experimental arms, but no rows with code version 40.

Evidence below distinguishes source findings, independently executed diagnostic probes, and results reported by the PR. No production code was changed, no model re-clear was run, and I did not independently rerun the reported 1,958-test suite. The visible PR check was the successful Workers deployment; that is not a model-validation check.

## 1. What the experiment actually establishes

The committed `output/ab_score.txt` reports:

| Measure | Base | Fixes | Interpretation |
|---|---:|---:|---|
| MAE, €/MWh | 27.23 | 27.22 | Essentially flat |
| Load-weighted MAE, €/MWh | 26.44 | 26.39 | Small reported improvement |
| Bias, €/MWh | −9.94 | −9.93 | Material underprediction remains |
| Pooled correlation | 0.758 | 0.758 | Unchanged |
| Recall at settlement ≤ €5/MWh | 17.5% | 17.5% | Collapse detection unchanged |
| False alarms at that threshold | **161** | **161** | README incorrectly says zero |
| Predictions ≥ €500/MWh | 0 | 0 | This sample does not cover the Sicily event |

These are 52 Wednesdays, 3 September 2025–26 August 2026. The scorer measures collapse over **all hours**, not a local-noon subset. It reports 2,268 low-price events and 48,570 matched cells. A zero-spike count here says nothing about the Tuesday, 24 February Sicily cluster.

Independent database checks confirmed **48,648 saved cells per arm**, against 48,672 expected from 52 × 24 × 39. SI is absent on 12 November 2025 in both arms. Another **78 saved cells disappear before the reported score**. A broad EUR day-ahead existence check found a price in every saved cell's hour, so those 78 exclusions need a sequence/window/join audit rather than being casually labelled missing settlement. Emit an exclusion ledger with exact zone, hour and reason.

The comparison enables the Germany-hub and zero-limit changes together. The load and outage-pass changes operate in both arms; their incremental effects are unmeasured. There is no separate attribution of Germany versus zero limits. Reported changes include DE_LU −€0.27/MWh MAE, HU −€0.43, AT +€0.31 and CH +€0.16. This redistribution is compatible with tighter exchange capacity, but does not establish that the represented feasible set is physically correct.

**Evaluation next step:** use a frozen input snapshot, immutable arm IDs and a small stratified panel covering all weekdays, seasons, high-RES weekends, scarce evenings and the known Sicily cluster. Compare the actual baseline with all repairs, then isolate the network changes. Report matched and unmatched coverage, zone results, day-level uncertainty, signed-tail metrics and input provenance. The current one-cent pooled difference should not be presented as a demonstrated accuracy gain.

## 2. Findings to resolve before release

### P1 — Zero net export is not zero gross export

`src/Network.jl:883–930` scales outgoing capacities against maximum net position and incoming capacities against minus minimum net position. cv40 extends this approximation to zero by deleting capacity in that direction. It also continues to ignore signed limits outside those two nonnegative cases.

A hub importing 100 MW and exporting 100 MW has net position zero. A maximum net position of zero permits this transit; setting all outgoing capacity to zero forbids it. Even positive limits are unnecessarily restrictive under separate gross caps. Sequential proportional scaling additionally makes the allocation depend on which other hub's reduction happened first.

**Required change:** represent `minNP ≤ exports − imports ≤ maxNP` as an explicit constraint on the appropriate commercial positions. Define the CCR boundary, external schedules and virtual-hub terms before wiring it into the solver. Net-position bounds remain only a relaxation of the full PTDF/RAM domain, but they should at least constrain the right quantity. If that cannot fit this release, separate or defer the new zero-cap behaviour and label the existing capacity scaling as an approximation.

Acceptance cases: balanced transit under a zero bound remains feasible; positive net export is rejected under that bound; signed import/export requirements work; reversing input iteration order gives the same feasible set; constraints cover the intended flow terms regardless of capacity source. A better aggregate score cannot substitute for these invariants.

### P1 — The candidate is still version 39

`src/db/postgres_core.jl:209` declares version 39, and the daily forecast consumes that constant (`bin/daily_forecast.jl:155`). Experimental clearing-mode labels distinguish the present A/B records. They do not protect ordinary record or forecast runs if changed code is deployed under the same version.

**Required change:** assign the release its own version before deployment and bind run metadata to commit SHA, input snapshot, switches, solver configuration and target version. Leave the existing record untouched. Deferring a historical backfill is reasonable; emitting changed forecasts under an unchanged model identity is not.

### P1 — Emitter binding checks can certify the wrong training data

`bin/emit_model_lines.py:94–121` still reads `probe2y37_dataset.parquet` for fresh training, then writes `book_cv = CV`. With `MODEL_LINES_CV=40` and no cached model, it can train from the old dataset and label the artifact cv40. That fresh-training path also bypasses `_check_binding`.

The binding remains incomplete elsewhere: `features_for` can fall back to an unversioned `data/model_line_feats` CSV; the weather forecast base query selects the freshest row without a code-version restriction. Validating a book directory alone does not bind the residual model, feature cache and physical forecast to one compatible pipeline.

**Required change:** take the training dataset and its provenance from a manifest, derive the trained-on version from that manifest, validate before training and before writing, version fallback features, and constrain the physics-base selection. Include target identity and issuance in the manifest. Test a deliberately mismatched fresh-training request and a stale fallback CSV. Both must fail without publishing an artifact.

### P2 — The settlement helper is useful, but not yet a canonical target contract

`docs/experiments/cv40-review-fixes/scripts/settlement_view.py:39–61` selects the sequence with the most covered dates, breaking ties by the median **absolute update timestamp**. This is not a measure of time since the auction gate. Coverage does not identify the auction, and selection can change when the evaluation window or ingestion history changes. “Days covered” also does not establish complete intraday coverage.

The deduplication sorts update time ascending and keeps the first row. An isolated execution of the actual helper with two revisions, 100 then 200, retained **100**. Its finest-resolution selection is only per timestamp, not over interval coverage: a synthetic hourly value of 100 at 00:00 and quarter-hour zeroes at 00:15/30/45 becomes **25**, although the retained observations overlap and do not form four equally weighted quarters. Neither behaviour is a safe general canonicalisation rule.

These are reproduced algorithmic edge cases, not a claim that they altered the reported A/B. A read-only screen found no mixed-resolution hours in the selected series on the sampled Wednesdays.

**Required change:** commit an explicit, reviewed zone/auction mapping with effective dates; deterministic revision policy; interval-overlap resolution; completeness and duration weights; and fail-closed handling for unknown series. Persist the selected mapping and rejected rows with every score. Promote the helper into the common evaluator and training-target path, rather than leaving it only in an experiment directory.

### P2 — Tests do not cover the four fixes as claimed

`test/test_cv40_fixes.jl` contains a copied hub-classification helper, arithmetic examples and a database check for returned hubs. It does **not** exercise zero-limit enforcement or outage-cap pass ordering. The averaging example does not call `get_loads`, so it cannot catch an integration regression there.

Keep the Germany correction and duration-weighted arithmetic, but test the production transformations with injected data. Include explicit and pre-gate capacities under an outage, missing versus true-zero limits, overlapping load resolutions, partial coverage and a forecast context carrying publication timestamps. The load conversion still uses hour-level coverage and accepts partial means without an explicit completeness contract. Do not interpret the arithmetic repair as resolution of every load-quality issue.

## 3. Refine #387 into an effective-RES contract

**The issue is valid, but narrower than the underlying inconsistency.** `book_build.jl:897–905` inserts combined `WeatherFill` rows; `:1140` only reads rows tagged `Solar` for the gate. In addition, `daily_forecast.jl:530–553` replaces total RES through `renewable_modifier` even where all TSO rows exist. The gate still reads the original TSO solar rows. Consequently, a fully populated weather-track hour can also gate on a different solar forecast from the one supplying the book. Input corrections and scenario modifiers have the same architectural risk because they change the aggregate effective series downstream of the original rows.

**The implementation can be smaller than the issue implies.** `bin/weather_res.jl:344–377` already holds separate wind and solar models and calls separate prediction functions; it discards the split when adding their outputs. Expose the components first. Retraining is not necessary merely to recover a split already computed internally. Keep a combined-output adapter for existing consumers while migrating them.

Use one effective component series per zone and interval after source selection, gap filling, correction and scenario adjustment. Derive total RES, residual demand, supply quantities and solar share from that same series. Carry source, issuance, units, coverage and missingness with the components.

For the TSO track, merge by **production type and interval**, not “any RES row in this hour”. A present wind row currently prevents filling absent solar. Preserve an actual published zero, but distinguish it from a missing value coalesced to zero. For the weather track, replace both components consistently. Specify how legacy aggregate modifiers behave; silently guessing a solar/wind allocation would recreate the ambiguity.

Acceptance should cover:

- Solar-only perturbation changes supply and solar-share signal; crossing the threshold activates the gate in an enabled zone.
- Wind-only perturbation changes supply and residual demand, but not the solar-share signal at fixed load. Clearing prices may still change.
- Missing solar with present wind is filled without overwriting wind; published solar zero is retained.
- Full TSO coverage on the weather track does not leave the regime tied to TSO solar.
- Component totals reconcile on 15-, 30- and 60-minute grids; missing weather is not manufactured as zero.
- The same issuance and source choices reproduce the same effective series and gate.

The default gate is limited to DE_LU, FR, PL, BE, CZ and CH. Quantify affected production hours within this scope before claiming an accuracy benefit. This fix removes a forecast inconsistency; it does not by itself explain or solve the recorded model's broader collapse-recall problem.

## 4. Next modelling experiments

### Noon collapse: identify what prevents clearing below zero

After #387, run a collapse-specific panel using each zone's local market time and a solar-position or daylight definition, with UTC retained in storage. Keep hourly and native settlement-interval results separate. Measure recall and precision at €5, €0 and −€50, onset and duration errors, false-collapse cost, and episode-weighted errors.

For each missed episode, save effective solar/wind/load, gate state, available and accepted RES, thermal minimum output, storage charging and state of charge, imports/exports, active constraints and marginal price-setting orders. Separate three cases: the gate did not activate; it activated but surplus supply was absorbed; or a different offer/constraint held price above the expected level.

Only then compare isolated mechanisms: negative RES/support-scheme bids, thermal commitment and CHP minima, storage energy balance, and export absorption. Treat renewable availability separately from curtailed realised output. A spill-based signal is worth testing after flow constraints are credible, but do not combine a new trigger, new floor and new thermal calibration in one arm. Require gains on unseen episodes without compensating deterioration on ordinary hours or scarce evenings.

### Sicily: a three-day attribution run before broader backfill

Re-clear **23–25 February 2026**, including 17:00–20:00 UTC on the 24th. The Wednesday panel misses the focal cluster. Use frozen pre-gate unit availability, interval-level remaining MW, effective load/RES, Calabria–Sicily capacity provenance, accepted orders, backstop use and the binding constraints behind the price.

Run the same snapshot under baseline and candidate code, then isolate generation availability, border constraints and commitment/backstop treatment. Use diagnostic relaxations to measure contribution, not as proposed production settings. Explain the scarcity quantity and marginal offer responsible for each spike, not merely whether the price falls.

Existing contextual news supports investigating system stress, but does not substitute for the actual interval constraints. Do not encode an outage from a future-closure headline. Accept a repair when it removes unsupported scarcity while preserving comparable genuinely tight evenings. This bounded experiment should precede a 16-hour historical run.

### UK / Türkiye / Ukraine: shared balances before richer price ladders

cv40 makes no direct changes to these boundary models. The central task remains preventing independent country-facing ladders from creating inconsistent external supply, demand or cable usage. `src/merit_order/boundary.jl:317` creates import and export orders separately; their relationship needs explicit physical accounting.

Start with **GB as a shared external balance across connected EU zones**, with individual cable limits/losses/outages and coherent total GB residual supply and demand. Distinguish cable schedules, aggregate country flows and commercial net positions to prevent duplicate injection. Enforce a valid signed cable flow and prove external energy conservation. Add time-aligned fuel, carbon and currency inputs within the issuance contract.

Then add **Türkiye across GR/BG jointly**: one external balance, explicit interconnector constraints, appropriate EPİAŞ/load/generation inputs, currency and local cost assumptions. Do not copy an EU gas/carbon anchor without validating it against the Turkish system. Use elastic trade as a testable model, with historical flows as benchmarks rather than simultaneous fixed injections.

For **Ukraine**, model aggregate feasible interchange across its connected borders, dated transfer restrictions and available supply/import need. A firm-demand tranche should have an observable, dated basis and an uncertainty range; historical persistent imports cannot guarantee the same future requirement. Evaluate prices and cross-border schedules together, including stress scenarios with reduced availability.

For all three, compare to simple forecast-vintage flow baselines. Reject an apparent EU price improvement if it depends on impossible external balances or unsupported simultaneous buy/sell volumes. Country-by-country rollout makes attribution easier.

## 5. Recommended delivery order

| Priority | Deliverable | Acceptance gate |
|---|---|---|
| 1 | Amend cv40 release candidate | Correct model identity and emitter manifest; resolve zero-net-position semantics; production-path regression tests; correct README false alarms |
| 2 | Reliable evaluation target and panel | Stable auction mapping, interval/revision policy, explicit exclusions, frozen inputs and isolated repair effects |
| 3 | Effective solar/wind contract for #387 | Component-level fill/override/corrections; gate and supply agree on both weather and TSO tracks |
| 4 | Sicily attribution and local-noon diagnostics | Known cluster included; price-setting mechanisms and scarce/surplus quantities explained |
| 5 | Net-position solver constraints, then full flow-based pilot | Feasible transit and signed bounds; commercial-position validation; explicit PTDF/RAM coordinate conventions |
| 6 | GB shared external balance, followed by TR and UA | Energy/cable constraints pass and out-of-sample price/flow results improve |
| 7 | Consolidated record backfill | Candidate SHA, target, inputs and acceptance results frozen; complete coverage and release-labelled outputs |

The full flow-based pilot can proceed separately from #387 and the Sicily trace. Preserve separate experiment identities even if several accepted corrections eventually share one record backfill. Append forecast input vintages now: without them, future forecast-quality claims will remain difficult to distinguish from revised-data hindsight.

## Evidence and reproducibility

Primary reviewed sources are pinned to [the cv40 candidate commit](https://github.com/philokalia-ai/energy-markets/tree/476308667e6f06d9bae5eaffb16d39ec08146e60): `src/Network.jl`, `src/Loads.jl`, `src/db/postgres_core.jl`, `src/merit_order/book_build.jl`, `src/merit_order/boundary.jl`, `bin/weather_res.jl`, `bin/daily_forecast.jl`, `bin/emit_model_lines.py`, `test/test_cv40_fixes.jl`, and the scripts/results under `docs/experiments/cv40-review-fixes/`.

Read-only review diagnostics checked saved arm coverage and missing zone-days, tested raw settlement existence and mixed-resolution exposure on sampled Wednesdays, and executed the candidate settlement helper on synthetic overlap/revision cases. The score table above is transcribed from the committed experiment output, not presented as an independent re-clear or full rescore. The 78-cell scoring exclusion remains unresolved and is explicitly part of the next evaluation work.
