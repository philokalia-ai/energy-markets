module MPCC

using JuMP, Dates, DataFrames
using JuMP: AffExpr
using Distributed: myid, workers, pmap, WorkerPool

# Import shared solver selection from parent module
import ..select_solver

# Import required modules from parent Euphemia package
import ..Euphemia.MarketOrders: MarketOrder, SimpleOrder, AggregatedPeriodicOrder
import ..Euphemia.Network: NetworkTopology, TransferCapacity, get_connected_zones, get_zone_pairs, create_transfer_capacity_from_entsoe
import ..Euphemia: get_loads, get_generators, get_generation_forecast_for_wind_and_solar
import ..Euphemia.BiddingStrategy: generate_market_orders_from_uc, UCToBidsResult

# Result structure
struct MPCCResult
    status::Symbol
    objective_value::Float64
    market_prices::Dict{String,Dict{String,Float64}}
    stepwise_acceptance::Dict{String,Float64}
    block_acceptance::Dict{String,Float64}
    block_activation::Dict{String,Float64}
    transmission_flows::Dict{String,Dict{String,Float64}}
    solve_time::Float64              # Time spent in optimization solver
    total_time::Float64              # Total processing time (including order book creation)
    solver_name::String
    message::String
end

"""
    with_total_time(result::MPCCResult, total_time::Float64) -> MPCCResult

Create a copy of MPCCResult with updated total_time.
Useful for setting the total processing time after order book creation.
"""
function with_total_time(result::MPCCResult, total_time::Float64)
    return MPCCResult(
        result.status,
        result.objective_value,
        result.market_prices,
        result.stepwise_acceptance,
        result.block_acceptance,
        result.block_activation,
        result.transmission_flows,
        result.solve_time,
        total_time,
        result.solver_name,
        result.message
    )
end

# Typed order book structure using existing MarketOrder types
struct MPCCOrderBook
    orders::Vector{MarketOrder}                # All market orders using existing types
    nodes::Vector{String}                      # Bidding zone identifiers
    periods::Vector{String}                    # Time period identifiers (e.g., "1", "2", ..., "24")
    price_limits::Tuple{Float64,Float64}       # (min_price, max_price) bounds
    network_topology::Union{Nothing,NetworkTopology,TransferCapacity}  # Optional network constraints (TransferCapacity for multi-zone)
end

# Configuration constants
const DEFAULT_MARKUP_FACTOR = 1.1
const BIG_M_PARAMETER = 4000000.0

"""
    extract_time_period(order_datetime::DateTime, order_book_periods::Vector{String})

Extracts the appropriate time period identifier for an order based on the order book's period structure.
Supports both hourly (1-24) and sub-hourly (timeslot strings) periods.
"""
function extract_time_period(order_datetime::DateTime, order_book_periods::Vector{String})
    # Check if periods are timeslot strings (sub-hourly) or simple numbers (hourly)
    if !isempty(order_book_periods)
        sample_period = order_book_periods[1]

        # If periods look like timeslot strings (e.g., "20180624-0015")
        if length(sample_period) > 5 && contains(sample_period, "-")
            # Format DateTime to match timeslot format: "YYYYMMDD-HHMM"
            date_str = Dates.format(order_datetime, "yyyymmdd")
            time_str = Dates.format(order_datetime, "HHMM")
            timeslot = "$(date_str)-$(time_str)"

            # Return the timeslot if it exists in periods, otherwise find closest match
            if timeslot in order_book_periods
                return timeslot
            else
                # Fallback: find the period with matching hour
                hour = Dates.hour(order_datetime)
                minute = Dates.minute(order_datetime)
                target_time = hour * 100 + minute

                for period in order_book_periods
                    if length(period) >= 13
                        period_hour = parse(Int, period[10:11])
                        period_min = parse(Int, period[12:13])
                        period_time = period_hour * 100 + period_min

                        if period_time >= target_time
                            return period
                        end
                    end
                end

                # Ultimate fallback: return first period of the day
                return order_book_periods[1]
            end
        else
            # Periods are simple hour numbers (1-24) - use original logic
            hour_of_day = Dates.hour(order_datetime) + 1  # Convert 0-23 to 1-24
            return string(hour_of_day)
        end
    else
        # Fallback for empty periods
        hour_of_day = Dates.hour(order_datetime) + 1
        return string(hour_of_day)
    end
end


"""
    create_typed_order_book(bidding_zone::String, day::Date; markup_factor::Float64=DEFAULT_MARKUP_FACTOR, optimizer::String="auto")

Creates a typed market order book from Unit Commitment results using existing MarketOrder types.
Preserves the native temporal resolution from Unit Commitment optimization (15/30/60 minutes).

# Arguments
- `bidding_zone::String`: Target bidding zone (e.g., "GR")  
- `day::Date`: Day for which to create the order book
- `markup_factor::Float64`: Markup factor for supply bids above marginal cost (default: 1.1 = 10% markup)
- `optimizer::String`: Solver preference for unit commitment ("auto", "highs", "gurobi", "cplex")

# Returns  
- `MPCCOrderBook`: Typed order book structure using existing MarketOrder types with native UC temporal resolution
"""
function create_typed_order_book(bidding_zone::String, day::Date;
                                  markup_factor::Float64=DEFAULT_MARKUP_FACTOR,
                                  optimizer::String="auto",
                                  use_cache::Bool=true,
                                  force_rerun::Bool=false,
                                  bidding_strategy::Symbol=:merit_order)
    try
        # Generate market orders from real unit commitment (will use cache if available)
        uc_to_bids = generate_market_orders_from_uc(bidding_zone, day;
            markup_factor=markup_factor,
            optimizer=optimizer,
            use_cache=use_cache,
            force_rerun=force_rerun,
            bidding_strategy=bidding_strategy
        )

        if !uc_to_bids.success
            error("Failed to generate market orders: $(uc_to_bids.message)")
        end

        # Create typed order book using existing SimpleOrder types
        all_orders = Vector{MarketOrder}()

        # Add all supply orders (already SimpleOrder types)
        append!(all_orders, uc_to_bids.supply_orders)

        # Add all demand orders (already SimpleOrder types) 
        append!(all_orders, uc_to_bids.demand_orders)

        # Extract unique time periods from the actual orders to preserve UC's native resolution
        time_periods = Set{String}()
        for order in all_orders
            if isa(order, SimpleOrder)
                # Format DateTime to timeslot string: "YYYYMMDD-HHMM"
                date_str = Dates.format(order.date_time, "yyyymmdd")
                time_str = Dates.format(order.date_time, "HHMM")
                timeslot = "$(date_str)-$(time_str)"
                push!(time_periods, timeslot)
            end
        end

        # Convert to sorted vector for consistent ordering
        periods_vector = sort(collect(time_periods))

        # Log the detected resolution
        if length(periods_vector) > 1
            println("   📊 Detected $(length(periods_vector)) time periods from UC orders")
            if length(periods_vector) == 24
                println("   ⏰ Resolution: Hourly (24 periods)")
            elseif length(periods_vector) == 48
                println("   ⏰ Resolution: 30-minute (48 periods)")
            elseif length(periods_vector) == 96
                println("   ⏰ Resolution: 15-minute (96 periods)")
            else
                println("   ⏰ Resolution: Custom ($(length(periods_vector)) periods)")
            end
        else
            # Fallback to hourly if no orders found
            periods_vector = [string(h) for h in 1:24]
            println("   ⚠️  No orders found, defaulting to 24 hourly periods")
        end

        # Create the typed order book with native UC resolution
        return MPCCOrderBook(
            all_orders,                                    # All orders as MarketOrder types
            [bidding_zone],                               # Single bidding zone
            periods_vector,                               # Preserve UC's native temporal resolution
            (0.0, 500.0),                                 # Price limits (€/MWh)
            nothing                                       # No network topology for single zone
        )

    catch e
        error("Failed to create typed order book from UC: $e")
    end
end


"""
    _process_zone_for_order_book(args::Tuple) -> NamedTuple

Worker function for parallel zone processing in multi-zone order book creation.
Processes a single zone and returns market orders as a named tuple.

# Arguments (unpacked from tuple)
- `zone::String`: Bidding zone to process
- `day::Date`: Market day
- `markup_factor::Float64`: Markup factor for supply bids
- `optimizer::String`: Solver preference
- `use_cache::Bool`: Whether to use UC result caching
- `force_rerun::Bool`: Whether to force UC re-solve
- `zone_net_imports::Union{Dict{String,Float64}, Nothing}`: Optional net imports for UC demand adjustment

# Returns
Named tuple with fields:
- `zone`: Zone identifier
- `success`: Whether processing succeeded
- `supply_orders`: Supply orders from UC
- `demand_orders`: Demand orders from UC
- `message`: Status message
- `elapsed_time`: Processing time in seconds
- `worker_id`: ID of the worker that processed this zone
"""
function _process_zone_for_order_book(args)
    zone, day, markup_factor, optimizer, use_cache, force_rerun, zone_net_imports, bidding_strategy = args
    worker_id = myid()
    start_time = time()

    try
        uc_to_bids = generate_market_orders_from_uc(zone, day;
            markup_factor=markup_factor,
            optimizer=optimizer,
            use_cache=use_cache,
            force_rerun=force_rerun,
            net_import_by_timeslot=zone_net_imports,
            bidding_strategy=bidding_strategy
        )

        elapsed = time() - start_time

        return (
            zone=zone,
            success=uc_to_bids.success,
            supply_orders=uc_to_bids.success ? uc_to_bids.supply_orders : SimpleOrder[],
            demand_orders=uc_to_bids.success ? uc_to_bids.demand_orders : SimpleOrder[],
            message=uc_to_bids.message,
            elapsed_time=elapsed,
            worker_id=worker_id
        )
    catch e
        elapsed = time() - start_time
        return (
            zone=zone,
            success=false,
            supply_orders=SimpleOrder[],
            demand_orders=SimpleOrder[],
            message="Error: $e",
            elapsed_time=elapsed,
            worker_id=worker_id
        )
    end
end


"""
    create_coupled_order_book(zones::Vector{String}, day::Date;
                                  markup_factor::Float64=DEFAULT_MARKUP_FACTOR,
                                  optimizer::String="auto",
                                  use_cache::Bool=true,
                                  force_rerun::Bool=false,
                                  parallel::Bool=false)

Creates a multi-zone market order book by aggregating orders from multiple bidding zones
and attaching transfer capacity constraints between zones.

# Arguments
- `zones::Vector{String}`: List of bidding zones to include (e.g., ["GR", "BG", "IT"])
- `day::Date`: Day for which to create the order book
- `markup_factor::Float64`: Markup factor for supply bids above marginal cost (default: 1.1)
- `optimizer::String`: Solver preference for unit commitment ("auto", "highs", "gurobi", "cplex")
- `use_cache::Bool`: Whether to use cached UC results (default: true)
- `force_rerun::Bool`: Whether to force UC re-solve, bypassing cache (default: false)
- `parallel::Bool`: Whether to process zones in parallel using Distributed.jl (default: false)

# Returns
- `MPCCOrderBook`: Multi-zone order book with transfer capacity constraints attached

# Parallel Execution
When `parallel=true`, zones are processed concurrently using `pmap`. Requires workers to be
set up externally via `addprocs(n)` and `@everywhere using Euphemia`. Falls back to
sequential processing if no workers are available.
"""
function create_coupled_order_book(zones::Vector{String}, day::Date;
                                      markup_factor::Float64=DEFAULT_MARKUP_FACTOR,
                                      optimizer::String="auto",
                                      use_cache::Bool=true,
                                      force_rerun::Bool=false,
                                      parallel::Bool=false,
                                      max_workers::Union{Int, Nothing}=nothing,
                                      net_imports_by_zone::Union{Dict{String, Dict{String, Float64}}, Nothing}=nothing,
                                      bidding_strategy::Symbol=:merit_order)
    if isempty(zones)
        error("At least one bidding zone must be specified")
    end

    println("🌍 Creating multi-zone order book for $(length(zones)) zones: $(join(zones, ", "))")

    # Aggregate orders from all zones
    all_orders = Vector{MarketOrder}()
    all_periods = Set{String}()
    failed_zones = String[]

    # Check for parallel execution
    use_parallel = parallel
    selected_worker_ids = Int[]
    if use_parallel
        worker_ids = filter(id -> id != 1, workers())
        available_workers = length(worker_ids)

        if available_workers == 0
            @warn "Parallel processing requested but no workers available. Falling back to sequential."
            use_parallel = false
        else
            # Determine max workers based on optimizer if not explicitly set
            effective_max_workers = if !isnothing(max_workers)
                max_workers
            elseif lowercase(optimizer) == "gurobi"
                # Gurobi WLS license typically limits concurrent sessions to 2
                2
            else
                # HiGHS: use half of available workers (leave headroom for system)
                max(1, available_workers ÷ 2)
            end
            workers_to_use = min(effective_max_workers, available_workers)
            selected_worker_ids = worker_ids[1:workers_to_use]
            reason = !isnothing(max_workers) ? "user-specified" :
                     (lowercase(optimizer) == "gurobi" ? "Gurobi license limit" : "HiGHS default")
            println("   ⚡ Parallel mode: $workers_to_use workers (of $available_workers available, $reason)")
        end
    end

    if use_parallel
        # Parallel path: process all zones concurrently using pmap with WorkerPool
        println("   📊 Processing $(length(zones)) zones in parallel...")
        # Build args with zone-specific net imports
        pmap_args = [(zone, day, markup_factor, optimizer, use_cache, force_rerun,
                      net_imports_by_zone !== nothing ? get(net_imports_by_zone, zone, nothing) : nothing,
                      bidding_strategy)
                     for zone in zones]
        # Use WorkerPool to limit concurrent workers (important for Gurobi license limits)
        pool = WorkerPool(selected_worker_ids)
        zone_results = pmap(_process_zone_for_order_book, pool, pmap_args)

        # Aggregate results from parallel execution
        for result in zone_results
            if result.success
                append!(all_orders, result.supply_orders)
                append!(all_orders, result.demand_orders)

                # Collect time periods from supply orders
                for order in result.supply_orders
                    if isa(order, SimpleOrder)
                        date_str = Dates.format(order.date_time, "yyyymmdd")
                        time_str = Dates.format(order.date_time, "HHMM")
                        timeslot = "$(date_str)-$(time_str)"
                        push!(all_periods, timeslot)
                    end
                end

                println("      [Worker $(result.worker_id)] $(result.zone): $(length(result.supply_orders)) supply + $(length(result.demand_orders)) demand ($(round(result.elapsed_time, digits=1))s)")
            else
                @warn "Failed zone $(result.zone): $(result.message)"
                push!(failed_zones, result.zone)
            end
        end
    else
        # Sequential path: process zones one at a time (original behavior)
        for zone in zones
            try
                println("   📊 Processing zone $zone...")

                # Get zone-specific net imports (or nothing)
                zone_net_imports = net_imports_by_zone !== nothing ?
                    get(net_imports_by_zone, zone, nothing) : nothing

                # Generate market orders from real unit commitment for this zone (will use cache if available)
                uc_to_bids = generate_market_orders_from_uc(zone, day;
                    markup_factor=markup_factor,
                    optimizer=optimizer,
                    use_cache=use_cache,
                    force_rerun=force_rerun,
                    net_import_by_timeslot=zone_net_imports,
                    bidding_strategy=bidding_strategy
                )

                if !uc_to_bids.success
                    @warn "Failed to generate market orders for zone $zone: $(uc_to_bids.message)"
                    push!(failed_zones, zone)
                    continue
                end

                # Append supply and demand orders
                append!(all_orders, uc_to_bids.supply_orders)
                append!(all_orders, uc_to_bids.demand_orders)

                # Collect time periods from orders
                for order in uc_to_bids.supply_orders
                    if isa(order, SimpleOrder)
                        date_str = Dates.format(order.date_time, "yyyymmdd")
                        time_str = Dates.format(order.date_time, "HHMM")
                        timeslot = "$(date_str)-$(time_str)"
                        push!(all_periods, timeslot)
                    end
                end

                println("      ✅ Added $(length(uc_to_bids.supply_orders)) supply + $(length(uc_to_bids.demand_orders)) demand orders")

            catch e
                @error "Error processing zone $zone: $e"
                push!(failed_zones, zone)
            end
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
    transfer_capacity = create_transfer_capacity_from_entsoe(day, successful_zones)

    # Log connectivity info
    zone_pairs = get_zone_pairs(transfer_capacity)
    println("   ✅ Found $(length(zone_pairs)) directional transfer capacity links")

    # Create the multi-zone order book
    order_book = MPCCOrderBook(
        all_orders,
        successful_zones,
        periods_vector,
        (0.0, 500.0),           # Price limits (€/MWh)
        transfer_capacity       # Attach transfer capacity for multi-zone clearing
    )

    println("✅ Created multi-zone order book:")
    println("   🌍 Zones: $(length(successful_zones))")
    println("   📝 Total orders: $(length(all_orders))")
    println("   🕐 Time periods: $(length(periods_vector))")
    println("   🔌 Transfer links: $(length(zone_pairs))")

    return order_book
end


"""
    solve_mpcc_market_clearing(order_book::MPCCOrderBook; 
                              preferred_solver::String="auto", 
                              silent::Bool=true,
                              big_m::Float64=BIG_M_PARAMETER)

Solves the MPCC-based market clearing problem using typed order book structure.

# Arguments
- `order_book::MPCCOrderBook`: Typed market order book structure
- `preferred_solver::String`: Preferred solver ("auto", "highs", "gurobi", or "cplex")
- `silent::Bool`: Whether to suppress solver output
- `big_m::Float64`: Big-M parameter for complementarity constraints

# Returns
- `MPCCResult`: Market clearing results including prices and order acceptance
"""
function solve_mpcc_market_clearing(order_book::MPCCOrderBook;
    preferred_solver::String="auto",
    silent::Bool=true,
    big_m::Float64=BIG_M_PARAMETER)

    # Analyze orders by type - currently we only handle SimpleOrder types from UC conversion
    simple_orders = filter(o -> isa(o, SimpleOrder), order_book.orders)

    # Create order mappings for efficient access
    orders_by_node = Dict{String,Dict{String,Vector{SimpleOrder}}}()
    for node_id in order_book.nodes
        orders_by_node[node_id] = Dict{String,Vector{SimpleOrder}}()
        for time_period in order_book.periods
            orders_by_node[node_id][time_period] = SimpleOrder[]
        end
    end

    # Group orders by node and time period
    for order in simple_orders
        node_id = string(order.zone)
        time_period = extract_time_period(order.date_time, order_book.periods)

        if haskey(orders_by_node, node_id) && haskey(orders_by_node[node_id], time_period)
            push!(orders_by_node[node_id][time_period], order)
        end
    end

    # Create and configure model
    optimizer, solver_name = select_solver(preferred_solver)
    model = Model(optimizer)

    if silent
        set_silent(model)
    end

    start_time = time()

    try
        # Create unique indices for orders - use a unique string ID based on order properties
        order_indices = Dict{SimpleOrder,String}()
        order_ids = String[]

        for (i, order) in enumerate(simple_orders)
            # Create a unique ID based on order properties and index, with explicit field labels to avoid ambiguity
            unique_id = "order_$(i)_z$(string(order.zone))_h$(Dates.hour(order.date_time))_q$(round(Int, order.quantity))_p$(round(Int, order.price))"
            order_indices[order] = unique_id
            push!(order_ids, unique_id)
        end

        # Decision Variables
        @variable(model, 0 <= stepwise_acceptance[order_id in order_ids])
        @variable(model, 0 <= stepwise_dual[order_id in order_ids])

        # Load shedding variables for market robustness (high penalty cost)
        @variable(model, load_shed[node_id in order_book.nodes, time_period in order_book.periods] >= 0)

        @variable(model, market_price[node_id in order_book.nodes, time_period in order_book.periods])

        # Multi-zone transmission flow variables and constraints (if TransferCapacity is provided)
        flow = nothing  # Initialize as nothing for single-zone case
        zone_pairs = Tuple{String,String}[]  # Empty for single-zone
        zones_to = Dict{String,Vector{String}}()   # zones that can send TO each zone
        zones_from = Dict{String,Vector{String}}() # zones that can receive FROM each zone

        if order_book.network_topology isa TransferCapacity
            tc = order_book.network_topology

            # Get all zone pairs with transfer capacity
            zone_pairs = get_zone_pairs(tc)

            if !isempty(zone_pairs)
                println("   🔌 Adding transmission flow variables for $(length(zone_pairs)) zone pairs")

                # Create flow variables for each zone pair and time period
                @variable(model, flow[pair in zone_pairs, t in order_book.periods])

                # Add ATC constraints: -backward <= flow <= forward
                for pair in zone_pairs
                    source, sink = pair
                    for t in order_book.periods
                        # Get capacity limits (using hourly period format for lookup)
                        # Convert timeslot period to hourly if needed
                        lookup_period = t
                        if length(t) > 5 && contains(t, "-")
                            # Extract hour from "YYYYMMDD-HHMM" format
                            hour = parse(Int, t[10:11]) + 1
                            lookup_period = string(hour)
                        end

                        forward_cap = get(tc.capacity_forward, (source, sink, lookup_period), 0.0)
                        backward_cap = get(tc.capacity_backward, (source, sink, lookup_period), 0.0)

                        # ATC bounds: -backward <= flow <= forward
                        set_lower_bound(flow[pair, t], -backward_cap)
                        set_upper_bound(flow[pair, t], forward_cap)
                    end
                end

                # Precompute connected zones for power balance
                for node in order_book.nodes
                    zones_to[node] = String[]   # Zones that can send TO this node
                    zones_from[node] = String[] # Zones that can receive FROM this node

                    for (s, d) in zone_pairs
                        if d == node
                            push!(zones_to[node], s)   # s can send TO node
                        end
                        if s == node
                            push!(zones_from[node], d) # node can send TO d
                        end
                    end
                end

                println("   ✅ Added $(length(zone_pairs) * length(order_book.periods)) flow variables with ATC bounds")
            end
        end

        # Stepwise order constraints
        @constraint(model, stepwise_upper_bound[order_id in order_ids],
            stepwise_acceptance[order_id] <= 1
        )

        # Create expressions for stepwise dual constraints - match dictionary formulation exactly
        stepwise_dual_rhs = Dict{String,AffExpr}()
        for (i, order) in enumerate(simple_orders)
            order_id = order_ids[i]
            node_id = string(order.zone)
            time_period = extract_time_period(order.date_time, order_book.periods)

            # Determine quantity sign: negative for supply, positive for demand
            quantity = order.type == :supply ? -order.quantity : order.quantity

            # Match dictionary formulation: sum over time periods (but SimpleOrder only has one period)
            # This should be equivalent since SimpleOrder represents single period
            stepwise_dual_rhs[order_id] = @expression(model,
                stepwise_dual[order_id] +
                quantity * market_price[node_id, time_period] -
                quantity * order.price
            )
        end

        @constraint(model, stepwise_dual_constraint[order_id in order_ids],
            0 <= stepwise_dual_rhs[order_id]
        )

        # Precompute mapping from (node_id, time_period) to relevant order indices
        orders_by_node_time = Dict{Tuple{String,String},Vector{Int}}()
        for (i, order) in enumerate(simple_orders)
            node = string(order.zone)
            # Use the extract_time_period function to get the correct period mapping
            period = extract_time_period(order.date_time, order_book.periods)
            key = (node, period)
            if haskey(orders_by_node_time, key)
                push!(orders_by_node_time[key], i)
            else
                orders_by_node_time[key] = [i]
            end
        end

        # Power balance constraints with optional transmission flows
        # For multi-zone: supply - demand + inflows - outflows + load_shed = 0
        # For single-zone: supply - demand + load_shed = 0
        if flow !== nothing && !isempty(zone_pairs)
            # Multi-zone power balance with transmission flows
            @constraint(model, nodal_power_balance[node_id in order_book.nodes, time_period in order_book.periods],
                # Order contribution: supply (negative) + demand (positive)
                sum(
                    stepwise_acceptance[order_ids[i]] *
                    (simple_orders[i].type == :supply ? -simple_orders[i].quantity : simple_orders[i].quantity)
                    for i in get(orders_by_node_time, (node_id, time_period), Int[]);
                    init=0.0
                ) +
                # Load shedding (emergency)
                load_shed[node_id, time_period] +
                # Inflows: power coming INTO this zone (flow[source, this_zone])
                sum(flow[(z, node_id), time_period] for z in get(zones_to, node_id, String[]); init=0.0) -
                # Outflows: power going OUT of this zone (flow[this_zone, sink])
                sum(flow[(node_id, z), time_period] for z in get(zones_from, node_id, String[]); init=0.0)
                == 0
            )
        else
            # Single-zone power balance (no transmission flows)
            @constraint(model, nodal_power_balance[node_id in order_book.nodes, time_period in order_book.periods],
                sum(
                    stepwise_acceptance[order_ids[i]] *
                    (simple_orders[i].type == :supply ? -simple_orders[i].quantity : simple_orders[i].quantity)
                    for i in get(orders_by_node_time, (node_id, time_period), Int[]);
                    init=0.0
                ) +
                load_shed[node_id, time_period] == 0
            )
        end

        # Complementarity constraints using Big-M reformulation
        @variable(model, stepwise_acceptance_complementarity_aux[order_id in order_ids], Bin)
        @constraint(model, stepwise_acceptance_complementarity_ineq1[order_id in order_ids],
            stepwise_acceptance[order_id] <= stepwise_acceptance_complementarity_aux[order_id] * big_m)
        @constraint(model, stepwise_acceptance_complementarity_ineq2[order_id in order_ids],
            stepwise_dual_rhs[order_id] <= (1 - stepwise_acceptance_complementarity_aux[order_id]) * big_m)

        # Price range constraints
        @constraint(model, minimum_price[node_id in order_book.nodes, time_period in order_book.periods],
            market_price[node_id, time_period] >= order_book.price_limits[1])
        @constraint(model, maximum_price[node_id in order_book.nodes, time_period in order_book.periods],
            market_price[node_id, time_period] <= order_book.price_limits[2])

        # Objective function - match dictionary formulation exactly
        # Dictionary version: stepwise_acceptance[order_id] * (sum of quantities) * price
        # Need to use signed quantities: negative for supply, positive for demand
        load_shed_penalty = 10000.0  # High penalty for load shedding (€/MWh)

        # Price regularization: small term to push market_price to the minimum feasible value.
        # Without this, market_price is underdetermined — it only appears in complementarity
        # constraints that set lower bounds (market_price ≥ accepted_supply_price), so the solver
        # picks any value up to the upper bound (500 EUR). The regularization drives the price
        # to max(accepted_supply_prices), which is the correct merit-order clearing price.
        # ε = 1e-6 is small enough to not affect welfare-optimal acceptance decisions.
        price_regularization = 1e-6

        @objective(model, Max,
            sum(stepwise_acceptance[order_ids[i]] *
                (order.type == :supply ? -order.quantity : order.quantity) * order.price
                for (i, order) in enumerate(simple_orders)) -
            load_shed_penalty * sum(load_shed[node_id, time_period]
                                    for node_id in order_book.nodes, time_period in order_book.periods) -
            price_regularization * sum(market_price[node_id, time_period]
                                       for node_id in order_book.nodes, time_period in order_book.periods)
        )

        # Solve the model
        optimize!(model)
        solve_time = time() - start_time

        # Extract results
        if has_values(model)
            market_prices = Dict{String,Dict{String,Float64}}()
            for node_id in order_book.nodes
                market_prices[node_id] = Dict{String,Float64}()
                for time_period in order_book.periods
                    market_prices[node_id][time_period] = value(market_price[node_id, time_period])
                end
            end

            stepwise_acceptance_values = Dict{String,Float64}()
            for (i, order) in enumerate(simple_orders)
                order_id = order_ids[i]
                stepwise_acceptance_values[order_id] = value(stepwise_acceptance[order_id])
            end

            # Extract transmission flow values if multi-zone
            transmission_flow_values = Dict{String,Dict{String,Float64}}()
            if flow !== nothing && !isempty(zone_pairs)
                for pair in zone_pairs
                    source, sink = pair
                    flow_id = "$(source)_to_$(sink)"
                    transmission_flow_values[flow_id] = Dict{String,Float64}()

                    for t in order_book.periods
                        transmission_flow_values[flow_id][t] = value(flow[pair, t])
                    end
                end
                println("   📊 Extracted flows for $(length(zone_pairs)) zone pairs")
            end

            # Convert JuMP termination status to our expected Symbol
            status_symbol = if string(termination_status(model)) == "OPTIMAL"
                :optimal
            elseif string(termination_status(model)) == "INFEASIBLE"
                :infeasible
            elseif string(termination_status(model)) == "UNBOUNDED"
                :unbounded
            elseif string(termination_status(model)) == "TIME_LIMIT"
                :time_limit
            else
                :error
            end

            return MPCCResult(
                status_symbol,
                objective_value(model),
                market_prices,
                stepwise_acceptance_values,
                Dict{String,Float64}(),  # Empty block acceptance
                Dict{String,Float64}(),  # Empty block activation
                transmission_flow_values,  # Transmission flows (populated if multi-zone)
                solve_time,
                solve_time,  # total_time (will be updated by caller if needed)
                solver_name,
                string(termination_status(model))
            )
        else
            return MPCCResult(
                termination_status(model),
                0.0,
                Dict{String,Dict{String,Float64}}(),
                Dict{String,Float64}(),
                Dict{String,Float64}(),
                Dict{String,Float64}(),
                Dict{String,Dict{String,Float64}}(),
                solve_time,
                solve_time,  # total_time (will be updated by caller if needed)
                solver_name,
                "No solution available: $(termination_status(model))"
            )
        end

    catch e
        solve_time = time() - start_time
        return MPCCResult(
            :error,
            0.0,
            Dict{String,Dict{String,Float64}}(),
            Dict{String,Float64}(),
            Dict{String,Float64}(),
            Dict{String,Float64}(),
            Dict{String,Dict{String,Float64}}(),
            solve_time,
            solve_time,  # total_time (will be updated by caller if needed)
            solver_name,
            "Optimization failed: $e"
        )
    end
end

# =============================================================================
# FLOW-TO-NET-IMPORT CONVERSION UTILITIES
# =============================================================================

"""
    compute_net_imports_from_flows(transmission_flows, zones) -> Dict{String, Dict{String, Float64}}

Convert MPCC transmission flows to per-zone net imports for UC demand adjustment.

Net import for zone Z = sum(inflows to Z) - sum(outflows from Z)
- Positive = zone is net importer (reduces UC demand)
- Negative = zone is net exporter (increases UC demand)

# Arguments
- `transmission_flows::Dict{String, Dict{String, Float64}}`: MPCC output with keys like "GR_to_BG"
- `zones::Vector{String}`: List of zone codes to compute net imports for

# Returns
- `Dict{String, Dict{String, Float64}}`: net_imports[zone][period] → MW

# Example
```julia
flows = Dict("GR_to_BG" => Dict("1" => 100.0, "2" => 150.0))
zones = ["GR", "BG"]
net_imports = compute_net_imports_from_flows(flows, zones)
# net_imports["GR"]["1"] == -100.0  (exporting)
# net_imports["BG"]["1"] == 100.0   (importing)
```
"""
function compute_net_imports_from_flows(
    transmission_flows::Dict{String, Dict{String, Float64}},
    zones::Vector{String}
)::Dict{String, Dict{String, Float64}}

    net_imports = Dict{String, Dict{String, Float64}}()

    # Initialize all zones with empty dicts
    for zone in zones
        net_imports[zone] = Dict{String, Float64}()
    end

    # Process each flow
    for (flow_id, period_flows) in transmission_flows
        # Parse "SOURCE_to_SINK" format
        parts = split(flow_id, "_to_")
        if length(parts) != 2
            @warn "Invalid flow_id format: $flow_id, expected SOURCE_to_SINK"
            continue
        end
        source_zone = String(parts[1])
        sink_zone = String(parts[2])

        for (period, flow_mw) in period_flows
            # Sink receives power (positive = import)
            if haskey(net_imports, sink_zone)
                current = get(net_imports[sink_zone], period, 0.0)
                net_imports[sink_zone][period] = current + flow_mw
            end

            # Source sends power (negative = export)
            if haskey(net_imports, source_zone)
                current = get(net_imports[source_zone], period, 0.0)
                net_imports[source_zone][period] = current - flow_mw
            end
        end
    end

    return net_imports
end

"""
    compute_max_price_change(current_prices, previous_prices) -> Float64

Compute maximum absolute change in market prices between iterations (€/MWh).
This is the primary convergence criterion for iterative UC-MPCC.

Price-based convergence is preferred over flow-based because:
- Prices are the economic fixed point of market coupling
- Flows are derived quantities that can oscillate near binding constraints
- UC binaries can cause small flow changes even when prices are stable

# Arguments
- `current_prices::Dict{String, Dict{String, Float64}}`: Prices by zone and period
- `previous_prices::Union{Dict{String, Dict{String, Float64}}, Nothing}`: Previous iteration prices

# Returns
- `Float64`: Maximum absolute price change across all zones and periods (€/MWh)
"""
function compute_max_price_change(
    current_prices::Dict{String, Dict{String, Float64}},
    previous_prices::Union{Dict{String, Dict{String, Float64}}, Nothing}
)::Float64
    if previous_prices === nothing
        return Inf
    end

    max_change = 0.0
    for (zone, periods) in current_prices
        prev_zone = get(previous_prices, zone, Dict{String, Float64}())
        for (period, price) in periods
            prev_price = get(prev_zone, period, price)  # Default to same price if missing
            change = abs(price - prev_price)
            max_change = max(max_change, change)
        end
    end
    return max_change
end

"""
    compute_max_relative_flow_change(current_flows, previous_flows; min_flow::Float64=10.0) -> Float64

Compute maximum relative change in transmission flows between iterations (fraction).
Used as a diagnostic metric alongside price convergence.

# Arguments
- `current_flows::Dict{String, Dict{String, Float64}}`: Flows by corridor and period
- `previous_flows::Union{Dict{String, Dict{String, Float64}}, Nothing}`: Previous iteration flows
- `min_flow::Float64`: Minimum flow magnitude for denominator to avoid division issues (default: 10 MW)

# Returns
- `Float64`: Maximum relative flow change as a fraction (e.g., 0.02 = 2%)
"""
function compute_max_relative_flow_change(
    current_flows::Dict{String, Dict{String, Float64}},
    previous_flows::Union{Dict{String, Dict{String, Float64}}, Nothing};
    min_flow::Float64=10.0
)::Float64
    if previous_flows === nothing
        return Inf
    end

    max_relative_change = 0.0
    for (flow_id, periods) in current_flows
        prev_corridor = get(previous_flows, flow_id, Dict{String, Float64}())
        for (period, flow) in periods
            prev_flow = get(prev_corridor, period, 0.0)
            abs_change = abs(flow - prev_flow)
            # Use max of current and previous flow magnitude for denominator
            denominator = max(abs(flow), abs(prev_flow), min_flow)
            relative_change = abs_change / denominator
            max_relative_change = max(max_relative_change, relative_change)
        end
    end
    return max_relative_change
end

"""
    compute_max_flow_change(current, previous) -> Float64

Compute maximum absolute change in transmission flows between iterations (MW).

This is the primary convergence criterion for the iterative UC-MPCC algorithm.
Flows are the primal input variable fed back to UC (via net imports adjusting demand),
making them the natural fixed-point variable. Convergence is declared when:

    max|f(k) - f(k-1)| < flow_tolerance

A typical tolerance is 100 MW for European-scale market coupling (36 zones).
"""
function compute_max_flow_change(
    current::Dict{String, Dict{String, Float64}},
    previous::Union{Dict{String, Dict{String, Float64}}, Nothing}
)::Float64
    if previous === nothing
        # First iteration - return infinity to force at least one more iteration
        return Inf
    end

    max_change = 0.0
    for (zone, periods) in current
        prev_zone = get(previous, zone, Dict{String, Float64}())
        for (period, value) in periods
            prev_value = get(prev_zone, period, 0.0)
            change = abs(value - prev_value)
            max_change = max(max_change, change)
        end
    end
    return max_change
end

"""
    apply_damping(current, previous, α) -> Dict{String, Dict{String, Float64}}

Apply damping to net imports: new = α × current + (1-α) × previous
"""
function apply_damping(
    current::Dict{String, Dict{String, Float64}},
    previous::Union{Dict{String, Dict{String, Float64}}, Nothing},
    α::Float64
)::Dict{String, Dict{String, Float64}}
    if previous === nothing || α >= 1.0
        return current
    end

    damped = Dict{String, Dict{String, Float64}}()
    for (zone, periods) in current
        damped[zone] = Dict{String, Float64}()
        prev_zone = get(previous, zone, Dict{String, Float64}())
        for (period, value) in periods
            prev_value = get(prev_zone, period, 0.0)
            damped[zone][period] = α * value + (1 - α) * prev_value
        end
    end
    return damped
end

end  # module MPCC