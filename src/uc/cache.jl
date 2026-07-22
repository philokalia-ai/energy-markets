# cache.jl — UC results caching: has_cached_uc_results / save_uc_results / load_uc_results against simulations.uc_*.
# Included by ../UnitCommitment.jl inside `module Euphemia` (definition order preserved).

# =============================================================================
# UC Results Caching Functions
# =============================================================================

"""
    has_cached_uc_results(bidding_zone::String, day::Date; code_version::Int=4) -> Bool

Check if valid cached UC results exist for the given zone and date.
Returns true if OPTIMAL results exist, false otherwise.
"""
function has_cached_uc_results(bidding_zone::String, day::Dates.Date; code_version::Int=4)::Bool
    query = """
    SELECT EXISTS(
        SELECT 1 FROM simulations.uc_results
        WHERE bidding_zone = \$1
          AND market_date = \$2
          AND code_version = \$3
          AND status = 'OPTIMAL'
    ) AS has_cache
    """

    try
        df = Euphemia.sql2df_with_retry(query, [bidding_zone, day, code_version])
        return !isempty(df) && df.has_cache[1]
    catch e
        # Table might not exist yet - that's fine, no cache
        @debug "Cache check failed (table may not exist): $e"
        return false
    end
end

"""
    save_uc_results(solution::NamedTuple, bidding_zone::String, day::Date;
                    code_version::Int=4) -> Union{Int,Nothing}

Save UC solution to database cache. Returns the uc_result_id or nothing on failure.

Uses delete-before-insert pattern for clean replacement of existing results.
"""
function save_uc_results(solution::NamedTuple, bidding_zone::String, day::Dates.Date;
                         code_version::Int=4)::Union{Int,Nothing}
    Euphemia._duckdb_readonly_guard("save_uc_results") && return nothing
    # Ensure tables exist
    Euphemia.ensure_uc_results_tables()

    try
        result_id = Euphemia.withdb() do cnx
            # Start transaction
            LibPQ.execute(cnx, "BEGIN")

            try
                # Delete existing results for this zone/date/version
                delete_sql = """
                DELETE FROM simulations.uc_results
                WHERE bidding_zone = \$1
                  AND market_date = \$2
                  AND code_version = \$3
                """
                LibPQ.execute(cnx, delete_sql, [bidding_zone, day, code_version])

                # Insert summary record
                cb = solution.cost_breakdown
                # Calculate curtailment and excess energy in MWh
                period_hours = solution.resolution_minutes / 60.0
                total_curtailment_mwh = sum(solution.curtailment) * period_hours
                total_excess_mwh = sum(solution.excess) * period_hours
                total_shortage_mwh = sum(solution.shortage) * period_hours

                insert_summary_sql = """
                INSERT INTO simulations.uc_results
                (bidding_zone, market_date, status, solver, resolution_minutes,
                 num_generators, num_periods, total_cost, production_cost,
                 startup_cost, noload_cost, hot_startups, warm_startups,
                 cold_startups, total_curtailment_mwh, curtailment_cost,
                 total_excess_mwh, excess_cost, total_shortage_mwh, shortage_cost, code_version)
                VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, \$13, \$14, \$15, \$16, \$17, \$18, \$19, \$20, \$21)
                RETURNING id
                """

                result = LibPQ.execute(cnx, insert_summary_sql, [
                    bidding_zone,
                    day,
                    string(solution.status),
                    solution.solver,
                    solution.resolution_minutes,
                    length(solution.generators),
                    length(solution.time_slots),
                    solution.total_cost,
                    cb.production_cost,
                    cb.startup_cost,
                    cb.noload_cost,
                    cb.startup_counts[:hot],
                    cb.startup_counts[:warm],
                    cb.startup_counts[:cold],
                    total_curtailment_mwh,
                    solution.curtailment_cost,
                    total_excess_mwh,
                    solution.excess_cost,
                    total_shortage_mwh,
                    solution.shortage_cost,
                    code_version
                ])

                df = DataFrame(result)
                uc_result_id = df.id[1]

                # Batch insert generation data
                N = length(solution.generators)
                T = length(solution.time_slots)

                gen_insert_sql = """
                    INSERT INTO simulations.uc_generation
                    (uc_result_id, generator_code, generator_idx, period_idx,
                     time_slot_utc, generation_mw, commitment, startup)
                    VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8)
                """

                for i in 1:N
                    gen = solution.generators[i]
                    for t in 1:T
                        time_slot_str = solution.time_slots[t]
                        time_slot_dt = DateTime(time_slot_str, dateformat"yyyymmdd-HHMM")

                        LibPQ.execute(cnx, gen_insert_sql, [
                            uc_result_id,
                            gen.code,
                            i,
                            t,
                            time_slot_dt,
                            solution.g[i, t],
                            round(Int, solution.u[i, t]),
                            round(Int, solution.v[i, t])
                        ])
                    end
                end

                # Insert net demand data (including curtailment, excess, and shortage per period)
                demand_insert_sql = """
                    INSERT INTO simulations.uc_net_demand
                    (uc_result_id, period_idx, time_slot_utc, net_demand_mw, renewable_generation_mw, curtailment_mw, excess_mw, shortage_mw)
                    VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8)
                """

                for t in 1:T
                    time_slot_str = solution.time_slots[t]
                    time_slot_dt = DateTime(time_slot_str, dateformat"yyyymmdd-HHMM")
                    renewable_gen = get(solution.renewable_generation, time_slot_str, missing)

                    LibPQ.execute(cnx, demand_insert_sql, [
                        uc_result_id,
                        t,
                        time_slot_dt,
                        solution.net_demand[t],
                        renewable_gen === nothing ? missing : renewable_gen,
                        solution.curtailment[t],
                        solution.excess[t],
                        solution.shortage[t]
                    ])
                end

                LibPQ.execute(cnx, "COMMIT")
                return uc_result_id

            catch e
                LibPQ.execute(cnx, "ROLLBACK")
                rethrow(e)
            end
        end

        @info "Saved UC results for $bidding_zone on $day (id=$result_id)"
        return result_id

    catch e
        @error "Failed to save UC results: $e"
        return nothing
    end
end

"""
    load_uc_results(bidding_zone::String, day::Date; code_version::Int=4) -> Union{NamedTuple,Nothing}

Load cached UC results from database. Returns a NamedTuple compatible with the
solve_unit_commitment() return structure, or nothing if no cache exists.

Note: Generator objects are fetched fresh to ensure current data.
"""
function load_uc_results(bidding_zone::String, day::Dates.Date; code_version::Int=4)
    # 1. Load summary record
    summary_query = """
    SELECT * FROM simulations.uc_results
    WHERE bidding_zone = \$1
      AND market_date = \$2
      AND code_version = \$3
      AND status = 'OPTIMAL'
    """

    summary_df = Euphemia.sql2df_with_retry(summary_query, [bidding_zone, day, code_version])

    if isempty(summary_df)
        return nothing
    end

    uc_result_id = summary_df.id[1]

    # 2. Get fresh generators (needed for BiddingStrategy - includes current p_max, marginal_cost, etc.)
    generators = get_generators(bidding_zone, day)

    # Create generator lookup by code
    gen_by_code = Dict(gen.code => gen for gen in generators)

    # 3. Load generation data
    gen_query = """
    SELECT * FROM simulations.uc_generation
    WHERE uc_result_id = \$1
    ORDER BY generator_idx, period_idx
    """

    gen_df = Euphemia.sql2df_with_retry(gen_query, [uc_result_id])

    # 4. Load net demand data
    demand_query = """
    SELECT * FROM simulations.uc_net_demand
    WHERE uc_result_id = \$1
    ORDER BY period_idx
    """

    demand_df = Euphemia.sql2df_with_retry(demand_query, [uc_result_id])

    # 5. Reconstruct matrices and vectors
    N = summary_df.num_generators[1]
    T = summary_df.num_periods[1]

    # Initialize matrices
    g = zeros(Float64, N, T)
    u = zeros(Float64, N, T)
    v = zeros(Float64, N, T)

    # Build ordered list of generators based on stored order
    unique_codes_df = Euphemia.sql2df_with_retry("""
        SELECT DISTINCT generator_code, generator_idx
        FROM simulations.uc_generation
        WHERE uc_result_id = \$1
        ORDER BY generator_idx
    """, [uc_result_id])

    ordered_generators = Generator[]
    for row in eachrow(unique_codes_df)
        code = row.generator_code
        if haskey(gen_by_code, code)
            push!(ordered_generators, gen_by_code[code])
        else
            @warn "Generator $code from cache not found in current data"
        end
    end

    # Fill matrices from generation data
    for row in eachrow(gen_df)
        i = row.generator_idx
        t = row.period_idx
        if i <= N && t <= T
            g[i, t] = row.generation_mw
            u[i, t] = Float64(row.commitment)
            v[i, t] = Float64(row.startup)
        end
    end

    # Reconstruct time_slots, net_demand, curtailment, excess, and shortage
    time_slots = String[]
    net_demand = Float64[]
    curtailment = Float64[]
    excess = Float64[]
    shortage = Float64[]
    renewable_generation = Dict{String,Float64}()

    for row in eachrow(demand_df)
        time_slot = Dates.format(row.time_slot_utc, dateformat"yyyymmdd-HHMM")
        push!(time_slots, time_slot)
        push!(net_demand, row.net_demand_mw)
        # Read curtailment (default to 0 for backwards compatibility with old cache entries)
        curtail_val = hasproperty(row, :curtailment_mw) && !ismissing(row.curtailment_mw) ? row.curtailment_mw : 0.0
        push!(curtailment, curtail_val)
        # Read excess (default to 0 for backwards compatibility with old cache entries)
        excess_val = hasproperty(row, :excess_mw) && !ismissing(row.excess_mw) ? row.excess_mw : 0.0
        push!(excess, excess_val)
        # Read shortage (default to 0 for backwards compatibility with old cache entries)
        shortage_val = hasproperty(row, :shortage_mw) && !ismissing(row.shortage_mw) ? row.shortage_mw : 0.0
        push!(shortage, shortage_val)
        if !ismissing(row.renewable_generation_mw)
            renewable_generation[time_slot] = row.renewable_generation_mw
        end
    end

    # Read curtailment, excess, and shortage costs from summary (default to 0 for backwards compatibility)
    curtailment_cost = hasproperty(summary_df, :curtailment_cost) && !ismissing(summary_df.curtailment_cost[1]) ? summary_df.curtailment_cost[1] : 0.0
    excess_cost = hasproperty(summary_df, :excess_cost) && !ismissing(summary_df.excess_cost[1]) ? summary_df.excess_cost[1] : 0.0
    shortage_cost = hasproperty(summary_df, :shortage_cost) && !ismissing(summary_df.shortage_cost[1]) ? summary_df.shortage_cost[1] : 0.0

    # Reconstruct cost breakdown (partial - some fields not stored)
    cost_breakdown = (
        production_cost=summary_df.production_cost[1],
        startup_cost=summary_df.startup_cost[1],
        noload_cost=summary_df.noload_cost[1],
        startup_counts=Dict{Symbol,Int}(
            :hot => summary_df.hot_startups[1],
            :warm => summary_df.warm_startups[1],
            :cold => summary_df.cold_startups[1]
        ),
        # Placeholder fields (not stored in cache, can be recalculated if needed)
        generator_costs=Dict{String,Float64}(),
        fuel_type_costs=Dict{Symbol,Float64}(),
        period_costs=Float64[],
        total_capacity=sum(gen.p_max for gen in ordered_generators; init=0.0),
        avg_committed_capacity=0.0,
        avg_generation=isempty(net_demand) ? 0.0 : sum(net_demand) / length(net_demand),
        capacity_utilization=0.0,
        commitment_utilization=0.0,
        startup_costs_by_type=Dict{Symbol,Float64}(:hot => 0.0, :warm => 0.0, :cold => 0.0)
    )

    @info "Loaded UC results from cache for $bidding_zone on $day ($(length(ordered_generators)) generators, $T periods)"

    # Reconstruct load_values from net_demand + renewable_generation - curtailment - excess + shortage
    # Note: net_demand = load - renewables + curtailment + excess - shortage, so load = net_demand + renewables - curtailment - excess + shortage
    load_values = Float64[]
    renewable_values = Float64[]
    for (i, slot) in enumerate(time_slots)
        renewable_val = get(renewable_generation, slot, 0.0)
        push!(renewable_values, renewable_val)
        push!(load_values, net_demand[i] + renewable_val - curtailment[i] - excess[i] + shortage[i])
    end

    return (
        status=OPTIMAL,  # Only OPTIMAL results are cached
        solver=summary_df.solver[1],
        generators=ordered_generators,
        time_slots=time_slots,
        resolution_minutes=summary_df.resolution_minutes[1],
        net_demand=net_demand,
        load_values=load_values,
        renewable_values=renewable_values,
        renewable_generation=renewable_generation,
        curtailment=curtailment,
        curtailment_cost=curtailment_cost,
        excess=excess,
        excess_cost=excess_cost,
        shortage=shortage,
        shortage_cost=shortage_cost,
        g=g,
        u=u,
        v=v,
        total_cost=summary_df.total_cost[1],
        cost_breakdown=cost_breakdown,
        initial_conditions=nothing,  # Not stored, can be re-fetched if needed
        from_cache=true  # Indicator that this is a cached result
    )
end

