using JuMP, Dates
using .Euphemia: select_solver
using .Euphemia: disaggregate_temporal_data

"""
    format_time(seconds::Float64) -> String

Formats time in seconds to a readable format (e.g., "5m 23s", "1h 2m 15s", "45s").
"""
function format_time(seconds::Float64)
    if seconds < 60
        return "$(round(seconds, digits=1))s"
    elseif seconds < 3600  # Less than 1 hour
        minutes = floor(Int, seconds / 60)
        remaining_seconds = seconds - minutes * 60
        if remaining_seconds < 1
            return "$(minutes)m"
        else
            return "$(minutes)m $(round(remaining_seconds, digits=1))s"
        end
    else  # 1 hour or more
        hours = floor(Int, seconds / 3600)
        remaining_seconds = seconds - hours * 3600
        minutes = floor(Int, remaining_seconds / 60)
        remaining_seconds = remaining_seconds - minutes * 60

        if minutes == 0 && remaining_seconds < 1
            return "$(hours)h"
        elseif remaining_seconds < 1
            return "$(hours)h $(minutes)m"
        else
            return "$(hours)h $(minutes)m $(round(remaining_seconds, digits=1))s"
        end
    end
end

# TODO: Include Actual Generation Per Production Unit for Previous Day for initial conditions?

function calculate_cost_breakdown(generators, g, u, T, N)
    # Calculate per-generator costs
    generator_costs = Dict{String,Float64}()
    fuel_type_costs = Dict{Symbol,Float64}()
    hourly_costs = Float64[]

    for i in 1:N
        gen_total_cost = 0.0
        for t in 1:T
            cost = generators[i].marginal_cost * g[i, t]
            gen_total_cost += cost
        end
        generator_costs[generators[i].name] = gen_total_cost

        # Aggregate by fuel type
        fuel_type = generators[i].fuel_type
        if haskey(fuel_type_costs, fuel_type)
            fuel_type_costs[fuel_type] += gen_total_cost
        else
            fuel_type_costs[fuel_type] = gen_total_cost
        end
    end

    # Calculate hourly costs
    for t in 1:T
        hourly_cost = sum(generators[i].marginal_cost * g[i, t] for i in 1:N)
        push!(hourly_costs, hourly_cost)
    end

    # Calculate utilization statistics
    total_capacity = sum(gen.p_max for gen in generators)
    committed_capacity = sum(generators[i].p_max * sum(u[i, t] for t in 1:T) for i in 1:N) / T
    actual_generation = sum(g[i, t] for i in 1:N, t in 1:T) / T

    return (
        generator_costs=generator_costs,
        fuel_type_costs=fuel_type_costs,
        hourly_costs=hourly_costs,
        total_capacity=total_capacity,
        avg_committed_capacity=committed_capacity,
        avg_generation=actual_generation,
        capacity_utilization=actual_generation / total_capacity,
        commitment_utilization=committed_capacity / total_capacity
    )
end

function print_cost_report(solution, day)
    println("\n" * "="^60)
    println("UNIT COMMITMENT COST REPORT - $day")
    println("="^60)

    total_cost = solution.total_cost
    breakdown = solution.cost_breakdown

    println("📊 OVERALL ECONOMICS")
    println("   Total cost: €$(round(total_cost, digits=2)) (€$(round(total_cost/1e6, digits=2))M)")
    println("   Average hourly cost: €$(round(total_cost/length(solution.time_slots), digits=2))")
    println("   Cost per MWh generated: €$(round(total_cost/sum(breakdown.avg_generation * length(solution.time_slots)), digits=2))")

    println("\n⚡ CAPACITY & GENERATION")
    println("   Total installed capacity: $(round(breakdown.total_capacity)) MW")
    println("   Average committed capacity: $(round(breakdown.avg_committed_capacity)) MW")
    println("   Average generation: $(round(breakdown.avg_generation)) MW")
    println("   Capacity utilization: $(round(breakdown.capacity_utilization * 100, digits=1))%")
    println("   Commitment utilization: $(round(breakdown.commitment_utilization * 100, digits=1))%")

    println("\n🔥 COSTS BY FUEL TYPE")
    sorted_fuel_costs = sort(collect(breakdown.fuel_type_costs), by=x -> x[2], rev=true)
    for (fuel_type, cost) in sorted_fuel_costs
        percentage = cost / total_cost * 100
        println("   $(fuel_type): €$(round(cost, digits=2)) ($(round(percentage, digits=1))%)")
    end

    println("\n🏭 TOP GENERATOR COSTS")
    sorted_gen_costs = sort(collect(breakdown.generator_costs), by=x -> x[2], rev=true)
    for (i, (gen_name, cost)) in enumerate(sorted_gen_costs[1:min(5, end)])
        percentage = cost / total_cost * 100
        println("   $i. $gen_name: €$(round(cost, digits=2)) ($(round(percentage, digits=1))%)")
    end

    println("\n📈 HOURLY COST PROFILE")
    hourly_costs = breakdown.hourly_costs
    min_cost = minimum(hourly_costs)
    max_cost = maximum(hourly_costs)
    avg_cost = sum(hourly_costs) / length(hourly_costs)

    println("   Peak hourly cost: €$(round(max_cost, digits=2)) (hour $(argmax(hourly_costs)))")
    println("   Minimum hourly cost: €$(round(min_cost, digits=2)) (hour $(argmin(hourly_costs)))")
    println("   Average hourly cost: €$(round(avg_cost, digits=2))")
    println("   Cost variability: $(round((max_cost-min_cost)/avg_cost * 100, digits=1))%")

    println("="^60)
end

function solve_unit_commitment(bidding_zone::String, day::Dates.Date; optimizer::String="auto")

    timing_start = time()

    # Select optimizer using shared solver selection
    optimizer_func, solver_name = select_solver(optimizer)
    model = Model(optimizer_func)
    set_silent(model)

    # Get data from the database
    data_fetch_start = time()
    generators = get_generators(bidding_zone, day)
    loads = get_loads(bidding_zone, day)
    renewables = get_generation_forecast_for_wind_and_solar(bidding_zone, day)
    data_fetch_time = time() - data_fetch_start

    # Check if we have data
    if isempty(generators)
        error("No generators found for $bidding_zone on $day")
    end
    if isempty(loads)
        error("No load data found for $bidding_zone on $day")
    end

    # Disaggregate all temporal data to finest resolution using centralized utilities
    target_time_slots, load_by_time, renewable_by_time, resolution_minutes = disaggregate_temporal_data(loads, renewables)

    T = length(target_time_slots)
    N = length(generators)

    println("Planning for $T time periods with $N generators")

    # Calculate net demand (load - renewables) for each time period
    net_demand = Float64[]
    for slot in target_time_slots
        load_value = get(load_by_time, slot, 0.0)
        renewable_gen = get(renewable_by_time, slot, 0.0)
        push!(net_demand, max(0.0, load_value - renewable_gen))  # Ensure non-negative
    end

    setup_start = time()

    # TODO: initial conditions

    # Get fuel-type-specific parameters for each generator
    fuel_params = Dict{Int,FuelTypeParameters}()
    for (i, gen) in enumerate(generators)
        fuel_params[i] = get_fuel_type_parameters(gen.fuel_type)
    end

    # Display fuel-type constraints being applied
    println("\n=== Applying Fuel-Type-Specific Constraints ===")
    fuel_type_counts = Dict{Symbol,Int}()
    for gen in generators
        fuel_type_counts[gen.fuel_type] = get(fuel_type_counts, gen.fuel_type, 0) + 1
    end

    for (fuel_type, count) in fuel_type_counts
        params = get_fuel_type_parameters(fuel_type)
        println("$fuel_type ($count units): startup $(params.hot_startup_time)-$(params.cold_startup_time)h, uptime $(params.min_uptime)h, ramp $(round(params.ramp_up_rate*100, digits=1))%/h")
    end

    # temperature stages
    Θ = [:cold, :warm, :hot]

    # ==== Model Variables ====

    # production variable, must be lower than maximum
    @variable(model, 0 <= g[i=1:N, t=1:T] <= generators[i].p_max)

    # binary commitment variable 
    @variable(model, u[i=1:N, t=1:T], Bin)

    # binary startup & shutdown variables
    @variable(model, v[i=1:N, t=1:T], Bin)
    @variable(model, z[i=1:N, t=1:T], Bin)

    # binary startup at given temperature stage variable 
    @variable(model, v_θ[i=1:N, θ in Θ, t=1:T], Bin)

    # binary startup profile operation variable 
    @variable(model, u_SU[i=1:N, t=1:T], Bin)

    # binary shutdown profile operation variable 
    @variable(model, u_SD[i=1:N, t=1:T], Bin)

    # binary disposable profile operation variable 
    @variable(model, u_DISP[i=1:N, t=1:T], Bin)

    # startup and shutdown production profile variables
    @variable(model, g_SU[i=1:N, t=1:T] >= 0)  # startup generation profile
    @variable(model, g_SD[i=1:N, t=1:T] >= 0)  # shutdown generation profile

    # Startup/shutdown time parameters based on fuel type and temperature
    T_SU = Dict{Tuple{Int,Symbol},Int}()  # startup time by generator and temperature
    T_SD = Dict{Int,Int}()  # shutdown time by generator - independent of temperature stage

    # Initialize with fuel-type-specific values
    for (i, gen) in enumerate(generators)
        params = fuel_params[i]
        # Map temperature stages to startup times (in hours, converted to periods)
        T_SU[(i, :hot)] = params.hot_startup_time
        T_SU[(i, :warm)] = params.warm_startup_time
        T_SU[(i, :cold)] = params.cold_startup_time
        # Shutdown time is typically same as hot startup time
        T_SD[i] = params.hot_startup_time
    end

    # Startup production profile parameters - power output during startup phase
    P_SU = Dict{Tuple{Int,Symbol,Int},Float64}()  # startup production profile P_SU[i, θ, t]

    # Initialize startup production profiles (ramping from 0 to p_min over startup time)
    for i in 1:N, θ in Θ
        startup_time = T_SU[(i, θ)]
        for t_su in 1:startup_time
            # Linear ramp from 0 to p_min over startup time
            P_SU[(i, θ, t_su)] = generators[i].p_min * (t_su / startup_time)
        end
    end

    # Shutdown production profile parameters - power output during shutdown phase  
    P_SD = Dict{Tuple{Int,Int},Float64}()  # shutdown production profile P_SD[i, t]

    # Initialize shutdown production profiles (ramping from p_min to 0 over shutdown time)
    for i in 1:N
        shutdown_time = T_SD[i]
        # Ensure we have enough entries for the maximum possible index
        max_shutdown_periods = max(shutdown_time, T)  # Ensure we cover all possible τ-t+1 values
        for t_sd in 1:max_shutdown_periods
            if t_sd <= shutdown_time
                # Linear ramp from p_min to 0 over shutdown time
                P_SD[(i, t_sd)] = generators[i].p_min * (1 - (t_sd - 1) / shutdown_time)
            else
                # Beyond shutdown time, power is 0
                P_SD[(i, t_sd)] = 0.0
            end
        end
    end

    # Ramp rate parameters - use per-generator rates if available, otherwise fuel-type defaults
    # All rates are stored as fraction/hour, so we scale by period duration
    period_hours = resolution_minutes / 60.0
    ramp_up = Float64[]
    ramp_down = Float64[]
    for (i, gen) in enumerate(generators)
        params = fuel_params[i]
        # Use generator's inferred ramp_up if available, otherwise use fuel-type default
        # Both are fraction/hour, so multiply by p_max and period_hours to get MW/period
        if gen.ramp_up !== nothing
            push!(ramp_up, gen.ramp_up * gen.p_max * period_hours)
        else
            push!(ramp_up, params.ramp_up_rate * gen.p_max * period_hours)
        end
        # Use generator's inferred ramp_down if available, otherwise use fuel-type default
        if gen.ramp_down !== nothing
            push!(ramp_down, gen.ramp_down * gen.p_max * period_hours)
        else
            push!(ramp_down, params.ramp_down_rate * gen.p_max * period_hours)
        end
    end

    M = 10000.0  # Big M parameter

    # ==== Model Constraints ====

    # generation of commited units must be within limits at all times
    @constraint(model, [i = 1:N, t = 1:T], g[i, t] <= generators[i].p_max * u[i, t])

    # Apply fuel-type-specific minimum load constraints
    for (i, gen) in enumerate(generators)
        params = fuel_params[i]
        # Minimum generation when committed (considering fuel-type minimum load factor)
        min_gen = max(gen.p_min, params.min_load_factor * gen.p_max)
        @constraint(model, [t = 1:T], g[i, t] >= min_gen * u[i, t])
    end

    # link commitment, startup, and shutdown
    @constraint(model, [i in 1:N, t in 2:T], u[i, t] == u[i, t-1] + v[i, t] - z[i, t])

    # startup & shutdown can't happen simultaneously
    @constraint(model, [i = 1:N, t = 1:T], v[i, t] + z[i, t] <= 1)

    # minimum uptime: if there was a startup in the last UT periods, unit must be on
    # Use generator's inferred value if available, otherwise fuel-type default
    for (i, gen) in enumerate(generators)
        UT = gen.min_uptime !== nothing ? gen.min_uptime : fuel_params[i].min_uptime
        if UT > 1  # Only add constraint if minimum uptime > 1
            @constraint(model, [t = UT:T],
                sum(v[i, τ] for τ in t-UT+1:t) <= u[i, t])
        end
    end

    # minimum downtime: if there was a shutdown in the last DT periods, unit must be off
    # Use generator's inferred value if available, otherwise fuel-type default
    for (i, gen) in enumerate(generators)
        DT = gen.min_downtime !== nothing ? gen.min_downtime : fuel_params[i].min_downtime
        if DT > 1  # Only add constraint if minimum downtime > 1
            @constraint(model, [t = DT:T],
                sum(z[i, τ] for τ in t-DT+1:t) <= 1 - u[i, t])
        end
    end

    # startup can happen only on a single given temperature stage
    @constraint(model, [i = 1:N, t = 1:T],
        v[i, t] == sum(v_θ[i, θ, t] for θ in Θ))

    # Temperature-dependent startup constraints based on downtime
    # Hot startup: unit offline for <= warm_threshold periods
    # Warm startup: unit offline for warm_threshold < periods <= cold_threshold  
    # Cold startup: unit offline for > cold_threshold periods
    for (i, gen) in enumerate(generators)
        params = fuel_params[i]
        warm_thresh = params.warm_threshold
        cold_thresh = params.cold_threshold

        # Hot startup constraints (short downtime)
        for t in 2:min(warm_thresh + 1, T)
            @constraint(model, v_θ[i, :hot, t] <= 1 - sum(z[i, τ] for τ in max(1, t - warm_thresh):t-1))
        end

        # Warm startup constraints (medium downtime)
        if warm_thresh < cold_thresh
            for t in max(2, warm_thresh + 1):min(cold_thresh + 1, T)
                @constraint(model, v_θ[i, :warm, t] <= sum(z[i, τ] for τ in max(1, t - cold_thresh):max(1, t - warm_thresh - 1)))
            end
        end

        # Cold startup constraints (long downtime)
        if cold_thresh < T
            for t in cold_thresh+2:T
                @constraint(model, v_θ[i, :cold, t] <= sum(z[i, τ] for τ in max(1, t - cold_thresh - 1):t-cold_thresh))
            end
        end
    end

    ### 
    ### startup / shutdown production profile (ramp constraints)
    ###

    # unit can be one of three stages: startup, dispatch ready or at shutdown
    @constraint(model, [i in 1:N, t in 1:T],
        u[i, t] == u_SU[i, t] + u_DISP[i, t] + u_SD[i, t])

    # startup operation profile duration depending on startup temperature stage
    @constraint(model, [i in 1:N, t in maximum(T_SU[i, θ] for θ in Θ):T],
        u_SU[i, t] == sum(sum(v_θ[i, θ, τ] for τ in max(1, t - T_SU[i, θ] + 1):t) for θ in Θ)
    )

    # startup operation profile depending on shutdown duration. TODO: ASK PROF (p.213) Έχει T_SD και με θ και χωρίς
    @constraint(model, [i in 1:N, t in 1:T-T_SD[i]+1],
        u_SD[i, t] == sum(z[i, τ] for τ in t:t+T_SD[i]-1)
    ) # TODO: Ensure it's u_SD and not u_SU. Book writes u_SU. Copilot claims it's u_SD. Typo?

    # production constraint for startup operation profile
    @constraint(model, [i in 1:N, t in maximum(T_SU[i, θ] for θ in Θ):T],
        g_SU[i, t] == sum(sum(P_SU[i, θ, t-τ+1] * v_θ[i, θ, τ] for τ in max(1, t - T_SU[i, θ] + 1):t) for θ in Θ)
    )

    # production constraint for shutdown operation profile
    @constraint(model, [i in 1:N, t in 1:T-T_SD[i]],
        #T_SD independent of θ
        g_SD[i, t] == sum(P_SD[i, τ-t] * z[i, τ] for τ in t+1:t+T_SD[i])
    )

    # production constraints for dispatch ready operation profile
    @constraint(model, [i in 1:N, t in 1:T],
        g[i, t] >= g_SU[i, t] + g_SD[i, t] + generators[i].p_min * u_DISP[i, t]
    )

    @constraint(model, [i in 1:N, t in 1:T],
        g[i, t] <= g_SU[i, t] + g_SD[i, t] + generators[i].p_max * u_DISP[i, t]
    )

    # ramp constraints considering startup & shutdown profiles (R: Ramp Constraint)
    # TODO: Add proper ramp rate parameters to Generator struct
    @constraint(model, [i in 1:N, t in 2:T], #TODO: ask about M parameter
        g[i, t] - g[i, t-1] <= ramp_up[i] + M * u_SU[i, t]
    )

    @constraint(model, [i in 1:N, t in 2:T],
        g[i, t-1] - g[i, t] <= ramp_down[i] + M * u_SD[i, t]
    )

    # Supply must equal net Demand (demand minus RES production) at all times
    @constraint(model, [t in 1:T], sum(g[i, t] for i in 1:N) == net_demand[t])

    @objective(
        model,
        Min,
        # Use marginal costs from generators
        sum(generators[i].marginal_cost * g[i, t] for i in 1:N, t in 1:T)
    )

    setup_time = time() - setup_start

    # Solve the optimization problem
    solve_start = time()
    optimize!(model)
    solve_time = time() - solve_start

    status = termination_status(model)
    if status != OPTIMAL
        total_time = time() - timing_start
        @info "Optimization failed" bidding_zone = bidding_zone status = status data_fetch_time = format_time(data_fetch_time) setup_time = format_time(setup_time) solve_time = format_time(solve_time) total_time = format_time(total_time)
        return (status=status,)
    end
    @assert primal_status(model) == FEASIBLE_POINT

    # Post-processing
    postprocess_start = time()
    # Calculate detailed cost breakdown
    cost_breakdown = calculate_cost_breakdown(generators, value.(g), value.(u), T, N)
    postprocess_time = time() - postprocess_start

    total_time = time() - timing_start

    # Log detailed timing information
    @info "Unit commitment completed" bidding_zone = bidding_zone status = status data_fetch_time = format_time(data_fetch_time) setup_time = format_time(setup_time) solve_time = format_time(solve_time) postprocess_time = format_time(postprocess_time) total_time = format_time(total_time)

    return (
        status=status,
        generators=generators,
        time_slots=target_time_slots,
        net_demand=net_demand,
        renewable_generation=renewable_by_time,
        g=value.(g),
        u=value.(u),
        total_cost=objective_value(model),
        cost_breakdown=cost_breakdown,
    )
end

# Example usage function (can be called from tests)
function test_unit_commitment(
    bidding_zone="GR",
    day=Date("2018-06-24")
)

    println("Solving unit commitment for $bidding_zone on $day")
    solution = solve_unit_commitment(bidding_zone, day)

    if solution.status == OPTIMAL
        println("Solution found!")
        print_cost_report(solution, day)
    else
        println("Optimization failed with status: ", solution.status)
    end

    return solution
end
