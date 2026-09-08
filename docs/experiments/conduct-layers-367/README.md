# Competitive opportunity cost vs conduct assumptions (issue #367)

**Status.** Steps 1–2 (registry + layer classification) and the ablation
switch are on `feat/conduct-layers-367` (rebased on the #370 fix so the
ablation arm pairs with a deterministic base). Step 4's ablation arm is queued
(§3); steps 3, 5 and 6 are scoped in §4.

## 1. The registry (machine-readable, emitted with the methodology export)

`PROVENANCE` in `src/merit_order/zone_profiles.jl` already carried, for every
form constant and every `ZoneProfile` field, whether it is `observed` (a data
value that exists before the gate) or `declared` (a chosen market
characteristic), its source and the code version. Every entry now also carries:

- `layer` — `engineering` (cost, availability, market rule, physical form),
  `opportunity` (a competitive seller's indifference price: water, nuclear,
  imports, must-run economics), or `conduct` (a behavioural perturbation not
  implied by competitive opportunity cost);
- `price_informed` — whether observed prices took part in selecting the value
  or the mechanism (an OOS-validated calibration is `true`; a market rule, a
  data feed or a physically fixed form is `false`).

`test/test_book_methodology_export.jl` asserts both on every key. The
classification of the 49 keys:

| kind / layer / price-informed | keys |
|---|---|
| observed · engineering · no (9) | ttf, eua, fleet_p95_installed, reservoir_fill, reservoir_dryness, flow_climatology, boundary_capability, import_backstop_qty, input_corrections |
| declared · engineering · no (3) | PRICE_CAP, FLEET_COMPLETION, FLEET_TRUTHING |
| declared · engineering · yes (8) | AVAILABILITY_FACTOR, DERATE_HEADROOM, MUST_RUN_SRMC_THRESHOLD, BACKSTOP_WEEKS, DEMAND_ELASTIC_SHARE/PRICE, fleet_truth_mode, scarcity_import_credit |
| declared · opportunity · yes (22) | water_value_base/span, WATER_VALUE_DRY_BOOST, hydro_model, seasonal_drawdown, wet_adjusted_drawdown, spill_surplus_dryness, opportunity_anchor, anchor_share, nuclear_avail_share_lo/hi, nuclear_bid_ref_ceiling, nuclear_srmc_floor, NUCLEAR_AVAIL_REF/FLOOR, MUST_RUN_PRICE_FACTOR, DEEP_SURPLUS_FLOOR_EUR, import_backstop, BACKSTOP_PRICE_MULT, ref_priced_exports, boundary_book, thermal_srmc_multiplier |
| **declared · conduct · yes (7)** | **TRANCHES, PEAK_EXPONENT, tranche_grading, peak_kappa, scarcity_kappa, scarcity_threshold, backstop_scarcity_credit** |

So the honest sentence about the benchmark is: 40 of 49 characteristics are
declared, 37 of those were selected with prices in the loop (out of sample,
never fitted), and 7 of them — the upper-tranche ladder and the
scarcity/peak markup — are conduct assumptions, not competitive opportunity
costs. The residual against the full ladder is therefore "price minus a
benchmark that already contains a declared conduct layer", and the premium
above the *competitive* layer is only identified once that layer is ablated.

## 2. The ablation switch

`EUPHEMIA_CONDUCT_LAYER=off` (in `create_merit_order_book`): every tranche at
1.0 × SRMC (`tranches = [(1.0, 1.0)]`) and `scarcity ≡ 1` (no
`scarcity_kappa`, `peak_kappa` terms). Engineering and opportunity layers
untouched. Inert unless set (guarded: DE_LU/GR books bit-identical with the
variable unset). It is a measurement arm: **zero conduct is an ablation, not
the true competitive price** — the competitive layer itself carries the
uncertainty of every `opportunity` entry above.

## 3. Ablation arm (queued)

`scripts/ab_arm.jl`: the same 52 Wednesdays 2025-09-03..2026-08-26 and the
same code as the #370 A/B's interval arm (`ab370_intervals`, conduct ON), with
the conduct layer OFF → label `ab367_noconduct`. Scored with
`scripts/score_ab.py ab370_intervals ab367_noconduct`: per zone MAE / bias /
corr against settled, and — the number the issue asks for — the **premium**:
settled minus the no-conduct benchmark, by zone and hour, its duration and
the energy it covers, next to the residual against the full ladder.

### Result (2026-09-08; `output/ab_score.txt`)

52 paired Wednesdays, 38 zones, 47,300 paired zone-hours. Removing the
conduct layer moves 76 % of cells (mean |Δ| 11.3):

| | full ladder (`ab370_intervals`) | **competitive layer only** (`ab367_noconduct`) |
|---|---|---|
| footprint MAE / energy-weighted | 26.73 / 26.02 | 29.16 / 28.76 |
| bias | −9.07 | −14.97 |
| corr | 0.767 | 0.739 |

**Where the conduct layer carries the model:** HU +6.8 MAE without it,
PL +5.6, SI +5.5, AT +5.4, SK +5.3, CZ +4.6, LT +4.3, RO +4.1, LV +3.9,
BG +3.5, GR/DK2/FR/DE_LU +3.0, RS +2.9. **Where it hurts:** ES −1.10 and
PT −0.76 (bias +7.8 → −0.6 and +6.5 → −1.0: the ladder over-prices Iberia,
whose competitive layer is already centred); BE +0.4 MAE but corr
0.658 → 0.575. The Nordics sit in between (+0.6..+1.9 MAE, bias still
+12..+16 in SE1/SE2/NO4 without any conduct — a water-value level problem,
the #366 finding, not conduct).

**The premium over the competitive benchmark** (settled − no-conduct,
energy-weighted mean €/MWh; share of hours above 10 €/MWh) — the number the
issue asks for, next to the residual over the full ladder:

| zone | premium (ew) | hours > 10 | residual vs full ladder |
|---|---|---|---|
| HU | **40.0** | 70 % | 28.3 |
| LT / LV | 36.6 / 35.3 | 65 % | 27.3 / 28.6 |
| AT / SI | 32.0 / 31.7 | 75 % / 70 % | 24.6 / 24.3 |
| SK | 30.1 | 63 % | 21.9 |
| RO / PL | 28.4 / 26.2 | 60 % / 56 % | 15.5 / 18.1 |
| NO5 | 24.6 | 76 % | 22.2 |
| GR / BG | 23.5 / 23.5 | 59 % | 9.9 / 13.5 |
| IT-NORTH .. IT-SOUTH | 18–23 | 57–68 % | 9–14 |
| CZ / NO1 / DK2 | 21.2 / 21.2 / 21.0 | 56–70 % | 15–20 |
| DE_LU / NL | 15.3 / 13.6 | 45 % / 44 % | 8.2 / 8.7 |
| BE / FR | 6.5 / 4.7 | 37 % / 41 % | −0.7 / −3.8 |
| ES / PT | 1.2 / 0.6 | 38 % / 40 % | −7.8 / −6.5 |
| FI / NO4 / SE1 / SE2 | −3.5 / −10.4 / −12.1 / −13.4 | 15–27 % | −8..−17 |

By hour of day (footprint mean): 3–6 €/MWh overnight and at midday, 24 at
05–06 UTC, **32–43 at 16–18 UTC**, 29 at 19 — the evening belt of the
2026-09 review, now expressed as a premium over a benchmark that contains
no conduct assumption.

**Reading.** The declared conduct layer is not decoration: on the coupled
footprint it explains 2.4 €/MWh of MAE and 6 of bias, almost all of it in
the Core satellites and the Baltics in the evening. Its *absence* leaves an
evening premium of 25–40 €/MWh in HU/AT/SI/SK/RO/PL/Baltics that the
competitive layers (fuel, availability, water, nuclear, imports) do not
produce — and a competitive layer that already over-prices Iberia and the
wet Nordics, where the ladder should not fire at all. Two consequences for
the claim: (i) the "premium" is identified against the no-conduct benchmark
only up to the uncertainty of the opportunity layer (the step-3 scenario
envelope, not run here); (ii) the same ladder is applied to zones where the
premium is 40 and zones where it is 1 — a zone-invariant conduct prior is
the wrong shape, and the honest benchmark reports the premium per zone
rather than absorbing it into a shared parameter.

## 4. What remains (steps 3, 5, 6)

- **Coherent scenario sets (step 3).** Low / central / high competitive
  assumptions are joint draws over the `opportunity` entries (water-value
  base/span and dry boost, anchor shares, backstop price, nuclear floors),
  specified before scoring and stored as a configuration hash; the
  `ZoneScenario` hooks already carry per-zone field overrides, so a scenario
  set is three labelled runs. Not run in this phase — a budgeted follow-up
  once the ablation arm sizes the conduct layer.
- **Development vs evaluation (step 5).** The ledger names, per code
  version, the days that informed selection (Set A / Set B, the 52 Wednesdays,
  the wet-winter Sundays). A frozen future window and its decision criteria
  belong in a prereg file before its outcomes are observed; the working
  agreement retired holdouts as a *rule* but nothing prevents declaring one.
- **Claims (step 6).** `web/models.html` and the methodology page should show
  the layer badge next to the observed/declared badge (the export already
  carries it), and describe persistent differences as unexplained premiums
  over a stated benchmark rather than conduct.
