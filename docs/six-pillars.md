# The six pillars — what this repository actually is

> Audit synthesis, chapter one of the SIX-PILLARS program. This is the corrected,
> completed statement of the mental model the owner dictated, verified against the
> code with file:line anchors. Where the dictation was imprecise it is corrected in
> place (flagged **CORRECTION**); where it was incomplete the missing machinery is
> added (flagged **ADDED**). Code version at audit: `ENERGY_PRICES_CODE_VERSION = 31`
> (`src/db/postgres_core.jl:158`).

The system is **six pillars over one clearing engine**. Two of them are *fitted*
(openly statistical, scored like any forecast); three are *constructed*
(mechanistic, no parameter tuned against the prices we score); the sixth is
*constructed with declared anchors* (out-of-EU neighbours priced on their own
fundamentals). This fit/construct wall is the whole epistemological claim of the
project — see `web/about.html` "The two layers".

| # | Pillar | Kind | Source of truth |
|---|--------|------|-----------------|
| 1 | The clearing solver (39-zone coupled auction) | **constructed** | `src/MPCC.jl`, `src/mpcc/`, `src/Network.jl`, `src/clearing/` |
| 2 | Next-day LOAD prediction | **fitted** | `bin/input_models/`, `bin/ml_inputs.jl`, `bin/load_models_v1.json` |
| 3 | Next-day SOLAR prediction | **fitted** | `bin/input_models/`, `bin/res_models_v2.json` |
| 4 | Next-day WIND prediction | **fitted** | `bin/input_models/`, `bin/res_models_v2.json` |
| 5 | Order-book construction | **constructed** | `src/merit_order/`, `src/Generators.jl` |
| 6 | Out-of-EU zone behaviours (TR / GB / UA) | **constructed w/ declared anchors** | `src/merit_order/{boundary,zone_profiles,flows_imports}.jl`, `src/Network.jl` |

---

## Pillar 1 — The clearing solver

**Dictation:** "a day-ahead market clearing engine — coupled (39 zones, ATC
network) and complete. Validated on real published auctions — GME €0.00 exact."
**Verdict: correct.**

The engine solves the same coupled auction the real market solves: a MILP /
complementarity (MPCC) formulation where **zonal prices are the duals of the
zonal balance constraints** and cross-border flows are bounded by ATC on every
border. Entry points:

- `run_multi_zone_market_clearing` (`src/clearing/multi_zone_run.jl`) — the
  39-zone coupled clear; `generate_energy_prices` (`src/clearing/single_zone.jl`)
  — one zone in isolation.
- MPCC solve, robustness ladder and competitive price reconstruction:
  `src/mpcc/solver.jl`; coupling metrics `src/mpcc/coupling_metrics.jl`.
- Network topology, `TransferCapacity`, enriched ATC build (implicit + explicit
  union, aggregate remap, flow-based border drops): `src/Network.jl`,
  `flow_based_drop_borders` (`src/clearing/multi_zone_books.jl:110`).
- **Two-pass** clearing (`passes=2`): opportunity-anchored zones re-bid against
  pass-1's coupled price (`mz_extract_anchor_inputs` / `mz_rebuild_anchored`,
  `src/clearing/multi_zone_books.jl`).
- Solvers HiGHS (default, open-source) and Gurobi; per-period decomposed canonical
  mode is solver-invariant (cv20, `docs/period-decomposition.md`).

**Validation (independent of the fitted inputs and of the book):** fed the *actual*
published GME (Italian) and OMIE (Iberian) day-ahead bid books, the solver
reproduces the official zonal price exactly wherever the published book alone
determines it — **max |Δ| = €0.00** across the well-determined GME cells
(`docs/experiments/pubbooks-clearing/{REPRODUCE,results}.md`). This is the pillar-1
correctness proof: the *mechanism* is exact; everything downstream is about the
*inputs* to it (pillars 2–6).

**ADDED (belongs on the surface):** the coupled clear is fully reproducible offline
against a published DuckDB extract — no Postgres, no license
(`docs/reproducibility.md`). "Complete" is honest: 39 zones, 24 hours, DST-aware
Athens market day.

---

## Pillars 2–4 — The fitted next-day input predictions

**Dictation:** load = per-zone ML/LightGBM + linear packs where they win; solar =
fitted, capacity-normalized; wind = fitted, physical power-curve packs still win
onshore. **Verdict: correct and precise.** Full inventory + code review in
[`docs/six-pillars-fits.md`](six-pillars-fits.md); the open reproduction recipe is
[`docs/predictions.md`](predictions.md).

These are the **only fitted layer**. For every delivery hour and zone they predict
the three ENTSO-E **D-1 forecasts the auction clears on** (not the settled outturn —
`docs/predictions.md §1`), so the weather track converges to the reference track's
price quality when it matches.

- **Model family:** per (zone, target) LightGBM (L1 / MAE-aligned), or the committed
  **linear packs** where those still win the frozen OOS scorecard. Winners resolved
  at run time from `bin/input_models/meta.json` (`ml_pilot_zones()`/`ml_use_new()`,
  `bin/ml_inputs.jl`). **76 of 117 zone-targets ship LightGBM; 41 keep the pack**
  (`docs/experiments/input-upgrade/rollout-39.md`).
  - **Load: 38/39 zones ML** (AR-lagged LightGBM beats the linear ridge nearly
    everywhere). Pack fallback for daily-forecast eligibility fill:
    `bin/load_models_v1.json` (`docs/experiments/dn-load-model`).
  - **Solar: 22/32 modeled zones ML**, capacity-normalized (ratio vs trailing-30d
    p95, so a growing fleet does not drift the forecast); 7 zones skip (no
    meaningful solar). Pack: `bin/res_models_v2.json`.
  - **Wind: 16/32 ML**; the physical **power-curve** pack still wins the
    low/onshore zones. Pack: `bin/res_models_v2.json` (v2 = refit on GFS-vintage
    winds, fixing the −29% GR train/serve level bug — `docs/experiments/res-forecasting`).
- **Honest vintage discipline:** every weather driver is a GFS `previous_day1`
  vintage (the value a run *issued on D-1* predicted), applied identically at train
  and serve — no lookahead, no train/serve skew (`docs/predictions.md §2`;
  `bin/weather_vintage.jl`).
- **Serve == train:** the pure-Julia GBDT scorer `bin/ml_inputs.jl` is bit-identical
  to python LightGBM on identical features (rare last-ULP split-flips aside).
- **Two tracks, one engine.** The multi-year **record** runs on the ENTSO-E
  *reference* inputs (isolating the mechanism); the live **ex-ante product** runs on
  *these fitted* inputs and freezes before the auction gate. The fitted predictions
  never enter the record (`web/about.html` "The two tracks").

**Why fitted here is legitimate:** these are *predictions*, labelled as statistics
and scored like any forecast; the fit/construct wall keeps them out of the price
mechanism, so no price parameter is ever tuned against a price error.

---

## Pillar 5 — Order-book construction methodology

**Dictation:** from ENTSO-E transparency data + our feeds, per unit/fuel-type and
**simple named market characteristics**; the owner wants every characteristic that
enters each bid category stated explicitly. This is "prediction" only in the sense
of *constructing the bid book from ex-ante information* — no price is regressed.
**Verdict: correct; the full explicit table is below.**

`create_merit_order_book` (`src/merit_order/book_build.jl:549`) builds each zone's
hourly supply/demand curve in stages. Every order is **tagged** with an owner and a
**strategy label** (the WHY of the block — `STRATEGY_DESCRIPTIONS`,
`book_build.jl:36`), which is exactly what the site's Books page renders.

### 5a. The cost model (what a unit's SRMC is made of)

`src/generators/fuel_costs.jl`, constants in `src/Generators.jl`:

- **Gas** `Fossil Gas`: `TTF/η + EUA·EF_gas/η + VOM`, η = `GAS_PLANT_EFFICIENCY = 0.55`,
  `GAS_EMISSION_FACTOR = 0.202` tCO₂/MWh_th, `GAS_VOM_COST = 2.0` (`fuel_costs.jl:202`).
  TTF = last front-month close strictly **before** the delivery day (no lookahead,
  cached; `get_ttf_price`).
- **Carbon** EUA = last daily close strictly before the market date from
  `yfinance.eua_co2` (`eua_price`), yearly-average fallback before Nov 2021.
- **Every other fuel**: `FUEL_SRMC_BASE[fuel] + FUEL_EMISSION_FACTOR_EL[fuel]·EUA(t)`
  (`fuel_costs.jl:228-255`). Named base costs (€/MWh_el, no bid markup): lignite 25 +
  EF 1.25; hard coal 37 + 0.90; oil 103 + 0.75; nuclear 10; ROR hydro 3; reservoir
  hydro 12 (water value applied in the book, not here); wind 1 / offshore 2 / solar 1;
  biomass 60; waste 25; geothermal 20.

### 5b. The named book parameters — the explicit characteristics table

Form-level constants (**identical in all 39 zones** — `zone_profiles.jl:237-273`)
and per-zone `ZoneProfile` fields (`zone_profiles.jl:330-455`). Each row: the named
characteristic, its value/source, and which bid category it feeds.

| Characteristic | Value / source | Feeds which bid category |
|---|---|---|
| `TRANCHES` | `[(.55,×.95),(.20,×1.05),(.15,×1.25),(.10,×1.60)]` (share of p_max, SRMC mult) | thermal supply ladder — `srmc_base` (tranche 1, no markup) + `peak_tranche_k` |
| `MUST_RUN_PRICE_FACTOR` | 0.05 | `must_run_deep`: deepest min-load block bid at 5% of SRMC (self-schedule) |
| `MUST_RUN_SRMC_THRESHOLD` | 1.15 × gas SRMC | which units are "committed"/must-run (`_committed_set`) |
| must-run second block | `min(max(0.5·SRMC, SRMC−40), nuc_ceil)` | `must_run_rest`: rest of min-load below cost (absolute discount) |
| `AVAILABILITY_FACTOR` | 0.80 | shapes the scarcity margin denominator (not p_max) |
| `PEAK_EXPONENT` | 4.0 | concentrates the peak markup in true peak hours |
| `scarcity_threshold` / `scarcity_kappa` | 1.4 / 3.0 (SEE); softened continental 1.25/1.5, Nordic 1.2/1.0 | upper-tranche scarcity uplift when margin < threshold |
| `peak_kappa` | 1.2 SEE / 0.6 continental / 0.5 Nordic | peak-hour strategic uplift (`norm_demand^4`) |
| `water_value_base` / `water_value_span` | 0.85/0.9 gas-anchored; 0.6/0.5 reservoir | hydro `water_value_*` bid level & within-day swing |
| `WATER_VALUE_DRY_BOOST` | 1.0 | dryness multiplier on the water value |
| `hydro_model` | `:gas_anchored` (SEE) or `:reservoir_opportunity` (Nordic/Alpine) | which water-value formula |
| `thermal_srmc_multiplier` | 1.0 default, **1.20 Italy** (LNG/older-fleet premium) | scales all non-hydro SRMC |
| `nuclear_srmc_floor` | 0 default, **55.0 France** | floor under nuclear bids (EDF off-peak position) |
| `opportunity_anchor` | `:none` / `:hydro` / `:nuclear` | which fleet re-bids in pass 2 at `share × coupled ref` |
| `anchor_share` | 0.9 default; FR 0.55; AT 1.1; BE 0.9 | fraction of coupled ref the anchored fleet asks |
| `nuclear_avail_share_lo/hi` | FR 0.40 / 0.95 (else 0=off) | availability-scaled nuclear share (cv23) |
| `nuclear_bid_ref_ceiling` | FR 1.3 (else 0=off) | caps anchor-lifted nuclear bids at 1.3× ref (crisis cap fix) |
| `scarcity_import_credit` | 1.0 on continental/Baltic (else 0) | credits offered import ATC into the scarcity margin |
| `fleet_truth_mode` | `:p95` (SEE) / `:installed` (continental core, Baltics) | fleet completion/derate target |
| `FLEET_COMPLETION` / `FLEET_TRUTHING` / `DERATE_HEADROOM` | true / true / 1.15 | complete fleet up to truth target; derate declining baseload to trailing p95 |
| `seasonal_drawdown` | true (SE1/SE2); false (NO4) | raises Nordic water-value floor with winter reservoir drawdown |
| `import_backstop` | on: AT/BE/CH/DK1/DK2/SE3/SI/RO/RS/HU/IT-CNORTH/NO1/NO3/FR (+ cv25 T1 BG/GR, T3 IT-NORTH) | elastic supply = demonstrated import headroom beyond climatology, priced `BACKSTOP_PRICE_MULT=1.8 × gas SRMC` over `BACKSTOP_WEEKS=8` same-weekday window |
| `backstop_scarcity_credit` | 1.0 on RO/RS/HU/FR (else 0) | credits that headroom into the scarcity margin too |
| `ref_priced_exports` | true on BE/SI (else false) | retained-border exports priced at coupled ref, not cap |
| `spill_surplus_dryness` | 0.15 Nordic (cv27 T2, **opt-in only**) | spill-risk valley chase (NOT shipped by default) |
| `boundary_book` | `nothing` except DK1/FR (GB), RO/HU/SK/PL (UA) | pillar 6 — see below |
| `DEEP_SURPLUS_FLOOR_EUR` | −20.0 | cv31 solar-regime floor price |
| Solar-regime floor (cv31) | ON default, θ=0.4, zones DE_LU/FR/PL/BE/CZ/CH | in high-solar hours RES + ROR + deepest must-run block price at the −20 floor so the clear can genuinely go below zero (`book_build.jl:816-867`) |
| `DEMAND_ELASTIC_SHARE` / `_PRICE` | 0.02 / 250 €/MWh; firm at `PRICE_CAP=3000` | demand: ~98% inelastic at cap + small elastic tail |

**The profile is data, not logic** — one `ZoneProfile` per zone in
`ZONE_PROFILES` (`zone_profiles.jl:971`), defaulting to `SEE_PROFILE` (the exact
v10 SEE calibration, regression-guarded byte-identical). The site's zone-strategy
table is generated *from this object in-process* (`bin/export_zone_strategies.jl`),
never hand-kept.

**ADDED (the owner's list should include):** the two-pass **opportunity anchors**
(hydro NO*/CH/AT/BE/SK, nuclear FR) that re-price flexible fleets against the
coupled reference; the **fleet-truthing / crisis-honesty derate**; and the
**ex-ante flow rule** (pillar 6) that decides how imports enter — these are as
load-bearing as the SRMC tranches.

**Every input is strictly ex-ante** (D-1 vintages for weather, last close before
the market day for fuel/carbon, trailing observed capabilities for capacities);
parameters are nameable market characteristics, validated on held-out windows,
never fitted to the scored prices.

---

## Pillar 6 — Out-of-EU zone behaviours (TR / GB / UA)

**Dictation:** TR = fixed observed injections on dropped borders; GB = cv21
Viking/DK1 + cv23 FR–GB elastic CCGT boundary books; UA = cv22 firm-slice
war-constrained buyer book. **Verdict: GB and UA correct and precise; TR needs a
CORRECTION.**

Out-of-footprint neighbours (TR, AL, MK, UA, GB) are not in the 39-zone footprint,
so by default they enter the coupled clear as **fixed observed net-import
injections** from `entsoe.physical_flows` (`get_net_imports`,
`src/merit_order/flows_imports.jl:466`). Two of them (GB, UA) are *promoted* on
specific borders to **elastic boundary books** — the neighbour is modelled as a
counterparty with its own supply/demand ladder anchored on **its own fundamental
SRMC** (`BoundaryBook`, `zone_profiles.jl:73`; ladders `boundary.jl`), which
*replaces* that neighbour's fixed injection and its import-backstop headroom.

| Country | How it enters | Anchor | Capability sizing | Where |
|---|---|---|---|---|
| **Turkey (TR)** | **Fixed observed net-import injection only** — never an elastic counterparty. On the BG–TR (and GR) border, the observed physical flow is committed as price-taking supply (import) / firm demand (export). Ex-ante-lagged, not same-day (see below). | — (no book) | — | `get_net_imports`; `Network.jl:734` lists TR as a GR neighbour |
| **Albania / N. Macedonia (AL/MK)** | Same as TR — fixed observed injections | — | — | `get_net_imports` |
| **Great Britain (GB)** | Elastic CCGT boundary book on TWO borders: **DK1–GB Viking Link** (cv21, `VIKING_GB_BOOK`) and **FR–GB IFA/IFA2/ElecLink** (cv23, `GB_FR_BOOK`). The FR book also fixes a ≈2× flow double-count (aggregate `GB` + three cables). GB elsewhere stays a fixed injection; GB the zone is PARKED. | GB CCGT SRMC = `TTF/0.52 + carbon/0.52 + €2`; carbon `:eua` (Viking) or `:uka` UK-ETS (FR). `anchor_mult` 1.15 | `:atc_capped` — day's offered DA explicit ATC capped at trailing-366d demonstrated max, p95-block floor on ATC gaps (`boundary.jl:105`) | `zone_profiles.jl:133,170`; DK1_PROFILE / FR_PROFILE |
| **Ukraine (UA)** | Elastic **war-constrained scarcity buyer** book on HU/SK/RO/PL–UA (cv22, `UA_BOOK`). Import side sells cheap surplus; export side is a **FIRM cap-priced base slice** (demonstrated persistent import need that does not curtail on price) + elastic tail. PL adds the UA_DobTPP radial. | `:zone_gas_srmc` (no UA feed — the documented generic-anchor compromise); import `0.55×gas×[.85,1,1.2]`, export tail `gas×[1.2,1]`, firm = trailing-28d p10 of daily block-mean export flow | `:p95_block` — pure trailing-366d p95 gross flow per 4h block (UA ATC stale ~4×) | `zone_profiles.jl:207`; RO/HU/SK/PL profiles |

**CORRECTION to the dictation:** "TR: fixed observed injections **on dropped
borders**" conflates two distinct mechanisms. There are no "dropped TR borders":
(1) **flow-based border DROPS** (`flow_based_drop_borders`) are an *internal*
network fix that removes misrepresenting ATC on **in-footprint** Core-FBMC borders
(AT–SI, CZ–SK, …), restoring their observed flows as import-only injections; (2)
**out-of-footprint** neighbours like TR are simply *never in the footprint*, so
their flows are injected as observed schedules. TR is a **fixed (ex-ante-lagged)
observed injection, full stop — no book, no anchor, no capability sizing.** The
BG–TR p95-block recipe (`boundary.jl:236` comment) is the *ancestor* of the UA
sizing, not a TR book. If TR ever gets an elastic book it would be a new pillar-6
item; today it does not have one.

**ADDED — the ex-ante flow rule (how ALL injections, incl. TR/AL/MK, become
ex-ante):** the EU-footprint path defaults to **`:v3`** flows
(`FLOW_ASOF_MODE`, `flows_imports.jl:63`; scoped default resolved in
`multi_zone_books.jl:549`): per border, a load-analogue median (16 trailing-365d
days nearest the delivery day's D-1 load-forecast vector — load as the ex-ante
thermometer) blended with the D-2 observed flow, plus D-7 recency on Norwegian
reservoir borders (`:v2` component). Same-day observed flows (`:d0`) are the SEE
legacy / byte-identity path only. This is what makes the injected TR/AL/MK/GB/UA
schedules honest ex-ante inputs rather than lookahead. (Historical note: the
pipelined records through cv24 were NOT ex-ante on flows — a defect found by audit
and closed in cv25; `docs/experiments/exante-audit-2026-07.md`.)

---

## The epistemology in one line

**We fit the inputs (pillars 2–4), we construct the prices (pillars 1, 5, 6).** No
price parameter is tuned against the price errors we publish; the residual between
the constructed competitive counterfactual and the settled market is the finding —
scarcity, strategic bidding, conduct — not a model error to be regressed away.
