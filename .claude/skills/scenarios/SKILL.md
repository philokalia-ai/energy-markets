---
name: scenarios
description: Run counterfactual scenarios and common analysis tasks on the Euphemia market model — add/remove capacity or demand, reprice a firm's bids, re-clear the 39-zone EU footprint offline, score accuracy, and compare scenario runs. Use whenever the user asks "what would prices be if …", wants a scenario/counterfactual/what-if exercise, an accuracy eval, or a re-clear of some days.
---

# Scenario modelling & common tasks in this repo

Everything below runs **offline** on the public DuckDB extract — no Postgres
needed. Full reference: `docs/scenario-api.md` (worked examples with measured
deltas), `docs/code-map.md` (where code lives), `docs/reproducibility.md`.

## Setup (once per machine)

`./setup.sh` downloads the public extract and instantiates Julia deps.
**Prefer the extract over live Postgres for ALL experiment work** — it is
4-10x faster for book builds and cannot disturb production. Get CURRENT data
with `bin/pull_live_extract.sh` (daily-refreshed, sha256-verified from
data.philokalia.ai), then point `EUPHEMIA_DUCKDB_PATH` at it. The
library auto-detects `data/extracts/euphemia-public.duckdb`; results are
written to a separate `data/results.duckdb` (the source extract stays
read-only). For current data instead of the frozen artifact:
`./setup.sh --live`.

## The five scenario hooks (`ZoneScenario`)

```julia
using Euphemia, Dates
ZoneScenario(;
  load_modifier      = (ts, mw) -> mw,        # reshape demand at the source
  renewable_modifier = (ts, mw) -> mw,        # reshape RES forecast
  extra_orders       = ctx -> SimpleOrder[],  # inject supply OR demand orders
  strategist         = ctx -> ...,            # rewrite ANY owner's offers
  fleet_modifier     = (zone, gens) -> gens)  # add/remove/derate units as data
```

- `extra_orders` ctx: `(zone, day, timeslots, resolution_minutes, load_by_time,
  renewable_by_time)`.
- `strategist` ctx: `(tagged_orders, zone, day, timeslots, load_by_time,
  renewable_by_time, firm_of)` — **NO `resolution_minutes`** (take it from an
  existing order: `first(ctx.tagged_orders)[1].resolution_code`). A closure
  that references a missing field throws and the zone is SILENTLY DROPPED
  from the book — if a zone returns zero prices, check this first.
- `strategist` REPLACES the tagged order list. Tags: unit codes for unit
  orders, `"RES"`, `"IMPORT"`, `"DEMAND"`, `"BACKSTOP"`, `"EXTRA"`;
  plain `Vector{SimpleOrder}` returns are re-tagged
  `"STRATEGIST"`. `ctx.firm_of` maps unit code → firm (from
  `simulations.unit_firms` in the extract).
- `fleet_modifier` runs AFTER fleet completion/truthing on purpose — removed
  units are not silently re-added.

## Single-zone scenario (fast: seconds)

```julia
solar = (ts, v) -> (8 <= parse(Int, ts[10:11]) <= 17) ? v + 300.0 : v  # +300 MW solar
prices = generate_energy_prices("GR", Date(2026, 1, 26);
    order_method=:merit_order, save_to_db=false, renewable_modifier=solar)
```

## Multi-zone EU scenario (the real thing: HiGHS default ~500 s/day, Gurobi ~10 s/day)

```julia
FOOTPRINT = ["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR",
  "HU","LT","LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1",
  "SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH",
  "IT-Calabria","IT-Sicily","IT-Sardinia","CH"]
ships = ctx -> ctx.zone == "GR" ?
    [SimpleOrder(:demand, 3000.0, 200.0, Symbol(ctx.zone),
        DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes)
     for ts in ctx.timeslots] : SimpleOrder[]
result = run_multi_zone_market_clearing(Date(2026, 4, 3); zones=FOOTPRINT,
    order_method=:merit_order, enrich_network=true, passes=2,
    scenario=ZoneScenario(extra_orders=ships), save_to_db=false)
result.market_prices["GR"]   # Dict timeslot => €/MWh
```

Two-pass propagation is emergent: a scenario in one zone moves the anchored
zones' pass-2 water values through the pass-1 reference — footprint-consistent.

## Comparing runs / labelling

- Save labelled runs with `save_to_db=true` + a distinct `clearing_mode=`
  kwarg (e.g. `"my_scn_base"` / `"my_scn_treat"`); offline they land in
  `data/results.duckdb` under `simulations.energy_prices`.
- Compare two labels: `bin/scenario_delta.jl` (load-weighted €/MWh delta +
  annualized €m). Worked exercises: `docs/experiments/scenario-exercises/`.
- ALWAYS run a base arm with the same code/days — never compare against a
  backfill made by different code.

## Accuracy / eval tasks

- One zone-day quickly: `julia --project=. test/scripts/eval_pricing_accuracy.jl merit_order "2026-01-26" GR`
- Per-zone corr/MAE/bias over a window vs a saved label:
  `julia --project=. test/scripts/eu_eval_metrics.jl <clearing_mode> <cv> <start> <end> new all`
  (resolution-aware actuals — the committed convention; needs Postgres for
  actuals unless the window is inside the extract).
- Reproduce the published record: `julia --project=. bin/reproduce.jl --quick`
  (diffs against committed reference metrics in `results/`).

## Pitfalls (each one cost us a debugging session)

1. Never write to the source extract — writers no-op read-only; results go to
   `data/results.duckdb` (`EUPHEMIA_RESULTS_DB` to override).
2. The frozen extract covers 2023-01-01…2026-06-30 — days outside it fail on
   missing inputs. `./setup.sh --live` gets current data.
3. `:merit_order` is the only extract-supported order method (`:uc_based` /
   `:alternative` need Postgres write paths).
4. Multi-zone runs on HiGHS by default: since cv20 the canonical EU-footprint
   mode is **per-period decomposition** (bit-identical across solvers, so the
   record is solver-invariant), which HiGHS solves fine — just ~50× slower than
   Gurobi (~500 s/day vs ~10 s). Only the legacy *monolithic* whole-day MILP
   needs Gurobi (HiGHS finds no incumbent there). Use `optimizer="gurobi"` for
   the faster path if licensed.
5. Scenario hooks default to `nothing` — the no-scenario path is byte-identical
   and guarded; keep it that way when editing the hook plumbing.
6. Model-behaviour changes bump `ENERGY_PRICES_CODE_VERSION` (ledger in
   `src/db/postgres_core.jl`); scenario runs NEVER do — they are labelled by
   `clearing_mode`, not by cv.
