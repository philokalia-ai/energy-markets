# SDAC hourly target: flag and shadow diff (#431, PR C)

**Status (2026-11-17, PR C2):** the flag has been flipped. `EUPHEMIA_DA_TARGET` now defaults to `sdac` for evaluation targets, and model inputs are pinned by `EUPHEMIA_DA_INPUT` (default `highest_seq`). The history is rescored by `rescore-hourly.yml`; see "C2: the flip" at the end. The sections up to "Reproduce" describe PR C as it shipped, with the flag off.

## What this adds

`EUPHEMIA_DA_TARGET=highest_seq|sdac` selects which auction an hourly "actual" is. Unset or empty means `highest_seq`; any other value is an error.

- **highest_seq** (default, unchanged): `resolution_aware_actuals`.
  - It takes the highest numeric `sequence` per (zone, interval), then the latest update, then a plain mean over the hour.
  - In AT and DE_LU that is sequence 2, the early **EXAA** auction (around 10:10 UTC on D-1), not SDAC.
- **sdac**: the SDAC auction only, using the rule of `cv40-review-fixes/scripts/settlement_view.py`:
  1. An explicit map picks the auction: AT and DE_LU use sequence 1; DK1 and DK2 use the blank main series. Zones not in the map must publish a single sequence. A zone with several sequences and no map entry **fails closed**: it is excluded and listed.
  2. Revisions are deduplicated: the latest update per (zone, resolution, interval) wins, with ties going to the higher price.
  3. Intervals must start on their resolution's grid, otherwise they are excluded as "misaligned interval".
  4. Each hour uses one resolution: the finest one with every aligned slot present. Hours that no resolution fully covers are dropped.
  5. The hour value is the duration-weighted mean.
  6. **There is no EXAA fallback.** An hour without SDAC is absent.

Implementations:

| Where | What |
|---|---|
| Julia: `test/scripts/eu_eval_metrics.jl` | `da_target_policy`, `da_target_actuals` (the switch), `sdac_hourly_actuals`, the pure `canonical_hourly_actuals`, `SDAC_SEQUENCE` (checked at load against `Q15_NON_SDAC_SEQUENCE`) |
| Python: `bin/da_target.py` | `policy`, `raw_rows`, `highest_seq_hourly`, `sdac_hourly`, `hourly_actuals` (an explicit `target=` is validated against `POLICIES`; an unknown value raises) |
| Shared fixtures: `test/fixtures/da_target_cases.json` | Read by `test/test_da_target.jl` (pure code, plus both SQL paths on a temporary DuckDB) and `test/test_da_target.py` (helper and reader SQL on an in-memory DuckDB). Cases: AT/DE_LU sequences 1 and 2, no EXAA fallback, DK copies with NULL sequence, duplicate revisions and an update-stamp tie, an incomplete quarter-hour, mixed PT60M/PT15M and PT30M/PT15M, misaligned PT30M, an ambiguous auction. |

Routed through the switch:

| Reader | Change |
|---|---|
| `bin/score_forecasts.jl` | hourly scores |
| `bin/export_forecast_json.jl` | actual charts (`export_zone_files`, `export_map_json`); one-line change each. The scoreboard (`export_scoreboard`, owned by level) is untouched: it reads `forecast_scores`, so it follows the scorer |
| `bin/export_web_parquet.jl` | same two call sites; added so parquet and JSON can't disagree after a flip |
| `test/scripts/eu_eval_metrics.jl` `metrics(:new)` | calibration evaluations |
| `bin/collapse_probability.py` | `hourly_actuals`; these are both its labels and its settled-price lags |
| `bin/emit_tsfm_overlay.py` | new `eval_actuals_duckdb`, for evaluation actuals only |
| `bin/naive_baselines.jl` `naive_zone_day_parts` (#437) | the scoreboard naives (D-1/D-7/weekday) read `da_target_actuals`, so naive and rMAE follow the target (review fix) |
| `docs/experiments/tsfm-2026-11/evaluate.py` `load` (and `prob_scores.load_backtest` through it) | labels and naives via `target_panel`: default = the frozen panel (unchanged); `sdac` = `EVAL_TARGET_PANEL` artifact or `EVAL_EXTRACT` through `bin/da_target.py`, otherwise an error. Forecasts and the model context are untouched. Integration test: `test/test_tsfm_evaluate_target.py` (review fix) |

**Not routed:**
- `PRICE_SQL` / `prices_duckdb`, Timestral's input context. That would be a model-input change. It is left as a `TODO(#431)` and has a test showing it is unchanged even with `sdac`.
- `bin/emit_model_lines.py`, which belongs to ops (PR D, which imports `bin/da_target.py`).
- The native 15-min path (`native_q15_actuals`), whose rule is unchanged.

## Shadow diff (offline, read-only extract `euphemia-live-20261115`)

`shadow_diff.py` computes both policies from the same raw rows. Outputs are in `output/`.

Coverage:
- **Live:** lead-1 physics, `weather*` track, from the saved live JSON. Athens market days 2026-09-14..11-13, 1,393 cells per zone, 54,303 in total, cv39/40/42.
- **Record:** the cv44 record clearing (`multi_zone_eu`, cv44, entsoe inputs, from `results/record-cv44.duckdb`). UTC days 2024-07-01..2026-06-30, 17,496 cells for AT and DE_LU, 681,648 in total.

| MAE, €/MWh | live legacy | live SDAC | Δ | record legacy | record SDAC | Δ |
|---|---|---|---|---|---|---|
| AT | 85.16 | 88.83 | **+3.68** | 18.00 | 20.43 | **+2.42** |
| DE_LU | 58.46 | 59.17 | **+0.71** | 19.09 | 20.20 | **+1.10** |
| footprint (pooled) | 81.62 | 81.73 | +0.11 | 24.73 | 24.82 | +0.09 |

The cell sets are identical under both targets in both windows, so every Δ is a pure target effect on the same cells.

| Mean abs EXAA − SDAC gap | live (UTC 09-13..11-13) | record |
|---|---|---|
| AT | 14.95 (max 214) | 10.09 (max 332) |
| DE_LU | 12.31 (max 275) | 8.60 (max 363) |

### Checks

- **Only AT and DE_LU change.**
  - Every other zone is identical to 0 in both windows.
  - DK1/DK2 differ only by float noise: max 1.2e-5 and 1.7e-5 €/MWh, mean 0.0000.
  - Why: DK's sequence-2 series is a copy of the blank SDAC series, apart from the last float digits. Legacy picks sequence 2 because it is numerically highest; SDAC picks the blank series.
  - DK's sequence-2 series exists only from 2026-01-20 (DK1) and 2026-01-22 (DK2), on part of the hours: 250 and 565 live hours, 388 and 1,060 record hours differ by more than 1e-6.
- **Coverage is unchanged** in both windows: same hours per zone, no legacy-only and no SDAC-only hours, and no incomplete, misaligned or resolution-dropped hours. The SDAC exclusion ledger contains only "other auction" (EXAA and DK copies) and "superseded revision".
  - At the leading edge the coverage does change: EXAA for D+1 is in the DB around 10:10 UTC, SDAC around 12:45 UTC. Example: in the 11-15 extract, DE_LU 11-15 23:00 UTC exists only as EXAA, so under SDAC it is absent (`output/identity.txt`).
  - After a flip, tomorrow's AT/DE_LU actual therefore appears about 2.5 h later.
- **The native quarters agree with the SDAC hourly actual.**
  - The mean of the 4 native PT15M quarters (`native_q15_actuals` rule) equals the SDAC hourly actual to ≤1e-9 in all 37 PT15M zones other than DK, AT and DE_LU included.
  - DK1/DK2 agree to ≤1.7e-5, because `native_q15_actuals` keeps whichever DK row has the later update stamp, sometimes the sequence-2 copy.
  - So with `sdac`, the hourly and 15-min scores target the same auction. Today they don't in AT/DE_LU.
- **Fable's numbers** (plan-431-fable §1.1: AT 85.3→88.9, DE_LU 58.5→59.2):
  - DE_LU is reproduced (58.46→59.17), as are both deltas (+3.68 vs +3.6, +0.71 vs +0.7), the cohort (54,303 cells, footprint 81.62 vs 81.6) and the live gaps (14.95 vs 15.0; 12.31 vs 12.2; the gap window here is UTC 09-13..11-13).
  - The AT level is 0.14 lower here: 85.16 against Fable's 85.3. The published JSON actual equals the recomputed legacy actual on every AT cell, so 85.16 is what the site's own data gives on that cohort.
  - Variants tried, none giving 85.3:
    - mean of daily MAEs: 85.13;
    - window shifted ±1 day: 85.17 / 85.84;
    - all lead-1 input modes: 85.80.
  - Fable's script isn't saved, so the small level difference is unexplained. The decision number, the AT delta, matches.
- **Flag-off identity** (`identity_check.jl`, `output/identity.txt`):
  - The actuals the scorer and exporters read are byte-identical to origin/main on 10 market days (18,680 rows, same sha256). The days cover DST, the 2025-10-01 move to 15-min, and the EXAA-ahead edge.
  - The Python readers' frames are identical to main.
  - Julia and Python agree on both policies (same rows, max |diff| 1.1e-13).
  - The scorer and exporter themselves can't run on the extract, which has no `simulations.forecast_*`. Identity is shown at their single changed input. With the flag unset, `da_target_actuals` *is* `resolution_aware_actuals`.

## Rescore workflow (PR C proposal; implemented in C2, below)

The flip must not be a code change alone. `score_forecasts.jl` rescores only the last `RESCORE_WINDOW_DAYS` (7), so the target would mix within one series:
- If the default flips without a full rescore, the last week becomes SDAC and all older days stay EXAA.
- If a full rescore runs under SDAC while the daily job still runs `highest_seq`, the next 06:30 run rewrites the last 7 days back to EXAA.

Proposal: a new `rescore-hourly.yml`, modelled on `rescore-q15.yml`, which is q15-only and is not the tool for this.

- `workflow_dispatch` only. Inputs: `start`, `end` (default: the full history), `cv`, `dry_run` (row counts only), `target` (default `sdac`).
- **Snapshot first:** dump the current `simulations.forecast_scores` hourly columns (`mae`, `bias`, `corr`, n) to a workflow artifact, plus a dated snapshot table if the leader prefers. This is the rollback.
- Run `score_forecasts.jl` with `RESCORE=true` and `EUPHEMIA_DA_TARGET=sdac` over the whole range, in bounded date batches, serially.
  - The q15 columns are untouched (their target is already SDAC).
  - Forecasts are never touched.
- **Its own concurrency group** (`rescore-hourly`). Also add a guard that skips if `daily-forecast` or the 10:40 server cron is running.
- **Run at about 13:30 UTC**: after SDAC for D+1 is published (around 12:45), and away from 06:30–08:00 and 10:40–12:00.
- **Same release:** in one sequence the same afternoon:
  1. merge the default flip (`sdac`, kill switch `EUPHEMIA_DA_TARGET=highest_seq`) and set it in the workflows and the server cron env;
  2. dispatch the rescore;
  3. run `publish-web-data`;
  4. run `deploy-web`.

  The exporters read actuals at export time, so the charts flip on that export.
- Rollback: set `EUPHEMIA_DA_TARGET=highest_seq`, restore the snapshot, re-export.
- Record it in `docs/code-version-ledger.md` as a dated **scoring-policy** entry. No code_version bump.
- Published numbers that move:
  - AT and DE_LU scores and the footprint averages: about +3.7 / +0.7 live, +2.4 / +1.1 on the record.
  - Any figure computed on the EXAA-blended target, such as the record tables and Timestral backtests, until rerun or footnoted.

## Reproduce

```
cp ~/armada/em-team/results/record-cv44.duckdb /tmp/record.duckdb      # don't open others' files
python docs/experiments/sdac-target-2026-11/shadow_diff.py --extract <extract> \
    --live-dir ~/armada/em-team/live --record-db /tmp/record.duckdb --out <outdir>
EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_PATH=<extract> EUPHEMIA_DUCKDB_READONLY=true \
    julia --project=. docs/experiments/sdac-target-2026-11/identity_check.jl <dir>   # on main and on the branch
python docs/experiments/sdac-target-2026-11/compare_python.py --extract <extract> --julia-dir <dir>
```

Python needs duckdb 2.0 (`bin/requirements-overlay.txt`). With duckdb 1.5, `zone` is a reserved word and the overlay's `PRICE_SQL` fails to parse.

## C2: the flip (owner decision 2026-11-16, effective 2026-11-17)

### Two settings

| Setting | Default | Covers |
|---|---|---|
| `EUPHEMIA_DA_TARGET` (evaluation) | `sdac`; `highest_seq` is the kill switch | `score_forecasts.jl` (hourly); `export_forecast_json.jl` and `export_web_parquet.jl` (actual charts); `naive_baselines.jl` (scoreboard naives and rMAE); `eu_eval_metrics.metrics(:new)`; collapse **evaluation labels** (`collapse_probability.main` relabels predictions through `retarget_labels`; `score_collapse_clearing.py` reads `role="target"`); `emit_tsfm_overlay.eval_actuals_duckdb`; `tsfm-2026-11/evaluate.py` (labels and naives; the target is read from `EVAL_TARGET_PANEL`, `EVAL_EXTRACT` or `EUPHEMIA_DUCKDB_PATH`, and it raises if none is set) |
| `EUPHEMIA_DA_INPUT` (model inputs, pinned) | `highest_seq` | Timestral price context (`emit_tsfm_overlay.prices_duckdb`, i.e. `PRICE_SQL`); GBM lag history (`emit_model_lines.target_policy` / `canonical_settled`; the function name and manifest key are kept); collapse logistic training labels and features (`collapse_probability.hourly_actuals(role="input")`, the default role, which `collapse_diagnostics.py` and `collapse_history_sensitivity.py` also use) |

Both settings accept only `highest_seq` or `sdac`; any other value raises. `daily-forecast.yml` and `publish-web-data.yml` pass the repo variable `vars.EUPHEMIA_DA_TARGET`: empty means the default, and `highest_seq` switches back without a code change. The 10:40 server cron re-exports the JSON with whatever its environment says, so the kill switch there is the same env var in the cron environment.

### rescore-hourly.yml
Dispatch-only, its own concurrency group, `contents: read` + `actions: read`, Julia 1.13.4.

1. **Guard** (`bin/rescore_guard.sh`). It refuses inside 06:15–08:30 or 10:30–12:15 UTC, or while daily-forecast or publish-web-data has a queued or active run; an API failure counts as active.
   - At start it needs 30 min of headroom before a blackout, to cover setup.
   - It is **rechecked before every write chunk and before a restore**, with 20 min of headroom. On refusal the run stops; resume with `start=`.
2. **Snapshot.** `bin/forecast_scores_snapshot.jl snapshot` dumps the hourly columns of all `forecast_scores` rows (key, hourly columns, exact `scored_at::text`) as the artifact `forecast-scores-hourly-snapshot-<run_id>`, kept 90 days.
3. **Dry run.** The scorer runs with `DRY_RUN=true` and prints the slices per mode and lead and the existing rows per zone that would be rewritten.
4. **Rescore.** The scorer runs with `RESCORE=true HOURLY_ONLY=true SCORE_LOCK_TIMEOUT=5s EUPHEMIA_DA_TARGET=sdac RESCORE_KEYS_OUT=campaign/keys.csv`, in `chunk_days` market-date chunks.
   - Each slice is one transaction under `SET LOCAL lock_timeout` and `statement_timeout`, retried 3 times.
   - After each slice's COMMIT, every key written and the exact `scored_at` it wrote are appended to the **campaign record**, uploaded even if the run fails as `rescore-hourly-campaign-<run_id>`.
   - The q15 columns are never written.
   - The default zones are `AT,DE_LU,DK1,DK2`, the only zones whose target changes. Rescoring the others would only fold in unrelated ENTSO-E revisions; pass `all` if wanted.
5. **Summary.** The policy, the range and the campaign key count go to the step summary, together with a snapshot-vs-now MAE table per zone.
6. **Rollback** (campaign-scoped). Dispatch `action=restore restore_run_id=<rescore run>`. It restores **only that run's campaign keys**, and only rows whose `scored_at` is still the campaign's: a row rescored since by a daily window or another run is skipped and counted.
   - Restored rows get their snapshot hourly columns and `scored_at` back, i.e. their exact pre-campaign state.
   - Keys the campaign created are reported, not deleted.
   - Also set the variable to `highest_seq`.
   - The test is `test/scripts/test_rescore_restore_pg.jl`, which runs on its own throwaway PostgreSQL cluster and goes through the real scorer and restore.

**No mixed target.** Merge after 12:15 UTC and dispatch the rescore the same afternoon, around 13:30, before the next 06:15. After the merge, every daily score (including its 7-day rescore window) uses SDAC, and the one full rescore covers everything older. `forecast_scores` has no policy column, so the policy goes in the scorer log (`TARGET_POLICY=…`), the workflow summary and the ledger (`docs/code-version-ledger.md`, "scoring policy sdac-v1").

### Verification
- **Kill switch:** `identity_check.jl` on 10 market days: with `EUPHEMIA_DA_TARGET=highest_seq`, the actuals are byte-identical to main's pre-flip default (18,680 rows, sha256 74a35cf4…). The new default is byte-identical to main's `sdac` output.
- **Python, kill switch** (separate processes against origin/main e758b93): collapse target labels, overlay eval actuals and `evaluate.load` (54,327 rows) are identical to main.
- **Python, default:** collapse input actuals and the Timestral context (320,064 rows) are identical to main. Evaluation labels change only in AT/DE_LU, plus DK by float noise.
- **Local dry run, DuckDB store mode,** on a scratch store built from the extract and the live JSON (5 zones, 2026-10-27..11-13):
  - the dry run reports 54 slices and 216 rows for AT/DE_LU/DK1/DK2;
  - snapshot and compare work;
  - restore refuses without `CONFIRM_RESTORE`.
  - The write path is Postgres-only, so it wasn't exercised here.
