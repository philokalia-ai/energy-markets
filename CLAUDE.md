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
├── runtests.jl              # Main test runner (includes core tests)
├── test_mpcc.jl             # MPCC solver tests (50 tests)
├── test_multi_zone_mpcc.jl  # Multi-zone transmission tests (21 tests)
├── test_network_module.jl   # Network/ATC tests (140 tests)
│
├── manual/                  # DB-dependent, long-running tests (run manually)
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

**Important column notes for transfer capacities:**
- Use `out_map_code` and `in_map_code` for short zone codes (e.g., "GR", "BG")
- Use `out_area_code` and `in_area_code` for EIC codes (e.g., "10YGR-HTSO-----Y")
- The short codes (`map_code`) match the generator/load data zone codes

**Note on area_type_code filtering**: The combined codes like 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY' capture cases where bidding zones overlap with control areas (CTA) or countries (CTY). These combined values are present in the database and necessary for comprehensive data retrieval.

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
