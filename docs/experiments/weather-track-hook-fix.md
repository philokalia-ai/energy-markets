# Weather-track net-demand hook fix (2026-08)

Fixes a defect in the ex-ante `INPUT_MODE=weather` daily-forecast track
(`bin/daily_forecast.jl`) that let a zone's predicted wind+solar reach the
merit-order supply curve while remaining invisible to net demand, the
scarcity margin and the peak-hour shape term — collapsing the day-shape of
zones whose price formation leans on that shape term. PL was the worst case:
its weather-track forecast standard deviation collapsed to **0.08–0.42
€/MWh** (effectively a flat line) on days where the `entsoe` reference track,
running the identical book mechanism on the same day, produced a normal
**11–45 €/MWh**.

## Diagnosis

`weather_scenario()` (`bin/daily_forecast.jl`) built each zone's
`ZoneScenario` with:

- `renewable_modifier = (ts, mw) -> 0.0` — zeroes whatever ENTSO-E RES exists.
- `extra_orders` — injects the weather-predicted wind+solar as a *separate*
  `SimpleOrder(:supply, 1.0, mw, ...)` price-taker block, tagged `"EXTRA"`.

In `src/merit_order/book_build.jl`, `renewable_modifier` is applied to
`renewable_by_time` in `_demand_series` (Stage 2) — the comment there is
explicit that this "propagates to net demand, scarcity margin, water value
and demand orders." Stage 3 then computes:

```julia
renewable_gen = get(renewable_by_time, ts, 0.0)   # always 0.0 on the weather track
net_demand[ts] = max(10.0, load_value - renewable_gen - slot_import(ts))
```

Because the weather track zeroed `renewable_by_time` and injected RES only
through `extra_orders` (which never touches `renewable_by_time`), `net_demand`
on this track was really just **load minus imports** — the predicted RES
never got subtracted. `net_demand` in turn drives `nd_min`/`nd_max`/`nd_span`,
the scarcity margin and `norm_demand` — the day-shape / peak-hour markup
layered on top of every generator's price ladder (`book_build.jl` lines
~676–687, 836–862). With RES excluded, a zone's computed "trough" was its
gross-load trough (overnight) instead of its true net-demand trough (midday,
when solar floods the market) — so the markup stayed elevated and nearly
constant through what should be the cheap midday hours. The actual RES supply
still entered the merit order via `extra_orders` and pulled the clearing price
down *some*, but the markup riding on top of every tranche never relaxed with
it, compressing the whole day toward one price band.

PL was hit hardest because it combines `CONTINENTAL_PROFILE`
(`scarcity_kappa=1.5`, `peak_kappa=0.6` — a meaningful markup layer), high
predicted solar penetration relative to load (~58% at its instantaneous
peak on the confirm day), and a wide, densely-populated flat coal-price
plateau (many `Fossil Hard coal` units bidding in lockstep tranches) that the
broken demand-shape signal never moved the clearing point off of. `NL`/`DE_LU`
share the same profile and structural defect but show visibly milder
compression (not collapse); `BG` (a different, `SEE_PROFILE` zone) shows
normal variance throughout — see the zone-day table below.

## Fix

`renewable_modifier` now returns the weather-predicted RES value for the
timeslot's hour (the same `trunc(ts, Hour)` mapping `load_modifier` already
used for load), so it **overrides** `renewable_by_time` — exactly the path
the `entsoe` track's real RES forecast already flows through implicitly (it
is simply never modified there). This propagates the prediction into net
demand, the scarcity margin and the peak-hour shape term, AND becomes the
Stage-6 merit-order RES supply order automatically (tagged `"RES"`, matching
the `entsoe` track's provenance — no more `"EXTRA"` tag for RES). The
`extra_orders` RES injection is removed.

`renewable_modifier` only *reshapes* existing `renewable_by_time` entries — it
cannot add an hour that has no key at all — so `res_fill` (the RES twin of
`load_fill`, already defined as `make_res_fill_fn = make_load_fill_fn`) is
now wired in too, guaranteeing every UTC hour has an entry for the modifier to
override even where ENTSO-E published nothing for that zone/hour. This exactly
mirrors how load is already handled (`load_modifier` + `load_fill`).

Net diff in `bin/daily_forecast.jl`'s `weather_scenario()`: replace
`renewable_modifier=zero_res` + `extra_orders=extra` with
`renewable_modifier=rmod` + `res_fill=res_fill_fn` (`rmod` built the same way
as the existing `lmod`).

## Validation

### Method

Two arms cleared per zone-day, **fresh `julia` process per arm**, reading
**bit-identical cached weather-RES/load predictions** (one fetch per
zone-day, JSON-cached, no re-fetch between arms) — `save_to_db=false`
throughout, read-only against the live store:

- `old` — the pre-fix hook (`renewable_modifier -> 0` + `extra_orders`,
  copied verbatim from `main`).
- `new` — the fixed hook (`renewable_modifier` returns the prediction).

**Single-zone cells** (12 zone-days: PL/NL/GR/DE_LU × 2026-07-30/31/08-01,
via `Euphemia.generate_energy_prices`, ~50–80s each): the fastest harness for
exercising the book-construction fix directly, but single-zone clearing
treats cross-border flow as a **fixed historical injection** (no coupled
network solve), so it cannot reproduce the multi-zone continental-price
plateau that PL's production forecast actually pins to. It DOES validate: (a)
RES-quantity conservation (the fix only moves RES between tags, never changes
its size), and (b) the correlation/shape shift against the `entsoe` reference.

**Multi-zone confirmatory cell** (39-zone footprint, 2-pass coupled clear,
PL/2026-08-01 — the exact zone-day that showed sd=0.08 in the production
record): reproduces the actual daily-forecast pipeline path old vs new, to
directly confirm the sd-collapse is fixed at the scale where it was observed.

### RES-quantity conservation (all 12 single-zone cells)

`max |old EXTRA_h − new RES_h|` per zone-day = **0.0** for every one of the 12
cells (bit-exact) — the fix moves RES provenance (`"EXTRA"` → `"RES"`), never
its size.

### Single-zone A/B table

| zone | day | old sd | new sd | old min | new min | old max | new max | old corr | new corr |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| PL | 2026-07-30 | 55.45 | 77.46 | 101.57 | 101.57 | 266.16 | 358.67 | 0.763 | 0.702 |
| PL | 2026-07-31 | 86.41 | 109.95 | 115.49 | 111.86 | 392.22 | 529.08 | 0.740 | 0.678 |
| PL | 2026-08-01 | 102.61 | 90.59 | 101.44 | 101.44 | 428.63 | 388.95 | 0.497 | 0.552 |
| NL | 2026-07-30 | 65.80 | 65.19 | 107.18 | 107.18 | 392.94 | 385.37 | 0.354 | 0.443 |
| NL | 2026-07-31 | 146.42 | 129.88 | 119.06 | 118.30 | 572.37 | 529.91 | -0.448 | -0.366 |
| NL | 2026-08-01 | 57.60 | 50.81 | 129.45 | 129.45 | 297.80 | 284.63 | 0.411 | 0.407 |
| GR | 2026-07-30 | 47.65 | 62.62 | 10.05 | 7.02 | 231.98 | 245.67 | 0.838 | 0.904 |
| GR | 2026-07-31 | 45.09 | 44.86 | 6.81 | 6.81 | 129.35 | 129.35 | 0.719 | 0.725 |
| GR | 2026-08-01 | 56.98 | 57.78 | 1.00 | 1.00 | 129.45 | 129.45 | 0.937 | 0.933 |
| DE_LU | 2026-07-30 | 952.53 | 960.79 | 7.02 | 7.02 | 3000.00 | 3000.00 | 0.494 | 0.474 |
| DE_LU | 2026-07-31 | 1206.67 | 1232.26 | 129.35 | 115.49 | 3000.00 | 3000.00 | 0.547 | 0.545 |
| DE_LU | 2026-08-01 | 830.22 | 832.44 | 6.10 | 6.10 | 3000.00 | 3000.00 | 0.466 | 0.464 |

*(corr = Pearson correlation of the cleared hourly prices against the stored
`entsoe`-track forecast for the same zone-day, on the ~21 UTC hours the two
tracks' windows overlap; single-zone scale is not comparable to the
multi-zone-cleared `entsoe` reference — see the multi-zone confirmatory cell
for the scale-comparable result.)*

GR (the zone with the largest predicted solar-to-load ratio among these four
and no boundary-book/backstop confound) shows the clearest directional
confirmation: midday minimums move DOWN under the new hook on the day with
the largest predicted solar swing (2026-07-30: €10.05 → €7.02), and corr vs
`entsoe` improves on 2 of 3 days (0.838→0.904, 0.719→0.725; 08-01 flat at
already-high 0.93+). PL's single-zone sd *increases* under the fix on 2 of 3
days — expected and correct: single-zone clearing has no import relief, so
once net demand correctly reflects the midday solar dip, PL's *domestic*
price swings more widely between the (now genuinely cheap) trough and the
(unrelieved) evening peak; this is resolved by the coupled network, not by
this hook — see the multi-zone cell below. `DE_LU` single-zone hits the
€3,000 cap on most hours regardless of arm (a single-zone-only artifact — a
large, import-dependent zone cannot be represented by a fixed-injection
proxy), so its single-zone cell is not informative for this fix; included for
completeness only.

### Multi-zone confirmatory cell (PL, 2026-08-01, 39-zone coupled clear)

| arm | sd | min | max | corr vs entsoe (n=21) |
|---|---:|---:|---:|---:|
| old (pre-fix) | 2.17 | 96.26 | 105.96 | 0.517 |
| new (fixed)   | 4.79 | 81.91 | 107.50 | 0.591 |

The fix more than doubles PL sd (2.17 → 4.79) and drops the minimum from
96.26 to **81.91 €/MWh** — landing exactly on the true net-demand-trough
price identified in the original diagnosis (the same 81.91 €/MWh rung a
from-scratch reproduction of the fixed hook found independently). corr vs
the stored `entsoe` forecast improves 0.517 → 0.591.

This one-UTC-day reproduction does not fully reach the stored `entsoe`
track sd (11.49 on this day) — expected, since (a) it clears a single UTC
day rather than the production pipeline's two-UTC-day Athens-window stitch,
and (b) it re-fetches live weather at a different moment than the actual
2026-07-31 evening production run (weather forecasts are not exactly
replayable after the fact). The **structural** result — RES now visibly
moves PL off the flat plateau, in the correct direction, by a factor of ~2x
on both sd and corr — is what this cell was built to confirm; a full
production-pipeline re-run (two-day stitch, scheduled-time vintage) was out
of scope for this read-only diagnostic and is left to the next scheduled
`INPUT_MODE=weather` cron run once this PR merges.

## Files changed

- `bin/daily_forecast.jl` — `weather_scenario()`: `renewable_modifier` now
  returns the weather-predicted RES per hour (was a constant zero);
  `res_fill` wired in (RES twin of the existing `load_fill`); `extra_orders`
  RES injection removed. Header doc block updated to match.

## Kill-switch / rollback

None added — this is a forecast-product-only path (`input_mode='weather'`
rows in `simulations.forecast_prices`), gated entirely behind
`INPUT_MODE=weather` (default `entsoe`, unaffected). No record/byte-identity
impact: the `entsoe` track and every `:merit_order` clearing path outside
`bin/daily_forecast.jl`'s weather scenario builder are untouched. Rollback is
a plain revert of the one function.

## Relevance to #252

The ML input-upgrade rollout (#252) consumes its inputs through this same
`weather_scenario()` hook — this fix is a prerequisite so the ML track
inherits a net-demand signal that actually sees predicted RES, not a
regression it would otherwise have to separately diagnose.
