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
    save_to_db=true)

# Process all zones for a single date
result = generate_energy_prices_for_all_zones(Date(2024, 6, 15))

# Process a date range
result = generate_energy_prices_for_date_range(Date(2024, 6, 1), Date(2024, 6, 7))
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
```

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

**Generator parameter inference from historical data:**
```julia
# Get generators with inferred parameters (uses DB cache, ~2 sec)
generators = get_generators_with_inferred_params("GR", Date(2024, 6, 15))

# Force fresh inference (slow, ~17 min, but updates cache)
generators = get_generators_with_inferred_params("GR", Date(2024, 6, 15); use_cache=false)

# Manual inference without caching
generators = get_generators("GR", Date(2024, 6, 15))
generators_with_inferred = infer_parameters_for_generators(generators, Date(2024, 6, 15))
```

The `infer_parameters_for_generators()` function analyzes historical generation from `entsoe.actual_generation_output_per_generation_unit` to infer:

- **Ramp rates** (`ramp_up`, `ramp_down`): 95th percentile of observed ramps, stored as fraction of p_max per hour
- **Minimum generation** (`p_min`): 5th percentile of stable non-zero operation
- **Min uptime/downtime** (`min_uptime`, `min_downtime`): 5th percentile of on/off cycle durations (hours)

Ramp rate inference:
- Queries 3 months of historical generation data
- Normalizes to hourly rates regardless of source resolution (PT15M, PT60M, etc.)
- Falls back to fuel-type defaults in `FuelTypeParameters` if insufficient data
- **Note on 3-month window**: Physical parameters (ramp rates, p_min) are plant characteristics that shouldn't vary by season. However, seasonal dispatch patterns may affect uptime/downtime inference for plants that operate differently in summer vs winter. A longer window (6-12 months) could capture more operating conditions but would increase query time and include potentially stale data. The 95th/5th percentile approach mitigates this by capturing extreme values even from limited data.

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

**Unit commitment solver:**
```julia
# Run unit commitment optimization
solution = solve_unit_commitment("GR", Date(2024, 6, 15))

# With custom solver tuning
solution = solve_unit_commitment("GR", Date(2024, 6, 15);
    mip_gap=0.01,       # Accept 1% optimality gap (default)
    time_limit=600.0)   # Max solve time in seconds (default 10 min)

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

Unit commitment objective function components:
- **Production costs**: `marginal_cost × generation` for each generator and period
- **Startup costs**: Temperature-dependent (hot × 1.0, warm × 1.5, cold × 2.5 base cost)
  - Base startup cost = `startup_cost_multiplier × marginal_cost × p_max`
  - From `FuelTypeParameters` for each fuel type
- **No-load costs**: Fixed cost when committed = `no_load_cost_fraction × marginal_cost × p_min × period_hours`

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
- `generate_energy_prices()` → `create_typed_order_book()` → `generate_market_orders_from_uc()` → `solve_unit_commitment()`
- `run_multi_zone_market_clearing()` → `create_multi_zone_order_book()` → `generate_market_orders_from_uc()` → `solve_unit_commitment()`

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
- `entsoe.actual_total_load` - Historical electricity demand data by bidding zone (filtered by area_type_code: BZN, BZN/CTA, BZN/CTY, BZN/CTA/CTY)
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
- `clearing_mode`: Distinguishes between `'single_zone'` (independent zone clearing) and `'multi_zone'` (joint clearing with transmission)
- `optimization_run_id`: Foreign key to `optimization_runs` table for traceability
- `code_version`: Schema version (current: 2)

**`simulations.optimization_runs`** - Optimization run metadata including status, solver info, and performance metrics
- For single-zone runs: `bidding_zone` contains the zone code (e.g., "GR")
- For multi-zone runs: `bidding_zone` is set to "MULTI_ZONE"
- Contains `optimizer`, `solve_time_seconds`, `objective_value`, etc.

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

**`simulations.uc_generation`** - Detailed generation data per generator per period
- `uc_result_id`: Foreign key to `uc_results`
- `generator_code`, `generator_idx`, `period_idx`: Generator and time indices
- `generation_mw`, `commitment`, `startup`: Values from g, u, v matrices

**`simulations.uc_net_demand`** - Net demand data per period
- `uc_result_id`: Foreign key to `uc_results`
- `period_idx`, `time_slot_utc`: Time period identification
- `net_demand_mw`, `renewable_generation_mw`: Demand and renewable data

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
