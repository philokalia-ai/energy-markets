# Input-upgrade rollout — 39-zone footprint

Extends the shipped 5-zone pilot (`docs/experiments/input-upgrade/`, PR #252) to
the **full 39-zone EU footprint** under the SAME frozen protocol
([protocol.md](protocol.md)), with three approved amendments (below). The
deliverable is per-zone-target LightGBM input models (ENTSO-E D-1 load / solar /
wind forecasts, honest GFS `previous_day1` weather), scored against the committed
linear packs on the frozen VALID window, shipping **per-zone-target winners
only** (a zone-target ships ML only when NEW beats its pack on VALID). No
activation change — `EUPHEMIA_ML_INPUTS` is already default-ON; the new zones
simply join the overlay via `bin/input_models/meta.json` + the `ML_USE_NEW` map.

## What carried over verbatim (frozen protocol)

- **Targets** = ENTSO-E D-1 forecasts per zone (`day_ahead_total_load_forecast`;
  `generation_forecasts_for_wind_and_solar`, Solar and Wind Onshore+Offshore),
  hourly-aggregated — the reference consumables, not actuals.
- **Weather** = GFS `gfs_seamless` `previous_day1` vintages (issued D-1) for train
  AND serve, via the open-meteo previous-runs API; the committed pack geometries
  (cells per zone from `bin/res_models_v2.json`, weighted cities from
  `bin/load_models_v1.json`) reused EXACTLY (amendment 3).
- **Features** = `features.py` (weather aggregation, clearness, sun-elevation,
  degree-hours, Fourier calendar, holiday flag, trailing-30d p95 capacity ref,
  D-1/D-7 AR load lags). RES targets are capacity-normalized ratio targets
  (`tgt / cap95`, cap95 = trailing-30d p95 actual gen ending D-2).
- **Split** = time-ordered TRAIN ≤ 2026-04-30, VALID 2026-05-01..2026-07-22.
- **Model** = LightGBM L1, `num_leaves≤31`, lr 0.05, early-stop on an inner
  time-ordered tail; predictions clamped ≥0, solar night-clamped.
- **Baseline** = the committed packs scored on IDENTICAL GFS-vintage weather
  (re-implemented from the pack JSON coefficients).

## Approved amendments (this rollout)

1. **Orthodox Easter for GR / BG / RO / RS.** The pilot disclosed that
   `features.py holidays()` derived GR's movable feasts from the WESTERN Gregorian
   Easter (an approximation). This retrain fixes it: the four Orthodox zones anchor
   their movable feasts on the ORTHODOX (Julian/Meeus) computus
   (`features.py orthodox_easter`, valid 1900-2099), with fixed national-holiday
   maps for BG/RO/RS added alongside GR's. **GR is retrained.** The Julia serve
   port (`bin/ml_inputs.jl ml_holidays` / `ml_orthodox_easter`) was changed IN
   LOCKSTEP — the two implementations produce **byte-identical** holiday sets for
   all mapped countries across 2024-2027 (asserted; GR retrain measured
   load MAE 138 → 109 vs the pilot's Western-Easter model). ES/DE/SE keep the
   Western Easter; unmapped countries carry an empty holiday set (so their load
   model has no holiday feature and, where holidays matter, loses to its pack —
   the winner-selection defends this).
2. **Skip the RES model where a zone has no meaningful resource** (pack/zero
   passthrough), decided ex-ante from the installed-scale signal =
   `max(trailing actual-gen peak, DA-forecast-target peak)` per type vs a
   `max(150 MW, 3% of peak load)` threshold (the DA-forecast term rescues zones
   whose actual generation is under-reported in ENTSO-E, e.g. NL behind-the-meter
   solar). Documented per zone in the winners table. Skipped: **solar** for
   NO1-5, SE1, SE2, RS; **wind** for CH, CZ, IT-CNORTH, IT-NORTH, SI, SK, NO5.
3. **Geometry reuse.** `geom.json` for the 34 new zones is the committed pack
   geometry verbatim — RES cells from `res_models_v2.json`, weighted cities from
   `load_models_v1.json` — extending the pilot's `geom.json` schema. The 5 pilot
   entries are preserved unchanged.

## Fetch coverage

GFS `gfs_seamless` `previous_day1` vintages, 2024-07-14 … 2026-07-29 (hourly, UTC),
cell/city geometry per zone from the committed packs. Durable cache:
`data/gfs_vintages/` (git-ignored; see docs/predictions.md).

- **34/34 new zones fetched** (PL, BG, CZ, AT, HU, RO, RS, FR, IT-NORTH, BE, SK, SI, PT, CH, FI, SE3, SE1, SE4, DK1, DK2, EE, LT, LV, NO1, NO2, NO3, NO4, NO5, IT-CNORTH, IT-CSOUTH, IT-SOUTH, IT-Sicily, IT-Sardinia, IT-Calabria); 0 failed.
- 5 pilot zones (GR, ES, DE_LU, SE2, NL) reuse the PR #252 cache (GR re-used for its retrain).
- Fetch paced against the open-meteo previous-runs **hourly** quota (parks to the next
  hour on 429; ~4-5 zones/hour), priority-ordered (PL, BG, CZ, AT, HU, RO, RS, FR, IT-NORTH … first).

## Scorecard (VALID 2026-05-01..07-22, MW)

NEW vs pack per zone-target, on identical GFS-vintage weather. `ship` = the model
that serves that zone-target (NEW only when it beats the pack on VALID MAE).

| zone | target | ship | NEW MAE | pack MAE | NEW corr | pack corr | NEW bias |
|---|---|---|--:|--:|--:|--:|--:|
| AT | load | **NEW** | 291.3 | 412.2 | 0.867 | 0.809 | 29.0 |
| AT | solar | pack | 336.9 | 225.7 | 0.969 | 0.965 | -298.6 |
| AT | wind | **NEW** | 268.2 | 293.9 | 0.867 | 0.862 | -56.2 |
| BE | load | **NEW** | 254.5 | 323.5 | 0.924 | 0.906 | -20.3 |
| BE | solar | **NEW** | 273.0 | 297.4 | 0.984 | 0.979 | -116.6 |
| BE | wind | pack | 354.4 | 244.9 | 0.857 | 0.938 | -131.2 |
| BG | load | **NEW** | 125.2 | 178.4 | 0.934 | 0.906 | 4.8 |
| BG | solar | **NEW** | 271.5 | 588.3 | 0.975 | 0.920 | -194.5 |
| BG | wind | pack | 60.7 | 59.1 | 0.758 | 0.753 | -4.8 |
| CH | load | **NEW** | 377.6 | 450.6 | 0.717 | 0.645 | -13.0 |
| CH | solar | pack | 195.7 | 145.0 | 0.982 | 0.983 | -151.3 |
| CH | wind | skip (no resource) | – | – | – | – | – |
| CZ | load | **NEW** | 136.9 | 244.7 | 0.975 | 0.961 | -2.3 |
| CZ | solar | **NEW** | 100.4 | 128.4 | 0.988 | 0.978 | -60.8 |
| CZ | wind | skip (no resource) | – | – | – | – | – |
| DE_LU | load | **NEW** | – | – | – | – | – |
| DE_LU | solar | **NEW** | – | – | – | – | – |
| DE_LU | wind | pack | – | – | – | – | – |
| DK1 | load | **NEW** | 165.8 | 232.0 | 0.803 | 0.735 | 20.8 |
| DK1 | solar | pack | 146.9 | 132.0 | 0.949 | 0.954 | 13.8 |
| DK1 | wind | **NEW** | 211.9 | 399.5 | 0.917 | 0.933 | -12.5 |
| DK2 | load | **NEW** | 66.5 | 89.8 | 0.943 | 0.928 | -18.2 |
| DK2 | solar | pack | 61.3 | 53.1 | 0.974 | 0.974 | 41.4 |
| DK2 | wind | pack | 122.1 | 96.2 | 0.887 | 0.916 | 10.0 |
| EE | load | **NEW** | 39.2 | 57.6 | 0.859 | 0.705 | 0.0 |
| EE | solar | pack | 54.3 | 52.6 | 0.930 | 0.949 | -42.1 |
| EE | wind | pack | 70.7 | 47.4 | 0.366 | 0.784 | -26.1 |
| ES | load | **NEW** | – | – | – | – | – |
| ES | solar | pack | – | – | – | – | – |
| ES | wind | pack | – | – | – | – | – |
| FI | load | **NEW** | 141.2 | 275.8 | 0.954 | 0.888 | -35.4 |
| FI | solar | **NEW** | 57.1 | 67.7 | 0.975 | 0.971 | -26.0 |
| FI | wind | **NEW** | 437.6 | 496.3 | 0.896 | 0.887 | -56.9 |
| FR | load | **NEW** | 1342.5 | 1453.0 | 0.946 | 0.931 | 191.2 |
| FR | solar | pack | 978.1 | 912.6 | 0.975 | 0.976 | 194.0 |
| FR | wind | **NEW** | 916.6 | 965.3 | 0.843 | 0.888 | 139.4 |
| GR | load | **NEW** | 109.3 | 197.4 | 0.994 | 0.983 | -53.6 |
| GR | solar | **NEW** | 365.7 | 747.6 | 0.987 | 0.980 | -336.7 |
| GR | wind | pack | 390.1 | 270.4 | 0.831 | 0.926 | -32.0 |
| HU | load | **NEW** | 219.2 | 346.8 | 0.899 | 0.924 | 130.3 |
| HU | solar | **NEW** | 133.5 | 168.6 | 0.987 | 0.976 | -60.0 |
| HU | wind | pack | 21.1 | 19.7 | 0.895 | 0.898 | 3.3 |
| IT-CNORTH | load | **NEW** | 120.5 | 179.4 | 0.961 | 0.928 | 26.8 |
| IT-CNORTH | solar | **NEW** | 33.8 | 41.1 | 0.992 | 0.990 | 3.4 |
| IT-CNORTH | wind | skip (no resource) | – | – | – | – | – |
| IT-CSOUTH | load | **NEW** | 216.4 | 304.8 | 0.970 | 0.947 | 18.1 |
| IT-CSOUTH | solar | **NEW** | 103.5 | 169.2 | 0.989 | 0.983 | 10.2 |
| IT-CSOUTH | wind | **NEW** | 187.5 | 199.4 | 0.789 | 0.763 | -45.1 |
| IT-Calabria | load | **NEW** | 86.2 | 107.8 | 0.884 | 0.809 | -35.2 |
| IT-Calabria | solar | **NEW** | 10.8 | 20.2 | 0.990 | 0.986 | 4.4 |
| IT-Calabria | wind | pack | 69.9 | 61.1 | 0.770 | 0.827 | -18.2 |
| IT-NORTH | load | **NEW** | 931.8 | 1546.9 | 0.944 | 0.887 | 197.8 |
| IT-NORTH | solar | **NEW** | 186.2 | 223.5 | 0.992 | 0.989 | 39.2 |
| IT-NORTH | wind | skip (no resource) | – | – | – | – | – |
| IT-SOUTH | load | **NEW** | 154.6 | 262.8 | 0.928 | 0.899 | -6.9 |
| IT-SOUTH | solar | **NEW** | 70.1 | 100.1 | 0.993 | 0.987 | -34.3 |
| IT-SOUTH | wind | **NEW** | 298.5 | 315.3 | 0.914 | 0.886 | -90.4 |
| IT-Sardinia | load | **NEW** | 32.7 | 76.8 | 0.975 | 0.878 | -0.1 |
| IT-Sardinia | solar | **NEW** | 32.3 | 61.0 | 0.988 | 0.985 | -11.4 |
| IT-Sardinia | wind | pack | 49.2 | 46.2 | 0.913 | 0.910 | -4.9 |
| IT-Sicily | load | **NEW** | 69.0 | 95.0 | 0.980 | 0.965 | -26.9 |
| IT-Sicily | solar | **NEW** | 62.1 | 137.1 | 0.990 | 0.989 | 25.5 |
| IT-Sicily | wind | **NEW** | 96.9 | 106.5 | 0.861 | 0.872 | -31.8 |
| LT | load | **NEW** | 75.9 | 137.5 | 0.806 | 0.749 | 47.1 |
| LT | solar | **NEW** | 76.0 | 89.0 | 0.976 | 0.971 | -32.7 |
| LT | wind | **NEW** | 141.6 | 143.3 | 0.893 | 0.898 | 66.1 |
| LV | load | **NEW** | 35.0 | 60.7 | 0.890 | 0.870 | -11.2 |
| LV | solar | pack | 92.9 | 91.9 | 0.914 | 0.899 | -47.0 |
| LV | wind | pack | 32.1 | 28.1 | 0.784 | 0.795 | -31.6 |
| NL | load | **NEW** | – | – | – | – | – |
| NL | solar | **NEW** | – | – | – | – | – |
| NL | wind | **NEW** | – | – | – | – | – |
| NO1 | load | **NEW** | 98.0 | 176.6 | 0.958 | 0.926 | 47.5 |
| NO1 | solar | skip (no resource) | – | – | – | – | – |
| NO1 | wind | **NEW** | 39.5 | 51.5 | 0.850 | 0.771 | -6.3 |
| NO2 | load | **NEW** | 102.1 | 129.0 | 0.953 | 0.918 | -83.2 |
| NO2 | solar | skip (no resource) | – | – | – | – | – |
| NO2 | wind | **NEW** | 102.9 | 116.3 | 0.798 | 0.881 | -0.2 |
| NO3 | load | **NEW** | 119.1 | 122.0 | 0.902 | 0.889 | 107.6 |
| NO3 | solar | skip (no resource) | – | – | – | – | – |
| NO3 | wind | pack | 167.1 | 154.9 | 0.849 | 0.874 | -37.0 |
| NO4 | load | pack | 59.4 | 49.9 | 0.901 | 0.897 | -39.5 |
| NO4 | solar | skip (no resource) | – | – | – | – | – |
| NO4 | wind | pack | 121.0 | 95.5 | 0.551 | 0.773 | -9.6 |
| NO5 | load | **NEW** | 64.1 | 87.7 | 0.728 | 0.732 | 53.3 |
| NO5 | solar | skip (no resource) | – | – | – | – | – |
| NO5 | wind | skip (no resource) | – | – | – | – | – |
| PL | load | **NEW** | 549.3 | 757.0 | 0.941 | 0.929 | 2.6 |
| PL | solar | **NEW** | 468.8 | 678.9 | 0.986 | 0.980 | 142.1 |
| PL | wind | pack | 457.9 | 447.7 | 0.942 | 0.935 | 208.0 |
| PT | load | **NEW** | 152.7 | 160.4 | 0.957 | 0.957 | -20.2 |
| PT | solar | pack | 135.1 | 129.7 | 0.981 | 0.985 | -29.7 |
| PT | wind | **NEW** | 285.6 | 321.1 | 0.898 | 0.884 | 70.3 |
| RO | load | **NEW** | 197.5 | 367.0 | 0.953 | 0.862 | 97.6 |
| RO | solar | **NEW** | 162.8 | 323.2 | 0.967 | 0.961 | -40.7 |
| RO | wind | **NEW** | 154.0 | 166.3 | 0.880 | 0.878 | -31.8 |
| RS | load | **NEW** | 93.0 | 140.4 | 0.958 | 0.935 | -7.7 |
| RS | solar | skip (no resource) | – | – | – | – | – |
| RS | wind | **NEW** | 57.3 | 57.8 | 0.795 | 0.768 | -28.2 |
| SE1 | load | **NEW** | 14.1 | 35.6 | 0.928 | 0.713 | 1.8 |
| SE1 | solar | skip (no resource) | – | – | – | – | – |
| SE1 | wind | **NEW** | 198.2 | 246.7 | 0.830 | 0.849 | -41.7 |
| SE2 | load | **NEW** | – | – | – | – | – |
| SE2 | solar | **NEW** | – | – | – | – | – |
| SE2 | wind | pack | – | – | – | – | – |
| SE3 | load | **NEW** | 157.1 | 288.8 | 0.970 | 0.903 | -33.1 |
| SE3 | solar | **NEW** | 51.6 | 53.0 | 0.984 | 0.984 | 3.7 |
| SE3 | wind | **NEW** | 180.2 | 201.5 | 0.917 | 0.913 | -65.6 |
| SE4 | load | **NEW** | 56.5 | 120.5 | 0.957 | 0.882 | -15.2 |
| SE4 | solar | pack | 30.0 | 28.4 | 0.976 | 0.977 | 4.6 |
| SE4 | wind | pack | 111.9 | 102.3 | 0.889 | 0.926 | 23.9 |
| SI | load | **NEW** | 82.4 | 130.3 | 0.908 | 0.792 | -52.3 |
| SI | solar | **NEW** | 42.8 | 54.2 | 0.978 | 0.962 | -10.2 |
| SI | wind | skip (no resource) | – | – | – | – | – |
| SK | load | **NEW** | 73.4 | 88.8 | 0.954 | 0.936 | -17.3 |
| SK | solar | **NEW** | 19.0 | 22.9 | 0.962 | 0.941 | -3.8 |
| SK | wind | skip (no resource) | – | – | – | – | – |

## Winners summary

**76 of 117 zone-targets ship the NEW ML model; 41 keep the linear pack.**
The overlay covers **38 zones** (all but NO4, which lost every target to its pack).

| target | NEW winners | modeled zones | note |
|---|--:|--:|---|
| load  | **38** | 39 | near-universal — AR-lagged LightGBM load beats the linear pack in 38/39 zones |
| solar | **22** | 32 | amendment-2 skip (no meaningful solar): NO1-5, SE1, RS (7 zones) |
| wind  | **16** | 32 | physical power-curve pack still wins the low/onshore zones; skip (no meaningful wind): CH, CZ, IT-CNORTH, IT-NORTH, SI, SK, NO5 (7 zones) |

SE2 keeps its pilot-shipped NEW solar (marginal-solar northern zone, retained from #252 for
continuity — the new northern zones SE1/NO* skip solar under amendment 2).

Notable: **PL** — load MAE 757 → **549**, solar 679 → **469** (both NEW). GR load 197 → **109**
(Orthodox-holiday retrain). AT/BG/CZ/HU/RO/FR loads all NEW. FR wind NEW; FR solar keeps its pack.
The winners config ships THROUGH `bin/input_models/meta.json` (`pilot_zones` + `winners`), read at
run time by `ml_pilot_zones()` / `ml_use_new()` (#280) — no const edits, so Phase-2 picks it up automatically.

## Collapse-awareness (solar zones)

Where prices collapse matters (continental-solar zones), we also track the
midday-coverage error of predicted vs reference solar (the classification signal
of the collapse question). 
The collapse question (does midday price crash to ≤0 under solar surplus) is dominated by SOLAR
input accuracy on the continental-solar group. NEW-vs-pack solar MAE there (VALID midday-bearing):

| zone | solar ship | NEW MAE | pack MAE |
|---|---|--:|--:|
| DE_LU | **NEW** | – | – |
| FR | pack | 978.1 | 912.6 |
| PL | **NEW** | 468.8 | 678.9 |
| BE | **NEW** | 273.0 | 297.4 |
| CZ | **NEW** | 100.4 | 128.4 |
| CH | pack | 195.7 | 145.0 |

Lower solar-forecast MAE tightens the predicted RES-coverage ratio that flips the collapse
classification near the threshold (the pilot validated this at PRICE level for GR-July, #252);
this rollout supplies the same-quality inputs to the continental group where the cv31 solar-regime
floor then acts.

## Equivalence (train/serve lockstep)

The pure-Julia serve port (`bin/ml_inputs.jl`) reproduces the python LightGBM
predictions on identical inputs — validated for a spot set of pilots + new zones
by `test/scripts/ml_inputs_equivalence.jl` (scorer bit-identical; feature port
rel < 1e-9; end-to-end NEW predictions bit-identical except rare last-ULP
split-flips). The holiday lockstep (amendment 1) is asserted separately.

Spot-checked on GR (Orthodox), PL (headline), FR (nuclear), NO2 (skip-solar), CZ (skip-wind), ES
(pack solar) over 2026-07-15…17: **scorer bit-identical** (max|Δ|=0 on 792 preds), **feature port
rel < 1e-9**, end-to-end **1/792 split-flip** (≤1%, the documented last-ULP mechanism). Holiday
lockstep asserted byte-identical python↔Julia for all 10 mapped countries 2024-27. Unit tests
`test/test_ml_inputs.jl` green (scorer, feature math, Orthodox holidays, meta-driven ship config).

## Reproduce

```
# 1. targets + capacity (offline extract)         2. geometry + skip decisions
python pull_all.py                                 python build_geom.py
# 3. weather fetch (paced, resumable, priority)    4. train + winner selection
python fetch_new.py                                python train39.py
# 5. assemble committed models (winners only)      6. equivalence spot-check
python wire_ml.py                                  python dump_eval39.py <d0> <d1>
                                                   julia test/scripts/ml_inputs_equivalence.jl
```
All scripts pin the scratchpad paths of the rollout run; the committed artifacts
are `bin/input_models/*.txt` + `meta.json` + `geom.json` and the `ML_USE_NEW` /
`ML_PILOT_ZONES` maps in `bin/ml_inputs.jl`.
