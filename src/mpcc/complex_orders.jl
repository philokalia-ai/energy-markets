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
is_block_family(f::AbstractString) = startswith(f, "BLK:")

function resolve_complex_orders(order_book::MPCCOrderBook;
    preferred_solver::String="highs", verbose::Bool=true,
    forced_reject::Set{String}=Set{String}(), block_time_limit::Float64=300.0)
    linked = LinkedHourlyOrder[o for o in order_book.orders if o isa LinkedHourlyOrder]
    isempty(linked) && return order_book
    rest = MarketOrder[o for o in order_book.orders if !(o isa LinkedHourlyOrder)]
    simple = SimpleOrder[o for o in rest if o isa SimpleOrder]
    nodes, periods = order_book.nodes, order_book.periods
    nset = Set(nodes)
    release(msg) = begin
        @warn "complex orders: $msg — releasing family members uncapped (baseline book)"
        LAST_COMPLEX_INFO[] = (status=:fallback, message=msg)
        # Storage members come back uncapped at their bid; block members come back
        # as plain hourly orders at their limit price (= no block condition).
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
        # One thread: deterministic, and avoids the HiGHS parallel-MIP scheduler
        # segfault (HighsSplitDeque::publishWork in a RENS sub-MIP) observed once on
        # a 39-zone block master. No-op for solvers without the option.
        try
            set_optimizer_attribute(model, "threads", 1)
        catch
        end
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
        blk_fams = sort(unique(o.family for o in linked if is_block_family(o.family)))
        if !isempty(blk_fams)
            # regular blocks: one acceptance binary per block, all members follow it
            @variable(model, z[f in blk_fams], Bin)
            for f in blk_fams
                f in forced_reject && fix(z[f], 0.0; force=true)
            end
        end
        for (j, o) in enumerate(linked)
            n = string(o.zone)
            t = extract_time_period(o.date_time, periods)
            (n in nset && haskey(bal, (n, t))) || continue
            add_to_expression!(bal[(n, t)], -o.quantity, y[j])
            if is_block_family(o.family)
                @constraint(model, y[j] == model[:z][o.family])
            else
                add_to_expression!(get!(fam_rows, o.family, AffExpr(0.0)),
                    o.quantity * o.resolution_code / 60.0, y[j])
                fam_budget[o.family] = o.family_budget_mwh
            end
        end
        if !isempty(blk_fams)
            set_time_limit_sec(model, block_time_limit)
            try
                set_attribute(model, MOI.RelativeGapTolerance(), 1e-7)
            catch
            end
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
        (st == MOI.OPTIMAL || (st == MOI.TIME_LIMIT && has_values(model))) ||
            return release("master status $st")

        yv = value.(y)
        out = copy(rest)
        info = Dict{String,Any}()
        blocks = Dict{String,Any}()   # accepted block -> (zone, price, [(dt, MW, res)])
        nblk_rej = 0
        for (j, o) in enumerate(linked)
            if is_block_family(o.family)
                if yv[j] > 0.5
                    b = get!(blocks, o.family, (zone=string(o.zone), price=o.price,
                        slices=Tuple{DateTime,Float64,Int}[]))
                    push!(b.slices, (o.date_time, o.quantity, o.resolution_code))
                    # fixed injection: price-taker at the book's floor
                    push!(out, SimpleOrder(:supply, order_book.price_limits[1], o.quantity,
                        o.zone, o.date_time, o.resolution_code))
                end
                continue
            end
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
        LAST_COMPLEX_INFO[] = (status=:optimal, solve_time=el, families=info,
            blocks=blocks, n_blocks=length(blk_fams), forced=copy(forced_reject),
            master_status=string(st))
        if verbose
            nbind = count(d -> d["used"] >= d["budget"] - 1.0, values(info))
            println("   🔋 complex orders: master $(length(info)) storage families " *
                    "($nbind budget-binding), blocks $(length(blocks))/$(length(blk_fams)) " *
                    "accepted ($(length(forced_reject)) PAB-rejected), $st, $(round(el, digits=1)) s")
        end
        return MPCCOrderBook(out, nodes, periods, order_book.price_limits,
            order_book.network_topology)
    catch e
        e isa InterruptException && rethrow()
        return release("master LP raised $(sprint(showerror, e))")
    end
end

"""
    solve_with_complex_orders(order_book, solve; max_pab_rounds=4) -> MPCCResult

EUPHEMIA acceptance loop around fix-and-reprice: master → per-period MPCC with
the complex decisions fixed → check every ACCEPTED block is in the money at the
resulting prices (Σ_t (P_t − b)·q_t ≥ 0); paradoxically accepted blocks are
rejected (forced out of the master) and the day re-solved. Paradoxical
REJECTION is allowed, as in EUPHEMIA. `solve(book)` is the plain MPCC solve.
Storage families need no check: their members re-enter at their own bid, so the
MPCC complementarity already keeps every accepted part in the money.
"""
function solve_with_complex_orders(order_book::MPCCOrderBook, solve::Function;
    preferred_solver::String="highs", verbose::Bool=true, max_pab_rounds::Int=4)
    forced = Set{String}()
    res = nothing
    for rnd in 1:max_pab_rounds
        ob2 = resolve_complex_orders(order_book; preferred_solver=preferred_solver,
            verbose=verbose, forced_reject=forced)
        info = LAST_COMPLEX_INFO[]
        res = solve(ob2)
        usable = res.status == :optimal ||
                 (res.status == :time_limit && !isempty(res.market_prices))
        (usable && info !== nothing && info.status == :optimal && !isempty(info.blocks)) ||
            return res
        pab = String[]
        for (f, b) in info.blocks
            haskey(res.market_prices, b.zone) || continue
            zp = res.market_prices[b.zone]
            surplus = 0.0
            for (dt, q, r) in b.slices
                t = extract_time_period(dt, order_book.periods)
                haskey(zp, t) || continue
                surplus += (zp[t] - b.price) * q * r / 60.0
            end
            surplus < -1e-3 && push!(pab, f)
        end
        verbose && println("   🧱 PAB check round $rnd: $(length(pab)) paradoxically " *
                           "accepted block(s) of $(length(info.blocks)) accepted")
        isempty(pab) && return res
        union!(forced, pab)
        rnd == max_pab_rounds &&
            @warn "complex orders: $(length(pab)) block(s) still paradoxically accepted after $max_pab_rounds rounds — returning the last clear"
    end
    return res
end
