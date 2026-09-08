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

_Results appended when the arm completes._

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
