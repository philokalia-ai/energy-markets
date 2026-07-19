# order_books.jl — Adapters from UC solutions and zone books to MPCCOrderBook: create_typed_order_book (single zone) and create_multi_zone_order_book.
# Included by ../MPCC.jl inside `module MPCC` (definition order preserved).

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
                                  force_rerun::Bool=false)
    try
        # Generate market orders from real unit commitment (will use cache if available)
        uc_to_bids = generate_market_orders_from_uc(bidding_zone, day;
            markup_factor=markup_factor,
            optimizer=optimizer,
            use_cache=use_cache,
            force_rerun=force_rerun
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
    zone, day, markup_factor, optimizer, use_cache, force_rerun, zone_net_imports = args
    worker_id = myid()
    start_time = time()

    try
        uc_to_bids = generate_market_orders_from_uc(zone, day;
            markup_factor=markup_factor,
            optimizer=optimizer,
            use_cache=use_cache,
            force_rerun=force_rerun,
            net_import_by_timeslot=zone_net_imports
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
    create_multi_zone_order_book(zones::Vector{String}, day::Date;
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
function create_multi_zone_order_book(zones::Vector{String}, day::Date;
                                      markup_factor::Float64=DEFAULT_MARKUP_FACTOR,
                                      optimizer::String="auto",
                                      use_cache::Bool=true,
                                      force_rerun::Bool=false,
                                      parallel::Bool=false,
                                      max_workers::Union{Int, Nothing}=nothing,
                                      net_imports_by_zone::Union{Dict{String, Dict{String, Float64}}, Nothing}=nothing)
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
                      net_imports_by_zone !== nothing ? get(net_imports_by_zone, zone, nothing) : nothing)
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
                    net_import_by_timeslot=zone_net_imports
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


