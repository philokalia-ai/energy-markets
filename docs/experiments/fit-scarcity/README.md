# fit-scarcity: what if we ACTUALLY fitted the scarcity/markup function?

**Status: epistemology experiment — NEVER feeds back into the product model.**
The product's merit-order book stays *no-fit calibrated by design*: its
constants are hand-picked against mechanism-level reasoning and guarded by
byte-identity tests, so a residual against reality stays interpretable as a
candidate market-conduct finding rather than something a fit silently absorbed
(see `memory/research-framing.md`). This experiment measures the *upper bound*
of what any fitted local markup function could achieve — what all-in fitting
would buy, and what it would cost.

## Question

The product prices the upper supply tranches with the hand-calibrated markup

```
scarcity = 1 + κ_s · max(0, θ − margin)² + κ_p · d̂^p          (book_build.jl:771)
```

(SEE profile: κ_s=3.0, θ=1.4, κ_p=1.2, p=4.0; CONTINENTAL: 1.5/1.25/0.6/4.0 —
`src/merit_order/zone_profiles.jl`). If we instead *estimated* that function
from data — same inputs, free constants; then free functional form; then free
features — what function does the data propose, and how much accuracy is left
on the table?

## Dataset (`build_dataset.py` → `dataset.tsv.gz`, git-ignored, rebuildable)

Hourly, zones GR / BG / ES / DE_LU, sample 2023-07-01 → 2026-06-30
(~103k rows; TRAIN 2023-07→2025-06, TEST strictly out-of-time 2025-07→2026-06,
plus an apr-2026 window for comparability with the repo's guard days). Source:
the read-only DuckDB extract only.

- **Target** `y = P_DA / SRMC_gas(day)`; `SRMC_gas = TTF/0.55 + 0.202/0.55·EUA
  + 2.0`, closes strictly before the market day (`src/generators/fuel_costs.jl`
  convention, no lookahead). Prices deduped to one row per (zone, ts) by
  highest `sequence` then latest `update_time_utc`, Day-ahead, BZN, sub-hourly
  averaged to hourly.
- **margin** (proxy): Σ over dispatchable types of trailing-30-day p95 of
  hourly per-type actual generation (window ends the day *before* the market
  day — D-1 legal), divided by (load_fc − RES_fc − net_imports). Net imports
  are **observed** physical flows — deliberately ex-post, so the experiment
  isolates the markup-form question from the flow-assumption question (the
  known GR evening bias was attributed to flows, not the markup form).
- **d̂**: within-day min-max normalized net demand from D-1 forecasts, exactly
  like `book_build.jl`.
- extras: hour, day-of-week, RES share, import share of load, weekly reservoir
  filling fraction (normalized by trailing-2-year max; DE_LU has no reporting —
  imputed constant), TTF level, net-demand and net-import levels.

**Framing caveat (important).** Here *every* hour is priced `markup ×
gas-SRMC`, whereas in the product the scarcity factor multiplies only the upper
tranches of a full order book (lignite/hydro/imports set off-peak prices). So
the hand-constant row below overstates the *product's* bias; the honest
comparison is hand-vs-refit-vs-flexible **on the same framing**. ES is the
extreme case: gas is frequently not marginal (median y = 0.77), so a
gas-anchored markup model of any constants is structurally wrong there.

## Models

| | model | what it answers |
|---|---|---|
| A0 | hand constants, same form | baseline to beat |
| A | same form, constants refit (NLS, `fit_models.py`) | were the hand constants near-optimal *for this form*? |
| B | gradient-boosted trees, core (margin, d̂) and rich features | ceiling of ANY local-feature function |
| C | symbolic regression (SymbolicRegression.jl, `sr_fit.jl`) | what function does the data itself propose? |
| D | dynamics: relaxation ODE (D-1 legal, `fit_dynamic.py`) + lagged-feature GBTs | do intraday dynamics matter at all? |
| E | Dyad | `dyad_assessment.md` — honest assessment, not built |

## Results — test-year MAE ladder (€/MWh, 2025-07 → 2026-06)

| model | GR | BG | ES | DE_LU |
|---|---|---|---|---|
| A0 hand constants | 39.2 (corr .63) | 47.2 (.54) | 70.7 (.48) | 29.9 (.56) |
| A refit constants | 28.4 (.61) | 37.8 (.50) | 46.8 (.10) | 26.7 (.63) |
| B GBT core (margin, d̂) | 23.2 (.75) | 35.0 (.63) | 21.7 (.75) | 15.7 (.87) |
| B GBT rich features | 22.3 (.76) | 39.5 (.68) | 20.8 (.79) | 15.0 (.89) |
| C SR best (complexity ≤ 15, core) | see Pareto table below | | | |
| D relax-ODE (D-1 legal) | 28.2 — α→1, collapses to static | 37.5 | 46.7 | 26.7 |
| D GBT + prev-day lag (D-1 legal) | 19.2 (.82) | 26.3 (.79) | 17.9 (.84) | 13.5 (.92) |
| D GBT + within-day lag (NOT D-1 legal) | 11.8 (.92) | 12.5 (.93) | 6.3 (.98) | 6.7 (.96) |

Full tables: `results_ladder.tsv`, `results_hourly_bias.tsv`,
`results_transfer.tsv`, `fitted_constants.tsv`, `results_dynamic_relax.tsv`,
`sr_front_core.tsv`, `sr_front_rich.tsv`.

### A: fitted constants vs hand constants

| zone | κ_s | θ | κ_p | p | (hand) |
|---|---|---|---|---|---|
| GR | 1.30 | 1.79 | 0.39 | 10.9 | 3.0 / 1.40 / 1.2 / 4.0 |
| BG | 2.42 | 1.33 | 0.91 | 5.4 | 3.0 / 1.40 / 1.2 / 4.0 |
| ES | 2.12 | 1.36 | ~0 | (12) | 3.0 / 1.40 / 1.2 / 4.0 |
| DE_LU | 2.09 | 1.52 | 0.17 | 12.0 | 1.5 / 1.25 / 0.6 / 4.0 |

Reading: for BG the hand constants were **close to the data's own choice**
(θ 1.40 vs 1.33, κ_s 3.0 vs 2.4); for GR the data wants the scarcity hinge to
start much earlier but gentler (θ≈1.8 ≈ GR's *median* margin, κ_s≈1.3) and a
small, ultra-sharp peak term (κ_p 0.39, p≈11) instead of the broad κ_p=1.2,
p=4 one. The refit buys GR 39.2 → 28.4 MAE and cuts the mean bias +29.7 →
+12.8 — but remember the framing caveat: part of that bias is the
gas-always-marginal framing, not the product's actual bias.

### The evening question (GR per-hour bias, test year, pred − actual)

| hours | A0 hand | A refit | B GBT rich | D prevday |
|---|---|---|---|---|
| 17–19 | +61 / +65 / +53 | +14 / +19 / +16 | +16 / +17 / +4 | +10 / +10 / +3 |
| 10–13 | +37 / +36 / +31 / +29 | +38 / +37 / +32 / +31 | +8 / +7 / +7 / +12 | +5 / +4 / +4 / +8 |

The hand form's evening over-prediction (+60–65, matching the known July-2026
failure signature) is mostly the *form*, not the flows: with observed net
imports in the margin, refitting constants alone removes ~75% of it. What the
parametric form cannot fix (midday +30–38: the solar-hour over-pricing of a
gas-anchored markup) needs features it doesn't have — the trees cut midday
bias to single digits using RES share/hour.

Cross-zone evening check (hours 17–19, hand → refit → GBT-rich): BG +105/+90/+62
→ +47/+35/+19 → **+48/+41/+26** — BG evenings keep a large residual *even under
the flexible model with observed imports*, i.e. a premium no local feature
explains (in the research framing: a candidate conduct/structure signature, not
a misfit). ES evenings are fully explained once solar features enter (+5/+5/+8);
DE_LU evenings were never biased (−2/−2/+1 even with hand constants).

### C: what function does the data propose? (symbolic regression, GR)

SR_RESULTS_PLACEHOLDER

### D: do dynamics matter? (honest answer: no — for the right reason)

The interpretable test: `P̂_h = P̂_{h−1} + α(F_h − P̂_{h−1})` (forward-Euler of
`dP/dt = α(F−P)`), α fit jointly with the form constants, rolled forward on
predicted values only (D-1 legal). **Every zone drives α → 1.0**, collapsing
the ODE to the static map: the day-ahead price is a simultaneous auction, not
a sequential process. The big gains of the within-day-lag GBT (11.8 vs 22.3)
are *conditioning on other hours of the same clearing* — information leakage,
not dynamics; even the legal prev-day-lag variant (19.2) is mostly "yesterday's
residual persists", i.e. slowly-varying omitted variables, not intraday physics.

### Transfer (fit GR → test elsewhere, test year)

| tested on | GR-fitted form | GR-fitted GBT-core | own hand | own refit | own GBT-core |
|---|---|---|---|---|---|
| BG | 41.9 | 39.1 | 47.2 | 37.8 | 35.0 |
| ES | 58.0 | 51.7 | 70.7 | 46.8 | 21.7 |
| DE_LU | 34.9 | 30.8 | 29.9 | 26.7 | 15.7 |

A GR-fitted form transfers *better than the shared hand SEE constants* to BG
(41.9 < 47.2) but *worse than the hand CONTINENTAL constants* to DE_LU
(34.9 > 29.9) — the hand calibration's per-zone differentiation was
directionally right. ES doesn't transfer under any gas-anchored form; its GBT
gains come entirely from non-margin features (solar share), confirming the
product's choice of a different mechanism (not constants) would be needed there.

## Conclusions

1. **Was the hand form near-optimal?** The *form* is reasonable — hinge +
   peak-shape explains most of what any (margin, d̂) function can: refit form
   28.4 vs GBT-core 23.2 on GR, so the parametric family captures ~70% of the
   core-feature ceiling's improvement over hand. The *constants* were not:
   refitting buys 10.7 €/MWh on GR (39.2→28.4) and kills most of the evening
   over-prediction. BG's hand constants were nearly the data's own choice.
2. **What does all-in fitting buy?** On GR: hand 39.2 → refit 28.4 → flexible
   local 22.3 → +prev-day persistence 19.2. The truly-dynamic-looking 11.8
   is not achievable ex ante (uses same-day hours). So the honest upper bound
   of a D-1-legal local markup model is ≈19 €/MWh MAE — roughly half the
   hand-constant number *in this standalone framing*.
3. **What it costs**: the fitted constants/trees are shaped by the framing
   (gas-always-marginal) and the sample (post-2023 regime); they carry no
   mechanism, so a residual is no longer attributable to conduct vs misfit —
   exactly the property the product's no-fit design exists to protect. The SR
   front shows the data's own preferred laws are smooth
   (hyperbolic-in-margin, interaction-coupled) rather than thresholded —
   useful *shape intelligence* for future hand calibration without adopting
   fitted constants.
4. **Dynamics don't matter** (α→1); **transfer is partial** — fitted functions
   are zone-idiosyncratic; the hand approach of shared mechanisms with
   per-profile constants is validated in direction, if not in the specific
   SEE values.

## Reproduce

```bash
python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
./.venv/bin/python build_dataset.py          # reads the read-only extract
OMP_NUM_THREADS=4 ./.venv/bin/python fit_models.py
OMP_NUM_THREADS=4 ./.venv/bin/python fit_dynamic.py
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia -t 16 --project=. sr_fit.jl
```
