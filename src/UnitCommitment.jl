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

function calculate_cost_breakdown(generators, g, u, v_θ, Θ, C_SU, C_NL, T, N)
    # Calculate per-generator costs (production only)
    generator_production_costs = Dict{String,Float64}()
    fuel_type_costs = Dict{Symbol,Float64}()
    period_costs = Float64[]  # Cost per time period (may be 15min, 30min, or 60min)

    # Production costs by generator
    for i in 1:N
        gen_total_cost = 0.0
        for t in 1:T
            cost = generators[i].marginal_cost * g[i, t]
            gen_total_cost += cost
        end
        generator_production_costs[generators[i].name] = gen_total_cost

        # Aggregate by fuel type
        fuel_type = generators[i].fuel_type
        if haskey(fuel_type_costs, fuel_type)
            fuel_type_costs[fuel_type] += gen_total_cost
        else
            fuel_type_costs[fuel_type] = gen_total_cost
        end
    end

    # Calculate total production cost
    total_production_cost = sum(values(generator_production_costs))

    # Calculate startup costs by temperature stage
    startup_costs = Dict{Symbol,Float64}(:hot => 0.0, :warm => 0.0, :cold => 0.0)
    for i in 1:N, θ in Θ, t in 1:T
        startup_costs[θ] += C_SU[(i, θ)] * v_θ[i, θ, t]
    end
    total_startup_cost = sum(values(startup_costs))

    # Calculate no-load costs
    total_noload_cost = sum(C_NL[i] * u[i, t] for i in 1:N, t in 1:T)

    # Calculate per-period total costs (production + startup + no-load)
    for t in 1:T
        production = sum(generators[i].marginal_cost * g[i, t] for i in 1:N)
        startup = sum(C_SU[(i, θ)] * v_θ[i, θ, t] for i in 1:N, θ in Θ)
        noload = sum(C_NL[i] * u[i, t] for i in 1:N)
        push!(period_costs, production + startup + noload)
    end

    # Calculate utilization statistics
    total_capacity = sum(gen.p_max for gen in generators)
    committed_capacity = sum(generators[i].p_max * sum(u[i, t] for t in 1:T) for i in 1:N) / T
    actual_generation = sum(g[i, t] for i in 1:N, t in 1:T) / T

    # Count startups by temperature
    startup_counts = Dict{Symbol,Int}(:hot => 0, :warm => 0, :cold => 0)
    for i in 1:N, θ in Θ, t in 1:T
        if v_θ[i, θ, t] > 0.5  # Binary variable
            startup_counts[θ] += 1
        end
    end

    return (
        generator_costs=generator_production_costs,
        fuel_type_costs=fuel_type_costs,
        period_costs=period_costs,
        total_capacity=total_capacity,
        avg_committed_capacity=committed_capacity,
        avg_generation=actual_generation,
        capacity_utilization=actual_generation / total_capacity,
        commitment_utilization=committed_capacity / total_capacity,
        # New cost breakdown fields
        production_cost=total_production_cost,
        startup_cost=total_startup_cost,
        startup_costs_by_type=startup_costs,
        startup_counts=startup_counts,
        noload_cost=total_noload_cost
    )
end

function print_cost_report(solution, day; resolution_minutes::Int=60)
    println("\n" * "="^60)
    println("UNIT COMMITMENT COST REPORT - $day")
    println("="^60)

    total_cost = solution.total_cost
    breakdown = solution.cost_breakdown
    num_periods = length(solution.time_slots)
    periods_per_hour = 60 / resolution_minutes

    println("OVERALL ECONOMICS")
    println("   Total cost: $(round(total_cost, digits=2)) EUR ($(round(total_cost/1e6, digits=2))M EUR)")
    println("   Average cost per period ($(resolution_minutes)min): $(round(total_cost/num_periods, digits=2)) EUR")
    println("   Cost per MWh generated: $(round(total_cost/sum(breakdown.avg_generation * num_periods / periods_per_hour), digits=2)) EUR")

    # Cost breakdown by component
    println("\nCOST COMPONENTS")
    println("   Production costs: $(round(breakdown.production_cost, digits=2)) EUR ($(round(breakdown.production_cost/total_cost*100, digits=1))%)")
    println("   Startup costs:    $(round(breakdown.startup_cost, digits=2)) EUR ($(round(breakdown.startup_cost/total_cost*100, digits=1))%)")
    println("      Hot startups:  $(breakdown.startup_counts[:hot]) @ $(round(breakdown.startup_costs_by_type[:hot], digits=2)) EUR")
    println("      Warm startups: $(breakdown.startup_counts[:warm]) @ $(round(breakdown.startup_costs_by_type[:warm], digits=2)) EUR")
    println("      Cold startups: $(breakdown.startup_counts[:cold]) @ $(round(breakdown.startup_costs_by_type[:cold], digits=2)) EUR")
    println("   No-load costs:    $(round(breakdown.noload_cost, digits=2)) EUR ($(round(breakdown.noload_cost/total_cost*100, digits=1))%)")

    println("\nCAPACITY & GENERATION")
    println("   Total installed capacity: $(round(breakdown.total_capacity)) MW")
    println("   Average committed capacity: $(round(breakdown.avg_committed_capacity)) MW")
    println("   Average generation: $(round(breakdown.avg_generation)) MW")
    println("   Capacity utilization: $(round(breakdown.capacity_utilization * 100, digits=1))%")
    println("   Commitment utilization: $(round(breakdown.commitment_utilization * 100, digits=1))%")

    println("\nPRODUCTION COSTS BY FUEL TYPE")
    sorted_fuel_costs = sort(collect(breakdown.fuel_type_costs), by=x -> x[2], rev=true)
    for (fuel_type, cost) in sorted_fuel_costs
        percentage = cost / breakdown.production_cost * 100
        println("   $(fuel_type): $(round(cost, digits=2)) EUR ($(round(percentage, digits=1))%)")
    end

    println("\nTOP GENERATOR PRODUCTION COSTS")
    sorted_gen_costs = sort(collect(breakdown.generator_costs), by=x -> x[2], rev=true)
    for (i, (gen_name, cost)) in enumerate(sorted_gen_costs[1:min(5, end)])
        percentage = cost / breakdown.production_cost * 100
        println("   $i. $gen_name: $(round(cost, digits=2)) EUR ($(round(percentage, digits=1))%)")
    end

    println("\nCOST PROFILE ($(resolution_minutes)min periods)")
    period_costs = breakdown.period_costs
    min_cost = minimum(period_costs)
    max_cost = maximum(period_costs)
    avg_cost = sum(period_costs) / length(period_costs)

    println("   Peak period cost: $(round(max_cost, digits=2)) EUR (period $(argmax(period_costs)))")
    println("   Minimum period cost: $(round(min_cost, digits=2)) EUR (period $(argmin(period_costs)))")
    println("   Average period cost: $(round(avg_cost, digits=2)) EUR")
    println("   Cost variability: $(round((max_cost-min_cost)/avg_cost * 100, digits=1))%")

    println("="^60)
end

function solve_unit_commitment(bidding_zone::String, day::Dates.Date;
                               optimizer::String="auto",
                               use_initial_conditions::Bool=true)

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

    # Get initial conditions for generators (state at t=0)
    if use_initial_conditions
        initial_conditions = get_initial_conditions(generators, day; use_historical=true)
        println("Loaded initial conditions for $(length(initial_conditions)) generators")
    else
        initial_conditions = nothing
    end
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

    # Calculate conversion factor from hours to periods
    # All fuel-type parameters (startup times, uptime, downtime) are in HOURS
    # but constraints operate on PERIODS (which may be 15min, 30min, or 60min)
    periods_per_hour = 60 / resolution_minutes

    println("Planning for $T time periods with $N generators ($(resolution_minutes)min resolution, $(periods_per_hour) periods/hour)")

    # Calculate net demand (load - renewables) for each time period
    net_demand = Float64[]
    for slot in target_time_slots
        load_value = get(load_by_time, slot, 0.0)
        renewable_gen = get(renewable_by_time, slot, 0.0)
        push!(net_demand, max(0.0, load_value - renewable_gen))  # Ensure non-negative
    end

    setup_start = time()

    # ============================================================================
    # Initial Conditions Setup
    # ============================================================================
    # Extract initial conditions into arrays for constraint formulation
    u0 = zeros(Int, N)        # Initial commitment (0 or 1)
    g0 = zeros(Float64, N)    # Initial generation (MW)
    T_on0 = zeros(Int, N)     # Hours already on at t=0
    T_off0 = zeros(Int, N)    # Hours already off at t=0

    if initial_conditions !== nothing
        for (i, gen) in enumerate(generators)
            if haskey(initial_conditions, gen.code)
                ic = initial_conditions[gen.code]
                u0[i] = ic.is_on ? 1 : 0
                g0[i] = ic.output
                T_on0[i] = ic.hours_on
                T_off0[i] = ic.hours_off
            end
        end
        on_count = sum(u0)
        println("Initial state: $on_count generators ON, $(N - on_count) OFF")
    end

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
    # FuelTypeParameters stores times in HOURS - convert to PERIODS here
    T_SU = Dict{Tuple{Int,Symbol},Int}()  # startup time by generator and temperature (in periods)
    T_SD = Dict{Int,Int}()  # shutdown time by generator (in periods) - independent of temperature stage

    # Initialize with fuel-type-specific values, converting hours to periods
    for i in 1:N
        params = fuel_params[i]
        # Map temperature stages to startup times (hours → periods, minimum 1 period)
        T_SU[(i, :hot)] = max(1, ceil(Int, params.hot_startup_time * periods_per_hour))
        T_SU[(i, :warm)] = max(1, ceil(Int, params.warm_startup_time * periods_per_hour))
        T_SU[(i, :cold)] = max(1, ceil(Int, params.cold_startup_time * periods_per_hour))
        # Shutdown time is typically same as hot startup time
        T_SD[i] = max(1, ceil(Int, params.hot_startup_time * periods_per_hour))
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

    # Big M parameter - scaled to problem size for numerical stability
    # Using 2x max capacity ensures M is large enough but not excessively so
    max_p_max = maximum(gen.p_max for gen in generators)
    M = 2.0 * max_p_max

    # ==== Cost Parameters ====

    # Startup costs by generator and temperature stage (€)
    # Hot startup is cheapest, cold startup is most expensive
    # Base cost = startup_cost_multiplier * marginal_cost * p_max
    # Temperature multipliers: hot=1.0, warm=1.5, cold=2.5 (typical values from literature)
    C_SU = Dict{Tuple{Int,Symbol},Float64}()
    for i in 1:N
        params = fuel_params[i]
        gen = generators[i]
        base_startup_cost = params.startup_cost_multiplier * gen.marginal_cost * gen.p_max
        C_SU[(i, :hot)] = base_startup_cost * 1.0
        C_SU[(i, :warm)] = base_startup_cost * 1.5
        C_SU[(i, :cold)] = base_startup_cost * 2.5
    end

    # No-load costs by generator (€/period)
    # Cost incurred when unit is committed, regardless of output level
    # = no_load_cost_fraction * marginal_cost * period_hours
    # The period_hours factor converts from €/MWh-equivalent to €/period
    C_NL = Float64[]
    for i in 1:N
        params = fuel_params[i]
        gen = generators[i]
        # No-load cost per period = fraction * marginal_cost * (typical output hours equivalent)
        # Using p_min as reference: no_load_cost = fraction * marginal_cost * p_min * period_hours
        no_load_cost = params.no_load_cost_fraction * gen.marginal_cost * gen.p_min * period_hours
        push!(C_NL, no_load_cost)
    end

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
    # For t=1: link to initial condition u0
    if initial_conditions !== nothing
        @constraint(model, [i in 1:N], u[i, 1] == u0[i] + v[i, 1] - z[i, 1])
    end
    # For t >= 2: link to previous period
    @constraint(model, [i in 1:N, t in 2:T], u[i, t] == u[i, t-1] + v[i, t] - z[i, t])

    # startup & shutdown can't happen simultaneously
    @constraint(model, [i = 1:N, t = 1:T], v[i, t] + z[i, t] <= 1)

    # minimum uptime: if there was a startup in the last UT periods, unit must be on
    # Use generator's inferred value if available, otherwise fuel-type default
    # All values are in HOURS - convert to PERIODS for constraints
    # Also account for initial hours on (T_on0) - if unit was already running for some hours
    for (i, gen) in enumerate(generators)
        # Get uptime in hours, then convert to periods
        UT_hours = gen.min_uptime !== nothing ? gen.min_uptime : fuel_params[i].min_uptime
        UT = max(1, ceil(Int, UT_hours * periods_per_hour))  # Convert hours → periods

        if UT > 1  # Only add constraint if minimum uptime > 1 period
            # Standard constraint for later periods
            @constraint(model, [t = UT:T],
                sum(v[i, τ] for τ in t-UT+1:t) <= u[i, t])

            # Initial condition constraint: if unit was on but hasn't met min uptime yet,
            # it must stay on for the remaining periods
            if initial_conditions !== nothing && u0[i] == 1
                # T_on0 is in hours, convert to periods for comparison
                T_on0_periods = ceil(Int, T_on0[i] * periods_per_hour)
                remaining_uptime = max(0, UT - T_on0_periods)
                if remaining_uptime > 0
                    # Unit must stay on for the remaining uptime periods
                    for t in 1:min(remaining_uptime, T)
                        @constraint(model, u[i, t] == 1)
                    end
                end
            end
        end
    end

    # minimum downtime: if there was a shutdown in the last DT periods, unit must be off
    # Use generator's inferred value if available, otherwise fuel-type default
    # All values are in HOURS - convert to PERIODS for constraints
    # Also account for initial hours off (T_off0) - if unit was already off for some hours
    for (i, gen) in enumerate(generators)
        # Get downtime in hours, then convert to periods
        DT_hours = gen.min_downtime !== nothing ? gen.min_downtime : fuel_params[i].min_downtime
        DT = max(1, ceil(Int, DT_hours * periods_per_hour))  # Convert hours → periods

        if DT > 1  # Only add constraint if minimum downtime > 1 period
            # Standard constraint for later periods
            @constraint(model, [t = DT:T],
                sum(z[i, τ] for τ in t-DT+1:t) <= 1 - u[i, t])

            # Initial condition constraint: if unit was off but hasn't met min downtime yet,
            # it must stay off for the remaining periods
            if initial_conditions !== nothing && u0[i] == 0
                # T_off0 is in hours, convert to periods for comparison
                T_off0_periods = ceil(Int, T_off0[i] * periods_per_hour)
                remaining_downtime = max(0, DT - T_off0_periods)
                if remaining_downtime > 0
                    # Unit must stay off for the remaining downtime periods
                    for t in 1:min(remaining_downtime, T)
                        @constraint(model, u[i, t] == 0)
                    end
                end
            end
        end
    end

    # startup can happen only on a single given temperature stage
    @constraint(model, [i = 1:N, t = 1:T],
        v[i, t] == sum(v_θ[i, θ, t] for θ in Θ))

    # Temperature-dependent startup constraints based on downtime
    # FuelTypeParameters thresholds are in HOURS - convert to PERIODS
    # Hot startup: unit offline for <= warm_threshold periods
    # Warm startup: unit offline for warm_threshold < periods <= cold_threshold
    # Cold startup: unit offline for > cold_threshold periods
    for i in 1:N
        params = fuel_params[i]
        # Convert thresholds from hours to periods
        warm_thresh = max(1, ceil(Int, params.warm_threshold * periods_per_hour))
        cold_thresh = max(1, ceil(Int, params.cold_threshold * periods_per_hour))

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
    # For t=1: constrain ramp from initial generation g0
    if initial_conditions !== nothing
        @constraint(model, [i in 1:N],
            g[i, 1] - g0[i] <= ramp_up[i] + M * u_SU[i, 1]
        )
        @constraint(model, [i in 1:N],
            g0[i] - g[i, 1] <= ramp_down[i] + M * u_SD[i, 1]
        )
    end
    # For t >= 2: standard ramp constraints
    @constraint(model, [i in 1:N, t in 2:T],
        g[i, t] - g[i, t-1] <= ramp_up[i] + M * u_SU[i, t]
    )

    @constraint(model, [i in 1:N, t in 2:T],
        g[i, t-1] - g[i, t] <= ramp_down[i] + M * u_SD[i, t]
    )

    # Supply must equal net Demand (demand minus RES production) at all times
    @constraint(model, [t in 1:T], sum(g[i, t] for i in 1:N) == net_demand[t])

    # ==== Objective Function ====
    # Total cost = Production costs + Startup costs + No-load costs
    @objective(
        model,
        Min,
        # 1. Production costs (variable cost based on marginal cost × generation)
        sum(generators[i].marginal_cost * g[i, t] for i in 1:N, t in 1:T)
        # 2. Startup costs (temperature-dependent: hot < warm < cold)
        + sum(C_SU[(i, θ)] * v_θ[i, θ, t] for i in 1:N, θ in Θ, t in 1:T)
        # 3. No-load costs (fixed cost when committed)
        + sum(C_NL[i] * u[i, t] for i in 1:N, t in 1:T)
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
    # Calculate detailed cost breakdown (including startup and no-load costs)
    cost_breakdown = calculate_cost_breakdown(
        generators, value.(g), value.(u), value.(v_θ), Θ, C_SU, C_NL, T, N
    )
    postprocess_time = time() - postprocess_start

    total_time = time() - timing_start

    # Log detailed timing information
    @info "Unit commitment completed" bidding_zone = bidding_zone status = status data_fetch_time = format_time(data_fetch_time) setup_time = format_time(setup_time) solve_time = format_time(solve_time) postprocess_time = format_time(postprocess_time) total_time = format_time(total_time)

    return (
        status=status,
        solver=solver_name,
        generators=generators,
        time_slots=target_time_slots,
        resolution_minutes=resolution_minutes,
        net_demand=net_demand,
        renewable_generation=renewable_by_time,
        g=value.(g),
        u=value.(u),
        v=value.(v),  # startup decisions
        total_cost=objective_value(model),
        cost_breakdown=cost_breakdown,
        initial_conditions=initial_conditions,
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
        print_cost_report(solution, day; resolution_minutes=solution.resolution_minutes)
    else
        println("Optimization failed with status: ", solution.status)
    end

    return solution
end
