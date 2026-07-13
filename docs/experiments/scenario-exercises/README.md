# GR scenario exercises — data center & cold ironing

Two counterfactual exercises on **Greece**, expressed through the first-class
scenario API (`docs/scenario-api.md`) and run fully **offline** against the
living DuckDB extract. They are also the reference walk-through of the
**counterfactual-on-the-counterfactual workflow**: define a scenario with the
hooks → run it labeled with `clearing_mode` → analyze it with
`queries/load_weighted_price_delta.sql`.

All runs: single-zone `generate_energy_prices("GR", day; order_method=:merit_order,
optimizer="highs", save_to_db=true, clearing_mode=<label>)`, source data
read-only from `data/extracts/euphemia-live.duckdb`, results persisted to
`data/results.duckdb`. Loops are resumable (already-saved `(day, clearing_mode)`
pairs are skipped) — see `common.jl`.

| run | script | clearing_mode | window | scenario hook |
|---|---|---|---|---|
| baseline | `baseline.jl` | `gr_scn_base` | 2024-07-01..2026-06-30 (730 d) | none |
| data center | `datacenter_574mw.jl` | `gr_scn_dc574` | 2025-07-01..2026-06-30 (365 d) | `load_modifier`: +574 MW constant |
| cold ironing | `cold_ironing_ops.jl` | `gr_scn_ops` | 2024-07-01..2025-06-30 (365 d) | `extra_orders`: hourly OPS profile at the cap |

The baseline is shared: its 730-day window is the union of the two scenario
windows, so each exercise compares against baseline days of its own window.

## Exercise 1 — 574 MW always-on data center

A hyperscale data center connects in GR and draws a constant 574 MW in every
timeslot of the year 2025-07-01..2026-06-30.

**Hook choice (`load_modifier`, not `extra_orders`).** Firm always-on baseload
demand shows up in the system load forecast, so the faithful representation
edits the load series at the source: `load_modifier` propagates the +574 MW
into everything derived from load — net demand, the scarcity margin (and hence
scarcity-priced tranches) and hydro water values. `extra_orders` would be a
pure demand-curve addition: the order clears, but the book's scarcity /
water-value machinery would still price against the unmodified load. The
`extra_orders` variant is the natural cheap sensitivity if you want to bracket
how much of the delta comes from the demand curve alone (not run here).

```julia
dc_load = (ts, load_mw) -> load_mw + 574.0
generate_energy_prices("GR", day; order_method=:merit_order, save_to_db=true,
    clearing_mode="gr_scn_dc574", load_modifier=dc_load)
```

## Exercise 2 — cold ironing (onshore power supply) at Greek ports

Every in-scope passenger ship (ro-pax / high-speed / cruise) berthed at one of
the 21 monitored Greek ports connects to shore power. This is the **real-data
incarnation of the documented "ships request power" example** in
`docs/scenario-api.md` — the same `extra_orders` hook, but sized by a measured
hourly demand profile instead of a flat 200 MW.

**Hook choice (`extra_orders`).** OPS demand is new price-inelastic demand bid
at the cap (ships connect regardless of the day-ahead price); unlike the data
center there is no claim that TSO load forecasts would carry it, so the pure
demand-curve addition is the faithful modelling.

```julia
ops_orders = ctx -> [SimpleOrder(:demand, 3000.0, OPS_MW[ts[1:11]], Symbol(ctx.zone),
                         DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes)
                     for ts in ctx.timeslots if get(OPS_MW, ts[1:11], 0.0) > 0]
generate_energy_prices("GR", day; order_method=:merit_order, save_to_db=true,
    clearing_mode="gr_scn_ops", extra_orders=ops_orders)
```

### Profile provenance

`ops_hourly_gr_central_2024H2_2025H1.csv` (committed here, 8,760 rows,
`datetime_utc, ops_mw`) is derived from the ceres ships pipeline
(`ceres` repo, branch `ships-cold-ironing`, `ships/outputs/ops_load_15min.csv`,
commits "ships: commit output datasets + data dictionary" /
"add central (imputed) scenario to 15-min OPS demand export"):

- **Source**: Global Fishing Watch port-visit AIS data over 21 Greek ports,
  2023-07-01..2025-06-30; at-berth load from GT-binned EMSA figures
  (2.5 / 5 / 12 MW for medium ferry / large ferry / cruise-scale).
- **Scenario**: `power_total_central_mw` — the **central** (imputed) scenario,
  **all-21-ports** scope. Central = confirmed >5000 GT ships (floor) plus
  imputed demand of scheduled ships whose tonnage GFW never matched; it leans
  high — the floor series is ~3.3× smaller. Full-uptake (all in-scope ships
  connect).
- **Aggregation**: the four 15-min UTC slots of each hour averaged to a mean
  hourly MW.
- **Window/mapping**: the exercise window 2024-07-01..2025-06-30 lies entirely
  inside the AIS coverage, so the profile uses **actual same-date values** —
  no calendar tiling or extrapolation. (The exercise was deliberately limited
  to one year to match the data; the earlier plan to tile a second year was
  dropped.) Timestamps are UTC on both sides (Euphemia timeslots are UTC), so
  the mapping is a direct datetime join.
- **Shape**: mean 126 MW, max 369 MW, strongly seasonal — ~205–250 MW mean in
  summer months (cruise/ferry season), ~27–32 MW in winter.

## Running

```bash
julia --project=. docs/experiments/scenario-exercises/baseline.jl
julia --project=. docs/experiments/scenario-exercises/datacenter_574mw.jl
julia --project=. docs/experiments/scenario-exercises/cold_ironing_ops.jl
```

Run them sequentially (the results DB is single-writer). Each is resumable —
rerun after an interruption and it continues where it left off. Analysis
(read-only, safe anytime):

```bash
julia --project=. bin/scenario_delta.jl gr_scn_base gr_scn_dc574 GR 2025-07-01 2026-07-01
julia --project=. bin/scenario_delta.jl gr_scn_base gr_scn_ops   GR 2024-07-01 2025-07-01
```

## Results

Runs completed 2026-07-13 against the living extract (source data
2023-01-01..2026-07-12; HiGHS; ~2.6 days/s per solve loop). Day counts:
baseline 729/730, data center 364/365, cold ironing 365/365, **0 solver
failures**. The one missing day, **2025-10-08**, is an upstream data gap — the
GR day-ahead wind/solar forecast has NULL values for that day (48 of 120 rows
populated), so the book build aborts identically in baseline and scenario; it
is simply absent from both runs and drops out of the comparison. 2024-10-26/27
saved partially (21 + 2 hours, the October DST changeover gap in the source
load series), again identically in both runs; the delta query joins on hours
present in both runs, so all of this is handled.

All numbers below from `bin/scenario_delta.jl` — load-weighted by the hourly
day-ahead load forecast (the model's own demand series, unmodified baseline
load), per calendar year and total.

### Data center (+574 MW, 2025-07-01..2026-06-30, Δ = gr_scn_dc574 − gr_scn_base)

| period | hours | LW base €/MWh | LW scenario €/MWh | **Δ €/MWh** | extra cost €m | annualized €m |
|---|---:|---:|---:|---:|---:|---:|
| 2025 H2 | 4,392 | 90.77 | 106.79 | **+16.02** | 419.7 | 837.1 |
| 2026 H1 | 4,344 | 105.31 | 128.47 | **+23.16** | 563.3 | 1,135.9 |
| **TOTAL** | 8,736 | 97.77 | 117.23 | **+19.46** | **982.9** | **985.6** |

The +574 MW is ~9% of GR average load, so a double-digit delta is expected —
the GR merit curve is steep between the RES/lignite shoulder and the gas SRMC
band. Decomposition: **+15.46 €/MWh** of the total comes from ordinary
merit-order steepening across 8,720 normal hours (€781m); **+4.00 €/MWh**
comes from just 16 hours (47 quarter-hour periods) where the added demand
exhausts the offered supply and the price hits the €3,000 cap (€202m). The
scarcity tail is real signal (the extra baseload eats the reserve margin in
tight hours) but is also the first thing that import relief would shave — see
the caveat below.

### Cold ironing (OPS profile, 2024-07-01..2025-06-30, Δ = gr_scn_ops − gr_scn_base)

| period | hours | LW base €/MWh | LW scenario €/MWh | **Δ €/MWh** | extra cost €m | annualized €m |
|---|---:|---:|---:|---:|---:|---:|
| 2024 H2 | 4,391 | 106.65 | 110.26 | **+3.62** | 97.3 | 194.1 |
| 2025 H1 | 4,344 | 97.16 | 99.26 | **+2.11** | 50.8 | 102.4 |
| **TOTAL** | 8,735 | 102.16 | 105.06 | **+2.90** | **148.1** | **148.5** |

Mean OPS demand is 126 MW but strongly summer-peaked (~205–250 MW mean in
summer, ~30 MW in winter), which lands on the season when GR prices are set by
gas and A/C load — hence the 2024 H2 (Jul–Dec) delta is ~1.7× the 2025 H1
(Jan–Jun) one. No scenario hour reaches the cap. Per MW of average added load,
cold ironing costs ~€1.18m/yr/MW vs the data center's ~€1.72m/yr/MW — the
seasonal concentration into already-tight hours makes OPS MW *more* expensive
than flat MW on that margin (the DC's higher figure is partly its scarcity
tail).

### Caveats

- **Single-zone runs**: net imports are fixed at their historical values, so
  no import relief responds to the added demand. In the coupled multi-zone
  measurement of the documented +200 MW ships example, neighbours absorb part
  of the shock (+2.62 €/MWh for 200 MW). These single-zone deltas are
  therefore toward the upper end; a multi-zone rerun would soften them,
  especially the DC scarcity tail.
- **OPS profile is the CENTRAL (imputed) scenario** — it leans high; the floor
  series is ~3.3× smaller. Bracket accordingly.
- **Full uptake**: every in-scope ship connects (pre-AFIR-phase-in upper
  bound).
