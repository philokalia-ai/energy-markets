# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Julia project implementing the **Euphemia** energy market clearing engine, focusing on electricity market simulation and optimization. The project models day-ahead electricity markets with support for unit commitment, bidding strategies, and network constraints.

## Core Architecture

The main module `Euphemia` provides:

- **Market clearing optimization**: Implements the Euphemia algorithm for economic surplus maximization
- **Unit commitment solver**: Optimizes generator dispatch with technical constraints
- **Bidding strategy engine**: Converts unit commitment results to market orders
- **Network modeling**: Handles Available Transfer Capacity (ATC) constraints between bidding zones
- **Multi-zone market clearing**: Simultaneous clearing across multiple zones with cross-border transmission flows
- **Data access layer**: Database utilities for energy market data

### Key Modules

- `src/Euphemia.jl` - Main module with market clearing functions and orchestration
- `src/MPCC.jl` - MPCC (Mathematical Program with Complementarity Constraints) solver for market clearing
- `src/UnitCommitment.jl` - Unit commitment optimization using JuMP/HiGHS
- `src/BiddingStrategy.jl` - Converts UC solutions to market bids
- `src/Network.jl` - Network topology, TransferCapacity, and ATC constraints
- `src/MarketOrders.jl` - Order types (SimpleOrder, BlockOrder)
- `src/AlternativeOrderBook.jl` - Alternative (faster) order book generation
- `src/Generators.jl`, `src/Loads.jl`, `src/Renewables.jl` - Data models
- `src/dbutils.jl` - Database connection and data access

### Key Functions

**Single-zone market clearing:**
```julia
# Generate prices for a single zone
prices = generate_energy_prices("GR", Date(2024, 6, 15);
    order_method=:uc_based,  # or :alternative (faster)
    save_to_db=true,
    force_rerun=false)       # Set true to bypass UC cache

# Process all zones for a single date
result = generate_energy_prices_for_all_zones(Date(2024, 6, 15);
    force_rerun=false)       # Propagates to all zone solves

# Process a date range
result = generate_energy_prices_for_date_range(Date(2024, 6, 1), Date(2024, 6, 7);
    force_rerun=false)       # Propagates to all date/zone solves
```

**Multi-zone market clearing with transmission flows:**
```julia
# Clear multiple zones simultaneously with cross-border ATC constraints
result = run_multi_zone_market_clearing(Date(2024, 6, 15);
    zones=["GR", "BG", "RO"],  # or empty for auto-discover
    order_method=:alternative,  # :uc_based or :alternative
    save_to_db=true)

# Access results
result.market_prices["GR"]      # Zonal prices
result.transmission_flows       # Cross-border flows
result.solve_time              # Solver time
result.total_time              # Total processing time

# Process multiple dates with multi-zone clearing
result = run_multi_zone_for_date_range(Date(2024, 6, 1), Date(2024, 6, 7);
    order_method=:alternative,
    save_to_db=true)

# Parallel UC execution (requires workers)
using Distributed
addprocs(4)
@everywhere using Euphemia

# Single date with parallel UC
result = run_multi_zone_market_clearing(Date(2024, 6, 15);
    zones=["GR", "BG", "RO", "HU"],
    order_method=:uc_based,
    parallel=true)  # UC solves run in parallel, MPCC runs after all complete

# Date range with parallel UC
result = run_multi_zone_for_date_range(Date(2023, 1, 1), Date(2024, 12, 31);
    order_method=:uc_based,
    parallel=true,       # UC solves run in parallel per date
    force_rerun=false,   # Set true to bypass UC cache
    save_to_db=true)
```

**Iterative multi-zone clearing (accounts for interconnections in UC):**
```julia
# Standard approach: UC ignores interconnections, MPCC handles flows
result = run_multi_zone_market_clearing(Date(2024, 6, 15); zones=["GR", "BG", "RO"])

# Iterative approach: UC-MPCC feedback loop until prices converge
result = run_iterative_multi_zone_market_clearing(Date(2024, 6, 15);
    zones=["GR", "IT-NORTH", "IT-SOUTH"],
    max_iterations=10,       # Stop after 10 iterations max
    price_tolerance=1.0,     # Stop when max price change < 1 €/MWh
    damping_factor=0.7,      # Update smoothing (0.7 = 70% new + 30% old)
    parallel=true            # Auto-limits: 2 workers for Gurobi, half for HiGHS
)

# Check convergence
result.converged              # true if price changes < tolerance
result.iterations             # number of iterations performed
result.convergence_metrics    # (price_change, flow_change_pct)
result.final_net_imports      # final net imports per zone
```

**Convergence criterion:** Uses price-based convergence (max |Δλ| < tolerance) rather
than flow-based. This is preferred because prices are the economic fixed point of
market coupling, while flows are derived quantities that can oscillate near binding
constraints due to UC binary decisions.

The iterative approach is recommended for tightly interconnected zones where
cross-border flows significantly affect optimal unit commitment decisions.
Typical convergence: 2-5 iterations. Runtime: 2-4× longer than non-iterative.

**Zone discovery:**
```julia
# Zones with generator data (for UC/bidding)
zones = get_available_zones(date)

# Zones with transfer capacity data (for multi-zone clearing)
zones = get_zones_with_transfer_capacity(date)
```

**Generator unavailability filtering:**
```julia
# Get generators with outage filtering (default behavior)
generators = get_generators("GR", Date(2024, 6, 15))

# Disable filtering to get all commissioned generators
generators = get_generators("GR", Date(2024, 6, 15); exclude_unavailable=false)
```

The `exclude_unavailable` parameter (default: `true`) filters generators based on outage data:
- **Complete outages** (`available_capacity_mw = 0`): Generator excluded entirely
- **Partial outages** (`available_capacity_mw > 0`): Generator's `p_max` reduced to available capacity
- Only `status = 'Active'` outages are considered (ignores `Cancelled`/`Withdrawn`)
- Uses `MIN(available_capacity_mw)` when multiple outage records exist (conservative)

**Generator deduplication (overlapping validity periods):**
- ENTSO-E data can have multiple rows for the same generator with overlapping `valid_from`/`valid_to` periods
- This is a data quality issue where capacity changes create duplicate entries instead of properly versioned records
- The query uses `DISTINCT ON (generation_unit_code)` to deduplicate
- Priority: most recent `valid_from`, then highest capacity as tiebreaker
- Example: Poland's "Dolna Odra B7" had 5 overlapping entries with capacities 210-232 MW

**Date validity filter with recent generation fallback:**
- ENTSO-E data has stale `valid_from`/`valid_to` dates for some operating plants
- Example: Spain nuclear plants had `valid_from` in 2026 (future!) but were actively generating
- Example: German coal plants had `valid_to` in 2022-2024 but were still operating in 2025
- Solution: Include plants that EITHER pass the date validity filter OR have recent actual generation output
- Recent generation = output > 0 MW within the last 60 days (from `actual_generation_output_per_generation_unit`)
- This ensures operating plants are included regardless of stale validity dates
- Plants with neither valid dates NOR recent generation are correctly excluded (truly decommissioned)

**Day-level outage cache + per-zone memoization (`get_generators` performance):**
- The `active_outages` aggregation and the `stale_outage_override` set are
  **zone-independent day-level work**: a ~3 s seq-scan of the 9.4 GB
  `unavailability_of_production_and_generation_units` table (text timestamps cast
  per row). `get_day_outages(day)` computes this ONCE per market day across ALL
  zones and caches it in a module-level `Dict{Date,DataFrame}` (thread-safe, like
  `TTF_PRICE_CACHE`; never cached on DB error). Each zone's `get_generators` query
  consumes its slice as array parameters (`unnest($3,$4,$5)`) — same rows as the
  old per-zone CTEs (identity-tested for GR/DE_LU/NO1/FR + a 2022 crisis date in
  `test/test_get_generators_identity.jl`). A 39-zone EU build hit the table once
  instead of ~50 times (235 s → 145 s for the generator stage).
- `get_generators` also memoizes its result per `(zone, day, exclude_unavailable,
  exclude_variable_renewables, infer_ramp_rates_flag)` in a module-level `Dict`, so
  pass-2 anchored rebuilds and repeated builds in one process are free (they
  return a shallow copy — callers may mutate the returned vector, e.g. fleet
  completion). `Euphemia.clear_generator_caches!()` clears both caches.

The `exclude_variable_renewables` parameter (default: `true`) filters out wind and solar generators:
- **Variable renewables** (Wind Onshore, Wind Offshore, Solar) are excluded from UC
- These generators' output is non-dispatchable and handled via renewable forecasts
- Renewable generation is subtracted from load to calculate net demand for UC
- This prevents double-counting (generator in UC + forecast subtracted from load)

**Gas marginal costs from real TTF prices:**

Gas-fired generators ("Fossil Gas") use real TTF front-month futures prices from
`yfinance.ttf_f` (populated by the ceres yfinance ETL, updated Tue–Sat):

```julia
# Most recent TTF close at or before a date (€/MWh), nothing if no data within 10 days
ttf = Euphemia.get_ttf_price(Date(2024, 6, 15))

# Gas marginal cost = TTF/efficiency + carbon + O&M (no bid markup)
mc = Euphemia.get_marginal_cost(Date(2024, 6, 15), "Fossil Gas")  # ≈ €97/MWh
```

Cost model constants (in `src/Generators.jl`): `GAS_PLANT_EFFICIENCY = 0.55`,
`GAS_EMISSION_FACTOR = 0.202` tCO₂/MWh gas, `GAS_VOM_COST = 2.0` €/MWh.

EUA carbon prices come from `yfinance.eua_co2` (daily EUR closes of the
SparkChange Physical Carbon ETC "CO2.L", populated by the ceres yfinance ETL
alongside TTF; the ETC physically holds EU Allowances so its close tracks
EUA spot ~1:1). `eua_price(day)` uses the close of the last trading day
strictly before the market date (no lookahead), cached in
`EUA_PRICE_CACHE`; before the feed's history starts (Nov 2021) or on DB
failure it falls back to the `EUA_PRICE_BY_YEAR` yearly lookup.

TTF lookups use the close of the last trading day strictly before the market
date (no lookahead) and are cached per date in `TTF_PRICE_CACHE` (transient DB
errors are never cached). If no TTF price exists within 10 days before the
requested date (e.g., before the table's history starts in Feb 2023), the
`FUEL_SRMC_BASE` fallback is used. All other fuel types use the `FUEL_SRMC_BASE`
table in `src/Generators.jl` — true short-run marginal costs: non-carbon base
plus `FUEL_EMISSION_FACTOR_EL × eua_price(day)` (e.g., lignite ≈ €112/MWh at
EUA 70), with no bid markup: bidding strategy belongs to the order-book
layer, not the cost model.

**Fuel type inference from generator names:**

Generators classified as "Other" in the ENTSO-E database may actually be known technology types. The `infer_fuel_type_from_name()` function attempts to reclassify them based on naming patterns:

```julia
# Automatic inference happens when loading generators
generators = get_generators("FR", Date(2024, 6, 15))
# Logs: "Inferred fuel type for BESS_AFD7_BARBAN: Other → Energy storage"
```

Currently recognized patterns:
- **BESS/Battery** → `Symbol("Energy storage")`: Matches "BESS", "BATTERY", "BATTERIE", "BATTERI"

Generators that cannot be inferred remain as "Other" with flexible parameters (see FuelTypeParameters below). Unknown "Other" generators are documented in `docs/unknown-other-generators.md` for future research.

**Flexible fuel types:**

The constant `FLEXIBLE_FUEL_TYPES` defines technologies that can operate at any output level (no minimum load factor):
```julia
FLEXIBLE_FUEL_TYPES = [
    Symbol("Hydro Water Reservoir"),
    Symbol("Hydro Run-of-river and pondage"),
    Symbol("Hydro Pumped Storage"),
    Symbol("Energy storage"),
    Symbol("Other")
]
```

These fuel types:
- Have `min_load_factor = 0` (can operate at any level down to 0 MW)
- Are excluded from thermal minimum generation constraints in UC
- Include "Other" since the actual technology is unknown

**Generator parameter inference from historical data:**

The UC solver uses inferred plant-specific parameters by default (`use_inferred_params=true`). This provides more accurate ramp rates, p_min, and uptime/downtime constraints based on historical generation data rather than generic fuel-type defaults.

```julia
# Get generators with inferred parameters (uses DB cache, ~2 sec)
generators = get_generators_with_inferred_params("GR", Date(2024, 6, 15))

# Force fresh inference (slow, ~17 min, but updates cache)
generators = get_generators_with_inferred_params("GR", Date(2024, 6, 15); use_cache=false)

# Manual inference without caching
generators = get_generators("GR", Date(2024, 6, 15))
generators_with_inferred = infer_parameters_for_generators(generators, Date(2024, 6, 15))
```

Parameter cache:
- Cached in PostgreSQL (`simulations.generator_inferred_parameters`)
- Default cache expiry: 365 days (physical parameters don't change frequently)
- For zones without cached data, inference runs automatically on first UC solve
- Use `max_cache_age_days` parameter to adjust cache expiry

**Proactive cache refresh:**

To avoid surprise delays during UC solves, use `refresh_inference_cache()` to proactively update the cache. When `parallel=true`, inference is parallelized at the **generator level** (not zone level), allowing full utilization of all available CPU cores. Each generator's inference is completely independent (just DB queries + statistics).

```julia
# Refresh cache for specific zones (sequential)
result = refresh_inference_cache(["GR", "BG", "RO"], Date(2024, 6, 15))

# Parallel refresh - uses half the cores (leave room for other users)
using Distributed
addprocs(Sys.CPU_THREADS ÷ 2)  # e.g., 40 cores on 80-core machine
@everywhere using Euphemia
zones = get_available_zones(Date(2024, 6, 15))
result = refresh_inference_cache(zones, Date(2024, 6, 15); parallel=true)
# With 400 generators across 80 workers: ~5x faster than sequential
```

**Command-line script** (`bin/refresh_inference_cache.jl`):
```bash
# Run manually with environment variables
REFERENCE_DATE="2026-01-01" PARALLEL="true" MAX_WORKERS="40" julia --project=. bin/refresh_inference_cache.jl
```

**GitHub Action** (`.github/workflows/refresh-inference-cache.yml`):
- Runs annually on January 1st to keep cache fresh
- Can be triggered manually before large batch runs
- Auto-discovers all zones and uses generator-level parallelism

The `infer_parameters_for_generators()` function analyzes historical generation from `entsoe.actual_generation_output_per_generation_unit` to infer:

- **Ramp rates** (`ramp_up`, `ramp_down`): 95th percentile of observed ramps, stored as fraction of p_max per hour
- **Minimum generation** (`p_min`): 5th percentile of stable non-zero operation
- **Min uptime/downtime** (`min_uptime`, `min_downtime`): 5th percentile of on/off cycle durations (hours)

Ramp rate inference:
- Queries 12 months of historical generation data to capture full seasonal variation
- Normalizes to hourly rates regardless of source resolution (PT15M, PT60M, etc.)
- Falls back to fuel-type defaults in `FuelTypeParameters` if insufficient data
- The 12-month window captures all seasonal dispatch patterns while the 95th/5th percentile approach extracts robust parameter estimates

Initial p_min (when loading from database):
- **Flexible resources** (hydro, batteries, storage): `p_min = 0`
- **Thermal plants**: `p_min = min_load_factor × p_max` from `FuelTypeParameters`
- This ensures consistency with what UC enforces, even before inference runs

p_min inference strategy (robust to data quality issues):
- **Flexible resources** (hydro, batteries): p_min = 0 (no inference needed)
- **Thermal plants**: Infers from historical stable operation
  - Filters zeros (plant off) and transients (startup/shutdown ramps)
  - Transient detection: points where |delta| > 5% of p_max
  - Takes 5th percentile of remaining stable values
  - Fuel-type-specific clamp bounds (aligned with FuelTypeParameters):
    - Coal/Lignite: 45-65% of p_max
    - Gas CCGT: 35-55% of p_max
    - Gas OCGT: 20-45% of p_max

Min uptime/downtime inference:
- Identifies consecutive "on" periods (output > 1 MW) for uptime
- Identifies consecutive "off" periods (output = 0) for downtime
- Filters out short glitches (< 2 periods)
- Requires at least 5 on/off cycles for meaningful inference
- Baseload plants (coal) often return N/A (rarely cycle)
- Fuel-type-specific clamp bounds:
  - Coal: uptime 8-48h, downtime 4-24h
  - Gas CCGT: uptime 2-12h, downtime 1-8h
  - Gas OCGT: uptime 1-4h, downtime 1-4h

p_min validation (outage handling):
- Inferred or cached p_min may exceed current p_max when outages reduce capacity
- Example: Generator historically operates at min 80 MW, but outage reduces p_max to 70 MW
- **Validation**: p_min is clamped to not exceed p_max in both:
  - `infer_parameters_for_generator()`: After inference
  - `get_generators_with_inferred_params()`: When applying cached parameters
- Logs a warning when clamping occurs for tracking data issues
- Without this validation, UC becomes infeasible (constraint p_min ≤ g ≤ p_max impossible)

**Generator initial conditions for unit commitment:**
```julia
# Get initial conditions for all generators (state at t=0)
conditions = get_initial_conditions(generators, Date(2024, 6, 15))

# Each generator has:
ic = conditions["GEN-CODE"]
ic.is_on        # Bool: was generator running at market day start?
ic.output       # Float64: MW output at t=0 (0 if off)
ic.hours_on     # Int: consecutive hours already running
ic.hours_off    # Int: consecutive hours already off
ic.thermal_state # Symbol: :hot, :warm, or :cold
```

Initial conditions inference:
- Uses batch query (`get_recent_generation_batch()`) to fetch all generator history in one SQL call
- Queries 72 hours of historical data before market day start (00:00 CET)
- Determines commitment status from most recent output (> 1 MW = on)
- Counts consecutive hours in current state for uptime/downtime constraints
- Thermal state based on hours_off:
  - Hot: hours_off <= 8 (quick restart)
  - Warm: 8 < hours_off <= 48
  - Cold: hours_off > 48 (full cold start)

Performance optimization:
- Batch query instead of N individual queries (~36x speedup)
- For ~40 generators: ~15 sec vs ~9 min with individual queries
- Uses `WHERE generation_unit_code = ANY($1)` for efficient batch lookup

Fallback defaults when no historical data:
- Baseload (coal, lignite, nuclear): Assume running
- Mid-merit (CCGT): Assume off but warm
- Peakers (OCGT): Assume off, potentially cold
- Flexible (hydro, batteries): Assume off, ready (hot)

Unit commitment integration:
- Links t=1 commitment to initial state u₀
- Constrains t=1 ramps from initial output g₀
- Enforces remaining uptime/downtime based on T_on₀/T_off₀

Initial output validation:
- Historical output data may be outside the valid `[effective_p_min, p_max]` range due to:
  - Data quality issues (measurement errors)
  - Capacity changes (derating, upgrades)
  - Outages affecting available capacity
- The UC solver validates and clamps initial output to prevent infeasibility:
  - If `output > p_max`: clamp to `p_max`
  - If `output < effective_p_min`: set to `max(0.7 × p_max, effective_p_min)`
  - Logs warnings when clamping occurs
- **Important**: `effective_p_min = max(declared_p_min, min_load_factor × p_max)` for thermal plants
  - This matches how the UC model calculates minimum generation
  - Flexible fuel types (hydro, storage) use only `declared_p_min`
- This ensures ramp constraints from t=0 to t=1 are always feasible

**Unit commitment solver:**
```julia
# Run unit commitment optimization
solution = solve_unit_commitment("GR", Date(2024, 6, 15))

# With custom solver tuning
solution = solve_unit_commitment("GR", Date(2024, 6, 15);
    mip_gap=0.01,       # Accept 1% optimality gap (default)
    time_limit=600.0)   # Max solve time in seconds (default 10 min)

# With inferred parameters from historical data (default: enabled)
solution = solve_unit_commitment("GR", Date(2024, 6, 15);
    use_inferred_params=true)  # Use plant-specific ramp rates from historical data

# Disable inferred parameters (use fuel-type defaults only)
solution = solve_unit_commitment("GR", Date(2024, 6, 15);
    use_inferred_params=false)  # Fall back to FuelTypeParameters defaults

# Access solution fields
solution.status              # JuMP termination status (OPTIMAL, INFEASIBLE, etc.)
solution.solver              # Solver used ("HiGHS" or "Gurobi")
solution.resolution_minutes  # Time period resolution (15, 30, or 60)
solution.total_cost          # Total cost (production + startup + no-load)
solution.g                   # Generation matrix [generator × time]
solution.u                   # Commitment matrix [generator × time]
solution.v                   # Startup decisions [generator × time]
solution.cost_breakdown      # Detailed cost breakdown (see below)
```

Solver tuning parameters (solver-agnostic via MOI):
- `mip_gap`: Relative optimality gap tolerance (default 0.01 = 1%). Solver stops when it finds a solution within this percentage of proven optimal.
- `time_limit`: Maximum solve time in seconds (default 600 = 10 min). Returns best solution found within time budget.
- `use_inferred_params`: Use plant-specific parameters inferred from historical data (default: true). When enabled, the solver uses `get_generators_with_inferred_params()` which provides plant-specific ramp rates, p_min, and uptime/downtime constraints. When disabled, uses fuel-type defaults from `FuelTypeParameters`.

Unit commitment objective function components:
- **Production costs**: `marginal_cost × generation` for each generator and period
- **Startup costs**: Temperature-dependent (hot × 1.0, warm × 1.5, cold × 2.5 base cost)
  - Base startup cost = `startup_cost_multiplier × marginal_cost × p_max`
  - From `FuelTypeParameters` for each fuel type
- **No-load costs**: Fixed cost when committed = `no_load_cost_fraction × marginal_cost × p_min × period_hours`
- **Curtailment costs**: Penalty for spilling renewable generation (default 1 €/MWh)

"Other" fuel type handling:
- Generators with unknown fuel type use flexible parameters (not conservative thermal)
- Parameters: 1-2h startup, 1h min up/downtime, 50% ramp rate, 0% min load factor
- This prevents infeasibility for miscategorized flexible resources (e.g., unidentified batteries)
- See `docs/unknown-other-generators.md` for list of generators requiring manual classification

**Renewable curtailment:**

The UC solver allows renewable curtailment to handle infeasibility when thermal P_min constraints exceed net demand. This is common in high-RES penetration scenarios.

```julia
# Default: curtailment allowed with 1 €/MWh penalty
solution = solve_unit_commitment("GR", Date(2024, 6, 15))

# Custom curtailment penalty (higher = less curtailment)
solution = solve_unit_commitment("GR", Date(2024, 6, 15);
    curtailment_penalty=5.0)  # 5 €/MWh penalty

# Access curtailment data
solution.curtailment      # Vector of curtailment per period (MWh)
solution.curtailment_cost # Total curtailment cost (€)
solution.load_values      # Raw load values (before net demand)
solution.renewable_values # Raw renewable forecast values
```

How curtailment works:
- **Balance constraint**: `Generation + Shortage = Load - Renewables + Curtailment + Excess`
- **Curtailment bounds**: `0 ≤ Curtailment[t] ≤ Renewables[t]`
- **Objective**: Adds `curtailment_penalty × sum(Curtailment)` to minimize unnecessary spilling

When curtailment is needed:
- Sum of committed thermal P_min exceeds net demand
- High renewable generation + low load periods
- Min uptime constraints prevent thermal unit shutdown

The curtailment penalty should reflect:
- `0 €/MWh`: Free curtailment (pure technical feasibility)
- `1-5 €/MWh`: Typical values (political/subsidy signal)
- Higher values reduce curtailment but may cause infeasibility

**Excess generation (structural oversupply):**

When curtailment alone cannot achieve feasibility (e.g., sum of thermal P_min > load even with all renewables curtailed), the UC solver allows "excess generation" as a last resort. This guarantees feasibility for all zones.

```julia
# Default: excess allowed with 10,000 €/MWh penalty
solution = solve_unit_commitment("GR", Date(2024, 6, 15))

# Custom excess penalty (higher = less excess, but may cause infeasibility)
solution = solve_unit_commitment("GR", Date(2024, 6, 15);
    excess_penalty=5000.0)  # 5,000 €/MWh penalty

# Access excess data
solution.excess      # Vector of excess generation per period (MWh)
solution.excess_cost # Total excess cost (€)
```

How excess generation works:
- **Balance constraint**: `Generation + Shortage = Load - Renewables + Curtailment + Excess`
- **Excess bounds**: `Excess[t] ≥ 0` (unbounded above)
- **Objective**: Adds `excess_penalty × sum(Excess)` to minimize structural oversupply

When excess is needed:
- Thermal P_min constraints force generation above what load can absorb
- Even after curtailing all renewables, thermal minimum > load
- Typically indicates grid has more baseload capacity than demand

The excess penalty should be high (default 10,000 €/MWh) to ensure it's only used as a last resort, after all curtailment options are exhausted. If excess generation appears, it indicates a structural oversupply problem in the zone.

**Shortage (load shedding):**

When total generation capacity is insufficient to meet demand (total P_max < net demand), the UC solver allows "load shedding" via a shortage variable. This guarantees feasibility for all zones.

```julia
# Default: shortage allowed with 10,000 €/MWh penalty
solution = solve_unit_commitment("GR", Date(2024, 6, 15))

# Custom shortage penalty
solution = solve_unit_commitment("GR", Date(2024, 6, 15);
    shortage_penalty=5000.0)  # 5,000 €/MWh penalty

# Access shortage data
solution.shortage      # Vector of load shedding per period (MWh)
solution.shortage_cost # Total shortage cost (€)
```

How shortage (load shedding) works:
- **Balance constraint**: `Generation + Shortage = Load - Renewables + Curtailment + Excess`
- **Shortage bounds**: `Shortage[t] ≥ 0` (unbounded above)
- **Objective**: Adds `shortage_penalty × sum(Shortage)` to minimize load shedding

When shortage is needed:
- Total available generation capacity (P_max) is less than net demand
- Even with all generators running at full capacity, demand cannot be met
- Typically indicates zone has insufficient generation capacity or data issues

The shortage penalty should be high (default 10,000 €/MWh) to ensure it's only used as a last resort. If shortage appears, it indicates either:
1. A capacity shortage in the zone (insufficient installed capacity)
2. Data quality issues (missing generators or incorrect load data)
3. The zone aggregates multiple sub-zones with different data availability

Cost breakdown fields:
```julia
cb = solution.cost_breakdown
cb.production_cost        # Total production costs (€)
cb.startup_cost           # Total startup costs (€)
cb.noload_cost            # Total no-load costs (€)
cb.startup_costs_by_type  # Dict{Symbol,Float64} - costs by :hot/:warm/:cold
cb.startup_counts         # Dict{Symbol,Int} - count of each startup type
cb.generator_costs        # Dict{String,Float64} - production cost by generator
cb.fuel_type_costs        # Dict{Symbol,Float64} - production cost by fuel type
cb.period_costs           # Vector{Float64} - total cost per time period
```

Time resolution handling:
- All parameters in `FuelTypeParameters` are stored in HOURS
- The UC solver converts to PERIODS based on actual data resolution
- Conversion factor: `periods_per_hour = 60 / resolution_minutes`
- Affected parameters: startup times, min uptime/downtime, temperature thresholds
- Example: At 15min resolution, `min_uptime=4` hours → 16 periods

Big M parameter:
- Used in ramp constraints to relax them during startup/shutdown
- Scaled to problem size: `M = 2 × max(p_max)` for numerical stability

**Infeasibility diagnosis (Gurobi only):**

When the UC solver returns INFEASIBLE with Gurobi, it automatically computes and prints the Irreducible Infeasible Subsystem (IIS):

```julia
# If infeasible, solver prints conflicting constraints:
# Computing IIS (Irreducible Infeasible Subsystem)...
# IN CONFLICT: min_uptime[GEN-CODE,5]: u[GEN-CODE,5] >= ...
# IN CONFLICT: ramp_down[GEN-CODE,1]: g[GEN-CODE,1] - g₀ >= ...
```

The IIS identifies the minimal set of constraints that cannot all be satisfied simultaneously. Common causes:
- **Ramp + initial conditions**: Generator output at t=0 too far from required t=1 range
- **Min uptime/downtime**: Generator must be both ON and OFF due to conflicting constraints
- **Startup profile**: Generator cannot complete startup within horizon

For systematic diagnosis, use the diagnostic script:
```bash
julia --project=. test/scripts/diagnose_fr_infeasibility.jl
```

This analyzes capacity by status, thermal state, startup time, and identifies locked generators.

**UC results caching:**
```julia
# Run UC with caching (default - uses cached results if available)
solution = solve_unit_commitment("GR", Date(2024, 6, 15))

# Force fresh solve, bypassing and replacing cache
solution = solve_unit_commitment("GR", Date(2024, 6, 15); force_rerun=true)

# Disable caching entirely (neither load nor save)
solution = solve_unit_commitment("GR", Date(2024, 6, 15); use_cache=false)

# Check if cached results exist
has_cache = has_cached_uc_results("GR", Date(2024, 6, 15))

# Load cached results directly (returns nothing if not found)
cached = load_uc_results("GR", Date(2024, 6, 15))

# Cached solutions have from_cache=true field
cached.from_cache  # true for loaded results, not present for fresh solves
```

Caching behavior:
- **Default** (`use_cache=true, force_rerun=false`): Check cache first, return cached if exists, else solve and save
- **Force rerun** (`force_rerun=true`): Solve fresh, replace cache entry
- **No caching** (`use_cache=false`): Solve fresh, don't save to cache
- Cache is stored in PostgreSQL (`simulations.uc_results`, `uc_generation`, `uc_net_demand`)
- Cache key: `(bidding_zone, market_date, code_version)`
- Storage: ~195 KB per zone/day (~700 MB/year for 10 zones)

The `force_rerun` parameter is passed through the entire call chain:
- `generate_energy_prices_for_date_range()` → `generate_energy_prices_for_all_zones()` → `generate_energy_prices()` → `create_typed_order_book()` → `generate_market_orders_from_uc()` → `solve_unit_commitment()`
- `run_multi_zone_for_date_range()` → `run_multi_zone_market_clearing()` → `create_multi_zone_order_book()` → `generate_market_orders_from_uc()` → `solve_unit_commitment()`

**Parallel UC execution:**
When `parallel=true` in `run_multi_zone_market_clearing()`:
- UC solves for each zone run concurrently using `Distributed.pmap`
- Requires workers: `addprocs(n)` + `@everywhere using Euphemia`
- Falls back to sequential if no workers available
- Cache reads/writes are safe (zone-specific keys, PostgreSQL transactions)

**Gurobi license constraints:**
- WLS (Web License Service) limits concurrent solver sessions (check "session baseline" in your Gurobi profile)
- Each parallel UC worker consumes 1 session while actively solving
- **Automatic cap**: When `parallel=true` and `max_workers` is not set:
  - Gurobi: automatically limits to 2 workers (license limit)
  - HiGHS: uses half of available workers (leaves headroom)
- Override with explicit `max_workers=N` if needed
- "Max distributed workers" is unrelated (for Gurobi's distributed MIP, not parallel independent solves)

### Pipelined multi-zone backfill (`run_pipelined_backfill`)

For long multi-zone EU backfills the bottleneck is that the two-pass merit-order
clear alternates a **slow book build** (39 zones of DB-heavy order construction)
with a **fast Gurobi solve**, so the scarce solver sits idle during every build.
`run_pipelined_backfill` (in `src/PipelinedBackfill.jl`) is a producer/consumer
pipeline that keeps the solver saturated: book-builder workers build complete
per-day 39-zone book sets **in memory, ahead of time**, and hand them to a small
pool of solver workers that "never sit".

```julia
using Distributed  # the coordinator manages the worker pool internally
result = run_pipelined_backfill(Date(2026,1,1):Day(1):Date(2026,6,30), FOOTPRINT;
    solver_workers=2,           # concurrent Gurobi solves (== WLS session cap)
    book_workers=10,            # default min(10, CPU_THREADS ÷ 8)
    in_flight=8,                # bounded days-in-flight (RAM + backpressure)
    optimizer="gurobi",
    clearing_mode="multi_zone_eu",
    save_to_db=true, resume=true)   # resumable: already-saved days are skipped
result.days_per_hour            # throughput
result.solver_utilization       # solve-busy / wall, per solver worker
```

Architecture (one flow per market day, with the pass-2 anchor feedback edge):
`feeder → BOOK WORKERS build pass-1 → SOLVER pass-1 MPCC → extract anchor refs →
BOOK WORKERS rebuild only the ~12 anchored zones (others reused verbatim) →
SOLVER pass-2 → single WRITER on the coordinator saves`. Stages are wired with
bounded `RemoteChannel`s; a counting-token semaphore caps days-in-flight at
`in_flight` and every internal channel has that capacity, so no internal `put!`
ever blocks (this breaks the pass-2 feedback cycle's deadlock potential) — only
the feeder blocks, which is the intended backpressure.

**Correctness (measured):** every model/book step reuses the exact functions the
sequential `run_multi_zone_market_clearing(...; passes=2)` path uses — the
exposed stages `mz_build_books`, `mz_solve_pass`, `mz_extract_anchor_inputs`,
`mz_rebuild_anchored`. Acceptance test `test/scripts/pipeline_identity.jl`
(3 days × 39 zones both ways): **bit-identical on the DuckDB extract** (2,808
prices, max |Δ| = 0) and bit-identical on Postgres with serialized DB access.
With *concurrent* book builds against live Postgres, SQL aggregate summation
order can shift at the last ULP (≤1e-12 €/MWh; rarely flips a near-degenerate
marginal tranche) — the same documented mechanism as the Postgres↔DuckDB
residual, inherent to concurrent Postgres querying (also affects `--workers 2`),
not a pipeline artifact. Benchmark (10 days, 2026-03): **1.43×** over the
day-parallel 2-worker mode (202 s vs 289 s; solver utilization 73–78%).

**Gurobi safety:** exactly `solver_workers` solver *processes* exist, each solving
one problem at a time, so at most `solver_workers` Gurobi solves run at once — set
it to the WLS concurrent-session cap (2 here), or **1 to coordinate with another
running backfill**. Each solver process creates ONE persistent Gurobi env on its
first solve (`SOLVER_ENV_CACHE`) and reuses it for every subsequent solve.

Wired into the runners: `bin/reproduce.jl --pipeline [--book-workers M]
[--solver-workers S]` (multi-zone jobs go through the pipeline; single-zone jobs
still run sequentially), and `bin/eu_calibration_run.jl` via `PIPELINE=true`
(with `BOOK_WORKERS` / `SOLVER_WORKERS`; saves energy_prices only under
`CLEARING_MODE`). Under the DuckDB extract the workers open it read-only and the
coordinator is the single writer, exactly like `--workers`.

## Data stores and scenario hooks

### Data store: Postgres or a DuckDB extract

By default the library reads from the live Postgres `energy` database. It can
instead read from a **self-contained DuckDB extract** — a single `.duckdb`
file that mirrors the same `schema.table` names, so both single-zone
merit-order pricing / scenario analysis **and the full 39-zone multi-zone EU
clearing** run fully offline with no Postgres available.

```julia
# Switch at runtime
configure_data_store!(backend=:duckdb, duckdb_path="data/extracts/euphemia_2026_see.duckdb")
generate_energy_prices("GR", Date(2026, 1, 26); order_method=:merit_order, save_to_db=false)
configure_data_store!(backend=:postgres)   # switch back
```

Or select DuckDB from the environment at module load (this also **skips** the
eager LibPQ pool entirely, so nothing needs Postgres):

```bash
EUPHEMIA_DATA_STORE=duckdb \
EUPHEMIA_DUCKDB_PATH=data/extracts/euphemia_2026_see.duckdb \
  julia --project=. test/scripts/eval_pricing_accuracy.jl merit_order "2026-01-26" GR
```

**Backend auto-detection.** When `EUPHEMIA_DATA_STORE` is *unset*, the module
auto-selects at load (`_resolve_data_store`): DuckDB if the default public extract
`data/extracts/euphemia-public.duckdb` exists (override the path with
`EUPHEMIA_DUCKDB_PATH`), else Postgres if `ENERGY_CONN_STR` is set, else a clear
error telling you to download the extract. **Explicit env always wins**, and
configured environments (CI, the product) are unchanged — the extract file isn't
present there, so Postgres is selected exactly as before.

**Public reproducibility artifact.** A published 39-zone, 2023-01-01…2026-06-30
extract lets anyone reproduce the counterfactual with no Postgres. Download it,
verify `SHA256SUMS`, materialize a `.duckdb` from the canonical parquet dir, and
run `bin/reproduce.jl --quick|--range|--full`. See
[docs/reproducibility.md](docs/reproducibility.md).

**Writable offline results.** The published extract stays **read-only** (source
data can never be written), but the three market-result writers
(`save_energy_prices`, `save_optimization_run`, `save_transmission_flows`) persist
to a **separate** `data/results.duckdb` (override `EUPHEMIA_RESULTS_DB`) ATTACHed
as `results_db`; reads of `simulations.energy_prices` / `optimization_runs` /
`transmission_flows` are redirected there transparently. So the full pipeline with
`save_to_db=true` **and** the eval scripts run end-to-end offline. UC caching and
`ensure_indexes` remain read-only no-ops (Postgres-only).

**Limitations:**
- **Source data is read-only** under DuckDB (entsoe.*/yfinance.* never written).
  Market results persist to `data/results.duckdb` (see above); UC caching and
  `ensure_indexes` still warn-and-no-op.
- **Merit-order only.** The DuckDB path targets the `:merit_order` book
  (single-zone and multi-zone). `:uc_based` / `:alternative` are not threaded
  (they need write-heavy UC caching and the full 365-day ramp-inference window,
  which the merit extract does not carry).
- **Scenario hooks** thread through both the single-zone `:merit_order` path and
  the multi-zone footprint path (`run_multi_zone_market_clearing(...; scenario=)`);
  `:uc_based` / `:alternative` are not wired.

**Multi-zone under DuckDB.** `run_multi_zone_market_clearing(..., order_method=`
`:merit_order, enrich_network=true, passes=2, save_to_db=false)` runs entirely
against the extract — the enriched network build (implicit + explicit ATC union,
aggregate remap, flow-based drops), `get_net_imports` with exclude/import-only
arrays, reservoir dryness, per-type p95, and the day-level-outage-cached
`get_generators` all dispatch through the DuckDB dialect. Prices match Postgres
to floating-point precision: on the 39-zone 2026-04-03 clear, **~98% of the 936
price rows are bit-identical** and the rest agree to **≤2e-12 €/MWh**
(`test/scripts/eu_duckdb_parity.jl`). The residual is
last-ULP non-determinism in SQL aggregate functions (`SUM`/`AVG` in
`get_net_imports`, `percentile_cont` in `get_type_output_p95` /
`get_hydro_availability`) — Postgres and DuckDB sum/interpolate in different
orders — reaching the price only through the scarcity factor of a marginal
tranche. Single-zone stays exactly bit-identical (its price never reads an
aggregated quantity). Cross-border **flows** are a degenerate primal (alternative
optima) and need not match; prices (the duals) are what the parity gate checks.

**How it works:** `sql2df` dispatches on `DATA_STORE[]`. The Postgres path is
unchanged; the DuckDB path applies a small dialect rewrite to our SQL — strips
` AT TIME ZONE 'UTC'` (the extract stores every timestamp as naive UTC),
maps `= ANY($n)` → `IN (SELECT unnest($n))`, `<> ALL($n)` →
`NOT IN (SELECT unnest($n))`, rewrites `get_generators`' Postgres multi-arg
table unnest of the day-outage arrays (`unnest($3::text[], $4::float8[]) AS
t(...)`) into DuckDB's lockstep-unnest subquery form (plus the single
`unnest($5::text[])`), and `to_char(x,'YYYYMMDD-HH24MI')` →
`strftime(x,'%Y%m%d-%H%M')` — then runs it against one lazily-opened,
lock-guarded DuckDB connection. Single-zone DuckDB prices are bit-identical to
Postgres; the multi-zone path matches to ≤2e-12 €/MWh (see the multi-zone note
above). DuckDB's `DATE()`/`EXTRACT(HOUR …)` on the naive-UTC extract match
Postgres because the DB session runs in UTC.

**DuckDB query-path performance.** The read path is tuned so a 39-zone day book
build runs in ~1–3 s (was ~14 s):
- **Sorted extract (artifact v1.1).** Tables are materialized `ORDER BY (zone,
  date)` so row-group zonemaps prune per-zone/per-day scans; the per-unit output
  table is `(month, unit, date)`-ordered so the 60-day recent-generation probe
  prunes. `Network.jl`'s ATC queries use the half-open day range
  (`date_time_utc >= $1::date AND < $1::date + 1`) instead of the non-sargable
  `DATE(date_time_utc) = $1`, so the sort is actually usable. See
  `docs/reproducibility.md` for v1 vs v1.1.
- **Day-level physical-flow cache.** `get_net_imports` / `get_dropped_border_exports`
  scan `entsoe.physical_flows` ONCE per day for all zones (cached in
  `MeritOrderBook._NET_IMPORTS_DAY_CACHE`, like `TTF_PRICE_CACHE`; never cached on
  error); per-zone calls slice + apply the exclude / import-only filters in Julia.
  Identity-tested against the original per-zone SQL in
  `test/test_duckdb_perf_paths.jl` (bit-identical on integer flows; the raw
  MW value can differ by ≤1e-12 on real data from last-ULP `SUM` reordering,
  invisible to prices). `clear_net_imports_cache!()` empties it.
- **Prepared-statement cache.** `_duckdb_sql2df` caches compiled statements per
  connection (keyed by rewritten SQL), so the ~300 small per-day queries skip
  re-parse/plan. Cleared when the connection is dropped/reopened.
- **Per-process engine sizing.** `_duckdb_connection` issues `SET threads /
  memory_limit / temp_directory` at open, sized for `EUPHEMIA_DUCKDB_NPROCS_HINT`
  (the number of concurrent DuckDB processes, wired from `bin/reproduce.jl`'s
  `--workers`) so N parallel workers don't each grab all cores / most of RAM.
  Overridable via `EUPHEMIA_DUCKDB_THREADS`, `EUPHEMIA_DUCKDB_MEMORY`,
  `EUPHEMIA_DUCKDB_TEMP`; `temp_directory` defaults to a dir next to the extract
  (on /home, never /tmp). `sql2df_with_retry` never touches the LibPQ pool under
  the DuckDB backend. `bin/reproduce.jl` persists each run segment in a single
  `Euphemia.results_write_transaction`, so the results DB commits once instead of
  per day.

### Building a DuckDB extract

```bash
# SEE 5-zone (single-zone pricing)
ZONES="GR,BG,RO,RS,HU" START_DATE=2026-01-01 END_DATE=2026-06-30 \
  OUT=data/extracts/euphemia_2026_see.duckdb \
  julia --project=. bin/build_duckdb_extract.jl

# 39-zone EU footprint for offline multi-zone clearing (merit-order only, so the
# huge per-unit output table is windowed to 90 days — see AGEN_BACK_DAYS below)
ZONES="AT,BE,BG,CZ,DE_LU,DK1,DK2,EE,ES,FI,FR,GR,HU,LT,LV,NL,NO1,NO2,NO3,NO4,NO5,PL,PT,RO,RS,SE1,SE2,SE3,SE4,SI,SK,IT-NORTH,IT-CNORTH,IT-CSOUTH,IT-SOUTH,IT-Calabria,IT-Sicily,IT-Sardinia,CH" \
  START_DATE=2026-04-01 END_DATE=2026-04-05 AGEN_BACK_DAYS=90 \
  OUT=data/extracts/euphemia_2026_eu.duckdb \
  julia --project=. bin/build_duckdb_extract.jl
```

The builder reads Postgres (normal `.env`), converts every timestamptz column
to naive UTC, and writes the same `schema.table` names. It carries both offered
ATC tables (`_implicit` + `_explicit`, for the enriched network build),
`physical_flows`, the per-type aggregate, the (windowed) unavailability table,
and the unit registry. Per-type/output aggregate tables are windowed back 400
days (covers the 365-day hydro-availability, 60-day recent-generation, and
30-day p95 lookbacks); the tiny weekly reservoir table is kept at full history so
the prior-year reservoir-dryness comparison is exact. **`AGEN_BACK_DAYS`**
(default 400) windows only the huge per-unit `actual_generation_output` table —
`:merit_order` never runs UC, so it only needs the 60-day recent-generation and
7-day stale-override lookback; setting `AGEN_BACK_DAYS=90` keeps a short-window
39-zone EU extract small. It prints per-table row counts and aborts if the
projected size would exceed the cap. The 2026 SEE extract is ~96 MB (7.1M rows).
`data/` is git-ignored — never commit the `.duckdb`/`.parquet` files.

**Public artifact mode.** Set `PARQUET_DIR` to also emit a canonical parquet
directory (one zstd file per table) plus `MANIFEST.json` + `SHA256SUMS` — parquet
is the engine-version-durable published format; `bin/build_duckdb_from_parquet.jl`
rebuilds a bit-identical `.duckdb` from it (with `PARITY_ONLY=true` +
`VERIFY_AGAINST=<duckdb>` to prove equivalence without a second copy). Tables above
`CHUNK_THRESHOLD` (default 8M rows) are built in monthly chunks to bound memory
(the 39-zone 3.5-year per-unit table is ~125M rows). `MAX_SIZE_GB` (default 12) and
`EST_BYTES_PER_ROW` (default 40, reflecting on-disk compression) parameterize the
size guard; `MIN_FREE_GB` (default 60) aborts gracefully if free space on the
target filesystem would drop too low, and DuckDB's spill workspace is kept next to
`OUT`. See [docs/reproducibility.md](docs/reproducibility.md) for the full public
build + reproduce flow.

### Scenario hooks on `create_merit_order_book` / `generate_energy_prices`

Five optional `Function` kwargs let you run counterfactual scenarios. When all
are `nothing` the code path is byte-identical to today (verified by the
benchmark). All five thread through `generate_energy_prices` on the
`:merit_order` path **and** through the multi-zone footprint path (see
"Multi-zone scenarios" below and [docs/scenario-api.md](docs/scenario-api.md)).

- `load_modifier(timeslot::String, load_mw::Float64) -> Float64` — applied to
  every `load_by_time` entry at the source, so it propagates to net demand,
  scarcity margin, water value and demand orders.
- `renewable_modifier(timeslot::String, mw::Float64) -> Float64` — same, on
  `renewable_by_time`.
- `extra_orders(ctx) -> Vector{SimpleOrder}` — appended before merging; `ctx =
  (zone, day, timeslots, resolution_minutes, load_by_time, renewable_by_time)`.
  Both `:supply` and `:demand` allowed (a new plant / ships requesting power).
- `strategist(ctx) -> Vector{Tuple{SimpleOrder,String}}` — see below.
- `fleet_modifier(zone::String, gens::Vector{Generator}) -> Vector{Generator}`
  — first-class capacity primitive: add / remove / derate physical units as
  DATA. Runs AFTER fleet completion/truthing, so a removed unit is not silently
  re-added by the `:installed`/p95 truth-up (scenario edits are physical reality
  changes; truthing runs on the pre-scenario registry).

```julia
# "+300 MW of solar": add 300 MW to renewables during daylight slots
solar = (ts, v) -> (8 <= parse(Int, ts[10:11]) <= 17) ? v + 300.0 : v
prices = generate_energy_prices("GR", Date(2026, 1, 26);
    order_method=:merit_order, save_to_db=false, renewable_modifier=solar)

# "ships request 200 MW more power": extra inelastic demand at the cap
ships = ctx -> [SimpleOrder(:demand, 3000.0, 200.0, Symbol(ctx.zone),
                    DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes)
                for ts in ctx.timeslots]
prices = generate_energy_prices("GR", Date(2026, 1, 26);
    order_method=:merit_order, save_to_db=false, extra_orders=ships)
```

### Strategist hook (tagged orders + firm map)

Every order in the merit book is tagged with an owner: the generator code for
unit orders (including fleet-completion aggregates), `"RES"` for the renewable
forecast, `"IMPORT"` for net-import injections, `"DEMAND"` for demand, `"EXTRA"`
for `extra_orders`. The `strategist` hook runs after `extra_orders` and before
merging; its returned set **replaces** the tagged order list. It receives
`ctx = (tagged_orders, zone, day, timeslots, load_by_time, renewable_by_time,
firm_of)` where `firm_of` is a `Dict{String,String}` unit_code→firm loaded from
`simulations.unit_firms` (empty + warn if the table is missing). A plain
`Vector{SimpleOrder}` return is also accepted and re-tagged `"STRATEGIST"`.

```julia
# "What would prices be if the incumbent PPC marked up its units 20%?"
ppc_markup = ctx -> [
    (o.type == :supply && get(ctx.firm_of, tag, "") == "PPC" ?
        SimpleOrder(o.type, o.price * 1.2, o.quantity, o.zone, o.date_time, o.resolution_code) : o,
     tag)
    for (o, tag) in ctx.tagged_orders]

prices = generate_energy_prices("GR", Date(2026, 1, 26);
    order_method=:merit_order, save_to_db=false, strategist=ppc_markup)
```

### Multi-zone scenarios (EU footprint)

The same hooks thread through the multi-zone path, bundled into a `ZoneScenario`
(`Base.@kwdef` struct: `load_modifier`, `renewable_modifier`, `extra_orders`,
`strategist`, `fleet_modifier`). Pass `scenario=` to
`run_multi_zone_market_clearing`: either **one** `ZoneScenario` applied to every
zone (the `ctx.zone` in `extra_orders`/`strategist` lets one function target
zones), or a `Dict{String,ZoneScenario}` for per-zone targeting. `nothing`
(default) is byte-identical to the no-scenario run (guarded on the single-zone
GR book, the SEE 5-zone book, and the full 39-zone EU book).

```julia
# "Ships request 200 MW more power in GR" on the EU footprint
ships = ctx -> ctx.zone == "GR" ?
    [SimpleOrder(:demand, 3000.0, 200.0, Symbol(ctx.zone),
        DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes)
     for ts in ctx.timeslots] : SimpleOrder[]
result = run_multi_zone_market_clearing(Date(2026,4,3); zones=FOOTPRINT,
    order_method=:merit_order, enrich_network=true, passes=2,
    scenario=ZoneScenario(extra_orders=ships))
```

**Two-pass propagation (emergent).** The footprint clears in two passes;
opportunity-anchored zones (`:hydro`/`:nuclear`) re-bid against the pass-1
coupled price. Because a scenario applies on both passes, a change to one zone's
pass-1 price flows through the anchor references into every anchored zone's
pass-2 opportunity cost — scenario-consistent across the footprint. Measured:
+4,000 MW demand in DE_LU lifts NO2's anchored water value +€3.6/MWh though the
scenario never touched NO2. See [docs/scenario-api.md](docs/scenario-api.md) for
the three worked examples (ships / PPC markup / unit retirement) and measured
deltas.

**Analyzing scenario outputs:** label each run with a distinct `clearing_mode`
(kwarg on `generate_energy_prices`), then compare two labels with
`queries/load_weighted_price_delta.sql` via `bin/scenario_delta.jl` (load-weighted
price delta in €/MWh + annualized extra cost in €m). Full workflow and two
committed exercises (GR data center / cold ironing): "Analyzing scenario
outputs" in docs/scenario-api.md and docs/experiments/scenario-exercises/.

## GitHub Actions / CI

The project includes several GitHub workflows for automated price generation:

### Workflows

| Workflow | Schedule | Description |
|----------|----------|-------------|
| `generate-energy-prices.yml` | Daily 2 AM UTC | Single-zone market clearing |
| `generate-multi-zone-prices.yml` | Daily 3 AM UTC | Multi-zone clearing with transmission |
| `generate-iterative-multi-zone-prices.yml` | Manual only | Iterative UC-MPCC (accounts for interconnections) |
| `refresh-inference-cache.yml` | Annually Jan 1st | Refresh generator parameter inference cache |

All workflows support `workflow_dispatch` for manual triggering with custom parameters.

### Bin Scripts

The workflows invoke Julia scripts in the `bin/` directory:

- **`bin/multi_zone_main.jl`** - Non-iterative multi-zone clearing for date ranges
- **`bin/iterative_multi_zone_main.jl`** - Iterative UC-MPCC clearing for date ranges

**Running locally:**
```bash
# Set required environment variables
export START_DATE="2025-01-01"
export END_DATE="2025-01-07"
export PARALLEL="true"
export OPTIMIZER="highs"
export MAX_WORKERS="0"  # 0 = auto-detect

# For iterative (additional params)
export MAX_ITERATIONS="10"
export PRICE_TOLERANCE="1.0"
export DAMPING_FACTOR="0.7"

# Run
julia --project=. bin/iterative_multi_zone_main.jl
```

## Development Commands

### Julia Package Management

```bash
# Activate the project environment
julia --project=.

# Install dependencies
julia -e "using Pkg; Pkg.instantiate()"

# Update dependencies
julia -e "using Pkg; Pkg.update()"
```

### Running Tests

```bash
# Run all core tests (211 tests, ~4 minutes)
julia --project=. test/runtests.jl

# Run specific test files
julia --project=. -e "using Test, Euphemia; include(\"test/test_mpcc.jl\")"
julia --project=. -e "using Test, Euphemia; include(\"test/test_network_module.jl\")"
julia --project=. -e "using Test, Euphemia; include(\"test/test_multi_zone_mpcc.jl\")"
```

### Test Organization

```
test/
├── runtests.jl                  # Main test runner (includes core tests)
├── test_generator_inference.jl  # Generator parameter inference tests (58 tests)
├── test_data_fetching.jl        # DB integration for loads/renewables/etc (23 tests)
├── test_initial_conditions.jl   # Generator initial state tests (69 tests)
├── test_uc_enhancements.jl      # UC cost breakdown, solver tuning, batch query tests
├── test_uc_caching.jl           # UC results caching tests (17 tests)
├── test_mpcc.jl                 # MPCC solver tests (50 tests)
├── test_multi_zone_mpcc.jl      # Multi-zone transmission tests (21 tests)
├── test_network_module.jl       # Network/ATC tests (140 tests)
│
├── manual/                      # DB-dependent, long-running tests (run manually)
│   ├── test_database_integration.jl
│   ├── test_date_range_processing.jl
│   ├── test_*_all_zones.jl
│   └── ...
│
├── scripts/                 # Debug, benchmarks, infrastructure scripts
│   ├── diagnose_fr_infeasibility.jl  # UC infeasibility diagnosis for any zone
│   ├── benchmark_gurobi_vs_highs.jl  # Compare Gurobi (2 workers) vs HiGHS (50 workers)
│   ├── test_gurobi.jl
│   ├── test_optimizer_comparison.jl
│   ├── test_parallel_*.jl
│   └── ...
│
└── archive/                 # Deprecated/broken tests
```

### Optimization Solvers

The project supports multiple optimization solvers:
- **HiGHS** (default): Open-source linear/mixed-integer solver
- **Gurobi**: Commercial solver (requires license)

Configure solver selection via the `optimizer` parameter:
```julia
result = run_multi_zone_market_clearing(date; optimizer="highs")  # or "gurobi"
```

### Database Configuration

The project uses PostgreSQL with LibPQ.jl for data access. Create a `.env` file with:
```
DATABASE_URL=postgresql://user:password@host:port/database
```

### Database Indexes

The ENTSOE tables are populated by an external ETL process and don't have indexes by default. For fast queries, run:

```julia
using Euphemia
Euphemia.ensure_indexes()
```

This creates indexes on frequently-queried tables:
- `actual_generation_output_per_generation_unit` (54 GB) - for parameter inference
- `unavailability_of_production_and_generation_units` (4.4 GB) - for outage filtering
- `production_and_generation_units` `(area_map_code)` and `(generation_unit_code)` -
  the unit registry had no indexes, so `get_generators`' per-zone `area_map_code`
  filter and the recent-generation subquery seq-scanned it 2-3× per zone
  (~280 ms each). The `area_map_code` index turns that into a bitmap index scan
  (EXPLAIN: cost 4697 → 395, ~0.1 ms).

First run takes 30-60 minutes for large tables. Subsequent runs are instant (`IF NOT EXISTS`). Add more indexes to `ensure_indexes()` in `src/dbutils.jl` as needed.

## Code Formatting

Use JuliaFormatter for consistent code style:
```bash
julia -e "using JuliaFormatter; format(\".\")"
```

## Thesis Integration

The `thesis/` directory contains LaTeX documentation:
```bash
cd thesis
make              # Build thesis.pdf
make clean        # Clean auxiliary files
make distclean    # Clean all generated files
```

## Project Dependencies

Key Julia packages:
- **JuMP.jl**: Mathematical optimization modeling
- **HiGHS.jl**, **Gurobi.jl**: Optimization solvers
- **DataFrames.jl**, **CSV.jl**: Data manipulation
- **LibPQ.jl**: PostgreSQL database access
- **Dates.jl**: Date/time handling
- **DotEnv.jl**: Environment configuration

## Data Sources

Market data is sourced from:
- ENTSO-e Transparency Platform (installed capacity, load)
- EnEx Group (Greek market participants)
- Weather data (renewable generation forecasts) — hourly temperature/wind/solar
  for 1,851 GR cities in the separate `silentech` DB; see
  [READING_WEATHER_DATA.md](READING_WEATHER_DATA.md) for how to query it
- TTFS (natural gas prices)

## Database Schema

The project uses PostgreSQL with two main schemas:

### ENTSO-E Schema (`entsoe.*`)
- `entsoe.production_and_generation_units` - Production unit data with commissioning status and bidding zone mapping
- `entsoe.day_ahead_total_load_forecast` - Day-ahead load forecast used for UC planning (consistent with renewable forecast horizon)
- `entsoe.actual_total_load` - Historical electricity demand (for backtesting/validation, not used in UC)
- `entsoe.generation_forecasts_for_wind_and_solar` - Renewable generation forecasts (filtered by same area_type_code values)
- `entsoe.offered_transfer_capacities_implicit` - Cross-border transfer capacity data between bidding zones
- `entsoe.unavailability_of_production_and_generation_units` - Generator outage data (planned/forced)
- `entsoe.actual_generation_output_per_generation_unit` - Historical generation output (used for parameter inference)

**Important column notes for transfer capacities:**
- Use `out_map_code` and `in_map_code` for short zone codes (e.g., "GR", "BG")
- Use `out_area_code` and `in_area_code` for EIC codes (e.g., "10YGR-HTSO-----Y")
- The short codes (`map_code`) match the generator/load data zone codes

**Note on area_type_code filtering**: The combined codes like 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY' capture cases where bidding zones overlap with control areas (CTA) or countries (CTY). These combined values are present in the database and necessary for comprehensive data retrieval.

**Unavailability table columns:**
- `asset_code`: Matches `generation_unit_code` in production_and_generation_units table
- `start_outage_utc`, `end_outage_utc`: Outage period (text, parsed as timestamp)
- `status`: `'Active'` (confirmed), `'Cancelled'`, or `'Withdrawn'`
- `type`: `'Planned'` (maintenance) or `'Forced'` (unexpected)
- `available_capacity_mw`: Remaining capacity during outage (0 = complete outage)

**Actual generation output table columns:**
- `generation_unit_code`: Matches generator code in production_and_generation_units
- `date_time_utc`: Timestamp of the measurement
- `resolution_code`: Temporal resolution (PT15M, PT30M, PT60M)
- `actual_generation_output_mw`: Output in MW at each timestamp

### Simulations Schema (`simulations.*`)

**`simulations.energy_prices`** - Generated energy price results by bidding zone, date, and time period
- `clearing_mode`: Distinguishes between `'single_zone'` (independent zone clearing), `'multi_zone'` (joint clearing with transmission), and `'multi_zone_iterative'` (iterative UC-MPCC feedback loop)
- `optimization_run_id`: Foreign key to `optimization_runs` table for traceability
- `code_version`: Model version (current: 17 for energy_prices, 4 for optimization_runs/uc_results). energy_prices v3 = SRMC/TTF cost model (July 2026); v7 = multi-zone artifact fixes (tight MIP gap, component-wise price reconstruction, border-aware import exclusion, July 2026; 4–6 were taken by legacy uc_based experiment rows); v8 = daily EUA carbon prices from `yfinance.eua_co2` (July 2026); v9 = multi-zone nodal-balance flow signs fixed (flows were physically mirrored, capping each border by the opposite direction's ATC — July 2026); v10 = crisis-year honesty (fleet-truthing derate of baseload types to trailing p95, absolute must-run below-cost discount — July 2026; 2022 GR bias −141 → +1); v14 = the calibrated 39-zone EU-footprint model, i.e. v0.2.0 (network enrichment incl. explicit ATC + aggregate remap + flow-based border drops, ZoneProfiles, two-pass opportunity anchors — July 2026; 11–13 are reserved for the intermediate calibration iterations, whose 5-day records live under `clearing_mode='multi_zone_eu_cal*'` at cv10; the cv14 full-year `multi_zone_eu` backfill 2025-07..2026-07 is the v0.2.0 record); v15 = iterations 6–8 (July 2026): SK Core-FBMC border drop + :hydro anchor (SK winter MAE 956→~40), seasonal reservoir-drawdown water value (SE1/SE2), import-ATC scarcity credit, installed-capacity fleet truth (`fleet_truth_mode=:installed` on the continental core DE_LU/NL/PL/CZ and the Baltics — DE_LU corr 0.62→0.80), and MPCC robustness (exact indicator-form complementarity retry rung + per-day :p95-books fallback — no missing days). v7 and v8 multi_zone rows carried that bug and were deleted; v8 single_zone rows are flow-free (bit-identical to v9 output) and were relabeled to 9. The SEE single_zone/multi_zone product is byte-identical across v10/v14/v15 code — v14/v15 matter for the EU footprint (`multi_zone_eu`). Earlier rows keep their old version and are not mixed with new results. Each version is one selectable "Run" in the Metabase counterfactual dashboard — bump it for every model iteration that gets a backfill. **Ex-ante flow default (cv16 onward):** the EU-footprint multi-zone path (`enrich_network=true` + `:merit_order`) now defaults to the fully ex-ante `:v2` flow rule (flow climatology + D-7 Norwegian recency, `docs/ex-ante-flows.md`) instead of same-day observed flows — this applies to EU-footprint saves from **cv16** onward; the cv15 full-year backfill was produced with `:d0` same-day flows. SEE legacy paths (single-zone, 5-zone multi_zone with `enrich_network=false`) keep `:d0` and their byte-identity. Explicit `EUPHEMIA_FLOW_ASOF_MODE` or the `ex_ante_mode` kwarg always wins over the scoped default. **v17 = weak-zone import fixes** (July 2026, `docs/experiments/weak-zone-diagnosis` + `docs/experiments/cv17-import-fixes.md`): the cv16 EU footprint's low-correlation zones were a handful of phantom-scarcity cap days from import starvation. Shipped: (1) AT–CZ / AT–DE_LU / AT–SI Core-FBMC border drops + SI on the Slovakia treatment (continental temperament + `:hydro` anchor — `SLOVENIA_PROFILE`); (2) profile-gated **ex-ante elastic import backstop** (`ZoneProfile.import_backstop`, quantity = trailing-8-same-weekday demonstrated import headroom beyond the `:v2` climatology minus offered endogenous ATC, priced 1.8×gas SRMC; on for AT/BE/CH/DK1/DK2/SE3/IT-CNORTH/SI/RO/RS, HU deliberately excluded); (3) SE3 anchor refs over dropped borders (`anchor_include_dropped`, SE2 climatology-flow-weighted); (4) ref-priced retained-border exports (`ref_priced_exports`: SI–HR, BE–GB). The SEE single-zone/5-zone products stay byte-identical (measured: full books + GR prices bit-identical cv16↔cv17 code).
- Unique on `(date_time_utc, bidding_zone, contract_type, order_method, clearing_mode, code_version)` - allows storing results from different clearing modes side by side

**`simulations.optimization_runs`** - Optimization run metadata including status, solver info, and performance metrics
- For single-zone runs: `bidding_zone` contains the zone code (e.g., "GR")
- For multi-zone runs: `bidding_zone` is set to "MULTI_ZONE"
- For iterative runs: `bidding_zone` is set to "MULTI_ZONE_ITERATIVE"
- Contains `optimizer`, `solve_time_seconds`, `objective_value`, etc.
- Unique on `(bidding_zone, optimization_date, order_method, model_type, code_version, optimizer)` - allows comparing different solvers
- **Iterative optimization metadata** (for UC-MPCC iterative runs):
  - `is_iterative`: Boolean flag indicating iterative optimization
  - `total_time_seconds`: Total time for all iterations including UC solves
  - `iterations`: Number of iterations performed
  - `converged`: Whether the algorithm achieved convergence
  - `final_price_change`: Final max price change in €/MWh at termination
  - `final_flow_change_pct`: Final flow change percentage at termination

**`simulations.transmission_flows`** - Cross-border transmission flow results from multi-zone clearing

**`simulations.generator_inferred_parameters`** - Cached inferred generator parameters
- `generator_code`, `bidding_zone`: Primary key
- `inference_date`: When inference was run (for cache expiration)
- `ramp_up`, `ramp_down`: Inferred ramp rates (fraction/hour)
- `p_min`: Inferred minimum generation (MW)
- `min_uptime`, `min_downtime`: Inferred cycle constraints (hours)
- `data_points_used`: Number of historical data points used for inference

**`simulations.uc_results`** - Cached unit commitment optimization results (summary)
- `bidding_zone`, `market_date`, `code_version`: Unique key
- `status`: JuMP termination status (e.g., "OPTIMAL")
- `solver`: Solver used ("HiGHS" or "Gurobi")
- `resolution_minutes`: Time period resolution (15, 30, or 60)
- `total_cost`, `production_cost`, `startup_cost`, `noload_cost`: Cost components
- `hot_startups`, `warm_startups`, `cold_startups`: Startup counts by type
- `total_curtailment_mwh`, `curtailment_cost`: Renewable curtailment summary
- `total_excess_mwh`, `excess_cost`: Excess generation summary (structural oversupply)
- `total_shortage_mwh`, `shortage_cost`: Load shedding summary (capacity shortage)

**`simulations.uc_generation`** - Detailed generation data per generator per period
- `uc_result_id`: Foreign key to `uc_results`
- `generator_code`, `generator_idx`, `period_idx`: Generator and time indices
- `generation_mw`, `commitment`, `startup`: Values from g, u, v matrices

**`simulations.uc_net_demand`** - Net demand data per period
- `uc_result_id`: Foreign key to `uc_results`
- `period_idx`, `time_slot_utc`: Time period identification
- `net_demand_mw`, `renewable_generation_mw`: Demand and renewable data
- `curtailment_mw`: Renewable curtailment per period (MW)
- `excess_mw`: Excess generation per period (MW, structural oversupply)
- `shortage_mw`: Load shedding per period (MW, capacity shortage)

**Joining prices with optimization metadata:**
```sql
SELECT ep.*, opr.optimizer, opr.solve_time_seconds
FROM simulations.energy_prices ep
JOIN simulations.optimization_runs opr ON ep.optimization_run_id = opr.id
```

## Testing Strategy

Tests focus on:
- Network topology and ATC constraint handling
- Multi-zone market clearing with transmission flows
- MPCC solver correctness and UC comparison
- Unit commitment optimization correctness
- Bidding strategy validation
- Data integrity and consistency
