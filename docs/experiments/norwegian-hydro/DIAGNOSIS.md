# Norwegian hydro zones — diagnosis (cv23 program)

**The program's oldest open problem.** Since cv16 the README has carried NO1 as
"the known open problem: its import flow regime flips week to week; neither an
8-week climatology nor D-7 recency captures it." This document reopens it from
the residual, structures *when* and *why* it fails, and identifies the lever.

Scope: NO1/NO3/NO4 (primary), NO5 + SE1–SE4 (secondary). Comparable full year
**2025-07-25 → 2026-07-24**, cv22 `multi_zone_eu` backfill vs realized
`entsoe.energy_prices` (Day-ahead). All analysis is offline on a single exported
slice: `export_slices.jl` dumps the price/reservoir/flow CSVs (to a git-ignored
`data/`), `make_tables.py` regenerates the committed `tbl_*.tsv` summaries the
tables below cite. The coupled A/B uses `ab_no.jl` + `launch_*.sh`, scored by
`score_ab.py` / `score_bkonly.py`.

## 0. The record (cv22, comparable full year)

| zone | corr | MAE | bias | act_mean | sim_mean | note |
|---|---|---|---|---|---|---|
| **NO1** | **0.00** | **62.7** | **+36.9** | 82.9 | 119.7 | the open problem |
| NO2 | 0.77 | 15.6 | +1.0 | 86.5 | 87.5 | **works** — export gateway |
| **NO3** | 0.13 | 42.7 | +26.5 | 57.9 | 84.4 | overpriced |
| NO4 | 0.14 | 26.7 | +3.1 | 27.6 | 30.6 | level ok, shape flat (congestion-isolated) |
| NO5 | 0.42 | 26.8 | +3.0 | 78.7 | 81.7 | partial |
| SE1 | 0.52 | 25.8 | −10.1 | 36.7 | 26.6 | |
| SE2 | 0.51 | 25.9 | −10.3 | 36.7 | 26.3 | |
| SE3 | 0.61 | 30.2 | +15.6 | 63.7 | 79.2 | |
| SE4 | 0.59 | 31.7 | −8.0 | 78.8 | 70.7 | |

`DE_LU 0.85 / DK1 0.78` for reference (continental couplers). **NO2 is the
anomaly that solves the case: same NORDIC hydro model, same `:hydro` anchor as
NO1/NO3/NO5, yet it fits.**

**cv22 ≈ cv19 on every NO zone** (NO1 both corr 0.003 / MAE ~65 / bias ~+41 on
the overlap window; May-2026 blowup 489 in both). The cv22 reservoir-window
bug-fixes (drawdown 52–104wk, dryness ISO-wrap) moved SE3/SE4 by ~0.03 corr but
**did nothing for the NO zones** — because the `:hydro`-anchored NO zones price
purely off the anchor and never reach the reservoir wv_frac / drawdown branch
(`book_build.jl` §"Only the non-anchored reservoir zones … reach the wv_frac
branch"). The reservoir signal is computed and then discarded for exactly these
zones. (`tbl_zone_stats.tsv`, and cv19/cv22 compare in the session log.)

## 1. NO1's failure is TWO independent failures

### 1a. A single-month phantom-scarcity blowup carries the ENTIRE bias

Removing one month, May 2026, from NO1:

| | corr | MAE | bias |
|---|---|---|---|
| NO1 all year | 0.004 | 62.7 | +36.9 |
| NO1 **excl. May-2026** | 0.046 | **29.4** | **+3.8** |

May 2026 NO1: **sim mean €489 vs actual €99**; **16 of 31 days clear sim > €200
(mean sim €846 vs actual €94)**. The blowup starts abruptly on 2026-05-13
(sim jumps €82→€764 while actual stays €119) and runs to month-end. It accounts
for the **entire +€37 annual bias** and roughly half the MAE. This is a
phantom-scarcity cap regime, not a pricing-level error. (`tbl_may_reservoir.tsv`.)

Mechanism (fundamentals, mid-May weeks 20–22): NO1's reservoir sits at its
**seasonal low** — ~0.9 TWh vs the 5.3 TWh autumn peak, refilling through the
snowmelt — and at the **25–33rd percentile vs the same week in prior years**, so
`get_reservoir_dryness` reads elevated. Two consequences in the
`:reservoir_opportunity` book: (i) offered hydro **quantity** is rationed
(`hydro_scale = clamp(1−dryness, 0.5, 1.0)`), and (ii) NO1's only other supply
is the *clamped observed import-only* flow over its dropped Nordic borders
(D-2/analogue-lagged, positive-direction only). When the coupled clear cannot
cover demand at any offered price below the cap, it clears against the inelastic
demand tranche → €200–2000. Reality had ample water (actual €94), so the dryness
rationing is **contradicted by the outturn**. NO1 has near-zero local thermal, so
nothing between the water value (clamped ≤ gas SRMC) and the demand cap catches
the shortfall. NO2 never does this — its physical DE/NL/DK cables enter as large
observed injections, so it is never short.

**This is a phantom-scarcity KNIFE-EDGE, not a fixed level.** Re-running the same
May days on the (more complete, daily-refreshed) live extract, base NO1 flips
between clean (05-17 €91, matching actual €99) and cap (05-18 €2045, actual €132)
— and a single-process re-run of 05-18 alone gave €119, while the 6-way
concurrent shard gave €2045. NO1's spring-drawdown clear sits at supply ≈ demand
at the offered prices, so the documented concurrent-SQL last-ULP `SUM` reordering
(CLAUDE.md: "rarely flips a near-degenerate marginal tranche") is enough to tip it
over the cap. The frozen cv22 Postgres record and the live extract cap on
*different* May days for the same reason. That instability **is** the diagnosis:
an import-starved zone one ULP away from the price cap. The `import_backstop`
(elastic import supply above the tranches) removes the knife-edge by construction
— the clear can lean on demonstrated import capability instead of jumping to the
cap.

### 1b. Even excluding May, NO1 has zero shape skill (corr 0.046)

The sim is a nearly **flat ≈€83 line** every month (76–90) while realized NO1
swings **€47 (Jul) → €110 (Feb)**. The residual sign **flips with season**:

| NO1 month | act | sim | bias |
|---|---|---|---|
| 2025-07..10 (wet summer/autumn) | 47–61 | 77–90 | **+22..+39 (overprice)** |
| 2026-01..04 (drawn-down winter) | 100–110 | 76–90 | **−18..−24 (underprice)** |

A flat line anti-correlated with a seasonally- and diurnally-swinging signal is
exactly corr ≈ 0. (`tbl_monthly.tsv`.) NO3 and NO5 show the same summer-
overprice / winter-underprice flip (NO3 far worse in summer: actual €6–24 while
sim €67–82).

## 2. The physical story and the mechanism of the failure

**NO1 is not a continental coupler — it is a hydro pocket *behind* NO2.** Norway's
interior zones reach the continent only through NO2 (NordLink→DE, NorNed→NL,
Skagerrak→DK1). The realized cross-correlations say it plainly:

- **corr(NO1, NO2) = 0.894**, NO1 mean only **€3.5 below** NO2 (|Δ|>€10 in just
  24% of hours). NO1 tracks its gateway.
- corr(NO1, DE_LU) = 0.629; NO1 sits €12 below DE and is **decoupled cheap
  (NO1 < DE − €20) in 36% of hours** — the summer surplus regime.
- corr(NO3,NO2)=0.58, corr(NO5,NO2)=0.73, corr(NO4,NO2)=0.41 (NO4 genuinely
  isolated).

**What our model does instead.** Every Norwegian-internal border is a dropped
flow-based residual (`flow_based_drop_borders`: NORDIC_NO_ZONES × NORDIC_FB_ZONES
— stale post-Oct-2024 ATC that would starve the zones if endogenized). So
NO1/NO3/NO5 have **zero endogenous ATC neighbours**, and
`compute_opportunity_anchor_refs` falls their anchor reference back to the
**DE_LU/NL continental proxy** (documented in that function). The `:hydro` anchor
then prices their water at `clamp(ref × (0.9 + dryness), 2, gas_srmc)` ≈ 0.9 ×
continental — a flat continental level with continental (not hydro) shape, and
the reservoir state discarded. **NO2 fits because NO2's DE/NL cables are NOT
Nordic-internal, so they survive as endogenous neighbours and its anchor
reference is genuinely its export market — which its price genuinely tracks.**

We give the interior zones the gateway's *destination* price when we should give
them the *gateway's own* price (discounted by the NO1→NO2 corridor congestion
that creates the summer decoupling).

### The counterfactual that sizes the prize

Pricing each interior zone at **NO2's own coupled sim price** (`sim_NO2`),
scored against that zone's realized price (`tbl_no2_counterfactual.tsv`):

| zone | own corr | own MAE | as-NO2 corr | as-NO2 MAE | realized corr w/ NO2 |
|---|---|---|---|---|---|
| **NO1** | 0.004 | 62.7 | **0.677** | **20.1** | 0.894 |
| NO3 | 0.127 | 42.7 | 0.420 | 41.2 | 0.580 |
| NO5 | 0.423 | 26.8 | 0.501 | 26.0 | 0.733 |

For **NO1 this is transformative** (corr 0.00→0.68, MAE 62.7→20.1) **and it
also removes the May blowup** — `sim_NO2` never caps, because NO2 is
cable-supplied. NO5 gains modestly; **NO3 gains shape (corr) but not level** —
NO3 is genuinely more decoupled (central Norway, cheap in summer like NO4), so
tracking NO2 fixes its diurnal shape while leaving a summer-overprice residual.

## 3. Reservoir stratification — the discarded fundamental

Realized NO1 price stratifies cleanly by **absolute** reservoir level
(`tbl_may_reservoir.tsv`): full **€64.6** / mid €103.1 / drawn-down **€105.3**. The seasonal
drawdown *is* the water-value signal, and the model already computes it
(`get_reservoir_drawdown`, shipped cv15/cv22) — but the `:hydro` anchor branch
never reads it. The prior-year-relative *dryness* percentile is a noisier signal
(it mixes seasons) and is exactly what mis-fires in the May blowup. **The clean
signal is absolute level / seasonal drawdown, not the same-week percentile.**

Two ways to restore it: (A) let NO1 track NO2 — NO2's coupled price already
embeds the seasonal state, so the reservoir signal arrives *through the gateway*;
or (B) add an explicit reservoir-drawdown term to the anchored water value. (A)
is simpler, is the export-opportunity-cost statement in its purest form, and
covers the May quantity failure too; (B) is a strictly local supply-curve fix
that does not address the May shortage. **The diagnosis favours (A).**

## 4. Literature check

Nordic hydro price formation is the **water value** — the marginal shadow price
of stored energy from stochastic dynamic programming over inflow/price
scenarios (SINTEF's EMPS / "Samkjøringsmodellen" and its successor
ProdRisk/SOVN; Wolfgang et al., *Hydro reservoir handling in Norway before and
after deregulation*, Energy 2009; Fosso et al., *Generation scheduling in a
deregulated system — the Norwegian case*, IEEE TPWRS 1999). The water value
rises as reservoirs draw down and as the expected future (export) price rises;
in surplus/high-inflow states with internal transmission congestion, interior
zones **decouple downward** from the export price — precisely the NO1 summer
regime. Two robust implications for us: (i) an interior zone's water value is
anchored on its **export-corridor opportunity cost**, not the distant
continental hub (matches §2); (ii) reservoir *level/drawdown* — not a
same-week-vs-years percentile — is the state variable (matches §3). A full
scenario water-value model needs **inflow forecasts**, which ENTSO-E does not
publish; the ex-ante, no-fit substitute available to us is the coupled NO2 price
(which internalises the same fundamentals through the market).

## 5. Verdict → the lever (and one measured dead end that shaped it)

The diagnosis says: **treat NO1/NO3 as pockets behind the NO2 gateway** — anchor
their water value on NO2 (the zone they physically export through) and restore
their tail-day import capability. Two profile-gated mechanisms, one paired zone
treatment (the SK/BE/SI precedent):

1. **Gateway anchor (`anchor_gateway = "NO2"`)** — reference the opportunity
   anchor on NO2 alone. **A first attempt used the existing
   `anchor_include_dropped`** (weight ALL dropped Nordic borders by import
   flow), and the coupled A/B **rejected it**: the import-flow weighting drags
   the reference to the cheap SE/FI level, so it doubled the winter underprice
   (NO1 winter bias −43→−87) and destroyed the summer shape (corr 0.83→0.11)
   even while it improved the annual MAE. That failure **is the evidence** that
   the weighting must be gateway-specific, not a Nordic average — the new
   `anchor_gateway` field references only NO2.
2. **`import_backstop`** — restore the interior zones' demonstrated tail-day
   import capability as elastic supply above the tranches (kills the spring-
   drawdown phantom-cap knife-edge; the cv17 fix DK1/DK2/CH/AT/SI already carry).

`NORWAY_ANCHORED_PROFILE` on NO1/NO3, gated by `EUPHEMIA_DISABLE_CV23`. **NO5 was
measured WORSE** under the treatment (corr 0.72→0.64) and stays plain
NORWAY_PROFILE; NO2 (gateway) and NO4 (isolated) untouched. A residual the
gateway anchor CANNOT fix: the anchored water value is clamped ≤ gas SRMC, so on
genuinely-scarce continental winter days (realized NO1 €135 > gas SRMC ≈ €95) the
interior zones still underprice — a structural ceiling, flagged for a follow-up
(let the coupled scarcity lift the anchor above gas SRMC).

Pre-registered gate in `GATE.md`; A/B result in §6.

## 6. A/B result

Full results in `results.md` (scored table `tbl_ab_gateway_scored.tsv`). Summary of the
coupled 13-day A/B:

- **Attempt 1 (blunt `anchor_include_dropped`): REJECTED** — the import-flow
  weighting drags the reference to the cheap SE/FI level (NO1 winter −43→−87,
  summer corr 0.83→0.11). It localised the fix to a gateway-specific weighting.
- **Attempt 2 (gateway anchor NO2 + backstop): FAILS the gate** — NO1 corr
  0.10→0.12 (< 0.30), MAE 367→86, all guards clean. The entire MAE win is the
  backstop's dry-May cap removal; **the anchor makes non-May WORSE** (corr
  0.746→0.533) because anchoring the hydro *offer* ≠ setting the clear price, and
  the gas-SRMC clamp only lets re-anchoring push the scarce winter *down*.
- **Attempt 3 (backstop-only, NO1/NO3): the clean minimal win.** NO1 MAE 340→73
  / bias +298→+30; NO3 corr 0.16→0.48 / MAE 314→46; dry-spring NO1 MAE 883→162;
  **every other zone byte-identical** (backstop inert off the tail — verified
  bit-identical on a guard day). Passes the phantom-cap gate (2) + guards (3,4);
  **fails the corr gate (1)** — 0.168 < 0.30 — which no lever meets.

**Gate verdict.** The re-anchoring levers fail and are shipped-as-negatives. The
import backstop passes its scoped phantom-cap objective + guards but not the corr
criterion (a separate problem). It is the one clean, cv17-precedented improvement
and is the cv23 ship candidate; the full-year corr≈0 stays open (§7).

## 7. What would actually fix it — the mechanism/data gap

The headline full-year NO1 corr ≈ 0 has two roots and the built levers reach
neither cleanly:

1. **Winter underprice — the gas-SRMC clamp (structural ceiling).** The anchored
   water value is `clamp(ref × (share+dryness), 2, gas_srmc)`. On genuinely-scarce
   continental-coupled winter days realized NO1 is €135 while gas SRMC ≈ €95, so
   the model *cannot* reach the price no matter what it anchors on. **Fix
   (new mechanism):** let the coupled continental scarcity lift the interior
   zones' water-value ceiling above gas SRMC on days when the pass-1 reference
   itself exceeds it — i.e. replace the `gas_srmc` cap with `max(gas_srmc,
   ref)` for the `:hydro`-anchored zones. This is a targeted clamp change, not a
   re-anchor; it must be gated and guarded against manufacturing summer scarcity.
2. **Summer decoupling — the corridor-congestion model (mechanism).** In surplus
   months NO1 decouples *below* NO2 because the NO1→NO2 internal corridor
   saturates. The book has no representation of the internal Norwegian corridors
   (all dropped as flow-based residuals). A proper fix models the NO1↔NO2↔NO5
   internal cuts endogenously (the "flow-based domain" the repo already flags as
   the eventual Nordic fix), or supplies a directed corridor-capacity-limited
   export outlet so NO1's surplus prices at the congested-corridor shadow value.
3. **The real water value — the data gap.** A first-principles Nordic price is the
   SDP water value over **inflow forecasts** (SINTEF EMPS/ProdRisk). ENTSO-E
   publishes weekly reservoir *levels* (used here) but **no inflow forecast**, so
   a true water-value model is not buildable from the current feeds. Acquiring an
   inflow/snowpack feed (e.g. NVE hydrological forecasts) is the data prerequisite
   for closing the seasonal residual from fundamentals rather than through the
   coupled proxy.

**Shippable now:** only the import backstop (Attempt 3) — a real de-risking of the
phantom-cap regime, well within the cv17 precedent. The corr fix is deferred to
items 1–2 above with the data note in item 3.
