# ML inputs — pure-Julia serve wiring (PR #252 → daily forecast)

Wires the input-upgrade LightGBM stack (PR #252, `bin/input_models/*.txt`) into
the Julia-only daily forecast: a self-contained GBDT scorer + a serve-time
feature port (`bin/ml_inputs.jl`), overlaid onto the weather track for the 5
pilot zones. Validated bit-for-bit against the python `predict_inputs.py`
pipeline, then price-tested on the combined stack (ML inputs + the merged #255
net-demand-aware weather-track hook).

## What shipped

| piece | file |
|-------|------|
| LightGBM text-dump parser + GBDT evaluator | `bin/ml_inputs.jl` (`parse_lgb_model`, `lgb_predict`, `lgb_node_decision`) |
| serve-time feature port (features.py replica) | `bin/ml_inputs.jl` (`ml_res_features`, `ml_load_features`, `ml_capacity_p95`, `ml_ar_load_lags`, `ml_res_agg`, `ml_load_agg`, `ml_holidays`) |
| 4-var GFS previous_day1 fetch (reuses weather_res machinery) | `bin/ml_inputs.jl` (`fetch_ml_res_weather`) |
| top-level overlay | `bin/ml_inputs.jl` (`build_ml_inputs`) |
| weather-track wiring | `bin/daily_forecast.jl` (`EUPHEMIA_ML_INPUTS`, overlay after `build_weather_predictions`) |
| DB-free unit tests | `test/test_ml_inputs.jl` (in `runtests.jl`) |
| equivalence harness vs python | `test/scripts/ml_inputs_equivalence.jl` |
| python reference dumper / panel driver | `docs/experiments/input-upgrade/dump_eval.py`, `panel_cell.jl`, `run_panel.sh`, `panel_report.py` |

## Per-zone-winner ship config (`ML_USE_NEW`)

`build_ml_inputs` overlays the pilot zones' RES + load; each (zone, target) takes
whichever of {NEW ML, committed pack} won the #252 OOS scorecard:

| zone | load | solar | wind |
|------|:----:|:-----:|:----:|
| GR | NEW | NEW | pack |
| ES | NEW | pack | pack |
| DE_LU | NEW | NEW | pack |
| SE2 | NEW | NEW | pack |
| NL | NEW | NEW | **NEW** (offshore) |

NEW load on all 5; NEW solar on all but ES (its pack ridge is already
near-perfect); NEW wind only on offshore-heavy NL (the physical power curve wins
the onshore zones). The 34 non-pilot zones and the entsoe track are untouched.

Behind `EUPHEMIA_ML_INPUTS` (default **on** for the weather track;
`=false`/`0`/`off` is the kill-switch, read at the wiring point, not memoized).
Inert unless `INPUT_MODE=weather`. The D-1 vintage discipline (`vintage_groups` +
`vintage_asof`), cap95 (trailing-30d p95 ending D-2, from the store) and the
AR-lag load features (D-1/D-7 DA forecasts) are all ex-ante; the
`prediction_made`/vintage purity guards downstream are unchanged (the overlay
only replaces which zone→hour→MW dict a pilot draws from).

## Train/serve consistency — the port replicates features.py's imperfections

**Critical rule (owner):** the feature port replicates `features.py` EXACTLY AS
TRAINED, including its known imperfections. The models learned on those features,
so a serve-time "fix" would introduce train/serve skew. Fixes happen at the next
retrain, never in the port. Carried-over imperfections, documented in
`bin/ml_inputs.jl`:

- **GR (Orthodox) holidays use the WESTERN Gregorian Easter** as an
  approximation (`ml_holidays`, NOT the correct Orthodox computus that
  `weather_load.jl` uses).
- **Only GR/ES/DE/SE carry a fixed-holiday map**; every other country (incl. NL)
  gets an empty holiday set → `is_hol` ≡ 0 there.
- **Degree-hour bases are the hard-coded 21.0 / 16.5 °C** from features.py, not
  the per-zone pack bases.
- **`is_hol` keys on the UTC calendar date** of the hour (features.py normalizes
  the UTC timestamp), not local date.

These are asserted in `test/test_ml_inputs.jl` so a refactor can't silently
"correct" them out of train/serve agreement.

## Validation A — equivalence vs python (identical inputs)

`test/scripts/ml_inputs_equivalence.jl`, 5 pilot zones × 4 recent days
(2026-07-24..27) × {load, solar, wind} = 480 zone-hours per target. Reference =
`predict_inputs.py`/`dump_eval.py` on the committed models. Two levels:

**(1) Scorer — identical (python-dumped) feature vectors → Julia GBDT evaluator:**

| target | n | max &#124;Δ&#124; | max relΔ |
|--------|--:|-----------------:|---------:|
| load | 480 | **0** | **0** |
| solar | 480 | **0** | **0** |
| wind | 480 | **0** | **0** |

The parser + tree routing (NaN→default_left, zero-splits, `<=` decisions) +
ratio/night-clamp post-processing are **bit-identical** to python LightGBM.

**(2) Feature port + full predict — rebuilt in Julia from the SAME GFS
previous_day1 parquets + the SAME DuckDB extract used to train:**

| quantity | n | max &#124;Δ&#124; | max relΔ |
|----------|--:|-----------------:|---------:|
| all features (18,240 scalars) | 18240 | 5.7e-13 | **7.1e-15** |
| NEW load MW | 480 | **0** | **0** |
| NEW solar MW | 480 | 6.99 MW | 3.0e-3 |
| NEW wind MW | 480 | 40.3 MW | 6.8e-2 |
| baseline pack solar (weather_res reuse) | 480 | 1.5e-11 | 5.5e-15 |
| baseline pack wind (weather_res reuse) | 480 | 1.8e-11 | 5.0e-15 |

Every **feature** matches to ~1e-13 (float summation-order noise in the
cell-mean / percentile aggregation). Load predictions are bit-identical. The
solar/wind residual is **2 of 960 RES hours** (GR 07-27 05:00 solar, SE2 07-27
07:00 wind) where a feature sits within ~1e-13 of a tree split threshold and the
**discrete split flips** — one tree's leaf changes, and in a ratio model
(leaf ≈ ±0.01 × cap95 ≈ 30–40 MW) that shows as a ~30–40 MW jump. This is the
**documented last-ULP mechanism** (the Postgres↔DuckDB parity residual: `SUM`/
`percentile` reordering reaching a marginal tranche), **not a port bug** — proven
by (1) the scorer being bit-identical on identical features and (2) the features
themselves matching to 7e-15. The other 478/480 solar and 479/480 wind hours are
bit-identical. `EQUIVALENCE PASS`.

## Validation B — the price panel (combined stack)

GR + NL, UTC days 2026-07-24..27, 39-zone EU footprint cleared on current `main`
(HiGHS, `enrich_network`, 2-pass, **incl. the #255 net-demand-aware weather-track
hook**), `save_to_db=false`, read-only extract, a **fresh Julia process per cell**
(`run_panel.sh`). The 5 pilots are overlaid; neighbours keep reference ENTSO-E
inputs, so the two arms isolate the pilots' input change:
**old** = committed linear packs, **ml** = the per-zone-winner LightGBM overlay.

### Midday price (€/MWh, UTC 09–15) — settled vs arms (headline GR + NL)

| day | zone | settled | old (pack) | ML |
|-----|------|--------:|-----------:|----:|
| 07-24 | GR | 94.8 | 94.1 | **52.8** |
| 07-24 | NL | 53.7 | 136.6 | 103.6 |
| 07-25 | GR | 7.0 | 30.8 | **20.1** |
| 07-25 | NL | -3.1 | 123.0 | 102.7 |
| 07-26 | GR | 14.4 | 18.6 | 17.0 |
| 07-26 | NL | 6.3 | 111.7 | 103.8 |
| 07-27 | GR | 38.1 | 54.4 | **37.3** |
| 07-27 | NL | 2.4 | 139.3 | 105.2 |

### Collapse classification vs settled (SCIENTIST.md §4, all 480 pilot zone-hours)

| threshold | settled pos | arm | hit | miss | FA |
|-----------|:-----------:|:---:|:---:|:----:|:--:|
| ≤ €5 | 107/480 | old | 59 | 48 | 21 |
| ≤ €5 | 107/480 | **ml** | 51 | 56 | 23 |
| < €0 | 59/480 | old | 0 | 59 | 0 |
| < €0 | 59/480 | **ml** | 0 | 59 | 0 |

### Per-zone all-hour MAE vs settled + collapse(≤€5) hit/FA

| zone | old MAE | ml MAE | old hit/FA | ml hit/FA |
|------|--------:|-------:|:----------:|:---------:|
| **GR** | 29.6 | 34.6 | 8/16, FA 0 | **13/16, FA 5** |
| ES | 19.0 | 16.7 | 20/31, 0 | 8/31, 0 |
| DE_LU | 29.1 | 27.2 | 7/13, 2 | 6/13, 0 |
| SE2 | 24.3 | 24.8 | 24/28, 19 | 24/28, 18 |
| **NL** | 58.6 | 49.4 | 0/19, 0 | 0/19, 0 |

### Reading — the owner's two questions

**Does the combined stack collapse GR July middays? YES, and it restores the
collapse SIGNAL.** GR collapse-hour detection goes **8/16 → 13/16** (the pack's
clear-sky solar under-prediction hid the collapses; the ML capacity-normalized
solar makes the weather track *see* them again — matching #252's reference
13/16). ML pulls GR midday toward settled on 3 of 4 days (07-25 30.8→20.1,
07-27 54.4→37.3, 07-26 ~flat). The cost is the documented one: on the single
genuinely-expensive day (07-24, settled €94.8) richer solar **over-collapses GR
to €52.8** — a false alarm (+5 GR FA), which lifts GR all-hour MAE 29.6→34.6.
This is exactly #252's *"do not ship blind — gate activation on the collapse
false-alarm rate, not MAE alone"* verdict, now reproduced on the combined stack.

**Does it move NL off its flat €104? PARTIALLY.** ML moves NL midday **down
~20–35 €/MWh** off the stuck-high pack level (136.6→103.6, 139.3→105.2) and cuts
NL all-hour MAE **58.6 → 49.4**, but NL stays flat ~€103–105 and never reaches
settled's negative regime (collapse ≤€5 still 0/19, negatives 0/59 in BOTH arms).
NL's residual is **structural**, exactly as #252 found: with neighbours at
reference inputs and RES entering as merit supply, NL cannot reach its negative
settled regime from a single-zone input swap — that needs a footprint-wide input
upgrade plus a below-cost/negative RES injection, out of scope for an input model.
Negatives are zero in every arm for the same structural reason (RES floors the
cleared price).

**Net:** the ML overlay is a clear INPUT-accuracy win (ES/DE_LU/NL MAE all
improve, GR/NL collapse signal restored) and behaves precisely as #252's OOS
scorecard predicted at price level. It is wired **default-on** but the GR
expensive-day false-alarm is real — a scored multi-day activation gate on the
collapse false-alarm rate is the prerequisite for trusting it unattended, and the
`EUPHEMIA_ML_INPUTS` kill-switch makes the A/B a one-flag flip.

## Reproduce

```bash
# equivalence (offline, read-only extract + PR #252 GFS parquets in scratchpad)
cd docs/experiments/input-upgrade && ../../../<venv>/bin/python dump_eval.py 2026-07-24 2026-07-27
EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true \
  EUPHEMIA_DUCKDB_PATH=<repo>/data/extracts/euphemia-live.duckdb \
  julia --project=. test/scripts/ml_inputs_equivalence.jl

# price panel (fresh process per cell)
bash docs/experiments/input-upgrade/run_panel.sh
<venv>/bin/python docs/experiments/input-upgrade/panel_report.py
```
