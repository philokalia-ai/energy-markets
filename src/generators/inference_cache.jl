# inference_cache.jl — Apply / persist inferred parameters (simulations.generator_inferred_parameters) and the proactive refresh entry point.
# Included by ../Generators.jl inside `module Euphemia` (definition order preserved).

"""
    infer_parameters_for_generator(gen::Generator, day::Date) -> Generator

Infer parameters for a single generator from historical data.
This is the core inference function that can be parallelized.

Parameters inferred:
- ramp_up, ramp_down: from 95th percentile of observed ramps (fraction/hour)
- p_min: from 5th percentile of stable non-zero operation (MW)
- min_uptime, min_downtime: from 5th percentile of on/off cycle durations (hours)
"""
function infer_parameters_for_generator(gen::Generator, day::Dates.Date)
    # Fetch historical generation data
    historical = get_historical_generation(gen.code, day)

    # Infer ramp rates (as fraction of p_max per hour)
    rates = infer_ramp_rates(historical, gen.p_max)

    # Determine parameters based on fuel type
    if gen.fuel_type in FLEXIBLE_FUEL_TYPES
        # Flexible resources (hydro, batteries) can operate at 0 MW
        # and have no meaningful uptime/downtime constraints
        final_p_min = 0.0
        final_uptime = nothing
        final_downtime = nothing
    else
        # Thermal plants: infer from stable operation
        inferred_p_min = infer_p_min(historical, gen.p_max, gen.fuel_type)
        final_p_min = inferred_p_min !== nothing ? inferred_p_min : gen.p_min

        # Infer uptime/downtime from on/off cycles
        (inferred_uptime, inferred_downtime) = infer_uptime_downtime(historical, gen.fuel_type)
        final_uptime = inferred_uptime
        final_downtime = inferred_downtime
    end

    # Validate: p_min must not exceed p_max (can happen if outages reduce capacity)
    if final_p_min > gen.p_max
        @warn "Clamping inferred p_min to p_max (outage reduced capacity)" generator=gen.code inferred_p_min=final_p_min p_max=gen.p_max
        final_p_min = gen.p_max
    end

    # Create new generator with inferred parameters
    return Generator(
        gen.code,
        gen.name,
        gen.fuel_type,
        gen.location,
        gen.p_max,
        final_p_min,
        gen.bidding_zone,
        gen.marginal_cost,
        rates.ramp_up,
        rates.ramp_down,
        final_uptime,
        final_downtime
    )
end

"""
    infer_parameters_for_generators(generators::Vector{Generator}, day::Date) -> Vector{Generator}

Infer parameters for multiple generators. Wrapper around `infer_parameters_for_generator`.
"""
function infer_parameters_for_generators(generators::Vector{Generator}, day::Dates.Date)
    return [infer_parameters_for_generator(gen, day) for gen in generators]
end

# Alias for backward compatibility
infer_ramp_rates_for_generators(generators::Vector{Generator}, day::Dates.Date) =
    infer_parameters_for_generators(generators, day)

# Convenience function for backward compatibility - defaults to GR
function get_generators(day::Dates.Date)
    return get_generators("GR", day)
end

# ============================================================================
# Cached Inferred Parameters (Database Persistence)
# ============================================================================

"""
    save_inferred_parameters(generators::Vector{Generator}, bidding_zone::String, reference_date::Date)

Save inferred generator parameters to the database cache.
Uses UPSERT to update existing records or insert new ones.
The inference_date is set to today (when inference was run), not the reference market day.
"""
function save_inferred_parameters(generators::Vector{Generator}, bidding_zone::String, reference_date::Dates.Date)
    sql = """
    INSERT INTO simulations.generator_inferred_parameters
    (generator_code, bidding_zone, inference_date, ramp_up, ramp_down, p_min, min_uptime, min_downtime, data_points_used, created_at)
    VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, NOW())
    ON CONFLICT (generator_code, bidding_zone) DO UPDATE SET
        inference_date = EXCLUDED.inference_date,
        ramp_up = EXCLUDED.ramp_up,
        ramp_down = EXCLUDED.ramp_down,
        p_min = EXCLUDED.p_min,
        min_uptime = EXCLUDED.min_uptime,
        min_downtime = EXCLUDED.min_downtime,
        data_points_used = EXCLUDED.data_points_used,
        created_at = NOW()
    """

    # Helper to convert nothing to missing for PostgreSQL NULL
    to_pg(x) = x === nothing ? missing : x

    # Use today's date as the inference date (when we ran the inference)
    today = Dates.today()

    saved_count = 0
    Euphemia.withdb() do conn
        for gen in generators
            # Count data points (estimate from historical query)
            historical = get_historical_generation(gen.code, reference_date)
            data_points = nrow(historical)

            params = [
                gen.code,
                bidding_zone,
                today,  # inference_date = when we ran the inference
                to_pg(gen.ramp_up),
                to_pg(gen.ramp_down),
                gen.p_min,
                to_pg(gen.min_uptime),
                to_pg(gen.min_downtime),
                data_points
            ]
            LibPQ.execute(conn, sql, params)
            saved_count += 1
        end
    end

    @info "Saved inferred parameters for $saved_count generators in zone $bidding_zone"
    return saved_count
end

"""
    load_cached_parameters(bidding_zone::String; max_age_days::Int=30)

Load cached inferred parameters from the database.
Returns a Dict mapping generator_code => (ramp_up, ramp_down, p_min, min_uptime, min_downtime).
Only returns parameters that are not older than max_age_days.

Note: Physical parameters like ramp rates don't change frequently, so a longer cache
period (30 days) is appropriate.
"""
function load_cached_parameters(bidding_zone::String; max_age_days::Int=30)
    query = """
    SELECT generator_code, ramp_up, ramp_down, p_min, min_uptime, min_downtime, inference_date
    FROM simulations.generator_inferred_parameters
    WHERE bidding_zone = \$1
      AND inference_date >= CURRENT_DATE - INTERVAL '\$2 days'
    """

    # Replace $2 with actual value since PostgreSQL doesn't parameterize intervals well
    query = replace(query, "\$2" => string(max_age_days))
    df = Euphemia.sql2df_with_retry(query, [bidding_zone])

    cache = Dict{String, NamedTuple{(:ramp_up, :ramp_down, :p_min, :min_uptime, :min_downtime),
                                     Tuple{Union{Float64,Nothing}, Union{Float64,Nothing}, Union{Float64,Nothing}, Union{Int,Nothing}, Union{Int,Nothing}}}}()

    for row in eachrow(df)
        cache[row.generator_code] = (
            ramp_up = ismissing(row.ramp_up) ? nothing : row.ramp_up,
            ramp_down = ismissing(row.ramp_down) ? nothing : row.ramp_down,
            p_min = ismissing(row.p_min) ? nothing : row.p_min,
            min_uptime = ismissing(row.min_uptime) ? nothing : Int(row.min_uptime),
            min_downtime = ismissing(row.min_downtime) ? nothing : Int(row.min_downtime)
        )
    end

    return cache
end

"""
    get_generators_with_inferred_params(map_code::String, day::Date;
                                        use_cache::Bool=true,
                                        max_cache_age_days::Int=7,
                                        exclude_unavailable::Bool=true)

Get generators with inferred parameters, using cached values when available.

If use_cache=true (default):
1. Load cached parameters from DB
2. For generators with cached values, apply them
3. For generators without cache (or stale cache), run inference and save to DB

If use_cache=false: Always run fresh inference (slow but guaranteed fresh).
"""
function get_generators_with_inferred_params(map_code::String, day::Dates.Date;
                                             use_cache::Bool=true,
                                             max_cache_age_days::Int=365,
                                             exclude_unavailable::Bool=true,
                                             exclude_variable_renewables::Bool=true)
    # Get base generators
    generators = get_generators(map_code, day;
                               exclude_unavailable=exclude_unavailable,
                               exclude_variable_renewables=exclude_variable_renewables)

    if !use_cache
        # Fresh inference for all
        println("  🔄 Running fresh parameter inference for all generators...")
        inferred = infer_parameters_for_generators(generators, day)
        save_inferred_parameters(inferred, map_code, day)
        return inferred
    end

    # Load cached parameters
    cache = load_cached_parameters(map_code; max_age_days=max_cache_age_days)
    println("  📦 Found $(length(cache)) cached parameter sets for zone $map_code")

    # Separate generators into cached and uncached
    cached_gens = Generator[]
    uncached_gens = Generator[]

    for gen in generators
        if haskey(cache, gen.code)
            params = cache[gen.code]
            # Apply cached parameters with validation
            candidate_p_min = params.p_min !== nothing ? params.p_min : gen.p_min

            # Validate: p_min must not exceed p_max (can happen if outages reduce capacity)
            if candidate_p_min > gen.p_max
                @warn "Clamping cached p_min to p_max (outage reduced capacity)" generator=gen.code cached_p_min=candidate_p_min p_max=gen.p_max
                candidate_p_min = gen.p_max
            end

            updated_gen = Generator(
                gen.code,
                gen.name,
                gen.fuel_type,
                gen.location,
                gen.p_max,
                candidate_p_min,
                gen.bidding_zone,
                gen.marginal_cost,
                params.ramp_up,
                params.ramp_down,
                params.min_uptime,
                params.min_downtime
            )
            push!(cached_gens, updated_gen)
        else
            push!(uncached_gens, gen)
        end
    end

    println("  ✓ Using cached params for $(length(cached_gens)) generators")

    # Run inference for uncached generators
    if !isempty(uncached_gens)
        println("  🔄 Running inference for $(length(uncached_gens)) uncached generators...")
        newly_inferred = infer_parameters_for_generators(uncached_gens, day)
        save_inferred_parameters(newly_inferred, map_code, day)
        append!(cached_gens, newly_inferred)
    end

    return cached_gens
end

"""
    refresh_inference_cache(zones::Vector{String}, date::Date; parallel::Bool=false)

Proactively refresh the generator parameter inference cache for specified zones.

This function runs parameter inference for all generators in the given zones and
saves results to the database cache. Use this before batch UC runs to ensure
predictable solve times (avoids surprise 17+ minute inference during UC).

When parallel=true, inference is parallelized at the **generator level** (not zone level),
allowing full utilization of all available workers. Each generator's inference is
completely independent.

# Arguments
- `zones`: List of bidding zone codes (e.g., ["GR", "BG", "RO"])
- `date`: Reference date for inference (uses 12 months of historical data before this date)
- `parallel`: If true, runs inference for all generators in parallel using available workers

# Returns
A NamedTuple with:
- `successful_zones`: Number of zones successfully processed
- `failed_zones`: Number of zones that failed
- `total_generators`: Total number of generators processed
- `successful_generators`: Number of generators successfully inferred
- `failed_generators`: Number of generators that failed
- `total_time`: Total processing time in seconds
- `zone_results`: Dict mapping zone code to (success, generator_count, failed_count)

# Example
```julia
# Refresh cache for specific zones
result = refresh_inference_cache(["GR", "BG", "RO"], Date(2024, 6, 15))

# Refresh all available zones with parallel processing
using Distributed
addprocs(80)  # Use all cores - inference is I/O bound
@everywhere using Euphemia
zones = get_available_zones(Date(2024, 6, 15))
result = refresh_inference_cache(zones, Date(2024, 6, 15); parallel=true)
```
"""
function refresh_inference_cache(zones::Vector{String}, date::Dates.Date; parallel::Bool=false)
    start_time = time()

    println("🔄 Refreshing inference cache for $(length(zones)) zones")
    println("📅 Reference date: $date (using 12 months of historical data)")
    println()

    # Step 1: Collect all generators from all zones
    println("📋 Collecting generators from all zones...")
    all_generators = Tuple{String, Generator}[]  # (zone, generator) pairs
    zone_generator_counts = Dict{String, Int}()

    for zone in zones
        try
            gens = get_generators(zone, date)
            zone_generator_counts[zone] = length(gens)
            for gen in gens
                push!(all_generators, (zone, gen))
            end
            println("  📍 $zone: $(length(gens)) generators")
        catch e
            println("  ❌ $zone: failed to load generators - $e")
            zone_generator_counts[zone] = 0
        end
    end

    total_generators = length(all_generators)
    println()
    println("📊 Total: $total_generators generators across $(length(zones)) zones")
    println()

    if total_generators == 0
        return (
            successful_zones = 0,
            failed_zones = length(zones),
            total_generators = 0,
            successful_generators = 0,
            failed_generators = 0,
            total_time = round(time() - start_time, digits=1),
            zone_results = Dict{String, NamedTuple{(:success, :generator_count, :failed_count), Tuple{Bool, Int, Int}}}()
        )
    end

    # Step 2: Run inference for each generator (parallel or sequential)
    println("⚙️  Running inference...")

    function infer_single(zg::Tuple{String, Generator})
        zone, gen = zg
        try
            inferred = infer_parameters_for_generator(gen, date)
            return (zone, gen.code, inferred, nothing)  # (zone, code, result, error)
        catch e
            return (zone, gen.code, nothing, e)
        end
    end

    if parallel && length(workers()) > 1
        println("⚡ Using $(length(workers())) parallel workers for $total_generators generators")
        results = pmap(infer_single, all_generators; on_error=ex -> (nothing, nothing, nothing, ex))
    else
        println("🔄 Sequential processing of $total_generators generators")
        results = [infer_single(zg) for zg in all_generators]
    end

    # Step 3: Group results by zone and save to cache
    println()
    println("💾 Saving results to cache...")

    zone_generators = Dict{String, Vector{Generator}}()
    zone_failures = Dict{String, Int}()
    successful_generators = 0
    failed_generators = 0

    for (zone, code, inferred, err) in results
        if zone === nothing
            failed_generators += 1
            continue
        end

        if !haskey(zone_generators, zone)
            zone_generators[zone] = Generator[]
            zone_failures[zone] = 0
        end

        if err === nothing && inferred !== nothing
            push!(zone_generators[zone], inferred)
            successful_generators += 1
        else
            zone_failures[zone] += 1
            failed_generators += 1
            println("  ⚠️  $zone/$code: inference failed - $err")
        end
    end

    # Save each zone's inferred generators to cache
    zone_results = Dict{String, NamedTuple{(:success, :generator_count, :failed_count), Tuple{Bool, Int, Int}}}()

    for zone in zones
        gens = get(zone_generators, zone, Generator[])
        failures = get(zone_failures, zone, 0)

        if !isempty(gens)
            try
                save_inferred_parameters(gens, zone, date)
                zone_results[zone] = (success=true, generator_count=length(gens), failed_count=failures)
                println("  ✅ $zone: saved $(length(gens)) generators")
            catch e
                zone_results[zone] = (success=false, generator_count=0, failed_count=length(gens) + failures)
                println("  ❌ $zone: failed to save - $e")
            end
        else
            zone_results[zone] = (success=false, generator_count=0, failed_count=failures)
            if zone_generator_counts[zone] > 0
                println("  ❌ $zone: all $(zone_generator_counts[zone]) generators failed")
            end
        end
    end

    total_time = round(time() - start_time, digits=1)
    successful_zones = count(r -> r.success, values(zone_results))
    failed_zones = length(zones) - successful_zones

    println()
    println("="^50)
    println("📊 Inference Cache Refresh Complete")
    println("="^50)
    println("✅ Zones: $successful_zones/$(length(zones)) successful")
    println("✅ Generators: $successful_generators/$total_generators successful")
    println("❌ Failed generators: $failed_generators")
    println("⏱️  Total time: $(total_time)s")
    if parallel && length(workers()) > 1
        println("⚡ Throughput: $(round(total_generators / total_time, digits=1)) generators/sec")
    end

    return (
        successful_zones = successful_zones,
        failed_zones = failed_zones,
        total_generators = total_generators,
        successful_generators = successful_generators,
        failed_generators = failed_generators,
        total_time = total_time,
        zone_results = zone_results
    )
end

# ============================================================================
# Initial Conditions for Unit Commitment
# ============================================================================

