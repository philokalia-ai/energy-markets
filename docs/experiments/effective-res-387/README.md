# The effective-RES component contract (#387, #390 §1)

**Date:** 2026-09-13 · **Branch:** `feat/effective-res-387` · **Code:** cv40 (no
`code_version` bump — the record path is unchanged, see the identity check below)

## The defect

`create_merit_order_book` built two different renewable pictures and used them
for two different things:

- the **supply stack and residual demand** read the *effective* series — the
  14.1.D rows plus the weather fill, the cv32 input corrections and any scenario
  modifier;
- the **cv31 solar-regime gate** re-derived its own signal from the *raw* rows
  (`production_type == "Solar"`).

On the forecast track those are not the same day. Two concrete consequences:

1. **Weather track.** `weather_scenario` replaces every zone's RES with the
   weather-model prediction through the aggregate `renewable_modifier`. The book
   therefore cleared on weather RES while the regime gate judged the TSO's own
   solar forecast. The scheduled pre-gate run (`daily-forecast.yml`, 06:30 UTC,
   7 leads) is a weather-track run, so this was live every day.
2. **RES fill.** The fill merged weather RES only into hours with *no* RES row
   at all, tagged `production_type = "WeatherFill"` — a type the regime gate does
   not recognise as solar. A RES-short zone got effective solar in the stack and
   none in the gate, and a zone that published wind but not solar was never
   filled for solar at all.

## The contract

One effective renewable series per zone-interval, carried **per component**
(`:solar` / `:wind` / `:other`) with its provenance, built once in Stage 2 and
read by everything downstream — `src/merit_order/effective_res.jl`.

- **Provenance on the row.** `RenewablesGenerationForecast` gained a `source`
  field: `:tso`, `:persistence` (a NULL reconstructed from the zone/type's own
  latest published value), `:absent` (the type published nothing usable and the
  row stands at 0 MW) or `:weather_fill`. This is what makes a **genuine
  published zero** distinguishable from a **missing value coalesced to zero** —
  the distinction the per-component fill needs.
- **Fill by component-hour.** `res_fill` now returns
  `Dict{Symbol,Dict{String,Float64}}`; each component-hour is filled iff that
  component is not covered there. The legacy combined `Dict{String,Float64}` is
  still accepted, still reaches supply and residual demand, and deliberately
  does **not** reach the solar axis: its split is unknown, and guessing one
  quietly is what this change exists to stop.
- **Components reconcile to the aggregate.** The aggregate stays whatever the
  existing pipeline produced (so no price moves from the plumbing), and the
  components are scaled to sum to it. `alloc` records how: `:exact`,
  `:pro_rata` (an aggregate-level hook moved the total and its delta was split
  by pre-modifier share — a *declared convention*, not a measurement) or
  `:unallocated`.
- **A component hook.** `res_component_modifier(timeslot, component, mw)` is the
  exact twin of `renewable_modifier` for scenarios that mean solar or wind
  specifically. `weather_scenario` now uses it, so the weather track replaces
  solar with weather solar and wind with weather wind, consistently.
- **cv32 corrections split.** The input corrections are per target (solar/wind)
  in the source table; the aggregate application is unchanged, and the per-target
  deltas now also reach the component series, so a corrected-solar hour is a
  solar hour to the gate. (IT-Sicily / IT-Sardinia are the opted-in zones — this
  matters for the #390 §2 Sicily trace.)

## What was measured

**Record path: unchanged.** The new effective axis vs the pre-#387 raw-row axis,
on real data, 6 regime zones × 4 days (2025-12-03, 2026-02-24, 2026-05-14,
2026-06-21), **24 zone-days / 576 hour-cells**:

| max \|Δ share\| | regime-state flips |
|---|---|
| 2.2 × 10⁻¹⁶ (one ulp) | **0 / 576** |

No fill, no scenario and no corrections apply in DE_LU/FR/PL/BE/CZ/CH, so the
record backfill is untouched. No `code_version` bump.

**Weather track: the axis moves where it should.** Old axis (TSO solar ÷ model
load) vs new (weather solar ÷ model load), same 6 zones × 5 days on real
open-meteo vintages, **720 zone-hours**:

| mean \|Δ share\| | max | regime turns ON | regime turns OFF | flipped |
|---|---|---|---|---|
| 0.018 | 0.150 | 3 | 15 | **18 (2.5%)** |

The gate was firing on TSO solar in 15 hours the weather model does not call
sunny, and missing 3 that it does. Those 18 hours are where the pre-gate run's
RES block, run-of-river and deepest must-run tranche price at the negative floor
— or no longer do.

**Per-component fill: rare but real.** Component-hours in the year to
2026-09-01 where a zone that normally publishes a component is missing it *while
the other component is published* — i.e. unfillable under the old per-hour rule,
fillable now (39 zones, live extract):

| | hours | zones |
|---|---|---|
| solar absent, wind present | 458 | BG 265, DK2 96, PL 48, FR 25, PT 23, DE_LU 1 |
| wind absent, solar present | 384 | ES 264, BG 40, DK1/DK2/CH 24 each, HU 8 |

At day granularity only 8 zone-days a year are affected, so this is an
hours-within-a-day correction, not a fleet-wide one. Most of the 1,088
raw partial-coverage zone-days in the same window are zones with no wind or no
solar fleet at all — correctly not "gaps".

## What is NOT claimed

No price-accuracy gain. The forecast books in the 18 affected zone-hours change,
and the mechanism they change is the cv31 floor, but a forecast A/B against
settled prices over a meaningful panel has not been run. That belongs with
#390 §3's deployment-faithful evaluation, not here.

## Tests

`test/test_effective_res.jl` (209 assertions, no DB, no solver):

- published zero is coverage, coalesced zero is not;
- a published wind row no longer blocks an absent solar one;
- the legacy combined fill stays out of the solar axis;
- components reconcile to the aggregate at 15/30/60-minute resolution and
  after down-aggregation to the hourly clearing grid;
- **the acceptance criterion:** a solar perturbation moves supply, residual
  demand *and* the solar share; a wind perturbation of the same size moves
  supply and residual demand and leaves the share where it was;
- an aggregate modifier is split pro rata and the book says `alloc=:pro_rata`;
- with no hooks, the effective axis reproduces the pre-#387 raw-row gate exactly.
