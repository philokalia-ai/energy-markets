# Scenario / counterfactual API

Two questions this API answers, on the **multi-zone EU footprint** (not just a
single isolated zone):

1. *Can a participant adjust their bids?* — `strategist` rewrites any owner's
   offers; `load_modifier` / `renewable_modifier` reshape demand / RES.
2. *Can we add or remove capacity / demand?* — `extra_orders` injects supply or
   demand as orders; `fleet_modifier` adds / removes / derates physical units.

All of it threads through one entry point:

```julia
run_multi_zone_market_clearing(day; zones=FOOTPRINT, order_method=:merit_order,
    enrich_network=true, passes=2, scenario=...)
```

`scenario` is either a single `ZoneScenario` (applied to **every** zone — the
hooks gate on `ctx.zone` themselves) or a `Dict{String,ZoneScenario}` (per-zone
targeting). `nothing` (the default) is byte-identical to the no-scenario run.

## `ZoneScenario`

```julia
Base.@kwdef struct ZoneScenario
    load_modifier      # (timeslot, load_mw) -> Float64
    renewable_modifier # (timeslot, mw)      -> Float64
    extra_orders       # ctx -> Vector{SimpleOrder}
    strategist         # ctx -> Vector{Tuple{SimpleOrder,String}}
    fleet_modifier     # (zone, gens::Vector{Generator}) -> Vector{Generator}
end
```

The `ctx` shapes are exactly those of the single-zone `create_merit_order_book`
hooks (see `.claude/skills/scenarios`); `extra_orders` and
`strategist` both carry `ctx.zone`, so one function can serve the whole
footprint.

## Two-pass correctness and the emergent propagation

The EU footprint is cleared in **two passes**: pass 1 clears the standard books;
opportunity-anchored zones (Norway/Sweden-south `:hydro`, France `:nuclear`,
alpine `:hydro`) then re-bid their dominant modulating resource at the *pass-1
coupled reference price* and the footprint is re-cleared.

The scenario is applied on **both** passes. Because a scenario that moves a
zone's pass-1 price feeds the anchor references every anchored zone reads in
pass 2, the counterfactual produces **scenario-consistent opportunity costs
across the whole footprint**, not just in the zone you edited.

**Measured pre-cv25** (2026-04-03, DE_LU/NO2/NL — illustrative of the mechanism,
not a current magnitude): +4,000 MW of inelastic demand in DE_LU raised DE_LU by
**+€8.17/MWh** and lifted NO2's anchored `:hydro` water value by **+€3.60/MWh**
without touching a single NO2 order — NO2's stored water prices at the (now
higher) export opportunity. (Guarded in `test/test_multi_zone_scenario.jl`,
gated `MZ_SCENARIO_SOLVE=1`.)

## `fleet_modifier` semantics (physical reality vs truthing)

`fleet_modifier` runs **after** fleet completion and fleet-truthing, which must
see the **pre-scenario** registry: run first, removing a 500 MW unit would
enlarge the completion gap and the `:installed`/p95 truth-up would silently
re-add the same aggregate MW, nullifying the edit. Running it last makes
scenario edits genuine **physical reality changes** — the offered fleet is
exactly what the modifier returns. Checked on DE_LU (`fleet_truth_mode=
:installed`, hard coal completed to 21 GW): removing one 514 MW hard-coal unit
drops the offered supply by **exactly 514 MW/slot**.

---

## Worked examples (each ≤ 10 lines)

Set up once (offline against the public DuckDB extract):

```julia
using Euphemia, Dates
configure_data_store!(backend=:duckdb,
    duckdb_path="data/extracts/euphemia-public.duckdb", read_only=true)
const FOOTPRINT = [...]   # the 39-zone EU footprint (see bin/reproduce.jl)
day = Date(2026, 4, 3)
```

### (i) "Ships request 200 MW more power in GR"

Extra inelastic demand at the price cap, targeted at GR:

```julia
ships = ctx -> ctx.zone == "GR" ?
    [SimpleOrder(:demand, 3000.0, 200.0, Symbol(ctx.zone),
        DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes)
     for ts in ctx.timeslots] : SimpleOrder[]

result = run_multi_zone_market_clearing(day; zones=FOOTPRINT,
    order_method=:merit_order, enrich_network=true, passes=2, optimizer="gurobi",
    scenario=ZoneScenario(extra_orders=ships))
```

**Measured pre-cv25** (2026-04-03, `[GR, BG, RO, HU]` — the shape is the point,
the magnitudes are stale): GR/BG/RO formed one uncongested price island at €131,
so +200 MW in GR lifted all three by the same **+€2.62** through the endogenous
flows, while HU sat behind a binding constraint at €85 and did not move. The
ripple reaches exactly the zones coupled to GR, and stops at the congestion.

### (ii) "What if the incumbent PPC marked up 20%?"

A `strategist` on GR that multiplies the offer price of every supply order owned
by a PPC unit by 1.2 (the `firm_of` map comes from `simulations.unit_firms`):

```julia
ppc = ctx -> [(o.type == :supply && get(ctx.firm_of, tag, "") == "PPC" ?
        SimpleOrder(o.type, o.price*1.2, o.quantity, o.zone, o.date_time, o.resolution_code) : o,
     tag) for (o, tag) in ctx.tagged_orders]

result = run_multi_zone_market_clearing(day; zones=FOOTPRINT,
    order_method=:merit_order, enrich_network=true, passes=2, optimizer="gurobi",
    scenario=Dict("GR" => ZoneScenario(strategist=ppc)))
```

The markup only bites in hours where a PPC unit is marginal; elsewhere the
coupled import stack caps the price. This is the collusion / market-power
counterfactual — the residual vs the observed price is the candidate finding.

### (iii) Remove a 500 MW GR lignite unit

`fleet_modifier` deletes a unit from the registry (physical retirement /
outage). Because it runs after truthing, the capacity genuinely leaves:

```julia
retire = (zone, gens) -> filter(g -> g.code != "29WGU-PTOLEM--VN", gens)

result = run_multi_zone_market_clearing(day; zones=FOOTPRINT,
    order_method=:merit_order, enrich_network=true, passes=2, optimizer="gurobi",
    scenario=Dict("GR" => ZoneScenario(fleet_modifier=retire)))
```

To add a plant instead, `push!` a new `Generator` onto `gens` and return it; to
derate, return the unit with a reduced `p_max`.

---

## Single-zone parity

The same five hooks are loose kwargs on the single-zone path:
`generate_energy_prices(zone, day; order_method=:merit_order, load_modifier=…,
renewable_modifier=…, extra_orders=…, strategist=…, fleet_modifier=…)`.

## Analyzing scenario outputs

**Run it labeled**: pass a distinct `clearing_mode` so baseline and
counterfactual rows coexist in `simulations.energy_prices` (single-zone:
`generate_energy_prices(zone, day; save_to_db=true, clearing_mode="my_scenario",
load_modifier=…)`). Offline, results persist to `data/results.duckdb`.

**Then diff the two labels** with `queries/load_weighted_price_delta.sql` —
load-weighted average price per run, the load-weighted delta (€/MWh, weighted by
the model's own demand series) and the window + annualized extra cost in €m:

```bash
julia --project=. bin/scenario_delta.jl <baseline_label> <scenario_label> \
    <zone> <start> <end_exclusive>
julia --project=. bin/scenario_delta.jl gr_scn_base gr_scn_dc574 GR 2025-07-01 2026-07-01
```

Two complete worked exercises live in
[`docs/experiments/scenario-exercises/`](experiments/scenario-exercises/README.md),
re-run at cv37 on the coupled 39-zone footprint against a fresh `eu37_base`
arm:

- **574 MW always-on data center in GR** (`load_modifier`, 730 days): GR
  **+7.10 €/MWh** load-weighted (+7.4%), EU-wide **+0.29**, **€1.55bn** extra
  consumer cost over the two years. Coupled import relief absorbs ~64% of what
  an isolated single-zone run would show.
- **Pan-EU cold ironing** (`extra_orders` from a measured hourly OPS profile,
  24 zones, 365 days): EU **+0.139 €/MWh**, **€371m/yr**.

Copy either script (`eu37_scenarios.jl`) to run your own.

## Honest notes

- **`:merit_order` only.** The unit-commitment path was DELETED in cv25;
  `:merit_order` is the only order method and anything else errors.
- **Pipelined backfill: scenario-aware.** `run_pipelined_backfill(...;
  scenario=)` threads a `ZoneScenario` (or per-zone Dict) into both book stages,
  so long counterfactual backfills run at full pipeline throughput (the EU
  exercises: 730-day 39-zone runs at ~155-204 days/h). `nothing` stays
  byte-identical. Workers resolve the EU-footprint scoped `:v3` ex-ante flow
  default since cv25 (an explicit `EUPHEMIA_FLOW_ASOF_MODE` is forwarded and
  still wins), and they load `Dates` so hooks referencing `DateTime` resolve —
  keep hooks to Euphemia exports, `Dates` and plain captured data (a hook that
  throws on a worker gets its zone silently dropped from the coupled book).
- **Solver.** The scenario threading is solver-agnostic; only the MPCC solve
  cost scales with the footprint. The canonical EU-footprint mode is per-period
  decomposition (cv20), bit-identical across HiGHS and Gurobi at 60 minutes —
  but **HiGHS segfaults on the cv35 JAO 108-link network**, so a current
  39-zone footprint clear needs `optimizer="gurobi"`. HiGHS remains fine for
  single-zone and small sub-footprints (~500 s/day vs Gurobi's ~10 s).
- **Offline caveat.** The frozen public artifact (v1.1) predates the `jao.*`
  tables, so a scenario run on it clears the **pre-cv35** network and scores
  materially worse on the Core and Nordic zones. Use the living extract (which
  carries them since 2026-08-26) or Postgres when the network matters to the
  counterfactual.
