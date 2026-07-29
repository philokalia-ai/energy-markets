# single_zone.jl — Single-zone market clearing: generate_energy_prices, zone discovery, legacy ENTSO-E entry points.
# Included by ../Euphemia.jl inside `module Euphemia` (definition order preserved).

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
                          order_method::Symbol=:merit_order, 
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
- `order_method::Symbol`: only `:merit_order` (the UC-based and alternative books were removed in cv25)
  - `:uc_based`: Creates orders preserving Unit Commitment's native temporal resolution (15/30/60 minutes)
  - `:alternative`: Creates orders at finest available resolution (15/30/60 minutes) from real load/renewable data
- `model::Symbol`: Market clearing model - `:mpcc` (more models may be added later)
- `optimizer::String`: Optimization solver - "highs" (default), "gurobi", "cplex", "auto"
- `markup_factor::Float64`: Price markup factor for UC-based orders (default: 1.1)
- `random_seed::Union{Int,Nothing}`: Random seed for alternative order book (default: nothing)
- `silent::Bool`: Whether to suppress solver output (default: true)
- `clearing_mode::String`: Label stored with saved prices (default: "single_zone").
  Scenario runs should use a distinct label (e.g. "gr_scn_dc574") so baseline and
  counterfactual rows coexist in `simulations.energy_prices` and can be compared
  with `queries/load_weighted_price_delta.sql`.

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
    order_method::Symbol=:merit_order,
    model::Symbol=:mpcc,
    optimizer::String="auto",
    markup_factor::Float64=1.1,
    random_seed::Union{Int,Nothing}=nothing,
    silent::Bool=true,
    save_to_db::Bool=false,
    force_rerun::Bool=false,
    clearing_mode::String="single_zone",
    load_modifier::Union{Nothing,Function}=nothing,
    renewable_modifier::Union{Nothing,Function}=nothing,
    extra_orders::Union{Nothing,Function}=nothing,
    strategist::Union{Nothing,Function}=nothing,
    fleet_modifier::Union{Nothing,Function}=nothing)

    # Validate inputs
    if order_method != :merit_order
        error("Invalid order_method: $order_method. Only :merit_order remains — the UC-based and alternative books were removed in cv25.")
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

        if order_method == :merit_order
            println("   Using merit-order book creation")
            order_book_result = create_merit_order_book(bidding_zone, date;
                                    load_modifier=load_modifier,
                                    renewable_modifier=renewable_modifier,
                                    extra_orders=extra_orders,
                                    strategist=strategist,
                                    fleet_modifier=fleet_modifier)

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
                                                           clearing_mode=clearing_mode,
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

