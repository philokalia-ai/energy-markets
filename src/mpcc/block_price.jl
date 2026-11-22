# block_price.jl — research-only P1: block-aware price existence / repair (highs-blocks, hb-lazy).
# Included by ../MPCC.jl inside `module MPCC`. Inert unless EUPHEMIA_BLOCK_PRICE=existence.
#
# The per-period reconstruction (`_reconstruct_component_prices`) picks ONE point of the price
# bracket each coupled component leaves open, knowing nothing about blocks, so it can make an
# accepted block paradoxically accepted although another admissible price vector would keep it
# in the money. P1 searches that admissible set jointly over the day:
#   variables  p[c,t]  one price per coupled component and period, within the reconstruction
#              bracket [lo,hi]; pinned components (a marginal order sets the price) and
#              components whose rent signs could not be reconciled stay at the published price;
#   rows       rent sign across binding links:  p[sink comp] >= p[source comp];
#              every accepted block b:  Σ_t (p[c(z_b,t),t] − b) q_t res/60 + s_b >= 0, s_b >= 0;
#   objective  min 1e6·Σ s_b + Σ_cells |p − p_recon|   (L1 per zone cell).
# When all s_b = 0 the repaired prices satisfy every block; otherwise the blocks with s_b > 0 are
# the PAB set after repair, and the (still admissible) repaired prices are used for that round's
# check. Changing published prices is an owner decision: research flag only.

block_price_mode() = lowercase(strip(get(ENV, "EUPHEMIA_BLOCK_PRICE", ""))) == "existence" ? :existence : :off

"""Collector for the per-period reconstruction brackets (set to a Vector while P1 prices a book)."""
const P1_COLLECT = Ref{Any}(nothing)
"""Stats of the last P1 repair (research)."""
const P1_LAST = Ref{Any}(nothing)

function _p1_collect!(diag, flow_values, flow_caps, recon_prices)
    P1_COLLECT[] isa Vector || return nothing
    fl = Tuple{String,String,String,Bool,Bool}[]
    for ((pair, t), v) in flow_values
        fw, bw = flow_caps[(pair, t)]
        push!(fl, (pair[1], pair[2], t, v >= fw - 1e-3, v <= -bw + 1e-3))
    end
    push!(P1_COLLECT[], (diag=diag, flows=fl, prices=recon_prices))
    return nothing
end

"""
    block_price_repair(prices, collected, blocks, periods; preferred_solver) -> (new_prices, stats)

`prices` = published (reconstructed) prices of the day, `collected` = the P1_COLLECT entries of the
per-period solves that produced them, `blocks` = accepted blocks (family => (zone, price, slices)).
"""
function block_price_repair(prices::Dict{String,Dict{String,Float64}}, collected, blocks, periods;
                            preferred_solver::String="highs")
    t0 = time()
    lo = Float64[]; hi = Float64[]; tgt = Float64[]; wt = Int[]
    comp_of = Dict{Tuple{String,String},Int}()
    rent = Tuple{Int,Int}[]
    for e in collected
        for c in e.diag
            t = c["period"]; zs = c["zones"]
            k = length(lo) + 1
            for z in zs
                comp_of[(z, t)] = k
            end
            pub = prices[zs[1]][t]
            if c["pinned"] || get(c, "rent_sign_bad", false)
                push!(lo, pub); push!(hi, pub)
            else
                push!(lo, min(c["lo"], pub)); push!(hi, max(c["hi"], pub))
            end
            push!(tgt, pub); push!(wt, length(zs))
        end
    end
    for e in collected, (a, b, t, at_fwd, at_bwd) in e.flows
        ka = get(comp_of, (a, t), 0); kb = get(comp_of, (b, t), 0)
        (ka == 0 || kb == 0 || ka == kb) && continue
        at_fwd && !at_bwd && push!(rent, (ka, kb))   # p[kb] >= p[ka]
        at_bwd && !at_fwd && push!(rent, (kb, ka))
    end
    n = length(lo)
    stats = Dict{String,Any}("n_vars" => n, "n_rent" => length(rent), "n_blocks" => length(blocks))
    n == 0 && (stats["status"] = "no brackets"; return prices, stats)
    optimizer, _ = select_solver(preferred_solver == "auto" ? "highs" : preferred_solver)
    model = Model(optimizer)
    set_silent(model)
    @variable(model, lo[k] <= p[k=1:n] <= hi[k])
    @variable(model, u[1:n] >= 0); @variable(model, v[1:n] >= 0)
    @constraint(model, [k=1:n], p[k] - u[k] + v[k] == tgt[k])
    for (a, b) in rent
        @constraint(model, p[b] >= p[a])
    end
    fams = sort(collect(keys(blocks)))
    @variable(model, s[1:length(fams)] >= 0)
    for (i, f) in enumerate(fams)
        b = blocks[f]
        ex = AffExpr(0.0)
        for (dt, q, r) in b.slices
            t = extract_time_period(dt, periods)
            k = get(comp_of, (b.zone, t), 0)
            e = q * r / 60.0
            if k == 0
                add_to_expression!(ex, (get(get(prices, b.zone, Dict{String,Float64}()), t, b.price) - b.price) * e)
            else
                add_to_expression!(ex, e, p[k]); add_to_expression!(ex, -b.price * e)
            end
        end
        @constraint(model, ex + s[i] >= 0)
    end
    @objective(model, Min, 1e6 * sum(s; init=0.0) + sum(wt[k] * (u[k] + v[k]) for k in 1:n))
    optimize!(model)
    st = termination_status(model)
    stats["status"] = string(st)
    if st != MOI.OPTIMAL
        stats["secs"] = time() - t0
        return prices, stats
    end
    pv = value.(p); sv = value.(s)
    out = Dict{String,Dict{String,Float64}}(z => copy(d) for (z, d) in prices)
    nchg = 0; maxd = 0.0; sumd = 0.0
    for ((z, t), k) in comp_of
        haskey(out, z) || continue
        d = abs(pv[k] - prices[z][t])
        if d > 1e-6
            out[z][t] = pv[k]; nchg += 1; maxd = max(maxd, d); sumd += d
        end
    end
    stats["feasible"] = all(x -> x <= 1e-6, sv)
    stats["n_short"] = count(x -> x > 1e-6, sv)
    stats["cells_changed"] = nchg; stats["max_delta"] = maxd
    stats["mean_delta_changed"] = nchg == 0 ? 0.0 : sumd / nchg
    stats["secs"] = time() - t0
    return out, stats
end
