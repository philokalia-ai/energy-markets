# Timestral WITH physics: does it extrapolate to structural change? (phase 2, 2026-11-15)

Owner's question: Timestral is good on prices alone. Can physics inputs make it extrapolate to
changes like the DC (+574 MW in GR) or cold ironing? The framing under test, not assumed: a
zero-shot TSFM conditions on covariates in context but has never seen the response to a shift it
has never seen, so an off-support change reaches the forecast only through an input whose effect
it can map from history.

**Answer in one line.**
- Physics covariates make Timestral clearly better day to day: arm C has MAE 22.8 against 28.0 on
  prices only, and it is better in all 39 zones.
- They do make the forecast move with a scenario: the pass-through is not ~0.
- But the movement is a per-zone statistical load→price sensitivity, not the coupled physics:
  - in GR it is 1.65–1.85× Euphemia's Δ;
  - in the neighbours it is 0.1–0.4×;
  - its hourly shape differs from Euphemia's;
  - it varies 1.3–2.8× from day to day.
- For scenarios, Euphemia must carry the structural Δ: scenario = C's base forecast + Δsim.

## Arms (Timestral-209M, zero-shot, no finetuning)

All arms use the same backtest as #404. The window is delivery 2026-09-14..11-13 (61 days), 39
zones, lead 1, settled context through D-1, 54,231 common cells. Covariate arms use a 2,048-h
context.

| arm | `--variant` | inputs | information-set label |
|---|---|---|---|
| A | `uni` | prices only | (a) 06:30 |
| B | `sim` | + live lead-1 weather-track `sim` | (a′) post-sim ~10:15 UTC |
| C | `phys` | + known-future [`sim`, residual load, gas SRMC] | (b) gate-time proxy |
| D | `physresid` | target settled − `sim`, C's covariates; final = `sim` + forecast | (b) |
| C-pre | `physpre` | + [lead-2 `sim` issued before D-1 06:30, residual load from t−168 h, SRMC] | (a) 06:30 |

Notes on the inputs:
- **Residual load** = ENTSO-E D-1 total-load forecast − wind − solar forecasts, latest revisions.
  The weather-track load is not in the extract.
- **SRMC** = TTF/0.5 + 0.404·EUA + 2, from closes dated before D-1 of the hour's market day.
- **Net position and imports: not used.** No ex-ante source exists (JAO net positions are auction
  outputs), and `sim` already carries the coupled flows.
- **Label (b)** is because only 63% of load rows and 2% of RES rows are provably published before
  D-1 10:00 UTC (#404 audit).

## Backtest

All 39 zones, 54,231 cells. ≤0 metrics use the same quantile→P(≤0) map as #404.

| arm | MAE | bias | corr | Brier ≤0 | AUC ≤0 | exIT MAE | on-time-days MAE |
|---|---|---|---|---|---|---|---|
| live sim | 81.5 | −51.2 | 0.39 | — | — | 65.9 | 81.8 |
| naive D-1 | 39.7 | −1.0 | 0.81 | — | — | 42.0 | 39.5 |
| A | 28.0 | −3.2 | 0.897 | 0.0094 | 0.945 | 29.0 | 28.2 |
| B | 25.1 | −2.7 | 0.917 | 0.0096 | 0.954 | 25.4 | 25.3 |
| **C** | **22.8** | −2.4 | **0.933** | **0.0087** | **0.972** | **23.2** | **22.9** |
| D | 25.7 | **−1.6** | 0.892 | 0.0115 | 0.958 | 25.3 | 26.1 |

- C beats A, B and D in 39/39 zones. D beats B in only 16/39.
- D fails in the zones where live sim is far off (Italy, sim bias −21 to −154 €/MWh), because the
  residual target has to carry that level.
- D's P(≤0) is badly calibrated (mean p 0.041 against a base rate of 0.013): the residual spread
  added to `sim` is too wide on low-price hours.
- Against collapse's pinned comparator D1 (57,111 cells, 743 events, 0 label disagreements):

| model | Brier | AUC |
|---|---|---|
| logistic | 0.00983 | 0.952 |
| C | 0.00850 | 0.973 |
| 50/50 blend of C and the logistic | **0.00823** | **0.981** |
| A-blend (phase 1) | 0.00900 | 0.967 |

**C-pre vs A, same 31 days (every second day), 29,015 common cells:**

| arm | MAE | bias | corr | Brier ≤0 | AUC ≤0 | exIT MAE | exIT AUC ≤0 |
|---|---|---|---|---|---|---|---|
| A | 28.1 | −6.9 | 0.894 | 0.0092 | 0.956 | 29.2 | 0.977 |
| C-pre | 25.5 | −4.4 | 0.915 | 0.0097 | 0.937 | 25.9 | 0.952 |
| B | 25.9 | −4.2 | 0.908 | 0.0099 | 0.956 | 26.3 | 0.973 |
| C | 23.3 | −3.7 | 0.927 | 0.0082 | 0.972 | 24.1 | 0.975 |

- C-pre improves the point forecast clearly: −2.6 ± 0.7 €/MWh (day-paired), 29/39 zones, 21/31
  days.
- Its P(≤0) is worse than A's.
- Most of C's gain needs the lead-1 sim and the D-1 ENTSO-E forecasts.

## Scenario pass-through (`passthrough.py`, `summarize_passthrough.py`)

Design:
- **Δsim profiles.** cv43 `results/scenarios-cv43.duckdb`: arms `eu43_dc574` and
  `eu43_ops_floor_paneu` against `eu43_base`. The mean scenario − base is taken per zone × Athens
  local hour over the Sep–Nov sample days (DC 46 days, ops 23); see `scenario_profiles.py`.
- **Load shifts.** DC: +574 MW flat in GR. Cold ironing: the FLOOR MW profile in 24 zones.
- **Perturbation.** These are added only to the delivery-day covariates. History is untouched,
  because the change is new: it is off-support.
- **Coverage.** 8 test days, every 8th: 09-14, 09-22, 09-30, 10-08, 10-16, 10-24, 11-01, 11-09.
- **Metric.** Pass-through = ΣΔforecast / ΣΔsim over the zone's delivery hours, on the median.

| test | B | C | D |
|---|---|---|---|
| DC GR (Δsim +7.03 €/MWh) | 0.52 | **1.85** | 1.65 |
| DC BG / RO / RS (Δsim +2.5 / +1.9 / +1.3) | 0.18 / 0.36 / 0.27 | 0.13 / 0.34 / 0.19 | 0.28 / 0.40 / 0.27 |
| DC GR load only (+574 MW, sim fixed), €/MWh per 100 MW | — | 2.0 | 1.6 |
| cold ironing, 30 zones pooled (Δsim +0.34) | 0.46 | 1.26 | 1.38 |
| synthetic sim +10%, all zones (zone median) | 0.47 (0.41) | 0.35 (0.29) | 0.46 (0.44) |
| synthetic residual load +10%, €/MWh per 100 MW (hours up) | — | 1.17 (91%) | 1.30 (92%) |

What this shows:
- **No arm passes ~0. Arm A passes exactly 0 by construction:** prices only can never see a
  scenario.
- **B (`sim` only) passes about half** of a `sim` shift. It rescales part of the level away: it
  learned from history that `sim` overshoots.
- **C and D move mainly through residual load.**
  - The load-only perturbation alone gives +11.6 €/MWh (C) and +9.0 €/MWh (D) in GR, against
    Euphemia's +7.0.
  - The TSFM puts the whole adjustment in the zone whose load moved; Euphemia's coupled clear
    spreads it over BG, RO and RS through the interconnectors.
  - So GR is over-shifted, neighbours under-shifted, and the footprint sum cancels to ~1.0 only by
    accident (C 1.02, D 0.97).
- **The shape differs.**
  - C's GR response peaks at midday: +18 to +28 €/MWh, where the base forecast is 85–110.
  - At the evening peak it is +9.
  - Euphemia's Δ is largest at 19–22. The two hourly profiles correlate at 0.51.
- **It is not stable.** C's per-day GR pass-through ranges 1.28–2.80; it is a sensitivity read off
  the particular 2,048-h context.
- **D is not "1 by construction".** It also sees `sim` as a covariate and lowers its residual when
  `sim` rises: its pass-through on a pure sim shift is 0.46.
- **Dose-response** (`dose_response.py`). 4 days (09-22, 10-08, 10-24, 11-09); GR load
  −574…+2,296 MW; ±10–40% shifts of sim or residual load in 8 zones (GR, DE_LU, ES, FR,
  IT-NORTH, PL, SE3, HU).
  - **The response is monotone.** C moves GR up in 100% of hours at every load dose.
  - **Sim shifts are proportional:** pass-through C 0.22–0.25, D 0.38–0.41, flat across doses.
  - **Load shifts saturate in GR.**
    - In C the effect per 100 MW is 2.3 (−574 MW), 1.9 (+287), 1.9 (+574), 1.75 (+1,148) and
      1.5 (+2,296) €/MWh.
    - In D it is 1.8 → 0.9, with 13% of hours not moving up at +2,296 MW.
  - The further the shift goes off-support, the more the response flattens. A merit order does
    the opposite near scarcity, so the TSFM's own response is least trustworthy exactly for big
    structural changes.

**Physics-delta composite vs the arms, DC scenario.** Δ in €/MWh, mean over 8 days × 24 h.

| | GR | BG | RO | RS | GR hourly-shape r |
|---|---|---|---|---|---|
| composite = Euphemia Δsim | +7.03 | +2.55 | +1.90 | +1.26 | 1.00 |
| C | +12.98 | +0.32 | +0.65 | +0.24 | 0.51 |
| D | +11.57 | +0.71 | +0.75 | +0.34 | 0.46 |
| B | +3.63 | +0.46 | +0.69 | +0.34 | 0.54 |

On cold ironing, the arms' responses correlate with Euphemia's Δ at cell level at only 0.18 (B),
0.25 (C) and 0.24 (D). That holds even where the pooled pass-through looks close to 1 (C 1.26).

## Recommendation (ship/no-ship is the owner's call)

**(a) Daily overlay.**
- **C is the best arm on every metric** and could be a post-sim refresh at about 10:40 UTC, after
  the lead-1 freeze (the slot `emit_model_lines.sh` already uses).
- The published 06:30 job (#415) cannot run it, because D's lead-1 sim does not exist yet. At
  06:30 the choice is A versus C-pre. C-pre is better on the line but worse on P(≤0) (AUC 0.937
  vs 0.956), so it is not a clear win: **keep A at 06:30.**
- Opt-in emitter arm: `TSFM_ARM=timestral-209m-phys --mode postsim` (PR #416). On an extract it reproduces the backtest's arm-C forecast to ≤1.5e-5 €/MWh.
- In production, the ENTSO-E forecasts are what the database holds at run time, so the label-(b)
  caveat applies to the backtest score, not to the live product.

**(b) Scenarios.**
- **Use no TSFM arm's own response as the scenario Δ.**
- Use the physics-anchored delta: scenario forecast = C base forecast (or A at 06:30) +
  (sim_scenario − sim_base), per zone-hour.
  - Euphemia carries the structure (coupling, hourly shape, merit order).
  - C carries the level and daily dynamics.
  - Pass-through is 1 by construction, and nothing new is trained.
- Use C's own load response only as a cross-check. Where it disagrees with Euphemia's Δ by more
  than 2× (GR on the DC scenario), report both.
  - C's single-zone sensitivity is an upper bound: an isolated zone, with no import relief.
  - Euphemia's Δ is the coupled answer.
- D is dominated: it is worse in the backtest, its P(≤0) is miscalibrated, and its scenario
  response is no more physical than C's.

## Coverage and what was not done

- **Backtest:** 61 days × 39 zones, 54,231 common cells. Scenario test: 8 days. DC: 4 zones ×
  24 h. Cold ironing: 30 zones with |Δsim| > 0.1 or a load shift.
- **One model, Timestral-209M.** Chronos-2 was not re-run (budget).
- **No ablation of C's three covariates.** The gain over B is not attributed between residual load
  and SRMC.
- **Scenario Δsim is a sample-mean profile per zone × hour**, not the per-day cv43 scenario sim.
  The per-day test is the right next step if scenarios go through this path.

## Files

- `run_tsfm.py`: `--variant phys|physresid|physpre` (phase 2).
- `scenario_profiles.py`: cv43 Δsim and load profiles.
- `passthrough.py`, `summarize_passthrough.py`: scenario pass-through.
- `dose_response.py`: proportionality check.
