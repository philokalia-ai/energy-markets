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

The `exclude_variable_renewables` parameter (default: `true`) filters out wind and solar generators:
- **Variable renewables** (Wind Onshore, Wind Offshore, Solar) are excluded from UC
- These generators' output is non-dispatchable and handled via renewable forecasts
- Renewable generation is subtracted from load to calculate net demand for UC
- This prevents double-counting (generator in UC + forecast subtracted from load)

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
    Symbol("Hydro Run-of-river and poundage"),
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
- Weather data (renewable generation forecasts)
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
- `code_version`: Schema version (current: 3)
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
