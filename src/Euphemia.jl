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
    # DuckDB backend via ENV: read from a self-contained extract and SKIP the
    # eager LibPQ pool entirely so the library works with no Postgres at all.
    if lowercase(get(ENV, "EUPHEMIA_DATA_STORE", "")) == "duckdb"
        path = get(ENV, "EUPHEMIA_DUCKDB_PATH", "")
        configure_data_store!(backend=:duckdb, duckdb_path=path)
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
    # "auto" prefers Gurobi when its package is installed: on multi-zone
    # complementarity MIPs it is 10-100x faster than HiGHS (benchmarked
    # 137.6s vs 1.1s on a 5-zone book). If no license is available at
    # runtime (e.g. CI), Env creation fails and the loop below falls back
    # to HiGHS with a warning — safe everywhere.
    auto_order = [("Gurobi", "gurobi"), ("HiGHS", "highs"), ("CPLEX", "cplex")]
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
    ZONE_PROFILES, SEE_PROFILE, IBERIA_PROFILE, CONTINENTAL_PROFILE,
    ITALY_PROFILE, NORDIC_PROFILE, BALTIC_PROFILE, FRANCE_PROFILE, NORWAY_PROFILE

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
export compute_net_imports_from_flows, compute_max_flow_change, apply_damping  # Flow conversion utilities
export compute_max_price_change, compute_max_relative_flow_change  # Price-based convergence

# Solver Environment Caching
export get_cached_optimizer, clear_solver_cache!

# Data store configuration (Postgres | DuckDB extract)
export configure_data_store!

# Alternative order book functionality
export create_adjusted_order_book, AdjustedOrderBookResult, print_order_book_summary
export create_merit_order_book
export ZoneProfile, get_zone_profile, ZONE_PROFILES, SEE_PROFILE, IBERIA_PROFILE,
    CONTINENTAL_PROFILE, ITALY_PROFILE, NORDIC_PROFILE, BALTIC_PROFILE, FRANCE_PROFILE,
    NORWAY_PROFILE

# Bidding strategy functionality
export generate_market_orders_from_uc, apply_bidding_strategy_to_uc, UCToBidsResult

# Fuel type parameters
export FuelTypeParameters, get_fuel_type_parameters, apply_fuel_type_constraints!

# Temporal resolution utilities
export parse_resolution_to_minutes, determine_finest_resolution, generate_sub_slots_from_source, disaggregate_temporal_data

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

# Αυτή η συνάρτηση πρέπει να διαβάζει τα market orders
# και να υπολογίζει το clearing price για timeslot για bidding zone
function calculate_market_clearing_price() end

# 
function commit_units() end

# Σε τι τιμή θα παράξουν τα accepted generators
function commit_units(generators::Vector{Generator}, load::Vector{Load})
    # TODO: να βγάζουμε ένα ενδιάμεσο vector με τα οριακά κόστη, ώστε 
    # να μπορούμε να πιάνουμε την στρατηγική του κάθε παίκτη
    # αντιπροσωπεύει την ελάχιστη τιμή που θα δώσουν αυτοί
    return Vector{MarketOrder}()
end

function calculate_market_clearing_price(market_orders::Vector{MarketOrder})::Array{Tuple{String,String,Float64}}
    return [
        ("Bidding Zone", "20252406T20:15:11", 5.0)
    ]
end

# Objective: Global Economic surplus Maximization
# https://www.nordpoolgroup.com/globalassets/download-center/single-day-ahead-coupling/euphemia-public-description.pdf Annex C1 - p72

function make_model()

    # Define the model
    model = Model(HiGHS.Optimizer)

    # Create transfer capacity structure (using real ENTSO-E data when available)
    transfer_capacity = create_example_transfer_capacity()

    # Extract bidding zones and time periods
    zones = transfer_capacity.bidding_zones
    time_periods = transfer_capacity.time_periods

    # Decision Variables
    # TRANSFER_FLOW variables for zone-to-zone transfers [source_zone, sink_zone, time_period]
    @variable(model, TRANSFER_FLOW[source in zones, sink in zones, t in time_periods; source != sink])

    # Add transfer capacity constraints from Network module
    add_transfer_capacity_constraints!(model, transfer_capacity, TRANSFER_FLOW)

    # EUPHEMIA master problem (Economic Surplus Maximization) as described in Annex C1
    @objective(
        model,
        Max,
        # Term 1: Step Orders contribution
        -sum(ACCEPT[z, t, s, o] * q[z, t, s, o] * p[z, t, s, o] * res(o)
             for z in Z, t in T[z], s in S, o in step_orders[z, t, s])

        # Term 2: Interpolated Orders contribution  
        -
        sum(ACCEPT[z, t, s, o] * q[z, t, s, o] *
            (p[z, t, s, o] + ACCEPT[z, t, s, o] * (p1[z, t, s, o] - p[z, t, s, o]) / 2) * res(o)
            for z in Z, t in T[z], s in S, o in interpolated_orders[z, t, s])

        # Term 3: Block Orders contribution
        -
        sum(ACCEPT[bo] * q[bo, t] * p[bo] * res(o)
            for bo in block_orders, t in T_bo[bo])

        # Term 4: Complex Orders contribution
        -
        sum(ACCEPT[z, co, t, o] * q[z, co, t, o] * p[z, co, t, o] * res(co)
            for z in Z, co in complex_orders[z], t in T[z], o in suborders[z, co, t])

        # Term 5: Scalable Complex Orders contribution
        -
        sum(ACCEPT[z, sco, t, o] * q[z, sco, t, o] * p[z, sco, t, o] * res(sco)
            for z in Z, sco in scalable_complex_orders[z], t in T[z], o in suborders[z, sco, t])
        -
        sum(sign(type(sco)) * FixedTerm[sco] * B_ACCEPT[sco]
            for sco in scalable_complex_orders)

        # Term 6: Merit Orders contribution
        -
        sum(ACCEPT[mo] * q[mo] * p[mo] * res(mo)
            for mo in merit_orders)

        # Term 7: Tariffs impact (adapted for zone-to-zone transfers)
        # Note: Original formula uses line-based tariffs, adapted for zone transfers
        # TODO: Define zone-to-zone tariff structure
        # -
        # sum(Tariff[source, sink, t] * TRANSFER_FLOW[source, sink, t]
        #     for source in zones, sink in zones, t in time_periods if source != sink)

        # Term 8: Price-taking hourly orders curtailment minimization
        -
        M * sum(MAX_CURTAILMENT_RATIO[z, t, o]
                for z in Z, t in T[z], o in price_taking_hourly_orders[z, t])
    )

    # Solve the model
    optimize!(model)
end

"""
    euphemia_market_clearing_with_entsoe(date::Date, bidding_zones::Vector{String}=String[])

Market clearing using real ENTSO-E transfer capacity data for the specified date.

# Arguments
- `date::Date`: Date for which to retrieve ENTSO-E transfer capacities
- `bidding_zones::Vector{String}`: Optional filter for specific bidding zones

# Returns
- JuMP model with transfer capacity constraints from real ENTSO-E data
"""
function euphemia_market_clearing_with_entsoe(date::Date, bidding_zones::Vector{String}=String[])
    model = Model(HiGHS.Optimizer)

    # Create transfer capacity structure using real ENTSO-E data
    transfer_capacity = create_transfer_capacity_from_entsoe(date, bidding_zones)

    # Extract bidding zones and time periods
    zones = transfer_capacity.bidding_zones
    time_periods = transfer_capacity.time_periods

    # Decision Variables
    # TRANSFER_FLOW variables for zone-to-zone transfers [source_zone, sink_zone, time_period]
    @variable(model, TRANSFER_FLOW[source in zones, sink in zones, t in time_periods; source != sink])

    # Add transfer capacity constraints from real ENTSO-E data
    add_transfer_capacity_constraints!(model, transfer_capacity, TRANSFER_FLOW)

    println("✅ Created EUPHEMIA model with real ENTSO-E data:")
    println("   🌍 Bidding zones: $(length(zones)) ($(join(zones, ", ")))")
    println("   🕐 Time periods: $(length(time_periods))")
    println("   🔗 Transfer variables: $(length(zones) * (length(zones)-1) * length(time_periods))")

    # TODO: Add order processing and objective function (same as main function)
    # For now, return the model with transfer capacity constraints
    return model, transfer_capacity
end

"""
    generate_energy_prices(bidding_zone::String, date::Date; 
                          order_method::Symbol=:uc_based, 
                          model::Symbol=:mpcc,
                          optimizer::String="auto",
                          markup_factor::Float64=1.1,
                          random_seed::Union{Int,Nothing}=nothing,
                          silent::Bool=true)

Unified function to generate energy prices for a bidding zone on a specific date through market clearing optimization.
Supports both hourly and sub-hourly temporal resolutions depending on the order method used.

# Arguments
- `bidding_zone::String`: The bidding zone code (e.g., "GR", "DE", "FR")
- `date::Date`: The date for which to generate prices
- `order_method::Symbol`: Method for creating orders - `:uc_based`, `:alternative` or `:merit_order`
  - `:uc_based`: Creates orders preserving Unit Commitment's native temporal resolution (15/30/60 minutes)
  - `:alternative`: Creates orders at finest available resolution (15/30/60 minutes) from real load/renewable data
- `model::Symbol`: Market clearing model - `:mpcc` (more models may be added later)
- `optimizer::String`: Optimization solver - "highs" (default), "gurobi", "cplex", "auto"
- `markup_factor::Float64`: Price markup factor for UC-based orders (default: 1.1)
- `random_seed::Union{Int,Nothing}`: Random seed for alternative order book (default: nothing)
- `silent::Bool`: Whether to suppress solver output (default: true)

# Returns
- `Dict{String,Float64}`: Dictionary mapping time periods to energy price (€/MWh)
  - Keys are timeslots in format "YYYYMMDD-HHMM" (e.g., "20240618-0000", "20240618-0015")
  - Both `:uc_based` and `:alternative` methods use consistent timeslot formatting
  Returns empty dict if any step fails.

# Temporal Resolution
The output resolution depends on the order method and underlying data resolution:
- **UC-based**: Preserves the native resolution from load/renewable data (15/30/60 minutes)
- **Alternative**: Automatically detects finest resolution from load/renewable data:
  - 15-minute data → 96 periods per day
  - 30-minute data → 48 periods per day  
  - 60-minute data → 24 periods per day

Both methods now support sub-hourly resolution and will automatically use the finest temporal 
resolution available in the underlying load and renewable generation data.

# Examples
```julia
# Generate prices using UC-based orders (hourly or sub-hourly depending on data)
prices = generate_energy_prices("GR", Date(2025, 7, 24))
println("Noon price: €\$(prices["20250724-1200"])/MWh")

# Generate prices using alternative order book (auto-detects temporal resolution)
prices_alternative = generate_energy_prices("AL", Date(2024, 6, 18); order_method=:alternative)
println("Number of price periods: \$(length(prices_alternative))")  # Could be 24, 48, or 96 depending on data

# Access specific time periods by timeslot
if haskey(prices_alternative, "20240618-1200")
    println("Noon price: €\$(prices_alternative["20240618-1200"])/MWh")
end

# Convert to vectors for analysis
price_values = collect(values(prices))
avg_price = sum(price_values) / length(price_values)
```
"""
function generate_energy_prices(bidding_zone::String, date::Date;
    order_method::Symbol=:uc_based,
    model::Symbol=:mpcc,
    optimizer::String="auto",
    markup_factor::Float64=1.1,
    random_seed::Union{Int,Nothing}=nothing,
    silent::Bool=true,
    save_to_db::Bool=false,
    force_rerun::Bool=false,
    load_modifier::Union{Nothing,Function}=nothing,
    renewable_modifier::Union{Nothing,Function}=nothing,
    extra_orders::Union{Nothing,Function}=nothing,
    strategist::Union{Nothing,Function}=nothing)

    # Validate inputs
    if !(order_method in [:uc_based, :alternative, :merit_order])
        error("Invalid order_method: $order_method. Must be :uc_based, :alternative or :merit_order")
    end

    if !(model in [:mpcc])
        error("Invalid model: $model. Currently only :mpcc is supported")
    end

    try
        println("🔄 Generating energy prices for $bidding_zone on $date")
        println("   📋 Order method: $order_method")
        println("   ⚖️  Model: $model")

        # Step 1: Create Order Book
        println("\n📋 Step 1: Creating Order Book...")
        order_book = nothing

        if order_method == :uc_based
            println("   Using UC-based order creation")
            order_book = create_typed_order_book(bidding_zone, date;
                markup_factor=markup_factor,
                optimizer=optimizer,
                force_rerun=force_rerun
            )

        elseif order_method in (:alternative, :merit_order)
            println("   Using $(order_method == :alternative ? "alternative" : "merit-order") book creation")
            order_book_result = order_method == :alternative ?
                                create_adjusted_order_book(bidding_zone, date; random_seed=random_seed) :
                                create_merit_order_book(bidding_zone, date;
                                    load_modifier=load_modifier,
                                    renewable_modifier=renewable_modifier,
                                    extra_orders=extra_orders,
                                    strategist=strategist)

            if !order_book_result.success
                # Check if this is a data availability issue (non-retryable)
                if contains(order_book_result.message, "No load data found") ||
                   contains(order_book_result.message, "No generators found")
                    throw(DataUnavailableError("$(order_book_result.message) for $bidding_zone on $date"))
                else
                    error("$(order_method) order book creation failed: $(order_book_result.message)")
                end
            end

            order_book = order_book_result.order_book
        end

        if order_book === nothing
            error("Failed to create order book")
        end

        println("   ✅ Order book created with $(length(order_book.orders)) orders")

        # Step 2: Run Market Clearing Model  
        println("\n⚖️  Step 2: Running Market Clearing ($model with $optimizer)...")

        if model == :mpcc
            optimization_start_time = time()

            try
                mpcc_result = solve_mpcc_market_clearing(order_book; preferred_solver=optimizer, silent=silent)
                solve_time_seconds = time() - optimization_start_time

                # A time-limited solve still returns its best incumbent —
                # usable, but the optimality gap is unproven, so warn loudly
                usable = mpcc_result.status == :optimal ||
                         (mpcc_result.status == :time_limit && !isempty(mpcc_result.market_prices))
                if !usable
                    # Save failed optimization run (only when persisting results —
                    # eval/backtest runs with save_to_db=false must not touch
                    # production run metadata)
                    save_to_db && save_optimization_run(bidding_zone, date, order_method, model, optimizer, mpcc_result.status;
                        solve_time_seconds=solve_time_seconds,
                        num_orders=length(order_book.orders),
                        error_message="MPCC optimization failed with status: $(mpcc_result.status)")

                    error("MPCC optimization failed with status: $(mpcc_result.status)")
                end
                mpcc_result.status == :time_limit &&
                    @warn "MPCC hit the solve time limit for $bidding_zone $date — using best incumbent (optimality gap unproven; prices may contain tolerance artifacts)"

                println("   ✅ MPCC optimization successful")
                println("   📊 Objective value: $(round(mpcc_result.objective_value, digits=2))")

                # Step 3: Extract Energy Prices
                println("\n💰 Step 3: Extracting Energy Prices...")

                if isempty(mpcc_result.market_prices)
                    # Save failed optimization run (successful solve but no prices)
                    save_to_db && save_optimization_run(bidding_zone, date, order_method, model, optimizer, :no_prices;
                        objective_value=mpcc_result.objective_value,
                        solve_time_seconds=solve_time_seconds,
                        num_orders=length(order_book.orders),
                        error_message="No market prices found in MPCC result")

                    error("No market prices found in MPCC result")
                end

                # Get prices for the bidding zone
                if !haskey(mpcc_result.market_prices, bidding_zone)
                    # Save failed optimization run (successful solve but no prices for zone)
                    save_to_db && save_optimization_run(bidding_zone, date, order_method, model, optimizer, :no_zone_prices;
                        objective_value=mpcc_result.objective_value,
                        solve_time_seconds=solve_time_seconds,
                        num_orders=length(order_book.orders),
                        error_message="No prices found for bidding zone: $bidding_zone")

                    error("No prices found for bidding zone: $bidding_zone")
                end

                prices = mpcc_result.market_prices[bidding_zone]

                println("   ✅ Energy prices extracted for $(length(prices)) time periods")
                println("   📈 Price range: €$(round(minimum(values(prices)), digits=2)) - €$(round(maximum(values(prices)), digits=2))/MWh")

                # Save successful optimization run and get the ID (skipped for
                # save_to_db=false runs so evals never touch production tables)
                optimization_run_id = save_to_db ?
                                      save_optimization_run(bidding_zone, date, order_method, model, optimizer, :optimal;
                                          objective_value=mpcc_result.objective_value,
                                          solve_time_seconds=solve_time_seconds,
                                          num_orders=length(order_book.orders),
                                          num_price_periods=length(prices)) : nothing

                # Save energy prices to database if requested
                if save_to_db
                    try
                        println("   💾 Saving $(length(prices)) price records to database...")
                        records_saved = save_energy_prices(prices, bidding_zone, date, order_method;
                                                           clearing_mode="single_zone",
                                                           optimization_run_id=optimization_run_id)
                        println("   ✅ Successfully saved $records_saved records to database")
                    catch db_error
                        println("   ⚠️  Warning: Failed to save prices to database: $db_error")
                    end
                end

                return prices

            catch mpcc_error
                solve_time_seconds = time() - optimization_start_time

                # Save failed optimization run with error details
                save_to_db && save_optimization_run(bidding_zone, date, order_method, model, optimizer, :error;
                    solve_time_seconds=solve_time_seconds,
                    num_orders=length(order_book.orders),
                    error_message=string(mpcc_error))

                rethrow(mpcc_error)
            end

        else
            error("Model $model not implemented yet")
        end

    catch e
        # Let DataUnavailableError bubble up to retry logic, handle all others
        if e isa DataUnavailableError
            rethrow(e)
        else
            println("❌ Error generating energy prices: $e")
            return Dict{String,Float64}()
        end
    end
end

"""
    get_available_zones(date::Date; fallback_zones::Vector{String}=String[])

Discover available bidding zones from the ENTSO-E database for a specific date.

This function queries the ENTSO-E production and generation units database to find
all bidding zones that have commissioned units on the specified date.

# Arguments
- `date::Date`: The target date for which to find available zones
- `fallback_zones::Vector{String}`: Optional fallback zones if database query fails

# Returns
- `Vector{String}`: Sorted list of available bidding zone codes

# Example
```julia
zones = get_available_zones(Date(2024, 10, 1))
println("Found \$(length(zones)) zones: \$(join(zones, \", \"))")

# With custom fallback
zones = get_available_zones(Date(2024, 10, 1); 
                           fallback_zones=["GR", "AT", "FR"])
```

The function:
1. Queries ENTSO-E database for zones with commissioned units on the target date
2. Filters by area type codes 'BZN' and 'BZN/CTA' (bidding zone codes)
3. Returns sorted list of unique zone codes
4. Falls back to provided zones if database query fails
5. Uses common European zones as final fallback if none provided
"""
function get_available_zones(date::Date; fallback_zones::Vector{String}=String[])
    # Query to get zones from ENTSO-E database
    query = """
    SELECT DISTINCT area_map_code
    FROM entsoe.production_and_generation_units
    WHERE production_unit_status = 'COMMISSIONED'
      AND generation_unit_status = 'COMMISSIONED'
      AND area_type_code IN ('BZN', 'BZN/CTA')
      AND \$1 >= valid_from
      AND (\$1 <= valid_to OR valid_to IS NULL)
      AND area_map_code IS NOT NULL
    ORDER BY area_map_code
    """

    try
        df = sql2df(query, [date])
        zones_raw = df.area_map_code
        # Filter out missing values and convert to String array
        zones_sorted = sort([string(zone) for zone in zones_raw if !ismissing(zone)])

        if !isempty(zones_sorted)
            return zones_sorted
        else
            @warn "No zones found in ENTSO-E database for $date"
        end

    catch e
        @warn "Failed to fetch zones from ENTSO-E database: $e"
    end

    # Use provided fallback zones
    if !isempty(fallback_zones)
        @info "Using provided fallback zones: " * join(fallback_zones, ", ")
        return sort(fallback_zones)
    end

    # Default fallback: common European zones that typically have data
    default_fallback = ["AT", "BE", "CH", "CZ", "DE", "ES", "FR", "GR", "IT", "NL", "PL"]
    @info "Using default fallback zones: " * join(default_fallback, ", ")

    return default_fallback
end

# =============================================================================
# MULTI-ZONE MARKET CLEARING WITH TRANSMISSION FLOWS
# =============================================================================

"""
    _create_multi_zone_order_book_alternative(zones::Vector{String}, day::Date; random_seed=nothing)

Internal helper to create a multi-zone order book using the alternative (faster) order generation method.
Uses `create_adjusted_order_book` for each zone and combines the results.
"""
function _create_multi_zone_order_book_alternative(zones::Vector{String}, day::Date; random_seed::Union{Int,Nothing}=nothing)
    if isempty(zones)
        error("At least one bidding zone must be specified")
    end

    println("🌍 Creating multi-zone order book (alternative method) for $(length(zones)) zones")

    # Aggregate orders from all zones
    all_orders = Vector{MarketOrders.MarketOrder}()
    all_periods = Set{String}()
    failed_zones = String[]

    for zone in zones
        try
            println("   📊 Processing zone $zone...")

            # Generate orders using alternative order book method
            result = create_adjusted_order_book(zone, day; random_seed=random_seed)

            if !result.success
                @warn "Failed to generate orders for zone $zone: $(result.message)"
                push!(failed_zones, zone)
                continue
            end

            # Extract orders from the result's order book
            append!(all_orders, result.order_book.orders)

            # Collect time periods
            for period in result.order_book.periods
                push!(all_periods, period)
            end

            println("      ✅ Added $(result.supply_orders) supply + $(result.demand_orders) demand orders")

        catch e
            @error "Error processing zone $zone: $e"
            push!(failed_zones, zone)
        end
    end

    # Determine successful zones
    successful_zones = filter(z -> !(z in failed_zones), zones)

    if isempty(successful_zones)
        error("Failed to generate orders for any zone")
    end

    if !isempty(failed_zones)
        @warn "Some zones failed: $(join(failed_zones, ", ")). Proceeding with: $(join(successful_zones, ", "))"
    end

    # Convert periods to sorted vector
    periods_vector = sort(collect(all_periods))

    if isempty(periods_vector)
        periods_vector = [string(h) for h in 1:24]
        @warn "No periods found in orders, defaulting to 24 hourly periods"
    end

    println("   📊 Detected $(length(periods_vector)) time periods")

    # Fetch transfer capacity from ENTSO-E for connections between these zones
    println("   🔌 Fetching transfer capacities between zones...")
    transfer_capacity = Network.create_transfer_capacity_from_entsoe(day, successful_zones)

    # Log connectivity info
    zone_pairs = Network.get_zone_pairs(transfer_capacity)
    println("   ✅ Found $(length(zone_pairs)) directional transfer capacity links")

    # Create the multi-zone order book
    order_book = MPCC.MPCCOrderBook(
        all_orders,
        successful_zones,
        periods_vector,
        (0.0, 500.0),           # Price limits (€/MWh)
        transfer_capacity       # Attach transfer capacity for multi-zone clearing
    )

    println("✅ Created multi-zone order book (alternative):")
    println("   🌍 Zones: $(length(successful_zones))")
    println("   📝 Total orders: $(length(all_orders))")
    println("   🕐 Time periods: $(length(periods_vector))")
    println("   🔌 Transfer links: $(length(zone_pairs))")

    return order_book
end

"""
    shadowed_aggregate_codes(footprint) -> Vector{String}

When a country is represented in the clearing footprint by its bidding-zone
sub-nodes (Italy: `IT-*`; Denmark: `DK1`/`DK2`), the ENTSO-E *aggregate* alias
for the same physical area (`IT`, `DK`) — and, for the German bidding zone
`DE_LU`, the four TSO control-area aliases — must never re-enter a footprint
zone's observed net imports. If they did, that country's cross-border energy
would be double-counted: once endogenously through the sub-node's power balance
and cross-border flow variables, and once again as a fixed observed injection
over the same physical interconnector filed under the aggregate code.

Returns the set of aggregate/alias map codes to exclude from observed net
imports for *every* footprint zone, given which sub-nodes are present. Codes
that are themselves footprint nodes are never returned.

Empirically these aliases are published at CTA/CTY area-type level and are
therefore already dropped by `get_net_imports`' `BZN`-both-sides filter, so this
is a defensive belt-and-suspenders layer: it is a no-op for the current data and
for any footprint without split-country sub-zones (e.g. the 5-zone SEE set,
which yields an empty result and is thus byte-identical to the prior behaviour).
"""
function shadowed_aggregate_codes(footprint::AbstractVector{<:AbstractString})
    fp = Set(String.(footprint))
    shadows = Set{String}()
    # Italy: any IT sub-zone present → the aggregate "IT" is a shadow alias
    any(z -> startswith(z, "IT-"), fp) && push!(shadows, "IT")
    # Denmark: DK1/DK2 present → the aggregate "DK" is a shadow alias
    (("DK1" in fp) || ("DK2" in fp)) && push!(shadows, "DK")
    # Germany: DE_LU bidding zone present → its TSO control-area aliases are shadows
    if "DE_LU" in fp
        for c in ("DE_50HzT", "DE_Amprion", "DE_TenneT_GER", "DE_TransnetBW")
            push!(shadows, c)
        end
    end
    # Never shadow a code that is itself a real footprint node
    return sort(collect(setdiff(shadows, fp)))
end

# Aggregate country codes whose *external* borders are filed only under the
# aggregate (not the bidding-zone sub-nodes), mapped to the sub-node that
# physically carries those continental borders. Confirmed case: Italy — the
# aggregate `IT` holds IT–FR/AT/SI/CH, all on the northern border, so they
# remap onto `IT-NORTH`. (Germany's DE_LU and Denmark's DK1/DK2 file their own
# BZN borders directly and need no remap — audited.)
const AGGREGATE_BORDER_REPRESENTATIVE = Dict{String,String}("IT" => "IT-NORTH")

# Nordic flow-based border handling. The Nordic CCR moved to flow-based DA
# capacity calculation in Oct 2024, so the implicit table's "offered ATC" rows
# for Nordic-internal borders are stale residuals. Where a zone's IMPORT
# capability lives in those residuals, endogenizing the border starves it into
# phantom scarcity at the cap (audited 2026-04: NO1 — fleet 2.4 GW vs 3.3–3.9
# GW load, published import ATC ~1.25 GW incl. SE3→NO1 = 0 MW, vs real imports
# ~2.3 GW; FI — SE1→FI published as 4 MW vs real imports ~2.3 GW). Dropping
# those borders makes the book keep observed net imports for them — the same
# honest treatment as other borders the ATC data cannot reproduce (RS, HU–RO).
#
# Deliberately NOT dropped: SE- and DK-internal borders. Their published rows
# are residuals too (SE2→SE3 = 8 MW vs ~7.3 GW physical), but the constrained
# EXPORT direction they impose fortuitously reproduces the real north–south
# congestion that keeps SE1/SE2 structurally cheap; replacing them with
# observed flows turns ~5 GW of exports into firm cap-priced demand against a
# thin unit fleet and manufactures scarcity (measured: SE1/SE2 bias +7/+9 with
# the borders endogenous vs +735/+710 with observed exports). A proper
# flow-based domain model is the eventual fix; until then this asymmetric
# treatment is the least-wrong ex-ante choice.
const NORDIC_FB_ZONES = ["NO1", "NO2", "NO3", "NO4", "NO5",
                         "SE1", "SE2", "SE3", "SE4", "FI", "DK1", "DK2"]
const NORDIC_NO_ZONES = ["NO1", "NO2", "NO3", "NO4", "NO5"]

"""
    nordic_flow_based_drop_borders(footprint) -> Vector{Tuple{String,String}}

Undirected border pairs whose stale flow-based ATC residuals must be dropped
from the enriched network (falling back to observed net imports): every
Nordic-internal border touching a Norwegian zone, plus Finland's import borders
from Sweden. Only pairs with both endpoints in the footprint are returned;
empty for footprints without Nordic zones (e.g. the 5-zone SEE set).
"""
function nordic_flow_based_drop_borders(footprint::AbstractVector{<:AbstractString})
    fp = Set(String.(footprint))
    pairs = Set{Tuple{String,String}}()
    ordered(a, b) = a < b ? (a, b) : (b, a)
    for no in NORDIC_NO_ZONES
        no in fp || continue
        for z in NORDIC_FB_ZONES
            z != no && z in fp && push!(pairs, ordered(no, z))
        end
    end
    if "FI" in fp
        for se in ("SE1", "SE3")
            se in fp && push!(pairs, ordered("FI", se))
        end
    end
    return sort(collect(pairs))
end

"""
    build_aggregate_remap(footprint) -> Dict{String,String}

Aggregate→representative-sub-zone remap entries applicable to a footprint: an
entry `agg => rep` is included only when the footprint contains `rep` (so the
representative exists as a node) but not `agg` itself. Empty for footprints
without split-country sub-zones (e.g. the 5-zone SEE set), so the enriched
network loader is a no-op there.
"""
function build_aggregate_remap(footprint::AbstractVector{<:AbstractString})
    fp = Set(String.(footprint))
    remap = Dict{String,String}()
    for (agg, rep) in AGGREGATE_BORDER_REPRESENTATIVE
        (rep in fp) && !(agg in fp) && (remap[agg] = rep)
    end
    return remap
end

"""
    compute_opportunity_anchor_refs(anchored_zones, market_prices, transfer_capacity)
        -> Dict{String,Dict{String,Float64}}

Per-zone reference prices for the two-pass opportunity anchor, extracted from
pass-1 clearing prices: for each anchored zone, the capacity-weighted average
pass-1 price of its ENDOGENOUS neighbors per timeslot (weight = total border
ATC over the day, both directions). Zones without endogenous neighbors (the
Norwegian zones — their flow-based borders are dropped) fall back to the
continental proxy: the DE_LU/NL average. The result carries both the daily
level and the hourly shape of the coupled price. All inputs are
model-internal (pass-1 output), so the anchor keeps the counterfactual
ex-ante — no observed prices enter.
"""
function compute_opportunity_anchor_refs(anchored_zones::Vector{String},
    market_prices::Dict{String,Dict{String,Float64}},
    transfer_capacity)

    proxy_zones = [z for z in ("DE_LU", "NL") if haskey(market_prices, z)]
    refs = Dict{String,Dict{String,Float64}}()
    for z in anchored_zones
        # Border-capacity weights toward endogenous neighbors
        w = Dict{String,Float64}()
        if transfer_capacity !== nothing
            for ((a, b, _), cap) in transfer_capacity.capacity_forward
                other = a == z ? b : (b == z ? a : nothing)
                other === nothing && continue
                haskey(market_prices, other) || continue
                w[other] = get(w, other, 0.0) + max(cap, 0.0)
            end
        end
        sources = if !isempty(w) && sum(values(w)) > 0
            w
        else
            Dict{String,Float64}(pz => 1.0 for pz in proxy_zones)
        end
        isempty(sources) && continue
        ref = Dict{String,Float64}()
        # Weighted mean per timeslot over the sources that price that slot
        slots = union((Set(keys(market_prices[src])) for src in keys(sources))...)
        for ts in slots
            num = 0.0; den = 0.0
            for (src, wt) in sources
                haskey(market_prices[src], ts) || continue
                num += wt * market_prices[src][ts]; den += wt
            end
            den > 0 && (ref[ts] = num / den)
        end
        isempty(ref) || (refs[z] = ref)
        src_desc = isempty(w) ? "continental proxy $(join(proxy_zones, "/"))" :
                   join(sort(collect(keys(w))), ",")
        println("   ⚓ Anchor ref for $z from $src_desc: " *
                "mean=$(round(sum(values(ref))/max(length(ref),1), digits=1)) €/MWh")
    end
    return refs
end

"""
    _create_multi_zone_order_book_merit(zones::Vector{String}, day::Date)

Multi-zone order book built from per-zone merit-order books.

Flows over borders that have ATC data inside the clearing set are endogenous
(ATC-constrained MPCC flow variables), so observed net-import injections are
excluded for exactly those borders. In-set borders WITHOUT ATC links keep
their observed injections: implicit-coupling capacity data does not exist for
them (e.g. RS has no implicitly coupled borders, HU–RO moved to flow-based
coupling in June 2022), so the model cannot reproduce those flows
endogenously — excluding them would silently remove real energy from the
books and price phantom scarcity.
"""
function _create_multi_zone_order_book_merit(zones::Vector{String}, day::Date;
    enrich_network::Bool=false, apply_zone_profiles::Bool=true,
    anchor_refs::Dict{String,Dict{String,Float64}}=Dict{String,Dict{String,Float64}}(),
    cached_zone_orders::Dict{String,Vector{MarketOrders.MarketOrder}}=Dict{String,Vector{MarketOrders.MarketOrder}}())
    isempty(zones) && error("At least one bidding zone must be specified")

    println("🌍 Creating multi-zone order book (merit-order method) for $(length(zones)) zones")

    # Network enrichment (opt-in, EU-footprint only): union explicit ATC (adds
    # CH + Serbia borders) and remap aggregate borders onto sub-zones (adds
    # Italy's continental IT-NORTH↔FR/AT/SI/CH). Also coalesces missing RES
    # forecasts so partial-coverage zones (CH, RS) build a book instead of
    # failing. Left off by default so the 5-zone SEE product is byte-identical.
    aggregate_remap = enrich_network ? build_aggregate_remap(zones) : Dict{String,String}()

    drop_borders = enrich_network ? nordic_flow_based_drop_borders(zones) :
                   Tuple{String,String}[]

    println("   🔌 Fetching transfer capacities between zones...")
    transfer_capacity = Network.create_transfer_capacity_from_entsoe(day, zones;
        include_explicit=enrich_network, aggregate_remap=aggregate_remap,
        drop_borders=drop_borders)
    zone_pairs = Network.get_zone_pairs(transfer_capacity)
    # A border only counts as endogenous if it can actually carry flow:
    # ATC rows with zero capacity in both directions all day (e.g. an
    # interconnector on full-day outage) bound the flow variable to zero,
    # so excluding observed imports over such a border would remove real
    # energy with no endogenous substitute
    can_carry_flow = Set{Tuple{String,String}}()
    for ((s, d, _), cap) in transfer_capacity.capacity_forward
        cap > 0 && push!(can_carry_flow, (s, d))
    end
    for ((s, d, _), cap) in transfer_capacity.capacity_backward
        cap > 0 && push!(can_carry_flow, (s, d))
    end
    atc_linked = Dict{String,Set{String}}(z => Set{String}() for z in zones)
    for (a, b) in zone_pairs
        (a in zones && b in zones && (a, b) in can_carry_flow) || continue
        push!(atc_linked[a], b)
        push!(atc_linked[b], a)
    end

    # Aggregate/alias codes for countries represented here by sub-zones must be
    # dropped from EVERY footprint zone's observed net imports (defensive — the
    # BZN-both-sides filter in get_net_imports already excludes them). Empty for
    # footprints without split-country sub-zones, so the 5-zone SEE path is
    # unchanged.
    shadow_codes = shadowed_aggregate_codes(zones)
    isempty(shadow_codes) ||
        println("   🚫 Shadowed aggregate codes excluded from observed imports: $(join(shadow_codes, ", "))")

    zone_exclude(keep::Vector{String}) = sort(unique(vcat(keep, shadow_codes)))

    function build_zone_book(zone::String, exclude::Vector{String})
        kept = sort([z for z in zones if z != zone && !(z in exclude)])
        isempty(kept) ||
            println("      ℹ️  No usable ATC link to $(join(kept, ", ")) — keeping observed net imports for those borders")
        # Per-zone region profile selects the bid-construction calibration.
        # In the SEE product (enrich_network=false) every zone resolves to
        # SEE_PROFILE, which equals the pre-abstraction defaults, so the call is
        # byte-identical; the EU footprint applies region-specific profiles.
        profile = (enrich_network && apply_zone_profiles) ?
                  MeritOrderBook.get_zone_profile(zone) : MeritOrderBook.SEE_PROFILE
        # Over DROPPED flow-based borders, observed flows enter import-only:
        # the import supplies a starving importer (NO1's 2.3 GW), but the
        # corresponding export must not become firm cap-priced demand in the
        # exporter's book (see get_net_imports docstring). Empty when no
        # borders were dropped, so the SEE path is unchanged.
        import_only = sort([other for (a, b) in drop_borders
                            for other in ((a == zone) ? [b] : (b == zone) ? [a] : String[])])
        return create_merit_order_book(zone, day;
            profile=profile,
            net_import_exclude=exclude,
            net_import_import_only=import_only,
            target_resolution_minutes=60,
            res_coalesce_missing=enrich_network,
            anchor_prices=get(anchor_refs, zone, nothing))
    end

    zone_orders = Dict{String,Vector{MarketOrders.MarketOrder}}()
    all_periods = Set{String}()
    failed_zones = String[]

    for zone in zones
        try
            # Pass-2 reuse: zones without an anchor keep their pass-1 orders
            # verbatim (books are deterministic; only anchored zones re-bid).
            if haskey(cached_zone_orders, zone) && !haskey(anchor_refs, zone)
                zone_orders[zone] = cached_zone_orders[zone]
                for o in cached_zone_orders[zone]
                    push!(all_periods, Dates.format(o.date_time, "yyyymmdd-HHMM"))
                end
                println("   ♻️  Zone $zone: reusing pass-1 book ($(length(cached_zone_orders[zone])) orders)")
                continue
            end
            println("   📊 Processing zone $zone...")
            result = build_zone_book(zone, zone_exclude(sort(collect(atc_linked[zone]))))

            if !result.success
                @warn "Failed to generate merit orders for zone $zone: $(result.message)"
                push!(failed_zones, zone)
                continue
            end

            zone_orders[zone] = result.order_book.orders
            for period in result.order_book.periods
                push!(all_periods, period)
            end
            println("      ✅ Added $(result.supply_orders) supply + $(result.demand_orders) demand orders")
        catch e
            e isa InterruptException && rethrow()
            @error "Error processing zone $zone: $e"
            push!(failed_zones, zone)
        end
    end

    successful_zones = filter(z -> !(z in failed_zones), zones)
    isempty(successful_zones) && error("Failed to generate merit orders for any zone")
    if !isempty(failed_zones)
        @warn "Some zones failed: $(join(failed_zones, ", ")). Proceeding with: $(join(successful_zones, ", "))"
        # A failed zone contributes no node to the book, so the MPCC drops
        # its flow variables — any surviving zone that excluded observed
        # imports over a border to it would lose that border's energy
        # entirely. Rebuild those zones' books keeping the observed imports.
        for zone in successful_zones
            affected = sort([c for c in atc_linked[zone] if c in failed_zones])
            isempty(affected) && continue
            @warn "Rebuilding $zone book: ATC-linked zone(s) $(join(affected, ", ")) failed — restoring their observed net imports"
            exclude = zone_exclude(sort([c for c in atc_linked[zone] if !(c in failed_zones)]))
            result = build_zone_book(zone, exclude)
            result.success || error("Rebuild of $zone book failed: $(result.message)")
            zone_orders[zone] = result.order_book.orders
            for period in result.order_book.periods
                push!(all_periods, period)
            end
        end
    end

    all_orders = Vector{MarketOrders.MarketOrder}()
    for zone in successful_zones
        append!(all_orders, zone_orders[zone])
    end

    periods_vector = sort(collect(all_periods))

    # Transfer capacities were fetched up front (to decide which borders'
    # observed net imports to exclude); links to failed zones are filtered
    # out by the MPCC solver, which restricts pairs to the book's nodes.
    println("   ✅ Found $(length(zone_pairs)) directional transfer capacity links")

    order_book = MPCC.MPCCOrderBook(
        all_orders,
        successful_zones,
        periods_vector,
        (-500.0, 3000.0),       # EU day-ahead floor / merit demand cap
        transfer_capacity
    )

    println("✅ Created multi-zone order book (merit-order):")
    println("   🌍 Zones: $(length(successful_zones))  📝 Orders: $(length(all_orders))  🕐 Periods: $(length(periods_vector))  🔌 Links: $(length(zone_pairs))")

    return order_book
end

"""
    run_multi_zone_market_clearing(date::Date;
                                   zones::Vector{String}=String[],
                                   order_method::Symbol=:uc_based,
                                   optimizer::String="auto",
                                   markup_factor::Float64=1.1,
                                   silent::Bool=true,
                                   save_to_db::Bool=false,
                                   force_rerun::Bool=false,
                                   parallel::Bool=false)

Run simultaneous multi-zone market clearing with cross-border transmission flows.

Unlike `generate_energy_prices_for_all_zones()` which processes zones independently,
this function solves all zones together in a single optimization problem with
transmission flow constraints between zones based on ENTSO-E ATC data.

# Arguments
- `date::Date`: The date for which to run market clearing
- `zones::Vector{String}`: List of bidding zones to include (default: auto-discover from DB)
- `order_method::Symbol`: Method for creating orders - `:uc_based`, `:alternative` or `:merit_order` (default: `:uc_based`)
- `optimizer::String`: Optimization solver - "highs" (default), "gurobi", "cplex", "auto"
- `markup_factor::Float64`: Price markup factor for supply bids (default: 1.1)
- `silent::Bool`: Whether to suppress solver output (default: true)
- `save_to_db::Bool`: Whether to save results to database (default: false)
- `force_rerun::Bool`: Whether to force UC re-solve, bypassing cache (default: false)
- `parallel::Bool`: Whether to run UC for each zone in parallel using Distributed.jl (default: false)

# Returns
- `MPCCResult`: Market clearing results including:
  - `market_prices`: Dict of prices per zone per time period
  - `transmission_flows`: Dict of cross-border flows per zone pair per period
  - `status`: Optimization status (:optimal, :infeasible, etc.)
  - `solve_time`: Time taken to solve the optimization

# Example
```julia
using Euphemia, Dates

# Auto-discover zones and run multi-zone clearing
result = run_multi_zone_market_clearing(Date(2024, 6, 15))

# Check zonal prices
for (zone, prices) in result.market_prices
    avg_price = mean(values(prices))
    println("\$zone: avg price = €\$(round(avg_price, digits=2))/MWh")
end

# Check transmission flows
for (flow_id, flows) in result.transmission_flows
    avg_flow = mean(values(flows))
    println("\$flow_id: avg flow = \$(round(avg_flow, digits=1)) MW")
end

# Run with specific zones
result = run_multi_zone_market_clearing(Date(2024, 6, 15);
    zones=["GR", "BG", "IT_SOUTH"],
    save_to_db=true)
```

# Notes
- Zones must have transfer capacity data in `entsoe.offered_transfer_capacities_implicit`
- Zones without UC data will be skipped with a warning
- ATC constraints bound flows: -backward_cap ≤ flow ≤ forward_cap
- Transmission is modeled as lossless (no losses on flows)
"""
function run_multi_zone_market_clearing(date::Date;
                                        zones::Vector{String}=String[],
                                        order_method::Symbol=:uc_based,
                                        optimizer::String="auto",
                                        markup_factor::Float64=1.1,
                                        silent::Bool=true,
                                        save_to_db::Bool=false,
                                        force_rerun::Bool=false,
                                        parallel::Bool=false,
                                        max_workers::Union{Int, Nothing}=nothing,
                                        clearing_mode::String="multi_zone",
                                        enrich_network::Bool=false,
                                        apply_zone_profiles::Bool=true,
                                        passes::Int=1)

    start_time = time()
    # Label the optimization_runs row so a non-standard footprint (e.g. the
    # Europe-wide "multi_zone_eu" experiment) does not collide with the standard
    # "MULTI_ZONE" run for the same date. Default preserves prior behaviour.
    run_zone_label = clearing_mode == "multi_zone" ? "MULTI_ZONE" :
                     "MULTI_ZONE_" * uppercase(replace(clearing_mode, "multi_zone_" => ""))

    println("=" ^ 60)
    println("🌍 MULTI-ZONE MARKET CLEARING WITH TRANSMISSION FLOWS")
    println("   Date: $date")
    println("=" ^ 60)

    # Discover zones if not provided
    if isempty(zones)
        println("\n🔍 Discovering available zones from transfer capacity data...")
        zones = Network.get_zones_with_transfer_capacity(date)

        if isempty(zones)
            error("No zones found in transfer capacity data for $date")
        end
    end

    println("\n📋 Target zones: $(join(zones, ", "))")
    println("   📋 Order method: $order_method")

    # Create multi-zone order book based on order_method
    println("\n📊 Creating multi-zone order book...")
    order_book = if order_method == :uc_based
        # UC-based: runs full unit commitment for each zone (slower but more accurate)
        MPCC.create_multi_zone_order_book(zones, date;
                                          markup_factor=markup_factor,
                                          optimizer=optimizer,
                                          force_rerun=force_rerun,
                                          parallel=parallel,
                                          max_workers=max_workers)
    elseif order_method == :alternative
        # Alternative: uses simplified order generation (faster)
        _create_multi_zone_order_book_alternative(zones, date)
    elseif order_method == :merit_order
        # Merit-order: deterministic strategy-based books per zone,
        # cross-zone flows endogenous via ATC-constrained MPCC
        _create_multi_zone_order_book_merit(zones, date; enrich_network=enrich_network,
                                            apply_zone_profiles=apply_zone_profiles)
    else
        error("Invalid order_method: $order_method. Must be :uc_based, :alternative or :merit_order")
    end

    # Run MPCC market clearing with transmission constraints
    println("\n⚡ Running multi-zone market clearing optimization...")
    mpcc_result = MPCC.solve_mpcc_market_clearing(order_book;
                                                   preferred_solver=optimizer,
                                                   silent=silent)

    # TWO-PASS opportunity-anchor clearing (opt-in via passes=2, merit-order
    # only). Pass 1 above cleared the standard books; zones whose profile
    # opts in (opportunity_anchor != :none — southern Norway :hydro, France
    # :nuclear) now re-bid their dominant modulating resource at opportunity
    # cost against the pass-1 coupled reference price, and the footprint is
    # re-cleared. Non-anchored zones reuse their pass-1 books verbatim. With
    # passes=1 (default) this block is dead code — SEE and the current EU
    # paths are unchanged.
    pass1_solve_time = mpcc_result.solve_time
    if passes >= 2 && order_method == :merit_order &&
       (mpcc_result.status == :optimal ||
        (mpcc_result.status == :time_limit && !isempty(mpcc_result.market_prices)))
        anchored = apply_zone_profiles ?
            [z for z in order_book.nodes
             if MeritOrderBook.get_zone_profile(z).opportunity_anchor != :none &&
                haskey(mpcc_result.market_prices, z)] : String[]
        if isempty(anchored)
            println("\n⚓ passes=$passes requested but no zone profile opts into an opportunity anchor — keeping pass-1 result")
        else
            println("\n⚓ PASS 2: opportunity-anchored re-clear for $(join(anchored, ", "))")
            refs = compute_opportunity_anchor_refs(anchored,
                mpcc_result.market_prices, order_book.network_topology)
            cached = Dict{String,Vector{MarketOrders.MarketOrder}}(
                z => [o for o in order_book.orders if String(o.zone) == z]
                for z in order_book.nodes)
            order_book2 = _create_multi_zone_order_book_merit(zones, date;
                enrich_network=enrich_network,
                apply_zone_profiles=apply_zone_profiles,
                anchor_refs=refs,
                cached_zone_orders=cached)
            println("\n⚡ Running pass-2 market clearing optimization...")
            result2 = MPCC.solve_mpcc_market_clearing(order_book2;
                preferred_solver=optimizer, silent=silent)
            if result2.status == :optimal ||
               (result2.status == :time_limit && !isempty(result2.market_prices))
                order_book = order_book2
                mpcc_result = result2
                println("   ⚓ Pass 2 accepted (status=$(result2.status), " *
                        "solve=$(round(result2.solve_time, digits=1))s; " *
                        "pass 1 was $(round(pass1_solve_time, digits=1))s)")
            else
                @warn "Pass-2 clearing failed (status=$(result2.status)) — falling back to pass-1 result"
            end
        end
    end

    total_time = time() - start_time

    # Update result with correct total_time (includes order book creation)
    result = MPCC.with_total_time(mpcc_result, total_time)

    # Report results
    println("\n" * "=" ^ 60)
    println("📊 MULTI-ZONE CLEARING RESULTS")
    println("=" ^ 60)
    println("   Status: $(result.status)")
    println("   Solve time: $(round(result.solve_time, digits=2))s (total: $(round(result.total_time, digits=2))s)")

    # A time-limited solve still returns its best incumbent — usable, but
    # the optimality gap is unproven, so warn loudly
    result.status == :time_limit && !isempty(result.market_prices) &&
        @warn "Multi-zone MPCC hit the solve time limit for $date — using best incumbent (optimality gap unproven; prices may contain tolerance artifacts)"
    if result.status == :optimal ||
       (result.status == :time_limit && !isempty(result.market_prices))
        println("   Objective value: $(round(result.objective_value, digits=2))")

        # Report zonal prices
        println("\n💰 Zonal Clearing Prices (avg):")
        for zone in order_book.nodes
            if haskey(result.market_prices, zone)
                prices = values(result.market_prices[zone])
                avg_price = isempty(prices) ? 0.0 : sum(prices) / length(prices)
                min_price = isempty(prices) ? 0.0 : minimum(prices)
                max_price = isempty(prices) ? 0.0 : maximum(prices)
                println("   $zone: avg=€$(round(avg_price, digits=2))/MWh (min=$(round(min_price, digits=2)), max=$(round(max_price, digits=2)))")
            end
        end

        # Report transmission flows
        if !isempty(result.transmission_flows)
            println("\n🔌 Cross-Border Flows (avg):")
            for (flow_id, flows) in result.transmission_flows
                flow_values = values(flows)
                avg_flow = isempty(flow_values) ? 0.0 : sum(flow_values) / length(flow_values)
                min_flow = isempty(flow_values) ? 0.0 : minimum(flow_values)
                max_flow = isempty(flow_values) ? 0.0 : maximum(flow_values)
                # Only print if there's significant flow
                if abs(avg_flow) > 0.1 || abs(max_flow) > 0.1
                    println("   $flow_id: avg=$(round(avg_flow, digits=1))MW (min=$(round(min_flow, digits=1)), max=$(round(max_flow, digits=1)))")
                end
            end
        end

        # Save to database if requested
        if save_to_db
            println("\n💾 Saving results to database...")
            try
                # Save optimization run record first and get the ID
                optimization_run_id = save_optimization_run(
                    run_zone_label,  # Special identifier for multi-zone runs (footprint-aware)
                    date,
                    order_method,
                    :mpcc_multi_zone,
                    result.solver_name,
                    result.status;
                    objective_value=result.objective_value,
                    solve_time_seconds=result.solve_time,
                    num_orders=length(order_book.orders),
                    num_price_periods=length(order_book.periods)
                )

                # Save prices for each zone with the optimization run ID
                for zone in order_book.nodes
                    if haskey(result.market_prices, zone)
                        save_energy_prices(result.market_prices[zone], zone, date, order_method;
                                           clearing_mode=clearing_mode,
                                           optimization_run_id=optimization_run_id)
                    end
                end

                # Save transmission flows
                if !isempty(result.transmission_flows)
                    save_transmission_flows(result.transmission_flows, date)
                end

                println("   ✅ Results saved to database")
            catch e
                @error "Failed to save results to database: $e"
            end
        end
    else
        println("   ⚠️  Optimization did not find optimal solution")
        println("   Message: $(result.message)")
    end

    println("\n" * "=" ^ 60)

    return result
end

"""
    run_iterative_multi_zone_market_clearing(date; kwargs...) -> NamedTuple

Run multi-zone market clearing with iterative UC-MPCC to account for
interconnection flows in unit commitment decisions.

The algorithm iterates between:
1. Solving UC for each zone (with adjusted demand based on expected flows)
2. Running MPCC to determine actual market flows
3. Updating expected flows based on MPCC results

Iteration continues until prices converge or max iterations reached.

# Convergence Criterion

**Primary: Price-based convergence** (recommended by market coupling theory)

Convergence is declared when: `max|λᶻ(k) − λᶻ(k−1)| < price_tolerance`

Price-based convergence is preferred over flow-based because:
- Prices are the economic fixed point of market coupling
- Flows are derived quantities that can oscillate near binding constraints
- UC binaries cause discontinuous flow changes even when prices are stable
- This matches how real market coupling (e.g., Euphemia) operates

Flow changes are logged as diagnostics but not used for convergence.

# Arguments
- `date::Date`: Market date
- `zones::Vector{String}`: Zones to include (empty = auto-discover)
- `optimizer::String`: Solver for MPCC ("highs" or "gurobi")
- `max_iterations::Int`: Maximum iteration count (default: 10)
- `price_tolerance::Float64`: Max price change for convergence in €/MWh (default: 1.0)
- `damping_factor::Float64`: Update damping α ∈ (0,1] (default: 0.7)
- `markup_factor::Float64`: Bid markup over marginal cost (default: 1.1)
- `silent::Bool`: Suppress solver output (default: true)
- `save_to_db::Bool`: Save final results to database (default: false)
- `parallel::Bool`: Parallelize UC across zones within each iteration (default: false)

# Returns
NamedTuple with all MPCCResult fields plus:
- `iterations::Int`: Number of iterations performed
- `converged::Bool`: Whether convergence was achieved
- `final_net_imports::Dict`: Final net imports per zone
- `convergence_metrics::NamedTuple`: Detailed convergence info (price_change, flow_change_pct)

# Caching Behavior
- Each iteration uses `force_rerun=true` to ensure fresh UC solves
- Only the final converged result is retained in cache (DELETE-before-INSERT)
- No database pollution: one cache entry per (zone, date, version)

# Example
```julia
result = run_iterative_multi_zone_market_clearing(
    Date(2025, 12, 10);
    zones=["GR", "IT-NORTH", "IT-SOUTH"],
    optimizer="gurobi",
    max_iterations=10,
    price_tolerance=1.0,  # €/MWh
    parallel=false  # Respect Gurobi license limits
)

println("Converged: \$(result.converged) in \$(result.iterations) iterations")
println("Final price change: \$(result.convergence_metrics.price_change) €/MWh")
```

See also: [`run_multi_zone_market_clearing`](@ref), [`compute_max_price_change`](@ref)
"""
function run_iterative_multi_zone_market_clearing(date::Date;
    zones::Vector{String}=String[],
    optimizer::String="auto",
    max_iterations::Int=10,
    price_tolerance::Float64=1.0,
    damping_factor::Float64=0.7,
    markup_factor::Float64=1.1,
    silent::Bool=true,
    save_to_db::Bool=false,
    parallel::Bool=false,
    max_workers::Union{Int, Nothing}=nothing
)
    total_start_time = time()

    println("\n" * "=" ^ 60)
    println("🔄 ITERATIVE MULTI-ZONE MARKET CLEARING")
    println("=" ^ 60)
    println("📅 Date: $date")
    println("⚙️  Max iterations: $max_iterations")
    println("💰 Price tolerance: $price_tolerance €/MWh")
    println("🎚️  Damping factor: $damping_factor")
    if parallel
        workers_info = isnothing(max_workers) ? "all available" : "max $max_workers"
        println("⚡ Parallel: enabled ($workers_info workers)")
    end

    # Discover zones if not provided
    if isempty(zones)
        zones = Network.get_zones_with_transfer_capacity(date)
        println("📍 Auto-discovered $(length(zones)) zones with transfer capacity")
    else
        println("📍 Using $(length(zones)) specified zones: $(join(zones, ", "))")
    end

    if length(zones) < 2
        error("Iterative UC-MPCC requires at least 2 zones")
    end

    # NOTE: Transfer capacities (ATC) are loaded internally by create_multi_zone_order_book()
    # from entsoe.offered_transfer_capacities_implicit - no explicit loading needed here

    # Initialize iteration state
    expected_net_imports = nothing  # No adjustment for iteration 1
    previous_prices = nothing
    previous_flows = nothing
    best_result = nothing
    order_book = nothing
    converged = false
    iteration = 0
    final_price_change = Inf
    final_flow_change_pct = Inf

    for iter in 1:max_iterations
        iteration = iter
        iter_start_time = time()
        println("\n" * "-" ^ 40)
        println("📊 Iteration $iter / $max_iterations")

        # Step 1: Create order book with current flow expectations
        # Always use force_rerun=true to get fresh UC with current flow adjustments
        order_book = MPCC.create_multi_zone_order_book(zones, date;
            markup_factor=markup_factor,
            optimizer=optimizer,
            use_cache=true,
            force_rerun=true,  # Always fresh solve
            parallel=parallel,
            max_workers=max_workers,
            net_imports_by_zone=expected_net_imports
        )

        # Step 2: Solve MPCC
        mpcc_start = time()
        result = MPCC.solve_mpcc_market_clearing(order_book;
            preferred_solver=optimizer,
            silent=silent
        )
        mpcc_time = time() - mpcc_start

        if result.status != :optimal
            @warn "MPCC failed at iteration $iter with status: $(result.status)"
            if best_result !== nothing
                println("⚠️  Returning best result from previous iteration")
                break
            else
                error("MPCC failed on first iteration: $(result.status)")
            end
        end

        best_result = result

        # Step 3: Compute convergence metrics
        # Primary: Price-based convergence (economic fixed point)
        price_change = MPCC.compute_max_price_change(result.market_prices, previous_prices)

        # Secondary (diagnostic): Relative flow change
        flow_change_pct = MPCC.compute_max_relative_flow_change(result.transmission_flows, previous_flows) * 100

        # Also compute net imports for UC adjustment
        actual_net_imports = MPCC.compute_net_imports_from_flows(result.transmission_flows, zones)

        iter_time = time() - iter_start_time

        # Log metrics
        println("   MPCC solve: $(round(mpcc_time, digits=2))s")
        println("   💰 Price change: $(round(price_change, digits=2)) €/MWh")
        println("   🔌 Flow change: $(round(flow_change_pct, digits=1))% (diagnostic)")
        println("   Iteration time: $(round(iter_time, digits=2))s")

        # Store final metrics
        final_price_change = price_change
        final_flow_change_pct = flow_change_pct

        # Step 4: Check convergence (price-based)
        if price_change < price_tolerance
            converged = true
            println("✅ Converged! Price change $(round(price_change, digits=2)) €/MWh < tolerance $price_tolerance €/MWh")
            break
        end

        # Step 5: Apply damping and update expected flows for next iteration
        previous_prices = result.market_prices
        previous_flows = result.transmission_flows
        expected_net_imports = MPCC.apply_damping(actual_net_imports, expected_net_imports, damping_factor)
    end

    total_time = time() - total_start_time

    println("\n" * "-" ^ 40)
    if converged
        println("✅ CONVERGED in $iteration iterations")
        println("   💰 Final price change: $(round(final_price_change, digits=2)) €/MWh")
        println("   🔌 Final flow change: $(round(final_flow_change_pct, digits=1))%")
    else
        println("⚠️  Did NOT converge after $iteration iterations")
        println("   💰 Final price change: $(round(final_price_change, digits=2)) €/MWh (tolerance: $price_tolerance)")
    end
    println("⏱️  Total time: $(round(total_time, digits=2))s")

    # Save to database if requested (only final result)
    if save_to_db && best_result !== nothing && best_result.status == :optimal
        println("\n💾 Saving final results to database...")
        try
            # Save optimization run record first and get the ID
            # Include iterative metadata for later analysis
            optimization_run_id = save_optimization_run(
                "MULTI_ZONE_ITERATIVE",  # Use special identifier for iterative runs
                date,
                :uc_based,
                :mpcc_iterative,
                best_result.solver_name,
                best_result.status;
                objective_value=best_result.objective_value,
                solve_time_seconds=best_result.solve_time,
                num_orders=length(order_book.orders),
                num_price_periods=length(order_book.periods),
                # Iterative optimization metadata
                is_iterative=true,
                total_time_seconds=total_time,
                iterations=iteration,
                converged=converged,
                final_price_change=final_price_change,
                final_flow_change_pct=final_flow_change_pct
            )

            # Save prices for each zone with the optimization run ID
            for zone in zones
                if haskey(best_result.market_prices, zone)
                    save_energy_prices(best_result.market_prices[zone], zone, date, :uc_based;
                                       clearing_mode="multi_zone_iterative",
                                       optimization_run_id=optimization_run_id)
                end
            end

            # Save transmission flows
            if !isempty(best_result.transmission_flows)
                save_transmission_flows(best_result.transmission_flows, date)
            end

            println("   ✅ Results saved to database")
        catch e
            @error "Failed to save results to database: $e"
        end
    end

    # Return enriched result
    return (
        # All MPCCResult fields
        status=best_result.status,
        objective_value=best_result.objective_value,
        market_prices=best_result.market_prices,
        stepwise_acceptance=best_result.stepwise_acceptance,
        block_acceptance=best_result.block_acceptance,
        block_activation=best_result.block_activation,
        transmission_flows=best_result.transmission_flows,
        solve_time=best_result.solve_time,
        total_time=total_time,
        solver_name=best_result.solver_name,
        message=best_result.message,
        # Additional iteration metadata
        iterations=iteration,
        converged=converged,
        final_net_imports=expected_net_imports,
        convergence_metrics=(
            price_change=final_price_change,
            flow_change_pct=final_flow_change_pct
        )
    )
end

"""
    run_multi_zone_for_date_range(start_date::Date, end_date::Date;
                                  zones::Vector{String}=String[],
                                  order_method::Symbol=:uc_based,
                                  optimizer::String="auto",
                                  markup_factor::Float64=1.1,
                                  silent::Bool=true,
                                  save_to_db::Bool=false,
                                  skip_existing::Bool=true,
                                  force_rerun::Bool=false,
                                  parallel::Bool=false)

Run multi-zone market clearing with cross-border transmission flows for a date range.

Processes multiple dates sequentially, running `run_multi_zone_market_clearing()` for each date.
Provides comprehensive progress tracking and timing statistics.

# Arguments
- `start_date::Date`: First date to process (inclusive)
- `end_date::Date`: Last date to process (inclusive)
- `zones::Vector{String}`: List of bidding zones to include (default: auto-discover from DB)
- `order_method::Symbol`: Method for creating orders - `:uc_based`, `:alternative` or `:merit_order` (default: `:uc_based`)
- `optimizer::String`: Optimization solver - "highs" (default), "gurobi", "cplex", "auto"
- `markup_factor::Float64`: Price markup factor for supply bids (default: 1.1)
- `silent::Bool`: Whether to suppress solver output (default: true)
- `save_to_db::Bool`: Whether to save results to database (default: false)
- `skip_existing::Bool`: Whether to skip dates that already have data (default: true)
- `force_rerun::Bool`: Whether to force UC re-solve, bypassing cache (default: false)
- `parallel::Bool`: Whether to run UC for each zone in parallel using Distributed.jl (default: false)

# Returns
- `NamedTuple` with the following fields:
  - `date_results::Vector{NamedTuple}`: Results for each date processed
  - `total_dates::Int`: Total number of dates in the range
  - `successful_dates::Int`: Number of dates processed successfully
  - `failed_dates::Int`: Number of dates that failed
  - `skipped_dates::Int`: Number of dates skipped (if skip_existing=true)
  - `total_time::Float64`: Total processing time for entire date range in seconds
  - `avg_time_per_date::Float64`: Average processing time per date in seconds

Each date result contains:
- `date::Date`: The date processed
- `success::Bool`: Whether the date was processed successfully
- `result::Union{MPCCResult,Nothing}`: The MPCC result (or nothing if failed)
- `elapsed_time::Float64`: Processing time for this date
- `num_zones::Int`: Number of zones processed
- `error_message::String`: Error details (empty if successful)

# Example
```julia
using Euphemia, Dates

# Process a week of multi-zone market clearing
result = run_multi_zone_for_date_range(
    Date(2024, 6, 1),
    Date(2024, 6, 7);
    save_to_db=true
)

println("Processed \$(result.successful_dates)/\$(result.total_dates) dates")
println("Total time: \$(round(result.total_time/60, digits=1)) minutes")
println("Average per date: \$(round(result.avg_time_per_date, digits=1)) seconds")

# Analyze results
for dr in result.date_results
    if dr.success
        println("\$(dr.date): \$(dr.num_zones) zones, \$(round(dr.elapsed_time, digits=1))s")
    else
        println("\$(dr.date): FAILED - \$(dr.error_message)")
    end
end
```
"""
function run_multi_zone_for_date_range(start_date::Date, end_date::Date;
                                       zones::Vector{String}=String[],
                                       order_method::Symbol=:uc_based,
                                       optimizer::String="auto",
                                       markup_factor::Float64=1.1,
                                       silent::Bool=true,
                                       save_to_db::Bool=false,
                                       skip_existing::Bool=true,
                                       force_rerun::Bool=false,
                                       parallel::Bool=false)

    # Validate date range
    if start_date > end_date
        error("start_date ($start_date) cannot be after end_date ($end_date)")
    end

    # Generate date range
    dates = collect(start_date:Day(1):end_date)
    total_dates = length(dates)

    println("=" ^ 70)
    println("🌍 MULTI-ZONE MARKET CLEARING FOR DATE RANGE")
    println("=" ^ 70)
    println("   📅 Date range: $start_date to $end_date ($total_dates days)")
    println("   📋 Order method: $order_method")
    println("   🔧 Optimizer: $optimizer")
    if !isempty(zones)
        println("   🗺️  Zones: $(join(zones, ", "))")
    else
        println("   🗺️  Zones: auto-discover")
    end
    if save_to_db
        println("   💾 Database saving: enabled")
    end
    println()

    range_start_time = time()
    date_results = NamedTuple[]

    successful_dates = 0
    failed_dates = 0
    skipped_dates = 0

    # Check for existing data if skip_existing is enabled
    dates_to_process = dates
    if skip_existing && save_to_db
        try
            println("🔍 Checking for existing multi-zone data...")
            # Check which dates already have data for multi_zone clearing mode
            existing_query = """
                SELECT DISTINCT DATE(date_time_utc) as run_date
                FROM simulations.energy_prices
                WHERE order_method = \$1
                AND clearing_mode = 'multi_zone'
                AND DATE(date_time_utc) >= \$2
                AND DATE(date_time_utc) <= \$3
                AND code_version = \$4
            """
            existing_df = sql2df(existing_query, [string(order_method), start_date, end_date, ENERGY_PRICES_CODE_VERSION])
            existing_dates = Set(Date.(existing_df.run_date))

            dates_to_process = filter(d -> d ∉ existing_dates, dates)
            skipped_count = length(dates) - length(dates_to_process)

            if skipped_count > 0
                skipped_dates = skipped_count
                println("⏭️  Skipping $skipped_count dates with existing data")
            end
        catch e
            @warn "Failed to check existing data, processing all dates: $e"
        end
    end

    if isempty(dates_to_process)
        println("✅ All dates already processed!")
        return (
            date_results=date_results,
            total_dates=total_dates,
            successful_dates=0,
            failed_dates=0,
            skipped_dates=skipped_dates,
            total_time=time() - range_start_time,
            avg_time_per_date=0.0
        )
    end

    println("🚀 Processing $(length(dates_to_process)) dates...")
    println()

    for (i, date) in enumerate(dates_to_process)
        date_start_time = time()

        println("=" ^ 60)
        println("📅 [$i/$(length(dates_to_process))] Processing $date")
        println("=" ^ 60)

        try
            result = run_multi_zone_market_clearing(date;
                                                    zones=zones,
                                                    order_method=order_method,
                                                    optimizer=optimizer,
                                                    markup_factor=markup_factor,
                                                    silent=silent,
                                                    save_to_db=save_to_db,
                                                    force_rerun=force_rerun,
                                                    parallel=parallel)

            date_elapsed = time() - date_start_time

            if result.status == :optimal
                successful_dates += 1
                num_zones = length(keys(result.market_prices))

                push!(date_results, (
                    date=date,
                    success=true,
                    result=result,
                    elapsed_time=date_elapsed,
                    num_zones=num_zones,
                    error_message=""
                ))

                println("\n✅ Date $date completed successfully")
                println("   ⏱️  Time: $(round(date_elapsed, digits=1))s (solver: $(round(result.solve_time, digits=1))s)")
                println("   🗺️  Zones: $num_zones")
            else
                failed_dates += 1

                push!(date_results, (
                    date=date,
                    success=false,
                    result=result,
                    elapsed_time=date_elapsed,
                    num_zones=0,
                    error_message=result.message
                ))

                println("\n❌ Date $date: optimization failed - $(result.message)")
            end

        catch e
            date_elapsed = time() - date_start_time
            failed_dates += 1
            error_msg = string(e)

            push!(date_results, (
                date=date,
                success=false,
                result=nothing,
                elapsed_time=date_elapsed,
                num_zones=0,
                error_message=error_msg
            ))

            println("\n❌ Date $date: EXCEPTION - $(first(split(error_msg, '\n')))")
        end

        # Progress update
        total_elapsed = time() - range_start_time
        remaining_dates = length(dates_to_process) - i
        if i > 0 && remaining_dates > 0
            avg_per_date = total_elapsed / i
            est_remaining = avg_per_date * remaining_dates / 60
            println("   📈 Progress: $i/$(length(dates_to_process)) | Est. remaining: $(round(est_remaining, digits=1)) min")
        end
        println()
    end

    total_time = time() - range_start_time
    processed_count = successful_dates + failed_dates
    avg_time_per_date = processed_count > 0 ? total_time / processed_count : 0.0

    # Print final summary
    println("=" ^ 70)
    println("🏁 MULTI-ZONE DATE RANGE PROCESSING COMPLETE")
    println("=" ^ 70)

    success_rate = total_dates > 0 ? round(100 * successful_dates / (successful_dates + failed_dates + 0.001), digits=1) : 0

    println("📊 Summary:")
    println("   📅 Date range: $start_date to $end_date")
    println("   📆 Total dates: $total_dates")
    if skipped_dates > 0
        println("   ⏭️  Skipped: $skipped_dates")
    end
    println("   ✅ Successful: $successful_dates")
    println("   ❌ Failed: $failed_dates")
    println("   📈 Success rate: $success_rate%")
    println("   ⏱️  Total time: $(round(total_time/60, digits=1)) minutes")
    println("   🕒 Average per date: $(round(avg_time_per_date, digits=1)) seconds")

    if failed_dates > 0
        failed_date_list = [r.date for r in date_results if !r.success]
        println("\n❌ Failed dates: $(join(failed_date_list, ", "))")
    end

    return (
        date_results=date_results,
        total_dates=total_dates,
        successful_dates=successful_dates,
        failed_dates=failed_dates,
        skipped_dates=skipped_dates,
        total_time=total_time,
        avg_time_per_date=avg_time_per_date
    )
end

"""
    generate_energy_prices_for_all_zones(date::Date;
                                        order_method::Symbol=:uc_based,
                                        model::Symbol=:mpcc,
                                        optimizer::String="auto",
                                        markup_factor::Float64=1.1,
                                        random_seed::Union{Int,Nothing}=nothing,
                                        silent::Bool=true,
                                        save_to_db::Bool=false,
                                        max_retries::Int=2,
                                        retry_delay::Float64=1.0,
                                        fallback_zones::Vector{String}=String[],
                                        skip_existing::Bool=true,
                                        progress_callback::Union{Function,Nothing}=nothing,
                                        parallel::Bool=false,
                                        max_workers::Union{Int,Nothing}=nothing,
                                        chunk_size::Int=1)

Generate energy prices for all available bidding zones on a specific date.

This function automatically discovers all available bidding zones for the specified date
using `get_available_zones()` and then generates energy prices for each zone using
`generate_energy_prices()`. It includes comprehensive error handling, retry mechanisms,
progress tracking, and optional parallel processing.

# Arguments
- `date::Date`: The date for which to generate prices for all zones
- `order_method::Symbol`: Method for creating orders - `:uc_based`, `:alternative` or `:merit_order` (default: `:uc_based`)
- `model::Symbol`: Market clearing model - `:mpcc` (default, more may be added later)
- `optimizer::String`: Optimization solver - "highs" (default), "gurobi", "cplex", "auto"
- `markup_factor::Float64`: Price markup factor for UC-based orders (default: 1.1)
- `random_seed::Union{Int,Nothing}`: Random seed for alternative order book (default: nothing)
- `silent::Bool`: Whether to suppress solver output (default: true)
- `save_to_db::Bool`: Whether to save results to database (default: false)
- `max_retries::Int`: Maximum retry attempts per zone (default: 2)
- `retry_delay::Float64`: Delay between retry attempts in seconds (default: 1.0)
- `fallback_zones::Vector{String}`: Custom fallback zones if zone discovery fails (default: empty)
- `skip_existing::Bool`: Whether to skip zones that already have data in database (default: true)
- `progress_callback::Union{Function,Nothing}`: Optional callback function for progress updates (default: nothing)
- `parallel::Bool`: Whether to use parallel processing (default: false)
- `max_workers::Union{Int,Nothing}`: Maximum number of parallel workers to use (default: auto-detect)
- `chunk_size::Int`: Number of zones to process per worker batch (default: 1)

# Returns
- `NamedTuple` with the following fields:
  - `results::Vector{NamedTuple}`: Detailed results for each zone
  - `success_count::Int`: Number of zones processed successfully
  - `failure_count::Int`: Number of zones that failed
  - `skipped_count::Int`: Number of zones skipped (if skip_existing=true)
  - `total_zones::Int`: Total number of zones discovered
  - `total_time::Float64`: Total processing time in seconds
  - `successful_zones::Vector{String}`: List of successfully processed zones
  - `failed_zones::Vector{String}`: List of zones that failed
  - `skipped_zones::Vector{String}`: List of zones that were skipped
  - `parallel_workers::Int`: Number of parallel workers used (1 if parallel=false)

Each result in `results` contains:
- `zone::String`: Bidding zone code
- `success::Bool`: Whether processing was successful
- `prices::Dict{String,Float64}`: Energy prices (empty if failed)
- `periods::Int`: Number of price periods generated
- `elapsed_time::Float64`: Processing time for this zone
- `min_price::Float64`, `max_price::Float64`, `avg_price::Float64`: Price statistics
- `error_message::String`: Error details (empty if successful)
- `attempt::Int`: Number of attempts made (including retries)
- `worker_id::Int`: ID of the worker that processed this zone

# Examples
```julia
using Euphemia, Dates

# Basic usage - generate prices for all zones on a specific date
result = generate_energy_prices_for_all_zones(Date(2024, 10, 1))
println("Success: \$(result.success_count)/\$(result.total_zones) zones")

# With parallel processing using all available cores
result = generate_energy_prices_for_all_zones(Date(2024, 10, 1);
    parallel=true)
println("Processed with \$(result.parallel_workers) workers")

# With parallel processing and limited workers
result = generate_energy_prices_for_all_zones(Date(2024, 10, 1);
    parallel=true,
    max_workers=16,
    chunk_size=2)

# With database saving and Gurobi optimizer (parallel)
result = generate_energy_prices_for_all_zones(Date(2024, 10, 1);
    optimizer="gurobi",
    save_to_db=true,
    silent=true,
    parallel=true)

# With custom progress callback (note: callbacks work differently in parallel mode)
function my_progress(zone, current, total, elapsed)
    println("Processing \$zone (\$current/\$total) - \$(round(elapsed, digits=1))s")
end

result = generate_energy_prices_for_all_zones(Date(2024, 10, 1);
    progress_callback=my_progress)

# Check detailed results
for zone_result in result.results
    if zone_result.success
        println("\$(zone_result.zone): \$(zone_result.periods) periods, €\$(zone_result.avg_price)/MWh avg (worker \$(zone_result.worker_id))")
    else
        println("\$(zone_result.zone): FAILED - \$(zone_result.error_message) (worker \$(zone_result.worker_id))")
    end
end

# Using alternative order book method with parallel processing
result = generate_energy_prices_for_all_zones(Date(2024, 10, 1);
    order_method=:alternative,
    random_seed=42,
    parallel=true,
    max_workers=32)
```

# Parallel Processing
When `parallel=true`, the function will:
1. Automatically detect available workers or use `max_workers` if specified
2. Distribute zones across workers in batches of size `chunk_size`
3. Process zones concurrently, significantly reducing total processing time
4. Aggregate results from all workers
5. Progress callbacks work but are called less frequently due to batching

Note: Parallel processing requires worker processes to be started before calling this function.
Workers should be set up externally using `addprocs(n)` or `julia -p n`, and the Euphemia 
package should be loaded on all workers using `@everywhere using Euphemia`.

Example setup:
```julia
using Distributed
addprocs(4)
@everywhere using Euphemia

# Now call parallel batch processing
result = generate_energy_prices_for_all_zones(date; parallel=true)
```

# Progress Callback
If provided, the progress_callback function will be called after each zone (sequential mode)
or after each worker batch (parallel mode) with signature:
`progress_callback(zone::String, current_index::Int, total_zones::Int, elapsed_time::Float64)`

# Database Integration
When `save_to_db=true`, the function will:
1. Check for existing data and skip zones if `skip_existing=true`
2. Save both optimization runs and energy prices to the database
3. Handle database constraint violations gracefully
4. Continue processing even if database saves fail
5. In parallel mode, each worker handles its own database connections

# Error Handling
The function includes robust error handling:
- Retry mechanism for transient failures
- Detailed error logging and reporting
- Graceful degradation (continues even if individual zones fail)
- Comprehensive result tracking for analysis
- In parallel mode, worker failures are isolated and reported
"""
function generate_energy_prices_for_all_zones(date::Date;
    order_method::Symbol=:uc_based,
    model::Symbol=:mpcc,
    optimizer::String="auto",
    markup_factor::Float64=1.1,
    random_seed::Union{Int,Nothing}=nothing,
    silent::Bool=true,
    save_to_db::Bool=false,
    max_retries::Int=2,
    retry_delay::Float64=1.0,
    fallback_zones::Vector{String}=String[],
    skip_existing::Bool=true,
    progress_callback::Union{Function,Nothing}=nothing,
    parallel::Bool=false,
    max_workers::Union{Int,Nothing}=nothing,
    chunk_size::Int=1,
    force_rerun::Bool=false)

    start_time = time()

    # Determine number of workers for parallel processing
    workers_used = 1
    println("🔍 Debug: parallel=$parallel, max_workers=$max_workers")
    println("🔍 Debug: CPU threads detected: $(Sys.CPU_THREADS)")
    println("🔍 Debug: Current workers: $(workers())")

    if parallel
        # Check for existing worker processes (user should have set these up)
        worker_ids = filter(id -> id != 1, workers())
        available_workers = length(worker_ids)
        println("🔍 Debug: Filtered worker IDs (excluding main process): $worker_ids")

        if available_workers == 0
            @warn "Parallel processing requested but no worker processes found. Please start workers before calling this function. Falling back to sequential processing."
            parallel = false
            workers_used = 1
        else
            workers_used = isnothing(max_workers) ? available_workers : min(max_workers, available_workers)
            println("🚀 Parallel processing enabled with $workers_used existing workers: $worker_ids")
        end
    end

    # Discover available zones
    println("🔍 Discovering available bidding zones for $date...")
    available_zones = get_available_zones(date; fallback_zones=fallback_zones)

    if isempty(available_zones)
        @warn "No bidding zones discovered for $date"
        return (
            results=NamedTuple[],
            success_count=0,
            failure_count=0,
            skipped_count=0,
            total_zones=0,
            total_time=0.0,
            successful_zones=String[],
            failed_zones=String[],
            skipped_zones=String[],
            parallel_workers=workers_used
        )
    end

    println("✅ Found $(length(available_zones)) zones: $(join(available_zones[1:min(10, length(available_zones))], ", "))$(length(available_zones) > 10 ? "..." : "")")

    # Check for existing data if skip_existing is enabled and save_to_db is true
    zones_to_process = available_zones
    skipped_zones = String[]

    if skip_existing && save_to_db
        try
            println("🔍 Checking for existing data...")
            existing_query = """
                SELECT DISTINCT bidding_zone
                FROM simulations.energy_prices
                WHERE DATE(date_time_utc) = \$1
                AND order_method = \$2
                AND clearing_mode = 'single_zone'
                AND code_version = \$3
            """
            existing_df = sql2df(existing_query, [date, string(order_method), ENERGY_PRICES_CODE_VERSION])
            existing_zones = Set(string(zone) for zone in existing_df.bidding_zone)

            zones_to_process = filter(zone -> zone ∉ existing_zones, available_zones)
            skipped_zones = filter(zone -> zone ∈ existing_zones, available_zones)

            if !isempty(skipped_zones)
                println("⏭️  Skipping $(length(skipped_zones)) zones with existing data: $(join(skipped_zones, ", "))")
            end
        catch e
            @warn "Failed to check existing data, processing all zones: $e"
        end
    end

    if isempty(zones_to_process)
        println("✅ All zones already processed!")
        return (
            results=NamedTuple[],
            success_count=0,
            failure_count=0,
            skipped_count=length(skipped_zones),
            total_zones=length(available_zones),
            total_time=time() - start_time,
            successful_zones=String[],
            failed_zones=String[],
            skipped_zones=skipped_zones,
            parallel_workers=workers_used
        )
    end

    println("🚀 Processing $(length(zones_to_process)) zones$(parallel ? " in parallel with $workers_used workers" : " sequentially with 1 worker")...")
    println("="^60)

    # Choose processing method
    if parallel
        results = _process_zones_parallel(
            zones_to_process, date, order_method, model, optimizer,
            markup_factor, random_seed, silent, save_to_db,
            max_retries, retry_delay, progress_callback, chunk_size
        )
    else
        results = _process_zones_sequential(
            zones_to_process, date, order_method, model, optimizer,
            markup_factor, random_seed, silent, save_to_db,
            max_retries, retry_delay, progress_callback, start_time
        )
    end

    # Aggregate results
    success_count = sum(r.success for r in results)
    failure_count = length(results) - success_count
    successful_zones = [r.zone for r in results if r.success]
    failed_zones = [r.zone for r in results if !r.success]

    total_time = time() - start_time

    # Print summary
    println("\n" * "="^60)
    println("🏁 PROCESSING OF AVAILABLE BIDDING ZONES FOR $date COMPLETE")
    println("="^60)

    total_processed = length(zones_to_process)
    success_rate = total_processed > 0 ? round(100 * success_count / total_processed, digits=1) : 0

    println("📊 Overall Statistics:")
    println("   🎯 Total zones discovered: $(length(available_zones))")
    if !isempty(skipped_zones)
        println("   ⏭️  Skipped zones: $(length(skipped_zones))")
    end
    println("   🔄 Processed zones: $total_processed")
    if parallel
        println("   ⚡ Parallel workers: $workers_used")
    end
    println("   ✅ Successful: $success_count")
    println("   ❌ Failed: $failure_count")
    println("   📈 Success rate: $success_rate%")
    println("   ⏱️  Total time: $(round(total_time/60, digits=1)) minutes")
    if total_processed > 0
        println("   🕒 Average per zone: $(round(total_time/total_processed, digits=1)) seconds")
    end

    if success_count > 0
        successful_results = filter(r -> r.success, results)
        total_periods = sum(r.periods for r in successful_results)
        avg_solve_time = sum(r.elapsed_time for r in successful_results) / success_count

        avg_prices = [r.avg_price for r in successful_results if r.avg_price > 0]
        if !isempty(avg_prices)
            min_prices = [r.min_price for r in successful_results if r.min_price > 0]
            max_prices = [r.max_price for r in successful_results if r.max_price > 0]
            overall_min = isempty(min_prices) ? 0.0 : minimum(min_prices)
            overall_max = isempty(max_prices) ? 0.0 : maximum(max_prices)
            overall_avg = sum(avg_prices) / length(avg_prices)

            println("\n💰 Price Statistics (successful zones):")
            println("   📊 Total periods: $total_periods")
            println("   ⏱️  Avg solve time: $(round(avg_solve_time, digits=2))s")
            println("   💵 Price range: €$(round(overall_min, digits=2)) - €$(round(overall_max, digits=2))/MWh")
            println("   📈 Average price: €$(round(overall_avg, digits=2))/MWh")
        end
    end

    if failure_count > 0
        println("\n❌ Failed Zones: $(join(failed_zones, ", "))")
    end

    return (
        results=results,
        success_count=success_count,
        failure_count=failure_count,
        skipped_count=length(skipped_zones),
        total_zones=length(available_zones),
        total_time=total_time,
        successful_zones=successful_zones,
        failed_zones=failed_zones,
        skipped_zones=skipped_zones,
        parallel_workers=workers_used
    )
end

"""
    generate_energy_prices_for_date_range(start_date::Date, end_date::Date;
                                          order_method::Symbol=:uc_based,
                                          model::Symbol=:mpcc,
                                          optimizer::String="auto",
                                          markup_factor::Float64=1.1,
                                          random_seed::Union{Int,Nothing}=nothing,
                                          silent::Bool=true,
                                          save_to_db::Bool=true,
                                          max_retries::Int=2,
                                          retry_delay::Float64=1.0,
                                          fallback_zones::Vector{String}=String[],
                                          skip_existing::Bool=true,
                                          progress_callback::Union{Function,Nothing}=nothing,
                                          parallel::Bool=false,
                                          max_workers::Union{Int,Nothing}=nothing,
                                          chunk_size::Int=1)

Generate energy prices for all available bidding zones across a date range.

This function processes multiple dates sequentially, calling `generate_energy_prices_for_all_zones()`
for each date in the specified range. It provides comprehensive progress tracking, error handling,
and result aggregation across the entire date range.

# Arguments
- `start_date::Date`: First date to process (inclusive)
- `end_date::Date`: Last date to process (inclusive)
- All other arguments are passed through to `generate_energy_prices_for_all_zones()`:
  - `order_method::Symbol`: Method for creating orders - `:uc_based`, `:alternative` or `:merit_order` (default: `:uc_based`)
  - `model::Symbol`: Market clearing model - `:mpcc` (default)
  - `optimizer::String`: Optimization solver - "highs" (default), "gurobi", "cplex", "auto"
  - `markup_factor::Float64`: Price markup factor for UC-based orders (default: 1.1)
  - `random_seed::Union{Int,Nothing}`: Random seed for alternative order book (default: nothing)
  - `silent::Bool`: Whether to suppress solver output (default: true)
  - `save_to_db::Bool`: Whether to save results to database (default: true for bulk operations)
  - `max_retries::Int`: Maximum retry attempts per zone (default: 2)
  - `retry_delay::Float64`: Delay between retry attempts in seconds (default: 1.0)
  - `fallback_zones::Vector{String}`: Custom fallback zones if zone discovery fails (default: empty)
  - `skip_existing::Bool`: Whether to skip zones that already have data in database (default: true)
  - `progress_callback::Union{Function,Nothing}`: Optional callback function for progress updates (default: nothing)
  - `parallel::Bool`: Whether to use parallel processing (default: false)
  - `max_workers::Union{Int,Nothing}`: Maximum number of parallel workers to use (default: auto-detect)
  - `chunk_size::Int`: Number of zones to process per worker batch (default: 1)

# Returns
- `NamedTuple` with the following fields:
  - `date_results::Vector{NamedTuple}`: Results for each date processed
  - `total_dates::Int`: Total number of dates in the range
  - `successful_dates::Int`: Number of dates processed successfully
  - `failed_dates::Int`: Number of dates that failed completely
  - `total_zones_processed::Int`: Total number of zone-date combinations processed
  - `total_zones_successful::Int`: Total number of zone-date combinations that succeeded
  - `total_time::Float64`: Total processing time for entire date range in seconds
  - `start_date::Date`, `end_date::Date`: Date range processed
  - `daily_summaries::Vector{NamedTuple}`: Summary statistics per date

Each date result in `date_results` contains:
- `date::Date`: The date processed
- `success::Bool`: Whether the date was processed successfully (at least one zone succeeded)
- `zones_result::NamedTuple`: Full result from `generate_energy_prices_for_all_zones()` for this date
- `elapsed_time::Float64`: Processing time for this date
- `zones_discovered::Int`: Number of zones discovered for this date
- `zones_successful::Int`: Number of zones processed successfully for this date
- `zones_failed::Int`: Number of zones that failed for this date
- `zones_skipped::Int`: Number of zones skipped for this date

Each summary in `daily_summaries` contains:
- `date::Date`: The date
- `zones_total::Int`: Total zones for this date
- `zones_successful::Int`: Successful zones for this date
- `success_rate::Float64`: Success rate percentage for this date
- `avg_price::Float64`: Average price across all successful zones (if any)
- `min_price::Float64`, `max_price::Float64`: Price extremes for this date
- `total_periods::Int`: Total price periods generated for this date

# Examples
```julia
using Euphemia, Dates

# Process a single month
result = generate_energy_prices_for_date_range(
    Date(2024, 10, 1), 
    Date(2024, 10, 31)
)

# Process with parallel processing and database saving
result = generate_energy_prices_for_date_range(
    Date(2024, 1, 1), 
    Date(2024, 1, 7);
    parallel=true,
    max_workers=20,
    save_to_db=true,
    optimizer="gurobi"
)

# Process specific date range with custom progress tracking
function date_progress(date, current, total, elapsed)
    println("📅 Date \$date completed (\$current/\$total) - \$(round(elapsed/60, digits=1)) min")
end

result = generate_energy_prices_for_date_range(
    Date(2024, 6, 1), 
    Date(2024, 6, 30);
    progress_callback=date_progress,
    save_to_db=true
)

# Check results
println("Processed \$(result.successful_dates)/\$(result.total_dates) dates successfully")
println("Total zones processed: \$(result.total_zones_successful)/\$(result.total_zones_processed)")
println("Total time: \$(round(result.total_time/3600, digits=1)) hours")

# Analyze daily summaries
for summary in result.daily_summaries
    if summary.zones_successful > 0
        println("\$(summary.date): \$(summary.zones_successful) zones, €\$(round(summary.avg_price, digits=2))/MWh avg")
    end
end

# Check failed dates
failed_dates = [r.date for r in result.date_results if !r.success]
if !isempty(failed_dates)
    println("Failed dates: \$(join(failed_dates, \", \"))")
end
```

# Date Range Processing
- Processes dates sequentially from start_date to end_date (inclusive)
- Each date is processed independently using `generate_energy_prices_for_all_zones()`
- Failed dates don't stop processing of remaining dates
- Comprehensive progress tracking and error reporting per date
- Automatic aggregation of statistics across the entire date range

# Performance Considerations
- Parallel date processing when `parallel=true` (zones within each date are processed sequentially)
- Sequential date processing when `parallel=false` (zones within each date are also processed sequentially)
- Memory efficient - each worker processes one date's zones sequentially
- Database operations are distributed across parallel date workers when `save_to_db=true`
- Progress callbacks help monitor long-running operations

# Error Handling
- Date-level errors are captured and reported but don't stop processing
- Zone-level errors are handled by the underlying `generate_energy_prices_for_all_zones()` function
- Comprehensive error reporting with per-date breakdowns
- Failed dates are clearly identified in results
"""
function generate_energy_prices_for_date_range(start_date::Date, end_date::Date;
    order_method::Symbol=:uc_based,
    model::Symbol=:mpcc,
    optimizer::String="auto",
    markup_factor::Float64=1.1,
    random_seed::Union{Int,Nothing}=nothing,
    silent::Bool=true,
    save_to_db::Bool=true,  # Default true for bulk operations
    max_retries::Int=2,
    retry_delay::Float64=1.0,
    fallback_zones::Vector{String}=String[],
    skip_existing::Bool=true,
    progress_callback::Union{Function,Nothing}=nothing,
    parallel::Bool=false,
    max_workers::Union{Int,Nothing}=nothing,
    chunk_size::Int=1,
    force_rerun::Bool=false)

    # Validate date range
    if start_date > end_date
        error("start_date ($start_date) cannot be after end_date ($end_date)")
    end

    # Generate date range
    dates = collect(start_date:Day(1):end_date)
    total_dates = length(dates)

    println("📅 Starting date range processing")
    println("="^60)
    println("   📍 Date range: $start_date to $end_date")
    println("   📊 Total dates: $total_dates")
    println("   📋 Order method: $order_method")
    println("   ⚖️  Model: $model")
    println("   🔧 Optimizer: $optimizer")
    if parallel
        println("   ⚡ Parallel processing: enabled")
    end
    if save_to_db
        println("   💾 Database saving: enabled")
    end
    println()

    range_start_time = time()
    date_results = NamedTuple[]
    daily_summaries = NamedTuple[]

    successful_dates = 0
    failed_dates = 0
    total_zones_processed = 0
    total_zones_successful = 0

    # Choose processing method: parallel dates vs sequential dates
    if parallel
        # Check for existing worker processes
        worker_ids = filter(id -> id != 1, workers())
        available_workers = length(worker_ids)

        if available_workers == 0
            @warn "Parallel date processing requested but no worker processes found. Please start workers before calling this function. Falling back to sequential date processing."
            parallel = false
        else
            workers_used = isnothing(max_workers) ? available_workers : min(max_workers, available_workers)
            println("🚀 Processing dates in parallel with $workers_used workers")

            # Process dates in parallel using pmap
            date_results = _process_dates_parallel(
                dates, order_method, model, optimizer, markup_factor,
                random_seed, silent, save_to_db, max_retries, retry_delay,
                fallback_zones, skip_existing, range_start_time, force_rerun
            )

            # Aggregate results from parallel processing
            successful_dates = sum(r.success for r in date_results)
            failed_dates = length(date_results) - successful_dates
            total_zones_processed = sum(r.zones_discovered for r in date_results)
            total_zones_successful = sum(r.zones_successful for r in date_results)

            # Generate daily summaries from results
            daily_summaries = _generate_daily_summaries(date_results)
        end
    else
        # Sequential date processing (fallback or when parallel=false)
        consecutive_failures = 0  # Track consecutive date failures
        max_consecutive_failures = 5  # Stop after 5 consecutive date failures

        for (i, date) in enumerate(dates)
            date_start_time = time()

            println("📅 [$i/$total_dates] Processing $date")
            println("-"^50)

            try
                # Process all zones for this date (always sequential when in date loop)
                zones_result = generate_energy_prices_for_all_zones(date;
                    order_method=order_method,
                    model=model,
                    optimizer=optimizer,
                    markup_factor=markup_factor,
                    random_seed=random_seed,
                    silent=silent,
                    save_to_db=save_to_db,
                    max_retries=max_retries,
                    retry_delay=retry_delay,
                    fallback_zones=fallback_zones,
                    skip_existing=skip_existing,
                    progress_callback=nothing,  # Disable per-zone callbacks to avoid clutter
                    parallel=false,  # Force sequential zones when processing dates in sequence
                    max_workers=1,
                    chunk_size=1,
                    force_rerun=force_rerun)

                date_elapsed = time() - date_start_time

                # Determine if date was successful (at least one zone succeeded)
                date_successful = zones_result.success_count > 0
                if date_successful
                    successful_dates += 1
                    consecutive_failures = 0  # Reset consecutive failure counter
                else
                    failed_dates += 1
                    consecutive_failures += 1
                end

                # Early termination if too many consecutive failures (likely systematic issue)
                if consecutive_failures >= max_consecutive_failures
                    println("🛑 EARLY TERMINATION: $consecutive_failures consecutive date failures detected.")
                    println("   This suggests a systematic issue (e.g., worker initialization problem).")
                    println("   Stopping to prevent infinite loop and resource waste.")
                    break
                end

                # Update totals
                total_zones_processed += zones_result.success_count + zones_result.failure_count
                total_zones_successful += zones_result.success_count

                # Create date result
                date_result = (
                    date=date,
                    success=date_successful,
                    zones_result=zones_result,
                    elapsed_time=date_elapsed,
                    zones_discovered=zones_result.total_zones,
                    zones_successful=zones_result.success_count,
                    zones_failed=zones_result.failure_count,
                    zones_skipped=zones_result.skipped_count
                )
                push!(date_results, date_result)

                # Create daily summary with price statistics
                if zones_result.success_count > 0
                    successful_results = filter(r -> r.success, zones_result.results)
                    all_prices = Float64[]
                    total_periods = 0

                    for zone_result in successful_results
                        if !isempty(zone_result.prices)
                            append!(all_prices, collect(values(zone_result.prices)))
                            total_periods += zone_result.periods
                        end
                    end

                    if !isempty(all_prices)
                        daily_summary = (
                            date=date,
                            zones_total=zones_result.total_zones,
                            zones_successful=zones_result.success_count,
                            success_rate=round(100 * zones_result.success_count / max(1, zones_result.total_zones), digits=1),
                            avg_price=round(sum(all_prices) / length(all_prices), digits=2),
                            min_price=round(minimum(all_prices), digits=2),
                            max_price=round(maximum(all_prices), digits=2),
                            total_periods=total_periods
                        )
                    else
                        daily_summary = (
                            date=date,
                            zones_total=zones_result.total_zones,
                            zones_successful=zones_result.success_count,
                            success_rate=round(100 * zones_result.success_count / max(1, zones_result.total_zones), digits=1),
                            avg_price=0.0,
                            min_price=0.0,
                            max_price=0.0,
                            total_periods=0
                        )
                    end
                else
                    daily_summary = (
                        date=date,
                        zones_total=zones_result.total_zones,
                        zones_successful=0,
                        success_rate=0.0,
                        avg_price=0.0,
                        min_price=0.0,
                        max_price=0.0,
                        total_periods=0
                    )
                end
                push!(daily_summaries, daily_summary)

                # Print date summary
                if date_successful
                    println("✅ Date $date: $(zones_result.success_count)/$(zones_result.total_zones) zones successful")
                    if zones_result.success_count > 0 && daily_summary.avg_price > 0
                        println("   💰 Price range: €$(daily_summary.min_price) - €$(daily_summary.max_price)/MWh (avg: €$(daily_summary.avg_price))")
                    end
                else
                    println("❌ Date $date: All zones failed")
                end

                println("   ⏱️  Date processing time: $(round(date_elapsed/60, digits=1)) minutes")

            catch date_error
                date_elapsed = time() - date_start_time
                failed_dates += 1
                consecutive_failures += 1

                # Early termination check for critical errors
                if consecutive_failures >= max_consecutive_failures
                    println("🛑 EARLY TERMINATION: $consecutive_failures consecutive critical failures.")
                    println("   Error: $date_error")
                    println("   Stopping to prevent infinite loop and resource waste.")
                    break
                end

                # Create failed date result
                date_result = (
                    date=date,
                    success=false,
                    zones_result=nothing,
                    elapsed_time=date_elapsed,
                    zones_discovered=0,
                    zones_successful=0,
                    zones_failed=0,
                    zones_skipped=0
                )
                push!(date_results, date_result)

                daily_summary = (
                    date=date,
                    zones_total=0,
                    zones_successful=0,
                    success_rate=0.0,
                    avg_price=0.0,
                    min_price=0.0,
                    max_price=0.0,
                    total_periods=0
                )
                push!(daily_summaries, daily_summary)

                println("❌ Date $date: CRITICAL FAILURE - $(date_error)")
            end

            # Call progress callback if provided
            if progress_callback !== nothing
                try
                    progress_callback(date, i, total_dates, time() - range_start_time)
                catch callback_error
                    @warn "Date-level progress callback failed: $callback_error"
                end
            end

            # Overall progress update
            total_elapsed = time() - range_start_time
            remaining_dates = total_dates - i
            est_remaining = remaining_dates > 0 ? (total_elapsed / i) * remaining_dates / 60 : 0
            println("   📈 Overall progress: $i/$total_dates dates | Est. remaining: $(round(est_remaining, digits=1)) min")
            println()
        end  # End sequential processing loop
    end  # End sequential processing block

    total_time = time() - range_start_time

    # Print final summary
    println("="^60)
    println("🏁 DATE RANGE PROCESSING COMPLETE")
    println("="^60)

    success_rate = total_dates > 0 ? round(100 * successful_dates / total_dates, digits=1) : 0
    zone_success_rate = total_zones_processed > 0 ? round(100 * total_zones_successful / total_zones_processed, digits=1) : 0

    println("📊 Date Range Summary:")
    println("   📅 Date range: $start_date to $end_date")
    println("   📆 Total dates: $total_dates")
    println("   ✅ Successful dates: $successful_dates")
    println("   ❌ Failed dates: $failed_dates")
    println("   📈 Date success rate: $success_rate%")
    println("   ⏱️  Total time: $(round(total_time/3600, digits=1)) hours")
    println("   🕒 Average per date: $(round(total_time/total_dates/60, digits=1)) minutes")

    println("\n🌍 Zone Processing Summary:")
    println("   🔄 Total zone-date combinations: $total_zones_processed")
    println("   ✅ Successful zone-date combinations: $total_zones_successful")
    println("   📈 Zone success rate: $zone_success_rate%")

    if total_zones_successful > 0
        successful_summaries = filter(s -> s.zones_successful > 0, daily_summaries)
        if !isempty(successful_summaries)
            avg_daily_price = sum(s.avg_price * s.zones_successful for s in successful_summaries) / sum(s.zones_successful for s in successful_summaries)
            min_prices = [s.min_price for s in successful_summaries if s.min_price > 0]
            max_prices = [s.max_price for s in successful_summaries if s.max_price > 0]
            overall_min = isempty(min_prices) ? 0.0 : minimum(min_prices)
            overall_max = isempty(max_prices) ? 0.0 : maximum(max_prices)

            println("\n💰 Price Statistics:")
            println("   📊 Overall price range: €$(overall_min) - €$(overall_max)/MWh")
            println("   📈 Weighted average price: €$(round(avg_daily_price, digits=2))/MWh")
        end
    end

    if failed_dates > 0
        failed_date_list = [r.date for r in date_results if !r.success]
        println("\n❌ Failed dates: $(join(failed_date_list, ", "))")
    end

    return (
        date_results=date_results,
        total_dates=total_dates,
        successful_dates=successful_dates,
        failed_dates=failed_dates,
        total_zones_processed=total_zones_processed,
        total_zones_successful=total_zones_successful,
        total_time=total_time,
        start_date=start_date,
        end_date=end_date,
        daily_summaries=daily_summaries
    )
end

# =============================================================================
# HELPER FUNCTIONS FOR PARALLEL AND SEQUENTIAL PROCESSING
# =============================================================================

"""
Helper function for processing dates in parallel.
"""
function _process_dates_parallel(dates, order_method, model, optimizer, markup_factor,
    random_seed, silent, save_to_db, max_retries, retry_delay,
    fallback_zones, skip_existing, range_start_time, force_rerun)

    println("📦 Processing $(length(dates)) dates in parallel...")

    # Create arguments tuple for each date
    date_args = [(date, order_method, model, optimizer, markup_factor, random_seed,
        silent, save_to_db, max_retries, retry_delay, fallback_zones,
        skip_existing, range_start_time, force_rerun) for date in dates]

    # Process dates in parallel using pmap
    date_results = pmap(_parallel_date_processor, date_args)

    return date_results
end

"""
Wrapper function for pmap to process a single date.
"""
function _parallel_date_processor(args)
    date, order_method, model, optimizer, markup_factor, random_seed,
    silent, save_to_db, max_retries, retry_delay, fallback_zones,
    skip_existing, range_start_time, force_rerun = args

    date_start_time = time()
    worker_id = myid()

    try
        println("📅 [Worker $worker_id] Processing $date")

        # Process all zones for this date (always sequential in parallel date mode)
        zones_result = generate_energy_prices_for_all_zones(date;
            order_method=order_method,
            model=model,
            optimizer=optimizer,
            markup_factor=markup_factor,
            random_seed=random_seed,
            silent=silent,
            save_to_db=save_to_db,
            max_retries=max_retries,
            retry_delay=retry_delay,
            fallback_zones=fallback_zones,
            skip_existing=skip_existing,
            progress_callback=nothing,  # No callbacks in parallel mode
            parallel=false,  # Always sequential zones in parallel date mode
            max_workers=1,
            chunk_size=1,
            force_rerun=force_rerun)

        date_elapsed = time() - date_start_time
        date_successful = zones_result.success_count > 0

        if date_successful
            println("✅ [Worker $worker_id] Date $date: $(zones_result.success_count)/$(zones_result.total_zones) zones successful ($(round(date_elapsed/60, digits=1)) min)")
        else
            println("❌ [Worker $worker_id] Date $date: All zones failed ($(round(date_elapsed/60, digits=1)) min)")
        end

        return (
            date=date,
            success=date_successful,
            zones_result=zones_result,
            elapsed_time=date_elapsed,
            zones_discovered=zones_result.total_zones,
            zones_successful=zones_result.success_count,
            zones_failed=zones_result.failure_count,
            zones_skipped=zones_result.skipped_count,
            worker_id=worker_id
        )

    catch date_error
        date_elapsed = time() - date_start_time
        println("❌ [Worker $worker_id] Date $date: CRITICAL FAILURE - $date_error ($(round(date_elapsed/60, digits=1)) min)")

        return (
            date=date,
            success=false,
            zones_result=nothing,
            elapsed_time=date_elapsed,
            zones_discovered=0,
            zones_successful=0,
            zones_failed=0,
            zones_skipped=0,
            worker_id=worker_id
        )
    end
end

"""
Generate daily summaries from parallel date processing results.
"""
function _generate_daily_summaries(date_results)
    daily_summaries = NamedTuple[]

    for result in date_results
        if result.success && result.zones_result !== nothing
            zones_result = result.zones_result

            if zones_result.success_count > 0
                successful_results = filter(r -> r.success, zones_result.results)
                all_prices = Float64[]
                total_periods = 0

                for zone_result in successful_results
                    if !isempty(zone_result.prices)
                        append!(all_prices, collect(values(zone_result.prices)))
                        total_periods += zone_result.periods
                    end
                end

                if !isempty(all_prices)
                    daily_summary = (
                        date=result.date,
                        zones_total=zones_result.total_zones,
                        zones_successful=zones_result.success_count,
                        success_rate=round(100 * zones_result.success_count / max(1, zones_result.total_zones), digits=1),
                        avg_price=round(sum(all_prices) / length(all_prices), digits=2),
                        min_price=round(minimum(all_prices), digits=2),
                        max_price=round(maximum(all_prices), digits=2),
                        total_periods=total_periods
                    )
                else
                    daily_summary = (
                        date=result.date,
                        zones_total=zones_result.total_zones,
                        zones_successful=0,
                        success_rate=0.0,
                        avg_price=0.0,
                        min_price=0.0,
                        max_price=0.0,
                        total_periods=0
                    )
                end
            else
                daily_summary = (
                    date=result.date,
                    zones_total=zones_result.total_zones,
                    zones_successful=0,
                    success_rate=0.0,
                    avg_price=0.0,
                    min_price=0.0,
                    max_price=0.0,
                    total_periods=0
                )
            end
        else
            daily_summary = (
                date=result.date,
                zones_total=0,
                zones_successful=0,
                success_rate=0.0,
                avg_price=0.0,
                min_price=0.0,
                max_price=0.0,
                total_periods=0
            )
        end
        push!(daily_summaries, daily_summary)
    end

    return daily_summaries
end

"""
Helper function for processing zones sequentially.
"""
function _process_zones_sequential(zones_to_process, date, order_method, model, optimizer,
    markup_factor, random_seed, silent, save_to_db,
    max_retries, retry_delay, progress_callback, start_time)
    results = NamedTuple[]

    for (i, zone) in enumerate(zones_to_process)
        zone_start_time = time()

        println("\n🏃 [$i/$(length(zones_to_process))] Zone: $zone")
        println("-"^40)

        # Try processing with retries
        zone_success = false
        zone_prices = Dict{String,Float64}()
        zone_error = ""
        attempts = 0

        for attempt in 1:max_retries
            attempts = attempt
            attempt_start = time()  # Move outside try block
            try
                retry_msg = attempt > 1 ? " (retry $attempt/$max_retries)" : ""
                println("🔄 Processing: $zone$retry_msg")

                zone_prices = generate_energy_prices(zone, date;
                    order_method=order_method,
                    model=model,
                    optimizer=optimizer,
                    markup_factor=markup_factor,
                    random_seed=random_seed,
                    silent=silent,
                    save_to_db=save_to_db,
                    force_rerun=force_rerun)

                if !isempty(zone_prices)
                    zone_success = true

                    min_price = minimum(values(zone_prices))
                    max_price = maximum(values(zone_prices))
                    avg_price = sum(values(zone_prices)) / length(zone_prices)
                    elapsed = time() - attempt_start

                    println("✅ SUCCESS: $zone ($(round(elapsed, digits=2))s)")
                    println("   💰 $(length(zone_prices)) periods: €$(round(min_price, digits=2)) - €$(round(max_price, digits=2))/MWh (avg: €$(round(avg_price, digits=2)))")
                    break
                else
                    zone_error = "No prices generated"
                    if attempt < max_retries
                        println("⚠️  No prices generated for $zone, retrying...")
                        sleep(retry_delay)
                    end
                end

            catch e
                zone_error = string(e)
                elapsed = time() - attempt_start

                # Check if this is a non-retryable error (data availability)
                is_retryable = !(e isa DataUnavailableError)

                if is_retryable && attempt < max_retries
                    println("❌ ATTEMPT $attempt FAILED: $zone ($(round(elapsed, digits=2))s)")
                    println("   📝 Error: $(first(split(zone_error, '\n')))")
                    println("   🔄 Retrying in $(retry_delay)s...")
                    sleep(retry_delay)
                else
                    if e isa DataUnavailableError
                        println("❌ DATA NOT AVAILABLE: $zone ($(round(elapsed, digits=2))s)")
                        println("   📝 Reason: $(first(split(zone_error, '\n')))")
                        println("   ⚠️  Skipping retries - data availability issue")
                    else
                        println("❌ FINAL FAILURE: $zone ($(round(elapsed, digits=2))s after $max_retries attempts)")
                        println("   📝 Error: $(first(split(zone_error, '\n')))")
                    end
                    break  # Exit retry loop
                end
            end
        end

        zone_elapsed = time() - zone_start_time

        # Calculate price statistics
        min_price = zone_success ? minimum(values(zone_prices)) : 0.0
        max_price = zone_success ? maximum(values(zone_prices)) : 0.0
        avg_price = zone_success && !isempty(zone_prices) ? sum(values(zone_prices)) / length(zone_prices) : 0.0

        # Store result
        zone_result = (
            zone=zone,
            success=zone_success,
            prices=zone_prices,
            periods=length(zone_prices),
            elapsed_time=zone_elapsed,
            min_price=min_price,
            max_price=max_price,
            avg_price=avg_price,
            error_message=zone_success ? "" : zone_error,
            attempt=attempts,
            worker_id=1
        )
        push!(results, zone_result)

        # Call progress callback if provided
        if progress_callback !== nothing
            try
                progress_callback(zone, i, length(zones_to_process), zone_elapsed)
            catch callback_error
                @warn "Progress callback failed: $callback_error"
            end
        end

        # Progress update
        total_elapsed = time() - start_time
        remaining = length(zones_to_process) - i
        est_remaining = remaining > 0 ? total_elapsed / i * remaining / 60 : 0
        println("   📈 Progress: $i/$(length(zones_to_process)) | Est. remaining: $(round(est_remaining, digits=1)) min")
    end

    return results
end

"""
Helper function for processing zones in parallel.
"""
function _process_zones_parallel(zones_to_process, date, order_method, model, optimizer,
    markup_factor, random_seed, silent, save_to_db,
    max_retries, retry_delay, progress_callback, chunk_size)

    # Split zones into chunks for distribution
    zone_chunks = [zones_to_process[i:min(i + chunk_size - 1, end)] for i in 1:chunk_size:length(zones_to_process)]

    println("📦 Split $(length(zones_to_process)) zones into $(length(zone_chunks)) chunks of size $chunk_size")

    # Prepare arguments for pmap
    pmap_args = [(chunk, date, order_method, model, optimizer, markup_factor, random_seed, silent, save_to_db, max_retries, retry_delay) for chunk in zone_chunks]

    # Process chunks in parallel
    chunk_start_time = time()

    # Use pmap for parallel processing of chunks
    chunk_results = pmap(_parallel_chunk_processor, pmap_args)

    # Flatten results from all chunks
    results = NamedTuple[]
    processed_count = 0

    for chunk_result in chunk_results
        for zone_result in chunk_result
            push!(results, zone_result)
            processed_count += 1

            # Call progress callback if provided (less frequently in parallel mode)
            if progress_callback !== nothing && processed_count % max(1, div(length(zones_to_process), 10)) == 0
                try
                    elapsed = time() - chunk_start_time
                    progress_callback(zone_result.zone, processed_count, length(zones_to_process), elapsed)
                catch callback_error
                    @warn "Progress callback failed: $callback_error"
                end
            end
        end
    end

    println("⚡ Parallel processing completed in $(round((time() - chunk_start_time)/60, digits=1)) minutes")

    return results
end

"""
Wrapper function for pmap to process a chunk of zones.
"""
function _parallel_chunk_processor(args)
    zone_chunk, date, order_method, model, optimizer, markup_factor, random_seed, silent, save_to_db, max_retries, retry_delay = args
    return _process_zone_chunk(zone_chunk, date, order_method, model, optimizer,
        markup_factor, random_seed, silent, save_to_db,
        max_retries, retry_delay)
end

"""
Process a chunk of zones on a single worker.
"""
function _process_zone_chunk(zone_chunk, date, order_method, model, optimizer,
    markup_factor, random_seed, silent, save_to_db,
    max_retries, retry_delay)
    worker_id = myid()
    chunk_results = NamedTuple[]

    for zone in zone_chunk
        zone_start_time = time()

        # Try processing with retries
        zone_success = false
        zone_prices = Dict{String,Float64}()
        zone_error = ""
        attempts = 0

        for attempt in 1:max_retries
            attempts = attempt
            try
                zone_prices = generate_energy_prices(zone, date;
                    order_method=order_method,
                    model=model,
                    optimizer=optimizer,
                    markup_factor=markup_factor,
                    random_seed=random_seed,
                    silent=silent,
                    save_to_db=save_to_db,
                    force_rerun=force_rerun)

                if !isempty(zone_prices)
                    zone_success = true
                    break
                else
                    zone_error = "No prices generated"
                    if attempt < max_retries
                        sleep(retry_delay)
                    end
                end

            catch e
                zone_error = string(e)
                if attempt < max_retries
                    sleep(retry_delay)
                end
            end
        end

        zone_elapsed = time() - zone_start_time

        # Calculate price statistics
        min_price = zone_success ? minimum(values(zone_prices)) : 0.0
        max_price = zone_success ? maximum(values(zone_prices)) : 0.0
        avg_price = zone_success && !isempty(zone_prices) ? sum(values(zone_prices)) / length(zone_prices) : 0.0

        # Store result
        zone_result = (
            zone=zone,
            success=zone_success,
            prices=zone_prices,
            periods=length(zone_prices),
            elapsed_time=zone_elapsed,
            min_price=min_price,
            max_price=max_price,
            avg_price=avg_price,
            error_message=zone_success ? "" : zone_error,
            attempt=attempts,
            worker_id=worker_id
        )
        push!(chunk_results, zone_result)
    end

    return chunk_results
end

end