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

(to be filled after the runs)
