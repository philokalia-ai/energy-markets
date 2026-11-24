module Euphemia

# Core dependencies
using JuMP
using DataFrames, CSV
using DotEnv
using Dates
using Distributed
using Statistics

using HiGHS                      # the only solver

include("dbutils.jl")
include("ForecastContext.jl")   # as-of input contract (issue #368): ForecastContext, with_context, asof_audit

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

function __init__()
    DotEnv.load!(".")
    # Runtime (not precompile-time) environment overrides.
    _init_pg_pool!()  # empty runtime-sized pool, before backend initialization
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
    select_solver(preferred_solver::String="highs") -> (optimizer, "HiGHS")

HiGHS is the only solver. `preferred_solver` stays for call-site compatibility
(`optimizer=` kwargs, the `OPTIMIZER` env of the runners) and must be `"highs"` or
`"auto"`; anything else is an error.
"""
function select_solver(preferred_solver::String="highs")
    lowercase(preferred_solver) in ("highs", "auto") ||
        error("optimizer=\"$preferred_solver\" is not supported: HiGHS is the only solver")
    return (HiGHS.Optimizer, "HiGHS")
end

include("MarketOrders.jl")
using .MarketOrders: MarketOrder, SimpleOrder, BlockOrder, LinkedBlockOrder, ExclusiveBlockOrder,
    FlexibleOrder, AggregatedPeriodicOrder, MICOrder, LoadGradientOrder, MeritOrder, PUNOrder,
    LinkedHourlyOrder

include("cv45_knobs.jl")       # cv45 per-change env knobs (cv45_on)
include("Generators.jl")
include("FuelTypeParameters.jl")
include("Loads.jl")
include("Renewables.jl")

include("TemporalResolutionUtilities.jl")



include("Network.jl")
using .Network: NetworkTopology, create_example_network, add_atc_constraints!
using .Network: TransferCapacity, create_transfer_capacity_from_entsoe, add_transfer_capacity_constraints!, create_example_transfer_capacity
using .Network: create_network_from_entsoe, create_greek_network_from_entsoe, get_entsoe_transfer_capacities
using .Network: get_bidding_zones, get_outgoing_lines, get_incoming_lines, create_greek_transfer_capacity_from_entsoe
using .Network: get_zones_with_transfer_capacity, get_connected_zones, get_zone_pairs  # Multi-zone support

include("MPCC.jl")
using .MPCC: MPCCResult, MPCCOrderBook, solve_mpcc_market_clearing, select_solver
using .MPCC: with_total_time  # Multi-zone support
using .MPCC: compute_net_imports_from_flows, compute_max_flow_change, apply_damping  # Iterative UC-MPCC utilities
using .MPCC: compute_max_price_change, compute_max_relative_flow_change  # Price-based convergence

include("OrderBookResult.jl")
using .OrderBookResult: AdjustedOrderBookResult

include("MeritOrderBook.jl")
using .MeritOrderBook: create_merit_order_book, ZoneProfile, get_zone_profile,
    ZONE_PROFILES, SEE_PROFILE, SEE_IMPORT_BACKED_PROFILE, CONTINENTAL_PROFILE,
    ITALY_PROFILE, NORDIC_PROFILE, BALTIC_PROFILE, FRANCE_PROFILE, NORWAY_PROFILE,
    SWISS_PROFILE, AUSTRIA_PROFILE, BELGIUM_PROFILE,
    SLOVAKIA_PROFILE, SLOVENIA_PROFILE, DENMARK_PROFILE, SE3_PROFILE,
    ITALY_CNORTH_PROFILE, ITALY_NORTH_PROFILE,
    with_profile, clear_net_imports_cache!, ZoneScenario, zone_scenario, is_empty_scenario,
    BiddingStrategy, MarketConduct, TranchesConduct, CompetitiveConduct, ShapeConduct, DayCtx, UnitCtx,
    conduct_day_factors, offers!, offers

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
export Generator, Load, RenewablesGenerationForecast

# Helper functions for data retrieval
export get_generators
export get_loads, get_generation_forecast_for_wind_and_solar

# Unit commitment functionality

# Network topology and transfer capacity
export NetworkTopology, create_example_network, add_atc_constraints!  # Network constraints (legacy)
export TransferCapacity, create_transfer_capacity_from_entsoe, add_transfer_capacity_constraints!
export create_example_transfer_capacity, create_greek_transfer_capacity_from_entsoe
export create_network_from_entsoe, create_greek_network_from_entsoe, get_entsoe_transfer_capacities
export get_bidding_zones, get_outgoing_lines, get_incoming_lines
export get_zones_with_transfer_capacity, get_connected_zones, get_zone_pairs  # Multi-zone support

# MPCC optimization functionality
export MPCCResult, MPCCOrderBook, solve_mpcc_market_clearing, select_solver
export run_multi_zone_market_clearing, run_multi_zone_for_date_range  # Multi-zone market clearing
export mz_build_books, mz_solve_pass, mz_extract_anchor_inputs, mz_rebuild_anchored  # Exposed clearing stages
export run_pipelined_backfill  # Producer-consumer pipelined multi-zone backfill
export compute_net_imports_from_flows, compute_max_flow_change, apply_damping  # Flow conversion utilities
export compute_max_price_change, compute_max_relative_flow_change  # Price-based convergence

# Solver Environment Caching

# Data store configuration (Postgres | DuckDB extract)
export configure_data_store!

# Alternative order book functionality
export AdjustedOrderBookResult
export create_merit_order_book
export ZoneProfile, get_zone_profile, ZONE_PROFILES, SEE_PROFILE, SEE_IMPORT_BACKED_PROFILE,
    CONTINENTAL_PROFILE, ITALY_PROFILE, NORDIC_PROFILE, BALTIC_PROFILE, FRANCE_PROFILE,
    NORWAY_PROFILE, SWISS_PROFILE, AUSTRIA_PROFILE, BELGIUM_PROFILE,
    SLOVAKIA_PROFILE, SLOVENIA_PROFILE, DENMARK_PROFILE, SE3_PROFILE,
    ITALY_CNORTH_PROFILE, ITALY_NORTH_PROFILE,
    with_profile

# Counterfactual scenario primitive for the multi-zone footprint path
export ZoneScenario
# pluggable market conduct (src/merit_order/conduct.jl; strategy/DESIGN-pluggable.md)
export BiddingStrategy, MarketConduct, TranchesConduct, CompetitiveConduct, ShapeConduct, DayCtx, UnitCtx,
    conduct_day_factors, offers!, offers

# Bidding strategy functionality

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
export ensure_indexes  # Create indexes on ENTSOE tables for query performance
export run_physics_audit, audit_summary, write_audit_json  # Physics-consistency data audit (read-only)

# UC results caching

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
include("clearing/batch_runners.jl")    # date-range / all-zones orchestration
include("clearing/batch_workers.jl")    # parallel & sequential worker helpers

# Producer/consumer pipelined multi-zone backfill (defined last so it can call
# the exposed mz_* clearing stages and the save_* helpers).
include("PipelinedBackfill.jl")

# perf-96: compile the clearing path at precompile time (DB-free workload).
include("precompile_workload.jl")


end # module Euphemia
