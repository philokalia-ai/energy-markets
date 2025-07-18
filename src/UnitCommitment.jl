using CSV, DataFrames, JuMP, HiGHS, Gurobi, Dates
# TODO: Include Actual Generation Per Production Unit for Previous Day for initial conditions?

function solve_unit_commitment(bidding_zone::String, day::Dates.Date)

    # TODO: choose optimizer
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    # Get data from the database
    generators = get_generators(day)
    loads = get_loads(bidding_zone, day)
    renewables = get_generation_forecast_for_wind_and_solar(bidding_zone, day)

    # Check if we have data
    if isempty(generators)
        error("No generators found for $bidding_zone on $day")
    end
    if isempty(loads)
        error("No load data found for $bidding_zone on $day")
    end

    # Validate resolution consistency
    if !isempty(loads) && !isempty(renewables)
        load_resolution = loads[1].resolution_code
        renewable_resolutions = unique([r.resolution_code for r in renewables])

        if length(renewable_resolutions) > 1
            @warn "Multiple resolution codes found in renewables data: $renewable_resolutions"
        end

        if !isempty(renewable_resolutions) && renewable_resolutions[1] != load_resolution
            @warn "Resolution mismatch: Loads ($load_resolution min) vs Renewables ($(renewable_resolutions[1]) min)"
        end

        println("Using resolution: $load_resolution minutes")
    end

    # Create time mapping from loads (assuming loads define our time periods)
    time_slots = [load.timeslot for load in loads]
    T = length(time_slots)
    N = length(generators)

    println("Planning for $T time periods with $N generators")

    # Validate time slot consistency
    if !isempty(renewables)
        renewable_time_slots = unique([r.date_time for r in renewables])
        missing_in_renewables = setdiff(time_slots, renewable_time_slots)
        extra_in_renewables = setdiff(renewable_time_slots, time_slots)

        if !isempty(missing_in_renewables)
            @warn "Missing renewable data for time slots: $missing_in_renewables"
        end
        if !isempty(extra_in_renewables)
            @warn "Extra renewable data for time slots not in load data: $extra_in_renewables"
        end
    end

    # Create renewable generation lookup by timeslot
    renewable_by_time = Dict{String,Float64}()
    for renewable in renewables
        # renewable.date_time is already formatted as string in the struct
        timeslot = renewable.date_time
        if haskey(renewable_by_time, timeslot)
            renewable_by_time[timeslot] += renewable.aggregated_generation_forecast
        else
            renewable_by_time[timeslot] = renewable.aggregated_generation_forecast
        end
    end

    # Calculate net demand (load - renewables) for each time period
    net_demand = Float64[]
    for (t, load) in enumerate(loads)
        renewable_gen = get(renewable_by_time, load.timeslot, 0.0)
        push!(net_demand, max(0.0, load.value - renewable_gen))  # Ensure non-negative
    end

    # TODO: initial conditions

    # uptime & downtime
    UT = 2
    DT = 4

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

    # Startup/shutdown time parameters (simplified for now)
    T_SU = Dict{Tuple{Int,Symbol},Int}()  # startup time by generator and temperature
    T_SD = Dict{Int,Int}()  # shutdown time by generator - independent of temperature stage

    # Initialize with default values (1 period for now)
    for i in 1:N, θ in Θ
        T_SU[(i, θ)] = 1  # Default 1 period startup time
    end
    for i in 1:N
        T_SD[i] = 1  # Default 1 period shutdown time
    end

    # Ramp rate parameters (30% of capacity per period as default)
    ramp_up = [0.3 * generators[i].p_max for i in 1:N]  # ramp up rate
    ramp_down = [0.3 * generators[i].p_max for i in 1:N]  # ramp down rate
    M = 10000.0  # Big M parameter

    # ==== Model Constraints ====

    # generation of commited units must be within limits at all times
    @constraint(model, [i = 1:N, t = 1:T], g[i, t] <= generators[i].p_max * u[i, t])
    @constraint(model, [i = 1:N, t = 1:T], g[i, t] >= generators[i].p_min * u[i, t])

    # link commitment, startup, and shutdown
    @constraint(model, [i in 1:N, t in 2:T], u[i, t] == u[i, t-1] + v[i, t] - z[i, t])

    # startup & shutdown can't happen simultaneously
    @constraint(model, [i = 1:N, t = 1:T], v[i, t] + z[i, t] <= 1)

    # minimum uptime: if there was a startup in the last UT periods, unit must be on
    @constraint(model, [i = 1:N, t = UT:T],
        sum(v[i, τ] for τ in t-UT+1:t) <= u[i, t])

    # minimum downtime: if there was a shutdown in the last DT periods, unit must be off
    @constraint(model, [i = 1:N, t = DT:T],
        sum(z[i, τ] for τ in t-DT+1:t) <= 1 - u[i, t])

    # startup can happen only on a single given temperature stage
    @constraint(model, [i = 1:N, t = 1:T],
        v[i, t] == sum(v_θ[i, θ, t] for θ in Θ))

    # TODO: Add time constraint of startup at given temperature stage based on downtime
    # This would require tracking how long each unit has been offline 
    # TODO: mistake in book, ask prof
    # @constraint(model, [i = 1:N, θ in Θ, t = TA:TB],
    #     v_θ[i, θ, t] <= sum(z[i, τ] for τ in t-TA+1:t-TB))

    ### 
    ### startup / shutdown production profile (ramp constraints)
    ###

    # unit can be one of three stages: startup, dispatch ready or at shutdown
    @constraint(model, [i in 1:N, t in 1:T],
        u[i, t] == u_SU[i, t] + u_DISP[i, t] + u_SD[i, t])

    # startup operation profile duration depending on startup temperature stage
    @constraint(model, [i in N, t in maximum(T_SU[i, θ] for θ in Θ):T],
        u_SU[i, t] == sum(sum(v[i, θ, τ] for τ in max(1, t - T_SU[i, θ] + 1):t) for θ in Θ)
    )

    # startup operation profile depending on shutdown duration. TODO: ASK PROF (p.213) Έχει T_SD και με θ και χωρίς
    @constraint(model, [i in N, t in 1:T-T_SD[i]+1],
        u_SU[i, t] == sum(z[i, τ] for τ in t:(t:T_SD[i]-1))
    )

    # production constraint for startup operation profile
    @constraint(model, [i in N, t in maximum(T_SU[i, θ] for θ in Θ):T],
        g_SU[i, t] == sum(sum(P_SU[i, θ, t-τ+1] * v[i, θ, τ] for τ in max(1, t - T_SU[i, θ] + 1):t) for θ in Θ)
    )

    # production constraint for shutdown operation profile
    @constraint(model, [i in N, t in 1:T-T_SD[i, θ] for θ in Θ],
        #TODO: Book doesn't include θ
        g_SD[i, t] == sum(
            sum(P_SD[i, t-τ+1] * z[i, τ] for τ in t+1:t+T_SD[i, θ]) for θ in Θ)
    )

    # production constraints for dispatch ready operation profile
    @constraint(model, [i in N, t in 1:T],
        g[i, t] >= g_SU[i, t] + g_SD[i, t] + generators[i].p_min * u_DISP[i, t]
    )

    @constraint(model, [i in N, t in 1:T],
        g[i, t] <= g_SU[i, t] + g_SD[i, t] + generators[i].p_max * u_DISP[i, t]
    )

    # ramp constraints considering startup & shutdown profiles (R: Ramp Constraint)
    # TODO: Add proper ramp rate parameters to Generator struct
    @constraint(model, [i in N, t in 2:T], #TODO: ask about M parameter
        g[i, t] - g[i, t-1] <= ramp_up[i] + M * u_SU[i, t]
    )

    @constraint(model, [i in N, t in 2:T],
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

    optimize!(model)
    status = termination_status(model)
    if status != OPTIMAL
        return (status=status,)
    end
    @assert primal_status(model) == FEASIBLE_POINT

    return (
        status=status,
        generators=generators,
        time_slots=time_slots,
        net_demand=net_demand,
        renewable_generation=renewable_by_time,
        g=value.(g),
        u=value.(u),
        total_cost=objective_value(model),
    )
end

# Example usage function (can be called from tests)
function test_unit_commitment()
    bidding_zone = "GR"
    day = Date("2018-06-24")

    println("Solving unit commitment for $bidding_zone on $day")
    solution = solve_unit_commitment(bidding_zone, day)

    if solution.status == OPTIMAL
        println("Solution found!")
        println("Total cost: €", round(solution.total_cost, digits=2))
        println("Number of generators: ", length(solution.generators))
        println("Number of time periods: ", length(solution.time_slots))
        println("Dispatch of Generators: ", solution.g, " MW")
        println("Commitment of Generators: ", solution.u)

        # Print some sample results
        for t in 1:min(5, length(solution.time_slots))
            println("Time $(solution.time_slots[t]): Net demand = $(solution.net_demand[t]) MW")
        end
    else
        println("Optimization failed with status: ", solution.status)
    end

    return solution
end
