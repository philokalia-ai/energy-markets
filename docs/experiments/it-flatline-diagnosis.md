# IT zones — the flat-line diagnosis (July 2026)

**Question (user).** "In Italy we predict a flat line — do we not have data?"

**Answer: the data are complete; the flat line is a book-structure gap.**

## Measured

Intraday shape ratio (mean per-day std of sim ÷ actual, cv17 `eu17_base`,
2023-07..2025-06, 715 days):

| zone | sim std | act std | shape ratio |
|---|---:|---:|---:|
| IT-CSOUTH | 6.0 | 23.1 | **0.26** |
| IT-Calabria | 7.7 | 23.5 | 0.33 |
| IT-SOUTH | 8.2 | 23.7 | 0.35 |
| IT-Sardinia | 12.6 | 27.8 | 0.45 |
| IT-CNORTH | 11.4 | 22.2 | 0.51 |
| IT-NORTH / IT-Sicily | ~12–15 | 20–26 | 0.59 |
| *GR (reference)* | 32.8 | 42.0 | 0.78 |
| *ES (reference)* | 33.2 | 24.0 | 1.38 |

Some IT days have literally zero sim variance (per-day corr = NaN).

**Input data are NOT missing**: every IT zone has full D-1 load forecast
(96 rows/day), full solar + wind forecasts, and per-type actuals in the
extract. This is not an ETL/data problem.

## Mechanism (IT-CSOUTH, 2025-02-15 — representative)

| | night | solar noon | evening peak |
|---|---|---|---|
| net load (MW) | +2,100…+2,700 | **−7,900** (RES > load!) | +1,300 |
| actual (€/MWh) | 139–151 | **110–117** | **168–175** |
| sim (€/MWh) | 139.0 | 127.7–139.0 | **139.0** |

The sim sits pinned at **139.0 for 21 of 24 hours** — the price of one wide
fleet-completed gas tranche. Net load swings by **10.6 GW** across the day and
the marginal order never changes, because:

1. **The completed gas fleet is one huge flat-priced tranche.** Fleet
   completion aggregates the (obfuscated-registry) Italian gas fleet into a
   single price step; the entire net-load range lands inside it, so the
   marginal price is constant by construction.
2. **No intraday scarcity/premium shaping for the IT profile.** The evening
   peak (actual 175) prices at the same 139 — the hourly scarcity term never
   activates at these margins (completed supply ≫ 1–7 GW zonal net load).
3. **RES-surplus hours don't price down.** With RES > load for 8 straight
   hours, the sim dips only 8–11 € (partial tranche step) while the actual
   drops 30–40 below the gas band — midday exports/curtailment economics are
   not represented in the zonal book.

## Fixes (cv18 candidates — model iteration, not data work)

1. **Split the completed-fleet gas tranche into an efficiency ladder** (CCGT η
   0.48–0.58 → ±10 % SRMC spread, 4–6 steps) so the marginal price moves with
   net load. Cheapest fix, likely the biggest shape gain.
2. **IT-profile intraday premium** shaped on the net-load percentile (the
   `peak_kappa` idea already in the cv18 backlog) — evening ramp pricing.
3. **RES-surplus pricing**: when zonal net load < 0, the marginal should fall
   toward the RES floor / export-congested level rather than stay on gas.

Expected effect: shape ratio 0.26→0.6+ for the flat zones would move their
correlations from 0.4–0.6 toward the thermal-zone band (0.7+), on data we
already have. File under the next calibration iteration with the standard
guards (SEE byte-identity, per-zone gates).

## Update (loop, 2026-07-18 late): mechanism CORRECTED by measurement

Two experiments sharpened the diagnosis:

1. **The fine-tranche ladder is a confirmed dead end.** A 10-step tranche
   ladder (0.85–1.60×SRMC, same average as stock) applied as a runtime profile
   override on 20 IT-CSOUTH days: MAE 21.81 → **27.27, worse on 20/20 days**,
   and — the tell — **sim intraday std unchanged (8.7 → 8.7)**. Tranche
   granularity does not control the shape.
2. **The marginal-attribution probe found the real pin.** On the flat day
   (2023-07-17, every hour clears at exactly 90.90): the marginal orders are
   FOUR different unit-level gas plants (Montalto, Aprilia, Torrevaldaliga,
   Civitavecchia) whose tranches price **identically** — every Italian gas
   unit carries the same type-level SRMC, so the whole fleet's same-multiplier
   tranches align into one flat step of several GW. Net load never leaves the
   step; any per-profile ladder just *moves* the step (level change, no shape).

**Corrected fix (cv18 candidate): per-unit efficiency spread.** Decorrelate
unit SRMCs (η ∈ ~0.48–0.58 → ±8 % cost spread, stable per unit — ideally from
inferred heat rates, else a deterministic draw) so unit tranches interleave
into a dense ladder. Prototyped via the strategist hook (±8 % stable-hash
repricing of every supply order) — results in
`docs/experiments/strategic-layer/it_unitspread_proto.jl` / the loop log.

## RESULT: per-unit efficiency spread WORKS (loop, 20-day A/B)

Stable ±8 % per-unit repricing of every IT-CSOUTH supply order (strategist
prototype, `it_unitspread_proto.jl`):

| | corr | MAE | sim intraday std | better days |
|---|---:|---:|---:|---:|
| stock | 0.307 | 21.81 | 8.7 | — |
| **±8 % unit spread** | **0.680** | **20.05** | 10.5 | **19/20** |

Correlation more than doubles, MAE drops, and the fully-flat days come alive
(final sample day: corr 0.0 → 0.75). This confirms the corrected mechanism and
makes **per-unit SRMC decorrelation the headline cv18 candidate for the IT
zones** — physically justified (real CCGT fleets span η ≈ 0.48–0.58; ideally
sourced from inferred heat rates rather than a hash draw), cheap, and entirely
inside the cost model. Adoption path: implement as a Generators-layer option
(per-unit efficiency inference or deterministic spread), guard with SEE
byte-identity + per-zone A/B on held-out days, bump cv18.

## Spread family — consolidated (loop, magnitude sweep + generalization)

| zone / arm | corr | MAE | better days |
|---|---:|---:|---:|
| IT-CSOUTH stock | 0.307 | 21.81 | — |
| IT-CSOUTH ±5 % | 0.667 | 20.68 | 19/20 |
| IT-CSOUTH ±8 % | 0.680 | 20.05 | 19/20 |
| IT-CSOUTH ±12 % | 0.677 | **19.35** | 19/20 |
| IT-NORTH stock → ±8 % | 0.747 → **0.820** | 19.74 → **17.82** | 17/20 |
| IT-Sicily stock → ±8 % | 0.489 → **0.720** | 21.82 → **20.10** | 19/20 |
| **IT-Sardinia stock → ±8 %** | 0.369 → 0.361 | 26.70 → 28.03 | **7/20 (negative)** |
| **DK1 stock → ±8 % (valid rerun)** | 0.495 → 0.521 | 34.44 → 33.96 | 10/20 (marginal) |

Correlation plateaus at ±8 %; MAE keeps improving to ±12 %. **cv18
recommendation: per-unit SRMC spread ≈ ±10 % for the IT mainland zones + Sicily**
(Sardinia is the honest exception — its sim already has structure and the
spread hurts; its residual is the island system / SAPEI import mix, filed
separately) (implemented
properly in the cost model — inferred heat rates where history allows, a
deterministic per-unit draw otherwise), guarded by SEE byte-identity and
held-out per-zone A/Bs. **DK1: marginal.** The first DK1 run was INVALID (a prefix bug meant Danish
unit orders were never repriced — caught in the loop's code-review pass); the
valid rerun gives corr 0.495 → 0.521, MAE −0.5, 10/20 days: a small real
effect, an order below the IT gains. DK1's main levers remain the
import/RES-surplus family per its hour-profile diagnosis.

## cv18 implementation record (the honest engineering trail)

Promoting the prototype to model code surfaced four measured subtleties:

1. **Spraying `marginal_cost` is wrong** — it also perturbs the UC-lite
   must-run *selection* (SRMC ≤ 1.15×gas gate), shifting the committed set:
   half the CSOUTH gain vanished and MAE worsened +2.4. The spread belongs at
   ORDER-PRICE time (gmc), selection on unsprayed costs — prototype semantics.
2. **The draw matters: ±0.1 corr across salts** (CSOUTH 0.51–0.71 over four
   seeds). The prototype's 0.68 was a good draw.
3. **Every deterministic permutation failed on CSOUTH** (monotone rank AND
   interleaved rank → 0.31 = stock): any fixed ordering has same-parity/
   adjacency clusters, and CSOUTH's four price-pinning units landed in one.
   Excluding the AGG aggregate (which any size-ranked scheme hands the extreme
   cheap slot, re-pinning the price) did not rescue ranking either.
4. **Final scheme: canonical unsalted FNV-1a draw** — arbitrary-but-fixed,
   bit-reproducible across runs and Julia versions; inferred heat rates
   replace it when unit history supports them.

Final gates (real cv18 code, 20-day sets; stock → cv18):

| zone | corr | MAE | note |
|---|---|---|---|
| IT-CSOUTH | 0.307 → **0.501** | 21.81 → 22.87 | below the lucky-draw prototype, +0.19 real |
| IT-NORTH | 0.747 → **0.839** | 19.74 → **17.28** | ≥ prototype |
| IT-Sicily | 0.489 → **0.734** | 21.82 → **20.96** | ≈ prototype |
| IT-Sardinia | 0.369 → **0.505** | 26.70 → 27.12 | indirect (no own spread — partner coupling) |
| DK1 (ladder) | 0.495 → **0.569** | 34.44 → **32.42** | = prototype exactly |
| GR | max\|Δ\| = 0.0 | — | byte-identity preserved |
