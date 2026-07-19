# model.jl — solve_unit_commitment — builds and solves the UC MILP (commitment, ramps, up/down-time, curtailment/excess/shortage) with solver tuning and IIS infeasibility diagnosis.
# Included by ../UnitCommitment.jl inside `module Euphemia` (definition order preserved).

function solve_unit_commitment(bidding_zone::String, day::Dates.Date;
                               optimizer::String="auto",
                               use_initial_conditions::Bool=true,
                               mip_gap::Float64=0.01,
                               time_limit::Float64=600.0,
                               use_cache::Bool=true,
                               force_rerun::Bool=false,
                               curtailment_penalty::Float64=1.0,
                               excess_penalty::Float64=10000.0,
                               shortage_penalty::Float64=10000.0,
                               use_inferred_params::Bool=true,
                               net_import_by_timeslot::Union{Dict{String,Float64}, Nothing}=nothing)

    # Check cache first (unless disabled or force_rerun)
    if use_cache && !force_rerun
        cached = load_uc_results(bidding_zone, day)
        if cached !== nothing
            println("Using cached UC results for $bidding_zone on $day")
            return cached
        end
    end

    timing_start = time()

    # Select optimizer using shared solver selection
    optimizer_func, solver_name = select_solver(optimizer)
    model = Model(optimizer_func)
    set_silent(model)

    # Solver tuning parameters (solver-agnostic via MOI)
    # MIP gap: Accept solution within X% of optimal (default 1%)
    # Time limit: Maximum solve time in seconds (default 600s = 10 min)
    set_optimizer_attribute(model, MOI.RelativeGapTolerance(), mip_gap)
    set_optimizer_attribute(model, MOI.TimeLimitSec(), time_limit)

    # PERFORMANCE NOTE (Gurobi): Avoid querying model attributes (num_constraints,
    # lower_bound, etc.) while building the model. Gurobi buffers modifications and
    # calls GRBupdatemodel on any query, causing O(n²) behavior in loops.
    # Pattern to avoid: for i in 1:N; @constraint(...); println(num_constraints(model)); end
    # Our code follows the correct pattern: build all constraints, then optimize, then query.

    # Get data from the database
    data_fetch_start = time()
    if use_inferred_params
        # Use inferred parameters from historical data (cached if available)
        # This provides plant-specific ramp rates, p_min, and uptime/downtime
        generators = get_generators_with_inferred_params(bidding_zone, day)
    else
        # Use default fuel-type parameters only
        generators = get_generators(bidding_zone, day)
    end
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

    # Store raw load and renewable values for each time period
    # These are needed for the curtailment formulation
    load_values = Float64[]
    renewable_values = Float64[]
    for slot in target_time_slots
        push!(load_values, get(load_by_time, slot, 0.0))
        push!(renewable_values, get(renewable_by_time, slot, 0.0))
    end

    # Adjust load for expected net imports from interconnections (iterative UC-MPCC)
    # Positive net_import = zone imports power → reduces generation needed
    # Negative net_import = zone exports power → increases generation needed
    if net_import_by_timeslot !== nothing
        for (t, slot) in enumerate(target_time_slots)
            net_import = get(net_import_by_timeslot, slot, 0.0)
            load_values[t] = load_values[t] - net_import
        end
        total_adjustment = sum(values(net_import_by_timeslot))
        if abs(total_adjustment) > 0.1
            println("  Net import adjustment: $(round(total_adjustment, digits=1)) MWh total")
        end
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

    # Renewable curtailment variable (allows spilling excess renewable generation)
    # This resolves infeasibility when thermal P_min constraints exceed net demand
    @variable(model, 0 <= curtailment[t=1:T] <= renewable_values[t])

    # Excess generation variable (allows thermal generation to exceed demand)
    # This handles feasibility when sum(P_min) > load - renewables + curtailment
    # High penalty ensures it's only used as last resort
    @variable(model, excess[t=1:T] >= 0)

    # Shortage variable (allows load shedding when capacity is insufficient)
    # This handles feasibility when total P_max < net demand (capacity shortage)
    # High penalty ensures it's only used as last resort
    @variable(model, shortage[t=1:T] >= 0)

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
    # Note: Flexible resources (hydro, batteries, storage) should not have min_load_factor applied
    # as they can operate at any output level including 0 MW
    for (i, gen) in enumerate(generators)
        params = fuel_params[i]

        if gen.fuel_type in FLEXIBLE_FUEL_TYPES
            # Flexible resources: use generator's p_min directly (typically 0)
            min_gen = gen.p_min
        else
            # Thermal resources: apply fuel-type minimum load factor
            min_gen = max(gen.p_min, params.min_load_factor * gen.p_max)
        end
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
    # For periods t >= max(T_SU), the standard constraint applies
    # For earlier periods (t < max(T_SU)), we still need to define u_SU properly
    for i in 1:N
        max_startup = maximum(T_SU[(i, θ)] for θ in Θ)

        # Standard constraint for later periods
        for t in max_startup:T
            @constraint(model,
                u_SU[i, t] == sum(sum(v_θ[i, θ, τ] for τ in max(1, t - T_SU[(i, θ)] + 1):t) for θ in Θ)
            )
        end

        # For early periods (t < max_startup), the constraint needs to consider
        # that startups at τ will keep the unit in startup mode for T_SU periods
        # The formula is the same, but we need to explicitly add it for all t in 1:min(max_startup-1, T)
        for t in 1:min(max_startup - 1, T)
            @constraint(model,
                u_SU[i, t] == sum(sum(v_θ[i, θ, τ] for τ in max(1, t - T_SU[(i, θ)] + 1):t) for θ in Θ)
            )
        end
    end

    # startup operation profile depending on shutdown duration. TODO: ASK PROF (p.213) Έχει T_SD και με θ και χωρίς
    @constraint(model, [i in 1:N, t in 1:T-T_SD[i]+1],
        u_SD[i, t] == sum(z[i, τ] for τ in t:t+T_SD[i]-1)
    ) # TODO: Ensure it's u_SD and not u_SU. Book writes u_SU. Copilot claims it's u_SD. Typo?

    # production constraint for startup operation profile
    # Same fix: apply for all periods, not just t >= max_startup
    for i in 1:N
        max_startup = maximum(T_SU[(i, θ)] for θ in Θ)

        # Apply constraint for all periods
        for t in 1:T
            @constraint(model,
                g_SU[i, t] == sum(sum(P_SU[i, θ, t-τ+1] * v_θ[i, θ, τ] for τ in max(1, t - T_SU[(i, θ)] + 1):t) for θ in Θ)
            )
        end
    end

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

    # Supply must equal net Demand (with slack variables for feasibility)
    # - Curtailment: spill excess renewable generation (bounded by renewable availability)
    # - Excess: absorb thermal overgeneration when sum(P_min) > net demand (high penalty)
    # - Shortage: load shedding when total P_max < net demand (capacity shortage, high penalty)
    # Formulation: Generation + Shortage = Load - Renewables + Curtailment + Excess
    @constraint(model, [t in 1:T],
        sum(g[i, t] for i in 1:N) + shortage[t] == load_values[t] - renewable_values[t] + curtailment[t] + excess[t])

    # ==== Objective Function ====
    # Total cost = Production + Startup + No-load + Curtailment + Excess + Shortage penalties
    @objective(
        model,
        Min,
        # 1. Production costs (variable cost based on marginal cost × generation)
        sum(generators[i].marginal_cost * g[i, t] for i in 1:N, t in 1:T)
        # 2. Startup costs (temperature-dependent: hot < warm < cold)
        + sum(C_SU[(i, θ)] * v_θ[i, θ, t] for i in 1:N, θ in Θ, t in 1:T)
        # 3. No-load costs (fixed cost when committed)
        + sum(C_NL[i] * u[i, t] for i in 1:N, t in 1:T)
        # 4. Curtailment costs (penalty for spilling renewable generation)
        + curtailment_penalty * sum(curtailment[t] for t in 1:T)
        # 5. Excess generation costs (high penalty for thermal oversupply)
        + excess_penalty * sum(excess[t] for t in 1:T)
        # 6. Shortage costs (high penalty for load shedding due to capacity shortage)
        + shortage_penalty * sum(shortage[t] for t in 1:T)
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

        # Attempt IIS analysis if model is infeasible (Gurobi only)
        if (status == INFEASIBLE || status == INFEASIBLE_OR_UNBOUNDED) && solver_name == "Gurobi"
            try
                @info "Computing IIS (Irreducible Infeasible Subsystem)..."
                compute_conflict!(model)

                # Count constraints in conflict
                iis_constraints = []
                for (F, S) in list_of_constraint_types(model)
                    for con in all_constraints(model, F, S)
                        conflict_status = MOI.get(model, MOI.ConstraintConflictStatus(), con)
                        if conflict_status == MOI.IN_CONFLICT
                            push!(iis_constraints, (F, S, con))
                        end
                    end
                end

                @info "IIS analysis complete: $(length(iis_constraints)) constraints in conflict"

                # Print first few conflicting constraints
                for (i, (F, S, con)) in enumerate(iis_constraints)
                    if i <= 20  # Limit output
                        println("  IIS[$i]: $con")
                    end
                end
                if length(iis_constraints) > 20
                    println("  ... and $(length(iis_constraints) - 20) more")
                end
            catch e
                @warn "IIS analysis failed: $e"
            end
        end

        return (status=status,)
    end
    @assert primal_status(model) == FEASIBLE_POINT

    # Post-processing
    postprocess_start = time()

    # Extract curtailment values
    curtailment_values = value.(curtailment)
    total_curtailment = sum(curtailment_values)
    curtailment_cost_value = curtailment_penalty * total_curtailment

    # Extract excess generation values
    excess_values = value.(excess)
    total_excess = sum(excess_values)
    excess_cost_value = excess_penalty * total_excess

    # Extract shortage (load shedding) values
    shortage_values = value.(shortage)
    total_shortage = sum(shortage_values)
    shortage_cost_value = shortage_penalty * total_shortage

    # Calculate net demand (actual, after curtailment, excess, and shortage decisions)
    # Balance: Generation + Shortage = Load - Renewables + Curtailment + Excess
    # So effective demand = Load - Renewables + Curtailment + Excess - Shortage
    net_demand = [load_values[t] - renewable_values[t] + curtailment_values[t] + excess_values[t] - shortage_values[t] for t in 1:T]

    # Log curtailment if any (convert MW-periods to MWh)
    if total_curtailment > 0.1
        curtailment_mwh = total_curtailment * period_hours
        @info "Renewable curtailment applied" energy_mwh=round(curtailment_mwh, digits=1) cost_eur=round(curtailment_cost_value, digits=2) max_mw=round(maximum(curtailment_values), digits=1) periods_with_curtailment=count(x -> x > 0.1, curtailment_values)
    end

    # Log excess generation if any (indicates structural oversupply)
    if total_excess > 0.1
        excess_mwh = total_excess * period_hours
        @warn "Excess generation required (structural oversupply)" energy_mwh=round(excess_mwh, digits=1) cost_eur=round(excess_cost_value, digits=2) max_mw=round(maximum(excess_values), digits=1) periods_with_excess=count(x -> x > 0.1, excess_values)
    end

    # Log shortage (load shedding) if any (indicates capacity shortage)
    if total_shortage > 0.1
        shortage_mwh = total_shortage * period_hours
        @warn "Load shedding required (capacity shortage)" energy_mwh=round(shortage_mwh, digits=1) cost_eur=round(shortage_cost_value, digits=2) max_mw=round(maximum(shortage_values), digits=1) periods_with_shortage=count(x -> x > 0.1, shortage_values)
    end

    # Calculate detailed cost breakdown (including startup and no-load costs)
    cost_breakdown = calculate_cost_breakdown(
        generators, value.(g), value.(u), value.(v_θ), Θ, C_SU, C_NL, T, N
    )
    postprocess_time = time() - postprocess_start

    total_time = time() - timing_start

    # Log detailed timing information
    @info "Unit commitment completed" bidding_zone = bidding_zone status = status data_fetch_time = format_time(data_fetch_time) setup_time = format_time(setup_time) solve_time = format_time(solve_time) postprocess_time = format_time(postprocess_time) total_time = format_time(total_time)

    solution = (
        status=status,
        solver=solver_name,
        generators=generators,
        time_slots=target_time_slots,
        resolution_minutes=resolution_minutes,
        net_demand=net_demand,
        load_values=load_values,
        renewable_values=renewable_values,
        renewable_generation=renewable_by_time,
        curtailment=curtailment_values,
        curtailment_cost=curtailment_cost_value,
        excess=excess_values,
        excess_cost=excess_cost_value,
        shortage=shortage_values,
        shortage_cost=shortage_cost_value,
        g=value.(g),
        u=value.(u),
        v=value.(v),  # startup decisions
        total_cost=objective_value(model),
        cost_breakdown=cost_breakdown,
        initial_conditions=initial_conditions,
    )

    # Save to cache if caching is enabled
    if use_cache
        save_uc_results(solution, bidding_zone, day)
    end

    return solution
end

