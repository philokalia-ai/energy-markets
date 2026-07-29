module Euphemia

# Core dependencies
using JuMP
using DataFrames, CSV
using DotEnv
using Dates
using Distributed
using Statistics

# Import optimization solvers with error handling
try
    using HiGHS
    global HIGHS_AVAILABLE = true
catch
    global HIGHS_AVAILABLE = false
end

try
    using Gurobi
    global GUROBI_AVAILABLE = true
catch
    global GUROBI_AVAILABLE = false
end

try
    using CPLEX
    global CPLEX_AVAILABLE = true
catch
    global CPLEX_AVAILABLE = false
end

include("dbutils.jl")

# =============================================================================
# CUSTOM EXCEPTION TYPES
# =============================================================================

"""
Custom exception for data availability issues that should not trigger retries.
Used when essential data (loads, generators) is missing for a specific zone/date.
"""
struct DataUnavailableError <: Exception
    message::String
end

Base.showerror(io::IO, e::DataUnavailableError) = print(io, "DataUnavailableError: ", e.message)

# =============================================================================
# SOLVER ENVIRONMENT CACHING SYSTEM
# =============================================================================

"""
Global cache for solver environments to avoid repeated initialization overhead.
Stores environments per solver type for reuse across multiple optimizations.
"""
const SOLVER_ENV_CACHE = Dict{String,Any}()

"""
    get_cached_optimizer(solver_name::String)

Returns an optimizer constructor that reuses cached environments when possible.
Automatically falls back to standard optimizer for unsupported solvers.

# Arguments
- `solver_name::String`: "gurobi", "cplex", "highs", etc.

# Returns
- Optimizer constructor function for use with JuMP Model()
"""
function get_cached_optimizer(solver_name::String)
    lower_name = lowercase(solver_name)

    if lower_name == "gurobi" && GUROBI_AVAILABLE
        return get_cached_gurobi_optimizer()
    elseif lower_name == "cplex" && CPLEX_AVAILABLE
        return get_cached_cplex_optimizer()
    elseif lower_name == "highs" && HIGHS_AVAILABLE
        # HiGHS doesn't need caching (no license overhead)
        return HiGHS.Optimizer
    else
        # Fallback for unknown solvers or when specific solver not available
        if lower_name == "gurobi" && GUROBI_AVAILABLE
            return Gurobi.Optimizer
        elseif lower_name == "cplex" && CPLEX_AVAILABLE
            return CPLEX.Optimizer
        elseif lower_name == "highs" && HIGHS_AVAILABLE
            return HiGHS.Optimizer
        else
            error("Solver '$solver_name' is not available")
        end
    end
end

"""
    get_cached_gurobi_optimizer()

Returns a Gurobi optimizer constructor that reuses a cached environment.
This eliminates the license authentication overhead for subsequent model creations.
"""
function get_cached_gurobi_optimizer()
    if !haskey(SOLVER_ENV_CACHE, "gurobi_env")
        # Create and cache Gurobi environment once. A failure here means no
        # usable license — let it propagate so select_solver falls back to
        # the next solver, instead of returning an optimizer that would
        # fail at solve time anyway.
        SOLVER_ENV_CACHE["gurobi_env"] = Gurobi.Env()
        @info "✅ Gurobi environment cached for session reuse"
    end

    # Return optimizer constructor that uses cached environment
    env = SOLVER_ENV_CACHE["gurobi_env"]
    return () -> Gurobi.Optimizer(env)
end

"""
    get_cached_cplex_optimizer()

Returns a CPLEX optimizer constructor that reuses a cached environment.
Similar to Gurobi caching for license overhead reduction.
"""
function get_cached_cplex_optimizer()
    if !haskey(SOLVER_ENV_CACHE, "cplex_env")
        try
            # CPLEX environment caching (if needed - check CPLEX.jl documentation)
            # This is a placeholder - actual implementation depends on CPLEX.jl API
            SOLVER_ENV_CACHE["cplex_env"] = true  # Placeholder
            @info "✅ CPLEX environment cached for session reuse"
        catch e
            @warn "Failed to create cached CPLEX environment: $e. Using standard optimizer."
            return CPLEX.Optimizer
        end
    end

    # For now, return standard CPLEX optimizer
    # TODO: Implement actual CPLEX environment caching if needed
    return CPLEX.Optimizer
end

"""
    clear_solver_cache!()

Clears all cached solver environments. Useful for testing or memory management.
"""
function clear_solver_cache!()
    # Properly dispose of Gurobi environment if it exists
    if haskey(SOLVER_ENV_CACHE, "gurobi_env")
        try
            finalize(SOLVER_ENV_CACHE["gurobi_env"])
        catch
            # Ignore errors during cleanup
        end
    end

    empty!(SOLVER_ENV_CACHE)
    @info "Solver environment cache cleared"
end

function __init__()
    DotEnv.load!(".")
    # Runtime (not precompile-time) environment overrides.
    RESULTS_DB_PATH[] = get(ENV, "EUPHEMIA_RESULTS_DB", "data/results.duckdb")
    # Ex-ante flow lag: read at runtime so the precompiled image doesn't bake in
    # whatever EUPHEMIA_FLOW_ASOF_LAG was set (or unset) at precompile time.
    MeritOrderBook.FLOW_ASOF_LAG[] =
        something(tryparse(Int, get(ENV, "EUPHEMIA_FLOW_ASOF_LAG", "0")), 0)
    MeritOrderBook.FLOW_ASOF_CLASS[] =
        Symbol(get(ENV, "EUPHEMIA_FLOW_ASOF_CLASS", "all"))
    MeritOrderBook.FLOW_ASOF_MODE[] =
        Symbol(get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "d0"))
    MeritOrderBook.FLOW_ASOF_MODE_EXPLICIT[] = haskey(ENV, "EUPHEMIA_FLOW_ASOF_MODE")
    # Backend selection (explicit env wins; else auto-detect the public extract;
    # else Postgres; else a clear error). See `_resolve_data_store`. When DuckDB
    # is selected the eager LibPQ pool is SKIPPED entirely so the library works
    # with no Postgres available at all.
    backend, path = _resolve_data_store(
        data_store=get(ENV, "EUPHEMIA_DATA_STORE", ""),
        duckdb_path=get(ENV, "EUPHEMIA_DUCKDB_PATH", ""),
        energy_conn_str=get(ENV, "ENERGY_CONN_STR", ""))
    if backend == :duckdb
        # EUPHEMIA_DUCKDB_READONLY=true opens the extract in shared read-only
        # mode (required for multi-process parallel workers; see bin/reproduce.jl).
        ro = lowercase(get(ENV, "EUPHEMIA_DUCKDB_READONLY", "")) == "true"
        configure_data_store!(backend=:duckdb, duckdb_path=path, read_only=ro)
    else
        preinit_pool()
    end
    @info "Initialization done"
end

"""
    select_solver(preferred_solver::String="auto")

Automatically selects the best available optimization solver for energy market problems.
Returns the optimizer constructor for use with JuMP, with environment caching for 
solvers that benefit from it (like Gurobi).

# Arguments
- `preferred_solver::String`: "auto" (default), "highs", "gurobi", or "cplex"

# Returns
- Tuple of (optimizer_constructor, solver_name)

# Examples
```julia
optimizer, name = select_solver("highs")
model = Model(optimizer)
```
"""
function select_solver(preferred_solver::String="auto")
    available_solvers = []

    # Check which solvers are available
    if HIGHS_AVAILABLE
        push!(available_solvers, ("HiGHS", "highs"))
    end
    if GUROBI_AVAILABLE
        push!(available_solvers, ("Gurobi", "gurobi"))
    end
    if CPLEX_AVAILABLE
        push!(available_solvers, ("CPLEX", "cplex"))
    end

    if isempty(available_solvers)
        error("No solvers available! Please install at least one of: HiGHS.jl (recommended), Gurobi.jl, or CPLEX.jl")
    end

    # Determine priority order based on preference.
    # "auto" prefers HiGHS (open-source, no license): since cv20 the
    # EU-footprint clear runs in canonical per-period-decomposed mode, which
    # HiGHS solves and which is bit-identical across solvers — so the open
    # default reproduces the published record exactly. Gurobi (10-100x
    # faster on the MONOLITHIC coupled MIP, benchmarked 137.6s vs 1.1s on a
    # 5-zone book; academic license here) remains the development option via
    # optimizer="gurobi".
    auto_order = [("HiGHS", "highs"), ("Gurobi", "gurobi"), ("CPLEX", "cplex")]
    auto_available = filter(s -> s in available_solvers, auto_order)

    solvers_to_try = if preferred_solver == "auto"
        auto_available
    elseif lowercase(preferred_solver) == "highs" && HIGHS_AVAILABLE
        [("HiGHS", "highs"); filter(x -> x[1] != "HiGHS", available_solvers)]
    elseif lowercase(preferred_solver) == "gurobi" && GUROBI_AVAILABLE
        [("Gurobi", "gurobi"); filter(x -> x[1] != "Gurobi", available_solvers)]
    elseif lowercase(preferred_solver) == "cplex" && CPLEX_AVAILABLE
        [("CPLEX", "cplex"); filter(x -> x[1] != "CPLEX", available_solvers)]
    elseif preferred_solver != "auto"
        @warn "Preferred solver '$preferred_solver' not available. Using auto-selection."
        auto_available
    else
        auto_available
    end

    # Try solvers in order - using cached optimizers when available
    for (i, (solver_display_name, solver_key)) in enumerate(solvers_to_try)
        try
            # Get cached optimizer (falls back to standard if caching fails)
            optimizer = get_cached_optimizer(solver_key)

            # If this isn't the first solver tried, announce the successful fallback
            if i > 1
                @info "✅ Using $solver_display_name solver as fallback"
            end

            return (optimizer, solver_display_name)
        catch e
            @warn "$solver_display_name failed to initialize: $(typeof(e))"
        end
    end

    error("All available solvers failed to initialize!")
end

include("MarketOrders.jl")
using .MarketOrders: MarketOrder, SimpleOrder, BlockOrder, LinkedBlockOrder, ExclusiveBlockOrder,
    FlexibleOrder, AggregatedPeriodicOrder, MICOrder, LoadGradientOrder, MeritOrder, PUNOrder

include("Generators.jl")
include("FuelTypeParameters.jl")
include("Loads.jl")
include("Renewables.jl")

include("TemporalResolutionUtilities.jl")

include("UnitCommitment.jl")

include("BiddingStrategy.jl")
using .BiddingStrategy: generate_market_orders_from_uc, apply_bidding_strategy_to_uc, UCToBidsResult

include("Network.jl")
using .Network: NetworkTopology, create_example_network, add_atc_constraints!
using .Network: TransferCapacity, create_transfer_capacity_from_entsoe, add_transfer_capacity_constraints!, create_example_transfer_capacity
using .Network: create_network_from_entsoe, create_greek_network_from_entsoe, get_entsoe_transfer_capacities
using .Network: get_bidding_zones, get_outgoing_lines, get_incoming_lines, create_greek_transfer_capacity_from_entsoe
using .Network: get_zones_with_transfer_capacity, get_connected_zones, get_zone_pairs  # Multi-zone support

include("MPCC.jl")
using .MPCC: MPCCResult, MPCCOrderBook, solve_mpcc_market_clearing, create_typed_order_book, select_solver
using .MPCC: create_multi_zone_order_book, with_total_time  # Multi-zone support
using .MPCC: compute_net_imports_from_flows, compute_max_flow_change, apply_damping  # Iterative UC-MPCC utilities
using .MPCC: compute_max_price_change, compute_max_relative_flow_change  # Price-based convergence

include("AlternativeOrderBook.jl")
using .AlternativeOrderBook: create_adjusted_order_book, AdjustedOrderBookResult, print_order_book_summary

include("MeritOrderBook.jl")
using .MeritOrderBook: create_merit_order_book, ZoneProfile, get_zone_profile,
    ZONE_PROFILES, SEE_PROFILE, SEE_IMPORT_BACKED_PROFILE, CONTINENTAL_PROFILE,
    ITALY_PROFILE, NORDIC_PROFILE, BALTIC_PROFILE, FRANCE_PROFILE, NORWAY_PROFILE,
    SWISS_PROFILE, AUSTRIA_PROFILE, BELGIUM_PROFILE,
    SLOVAKIA_PROFILE, SLOVENIA_PROFILE, DENMARK_PROFILE, SE3_PROFILE,
    ITALY_CNORTH_PROFILE,
    with_profile, clear_net_imports_cache!, ZoneScenario, zone_scenario, is_empty_scenario

# ===== EXPORTS =====
# All module exports are centralized here following Julia best practices
# Exports come after includes so all symbols are defined before being exported

# Core market clearing functionality
export calculate_market_clearing_price, commit_units

# Market order types and utilities
export MarketOrder, SimpleOrder, BlockOrder
export LinkedBlockOrder, ExclusiveBlockOrder, FlexibleOrder, AggregatedPeriodicOrder
export MICOrder, LoadGradientOrder, MeritOrder, PUNOrder

# Entity types
export Generator, Load, RenewablesGenerationForecast, InitialConditions

# Helper functions for data retrieval
export get_generators, get_generators_with_inferred_params, infer_parameters_for_generator, infer_parameters_for_generators, refresh_inference_cache
export get_loads, get_generation_forecast_for_wind_and_solar
export get_initial_conditions, get_default_initial_conditions, determine_thermal_state

# Unit commitment functionality
export test_unit_commitment, calculate_cost_breakdown, solve_unit_commitment

# Network topology and transfer capacity
export NetworkTopology, create_example_network, add_atc_constraints!  # Network constraints (legacy)
export TransferCapacity, create_transfer_capacity_from_entsoe, add_transfer_capacity_constraints!
export create_example_transfer_capacity, create_greek_transfer_capacity_from_entsoe
export create_network_from_entsoe, create_greek_network_from_entsoe, get_entsoe_transfer_capacities
export get_bidding_zones, get_outgoing_lines, get_incoming_lines
export get_zones_with_transfer_capacity, get_connected_zones, get_zone_pairs  # Multi-zone support

# MPCC optimization functionality
export MPCCResult, MPCCOrderBook, solve_mpcc_market_clearing, create_typed_order_book, select_solver
export create_multi_zone_order_book, run_multi_zone_market_clearing, run_multi_zone_for_date_range  # Multi-zone market clearing
export run_iterative_multi_zone_market_clearing  # Iterative UC-MPCC with flow feedback
export mz_build_books, mz_solve_pass, mz_extract_anchor_inputs, mz_rebuild_anchored  # Exposed clearing stages
export run_pipelined_backfill  # Producer-consumer pipelined multi-zone backfill
export compute_net_imports_from_flows, compute_max_flow_change, apply_damping  # Flow conversion utilities
export compute_max_price_change, compute_max_relative_flow_change  # Price-based convergence

# Solver Environment Caching
export get_cached_optimizer, clear_solver_cache!

# Data store configuration (Postgres | DuckDB extract)
export configure_data_store!

# Alternative order book functionality
export create_adjusted_order_book, AdjustedOrderBookResult, print_order_book_summary
export create_merit_order_book
export ZoneProfile, get_zone_profile, ZONE_PROFILES, SEE_PROFILE, SEE_IMPORT_BACKED_PROFILE,
    CONTINENTAL_PROFILE, ITALY_PROFILE, NORDIC_PROFILE, BALTIC_PROFILE, FRANCE_PROFILE,
    NORWAY_PROFILE, SWISS_PROFILE, AUSTRIA_PROFILE, BELGIUM_PROFILE,
    SLOVAKIA_PROFILE, SLOVENIA_PROFILE, DENMARK_PROFILE, SE3_PROFILE,
    ITALY_CNORTH_PROFILE,
    with_profile

# Counterfactual scenario primitive for the multi-zone footprint path
export ZoneScenario

# Bidding strategy functionality
export generate_market_orders_from_uc, apply_bidding_strategy_to_uc, UCToBidsResult

# Fuel type parameters
export FuelTypeParameters, get_fuel_type_parameters, apply_fuel_type_constraints!

# Temporal resolution utilities
export parse_resolution_to_minutes, determine_finest_resolution, generate_sub_slots_from_source, disaggregate_temporal_data, replicate_to_finer_resolution

# Market clearing with ENTSO-E integration
export euphemia_market_clearing_with_entsoe

# Energy price generation (unified interface)
export generate_energy_prices

# Database utilities
export save_energy_prices, ensure_energy_prices_table, withdb, save_optimization_run
export save_transmission_flows, ensure_transmission_flows_table  # Multi-zone transmission flows
export ensure_uc_results_tables  # UC results caching tables
export ensure_indexes  # Create indexes on ENTSOE tables for query performance

# UC results caching
export has_cached_uc_results, save_uc_results, load_uc_results

# Zone discovery utilities  
export get_available_zones

# Batch processing utilities
export generate_energy_prices_for_all_zones, generate_energy_prices_for_date_range


# =============================================================================
# CLEARING ENGINE — split by concern (each file is `include`d in the original
# definition order, so the module body is line-for-line the pre-split code)
# =============================================================================
include("clearing/single_zone.jl")      # generate_energy_prices + zone discovery
include("clearing/multi_zone_books.jl") # multi-zone book builders, network prep, mz_* stages
include("clearing/multi_zone_run.jl")   # run_multi_zone_market_clearing (one date)
include("clearing/iterative.jl")        # iterative UC-MPCC feedback loop
include("clearing/batch_runners.jl")    # date-range / all-zones orchestration
include("clearing/batch_workers.jl")    # parallel & sequential worker helpers

# Producer/consumer pipelined multi-zone backfill (defined last so it can call
# the exposed mz_* clearing stages and the save_* helpers).
include("PipelinedBackfill.jl")


end # module Euphemia
