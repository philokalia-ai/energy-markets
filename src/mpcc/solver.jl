# solver.jl — solve_mpcc_market_clearing — the complementarity clearing solve with its robustness retry ladder — plus _solve_mpcc_by_period (period decomposition for HiGHS).
# Included by ../MPCC.jl inside `module MPCC` (definition order preserved).


"""
    _reconstruct_component_prices(nodes, periods, zone_pairs, flow_values, flow_caps,
                                  orders_by_node_time, simple_orders, order_ids,
                                  stepwise_acceptance_values, price_limits, solver_prices)

Competitive price reconstruction, extracted from `solve_mpcc_market_clearing`
so it can run — and be tested — without a live solver.

This is the arithmetic that decides every published price. The complementarity
constraints only BRACKET the price, and the welfare objective does not involve
`market_price`, so the solver's value is an arbitrary point of that interval;
this function recomputes it from the acceptance pattern. It takes flow VALUES
(already extracted with `value(...)`) rather than JuMP variables, so it touches
no model object.

Returns `(prices, fallback_periods)`: a fresh price dict, plus the list of
periods whose rent-sign validation failed and therefore keep the solver's raw
prices verbatim (observable provenance — cv25).
"""
function _reconstruct_component_prices(nodes::Vector{String}, periods::Vector{String},
    zone_pairs, flow_values::Dict{Tuple{Tuple{String,String},String},Float64},
    flow_caps, orders_by_node_time, simple_orders, order_ids,
    stepwise_acceptance_values::Dict{String,Float64}, price_limits,
    solver_prices::Dict{String,Dict{String,Float64}})

    prices = Dict{String,Dict{String,Float64}}(z => copy(solver_prices[z]) for z in nodes)
    fallback_periods = String[]
    fallback_cells = 0
    inconsistent_brackets = 0
    is_multi_zone = !isempty(zone_pairs)
    # Acceptance is classified in MW, not as a fraction of the order (bug sweep
    # 2026-08-24): a relative 1e-4 let up to 6 MW of a 60 GW price-taker block be
    # curtailed and still read as "fully accepted", so a genuine scarcity hour
    # (model price = cap) was published at the top accepted supply price.
    # Solver bound/feasibility noise is ~1e-6 x Q (<= 0.06 MW at 60 GW).
    quantity_atol = 0.5
    # A flow within this many MW of its ATC limit counts as binding.
    # Must sit just above the solver's absolute feasibility
    # tolerance (~1e-6): anything larger decouples links whose flow
    # is strictly interior, where the model forced prices equal.
    flow_atol = 1e-3
    # Slack for the rent-sign checks (€/MWh), covering float noise
    # without masking economically meaningful sign violations
    price_atol = 0.01
    parent = Dict{String,String}()
    function find_root(z::String)
        while parent[z] != z
            z = parent[z]
        end
        return z
    end
    for time_period in periods
        # Union-find over uncongested links → coupled components
        for z in nodes
            parent[z] = z
        end
        if is_multi_zone
            for pair in zone_pairs
                fv = flow_values[(pair, time_period)]
                fwd_cap, bwd_cap = flow_caps[(pair, time_period)]
                interior = fv < fwd_cap - flow_atol && fv > -bwd_cap + flow_atol
                interior || continue
                ra, rb = find_root(pair[1]), find_root(pair[2])
                ra == rb || (parent[ra] = rb)
            end
        end
        components = Dict{String,Vector{String}}()
        for z in nodes
            push!(get!(components, find_root(z), String[]), z)
        end

        # Per component: the bracket [lo, hi] the accepted/rejected orders
        # leave open, the point estimate, and whether a marginal (partially
        # accepted) order PINS it.
        comp_lo = Dict{String,Float64}(); comp_hi = Dict{String,Float64}()
        comp_price = Dict{String,Float64}(); comp_pinned = Dict{String,Bool}()
        for (root, comp_zones) in components
            order_idxs = Int[]
            for z in comp_zones
                append!(order_idxs, get(orders_by_node_time, (z, time_period), Int[]))
            end
            if isempty(order_idxs)
                # Orderless component (data gap): nothing economic
                # constrains the price — pin it to the floor so the
                # output is at least deterministic and recognizable.
                comp_lo[root] = comp_hi[root] = comp_price[root] = price_limits[1]
                comp_pinned[root] = true
                continue
            end
            lo = price_limits[1]
            hi = price_limits[2]
            marginal_price = nothing
            for i in order_idxs
                o = simple_orders[i]
                q = o.quantity
                # A zero-size order cannot constrain the price (its acceptance
                # is a free column the solver parks anywhere).
                q <= quantity_atol && continue
                a = stepwise_acceptance_values[order_ids[i]]
                accepted_mw = a * q
                rejected_mw = (1 - a) * q
                if accepted_mw > quantity_atol && rejected_mw > quantity_atol
                    marginal_price = marginal_price === nothing ? o.price :
                                     (o.type == :supply ? max(marginal_price, o.price) :
                                      min(marginal_price, o.price))
                elseif o.type == :supply
                    rejected_mw <= quantity_atol ? (lo = max(lo, o.price)) : (hi = min(hi, o.price))
                else
                    rejected_mw <= quantity_atol ? (hi = min(hi, o.price)) : (lo = max(lo, o.price))
                end
            end
            # An inverted bracket means the accepted/rejected sets are not
            # consistent with any single price — flag it instead of hiding it
            # behind the clamp.
            lo > hi + price_atol && (inconsistent_brackets += 1)
            polished = marginal_price === nothing ? lo : marginal_price
            comp_lo[root] = min(lo, hi); comp_hi[root] = max(lo, hi)
            comp_price[root] = clamp(polished, comp_lo[root], comp_hi[root])
            comp_pinned[root] = marginal_price !== nothing
        end

        # Rent-sign constraints across BINDING links: p[sink] >= p[source] on
        # a link at its forward cap (and the mirror at the backward cap).
        # Instead of abandoning the whole period on a violation (the pre-2026-08
        # behaviour published the solver's arbitrary bracket point for EVERY
        # zone, including uninvolved ones), propagate: an unpinned component may
        # move within its own bracket to satisfy the link; only the components
        # that genuinely cannot be reconciled keep the solver's prices.
        constraints = Tuple{String,String}[]      # (lower_root, higher_root)
        if is_multi_zone
            for pair in zone_pairs
                fv = flow_values[(pair, time_period)]
                fwd_cap, bwd_cap = flow_caps[(pair, time_period)]
                at_fwd = fv >= fwd_cap - flow_atol
                at_bwd = fv <= -bwd_cap + flow_atol
                rs, rk = find_root(pair[1]), find_root(pair[2])
                rs == rk && continue
                if at_fwd && !at_bwd
                    push!(constraints, (rs, rk))
                elseif at_bwd && !at_fwd
                    push!(constraints, (rk, rs))
                end
            end
        end
        bad = Set{String}()
        changed = true
        iter = 0
        while changed && iter < 4 * length(constraints) + 1
            changed = false
            iter += 1
            for (lo_r, hi_r) in constraints
                (lo_r in bad || hi_r in bad) && continue
                p_lo = comp_price[lo_r]
                p_hi = comp_price[hi_r]
                p_hi >= p_lo - price_atol && continue
                if !comp_pinned[hi_r] && comp_hi[hi_r] >= p_lo - price_atol
                    comp_price[hi_r] = min(p_lo, comp_hi[hi_r]); changed = true
                elseif !comp_pinned[lo_r] && comp_lo[lo_r] <= p_hi + price_atol
                    comp_price[lo_r] = max(p_hi, comp_lo[lo_r]); changed = true
                else
                    push!(bad, lo_r); push!(bad, hi_r); changed = true
                end
            end
        end
        # Anything still violated after the iteration cap is unreconciled too
        for (lo_r, hi_r) in constraints
            (lo_r in bad || hi_r in bad) && continue
            comp_price[hi_r] >= comp_price[lo_r] - price_atol || (push!(bad, lo_r); push!(bad, hi_r))
        end

        for (root, comp_zones) in components
            if root in bad
                fallback_cells += length(comp_zones)    # keep the solver's prices
            else
                for z in comp_zones
                    prices[z][time_period] = comp_price[root]
                end
            end
        end
        isempty(bad) || push!(fallback_periods, time_period)
    end

    isempty(fallback_periods) ||
        @warn "Price reconstruction: rent-sign validation failed on " *
              "$(length(fallback_periods)) period(s) — $fallback_cells zone-period cell(s) " *
              "keep the solver's raw prices (component-scoped fallback; provenance " *
              "differs from reconstructed cells)" periods = fallback_periods
    inconsistent_brackets == 0 ||
        @warn "Price reconstruction: $inconsistent_brackets component-period(s) had an " *
              "inverted accepted/rejected bracket (lo > hi) — priced at the bracket edge"

    return (prices = prices, fallback_periods = fallback_periods,
            fallback_cells = fallback_cells, inconsistent_brackets = inconsistent_brackets)
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
    big_m::Float64=BIG_M_PARAMETER,
    time_limit::Float64=900.0,
    mip_gap::Float64=1e-6,
    heuristic_effort::Union{Float64,Nothing}=nothing,
    # Per-period decomposition. The MPCC has NO inter-temporal coupling
    # (no ramp/storage/block/t±1 links — every period is a mathematically
    # independent clearing), so the monolithic optimum is exactly the
    # concatenation of the per-period optima. When true (and there is more
    # than one period) each period is solved as its own single-period
    # MPCC and the results are merged into one MPCCResult of the same
    # shape. This makes the 39-zone clear solvable with HiGHS (which cannot
    # find a first incumbent on the monolithic 39-zone×24 MIP). Default
    # false keeps the monolithic path byte-identical for Gurobi.
    decompose_periods::Bool=false,
    # Suppress the per-solve flow-setup chatter. Default true keeps the
    # monolithic path's output byte-identical; the decomposition driver
    # passes false to its (many) single-period sub-solves.
    verbose::Bool=true)

    # Period decomposition: solve each period independently and merge. Only
    # engages with >1 period; a single-period book already IS the per-period
    # problem, so it falls through to the monolithic path unchanged.
    if decompose_periods && length(order_book.periods) > 1
        return _solve_mpcc_by_period(order_book;
            preferred_solver=preferred_solver, silent=silent, big_m=big_m,
            time_limit=time_limit, mip_gap=mip_gap,
            heuristic_effort=heuristic_effort, verbose=verbose)
    end

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

    # Safety limits for large (multi-zone) MIPs: cap the solve time; the
    # best incumbent is still returned. The gap tolerance must be tight:
    # the welfare objective is dominated by price-taker demand bid at the
    # price cap, so even a 0.1% relative gap is millions of € — enough
    # slack for the incumbent to curtail demand at the cap in some hour,
    # which prices that hour at the cap instead of the competitive level.
    # Defaults unchanged (900 s / 1e-6); callers may extend the budget for
    # solvers that need longer to find a first incumbent on the 39-zone MIP
    # (HiGHS) — see bin/reproduce.jl.
    set_time_limit_sec(model, time_limit)
    try
        set_attribute(model, MOI.RelativeGapTolerance(), mip_gap)
    catch
        # attribute not supported by this solver version — proceed with defaults
    end
    # Optional: crank the solver's primal-heuristic effort (HiGHS
    # "mip_heuristic_effort", default 0.05) to find a first incumbent sooner
    # on the large multi-zone complementarity MIP. No-op if unsupported.
    if heuristic_effort !== nothing && solver_name == "HiGHS"
        try
            set_optimizer_attribute(model, "mip_heuristic_effort", heuristic_effort)
        catch
        end
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
        flow_caps = Dict{Tuple{Tuple{String,String},String},Tuple{Float64,Float64}}()

        if order_book.network_topology isa TransferCapacity
            tc = order_book.network_topology

            # Get zone pairs with transfer capacity, restricted to zones in
            # this book: capacity data can include borders to zones outside
            # the clearing set, and a flow to a zone with no power balance
            # would act as a free, costless energy source/sink
            zone_pairs = [p for p in get_zone_pairs(tc)
                          if p[1] in order_book.nodes && p[2] in order_book.nodes]

            if !isempty(zone_pairs)
                verbose && println("   🔌 Adding transmission flow variables for $(length(zone_pairs)) zone pairs")

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
                        # `capacity_backward[(A,B,p)]` only exists when `(A,B,p)`
                        # is itself a published forward key; since `get_zone_pairs`
                        # now returns ONE orientation per border, a period that
                        # publishes only the reverse direction would otherwise
                        # silently lose its capacity. Fall back to the reverse
                        # forward key — which is exactly how `capacity_backward`
                        # is defined, so this is identical wherever both exist.
                        backward_cap = get(tc.capacity_backward, (source, sink, lookup_period),
                            get(tc.capacity_forward, (sink, source, lookup_period), 0.0))

                        # ATC bounds: -backward <= flow <= forward
                        set_lower_bound(flow[pair, t], -backward_cap)
                        set_upper_bound(flow[pair, t], forward_cap)
                        flow_caps[(pair, t)] = (forward_cap, backward_cap)
                    end
                end

                # Market-coupling price condition. Flows alone only move
                # energy; without a price-side condition zone prices are
                # completely uncoupled and the solver may publish arbitrary
                # cross-zone spreads over uncongested links. EU coupling
                # requires: price[sink] - price[source] equals the congestion
                # rent — zero while the link is inside its ATC limits (prices
                # equal), positive only at the forward limit, negative only
                # at the backward limit. Complementarity via per-link
                # binaries; the rent is bounded by the book's price span.
                price_span_flows = order_book.price_limits[2] - order_book.price_limits[1]
                @variable(model, congestion_fw[pair in zone_pairs, t in order_book.periods] >= 0)
                @variable(model, congestion_bw[pair in zone_pairs, t in order_book.periods] >= 0)
                @variable(model, congestion_fw_aux[pair in zone_pairs, t in order_book.periods], Bin)
                @variable(model, congestion_bw_aux[pair in zone_pairs, t in order_book.periods], Bin)
                for pair in zone_pairs
                    source, sink = pair
                    # capacity data can include borders to zones outside the
                    # clearing set — no price variable exists for those
                    (source in order_book.nodes && sink in order_book.nodes) || continue
                    for t in order_book.periods
                        forward_cap, backward_cap = flow_caps[(pair, t)]
                        cap_span = forward_cap + backward_cap
                        @constraint(model,
                            market_price[sink, t] - market_price[source, t] ==
                            congestion_fw[pair, t] - congestion_bw[pair, t])
                        # fw rent > 0 only when flow is at the forward limit
                        @constraint(model,
                            congestion_fw[pair, t] <= congestion_fw_aux[pair, t] * price_span_flows)
                        @constraint(model,
                            forward_cap - flow[pair, t] <=
                            (1 - congestion_fw_aux[pair, t]) * cap_span)
                        # bw rent > 0 only when flow is at the backward limit
                        @constraint(model,
                            congestion_bw[pair, t] <= congestion_bw_aux[pair, t] * price_span_flows)
                        @constraint(model,
                            flow[pair, t] + backward_cap <=
                            (1 - congestion_bw_aux[pair, t]) * cap_span)
                    end
                end
                verbose && println("   🔗 Added market-coupling price conditions for $(length(zone_pairs)) links")

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

                verbose && println("   ✅ Added $(length(zone_pairs) * length(order_book.periods)) flow variables with ATC bounds")
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

        # Power balance constraints with optional transmission flows.
        # Order contributions are signed supply-NEGATIVE / demand-POSITIVE, so
        # the balance reads  -S + D + shed - inflows + outflows = 0, i.e.
        # S + inflows = D + shed + outflows: an importing zone needs LESS
        # local supply, an exporting zone needs MORE. (With the signs the
        # other way round — inflows added, outflows subtracted — every flow
        # acts physically mirrored: flow[(A,B)] > 0 drains B into A, so ATC
        # bounds and congestion-rent conditions apply to the wrong direction
        # and asymmetric borders force spurious shortages.)
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
                load_shed[node_id, time_period] -
                # Inflows: power coming INTO this zone (flow[source, this_zone])
                sum(flow[(z, node_id), time_period] for z in get(zones_to, node_id, String[]); init=0.0) +
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
        # Side 1: acceptance ⊥ dual_rhs — an accepted order earns no
        # out-of-money surplus (acceptance > 0 ⟹ dual_rhs = 0).
        # The rhs Big-M is per-order (quantity × price span bounds the rhs of
        # any rejected order): a global constant would force the price to
        # within global_M/quantity of a large rejected order's bid, silently
        # raising the price floor for multi-GW price-taker orders.
        @variable(model, stepwise_acceptance_complementarity_aux[order_id in order_ids], Bin)
        @constraint(model, stepwise_acceptance_complementarity_ineq1[order_id in order_ids],
            stepwise_acceptance[order_id] <= stepwise_acceptance_complementarity_aux[order_id] * 1.0)
        # Refs to the two Big-M constraint families, collected so the last
        # retry rung can swap them for exact indicator constraints (see the
        # ladder below). Only those two families carry the q×price-span
        # constants; everything else is unit-coefficient.
        side1_bigm_cons = JuMP.ConstraintRef[]
        side2_bigm_cons = JuMP.ConstraintRef[]
        for (i, order) in enumerate(simple_orders)
            order_id = order_ids[i]
            # TIGHT per-order bound on the rejected-order rhs. When aux = 0
            # the acceptance is 0, which (via side 2's second constraint)
            # forces aux2 = 0 and hence dual = 0 — so the rhs reduces to
            # |q|·(bid-vs-price gap): q·(bid − floor) for supply,
            # q·(ceiling − bid) for demand, both maximized at the far price
            # bound. When aux = 1 the constraint pins rhs to 0 and the
            # constant is unused. The previous 2·q·span headroom for the
            # dual term was vacuous (dual is provably 0 in the aux = 0
            # branch) and produced ~1e8 coefficients on multi-GW cap-priced
            # demand blocks (2 × 60 GW × 3500), whose integrality-tolerance
            # leakage (~1e-5 × 1e8 ≈ 4000 €·MW) is the measured source of
            # false INFEASIBLE certificates on large books (2026-04-02: the
            # blamed hour solves optimal in isolation). For a cap-priced
            # demand block the tight constant is exactly 0 — the coefficient
            # disappears entirely. Bids outside the price limits keep their
            # documented behaviour: rejection is impossible via the rhs ≥ 0
            # constraint itself, independent of this constant.
            m1 = order.type == :supply ?
                 order.quantity * max(0.0, order.price - order_book.price_limits[1]) :
                 order.quantity * max(0.0, order_book.price_limits[2] - order.price)
            push!(side1_bigm_cons, @constraint(model,
                stepwise_dual_rhs[order_id] <=
                (1 - stepwise_acceptance_complementarity_aux[order_id]) * m1))
        end

        # Side 2: dual ⊥ (1 - acceptance) — only a FULLY accepted order may
        # carry positive surplus (dual > 0 ⟹ acceptance = 1). Without this
        # side, a partially accepted (marginal) order does not pin the price
        # to its bid, and rejected orders don't constrain the price at all:
        # the market price is then only bracketed, not determined, and the
        # solver returns an arbitrary point of the feasible interval. With
        # it, the marginal order sets the price exactly — including the
        # demand price cap in shortage hours, per EU day-ahead convention.
        # The dual equals the order's full surplus when fully accepted, so
        # its Big-M must cover the order's maximum possible surplus given
        # the price bounds: q × (bid − floor) for demand, q × (ceiling − bid)
        # for supply. Using quantity × price_span instead would make the
        # model INFEASIBLE for orders bid outside the book's price limits
        # (e.g. demand at 3000 in a book capped at 500), and a global
        # constant would silently cap large orders' surplus and distort the
        # price. The acceptance side is bounded by 1, so its "Big-M" is 1.
        @variable(model, stepwise_dual_complementarity_aux[order_id in order_ids], Bin)
        for (i, order) in enumerate(simple_orders)
            order_id = order_ids[i]
            max_surplus = order.type == :supply ?
                          order.quantity * max(0.0, order_book.price_limits[2] - order.price) :
                          order.quantity * max(0.0, order.price - order_book.price_limits[1])
            push!(side2_bigm_cons, @constraint(model,
                stepwise_dual[order_id] <=
                stepwise_dual_complementarity_aux[order_id] * max_surplus))
            @constraint(model,
                1 - stepwise_acceptance[order_id] <=
                (1 - stepwise_dual_complementarity_aux[order_id]) * 1.0)
        end

        # Price range constraints
        @constraint(model, minimum_price[node_id in order_book.nodes, time_period in order_book.periods],
            market_price[node_id, time_period] >= order_book.price_limits[1])
        @constraint(model, maximum_price[node_id in order_book.nodes, time_period in order_book.periods],
            market_price[node_id, time_period] <= order_book.price_limits[2])

        # Objective function - match dictionary formulation exactly
        # Dictionary version: stepwise_acceptance[order_id] * (sum of quantities) * price
        # Need to use signed quantities: negative for supply, positive for demand
        load_shed_penalty = 10000.0  # High penalty for load shedding (€/MWh)
        @objective(model, Max,
            sum(stepwise_acceptance[order_ids[i]] *
                (order.type == :supply ? -order.quantity : order.quantity) * order.price
                for (i, order) in enumerate(simple_orders)) -
            load_shed_penalty * sum(load_shed[node_id, time_period]
                                    for node_id in order_book.nodes, time_period in order_book.periods)
        )

        # Solve the model
        optimize!(model)

        # Gurobi's presolve can return the ambiguous INFEASIBLE_OR_UNBOUNDED
        # on numerically borderline instances (observed: the 2026-04-02 EU
        # book — a coin-flip outcome across otherwise identical runs). Retry
        # once with DualReductions=0, which forces Gurobi to distinguish the
        # two cases and, for this model class (bounded prices, bounded
        # acceptances — it cannot actually be unbounded), typically proves
        # optimality. No-op for every solve that doesn't hit this status.
        if termination_status(model) == MOI.INFEASIBLE_OR_UNBOUNDED
            @warn "MPCC solve returned INFEASIBLE_OR_UNBOUNDED — retrying with DualReductions=0"
            try
                set_optimizer_attribute(model, "DualReductions", 0)
                optimize!(model)
            catch e
                @warn "DualReductions retry unavailable ($(sprint(showerror, e))) — keeping original status"
            end
        end
        # A "proven" INFEASIBLE can be a false certificate on this big-M
        # complementarity model at scale. Measured on the 2026-04-02 EU book
        # (~22k orders): the periods are independent, the hour the IIS
        # blamed (15:00) solves OPTIMAL in isolation, and earlier runs of
        # the same day solved optimally — the outcome is an ordering
        # coin-flip. Gated retry ladder (each time-boxed, none default-on):
        # 1) maximum numeric care with presolve kept conservative, then
        # 2) a different seed as last resort. The root fix — per-order
        # Big-M sized from each order's price range — is deferred to its
        # own change with an MPCC-level SEE-guard test.
        if termination_status(model) == MOI.INFEASIBLE
            try
                @warn "MPCC solve claims INFEASIBLE — retrying with NumericFocus=3"
                set_optimizer_attribute(model, "NumericFocus", 3)
                set_optimizer_attribute(model, "Presolve", 1)
                # Same budget as the first solve (bug sweep 2026-08-25: the rung
                # silently cut it 900 -> 300 s, so a false INFEASIBLE could come
                # back as a poor :time_limit incumbent that callers accept).
                set_optimizer_attribute(model, "TimeLimit", time_limit)
                optimize!(model)
                if termination_status(model) == MOI.INFEASIBLE
                    @warn "Still INFEASIBLE — last-resort retry with a different seed"
                    set_optimizer_attribute(model, "Seed", 42)
                    optimize!(model)
                end
            catch e
                @warn "Numeric retry ladder unavailable ($(sprint(showerror, e))) — keeping INFEASIBLE"
            end
        end
        # FINAL rung: exact indicator complementarity. The two Big-M families
        # carry q×price-span constants up to ~2.6e8 on multi-GW cap-priced
        # demand blocks; integrality-tolerance leakage at that magnitude is
        # the measured source of FALSE infeasible certificates on large books
        # (2026-04-02 previously; 2025-07-01/07-08/10-21/12-12, 2026-02-06/07
        # in the cv14 backfill; the DE_LU book under :installed fleet truth).
        # Swap both families for Gurobi native indicator constraints — the
        # SAME logical model with no constants at all (aux=1 ⟹ dual_rhs ≤ 0;
        # aux2=0 ⟹ dual ≤ 0; integer solutions pin dual = surplus exactly as
        # before via dual_rhs ≥ 0). Only reached when every Big-M solve has
        # failed, so the default path stays byte-identical.
        if termination_status(model) in (MOI.INFEASIBLE, MOI.INFEASIBLE_OR_UNBOUNDED) &&
           occursin("Gurobi", solver_name)
            @warn "Retry ladder exhausted — swapping Big-M complementarity for exact indicator constraints"
            try
                for c in side1_bigm_cons
                    delete(model, c)
                end
                for c in side2_bigm_cons
                    delete(model, c)
                end
                for (i, order) in enumerate(simple_orders)
                    oid = order_ids[i]
                    @constraint(model,
                        stepwise_acceptance_complementarity_aux[oid] -->
                        {stepwise_dual_rhs[oid] <= 0})
                    @constraint(model,
                        !stepwise_dual_complementarity_aux[oid] -->
                        {stepwise_dual[oid] <= 0})
                end
                set_optimizer_attribute(model, "TimeLimit", 600.0)
                optimize!(model)
                @info "Indicator-form re-solve finished with status $(termination_status(model))"
            catch e
                @warn "Indicator retry unavailable ($(sprint(showerror, e))) — keeping INFEASIBLE"
            end
        end
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

            # Competitive price selection. The complementarity constraints
            # only bracket the price — [max(accepted supply, rejected demand),
            # min(accepted demand, rejected supply)] — and the welfare
            # objective does not involve market_price, so the solver's value
            # is an arbitrary point of that interval (and a tiny objective
            # epsilon would drown in the MIP gap). Recompute the price from
            # the acceptance pattern instead: a marginal (partially accepted)
            # order pins the price to its bid exactly — including the demand
            # cap in shortage hours, per EU convention — and otherwise the
            # competitive (supply-side) end of the interval is used.
            #
            # Multi-zone books: zones are first grouped into price-coupled
            # components per period — a link whose flow is strictly inside
            # its ATC limits carries zero congestion rent, so its endpoint
            # prices are equal and the coupled zones share one merged order
            # stack. Links at a limit (including zero-capacity links, whose
            # flow sits at both limits) decouple, and each component is
            # priced from its own pooled acceptance pattern. Without this
            # the solver's price at a degenerate hour is an arbitrary point
            # of the coupling-feasible set (e.g. one zone at the cap and a
            # neighbor at the floor, both within the MIP gap).
            #
            # Two consistency guards keep the reconstruction from publishing
            # prices the solved model excludes:
            # - flow_atol matches the solver's feasibility tolerance: the
            #   congestion binaries only permit price separation when the
            #   flow is AT its limit, so a link merely NEAR the limit is
            #   still price-coupled and must stay in one component.
            # - Congestion-rent signs are validated per period: at a
            #   forward-binding link the sink's price may not fall below
            #   the source's (and symmetrically at a backward-binding one;
            #   links at both limits, i.e. zero capacity, are free). If any
            #   sign check fails the period keeps the solver's prices,
            #   which satisfy these constraints by construction.
            # Competitive price reconstruction (see _reconstruct_component_prices).
            # Flow values are extracted first so the reconstruction itself never
            # touches a JuMP object — that is what makes it unit-testable.
            flow_values = Dict{Tuple{Tuple{String,String},String},Float64}()
            if flow !== nothing && !isempty(zone_pairs)
                for pair in zone_pairs, t in order_book.periods
                    flow_values[(pair, t)] = value(flow[pair, t])
                end
            end
            recon = _reconstruct_component_prices(
                order_book.nodes, order_book.periods,
                zone_pairs,   # already empty whenever flow === nothing
                flow_values, flow_caps, orders_by_node_time, simple_orders,
                order_ids, stepwise_acceptance_values, order_book.price_limits,
                market_prices)
            market_prices = recon.prices


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
                verbose && println("   📊 Extracted flows for $(length(zone_pairs)) zone pairs")
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
            # A proven INFEASIBLE deserves diagnostics: compute the Gurobi IIS
            # (same machinery as the UC solver) so the conflicting constraint
            # set is printed instead of a blind failure.
            if termination_status(model) == MOI.INFEASIBLE &&
               occursin("Gurobi", solver_name)
                try
                    @info "MPCC model INFEASIBLE — computing IIS..."
                    compute_conflict!(model)
                    n = 0
                    for (F, S) in list_of_constraint_types(model)
                        for con in all_constraints(model, F, S)
                            if MOI.get(model, MOI.ConstraintConflictStatus(), con) == MOI.IN_CONFLICT
                                n += 1
                                n <= 25 && println("  IIS[$n]: $con")
                            end
                        end
                    end
                    # Variable bounds can also be in conflict
                    for v in all_variables(model)
                        try
                            if MOI.get(model, MOI.VariableInConflict(), v)
                                n += 1
                                n <= 25 && println("  IIS[$n]: variable bound $v ∈ [$(has_lower_bound(v) ? lower_bound(v) : -Inf), $(has_upper_bound(v) ? upper_bound(v) : Inf)]")
                            end
                        catch
                        end
                    end
                    @info "IIS complete: $n constraints/bounds in conflict"
                catch e
                    @warn "IIS computation failed: $(sprint(showerror, e))"
                end
            end
            # TerminationStatusCode does not convert to Symbol implicitly —
            # returning the raw enum used to crash the result construction
            # (MethodError(convert, (Symbol, MOI.INFEASIBLE))) and mask the
            # true status as :error. Map it explicitly.
            return MPCCResult(
                Symbol(lowercase(string(termination_status(model)))),
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
        # Never swallow silently — the :error status hides the true cause
        # (measured: a MethodError in a retry rung masqueraded as "solver
        # returned error" for a whole day).
        @warn "MPCC solve raised an exception — returning :error" exception=(e, catch_backtrace())
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

"""
    _solve_mpcc_by_period(order_book; preferred_solver, silent, big_m,
                          time_limit, mip_gap, heuristic_effort, verbose) -> MPCCResult

Period-decomposition driver. Because the MPCC has no inter-temporal coupling,
each period `t` in `order_book.periods` is an independent clearing problem. This
splits the book into one single-period sub-book per period (same nodes, same
network/ATC object — the ATC lookup already derives the hour from the timeslot,
so it is per-period — and the orders whose `extract_time_period` maps to `t`),
solves each on its own via the monolithic `solve_mpcc_market_clearing`, and
merges the per-period results into one full-day `MPCCResult` of the same shape
that all downstream code (saving, scoring, two-pass anchor extraction) expects.

Each per-period solve runs the FULL retry ladder in
`solve_mpcc_market_clearing`, so a single numerically hard period falls back on
its own without sinking the rest of the day.

Merge semantics:
- `market_prices` / `transmission_flows`: union of per-period slices.
- `objective_value` / `solve_time`: summed across periods.
- `stepwise_acceptance`: namespaced by period (`"t::order_id"`) to avoid the
  per-solve `order_id` collisions across periods; not load-bearing downstream.
- `status`: `:optimal` iff every period is `:optimal`; else the worst observed
  (`:error` > `:infeasible`/`:unbounded` > `:time_limit`). A period that hits
  its own time limit but still returns an incumbent surfaces as `:time_limit`
  (usable), matching the monolithic convention.
"""
function _solve_mpcc_by_period(order_book::MPCCOrderBook;
    preferred_solver::String="auto",
    silent::Bool=true,
    big_m::Float64=BIG_M_PARAMETER,
    time_limit::Float64=900.0,
    mip_gap::Float64=1e-6,
    heuristic_effort::Union{Float64,Nothing}=nothing,
    verbose::Bool=true)

    periods = order_book.periods
    println("   🧩 Period-decomposition: $(length(periods)) independent single-period clears (solver=$(preferred_solver))")

    simple_orders = filter(o -> isa(o, SimpleOrder), order_book.orders)

    # Bucket each order by its full-book period assignment. Using the full
    # periods vector here (not [t]) keeps the hourly/timeslot mapping identical
    # to the monolithic grouping; the single-period sub-book below then re-maps
    # these same orders onto its own [t] grid (a no-op for both formats).
    orders_by_period = Dict{String,Vector{MarketOrder}}()
    for t in periods
        orders_by_period[t] = MarketOrder[]
    end
    for o in simple_orders
        t = extract_time_period(o.date_time, periods)
        haskey(orders_by_period, t) && push!(orders_by_period[t], o)
    end

    merged_prices = Dict{String,Dict{String,Float64}}()
    for z in order_book.nodes
        merged_prices[z] = Dict{String,Float64}()
    end
    merged_flows = Dict{String,Dict{String,Float64}}()
    merged_accept = Dict{String,Float64}()
    total_obj = 0.0
    total_solve = 0.0
    statuses = Symbol[]
    solver_name = preferred_solver
    wall_start = time()

    for (pi, t) in enumerate(periods)
        sub_book = MPCCOrderBook(
            orders_by_period[t],
            order_book.nodes,
            [t],
            order_book.price_limits,
            order_book.network_topology
        )
        r = solve_mpcc_market_clearing(sub_book;
            preferred_solver=preferred_solver, silent=silent, big_m=big_m,
            time_limit=time_limit, mip_gap=mip_gap,
            heuristic_effort=heuristic_effort,
            decompose_periods=false, verbose=false)

        solver_name = r.solver_name
        push!(statuses, r.status)
        total_obj += r.objective_value
        total_solve += r.solve_time

        for (z, pd) in r.market_prices
            zt = get!(merged_prices, z, Dict{String,Float64}())
            for (per, p) in pd
                zt[per] = p
            end
        end
        for (fid, pd) in r.transmission_flows
            d = get!(merged_flows, fid, Dict{String,Float64}())
            for (per, f) in pd
                d[per] = f
            end
        end
        for (oid, a) in r.stepwise_acceptance
            merged_accept["$(t)::$(oid)"] = a
        end

        if verbose && (pi % 12 == 0 || pi == length(periods))
            n_bad = count(s -> s != :optimal, statuses)
            println("      · $(pi)/$(length(periods)) periods " *
                    "($(round(time() - wall_start, digits=1))s, last=$(r.status)" *
                    (n_bad > 0 ? ", $(n_bad) non-optimal)" : ")"))
        end
    end

    # Completeness is the invariant that matters, not the status name. A
    # per-period status is `Symbol(lowercase(string(termination_status)))`
    # whenever the model has no values, so :numerical_error / :other_error /
    # :memory_limit / :almost_optimal all exist and none was classified —
    # they fell through to the permissive `else :time_limit`, which the
    # caller (`pass1_usable` in multi_zone_run.jl) treats as USABLE. A day
    # missing one hour was then saved as a complete record. Assert every
    # node×period cell instead: this is inert when all periods produced
    # prices (the only case that ever reached the record intentionally).
    missing_cells = 0
    for z in order_book.nodes, t in periods
        haskey(get(merged_prices, z, Dict{String,Float64}()), t) || (missing_cells += 1)
    end

    merged_status = if missing_cells > 0
        :error
    elseif all(s -> s == :optimal, statuses)
        :optimal
    elseif any(s -> s == :error, statuses)
        :error
    elseif any(s -> s in (:infeasible, :unbounded), statuses)
        :infeasible
    else
        :time_limit
    end

    if missing_cells > 0
        stat_list = join(sort(unique(String.(statuses))), ", ")
        n_cells = length(order_book.nodes) * length(periods)
        @error "Period-decomposition: $missing_cells of $n_cells node×period price " *
               "cells are MISSING — the clear is incomplete and is reported as " *
               ":error so it can never be saved as a complete day " *
               "(per-period statuses: $stat_list)"
    end

    n_opt = count(s -> s == :optimal, statuses)
    msg = "Period-decomposed clear: $(n_opt)/$(length(periods)) periods optimal, " *
          "merged status $(merged_status)"
    merged_status != :optimal &&
        @warn "Period-decomposition: $msg"

    return MPCCResult(
        merged_status,
        total_obj,
        merged_prices,
        merged_accept,
        Dict{String,Float64}(),   # block acceptance (unused, as monolithic)
        Dict{String,Float64}(),   # block activation (unused)
        merged_flows,
        total_solve,
        time() - wall_start,
        solver_name,
        msg
    )
end
