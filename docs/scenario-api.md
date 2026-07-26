# Scenario / counterfactual API

Two questions this API answers, on the **multi-zone EU footprint** (not just a
single isolated zone):

1. *Can a participant adjust their bids?* — yes: the `strategist` hook rewrites
   any owner's offers; `load_modifier` / `renewable_modifier` reshape demand /
   RES.
2. *Can we add or remove capacity / demand?* — yes: `extra_orders` injects
   supply or demand as orders; the new **`fleet_modifier`** adds / removes /
   derates physical units as data.

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
hooks (see the "Scenario hooks" section of CLAUDE.md); `extra_orders` and
`strategist` both carry `ctx.zone`, so one function can serve the whole
footprint.

## Two-pass correctness and the emergent propagation

The EU footprint is cleared in **two passes**: pass 1 clears the standard books;
opportunity-anchored zones (Norway/Sweden-south `:hydro`, France `:nuclear`,
alpine `:hydro`) then re-bid their dominant modulating resource at the *pass-1
coupled reference price* and the footprint is re-cleared.

The scenario is applied on **both** passes. A zone that the scenario changes is
rebuilt with its scenario in pass 2 too; and — the emergent property — because
a scenario that moves a zone's **pass-1** price feeds the anchor references that
every anchored zone reads in pass 2, the counterfactual produces
**scenario-consistent opportunity costs across the whole footprint**, not just
in the zone you edited.

**Measured** (2026-04-03, cluster DE_LU/NO2/NL, HiGHS two-pass): injecting
+4,000 MW of inelastic demand in **DE_LU** raises DE_LU's own price by
**+€8.17/MWh** and lifts **NO2**'s anchored `:hydro` water value by
**+€3.60/MWh** — even though the scenario never touched a single NO2 order.
NO2's stored water simply prices at the (now higher) export opportunity.
(Regression-guarded in `test/test_multi_zone_scenario.jl`, gated
`MZ_SCENARIO_SOLVE=1`.)

## `fleet_modifier` semantics (physical reality vs truthing)

`fleet_modifier` runs **after** fleet completion and fleet-truthing. Those two
mechanisms true the registry to the zone's recently-observed capability, and
they must operate on the **pre-scenario** registry. If the modifier ran first,
removing a 500 MW unit would enlarge the completion gap and the `:installed`/p95
truth-up would silently re-add the same aggregate MW — nullifying the edit.

Running it last makes scenario edits genuine **physical reality changes**: the
offered fleet is exactly what the modifier returns. Measured on DE_LU (which
uses `fleet_truth_mode=:installed`, so hard coal is completed to 21 GW): removing
one 514 MW hard-coal unit drops the offered supply by **exactly 514 MW/slot** —
not re-added by completion.

---

## Worked examples (each ≤ 10 lines)

Set up once (offline against the public DuckDB extract):

```julia
using Euphemia, Dates
configure_data_store!(backend=:duckdb,
    duckdb_path="data/public/euphemia-public-v1.1.duckdb", read_only=true)
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
    order_method=:merit_order, enrich_network=true, passes=2, optimizer="highs",
    scenario=ZoneScenario(extra_orders=ships))
```

**Measured deltas** (2026-04-03, day-mean €/MWh, enriched multi-zone clear over
GR + its coupled SEE neighbours `[GR, BG, RO, HU]` — none opportunity-anchored,
so a single pass is exact; HiGHS, both clears `:optimal`):

| zone | baseline | +200 MW ships in GR | Δ €/MWh |
|------|---------:|--------------------:|--------:|
| GR   | 131.34   | 133.96              | **+2.62** |
| BG   | 131.34   | 133.96              | +2.62 |
| RO   | 131.34   | 133.96              | +2.62 |
| HU   |  84.96   |  84.96              |  0.00 |

The demand lands in GR, but GR, BG and RO form one **uncongested** price island
(all €131), so the +200 MW lifts all three by the same +€2.62 through the
endogenous cross-border flows — that is market coupling, reproduced by the
counterfactual. HU sits behind a **binding** constraint at €85 that hour-set and
is unmoved: the ripple reaches exactly the zones coupled to GR, and stops at the
congestion. (Run on a GR-coupled sub-footprint for a fast, `:optimal` HiGHS
clear; the identical call with `zones=FOOTPRINT` clears the full 39 zones — see
the note on solver budget below.)

### (ii) "What if the incumbent PPC marked up 20%?"

A `strategist` on GR that multiplies the offer price of every supply order owned
by a PPC unit by 1.2 (the `firm_of` map comes from `simulations.unit_firms`):

```julia
ppc = ctx -> [(o.type == :supply && get(ctx.firm_of, tag, "") == "PPC" ?
        SimpleOrder(o.type, o.price*1.2, o.quantity, o.zone, o.date_time, o.resolution_code) : o,
     tag) for (o, tag) in ctx.tagged_orders]

result = run_multi_zone_market_clearing(day; zones=FOOTPRINT,
    order_method=:merit_order, enrich_network=true, passes=2, optimizer="highs",
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
    order_method=:merit_order, enrich_network=true, passes=2, optimizer="highs",
    scenario=Dict("GR" => ZoneScenario(fleet_modifier=retire)))
```

To add a plant instead, `push!` a new `Generator` onto `gens` and return it; to
derate, return the unit with a reduced `p_max`.

---

## Single-zone parity

The same five hooks remain available as loose kwargs on the single-zone
`generate_energy_prices(zone, day; order_method=:merit_order, load_modifier=…,
renewable_modifier=…, extra_orders=…, strategist=…, fleet_modifier=…)` path —
unchanged, plus the new `fleet_modifier`.

## Analyzing scenario outputs — the counterfactual-on-the-counterfactual workflow

The full loop is three beats:

1. **Define** a scenario with the hooks (`load_modifier` / `renewable_modifier`
   / `extra_orders` / `strategist` / `fleet_modifier`, or a `ZoneScenario`
   bundling them).
2. **Run** it labeled: pass a distinct `clearing_mode` label so baseline and
   counterfactual rows coexist in `simulations.energy_prices`
   (single-zone: `generate_energy_prices(zone, day; save_to_db=true,
   clearing_mode="my_scenario", load_modifier=…)`). Offline, results persist to
   `data/results.duckdb`.
3. **Analyze** with `queries/load_weighted_price_delta.sql`: given two
   `clearing_mode` labels, a zone and a date window, it returns the
   load-weighted average price of each run, the load-weighted **delta**
   (€/MWh — "how much more people pay per MWh", weighted by the model's own
   demand series, the day-ahead load forecast) and the window + annualized
   extra cost in €m. Wrapper:

   ```bash
   julia --project=. bin/scenario_delta.jl <baseline_label> <scenario_label> \
       <zone> <start> <end_exclusive>
   julia --project=. bin/scenario_delta.jl gr_scn_base gr_scn_dc574 GR 2025-07-01 2026-07-01
   ```

Two complete worked exercises live in
[`docs/experiments/scenario-exercises/`](experiments/scenario-exercises/README.md)
— a 574 MW always-on data center in GR (`load_modifier`; **+19.46 €/MWh
load-weighted, ≈€986m/yr**, of which +4.00 from 16 scarcity hours at the cap)
and cold ironing at the 21 monitored Greek ports (`extra_orders` sized by a
measured hourly OPS profile — the real-data incarnation of example (i) above;
**+2.90 €/MWh, ≈€148m/yr**). Both offline single-zone runs on the living
extract (fixed historical imports — upper-end deltas). Copy either script to
run your own scenario in minutes.

## Deferred (honest notes)

- **`:merit_order` only.** Scenarios thread through the merit-order book (single
  and multi-zone). `:uc_based` / `:alternative` are not wired.
- **Pipelined backfill: scenario-aware.** `run_pipelined_backfill(...;
  scenario=)` threads a `ZoneScenario` (or per-zone Dict) into both book stages,
  so long counterfactual backfills run at full pipeline throughput (used for
  the EU-coupled exercises: 730-day 39-zone runs at ~155-204 days/h). `nothing`
  stays byte-identical. Two worker-side notes: an explicitly-set
  `EUPHEMIA_FLOW_ASOF_MODE` is forwarded to the workers (they bypass the
  EU-footprint scoped `:v2` default), and workers load `Dates` so hooks
  referencing `DateTime` resolve — keep hooks to Euphemia exports, `Dates`,
  and plain captured data (a hook that throws on a worker gets its zone
  silently dropped from the coupled book).
- **Solver budget on the full 39-zone footprint.** The scenario threading is
  solver-agnostic and identical whatever the footprint size; only the MPCC solve
  cost scales. Since **cv20 the canonical EU-footprint mode is per-period
  decomposition** (default), and it is **bit-identical across HiGHS and
  Gurobi** — so the full 39-zone scenario clear runs on the bundled open-source
  **HiGHS** (default), just slower (~500 s/day vs Gurobi's ~10 s). Gurobi is the
  faster development option via `optimizer="gurobi"` (respecting the WLS session
  cap — a running backfill may already hold several sessions). Only the legacy
  *monolithic* clear needs Gurobi (HiGHS finds no incumbent on the whole-day
  39-zone MILP); the decomposed default sidesteps that entirely.
