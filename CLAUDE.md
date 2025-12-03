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
- **Data access layer**: Database utilities for energy market data

### Key Modules

- `src/Euphemia.jl` - Main module with market clearing functions
- `src/UnitCommitment.jl` - Unit commitment optimization using JuMP/HiGHS
- `src/BiddingStrategy.jl` - Converts UC solutions to market bids
- `src/Network.jl` - Network topology and ATC constraints
- `src/MarketOrders.jl` - Order types (SimpleOrder, BlockOrder)
- `src/Generators.jl`, `src/Loads.jl`, `src/Renewables.jl` - Data models
- `src/dbutils.jl` - Database connection and data access

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
# Run all tests
julia --project=. test/runtests.jl

# Test specific functionality
julia --project=. test/test_bidding_strategy.jl
julia --project=. test/compare_bidding_strategies.jl
```

### Optimization Solvers

The project supports multiple optimization solvers:
- **HiGHS** (default): Open-source linear/mixed-integer solver
- **Gurobi**: Commercial solver (requires license)

Configure solver selection in the optimization model creation.

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

**Note on area_type_code filtering**: The combined codes like 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY' capture cases where bidding zones overlap with control areas (CTA) or countries (CTY). These combined values are present in the database and necessary for comprehensive data retrieval.
- `entsoe.offered_transfer_capacities_implicit` - Cross-border transfer capacity data between bidding zones

### Simulations Schema (`simulations.*`)
- `simulations.energy_prices` - Generated energy price results by bidding zone, date, and time period
- `simulations.optimization_runs` - Optimization run metadata including status, solver info, and performance metrics

## Testing Strategy

Tests focus on:
- Unit commitment optimization correctness
- Bidding strategy validation
- Network constraint satisfaction  
- Data integrity and consistency
- Multi-day simulation stability