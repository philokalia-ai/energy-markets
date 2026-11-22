# blocks_r1.jl — research-only R1 block acceptance search (highs-blocks, hb-lazy).
# Included by ../MPCC.jl inside `module MPCC`. Inert unless EUPHEMIA_BLOCKS_PAB=r1.
#
# Reversible search instead of the loop's permanent forced rejections:
#   1. loop phase: the production loop semantics for up to 4 rounds (master with z free except the
#      cumulative forced-reject set, per-period pricing, PAB blocks forced out); stops at the first
#      PAB-free acceptance set (the seed);
#   2. prune (only if the loop phase found no PAB-free set): freeze the acceptance, drop the PAB
#      blocks, re-price, repeat (prices rise as supply leaves; A = ∅ is the worst case);
#   3. reinsertion: rejected blocks in the money at the current prices (PRBs), surplus descending
#      then name, in batches (first ceil(n/4), doubling after a success, halving after a failure);
#      a batch whose insertion creates PABs is pruned (≤ 3 steps) and kept iff W strictly improves.
# Every candidate is priced by the SAME `solve` (per-period MPCC; M1 when EUPHEMIA_MPCC_LP_CERT=1)
# on the book whose master has every block binary fixed (W(A) = that master's objective).
# Deterministic budget: EUPHEMIA_BLOCKS_R1_MAX_CALLS (default 30) pricing solves in total, and a
# gap stop EUPHEMIA_BLOCKS_R1_GAP_STOP (default 50000 €) against the round-1 master objective (UB);
# also stops when no in-the-money rejected block is left. Returns the best PAB-free set's clear.
# If no PAB-free set is found within budget it runs the production loop with 20 rounds (which
# itself falls back to the baseline book if that fails) and logs the path.

function blocks_pab_mode()
    v = lowercase(strip(get(ENV, "EUPHEMIA_BLOCKS_PAB", "")))
    return v == "r1" ? :r1 : v == "lazy" ? :lazy : :loop
end
_r1_env_int(k, d) = (v = strip(get(ENV, k, "")); isempty(v) ? d : parse(Int, v))
_r1_env_float(k, d) = (v = strip(get(ENV, k, "")); isempty(v) ? d : parse(Float64, v))

"""Stats of the last R1 call (research)."""
const R1_LAST = Ref{Any}(nothing)

function _r1_block_structure(order_book)
    B = Dict{String,Any}()
    for o in order_book.orders
        o isa LinkedHourlyOrder || continue
        is_block_family(o.family) || continue
        b = get!(B, o.family, (zone=string(o.zone), price=o.price, slices=Tuple{String,Float64,Int}[]))
        push!(b.slices, (extract_time_period(o.date_time, order_book.periods), o.quantity, o.resolution_code))
    end
    return B
end

function _r1_surplus(b, prices)
    zp = get(prices, b.zone, nothing)
    zp === nothing && return NaN
    s = 0.0
    for (t, q, r) in b.slices
        haskey(zp, t) || return NaN
        s += (zp[t] - b.price) * q * r / 60.0
    end
    return s
end

"""Price a resolved book (ob, info) and classify blocks. Returns a NamedTuple."""
function _r1_price(order_book, solve, ob, info, B)
    res = solve(ob)
    A = Set{String}(keys(info.blocks))
    pab = Dict{String,Float64}(); prb = Dict{String,Float64}()
    usable = res.status == :optimal ||
             (res.status == :time_limit && !isempty(res.market_prices))
    if usable
        for (f, b) in B
            s = _r1_surplus(b, res.market_prices)
            if f in A
                (isnan(s) || s < -1e-3) && (pab[f] = s)
            else
                (!isnan(s) && s > 1e-3) && (prb[f] = s)
            end
        end
    end
    return (ok=usable, A=A, W=info.master_objective, pab=pab, prb=prb, res=res, info=info)
end

function _r1_fixed(order_book, solve, A, B; preferred_solver)
    ob = resolve_complex_orders(order_book; preferred_solver=preferred_solver, verbose=false,
        fixed_accept=A)
    info = LAST_COMPLEX_INFO[]
    (info === nothing || info.status != :optimal) &&
        return (ok=false, A=A, W=NaN, pab=Dict{String,Float64}(), prb=Dict{String,Float64}(),
                res=nothing, info=info)
    return _r1_price(order_book, solve, ob, info, B)
end

function solve_with_r1(order_book::MPCCOrderBook, solve::Function;
    preferred_solver::String="highs", verbose::Bool=true)
    t0 = time()
    max_calls = _r1_env_int("EUPHEMIA_BLOCKS_R1_MAX_CALLS", 30)
    gap_stop = _r1_env_float("EUPHEMIA_BLOCKS_R1_GAP_STOP", 50_000.0)
    B = _r1_block_structure(order_book)
    calls = Ref(0); UB = Ref(NaN)
    best = Ref{Any}(nothing)
    note(o) = (o.ok && isempty(o.pab) && (best[] === nothing || o.W > best[].W) && (best[] = o); o)
    gap() = best[] === nothing ? Inf : UB[] - best[].W
    stop() = calls[] >= max_calls || gap() <= gap_stop
    log = Any[]
    function trace(phase, o)
        push!(log, (phase=phase, call=calls[], n_acc=length(o.A), n_pab=length(o.pab), W=o.W, gap=gap()))
        verbose && println("   🧱 R1 [$phase] call $(calls[]): accepted $(length(o.A)), PAB $(length(o.pab)), " *
                           "PRB $(length(o.prb)), W $(round(o.W, digits=1)), best gap $(round(gap(), digits=1))")
    end
    # 1. loop phase (production semantics, ≤ 4 rounds)
    forced = Set{String}(); cur = nothing
    for rnd in 1:min(4, max_calls)
        ob = resolve_complex_orders(order_book; preferred_solver=preferred_solver, verbose=verbose,
            forced_reject=forced)
        info = LAST_COMPLEX_INFO[]
        if info === nothing || info.status != :optimal || !hasproperty(info, :blocks) || isempty(info.blocks)
            best[] === nothing || break     # keep the best PAB-free set found so far
            # nothing to search over (no blocks / master failure): behave as the loop would
            res = solve(ob)
            R1_LAST[] = Dict("path" => "no-blocks-or-master-failure", "calls" => 1, "wall" => time() - t0)
            return res
        end
        cur = _r1_price(order_book, solve, ob, info, B); calls[] += 1
        rnd == 1 && (UB[] = cur.W)
        note(cur); trace("loop", cur)
        (cur.ok && isempty(cur.pab)) && break
        cur.ok || break
        union!(forced, keys(cur.pab))
    end
    # 2. prune
    while cur !== nothing && cur.ok && !isempty(cur.pab) && calls[] < max_calls
        cur = _r1_fixed(order_book, solve, setdiff(cur.A, keys(cur.pab)), B;
            preferred_solver=preferred_solver)
        calls[] += 1; note(cur); trace("prune", cur)
    end
    # 3. reinsertion
    nins = 0
    if cur !== nothing && cur.ok && isempty(cur.pab)
        cur, nins = _r1_reinsert(order_book, solve, B, cur, calls, max_calls, stop, note, trace;
            preferred_solver=preferred_solver)
    end
    wall = time() - t0
    if best[] === nothing
        verbose && println("   🧱 R1: no PAB-free set within $(calls[]) pricing solves — running the loop (20 rounds)")
        res = solve_with_complex_orders(order_book, solve; preferred_solver=preferred_solver,
            verbose=verbose, max_pab_rounds=20, _r1_dispatch=false)
        inner = LAST_COMPLEX_INFO[]
        path = (inner !== nothing && inner.status == :pab_fallback) ? "r1->loop20->fallback" : "r1->loop20"
        R1_LAST[] = Dict("path" => path, "calls" => calls[], "wall" => time() - t0, "r1_wall" => wall)
        verbose && println("   🧱 R1 summary: path=$path, R1 pricing solves $(calls[]), wall $(round(time() - t0, digits=1)) s")
        return res
    end
    o = best[]
    LAST_COMPLEX_INFO[] = o.info
    nprb = length(o.prb); prb_eur = sum(values(o.prb); init=0.0)
    path = isempty(log) ? "r1" : (log[end].phase == "loop" && calls[] <= 4 && nins == 0 ? "r1(loop-seed)" : "r1")
    R1_LAST[] = Dict("path" => path, "calls" => calls[], "wall" => wall, "UB" => UB[], "W" => o.W,
        "gap" => UB[] - o.W, "n_accepted" => length(o.A), "n_prb" => nprb, "prb_eur" => prb_eur,
        "inserted" => nins, "n_forced_loop" => length(forced), "max_calls" => max_calls,
        "gap_stop" => gap_stop, "log" => log)
    verbose && println("   🧱 R1 summary: path=$path, pricing solves $(calls[]), wall $(round(wall, digits=1)) s, " *
                       "accepted $(length(o.A)), W $(round(o.W, digits=1)), gap to UB $(round(UB[] - o.W, digits=1)) €, " *
                       "PRB $nprb / $(round(prb_eur, digits=0)) €")
    return o.res
end

"""Reinsertion of in-the-money rejected blocks from the PAB-free set `cur` (shared by R1 and lazy).
`calls` is a Ref counter, `stop()` the budget/gap test, `note`/`trace` the incumbent bookkeeping."""
function _r1_reinsert(order_book, solve, B, cur, calls, max_calls, stop, note, trace; preferred_solver)
    nins = 0
    tried = Set{String}()
    cands() = [f for (f, _) in sort(collect(cur.prb); by=x -> (-x[2], x[1])) if !(f in tried)]
    queue = cands()
    k = cld(length(queue), 4)
    while !isempty(queue) && !stop()
        k = clamp(k, 1, length(queue))
        S = Set{String}(queue[1:k])
        o2 = _r1_fixed(order_book, solve, union(cur.A, S), B; preferred_solver=preferred_solver)
        calls[] += 1; note(o2); trace("insert", o2)
        pf2 = o2.ok && isempty(o2.pab)
        if !pf2 && o2.ok
            np = 0
            while o2.ok && !isempty(o2.pab) && np < 3 && calls[] < max_calls
                o2 = _r1_fixed(order_book, solve, setdiff(o2.A, keys(o2.pab)), B;
                    preferred_solver=preferred_solver)
                calls[] += 1; np += 1; note(o2); trace("insprune", o2)
            end
            if o2.ok && isempty(o2.pab) && o2.W > cur.W + 1e-6
                for f in S
                    f in o2.A || push!(tried, f)
                end
                nins += count(f -> f in o2.A, S)
                cur = o2; queue = cands(); k = min(2k, length(queue))
                continue
            end
            pf2 = false
        end
        if pf2 && o2.W >= cur.W - 1e-6
            cur = o2; nins += k
            queue = cands(); k = min(2k, length(queue))
        elseif k == 1
            push!(tried, queue[1]); queue = queue[2:end]
        else
            k = k ÷ 2
        end
    end
    return cur, nins
end
