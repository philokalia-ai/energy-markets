# DRAFT: `tsfm` + collapse-probability overlay (owner decision, not wired into cron)

This is the smallest production path for two overlay series next to `sim` / `gbm` / `stats`.
Evidence for both is in [README.md](README.md): Sep–Nov 2026, 39 zones, 54,231 cells.

| series | what it is | backtest (D-1 info set) |
|---|---|---|
| `tsfm` (median, q10, q90) | zero-shot TSFM lead-1 price | prices only, 06:30: MAE 29.0 (Chronos-2) / 28.0 (Timestral) vs live `sim` 81.5. With `sim` covariate, post-sim: 26.1 / 25.1 |
| `p_le0` | unfitted 50/50 blend of collapse's D-1 logistic and the TSFM's quantile P(≤ 0) | with Chronos-2 (default): Brier 0.0096, AUC 0.953; with Timestral: 0.0090 / 0.967. Logistic alone: 0.0098 / 0.952 (57,111 cells, 743 events) |
| `p_any_le0` (per zone-day) | 50/50 blend of collapse's day logistic and max-hour TSFM P(≤ 0) | max-hour TSFM P alone: Brier 0.045–0.049, AUC 0.85–0.89 on 2,378 zone-days. The independent-hours formula is 2× worse (mean p 0.25 vs a 0.067 base rate) |

It is a **prediction product**. It reads settled prices, so it never feeds the counterfactual,
the books or `code_version`. `sim` stays the conduct instrument.

## Code

- `bin/emit_tsfm_overlay.py`: the emitter. The information-set logic lives in pure functions:
  - `build_context`: settled prices strictly before the start of Athens day D.
  - `sim_known`: post-sim issue time, plus only the `sim` rows made by then.
  - `market_day_hours`: the 23/24/25 hours of the Athens market day.
- `test/test_tsfm_overlay.py`: 7 tests, no extract or weights needed (stub model):
  - DST hours;
  - target-day prices invisible, and D-1 prices visible;
  - pre-gate mode never reads `sim` and issues at 06:30;
  - post-sim issue = latest made time of D's `sim`, with later re-runs excluded;
  - the after-gate flag;
  - quantile → P(≤ 0), and the blend fallback;
  - day-level = max hour, and the logistic join.
- Run: `python -m pytest test/test_tsfm_overlay.py test/test_collapse_probability.py` (18 pass).

## Modes, explicit in the output's `input_mode`

| `--mode` | inputs | `issue_utc` | note |
|---|---|---|---|
| `pregate0630` (default) | settled prices through D-1 | D-1 06:30 UTC | can run in the 06:30 job |
| `postsim` | + live lead-1 weather `sim` (history + D) as known-future covariate | latest `prediction_made_utc` of D's lead-1 `sim` (08:16–10:06 UTC in Sep–Nov) | `after_gate=True` if issue > D-1 10:00 UTC. Rows made after the issue time are excluded |

- **Model:** `TSFM_MODEL=chronos2` (default, Apache-2.0) | `timestral-209m` | `timestral-28m`.
- **Timestral licence:** the weights are "Modified MIT", which **withholds all rights from
  companies (or employers) with consolidated monthly revenue above $20M**
  ([licence](https://huggingface.co/mistralai/Timestral-209M/blob/main/LICENSE)). Check before
  selecting it. Chronos-2 is about 1 €/MWh behind.

## Dry run (offline extract; no DB access at all)

```bash
export EUPHEMIA_DUCKDB_PATH=/path/to/euphemia-live.duckdb HF_HUB_OFFLINE=1
python bin/emit_tsfm_overlay.py --delivery 2026-11-15 --mode pregate0630 --output data/tsfm_overlay
python bin/emit_tsfm_overlay.py --delivery 2026-11-15 --mode postsim --live-json <dir of api zone JSONs>
```

**Demo, 2026-11-15** (extract refreshed 2026-11-14; 39 zones; 936 hourly + 39 day rows per mode):

- `pregate0630`: issue 2026-11-14 06:30 UTC. Wall time 144 s, of which the TSFM is 34 s and
  collapse's per-zone logistic refit about 105 s. Peak RSS 3.4 GB.
- `postsim`: issue 2026-11-14 09:13:05 UTC, `after_gate=False`. Wall time 151 s; RSS 3.9 GB.
- Top day-level P(any hour ≤ 0), pre-gate: GR 0.68 (logistic 0.93 / TSFM 0.42), ES 0.13,
  PT 0.11, NO4 0.06, SE2 0.06.

Hardware: 16 aarch64 cores.

## Where it plugs in (proposal)

1. **Schedule:**
   - `pregate0630` as a step at the end of `daily-forecast.yml`. It adds about 2.5 min including
     the logistic, against the job's 120-min budget.
   - `postsim` as one line in `bin/emit_model_lines.sh` (cron 10:40 UTC, which already runs after
     the lead-1 `sim`). Python dependencies: `uv run --with chronos-forecasting,torch,scikit-learn,scipy,duckdb`.
   - Cache the weights (about 460 MB for Chronos-2) in the pod or a PVC, with `HF_HUB_OFFLINE=1`.
2. **Storage:**
   - Prices go into the existing **`simulations.model_lines`**:
     - `model = tsfm_<mode>` (median), `tsfm_<mode>_q10`, `tsfm_<mode>_q90`;
     - `code_version` = `LINES_VERSION` (1);
     - same upsert key as `hybrid_gbm` / `stats_gbm`.
   - Probabilities do not belong in a price column, so they get a sibling table,
     **`simulations.overlay_probabilities`**:
     - DDL in `OVERLAY_DDL` in the emitter; nothing creates it automatically;
     - one row per `(zone, market_date, hour | NULL for day, quantity, input_mode, model_version)`;
     - quantities `p_le0`, `p_le0_tsfm`, `p_le0_logit`, `p_any_le0`, …
3. **Not wired in this draft:** the Postgres readers (prices from `entsoe.energy_prices`,
   `sim` from `simulations.forecast_prices` lead-1 weather rows) and the collapse logistic on
   Postgres, which today reads a DuckDB connection.
   - `--write` exits with a message; `write_db()` shows the intended upserts.
   - Wiring them is about 40 lines once the owner decides.
4. **API / web (description only; `web/` and `workers/` untouched):**
   - `bin/export_forecast_json.jl` and `export_web_parquet.jl` would add, per zone-day:
     - `"tsfm"`, `"tsfm_q10"`, `"tsfm_q90"` hourly arrays next to `"sim"`, `"gbm"`, `"stats"`
       (from `model_lines`, as `model_lines_map` does today);
     - `"p_le0"` hourly and `"p_any_le0"` scalar (from `overlay_probabilities`);
     - `"tsfm_input_mode"`, so the page can say "06:30, prices only" or "after sim, ≈10:15".
   - The site would draw `tsfm` as a fourth dashed line with a q10–q90 band, and show `p_any_le0`
     as a "negative-price risk" badge per zone-day.
   - The API at `/api/v1/zones/<Z>` gets the same fields (additive, nullable).

## Not done / risks

- **Scoring:** the demo day isn't scored; 2026-11-15 settles after the extract.
- **Untested:** the Postgres write path.
- **Coverage gaps:**
  - Leads 2–7 are not evaluated.
  - The 50/50 blend is unfitted; a rolling-origin calibrated stack would be the next step.
- **Dependencies:** `timestral` is a git dependency (pin a commit if selected). Chronos-2 is on
  PyPI (`chronos-forecasting`).
- **The TSFM extrapolates statistically.** It lags regime breaks (worst backtest day 11-09: MAE
  about 55) and forecasts collapses mostly where recent history shows them.
