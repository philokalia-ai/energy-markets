# complex_orders.jl — stage 1 of the complex-order clear: the full-day MASTER LP.
# Included by ../MPCC.jl inside `module MPCC`.
#
# EUPHEMIA solves a welfare master problem that decides the inter-temporal
# (complex) orders, then prices every period with those decisions fixed
# (fix-and-reprice). This file is the master for the one complex-order family
# the book can emit — `LinkedHourlyOrder` (hourly orders sharing a daily energy
# budget; the divisible form of an exclusive group of profile blocks):
#
#   max  Σ demand q·p·x − Σ supply q·p·x − Σ linked q·p·y − PEN·Σ shed
#   s.t. per (node, period): the same nodal balance as the MPCC (same signs,
#        same ATC bounds, same JAO hub net-position limits, same shed slack),
#        per family f:       Σ_{j∈f} q_j·(res_j/60)·y_j ≤ E_f,
#        0 ≤ x, y ≤ 1.
#
# Pure LP (no binaries): convex, fast, deterministic. Its only output is each
# family member's ALLOCATION a_j = q_j·y_j. `resolve_complex_orders` then
# returns the book with every member replaced by a plain SimpleOrder at its
# ORIGINAL bid capped at a_j (members with no allocation drop out), so the
# unchanged per-period MPCC prices the day: the member can still be marginal
# where its cap does not bind; where the budget binds, the next order sets the
# price (the storage's scarcity rent). Per-period decomposition is preserved.
#
# Books without a LinkedHourlyOrder never reach this code (byte-identical).

"""Last stage-1 diagnostics (per family), for harnesses. Overwritten per call."""
const LAST_COMPLEX_INFO = Ref{Any}(nothing)

_hourly_lookup(t::String) = (length(t) > 5 && contains(t, "-")) ?
    string(parse(Int, t[10:11]) + 1) : t

"""
    resolve_complex_orders(order_book; preferred_solver="highs", verbose=true)
        -> MPCCOrderBook

Run the master LP and return the fix-and-reprice book (only SimpleOrders and the
book's other non-linked orders). On any master failure the members are released
UNCAPPED (exactly the pre-complex-order book) with a warning — the clear never
breaks.
"""
function resolve_complex_orders(order_book::MPCCOrderBook;
    preferred_solver::String="highs", verbose::Bool=true)
    linked = LinkedHourlyOrder[o for o in order_book.orders if o isa LinkedHourlyOrder]
    isempty(linked) && return order_book
    rest = MarketOrder[o for o in order_book.orders if !(o isa LinkedHourlyOrder)]
    simple = SimpleOrder[o for o in rest if o isa SimpleOrder]
    nodes, periods = order_book.nodes, order_book.periods
    nset = Set(nodes)
    release(msg) = begin
        @warn "complex orders: $msg — releasing family members uncapped (baseline book)"
        LAST_COMPLEX_INFO[] = (status=:fallback, message=msg)
        MPCCOrderBook(vcat(rest, MarketOrder[SimpleOrder(o.type, o.price, o.quantity,
                o.zone, o.date_time, o.resolution_code) for o in linked]),
            nodes, periods, order_book.price_limits, order_book.network_topology)
    end
    t0 = time()
    try
        # HiGHS for the LP regardless of the MPCC solver preference unless the
        # caller insists on another one (an LP is easy for every backend).
        optimizer, _ = select_solver(preferred_solver == "auto" ? "highs" : preferred_solver)
        model = Model(optimizer)
        set_silent(model)
        ns, nl = length(simple), length(linked)
        @variable(model, 0 <= x[1:ns] <= 1)
        @variable(model, 0 <= y[1:nl] <= 1)
        @variable(model, shed[n in nodes, t in periods] >= 0)

        # nodal contributions, MPCC sign convention: supply −, demand +
        bal = Dict{Tuple{String,String},AffExpr}((n, t) => AffExpr(0.0)
                                                 for n in nodes, t in periods)
        for (i, o) in enumerate(simple)
            n = string(o.zone)
            n in nset || continue
            t = extract_time_period(o.date_time, periods)
            haskey(bal, (n, t)) || continue
            add_to_expression!(bal[(n, t)], o.type == :supply ? -o.quantity : o.quantity, x[i])
        end
        fam_rows = Dict{String,AffExpr}()
        fam_budget = Dict{String,Float64}()
        for (j, o) in enumerate(linked)
            n = string(o.zone)
            t = extract_time_period(o.date_time, periods)
            (n in nset && haskey(bal, (n, t))) || continue
            add_to_expression!(bal[(n, t)], -o.quantity, y[j])
            add_to_expression!(get!(fam_rows, o.family, AffExpr(0.0)),
                o.quantity * o.resolution_code / 60.0, y[j])
            fam_budget[o.family] = o.family_budget_mwh
        end

        # network: identical bounds to solve_mpcc_market_clearing
        zone_pairs = Tuple{String,String}[]
        tc = order_book.network_topology
        if tc isa TransferCapacity
            zone_pairs = [p for p in get_zone_pairs(tc) if p[1] in nset && p[2] in nset]
        end
        if !isempty(zone_pairs)
            @variable(model, flow[pair in zone_pairs, t in periods])
            for pair in zone_pairs, t in periods
                lp = _hourly_lookup(t)
                s, d = pair
                fw = get(tc.capacity_forward, (s, d, lp), 0.0)
                bw = get(tc.capacity_backward, (s, d, lp),
                    get(tc.capacity_forward, (d, s, lp), 0.0))
                set_lower_bound(flow[pair, t], -bw)
                set_upper_bound(flow[pair, t], fw)
                # inflow to d (−), outflow from s (+)
                add_to_expression!(bal[(d, t)], -1.0, flow[pair, t])
                add_to_expression!(bal[(s, t)], 1.0, flow[pair, t])
            end
            if !isempty(tc.net_position)
                for t in periods
                    lp = _hourly_lookup(t)
                    for ((ccr, hub, per), (mn, mx)) in tc.net_position
                        per == lp || continue
                        prs = get(tc.ccr_pairs, ccr, Set{Tuple{String,String}}())
                        terms = AffExpr(0.0)
                        nterm = 0
                        for pair in zone_pairs
                            inccr = (pair in prs) || ((pair[2], pair[1]) in prs)
                            inccr || continue
                            if pair[1] == hub
                                add_to_expression!(terms, 1.0, flow[pair, t]); nterm += 1
                            elseif pair[2] == hub
                                add_to_expression!(terms, -1.0, flow[pair, t]); nterm += 1
                            end
                        end
                        nterm == 0 && continue
                        @constraint(model, mn <= terms <= mx)
                    end
                end
            end
        end
        for n in nodes, t in periods
            @constraint(model, bal[(n, t)] + shed[n, t] == 0)
        end
        @constraint(model, fam[f in collect(keys(fam_rows))], fam_rows[f] <= fam_budget[f])

        obj = AffExpr(0.0)
        for (i, o) in enumerate(simple)
            add_to_expression!(obj, (o.type == :supply ? -o.quantity : o.quantity) * o.price, x[i])
        end
        for (j, o) in enumerate(linked)
            add_to_expression!(obj, -o.quantity * o.price, y[j])
        end
        @objective(model, Max, obj - 10000.0 * sum(shed))
        optimize!(model)
        st = termination_status(model)
        st == MOI.OPTIMAL || return release("master LP status $st")

        yv = value.(y)
        out = copy(rest)
        info = Dict{String,Any}()
        for (j, o) in enumerate(linked)
            a = o.quantity * clamp(yv[j], 0.0, 1.0)
            d = get!(info, o.family, Dict{String,Any}("budget" => o.family_budget_mwh,
                "used" => 0.0, "offered_mwh" => 0.0, "slots_capped" => 0, "slots_zero" => 0,
                "capped" => Tuple{DateTime,Float64,Float64}[]))
            d["offered_mwh"] += o.quantity * o.resolution_code / 60.0
            d["used"] += a * o.resolution_code / 60.0
            if a < o.quantity - 0.1
                d["slots_capped"] += 1
                a <= 0.1 && (d["slots_zero"] += 1)
                push!(d["capped"], (o.date_time, o.quantity, a))
            end
            a > 0.1 && push!(out, SimpleOrder(o.type, o.price, a, o.zone, o.date_time,
                o.resolution_code))
        end
        el = time() - t0
        LAST_COMPLEX_INFO[] = (status=:optimal, solve_time=el, families=info)
        if verbose
            nbind = count(d -> d["used"] >= d["budget"] - 1.0, values(info))
            println("   🔋 complex orders: master LP $(length(info)) families, " *
                    "$nbind budget-binding, $(round(el, digits=1)) s")
        end
        return MPCCOrderBook(out, nodes, periods, order_book.price_limits,
            order_book.network_topology)
    catch e
        e isa InterruptException && rethrow()
        return release("master LP raised $(sprint(showerror, e))")
    end
end
