# Time-series foundation models as a lead-1 price forecast (sprint 2026-11-14)

> **Phase 2 (2026-11-15): Timestral with physics covariates and the scenario pass-through test →
> [physics.md](physics.md).**

**Question (owner):** "it would be interesting to try more advanced tools, like Timestral, for
this job." Can a zero-shot time-series foundation model (TSFM), run on CPU, forecast the
day-ahead price better than the live product, and is there a simple way to combine it with the
counterfactual?

**Framing.** The counterfactual (`sim`) is a conduct/physics instrument: its deviations from
settled prices are the finding, and it never reads settled prices (no-fit rule). A TSFM reads
settled prices by construction, so it is a **separate prediction product**. It answers "what will
the price be?", not "what would a competitive market have cleared?". It belongs next to `sim`
the way the existing `gbm` / `stats` overlays do, never inside the clearing.

## Verdict (numbers below; ship/no-ship is the owner's call)

All verdicts are on 54,231 cells (39 zones × 58 days, 2026-09-14..11-13), lead-1. Issuance
labels:

- **(a) 06:30** — prices only.
- **(a′) post-sim, about 10:15 UTC D-1, still pre-gate** — anything that reads the live `sim`.
  `sim` is published 08:16–10:06 UTC D-1.
- **(b) gate-time proxy** — ENTSO-E latest revisions, publication time not verified.

- **Zero-shot point forecast, (a) 06:30.** Timestral-209M on settled prices alone scores
  **MAE 28.0 €/MWh, corr 0.90**. The live lead-1 product scores **81.5 / 0.39**, and naive D-1 39.7 / 0.81.
  Chronos-2 is about 1 €/MWh behind (29.0).
- **Hybrid, (a′) post-sim about 10:15 UTC — not a 06:30 product.** Feeding the live
  counterfactual `sim` to the TSFM as a known-future covariate gives **25.1 / 0.92**.
  - On the 47,679 cells where `sim` was published by 10:00 UTC D-1 it gives **25.3**, against
    28.8 for the same-context prices-only control.
  - The gain is concentrated where the physics matters (Nordic, Baltic and NW-European wind
    zones).
- **Failure, (a′).** Correcting `sim` with a TSFM forecast of its residual does **not** work
  (42.3).
- **P(price ≤ 0).** Like-for-like against agent `collapse`'s D-1 logistic (Brier 0.0098, AUC 0.952):
  - Timestral (a) scores Brier **0.0094**, AUC 0.945.
  - An unfitted 50/50 average of the two, also (a), reaches **Brier 0.0090, AUC 0.967**.
  - Averaging with Timestral+`sim` (a′) reaches 0.0088 / 0.972.
- **Runtime.** About 30 s for all 39 zones on 16 CPU cores, which fits the 06:30 job trivially.
- **This is a prediction product, not a change to the counterfactual.**

## What "Timestral" is

[Timestral](https://mistral.ai/news/timestral/) is Mistral AI's first time-series foundation
model family, released 2026-10-15. Four sizes: 5M, 28M, 123M and 209M parameters. It is a
patch-based causal transformer with:

- a 32,768-step context;
- 21 output quantiles;
- multivariate targets;
- past-only, known-future and categorical covariates.

It runs on CPU. Code is Apache-2.0
([github.com/mistralai/timestral](https://github.com/mistralai/timestral)); weights are
Modified-MIT ([HF](https://huggingface.co/mistralai/Timestral-209M)). Mistral self-reports #1
on GIFT-Eval, TIME and fev-bench; I found no independent verification and no energy-price
example. The second model is **Chronos-2** (Amazon, [arXiv 2510.15821](https://arxiv.org/abs/2510.15821),
`amazon/chronos-2`, 120M params, covariates, the leader before Timestral). TimesFM-2.5/3, TiRex
and Moirai-2 were not run, because they are univariate-core models and two covariate-capable
models were enough for the budget.

## Information set (enforced in `run_tsfm.py::build_inputs`)

- **Issuance and lead.** Lead 1. Prices-only variants issue nominally at D-1 06:30 UTC (`issued_utc` in
  the outputs). Variants that read `sim` can only issue after `sim` is published (live
  `prediction_made_utc` = 08:16–10:06 UTC D-1 in this window), so they are **post-sim, about
  10:15 UTC** reconstructions. The nominal `issued_utc` stamp does not apply to them. On 7 days
  (6,552 cells: 10-08, 10-09, 10-11, 10-12, 10-13, 10-16, 10-20) `sim` came after 10:00 UTC; the
  `*_ontime` scopes in `evaluate.py` exclude them. The delivery day D is the
  Europe/Athens market day, with the same 24/23/25 UTC hours as the live JSON.
- **Primary context: settled prices through D-1** (`settled_lag=1`, files `*_L1`). D-1's prices
  were auctioned on D-2 at 12:00 CET and published around 12:45 CET D-2, so they are public at
  issuance.
- **Conservative context: through D-2** (`settled_lag=2`). This was the sprint brief's original
  rule, kept as a variant.
- **Covariates and their labels:**
  - `uni` reads only prices. Label **(a) 06:30**.
  - `sim` and `resid` also read the live `sim` for D-1 and D. Label **(a′) post-sim about
    10:15 UTC D-1**, still before the 12:00 CET gate.
  - `cov` adds the ENTSO-E D-1 load, wind and solar forecasts, latest vintage in the extract.
    Label **(b) gate-time proxy**: these are latest revisions with no publication filter, so the
    label does not imply verified 10:00 availability. A publication audit (`update_time_utc` < D-1 06:30 UTC,
    2026-09-14..11-13) found load forecasts provably pre-gate only for the 7 IT zones (and part
    of HU/RS/LT). RES forecasts were never provably pre-gate.
- **Naive baselines:** same local hour on Athens market day D-1 / D-2 / D-7, not UTC−24 h, so
  the 25-h DST day 10-25 cannot pull a target-day price. Policy for the repeated fall-back 03:00
  hour: the source value is the mean of the duplicated hours, and both repeated target hours map
  to the same source hour.
- **Settled actuals:** resolution-aware hourly mean, highest `sequence`
  (`test/scripts/eu_eval_metrics.jl` convention), rounded to 1e-8 so exact zeros stay zero.

## Coverage

- **Window:** 2026-09-14 → 2026-11-13, all 39 zones.
- **Comparator:** the live published lead-1 **weather** track (`em-team/live/*.json`, cv40–42).
- **Common set:** cells where the live row, the settled price and every method exist. That is
  **54,231 cells = 39 zones × 58 days**; the live lead-1 weather track has no row for 3 days of
  the window.
- **Scopes:** everything is reported on all 39 zones and excluding the 7 IT-* zones (the sim
  had an Italian fleet data defect 07-20..11-03).
- **P(≤0) set:** scored on agent `collapse`'s 57,111 cells / 743 events, with labels identical to
  ours (0 disagreements).

## Results

### Headline: point forecast on 54,231 cells (39 zones × 58 days)

| method | context | label | MAE all39 | bias | pooled corr | per-zone corr | MAE exIT |
|---|---|---|---|---|---|---|---|
| live `sim` (lead-1 weather, cv40–42) | – | (a) | 81.5 | −51.2 | 0.39 | 0.61 | 65.9 |
| naive: D-1 same local hour | D-1 | (a) | 39.7 | −1.0 | 0.81 | 0.67 | 42.0 |
| naive: D-2 same local hour | D-2 | (a) | 51.1 | −2.2 | 0.72 | 0.52 | 54.4 |
| naive: D-7 same local hour | D-7 | (a) | 54.4 | −11.0 | 0.68 | 0.46 | 58.2 |
| **Timestral-209M, prices only** | **D-1** | (a) | **28.0** | −3.2 | **0.90** | **0.80** | **29.0** |
| Chronos-2, prices only | D-1 | (a) | 29.0 | −3.7 | 0.89 | 0.79 | 30.2 |
| Timestral-209M, prices only | D-2 | (a) | 37.5 | −6.8 | 0.84 | 0.68 | 39.9 |
| Chronos-2, prices only | D-2 | (a) | 38.6 | −5.4 | 0.83 | 0.66 | 41.2 |
| Chronos-2 residual corrector (`sim` + TSFM(settled − `sim`)) | D-1 | (a′) | 42.8 | +0.1 | 0.65 | 0.68 | 34.9 |
| Chronos-2 residual corrector | D-2 | (a′) | 47.4 | −0.3 | 0.62 | 0.65 | 39.3 |
| Timestral-209M residual corrector | D-1 | (a′) | 42.3 | +1.0 | 0.65 | 0.69 | 34.9 |
| Timestral-209M, prices only, 2048-h context (control) | D-1 | (a) | 28.6 | −3.4 | 0.89 | 0.79 | 29.7 |
| **Timestral-209M + live `sim` as known-future covariate** (2048 h) | **D-1** | **(a′) post-sim** | **25.1** | −2.7 | **0.92** | **0.85** | **25.4** |
| Chronos-2 + live `sim` as known-future covariate | D-1 | (a′) post-sim | 26.1 | −2.9 | 0.91 | 0.84 | 26.5 |
| Chronos-2 + ENTSO-E D-1 load/wind/solar (known-future) | D-1 | **(b) gate-time** | 24.7 | −1.9 | 0.92 | 0.85 | 25.3 |

**Excluding the 7 days with `sim` after 10:00 UTC** (47,679 cells, `all39_ontime`):

| method | MAE all39 | corr | MAE exIT |
|---|---|---|---|
| live `sim` | 81.8 | 0.40 | 66.8 |
| naive D-1 | 39.5 | 0.82 | 41.9 |
| Timestral, prices only (8192 h), (a) | 28.2 | 0.90 | 29.4 |
| Timestral, prices only (2048 h control), (a) | 28.8 | 0.89 | 30.1 |
| Timestral + `sim`, (a′) | 25.3 | 0.92 | 25.7 |
| Chronos-2 + `sim`, (a′) | 26.3 | 0.91 | 27.0 |
| Chronos-2 + ENTSO-E, (b) | 25.0 | 0.92 | 25.7 |
| Timestral residual corrector, (a′) | 43.6 | 0.64 | 35.6 |

The hybrid's 3.5 €/MWh gain is the same with and without those days.

**Gate-time covariates on the 8 calibration days only** (7,488 cells). The full Timestral run
was stopped at the budget, at 75 s/day.

| method (D-1 context) | label | MAE all39 | corr | per-zone corr | MAE exIT |
|---|---|---|---|---|---|
| live `sim` | (a) | 85.2 | 0.37 | 0.60 | 68.5 |
| Timestral, prices only, 2048 h (control) | (a) | 30.1 | 0.91 | 0.84 | 31.0 |
| Timestral + `sim` covariate, 2048 h | (a′) | 27.3 | 0.92 | 0.87 | 27.7 |
| Timestral + ENTSO-E load/wind/solar, 2048 h | (b) | 24.8 | 0.94 | 0.90 | 25.2 |

Over the full window, Chronos-2 + ENTSO-E (gate-time) scores 24.7, against 26.1 with `sim` and
29.0 on prices only. At gate time, ENTSO-E's own load and RES forecasts help more than `sim`, as expected: they
are the fundamentals the auction clears on. Their publication before the gate is not verified
in the extract (latest revisions), and at 06:30 they are not provably published. That is why
the pre-gate hybrid uses `sim`, which is built on the weather-track RES/load and published about
10:15 UTC, as its carrier of fundamentals.

- **Per month (all39, Sep / Oct / Nov):** Timestral D-1 27.0 / 27.0 / 31.4; live `sim`
  65.2 / 82.6 / 100.5; naive D-1 40.1 / 37.7 / 43.6.
- **On the 8 calibration days, Timestral D-1 vs `sim`:**

  | day | Timestral D-1 | `sim` |
  |---|---|---|
  | 09-16 | 22.1 | 47.0 |
  | 09-20 | 17.0 | 59.0 |
  | 09-27 | 25.3 | 58.6 |
  | 10-06 | 24.6 | 77.3 |
  | 10-19 | 26.3 | 103.4 |
  | 11-04 | 23.6 | 126.4 |
  | 11-09 | 55.1 | 155.6 |
  | 11-13 | 35.9 | 53.9 |

- **Per zone** (`eval_L1_perzone.csv`):
  - Timestral D-1 has a lower MAE than `sim` in **all 39 zones**, and a lower one than naive D-1
    in all 39.
  - `sim` keeps the **better hourly correlation** where the physics carries information prices
    alone do not: FI (0.80 vs 0.40), SE1 (0.67 vs 0.53), SE2 (0.64 vs 0.47), EE (0.75 vs 0.70),
    NO4 (0.44 vs 0.31), DE_LU (0.87 vs 0.85). These are wind- and hydro-driven zones.
- **Against the site's own ML overlays, on their published coverage:**
  - `gbm` (physics + GBM residual): MAE 64.5 vs Timestral D-1 26.3 (19,560 cells).
  - `stats` (pure-stats GBM on settled lags): 47.5 vs Timestral D-1 27.1 (14,388 cells).
- **Point-forecast collapse classification:** the TSFM median rarely goes ≤ 0. Timestral D-1
  has a hit-rate of 0.21 and a false-alarm ratio of 0.31; `sim` has a hit-rate of 0. The
  probability below is the useful output.

### The hybrid that works: the counterfactual as a covariate (post-sim, about 10:15 UTC)

Giving the TSFM the live lead-1 `sim` (history plus D-1 and D) as a known-future covariate cuts
MAE by **3.5 €/MWh at equal context**: 28.6 → 25.1 for Timestral, 29.0 → 26.1 for Chronos-2.
Per-zone correlation rises from 0.79 to 0.85, and 32 of 39 zones improve.

The gains are where the physics carries information that prices alone do not:

| zone | MAE change (€/MWh) | hourly corr before → after |
|---|---|---|
| FI | −18.2 | 0.35 → 0.86 |
| EE | −12.2 | |
| LT | −9.2 | |
| DE_LU | −8.4 | |
| DK1 / DK2 / NL / BE | −7 to −8 | |
| SE1–SE4 | −6 to −7 | SE1 0.44 → 0.77 |

There is no gain in the IT zones, where `sim` had the fleet-data defect (IT `sim` corr ≈ 0.3), or
in SEE.

So despite its −51 €/MWh level bias, the counterfactual's hourly **shape** (RES, interconnection,
merit order) is real information that the statistical model uses. This is the right way to
combine them: the TSFM supplies the level from recent settled prices, `sim` supplies the
physics of tomorrow, and `sim` itself stays untouched as the conduct instrument.

The hybrid is **not** a 06:30 result. It can only run once that day's `sim` exists (08:16–10:06
UTC D-1 here), so it is a post-sim, pre-gate (about 10:15 UTC) product. A genuine 06:30 hybrid
would need a `sim` archived by then, which the live pipeline does not produce today.

### P(price ≤ 0), against agent `collapse`'s pre-gate logistic

The comparators are pinned in `compare_collapse.py`, which asserts 57,111 cells, 743 events and
label equality with our panel (0 disagreements):

- **D1** (default): `results/collapse-probability-primary/`, `settled_history_lag=1`. This is
  like-for-like with the `*_L1` runs.
- **D2:** `results/collapse-probability-v2/`, conservative. This is like-for-like with the D-2 runs.
- The superseded `collapse-probability/` (741 events, unrounded labels) is not used.

The TSFM probability comes from interpolating the 21 quantiles.

**D-1 information set (primary):**

| model | label | Brier all39 | AUC all39 | log-loss | Brier exIT | AUC exIT |
|---|---|---|---|---|---|---|
| climatology (collapse's) | | 0.01348 | 0.657 | 0.0770 | 0.01377 | 0.711 |
| collapse logistic, D-1 (load/RES persistence + calendar + D-1 prices) | (a) | 0.00983 | 0.952 | 0.0412 | 0.00911 | 0.954 |
| **Timestral-209M, D-1** | (a) | **0.00938** | 0.945 | 0.0400 | 0.00891 | 0.970 |
| Chronos-2, D-1 | (a) | 0.01028 | 0.899 | 0.0455 | 0.00992 | 0.937 |
| Timestral-209M + `sim`, D-1 | (a′) | 0.00961 | 0.953 | 0.0408 | 0.00901 | 0.970 |
| **unfitted 50/50 blend: logistic D-1 + Timestral D-1** | (a) | **0.00900** | **0.967** | **0.0365** | **0.00851** | **0.977** |
| unfitted 50/50 blend: logistic D-1 + Timestral+`sim` | (a′) | 0.00882 | 0.972 | 0.0356 | 0.00821 | 0.981 |

**D-2 information set (conservative):**

| model | Brier all39 | AUC all39 | Brier exIT | AUC exIT |
|---|---|---|---|---|
| collapse logistic, D-2 | 0.01049 | 0.931 | 0.01024 | 0.925 |
| Timestral-209M, D-2 | 0.01088 | 0.923 | 0.01059 | 0.951 |
| unfitted 50/50 blend | 0.01027 | 0.949 | 0.01001 | 0.956 |

- **TSFM probabilities rank well but are over-dispersed.** Mean p is 0.017–0.022 against a base
  rate of 0.013.
- **The logistic and the TSFM are complementary.** At equal information the TSFM has the better
  Brier and the logistic the better AUC. Their unfitted average beats both on every score.
- **Not done here:** a calibrated stack would need a rolling-origin fit.

### Failed: residual corrector (one paragraph)

Forecasting the counterfactual's residual (settled − `sim`) with the TSFM and adding it back to
`sim` removes `sim`'s level bias (bias ≈ 0) but loses badly to the plain TSFM: Chronos-2 D-1
MAE is 42.8 vs 29.0 (ex-IT 34.9 vs 30.2). Two reasons:

- The corrected forecast inherits `sim`'s hour-to-hour noise.
- The residual series is **not stationary across code versions**. The cv40 → cv42 switch on
  11-03 changed the Italian level by hundreds of €/MWh, so on 11-04 the corrector scored 83.7
  against 24.6 for the plain TSFM, and on 11-09 it scored 107 against 60.

A residual model only makes sense on a frozen `sim` version with a long, version-consistent
residual history, which the live product does not have. Not pursued further.

### Runtime (CPU, aarch64 Neoverse-N1, all 39 zones, one delivery day)

| model | context | threads | wall per day (39 zones) | weights |
|---|---|---|---|---|
| Timestral-209M, prices only | 8192 h | 16 | 26 s (idle box) · 42 s with 8 threads under contention | 837 MB |
| Timestral-28M, prices only | 8760 h | 16 | 11 s | 111 MB |
| Chronos-2, prices only | 8192 h | 16 | 18 s · 25 s with 8 threads | 456 MB |
| Timestral-209M + 3 covariates | 2048 h | 16 | 35 s (grows ~quadratically: 97 s at 4096 h) | |
| Chronos-2 + 3 covariates | 8192 h | 16 | 50 s | |

Model load is 2–12 s. The whole 61-day × 39-zone backtest of one variant took 26–45 minutes on
8 cores.

## How it would sit in production (proposal, not implemented)

The TSFM is a **prediction overlay**, exactly like the existing `gbm` / `stats` lines. It does
not touch the clearing, the books or `code_version`.

1. **Where it runs.** Add one Python step after the Julia forecast in the 06:30 UTC
   `daily-forecast.yml` job (self-hosted `energy-markets-k8s` pod, 120-min timeout), or put it
   in the same emitter that writes `simulations.model_lines` (`bin/emit_model_lines.py`).
2. **What it reads.** Settled `entsoe.energy_prices` through D-1, using the same dedup + hourly
   mean as `test/scripts/eu_eval_metrics.jl`, and an 8192-h context per zone. No covariates are
   needed for the headline number.
3. **What it writes.** Rows `model='tsfm_timestral'` to `simulations.model_lines` for the 24 h
   of D, with the median as `price_eur_mwh`. It optionally also writes `tsfm_p0` (P ≤ 0) and
   `tsfm_q10` / `tsfm_q90`.
   - `bin/export_forecast_json.jl` / `export_web_parquet.jl` would add a `"tsfm"` field next to
     `"sim"`, `"gbm"` and `"stats"` (a third dashed line on the site). `"tsfm_p0"` could also
     feed the collapse-risk badge, preferably blended with `collapse`'s logistic.
4. **Runtime.** About 30 s for 39 zones × lead-1 on 16 aarch64 cores (Timestral-209M), or about
   11 s with the 28M model. Add a one-time ~800 MB weight download, which should be cached in the
   pod image or a PVC with `HF_HUB_OFFLINE=1`. This is negligible against the job's 120-min budget
   (live lead-1 rows are stamped ~09:10 UTC today, so the Julia part is the bottleneck).
   - The prices-only line can issue at 06:30. The `sim`-covariate hybrid must run **after** that
     day's lead-1 `sim` is written (about 10:15 UTC, before the 12:00 CET gate). In practice it is
     a second step at the end of the forecast job.
   - Leads 2–7 are a longer horizon in the same call: one forward pass covers 168 h. They are
     **not evaluated here**.
5. **What it must not do.** Feed the counterfactual. `sim` stays the conduct instrument. The gap
   `tsfm − sim` is itself an informative series: a market-expectation-vs-physics spread per
   zone-hour.
6. **Risks.**
   - **Licences: owner decision.** The Timestral weights' "Modified MIT" licence withholds all
     rights from any company (or employer) whose consolidated monthly revenue exceeds $20M; a
     commercial licence must be requested from Mistral. Chronos-2 is Apache-2.0 with no such
     clause and is only ~1 €/MWh worse (29.0 vs 28.0), so it is the safe default if the
     revenue clause is a problem.
   - **The pip install is a git dependency.** Pin a commit.
   - **The model is a statistical extrapolator.** It forecasts collapses only where recent
     history shows them, and it lags regime breaks (11-09 is its worst day, MAE 55).


## Files

- `build_panel.py`: hourly panel (settled, ENTSO-E load/wind/solar + update stamps) plus the
  live lead-1 rows. Reads the extract read-only.
- `run_tsfm.py`: forecasts. Arguments: `--model t209|t28|c2`, `--variant uni|cov|sim|resid`,
  `--settled-lag 1|2`, `--ctx`.
  - Writes one row per (zone, hour) with `issued_utc`, `context_end_utc`, `median`, `p_le0`,
    `p_le5` and 21 quantiles.
- `evaluate.py`: MAE, bias, corr, per-zone corr, ≤0/≤5 hit and false-alarm rates, Brier, AUC
  and 80% interval coverage, vs `sim`, naive D-1/D-2/D-7 and the site's `gbm`/`stats` overlays.
- `compare_collapse.py`: P(≤0) vs `collapse`'s logistic on common cells.
- `prob_scores.py` ([prob-scores.md](prob-scores.md), #431): per-quantile pinball loss, a 21-grid CRPS
  approximation (backtest only), 50/80/90/98 % coverage and width, P(≤0) reliability for raw TSFM
  and the hourly/day blends, and an offline split-conformal test. `--live-api` scores the live overlay.
- Phase 2 ([physics.md](physics.md)): `run_tsfm.py --variant phys|physresid|physpre`,
  `scenario_profiles.py`, `passthrough.py`, `summarize_passthrough.py`, `dose_response.py`.

Environment: a Python 3.12 venv outside the repo with `torch` (CPU), `timestral` (git) and
`chronos-forecasting` 2.3.2. Weights come from the HF cache; none are committed.


Production wiring draft (owner decision): [overlay.md](overlay.md) — `bin/emit_tsfm_overlay.py`, `test/test_tsfm_overlay.py`.
