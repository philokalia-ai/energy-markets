# complex_orders.jl — the complex-order clear: the full-day MASTER and the block acceptance search.
# Included by ../MPCC.jl inside `module MPCC`.
#
# EUPHEMIA solves a welfare master problem that decides the inter-temporal
# (complex) orders, then prices every period with those decisions fixed
# (fix-and-reprice). The book can emit two complex-order families, both as
# `LinkedHourlyOrder`s:
#   - storage (`ESTOR:` …): hourly orders sharing a daily energy budget (the
#     divisible form of an exclusive group of profile blocks);
#   - regular blocks (`BLK:`): one acceptance binary per block, all hours follow it.
#
#   max  Σ demand q·p·x − Σ supply q·p·x − Σ linked q·p·y − PEN·Σ shed
#   s.t. per (node, period): the same nodal balance as the MPCC (same signs,
#        same ATC bounds, same JAO hub net-position limits, same shed slack),
#        per storage family f: Σ_{j∈f} q_j·(res_j/60)·y_j ≤ E_f,
#        per block b:          y_j = z_b, z_b ∈ {0,1},
#        0 ≤ x, y ≤ 1.
#
# Without blocks the master is a pure LP. Its output is each storage member's
# ALLOCATION a_j = q_j·y_j (the member re-enters the per-period MPCC as a plain
# SimpleOrder at its ORIGINAL bid capped at a_j, so it can still be marginal
# where its cap does not bind; where the budget binds, the next order sets the
# price) and, with blocks, the accepted set (fixed injections in the MPCC).
# Per-period decomposition is preserved.
#
# Block acceptance (`solve_with_complex_orders`): an accepted block must be in
# the money at the resulting prices (no paradoxically accepted block, PAB);
# paradoxical rejection is allowed, as in EUPHEMIA. The master cannot see the
# MPCC prices, so a reversible search around it finds a PAB-free set with high
# welfare W (= master objective with the set fixed); see that function.
#
# Books without a LinkedHourlyOrder never reach this code (byte-identical).

"""Last stage-1 diagnostics (per family), for harnesses. Overwritten per call."""
const LAST_COMPLEX_INFO = Ref{Any}(nothing)

_hourly_lookup(t::String) = (length(t) > 5 && contains(t, "-")) ?
    string(parse(Int, t[10:11]) + 1) : t

"""
    resolve_complex_orders(order_book; preferred_solver="highs", verbose=true,
        forced_reject=Set(), fixed_accept=nothing) -> MPCCOrderBook

Run the master and return the fix-and-reprice book (only SimpleOrders and the
book's other non-linked orders; accepted blocks as fixed injections).
`forced_reject` fixes those blocks' binaries to 0; `fixed_accept = A` fixes every
block binary (z_b = b ∈ A), which makes the master an LP. On any master failure
the members are released (the baseline book: storage uncapped, blocks dropped,
their original `BLKFB:` must-run offers restored) with a warning — the clear
never breaks.
"""
is_block_family(f::AbstractString) = startswith(f, "BLK:")
# Company block families with EUPHEMIA's block relations (strategy research, st-blocks). Books without
# them never reach any of this code (every branch below is guarded by an empty-list check):
#   BLKM:<zone>:<name>:mar=<r>          minimum acceptance ratio: accepted ratio ∈ {0} ∪ [r, 1]
#   BLKL:<zone>:<name>[:parent=<p>]     linked: accepted only if the family named <p> (same zone) is
#   BLKX:<zone>:<name>:group=<g>        exclusive group <g>: at most one member accepted
# Members carry their own price and side (supply injects, demand withdraws), so a family may be a loop.
is_cblock_family(f::AbstractString) = startswith(f, "BLKM:") || startswith(f, "BLKL:") || startswith(f, "BLKX:")
function _cblock_attrs(f::AbstractString)
    parts = split(f, ':')
    kv = Dict{String,String}()
    for p in parts[4:end]
        k, v = split(p, '='; limit=2)
        kv[String(k)] = String(v)
    end
    return (kind=Symbol(parts[1]), zone=String(parts[2]), name=String(parts[3]), attrs=kv)
end
"""family => parent family id (BLKL children), resolved by (zone, name) among the given families."""
function _cblock_parents(fams)
    byname = Dict{Tuple{String,String},String}()
    for f in fams
        a = _cblock_attrs(f); byname[(a.zone, a.name)] = f
    end
    par = Dict{String,String}()
    for f in fams
        a = _cblock_attrs(f)
        p = get(a.attrs, "parent", "")
        isempty(p) && continue
        haskey(byname, (a.zone, p)) || error("linked block $f: parent '$p' not in the book")
        par[f] = byname[(a.zone, p)]
    end
    return par
end
is_block_fallback(f::AbstractString) = startswith(f, "BLKFB:")
_plain(o::LinkedHourlyOrder) = SimpleOrder(o.type, o.price, o.quantity, o.zone,
                                           o.date_time, o.resolution_code)

function resolve_complex_orders(order_book::MPCCOrderBook;
    preferred_solver::String="highs", verbose::Bool=true,
    forced_reject::Set{String}=Set{String}(), block_time_limit::Float64=300.0,
    fixed_accept::Union{Nothing,Set{String}}=nothing, mar_full::Set{String}=Set{String}())
    all_linked = LinkedHourlyOrder[o for o in order_book.orders if o isa LinkedHourlyOrder]
    isempty(all_linked) && return order_book
    rest = MarketOrder[o for o in order_book.orders if !(o isa LinkedHourlyOrder)]
    # `BLKFB:` members are the ORIGINAL calibrated must-run offers a block replaced:
    # never in the master; restored verbatim only when the master fails (release).
    fallback = MarketOrder[_plain(o) for o in all_linked if is_block_fallback(o.family)]
    linked = LinkedHourlyOrder[o for o in all_linked if !is_block_fallback(o.family)]
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
                            if !is_block_family(o.family) && !is_cblock_family(o.family) &&
                               !is_block_fallback(o.family)]),
            nodes, periods, order_book.price_limits, order_book.network_topology, fixed_in)
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
            haskey(bal, (n, t)) && add_to_expression!(bal[(n, t)], -mw)   # accepted supply: −
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
        cblk = sort(unique(o.family for o in linked if is_cblock_family(o.family)))
        if !isempty(cblk)
            # company blocks: ratio zc ∈ [0,1] gated by the acceptance binary uc (MAR: r·uc ≤ zc ≤ uc)
            @variable(model, 0 <= zc[f in cblk] <= 1)
            @variable(model, uc[f in cblk], Bin)
            groups = Dict{String,Vector{String}}()
            for f in cblk
                a = _cblock_attrs(f)
                if a.kind == :BLKM
                    r = parse(Float64, a.attrs["mar"])
                    @constraint(model, zc[f] >= r * uc[f])
                    @constraint(model, zc[f] <= uc[f])
                else
                    @constraint(model, zc[f] == uc[f])
                end
                a.kind == :BLKX && push!(get!(groups, a.zone * ":" * a.attrs["group"], String[]), f)
                f in forced_reject && fix(uc[f], 0.0; force=true)
                fixed_accept === nothing || fix(uc[f], f in fixed_accept ? 1.0 : 0.0; force=true)
                # a MAR block the search moved to its upper boundary: all-or-nothing from now on
                (a.kind == :BLKM && f in mar_full) && @constraint(model, zc[f] >= uc[f])
            end
            for (c, p) in _cblock_parents(cblk)
                @constraint(model, uc[c] <= uc[p])
            end
            for (_, fs) in groups
                @constraint(model, sum(uc[f] for f in fs) <= 1)
            end
        end
        for (j, o) in enumerate(linked)
            n = string(o.zone)
            t = extract_time_period(o.date_time, periods)
            (n in nset && haskey(bal, (n, t))) || continue
            if is_cblock_family(o.family)
                add_to_expression!(bal[(n, t)], o.type == :supply ? -o.quantity : o.quantity, y[j])
                @constraint(model, y[j] == model[:zc][o.family])
                continue
            end
            add_to_expression!(bal[(n, t)], -o.quantity, y[j])
            if is_block_family(o.family)
                @constraint(model, y[j] == model[:z][o.family])
            else
                add_to_expression!(get!(fam_rows, o.family, AffExpr(0.0)),
                    o.quantity * o.resolution_code / 60.0, y[j])
                fam_budget[o.family] = o.family_budget_mwh
            end
        end
        if !isempty(blk_fams) || !isempty(cblk)
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
        # Sub-hourly books (the 15-min clear, cv46 default): the storage LP is
        # degenerate across the quarters of an hour wherever inputs are
        # hourly-replicated, and otherwise swings a whole family 0 <-> Pmax
        # between quarters on tiny price differences. Each storage family's MW
        # is held constant within the hour (a coarse ramp proxy). Only members
        # with resolution < 60 are touched, so hourly books are unchanged.
        # (Was the opt-in EUPHEMIA_PS_INTRAHOUR=flat; the env is gone in cv46.)
        let
            fq = Dict{Tuple{String,String},AffExpr}()
            for (j, o) in enumerate(linked)
                (is_block_family(o.family) || is_cblock_family(o.family) || o.resolution_code >= 60) && continue
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
            add_to_expression!(obj, (is_cblock_family(o.family) && o.type == :demand ?
                                     o.quantity : -o.quantity) * o.price, y[j])
        end
        @objective(model, Max, obj - 10000.0 * sum(shed))
        optimize!(model)
        st = termination_status(model)
        (st == MOI.OPTIMAL || (st == MOI.TIME_LIMIT && has_values(model))) ||
            return release("master status $st")
        # A TIME_LIMIT incumbent is used, but it is not a proven optimum (and the
        # block search's upper bound is then not a bound): say so.
        if st == MOI.TIME_LIMIT
            gap = try
                relative_gap(model)
            catch
                NaN
            end
            @warn "complex orders: master MILP hit its time limit ($(block_time_limit) s) — " *
                  "using the incumbent (rel. gap $gap)"
        end

        yv = value.(y)
        out = copy(rest)
        fixed = copy(fixed_in)
        info = Dict{String,Any}()
        blocks = Dict{String,Any}()   # accepted block -> (zone, price, [(dt, MW, res)])
        nblk_rej = 0
        for (j, o) in enumerate(linked)
            if is_cblock_family(o.family)
                if value(model[:uc][o.family]) > 0.5
                    ratio = clamp(value(model[:zc][o.family]), 0.0, 1.0)
                    b = get!(blocks, o.family, (zone=string(o.zone), price=o.price, ratio=ratio,
                        slices=Tuple{DateTime,Float64,Int}[]))
                    sq = o.type == :supply ? o.quantity : -o.quantity
                    push!(b.slices, (o.date_time, sq, o.resolution_code))
                    # every accepted company block, a partially accepted MAR block included, is ONE fixed
                    # injection at ONE ratio over all its periods (EUPHEMIA's single acceptance ratio; round 2:
                    # replaces round 1's per-period capped re-entry, which cleared below the cap in 295/660 cells)
                    k = (string(o.zone), extract_time_period(o.date_time, periods))
                    fixed[k] = get(fixed, k, 0.0) + sq * ratio
                end
                continue
            end
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


# Block acceptance search budget, as validated (highs-blocks: 4 eval days × 2 passes and
# 2 hold-out days, every call PAB-free within budget). Constants by design, no env knob.
const BLOCKS_MAX_PRICINGS = 30        # pricing solves per call (master + per-period MPCC)
const BLOCKS_GAP_STOP_EUR = 50_000.0  # stop once the best PAB-free W is this close to the UB
const BLOCKS_SEED_ROUNDS = 4          # seed: master rounds with cumulative forced rejections

"""Block structure of a book: family => (zone, price, [(period, MW, resolution)])."""
function _block_structure(order_book::MPCCOrderBook)
    B = Dict{String,Any}()
    for o in order_book.orders
        (o isa LinkedHourlyOrder && is_block_family(o.family)) || continue
        b = get!(B, o.family, (zone=string(o.zone), price=o.price, slices=Tuple{String,Float64,Int}[]))
        push!(b.slices, (extract_time_period(o.date_time, order_book.periods), o.quantity,
                         o.resolution_code))
    end
    return B
end

"""Day surplus Σ_t (P_t − b)·q_t·res/60 of block `b` at `prices`; NaN if a price is missing."""
function _block_surplus(b, prices)
    zp = get(prices, b.zone, nothing)
    zp === nothing && return NaN
    s = 0.0
    for (t, q, r) in b.slices
        haskey(zp, t) || return NaN
        s += (zp[t] - b.price) * q * r / 60.0
    end
    return s
end

"""Company block structure (BLKM/BLKL/BLKX): family => (kind, zone, parent, group, slices=[(period, signed MW,
resolution, price)]). Empty for every book without them."""
function _cblock_structure(order_book::MPCCOrderBook)
    C = Dict{String,Any}()
    for o in order_book.orders
        (o isa LinkedHourlyOrder && is_cblock_family(o.family)) || continue
        c = get!(C, o.family) do
            a = _cblock_attrs(o.family)
            (kind=a.kind, zone=a.zone, group=a.kind == :BLKX ? a.zone * ":" * a.attrs["group"] : "",
             parent=Ref(""), slices=Tuple{String,Float64,Int,Float64}[])
        end
        push!(c.slices, (extract_time_period(o.date_time, order_book.periods),
                         o.type == :supply ? o.quantity : -o.quantity, o.resolution_code, o.price))
    end
    for (ch, p) in (isempty(C) ? Dict{String,String}() : _cblock_parents(keys(C)))
        C[ch].parent[] = p
    end
    return C
end

"""Surplus Σ (P_t − p)·q_t·res/60 (signed q) of company block `c` at full ratio; NaN if a price is missing."""
function _cblock_surplus(c, prices)
    zp = get(prices, c.zone, nothing)
    zp === nothing && return NaN
    s = 0.0
    for (t, q, r, p) in c.slices
        haskey(zp, t) || return NaN
        s += (zp[t] - p) * q * r / 60.0
    end
    return s
end

"""Make a fixed acceptance set consistent with the relations: per exclusive group keep the member with the
highest `prio` (then name); drop linked blocks whose parent is not kept. BLK families pass through."""
function _cblock_closure(A::Set{String}, C, prio::Dict{String,Float64})
    isempty(C) && return A
    A = copy(A)
    byg = Dict{String,Vector{String}}()
    for f in A
        haskey(C, f) && !isempty(C[f].group) && push!(get!(byg, C[f].group, String[]), f)
    end
    for (_, fs) in byg
        length(fs) > 1 || continue
        keep = sort(fs; by=f -> (-get(prio, f, -Inf), f))[1]
        for f in fs; f == keep || delete!(A, f); end
    end
    changed = true
    while changed
        changed = false
        for f in collect(A)
            haskey(C, f) || continue
            p = C[f].parent[]
            if !isempty(p) && !(p in A)
                delete!(A, f); changed = true
            end
        end
    end
    return A
end

"""PAB/PRB of company blocks at `prices` given the accepted set `A` (ratios from the master info):
accepted f is PAB when its value S_f·ratio + Σ (accepted children's values) < 0 (children may pay for a
parent, EUPHEMIA's linked-family rule; plain/MAR/exclusive: S_f·ratio < 0); rejected f is a PRB when it is
in the money at full ratio and eligible (its parent accepted; no member of its group accepted)."""
function _cblock_check!(pab, prb, C, A, info, prices)
    isempty(C) && return
    S = Dict(f => _cblock_surplus(c, prices) for (f, c) in C)
    kids = Dict{String,Vector{String}}()
    for (f, c) in C
        isempty(c.parent[]) || push!(get!(kids, c.parent[], String[]), f)
    end
    val = Dict{String,Float64}()
    function v(f)
        get!(val, f) do
            r = haskey(info.blocks, f) ? info.blocks[f].ratio : 0.0
            S[f] * r + sum((v(k) for k in get(kids, f, String[]) if k in A); init=0.0)
        end
    end
    gacc = Set(C[f].group for f in A if haskey(C, f) && !isempty(C[f].group))
    for (f, c) in C
        if f in A
            x = v(f)
            (isnan(x) || x < -1e-3) && (pab[f] = x)
        elseif !isnan(S[f]) && S[f] > 1e-3 && (isempty(c.parent[]) || c.parent[] in A) &&
               (isempty(c.group) || !(c.group in gacc))
            prb[f] = S[f]
        end
    end
end

"""One candidate: the master (with `forced_reject` or `fixed_accept`), priced by `solve`.
`pab`: accepted blocks out of the money (a missing price counts as PAB); `prb`: rejected
blocks in the money (surplus €). `ok = false` when the master or the pricing failed."""
# A partially accepted MAR block (MAR ≤ r < 1) is the marginal block: its day surplus at the final prices must be ~0.
# In the money (surplus > MAR_TOL_EUR) points to r = 1: the block is made all-or-nothing and the candidate re-priced
# (≤ MAR_MOVE_ROUNDS rounds); out of the money is a PAB (pruned by the search as any block). Constants by design.
const MAR_TOL_EUR = 1.0
const MAR_MOVE_ROUNDS = 3

function _block_candidate(order_book, solve, B, phase; preferred_solver, verbose,
                          C=Dict{String,Any}(), prio=Dict{String,Float64}(), kw...)
    if !isempty(C) && haskey(kw, :fixed_accept)
        kw = merge(NamedTuple(kw), (fixed_accept=_cblock_closure(kw[:fixed_accept], C, prio),))
    end
    mar_full = Set{String}(); mar_moved = 0; mar_cap_hit = false
    local ob, info, res, A, ok
    for rnd in 0:(isempty(C) ? 0 : MAR_MOVE_ROUNDS)
        kwr = isempty(mar_full) ? kw : merge(NamedTuple(kw), (mar_full=copy(mar_full),))
        ob = resolve_complex_orders(order_book; preferred_solver=preferred_solver, verbose=verbose, kwr...)
        info = LAST_COMPLEX_INFO[]
        info.status == :optimal || return (ok=false, phase=phase, book=ob, res=nothing, info=info,
                                           A=Set{String}(), W=NaN, pab=Dict{String,Float64}(),
                                           prb=Dict{String,Float64}(), mar_moved=mar_moved, mar_partial=0,
                                           mar_cap_hit=mar_cap_hit)
        res = solve(ob)
        A = Set{String}(keys(info.blocks))
        ok = res.status == :optimal || (res.status == :time_limit && !isempty(res.market_prices))
        ok || break
        move = String[f for f in A if haskey(C, f) && C[f].kind == :BLKM && !(f in mar_full) &&
                      info.blocks[f].ratio < 1.0 - 1e-6 &&
                      info.blocks[f].ratio * _cblock_surplus(C[f], res.market_prices) > MAR_TOL_EUR]
        isempty(move) && break
        rnd == MAR_MOVE_ROUNDS && (mar_cap_hit = true; break)   # still a partial in-the-money block after the cap
        union!(mar_full, move); mar_moved += length(move)
    end
    mar_partial = count(f -> haskey(C, f) && C[f].kind == :BLKM && info.blocks[f].ratio < 1.0 - 1e-6, A)
    pab = Dict{String,Float64}(); prb = Dict{String,Float64}()
    if ok
        for (f, b) in B
            s = _block_surplus(b, res.market_prices)
            if f in A
                (isnan(s) || s < -1e-3) && (pab[f] = s)
            elseif !isnan(s) && s > 1e-3
                prb[f] = s
            end
        end
        _cblock_check!(pab, prb, C, A, info, res.market_prices)
    end
    return (ok=ok, phase=phase, book=ob, res=res, info=info, A=A, W=info.master_objective,
            pab=pab, prb=prb, mar_moved=mar_moved, mar_partial=mar_partial, mar_cap_hit=mar_cap_hit)
end

"""
    solve_with_complex_orders(order_book, solve; max_pricings=$BLOCKS_MAX_PRICINGS,
        gap_stop=$BLOCKS_GAP_STOP_EUR) -> MPCCResult

Fix-and-reprice with EUPHEMIA's block acceptance rule: every ACCEPTED block is in the
money at the resulting prices (Σ_t (P_t − b)·q_t ≥ 0); paradoxical rejection is allowed.
`solve(book)` is the plain per-period MPCC solve. Storage families need no check (their
members re-enter at their own bid, so the MPCC keeps every accepted part in the money):
a book without blocks is one master LP and one pricing.

With blocks, a reversible search. Every candidate acceptance set A is priced by `solve`,
and its welfare W(A) is the master objective with A fixed; UB = the first master's
objective (z free).
  1. Seed (≤ $BLOCKS_SEED_ROUNDS rounds): master with the cumulative PAB set forced out, as
     EUPHEMIA-style loops do; stops at the first PAB-free set.
  2. Prune (only if the seed found none): freeze A, drop its PABs, re-price; repeat. A shrinks
     every step and ∅ is PAB-free, so this always ends PAB-free (when the budget is spent
     it goes straight to ∅).
  3. Reinsertion: rejected blocks in the money at the current prices (PRBs), by surplus
     then name, in batches (first ⌈n/4⌉; doubled after a success, halved after a failure).
     A batch that creates PABs is pruned (≤ 3 steps) and kept only if W strictly improves.
Stops after `max_pricings` pricings, when the best PAB-free W is within `gap_stop` € of
UB, or when no PRB is left; returns the clear of the best PAB-free set (W highest).
`LAST_COMPLEX_INFO[]` is that set's master info plus `search` (pricings, wall, UB, W, gap,
PRBs, inserted blocks).

Failures: if the master fails, `resolve_complex_orders` releases the blocks to their
original `BLKFB:` must-run offers and that baseline book is cleared
(`LAST_COMPLEX_INFO.status == :fallback`). If a pricing solve fails before any PAB-free set
exists, its (failed) result is returned, as for a plain clear. Both are the only ways to
end without a PAB-free set.
"""
function solve_with_complex_orders(order_book::MPCCOrderBook, solve::Function;
    preferred_solver::String="highs", verbose::Bool=true,
    max_pricings::Int=BLOCKS_MAX_PRICINGS, gap_stop::Float64=BLOCKS_GAP_STOP_EUR)
    B = _block_structure(order_book)
    C = _cblock_structure(order_book)
    isempty(B) && isempty(C) && return solve(resolve_complex_orders(order_book;
        preferred_solver=preferred_solver, verbose=verbose))
    t0 = time()
    calls = Ref(0); UB = Ref(NaN); best = Ref{Any}(nothing)
    gap() = best[] === nothing ? Inf : UB[] - best[].W
    stop() = calls[] >= max_pricings || gap() <= gap_stop
    function price(phase; master_verbose=false, kw...)
        o = _block_candidate(order_book, solve, B, phase; preferred_solver=preferred_solver,
            verbose=master_verbose, C=C, prio=(cur === nothing ? Dict{String,Float64}() : cur.prb), kw...)
        calls[] += 1
        o.ok && isempty(o.pab) && (best[] === nothing || o.W > best[].W) && (best[] = o)
        verbose && o.info.status == :optimal &&
            println("   🧱 blocks [$phase] pricing $(calls[]): accepted $(length(o.A)), PAB $(length(o.pab)), " *
                    "PRB $(length(o.prb)), W $(round(o.W, digits=1)), best gap $(round(gap(), digits=1))")
        return o
    end

    # 1. seed
    forced = Set{String}()
    cur = nothing
    for rnd in 1:BLOCKS_SEED_ROUNDS
        cur = price("seed"; master_verbose=verbose, forced_reject=copy(forced))
        cur.info.status == :optimal || return solve(cur.book)   # master failed: baseline book
        rnd == 1 && (UB[] = cur.W)
        (!cur.ok || isempty(cur.pab) || calls[] >= max_pricings) && break
        union!(forced, keys(cur.pab))
    end
    # 2. prune
    while cur.ok && !isempty(cur.pab)
        cur = price("prune"; fixed_accept=calls[] < max_pricings ?
                                          setdiff(cur.A, keys(cur.pab)) : Set{String}())
    end
    # 3. reinsertion
    nins = 0
    if cur.ok && isempty(cur.pab)
        tried = Set{String}()
        cands() = [f for (f, _) in sort(collect(cur.prb); by=x -> (-x[2], x[1])) if !(f in tried)]
        queue = cands()
        k = cld(length(queue), 4)
        while !isempty(queue) && !stop()
            k = clamp(k, 1, length(queue))
            S = Set{String}(queue[1:k])
            o = price("insert"; fixed_accept=union(cur.A, S))
            if o.ok && !isempty(o.pab)
                np = 0
                while o.ok && !isempty(o.pab) && np < 3 && calls[] < max_pricings
                    o = price("insprune"; fixed_accept=setdiff(o.A, keys(o.pab)))
                    np += 1
                end
                if o.ok && isempty(o.pab) && o.W > cur.W + 1e-6
                    for f in S
                        f in o.A || push!(tried, f)
                    end
                    nins += count(f -> f in o.A, S)
                    cur = o; queue = cands(); k = min(2k, length(queue))
                    continue
                end
            elseif o.ok && o.W >= cur.W - 1e-6
                cur = o; nins += k
                queue = cands(); k = min(2k, length(queue))
                continue
            end
            if k == 1
                push!(tried, queue[1]); queue = queue[2:end]
            else
                k ÷= 2
            end
        end
    end

    o = best[]
    if o === nothing   # only after a failed master or pricing
        @warn "complex orders: no PAB-free block set — " *
              (cur.res === nothing ? "master failed, clearing the baseline book" :
                                     "pricing solve failed ($(cur.res.status))")
        return cur.res === nothing ? solve(cur.book) : cur.res
    end
    wall = time() - t0
    nprb = length(o.prb); prb_eur = sum(values(o.prb); init=0.0)
    LAST_COMPLEX_INFO[] = merge(o.info, (search=(pricings=calls[], wall=wall, UB=UB[], W=o.W,
        mar_moved=o.mar_moved, mar_partial=o.mar_partial, mar_cap_hit=o.mar_cap_hit,
        gap=UB[] - o.W, phase=o.phase, n_prb=nprb, prb_eur=prb_eur, inserted=nins,
        seed_forced=length(forced)),))
    verbose && println("   🧱 R1 summary: path=$(o.phase), pricing solves $(calls[]), wall $(round(wall, digits=1)) s, " *
                       "accepted $(length(o.A)), W $(round(o.W, digits=1)), gap to UB $(round(UB[] - o.W, digits=1)) €, " *
                       "PRB $nprb / $(round(prb_eur, digits=0)) €")
    return o.res
end
