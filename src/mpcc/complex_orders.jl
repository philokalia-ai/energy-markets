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
is_block_fallback(f::AbstractString) = startswith(f, "BLKFB:")
_plain(o::LinkedHourlyOrder) = SimpleOrder(o.type, o.price, o.quantity, o.zone,
                                           o.date_time, o.resolution_code)

function resolve_complex_orders(order_book::MPCCOrderBook;
    preferred_solver::String="highs", verbose::Bool=true,
    forced_reject::Set{String}=Set{String}(), block_time_limit::Float64=300.0,
    release_blocks::Bool=false, dump=nothing,
    fixed_accept::Union{Nothing,Set{String}}=nothing,   # research (replay scorer): z[f] := f ∈ A
    pre_optimize=nothing)   # research (hb-lazy in-tree PAB): f(model, z) called just before optimize!
    all_linked = LinkedHourlyOrder[o for o in order_book.orders if o isa LinkedHourlyOrder]
    isempty(all_linked) && return order_book
    rest = MarketOrder[o for o in order_book.orders if !(o isa LinkedHourlyOrder)]
    # `BLKFB:` members are the ORIGINAL calibrated must-run offers a block replaced:
    # never in the master; restored verbatim whenever the blocks are released.
    fallback = MarketOrder[_plain(o) for o in all_linked if is_block_fallback(o.family)]
    has_blocks = any(o -> is_block_family(o.family), all_linked)
    linked = LinkedHourlyOrder[o for o in all_linked if !is_block_fallback(o.family) &&
                               !(release_blocks && is_block_family(o.family))]
    if release_blocks && has_blocks
        rest = vcat(rest, fallback)
    end
    simple = SimpleOrder[o for o in rest if o isa SimpleOrder]
    nodes, periods = order_book.nodes, order_book.periods
    nset = Set(nodes)
    fixed_in = order_book.fixed_injections
    release(msg) = begin
        @warn "complex orders: $msg — releasing to the baseline book"
        LAST_COMPLEX_INFO[] = (status=:fallback, message=msg)
        # Baseline book exactly: storage members uncapped at their bid, blocks
        # dropped, their original calibrated must-run offers restored.
        base = MarketOrder[o for o in order_book.orders if !(o isa LinkedHourlyOrder)]
        MPCCOrderBook(vcat(base, fallback,
                MarketOrder[_plain(o) for o in all_linked
                            if !is_block_family(o.family) && !is_block_fallback(o.family)]),
            nodes, periods, order_book.price_limits, order_book.network_topology, fixed_in)
    end
    if isempty(linked)   # only blocks, and they were released
        LAST_COMPLEX_INFO[] = (status=:blocks_released, solve_time=0.0,
            families=Dict{String,Any}(), blocks=Dict{String,Any}(), n_blocks=0,
            forced=copy(forced_reject), master_status="none")
        return MPCCOrderBook(rest, nodes, periods, order_book.price_limits,
            order_book.network_topology, fixed_in)
    end
    t0 = time()
    try
        # HiGHS for the LP regardless of the MPCC solver preference unless the
        # caller insists on another one (an LP is easy for every backend).
        optimizer, _ = select_solver(preferred_solver == "auto" ? "highs" : preferred_solver)
        model = Model(optimizer)
        set_silent(model)
        # No thread override: HiGHS (1.27) keeps ONE process-wide scheduler, and a
        # model asking for a different `threads` than the one it was started with
        # fails with OTHER_ERROR — so the master uses the same default as the MPCC.
        # (A threads=1 pin was tried against an old-HiGHS 1.16 segfault; that crash
        # also hit flag-off books and is gone on HiGHS 1.27.)
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
        for ((n, t), mw) in fixed_in
            haskey(bal, (n, t)) && add_to_constant!(bal[(n, t)], -mw)
        end
        fam_rows = Dict{String,AffExpr}()
        fam_budget = Dict{String,Float64}()
        blk_fams = sort(unique(o.family for o in linked if is_block_family(o.family)))
        if !isempty(blk_fams)
            # regular blocks: one acceptance binary per block, all members follow it
            @variable(model, z[f in blk_fams], Bin)
            for f in blk_fams
                f in forced_reject && fix(z[f], 0.0; force=true)
                fixed_accept === nothing || fix(z[f], f in fixed_accept ? 1.0 : 0.0; force=true)
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
            cbal = @constraint(model, bal[(n, t)] + shed[n, t] == 0)
            # research dump only: machine-mappable balance-row names (LP duals = prices)
            dump === nothing || set_name(cbal, "bal[$n|$t]")
        end
        @constraint(model, fam[f in collect(keys(fam_rows))], fam_rows[f] <= fam_budget[f])
        # Sub-hourly books (15-min clear): the storage LP is degenerate across the
        # quarters of an hour wherever inputs are hourly-replicated, and otherwise
        # swings a whole family 0 <-> Pmax between quarters on tiny price
        # differences. EUPHEMIA_PS_INTRAHOUR=flat holds each storage family's MW
        # constant within the hour (a coarse ramp proxy); no-op on hourly books.
        if lowercase(get(ENV, "EUPHEMIA_PS_INTRAHOUR", "free")) == "flat"
            fq = Dict{Tuple{String,String},AffExpr}()
            for (j, o) in enumerate(linked)
                (is_block_family(o.family) || o.resolution_code >= 60) && continue
                t = extract_time_period(o.date_time, periods)
                add_to_expression!(get!(fq, (o.family, t), AffExpr(0.0)), o.quantity, y[j])
            end
            byhour = Dict{Tuple{String,String},Vector{String}}()
            for (f, t) in keys(fq)
                push!(get!(byhour, (f, first(t, 11)), String[]), t)
            end
            for ((f, _), ts) in byhour
                sort!(ts)
                for t in ts[2:end]
                    @constraint(model, fq[(f, t)] == fq[(f, ts[1])])
                end
            end
        end

        obj = AffExpr(0.0)
        for (i, o) in enumerate(simple)
            add_to_expression!(obj, (o.type == :supply ? -o.quantity : o.quantity) * o.price, x[i])
        end
        for (j, o) in enumerate(linked)
            add_to_expression!(obj, -o.quantity * o.price, y[j])
        end
        @objective(model, Max, obj - 10000.0 * sum(shed))
        dump === nothing || _dump_master_pre(model, dump, simple, linked, periods)
        pre_optimize === nothing || pre_optimize(model, isempty(blk_fams) ? nothing : model[:z])
        optimize!(model)
        dump === nothing || _dump_master_post(model, dump, t0, length(blk_fams),
                                              length(forced_reject))
        st = termination_status(model)
        (st == MOI.OPTIMAL || (st == MOI.TIME_LIMIT && has_values(model))) ||
            return release("master status $st")
        # A TIME_LIMIT incumbent is used (unchanged behaviour) but it is NOT a proven
        # optimum: say so loudly instead of accepting it silently.
        if st == MOI.TIME_LIMIT
            gap = try
                relative_gap(model)
            catch
                NaN
            end
            @warn "complex orders: master MILP hit its time limit ($(block_time_limit) s) — " *
                  "FAILURE to prove optimality; using the incumbent (rel. gap $gap, " *
                  "$(length(forced_reject)) forced rejections)"
        end

        yv = value.(y)
        out = copy(rest)
        fixed = copy(fixed_in)
        info = Dict{String,Any}()
        blocks = Dict{String,Any}()   # accepted block -> (zone, price, [(dt, MW, res)])
        nblk_rej = 0
        for (j, o) in enumerate(linked)
            if is_block_family(o.family)
                if yv[j] > 0.5
                    b = get!(blocks, o.family, (zone=string(o.zone), price=o.price,
                        slices=Tuple{DateTime,Float64,Int}[]))
                    push!(b.slices, (o.date_time, o.quantity, o.resolution_code))
                    # accepted block = a FIXED injection in the pricing problem (not an
                    # order the clear could partially reject)
                    k = (string(o.zone), extract_time_period(o.date_time, periods))
                    fixed[k] = get(fixed, k, 0.0) + o.quantity
                end
                continue
            end
            a = o.quantity * clamp(yv[j], 0.0, 1.0)
            d = get!(info, o.family, Dict{String,Any}("budget" => o.family_budget_mwh,
                "used" => 0.0, "offered_mwh" => 0.0, "slots_capped" => 0, "slots_zero" => 0,
                "capped" => Tuple{DateTime,Float64,Float64}[],
                "all" => Tuple{DateTime,Float64,Float64}[]))
            push!(d["all"], (o.date_time, o.quantity, a))
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
            master_status=string(st), master_objective=objective_value(model))
        if verbose
            nbind = count(d -> d["used"] >= d["budget"] - 1.0, values(info))
            println("   🔋 complex orders: master $(length(info)) storage families " *
                    "($nbind budget-binding), blocks $(length(blocks))/$(length(blk_fams)) " *
                    "accepted ($(length(forced_reject)) PAB-rejected), $st, $(round(el, digits=1)) s")
        end
        return MPCCOrderBook(out, nodes, periods, order_book.price_limits,
            order_book.network_topology, fixed)
    catch e
        e isa InterruptException && rethrow()
        return release("master LP raised $(sprint(showerror, e))")
    end
end

_max_pab_rounds_default() = (v = strip(get(ENV, "EUPHEMIA_MAX_PAB_ROUNDS", ""));
                             isempty(v) ? 4 : parse(Int, v))   # research hook; default 4

"""
    solve_with_complex_orders(order_book, solve; max_pab_rounds=4) -> MPCCResult

EUPHEMIA acceptance loop around fix-and-reprice: master → per-period MPCC with
the complex decisions fixed (accepted blocks as fixed injections) → check every
ACCEPTED block is in the money at the resulting prices (Σ_t (P_t − b)·q_t ≥ 0);
paradoxically accepted blocks are rejected (forced out of the master) and the
day re-solved. Paradoxical REJECTION is allowed, as in EUPHEMIA.

If blocks are still paradoxically accepted after `max_pab_rounds`, the clear is
NOT returned: the blocks are released to their original calibrated must-run
offers (the baseline book; storage families keep their master caps) and that
book is cleared instead. The result's `message` and `LAST_COMPLEX_INFO.status =
:pab_fallback` say so explicitly. `solve(book)` is the plain MPCC solve.
Storage families need no check: their members re-enter at their own bid, so the
MPCC complementarity already keeps every accepted part in the money.
"""
function solve_with_complex_orders(order_book::MPCCOrderBook, solve::Function;
    preferred_solver::String="highs", verbose::Bool=true,
    max_pab_rounds::Int=_max_pab_rounds_default())
    forced = Set{String}()
    cert_ctx = lp_cert_mode() !== :off   # research (M1 shadow logging) only
    if cert_ctx
        dkey = "pass_" * _cert_day(order_book.periods)
        CERT_CTX[dkey] = get(CERT_CTX, dkey, 0) + 1
    end
    # Research dump (EUPHEMIA_DUMP_MODELS, research_dump.jl): inert when unset.
    dumping = dump_enabled()
    D = nothing; ddir = ""
    if dumping
        ddir, D = _dump_begin(order_book, max_pab_rounds)
        _dump_base!(D, ddir, order_book, solve, preferred_solver)
    end
    for rnd in 1:max_pab_rounds
        dumping && (_DUMP_MASTER_LAST[] = nothing; tm = time())
        cert_ctx && (CERT_CTX["round"] = rnd)
        ob2 = resolve_complex_orders(order_book; preferred_solver=preferred_solver,
            verbose=verbose, forced_reject=forced,
            dump=dumping ? (ddir, "master_r$rnd") : nothing)
        info = LAST_COMPLEX_INFO[]
        # research P1 (EUPHEMIA_BLOCK_PRICE=existence): collect the reconstruction brackets
        p1 = block_price_mode() === :existence
        p1c = Any[]
        p1 && (P1_COLLECT[] = p1c)
        local res, plog, mpcc_secs
        dumping && (master_wall = time() - tm)
        try
            if dumping
                res, plog, mpcc_secs = _dump_solve(solve, ob2, ddir, "mpcc_blk_r$rnd")
            else
                res = solve(ob2)
            end
        finally
            P1_COLLECT[] = nothing
        end
        if p1 && res.status == :optimal && info !== nothing && info.status == :optimal &&
           !isempty(info.blocks)
            # research P1: search the admissible prices for one that keeps every accepted block
            # in the money; the PAB check below then runs at the repaired prices
            newp, p1stats = block_price_repair(res.market_prices, p1c, info.blocks,
                order_book.periods; preferred_solver=preferred_solver)
            P1_LAST[] = p1stats
            verbose && println("   🧮 P1 block-price repair round $rnd: $(p1stats)")
            res = MPCCResult(res.status, res.objective_value, newp, res.stepwise_acceptance,
                res.block_acceptance, res.block_activation, res.transmission_flows,
                res.solve_time, res.total_time, res.solver_name, res.message)
        end
        usable = res.status == :optimal ||
                 (res.status == :time_limit && !isempty(res.market_prices))
        if !(usable && info !== nothing && info.status == :optimal && !isempty(info.blocks))
            dumping && _dump_round!(D, ddir, order_book, rnd, forced, info, master_wall,
                res, plog, mpcc_secs, Dict{String,Float64}(), String[];
                outcome="returned (usable=$usable, master=$(info === nothing ? "none" : info.status), " *
                        "accepted=$(info === nothing || !hasproperty(info, :blocks) ? 0 : length(info.blocks)))")
            return res
        end
        pab = String[]
        surplus_all = Dict{String,Float64}()
        for (f, b) in info.blocks
            haskey(res.market_prices, b.zone) || continue
            zp = res.market_prices[b.zone]
            surplus = 0.0
            for (dt, q, r) in b.slices
                t = extract_time_period(dt, order_book.periods)
                haskey(zp, t) || continue
                surplus += (zp[t] - b.price) * q * r / 60.0
            end
            dumping && (surplus_all[f] = surplus)
            surplus < -1e-3 && push!(pab, f)
        end
        verbose && println("   🧱 PAB check round $rnd: $(length(pab)) paradoxically " *
                           "accepted block(s) of $(length(info.blocks)) accepted")
        dumping && _dump_round!(D, ddir, order_book, rnd, forced, info, master_wall,
            res, plog, mpcc_secs, surplus_all, pab;
            outcome=isempty(pab) ? "PAB-free: returned" : "continue")
        isempty(pab) && return res
        union!(forced, pab)
    end
    # Exhausted: never expose a clear that violates the block acceptance rule.
    @warn "complex orders: blocks still paradoxically accepted after $max_pab_rounds " *
          "round(s) — releasing the blocks to the original must-run offers (baseline book)"
    cert_ctx && (CERT_CTX["round"] = "fallback")
    ob3 = resolve_complex_orders(order_book; preferred_solver=preferred_solver,
        verbose=verbose, release_blocks=true)
    inner = LAST_COMPLEX_INFO[]
    if dumping
        res, plog, secs = _dump_solve(solve, ob3, ddir, "mpcc_fallback"; write_models=false)
        _dump_fallback!(D, ddir, res, plog, secs, forced)
    else
        res = solve(ob3)
    end
    LAST_COMPLEX_INFO[] = (status=:pab_fallback, inner=inner,
        message="PAB rounds exhausted ($max_pab_rounds); blocks released to baseline must-run offers")
    return MPCCResult(res.status, res.objective_value, res.market_prices,
        res.stepwise_acceptance, res.block_acceptance, res.block_activation,
        res.transmission_flows, res.solve_time, res.total_time, res.solver_name,
        "COMPLEX-ORDERS PAB FALLBACK (blocks released to baseline must-run): " * res.message)
end
