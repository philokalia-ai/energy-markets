# NL residual diagnosis (exp/nl-diagnosis)

**Mission.** NL sits persistently just below the 0.75 corr bar (cv23 hourly corr
0.69/0.72/0.73/0.70 for 2023/24/25/26H1 at 117 TWh/yr). Determine whether a
spec-true ex-ante mechanism materially fixes it.

**Data.** cv23 model hourly CSV (`scratchpad/cv23_model.csv`, NL 30,479 hourly
rows 2023-01-01…2026-07-26, UTC instants) vs settled `entsoe.energy_prices`
(NL Day-ahead EUR; PT60M through 2025-09-30 then PT15M aggregated to hourly by
mean) from the offline extract `data/extracts/euphemia-live.duckdb` (read-only).
Border net imports from `entsoe.physical_flows` (import_from_X = flow(X→NL) −
flow(NL→X), hourly mean MW). Harnesses: `scratchpad/build_resid.jl`,
`analyze.jl`, `regime.jl`. Local hour = UTC + EU DST offset.

Overall (full window): **corr 0.720, MAE 24.29, bias(model−settled) −6.18**.
Alignment sanity-checked (corr matches the record's per-year 0.69–0.73).

## 1. This is a SHAPE (amplitude) problem, not a level problem

### By year
| year | n | corr | MAE | bias | settled |
|---|---|---|---|---|---|
| 2023 | 8688 | 0.767 | 24.65 | −14.88 | 96.0 |
| 2024 | 8544 | 0.711 | 22.48 | +1.09 | 77.3 |
| 2025 | 8447 | 0.728 | 24.16 | −2.93 | 87.2 |
| 2026H1 | 4800 | 0.697 | 27.09 | −9.11 | 99.3 |

Level bias swings sign year to year (−15 … +1); the corr ceiling is stable at
~0.7–0.73 regardless of level. So the binding constraint is diurnal SHAPE, not
absolute level.

### By local hour (bias = model − settled, all years)
The model's price curve is **too flat**: it does not fall enough at the solar
midday and does not rise enough at the morning and (especially) evening peaks.

| daypart | hours | bias | MAE | settled |
|---|---|---|---|---|
| night 00–05 | | ≈0 (−4…+5) | ~14 | 78–90 |
| morning ramp 07–08 | | **−18** | 28–30 | 109–110 |
| solar midday 11–15 | | **+8…+12** | 26–29 | 48–65 |
| evening peak 17–21 | | **−22…−36** | 27–39 | 117–132 |

Worst single hours: h19 bias −35.7 / MAE 39.4, h20 −34.1 / 38.5 (settled ~130).
Night hours are essentially unbiased and low-MAE — the model gets the trough
right; it misses the **peaks and the solar dip**.

### Season × daypart (worst cells)
- **JJA/MAM midday**: settled craters to ~29 €/MWh, model over-prices +14…+26.
- **All-season evening**: bias −18 (SON) … −29 (JJA); the dominant error mass.

## 2. Two distinct failure modes

### (A) Evening peak under-priced — partly NL-specific (GB), mostly systemic
Evening (h17–21, n=6350): bias **−26.5**, MAE 33.1. `corr(resid, imp_GB) =
−0.31`; net total import is uninformative (corr −0.03). Binning by BritNed
(NL↔GB) regime:

| GB regime | n | bias | MAE | settled | mean imp_GB |
|---|---|---|---|---|---|
| NL→GB (export) | 2630 | −14.0 | 23.9 | 107.0 | −860 |
| neutral | 2115 | −27.0 | 33.2 | 120.2 | −17 |
| **GB→NL (import)** | 1605 | **−46.4** | **48.3** | 139.8 | +800 |

The **worst evening under-pricing coincides exactly with NL importing from GB**:
settled ~140, model ~46 low. Mechanism: the fixed ex-ante flow injects ~800 MW
of GB power into NL cheaply, while in reality GB is at its own evening
CCGT-marginal peak and BritNed clears expensive. NL is the only footprint zone
whose *only* explicit-ATC border is GB (BE/DE_LU/NO2/DK1 are all implicit /
flow-coupled) — the textbook out-of-footprint boundary case.

**But the evening miss is largely systemic.** Comparing model−settled evening
bias across the continental core (UTC h17–19):

| zone | corr | MAE | bias | settled |
|---|---|---|---|---|
| **NL** | **0.427** | 38.7 | **−34.9** | 131.4 |
| DE_LU | 0.717 | 30.9 | −25.9 | 131.5 |
| BE | 0.603 | 32.5 | −26.2 | 124.5 |
| DK1 | 0.654 | 35.0 | −18.3 | 119.8 |
| NO2 | 0.637 | 24.6 | +9.7 | 85.4 |

Every continental zone under-prices the evening (~−26); it is a footprint-wide
evening-scarcity/shape deficit that NL inherits through coupling. NL is the
*worst* (bias −35, corr collapses to 0.43) — the extra ~−9 vs DE_LU plus the
GB-import tail (−46) is the NL-specific slice a BritNed book can address. The
bulk (~−26, present even when NL *exports* to GB) is the systemic component,
outside a single NL lever.

### (B) Solar-midday over-priced — the model has no downward flexibility
Midday (h11–15): **17.8%** of settled hours are **negative** (1131/6350); the
model is **never** negative (0 hours < 0). When settled < 20 €/MWh (1898 hrs),
model mean **+31.0** vs settled **−12.1** — a ~43 €/MWh over-price. The merit
book floors near the must-run discount and cannot express negative / deep-surplus
pricing. This is the cv18 `export_absorption_steps` territory (built, inert,
held back for coupled interactions) and/or a solar-forecast-underestimate
question — not an NL-specific boundary lever.

## 3. Ranked mechanism candidates

1. **BritNed NL↔GB BoundaryBook** *(measured here — the one spec-clean,
   NL-specific, established mechanism)*. GB out-of-footprint; the cv21/cv23 GB
   CCGT recipe (TTF/0.52 + UKA carbon/0.52 + O&M, laddered over demonstrated
   NL↔GB DA-explicit-ATC capability) generalizes directly. Targets the −46
   evening GB-import tail (~1600 hrs). Bounded upside: BritNed is ~1 GW on a
   ~15–20 GW peak, and it addresses only NL's GB slice, not the ~−26 systemic
   evening deficit. Full DA-explicit-ATC coverage confirmed 2023–2026 (~1000 MW).
2. **Footprint-wide evening scarcity shape** (systemic, NOT NL-specific): the
   ~−26 evening under-pricing shared by NL/BE/DE_LU/DK1 is the larger error mass.
   Out of scope for an NL mission; belongs to a peak-scarcity-form redesign
   (docs/experiments/fit-scarcity).
3. **Negative / export-absorption pricing at solar midday** (cv18 lever, or a
   solar-forecast-bias data fix): addresses the +8…+26 midday over-price and the
   18%-negative-hours the model cannot reach. Coupled-interaction risk (cv18
   NO-SHIP lesson); not NL-specific.
4. **Import backstop / scarcity credit for NL** (cv17): would *lower* NL prices —
   wrong sign for the dominant evening error; not pursued.

## 4. Pre-registered A/B gate (BritNed book, set BEFORE running)

Top candidate = the BritNed book (#1). 39-zone coupled footprint, :merit_order,
2-pass, HiGHS, save_to_db=false. Arm A = book OFF (`EUPHEMIA_DISABLE_NLGB=1`),
Arm B = book ON. Two windows (winter + summer), 8 days each.

- **PRIMARY (NL):** SHIP-CANDIDATE requires, in **both** windows, NL evening
  (h17–19) MAE −≥5% AND NL overall corr non-decreasing (Δ ≥ −0.005); with a
  material overall move (NL overall corr +≥0.02 **or** MAE −≥5%) in at least one
  window and no overall regression in the other.
- **NEIGHBOR SAFETY:** every captured neighbor (BE, DE_LU, DK1, NO2, FR) within
  **±0.02 corr and ±1.0 MAE** in both windows.
- **NO-SHIP** if NL fails the primary in either window, or any neighbor breaches
  the safety band (the cv18 coupled-leakage failure mode).

## 5. A/B results

> **HEADLINE VERDICT: NO-SHIP.** A first small **2+2-day pilot** (§5a) looked like
> a strong summer NL win, but the **blind wider confirm (7 winter + 8 summer days,
> §5b)** shows the effect is not real: NL summer flat (corr −0.001), NL winter
> corr-up-but-MAE-worse, and a genuine **FR winter neighbor regression** (corr
> −0.189 / MAE +2.2) with large bidirectional coupled swings — the pre-registered
> gate fails on every prong. The pilot was a small-sample artifact (the cv18
> coupled-mechanism lesson). Details below.

### 5a. Pilot (2+2 days) — LOOKED promising, was small-sample noise

39-zone coupled footprint, :merit_order, enrich_network, passes=2, HiGHS,
save_to_db=false, extract read-only. Arm A = book OFF (`EUPHEMIA_DISABLE_NLGB=1`),
Arm B = book ON. Harness `ab_harness.jl`, scorer `score_ab.jl`. This first window
was **2 winter + 2 summer days** (all 8 clears, no crashes). Metrics vs settled
`entsoe.energy_prices` (hourly). EVE = UTC h17–19 (local evening peak).
**Superseded by §5b — do not read the pilot as the result.**

### WINTER — 2025-01-14, 2025-01-15
| zone | A corr | A MAE | B corr | B MAE | ΔcorrN | eve MAE A→B |
|---|---|---|---|---|---|---|
| **NL** | 0.603 | 61.30 | 0.594 | 61.17 | **−0.009** | 84.0→84.0 |
| BE | 0.887 | 23.35 | 0.887 | 23.43 | 0.000 | 29.9→29.9 |
| DE_LU | 0.977 | 46.02 | 0.977 | 46.02 | 0.000 | 65.5→65.5 |
| DK1 | 0.955 | 52.09 | 0.956 | 52.00 | +0.001 | 39.2→39.2 |
| NO2 | 0.519 | 57.51 | 0.519 | 57.48 | 0.000 | 67.8→67.8 |
| FR | 0.781 | 18.75 | 0.781 | 19.15 | 0.000 | 26.4→26.4 |

Winter is **inert** — NL corr −0.009, evening unchanged. But these 2 days are
**anomalous** (NL MAE 61, bias −59): a large *systemic level* under-price the
~1 GW BritNed slice cannot touch. (The single day 2025-01-14 scored in isolation
was NL corr +0.021 / MAE −0.5 — so the winter window is dominated by 2025-01-15's
level miss, i.e. underpowered, not a clean negative.)

### SUMMER — 2025-07-15, 2025-07-16
| zone | A corr | A MAE | B corr | B MAE | ΔcorrN | eve MAE A→B |
|---|---|---|---|---|---|---|
| **NL** | 0.728 | 17.08 | **0.816** | **14.43** | **+0.088** | 29.4→26.3 (−10.5%) |
| BE | 0.821 | 13.36 | 0.824 | 13.32 | +0.003 | 22.4→21.4 |
| DE_LU | 0.911 | 10.79 | 0.911 | 10.79 | 0.000 | 16.2→16.2 |
| DK1 | 0.906 | 10.85 | 0.906 | 10.85 | 0.000 | 13.4→13.4 |
| NO2 | 0.623 | 11.22 | 0.675 | 10.88 | +0.052 | 6.1→6.1 |
| FR | 0.827 | 16.56 | 0.827 | 16.57 | 0.000 | 24.0→24.0 |

Summer is a **strong, clean NL win**: corr +0.088, MAE −15.5%, evening MAE −10.5%
and evening bias −29.4→−26.3 (toward zero). Neighbor safety fully satisfied:
DE_LU/DK1/FR essentially identical; BE and NO2 *improved* (beneficial spillover,
same direction, so not a regression). No zone regressed beyond the ±0.02/±1.0 band.

The pilot *looked* like a clean summer win (NL corr +0.088, MAE −15.5%, neighbors
safe). **This did not survive a blind, larger window.**

### 5b. Wider confirm (BLIND 8 days/season) — the decisive result

Days chosen purely by calendar (1st & 15th of Nov–Feb winter, May–Aug summer),
**before any scoring**, so selection is outcome-blind. 2025-12-15 returned a
degenerate 1-hour clear (source-data gap in the extract) and is excluded blind to
its score ⇒ **7 winter + 8 summer paired days**, 30 clears, no crashes. Same
config, extract read-only, HiGHS, save_to_db=false. Scorer `score_final.jl`
(pairs A/B on the same days; per-day + season aggregate). EVE = UTC h17–19.

**NL per-day (Δcorr = B−A) — genuinely mixed, no consistent gain:**
| winter day | Δcorr | ΔMAE% | eveMAE% | | summer day | Δcorr | ΔMAE% | eveMAE% |
|---|---|---|---|---|---|---|---|---|
| 2025-11-01 | +0.033 | +0.4 | −37.1 | | 2025-05-01 | +0.024 | −2.0 | −8.0 |
| 2025-11-15 | +0.145 | +14.4 | +1.8 | | 2025-05-15 | +0.005 | −9.1 | 0.0 |
| 2025-12-01 | −0.063 | +25.0 | +21.1 | | 2025-06-01 | −0.014 | +1.7 | 0.0 |
| 2026-01-01 | −0.101 | +30.2 | 0.0 | | 2025-06-15 | +0.002 | +0.8 | 0.0 |
| 2026-01-15 | +0.035 | −4.7 | −11.0 | | 2025-07-01 | −0.030 | −1.3 | 0.0 |
| 2026-02-01 | −0.012 | +1.3 | +3.8 | | 2025-07-15 | +0.037 | −13.5 | −7.1 |
| 2026-02-15 | −0.166 | +13.6 | −11.3 | | 2025-08-01 | +0.065 | −8.9 | −4.0 |
| | | | | | 2025-08-15 | +0.009 | −16.4 | −5.0 |

Winter: 3 up / 4 down on corr, MAE worse on 5 of 7. Summer: near-zero (largest
+0.065), MAE mostly slightly better.

**Season aggregates (all zones), Arm A → Arm B:**
| | NL | BE | DE_LU | DK1 | NO2 | FR |
|---|---|---|---|---|---|---|
| **WINTER** Δcorr | **+0.036** | +0.022 | −0.001 | −0.001 | +0.015 | **−0.189** |
| WINTER ΔMAE% | **+11.0** | −1.7 | +0.5 | +1.8 | −4.5 | +9.4 |
| WINTER eveMAE% | −2.7 | −1.2 | −0.9 | +0.5 | −0.5 | 0.0 |
| **SUMMER** Δcorr | **−0.001** | −0.002 | +0.001 | +0.001 | +0.001 | +0.000 |
| SUMMER ΔMAE% | −4.0 | −1.2 | +0.3 | −0.4 | −0.4 | −0.1 |
| SUMMER eveMAE% | −1.5 | −0.7 | −0.6 | −0.8 | −0.9 | −0.0 |

**Neighbor coupled swings are large and bidirectional (per-day winter):** FR
2025-11-01 corr 0.741→0.144 (Δ−0.597, MAE +9.4), FR 2026-01-01 Δ−0.155 (MAE +7.1);
but BE 2025-12-01 +0.730 and NO2 2025-12-01 +0.556 (both on near-flat low-variance
days where corr is unstable). DE_LU is well-insulated (≤0.027). This is the cv18
signature: an NL-local book perturbs the coupled winter footprint non-locally and
unpredictably.

### Verdict: **NO-SHIP**

Against the pre-registered gate, the wider blind confirm fails on **every** prong:
1. **Evening MAE −≥5% in both seasons** — NOT met (winter −2.7%, summer −1.5%).
2. **NL corr non-decreasing in both** — summer −0.001 (flat/down); winter +0.036
   but with **MAE +11% worse** (the corr rise is not a genuine fit improvement).
3. **Material NL move** — absent (summer flat; winter corr-up/MAE-worse).
4. **Neighbor safety (±0.02 corr / ±1.0 MAE)** — **BREACHED**: FR winter corr
   −0.189, MAE +2.18, on ≥2 real winter days — the cv18 non-local coupled-leakage
   failure mode.

The favorable pilot was a small-sample artifact. **The BritNed NL↔GB BoundaryBook
as specified does NOT materially fix NL and harms FR in winter — NO-SHIP.**

**What this does *not* refute** (and where NL's fix actually lives): the residual
diagnosis (§1–2) stands — NL is a shape problem whose dominant mass is (A) the
*systemic footprint-wide* evening under-pricing (NL/BE/DE_LU/DK1 all ~−26) and
(B) the *midday negative-price* gap the merit book cannot express (18% of settled
midday hours negative, model never negative). Neither is an NL-only boundary
lever; both are footprint-wide *form* problems. The honest next step for NL is a
peak-scarcity-form redesign and a negative/export-absorption pricing capability
validated on the coupled footprint — **not** a per-border book. GB coupling is a
real but bounded aggravator of NL's worst evening hours (§2A), not the fix.
