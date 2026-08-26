# Pre-gate / 7-lead forecast + data reset — prereg-lite

**Status:** Phase 1 (code + prereg, this PR). Phase 2 (the retro backfill
execution + scored per-lead board) is a separate, sequenced run — see the
runbook at the end.

**Owner-approved package (α–δ).** Move the ex-ante forecast to a ~06:30 UTC run
producing every lead D+1..D+7, with lead-1 becoming a genuine **pre-gate**
forecast (before the 12:00 CET auction); ship the two enablers that let the
weather track freeze fully before the gate; lay the groundwork for a retroactive
**data reset** (weather-track reconstruction from 2026-07-01, all 39 zones, full
lead ladder 1..7); and validate the whole thing with a **per-lead skill
scoreboard**.

This doc FREEZES, before any scored run: the metrics that judge the 06:30 slice,
the retro labeling contract, and the Phase-2 runbook.

---

## 1. What changed (code, this PR)

### α — Multi-lead pre-gate run
The forecast driver already loops every candidate market day D+1..D+N; the 06:30
UTC cron (`.github/workflows/daily-forecast.yml`) runs it on the **weather**
track with `EUPHEMIA_FORECAST_PREGATE=true`. Lead-1 (tomorrow) freezes before the
auction. The vintage discipline is unchanged for the live forward run: a future
day's current GFS run (lag 0) is already horizon-natural — the run issued today
IS the run issued D−lead for delivery day D=today+lead, so `previous_day{lead}`
and the current run coincide. The **retro** path is where the lag equals the lead
(§2).

### β1 — Weather-track thermometer uses OUR model load
The `:v3` analogue flow selection (`src/merit_order/flows_imports.jl`) reads a
24-h load vector as its thermometer to pick thermally-similar analogue days.
Today it reads the **published ENTSO-E D-1 load forecast**. On the weather track
we (a) may not have that forecast yet at 06:30, and (b) claim not to read it. So
the weather track injects our own model/ML load vector via
`set_thermometer_load!(zone, day, vec24)`, weather-track-scoped and
default-inert. Kill-switch `EUPHEMIA_DISABLE_WEATHER_THERMOMETER`.
**Guard (measured, offline extract, GR 2026-04-03):** with the override empty
(entsoe track / record / backfill) the analogue selection is **byte-identical**
to the published-forecast path; injecting the same published vector reproduces it
exactly; a different vector changes the selection; the kill-switch reverts to
published. The record keeps the published thermometer by construction.

### β2 — Pre-gate ATC fallback (demonstrated capability)
At 06:30 tomorrow's **Day-ahead ATC has not published**, so many footprint
borders have *no offered row at all* for D (not the cv27 "present row with
n_da==0" case — wholly absent). The enriched network build (`src/Network.jl`)
now, when `Network.PREGATE_ATC_FALLBACK[]` is set, **adds** a demonstrated-
capability row (trailing-366d p95 gross flow per 4h block, `_fbmc_capability` —
the cv27 signal) for every footprint-internal border-hour absent from the offered
data. The cv27 machinery is thereby generalized from "re-size a present row" to
"supply a missing one". Kill-switch `EUPHEMIA_DISABLE_PREGATE_ATC`; default OFF ⇒
byte-identical.
**Guard (measured, offline extract, 8-zone SEE+IT 2026-04-03):** baseline
border-hours ⊆ pre-gate border-hours (the fallback only ADDS, +48 border-hours
where offered ATC was absent); every present border-hour's capacity is unchanged
(never clobbers a real row); the kill-switch is byte-identical to baseline.

### γ — Retro / data-reset backfill
`EUPHEMIA_FORECAST_RETRO_ASOF=<date>` (window end; `EUPHEMIA_FORECAST_RETRO_START`
default 2026-07-01) runs `run_retro()`: for each lead 1..N, reconstruct every
past market day in the window using the historical `previous_day{lead}` weather
vintage of the time (`openmeteo_retro_vintage_lag`). Rows are stamped
`is_retro=true`, `reset_tag` (default `2026-08-01-reset`), and the **additive**
provenance columns on `simulations.forecast_prices` (`retro_of_utc` = the natural
D−lead compute instant it stands in for). The writer **refuses to clobber any
genuine LIVE vintage** (§3).

### δ — Per-lead skill scoreboard
`bin/score_forecasts.jl` scores every slice per `(market_date, lead_days,
code_version, input_mode)` and now also computes, per zone-day, the **collapse
classification** (≤ €5 threshold): actual/predicted collapse counts, hits, false
alarms, hit-rate, false-alarm rate — additive columns on
`simulations.forecast_scores`, plus `is_retro`/`reset_tag`. The per-lead board is
the aggregate of these by `(input_mode, lead_days, zone)`.

### Phase-2 hook — zone→model resolved from meta at run time
`bin/ml_inputs.jl` resolves the pilot set (`ml_pilot_zones()`) and the per-target
winner (`ml_use_new(zone, target)`) from `bin/input_models/meta.json` at run
time, falling back to the committed 5-pilot consts. When the **39-zone ML
rollout** merges its winners config into meta (optional `pilot_zones` / `winners`
keys), Phase 2 automatically picks up whatever zones it shipped — no code edit.

---

## 2. The per-lead vintage convention (and its declared cost)

Models were trained on `previous_day1`. Serving day-`n` vintages of the **same
variables** at lead `n` is the declared convention: for a past delivery day D,
the honest lead-`n` information set is the GFS run issued D−n, recovered via the
previous-runs API's `_previous_day{n}` (per-timestamp). The per-lead scoreboard
**measures the skill decay** across the ladder — that IS the validation of the
convention. We expect MAE to rise and corr to fall monotonically with lead as
the weather vintage ages; the board quantifies by how much, per zone and per
regime.

**Coverage (verify at Phase-2 kickoff):** `gfs_seamless` previous-runs history is
dense from ~2024-07, so `previous_day1..7` are available for the whole
2026-07-01→ window. Days/vars with null previous-run hours make that zone-day
**ineligible loudly** (no silent zero-input clear), never kill the run.

**Documented Phase-1 residual (ML pilots only):** the ML input features `cap95`
(trailing-30d, ending D-2) and the AR load lags (D-1/D-7 DA forecasts) are still
read at their D-2/D-1 horizon regardless of lead, so at leads ≥2 they carry a
small lookahead for the 5 ML pilot zones' capacity-normalization and AR terms.
The **weather vintage** (the dominant per-lead signal) is honest at every lead,
and the 34 pack zones' load ridge (weather+calendar, no AR) is fully honest.
Tightening `cap95`/AR to the D−lead horizon is a Phase-2 refinement to take up
only if the per-lead board shows it matters.

---

### 2b. Declared convention (owner decision 2026-08-25, cv34)

**The lead ladder measures weather decay only.** Of the inputs a lead-*n*
row consumes, only the weather comes from the vintage of the time; the D-2
observed flows, the load-analogue pool, TTF/EUA, outages, the capability
windows and the ML load model's autoregressive features all read data
anchored to the delivery day (retro rows) or are absent/NaN (live rows at
leads ≥ 2). A retro lead-7 row therefore answers "how much does *weather*
degrade over 7 days with every other input at lead-1 quality", nothing more.
Consequences baked into the code from cv34: live and retro rows are never
pooled — `forecast_scores` is keyed by `is_retro` and the summary reports
`<mode>/retro` separately; the `entsoe` track's leads 2–7 are weekly
persistence copies and carry `input_mode='entsoe_persist'`. Making the
non-weather inputs vintage-aware is a separate project, not started.

### 2c. JAO-aware lead-1 freeze (2026-08-26)

Lead 1 is no longer written by the 06:30 UTC run: JAO publishes tomorrow's
flow-based capacities at 10:30 CET on D-1, so the 06:30 run does leads 2..7
(`MIN_LEAD_DAYS=2`) and lead 1 is frozen at 09:05 UTC (`EUPHEMIA_REQUIRE_JAO`,
skips if JAO is not out yet) or 10:05 UTC (always). Both are before the 12:00
CET gate (10:00 UTC summer / 11:00 UTC winter). See
`docs/experiments/jao-maxbex-atc.md`.

## 3. Retro labeling contract (honesty-critical, FROZEN)

The retro writer has **two modes** (owner amendment, Aug 2026). Both keep the
same honesty invariant — *"what we said then" is preserved verbatim, forever* —
but relocate where it lives:

- **Additive-fill mode (default, `EUPHEMIA_RETRO_SUPERSEDE` unset).**
  `write_forecast!(...; is_retro=true)` checks, inside the write transaction,
  whether the slice `(market_date, lead_days, input_mode)` already holds any
  `is_retro=false` row at any code_version. If so it **refuses** (`:refuse`). The
  reset only FILLS GAPS in the live record; the genuine live rows stand in place,
  immutable.
- **Supersede mode (`EUPHEMIA_RETRO_SUPERSEDE=1`).** The reset REPLACES the
  existing live weather-track vintages so the live series shows one consistent
  reset generation. Honesty is preserved by a **backup**: for each colliding
  slice the writer, in a single transaction, (1) copies every live row VERBATIM
  to `simulations.forecast_prices_pre_reset` (same data columns +
  `superseded_at_utc`), asserting the backup count **equals** the replaced count,
  then (2) delete-then-inserts the retro rows in the live table (`:supersede`).
  The backup table IS the honesty mechanism now — "what we said then" is
  auditable there in full; the live series carries the `reset_tag`. `Ας κρατήσει
  ένα backup` — kept, by construction.

Common to both:

1. **Honest stamping.** `prediction_made_utc` = the ACTUAL compute time (now,
   Aug 2026). `is_retro=true`, `reset_tag`, and `retro_of_utc` (the natural
   D−lead instant reconstructed) are ADDITIVE — existing readers are unaffected.
2. **The purity guard is mode-scoped.** LIVE writes keep both hard guards
   absolute (`assert_unrealized` day-level + `assert_hours_unrealized`
   hour-level). RETRO reconstructs already-realized days on purpose, so those
   assertions are replaced by this labeling contract — the honesty comes from the
   labels + (refuse | backup-then-replace), not from a future-hour assertion.
3. **The three writer paths are a pure decision** (`retro_write_plan`,
   `:insert`/`:refuse`/`:supersede`), unit-tested DB-free, and validated by a
   real-Postgres roundtrip (refuse leaves the live slice intact; supersede backs
   up N and replaces with backup-count == replaced-count; no-conflict inserts
   directly).
4. **Display.** The web manifest carries an additive `data_reset` field (reset
   tag, window, slice count, the notice text) and the zone series parquet carries
   per-row `is_retro`/`reset_tag`, so the SPA renders the reset notice ("Data
   reset at 1 Aug 2026, retroactively") and can badge retro rows within the
   unified "what we said when" series. Freshest-enabled default per day + the
   lead ladder browsable — generalizes the current view.

---

## 4. Frozen metrics for judging the 06:30 slice

Judged on the WEATHER track, per lead, per zone, within-regime where relevant:

- **Per-lead skill:** MAE, bias (sim − actual), Pearson corr, aggregated by
  `(lead_days, zone)` and footprint-wide. Scored-cell counts beside every figure.
- **Lead-1 pre-gate vs the evening entsoe refresh:** the pre-gate weather lead-1
  slice vs the same day's evening entsoe lead-1 slice — the cost (if any) of
  freezing before the gate on model inputs instead of after it on the TSO's
  published forecast. The pre-gate slice is useful if its MAE/corr are within the
  per-zone envelope (+3.0 MAE / −0.05 corr) of the evening refresh.
- **Collapse (SCIENTIST.md §4, ≤ €5):** hit-rate and false-alarm rate per lead,
  first-class alongside MAE/corr — the midday solar-surplus / negative-hour
  classification that dominates continuous MAE near the RES-coverage threshold.
- **Monotonicity:** MAE non-decreasing / corr non-increasing with lead is the
  expected shape; a non-monotone lead is a flag to investigate (vintage gap,
  eligibility artefact).

**Guardrails (unchanged program gates):** per-zone envelope (+3.0 MAE / −0.05
corr), the no-new-cap-hours ceiling, outside-regime deltas ≈ 0. The two enablers'
byte-identity guards (§1) are the ship guard for the record path.

---

## 5. Phase-2 runbook (the actual reset execution checklist)

Phase 2 is a separate run, executed AFTER:
- the **39-zone ML rollout** merges (its winners land in `meta.json`; the driver
  picks them up automatically), and
- the **strategy-tagged book-capture** PR lands (additive `strategy` column on
  the books parquet via `BOOK_SINK`, price-inert). The retro backfill must run
  after it so the regenerated July books carry the `strategy` column — the
  capture path change flows through automatically; just sequence on that PR's
  merge.

Execution checklist ("fill all surfaces"):

1. **Scoreboard:** run `bin/score_forecasts.jl` after the backfill (and on the
   ongoing schedule) so every retro `(date, lead, zone)` slice gets MAE/bias/corr
   + collapse metrics; the per-lead board aggregates them.
2. **Books via the record:** with the strategy-column capture in place, the retro
   run captures each regenerated day's tagged book to the books parquet
   (`BOOK_SINK`, worker-side) — the July books carry the `strategy` column.
3. **Recent days + map:** `bin/export_web_parquet.jl` (+ `export_forecast_json.jl`)
   re-export the zone series (now carrying `is_retro`/`reset_tag`), the scoreboard
   and the map; the manifest gains `data_reset`.
4. **Inputs plane:** `bin/export_prediction_inputs.jl` over the whole reset window
   (`INPUTS_BACK_DAYS` large enough to span 2026-07-01→) so the Predictions page's
   driver/prediction/reference/actuals surface covers the reset window.
5. **Flows persistence for forecast runs (the #278 dormant feature):** enable
   forecast-flow persistence so `export_flows_parquet.jl` writes per-day coupled
   flows for the reconstructed window (dormant today — pure-forecast windows
   don't persist `transmission_flows`).
6. **Verify:** the retro no-clobber contract left every genuine live slice intact
   (`is_retro=false` counts unchanged); `data_reset` manifest reflects the window;
   per-lead board renders on the SPA with the reset notice.

Run command (Phase 2, per the machine's ≤10-parallel-clear constraint). The
owner amendment: the reset REPLACES the existing July live weather-track
vintages (`EUPHEMIA_RETRO_SUPERSEDE=1`), backing them up to
`simulations.forecast_prices_pre_reset` first. Omit the flag for the default
additive gap-fill.
```bash
EUPHEMIA_DATA_STORE=... INPUT_MODE=weather EUPHEMIA_RETRO_SUPERSEDE=1 \
EUPHEMIA_FORECAST_RETRO_ASOF=<last past market day> \
EUPHEMIA_FORECAST_RETRO_START=2026-07-01 \
EUPHEMIA_FORECAST_RESET_TAG=2026-08-01-reset MAX_LEAD_DAYS=7 \
  julia --project=. bin/daily_forecast.jl
```
Verify after: `SELECT reset_tag, count(*) FROM simulations.forecast_prices
WHERE is_retro GROUP BY 1` and `SELECT count(*) FROM
simulations.forecast_prices_pre_reset` (== the superseded live-row count).

### Expected Phase-2 runtime
`run_retro` iterates leads (each a fixed vintage) and, within a lead, clears the
window sharing the UTC-day cache: **7 leads × (W_days + 1) coupled UTC-day
clears** for a W-day window. One 39-zone two-pass UTC-day clear **measured
offline** (HiGHS, single process, DuckDB extract, 2026-04-03) = **≈ 122 s**
(status optimal, 39 zones). For the July window (W ≈ 31): 7 × 32 ≈ **224 clears**
≈ **7.5 h of pure solve** run sequentially (≈ 14 min per market day across all 7
leads, since consecutive market days share the UTC-day cache within a lead), plus
the per-lead open-meteo weather fetch (39 zones × RES+load, throttled) — a few
minutes per lead. Two caveats on the estimate: (a) the first clear pays cold
caches — warm clears in a long run are faster, so 122 s is an upper-ish per-clear
figure; (b) live Postgres I/O differs from the extract. Parallelize across leads
(they are independent) to compress wall time, keeping **concurrent clears ≤ 10**
(the machine runs an overnight fetch). A window that extends past July scales
linearly at ≈ 14 min/market-day.
