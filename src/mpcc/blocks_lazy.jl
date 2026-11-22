# blocks_lazy.jl — research-only in-tree PAB search with HiGHS lazy constraints (highs-blocks, hb-lazy).
# Included by ../MPCC.jl inside `module MPCC`. Inert unless EUPHEMIA_BLOCKS_PAB=lazy.
#
# Needs a libhighs with kCallbackMipDefineLazyConstraints (HiGHS branch hb/lazy, loaded through the
# JLL override depot). One master MIP solve; at every improving incumbent HiGHS calls back with the
# candidate acceptance set A, which is priced exactly like R1 does (master with z fixed to A + the
# per-period `solve`, M1 when EUPHEMIA_MPCC_LP_CERT=1). For every paradoxically accepted block b the
# callback returns the zone-conditional rejection
#     z_b + Σ_{c ∈ A, zone(c)=zone(b), c≠b} z_c − Σ_{r ∉ A, zone(r)=zone(b)} z_r <= |A_zone(b) \ b|
# This is a HEURISTIC cut (it can remove PAB-free sets); the master's OPTIMAL status is relative to
# the cuts it received, and the gap to the round-1 master objective is the honest measure.
# Budget (deterministic): EUPHEMIA_BLOCKS_LAZY_MAX_CALLBACKS (default 20) oracle calls, and the R1
# gap stop EUPHEMIA_BLOCKS_R1_GAP_STOP (default 50000 €); when either is reached the callback ends
# the master solve with an infeasible lazy row. If budget remains and the gap is above the stop, R1
# reinsertion continues from the best PAB-free set (EUPHEMIA_BLOCKS_R1_MAX_CALLS total, default 30
# + the lazy budget). No PAB-free set -> R1 path (which itself ends in loop20 -> fallback).
# HiGHS runs this master with parallel=off, presolve=off, no symmetry, no restarts (forced by the
# lazy callback in hb/lazy).

const _BL_CTX = Ref{Any}(nothing)
const _HIGHS_PKG = Base.PkgId(Base.UUID("87dc4568-4c63-4d18-b0c0-bb2238e4078b"), "HiGHS")

function _bl_cfn(cbtype::Cint, msg::Ptr{Cchar}, pout::Ptr{Cvoid}, pin::Ptr{Cvoid}, ud::Ptr{Cvoid})::Cvoid
    cbtype == Cint(8) || return nothing
    ctx = _BL_CTX[]
    ctx === nothing && return nothing
    try
        ctx.handle(pout, pin)
    catch e
        push!(ctx.errors, sprint(showerror, e))
    end
    return nothing
end

function solve_with_lazy(order_book::MPCCOrderBook, solve::Function;
    preferred_solver::String="highs", verbose::Bool=true)
    t0 = time()
    H = Base.require(_HIGHS_PKG)
    lib = H.libhighs
    fptr = Base.Libc.Libdl.dlsym(Base.Libc.Libdl.dlopen(lib), :Highs_addCallbackLazyConstraints;
        throw_error=false)
    if fptr === nothing
        @warn "EUPHEMIA_BLOCKS_PAB=lazy: $lib has no lazy-constraint callback (needs the hb/lazy build via " *
              "the override depot) — using the R1 path"
        return solve_with_r1(order_book, solve; preferred_solver=preferred_solver, verbose=verbose)
    end
    maxcb = _r1_env_int("EUPHEMIA_BLOCKS_LAZY_MAX_CALLBACKS", 20)
    gap_stop = _r1_env_float("EUPHEMIA_BLOCKS_R1_GAP_STOP", 50_000.0)
    max_calls = maxcb + _r1_env_int("EUPHEMIA_BLOCKS_R1_MAX_CALLS", 30)
    B = _r1_block_structure(order_book)
    zone_of = Dict(f => b.zone for (f, b) in B)
    # UB = round-1 master objective (z free)
    resolve_complex_orders(order_book; preferred_solver=preferred_solver, verbose=false)
    ub_info = LAST_COMPLEX_INFO[]
    if ub_info === nothing || ub_info.status != :optimal || !hasproperty(ub_info, :blocks)
        return solve_with_r1(order_book, solve; preferred_solver=preferred_solver, verbose=verbose)
    end
    UB = Ref(ub_info.master_objective)
    calls = Ref(0); best = Ref{Any}(nothing); seen = Dict{Set{String},Any}()
    note(o) = (o.ok && isempty(o.pab) && (best[] === nothing || o.W > best[].W) && (best[] = o); o)
    gap() = best[] === nothing ? Inf : UB[] - best[].W
    stop() = calls[] >= max_calls || gap() <= gap_stop
    trace(phase, o) = verbose && println("   🧱 LAZY [$phase] call $(calls[]): accepted $(length(o.A)), " *
        "PAB $(length(o.pab)), PRB $(length(o.prb)), W $(round(o.W, digits=1)), best gap $(round(gap(), digits=1))")
    cols = Dict{String,Int}(); errors = String[]
    ncb = Ref(0); nrows = Ref(0); stopped = Ref(false)
    function handle(pout, pin)
        ncb[] += 1
        if stopped[]
            c0 = Int32[first(values(cols))]
            ccall(fptr, Int32, (Ptr{Cvoid}, Int32, Int32, Ptr{Int32}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}),
                pin, 1, 1, Int32[0], c0, [1.0], [2.0], [Inf])
            return nothing
        end
        d = unsafe_load(Ptr{H.HighsCallbackDataOut}(pout))
        x = unsafe_wrap(Array, d.mip_solution, d.mip_solution_size)
        A = Set{String}(f for (f, c) in cols if x[c+1] > 0.5)
        o = get(seen, A, nothing)
        if o === nothing
            o = _r1_fixed(order_book, solve, A, B; preferred_solver=preferred_solver)
            calls[] += 1; seen[A] = o; note(o); trace("callback", o)
        end
        if o.ok && !isempty(o.pab)
            st = Int32[]; ix = Int32[]; va = Float64[]; lo = Float64[]; up = Float64[]
            for b in sort(collect(keys(o.pab)))
                zb = zone_of[b]; na = 0
                push!(st, length(ix)); push!(ix, cols[b]); push!(va, 1.0)
                for f in sort(collect(keys(zone_of)))
                    (zone_of[f] == zb && f != b) || continue
                    push!(ix, cols[f])
                    if f in A
                        push!(va, 1.0); na += 1
                    else
                        push!(va, -1.0)
                    end
                end
                push!(lo, -Inf); push!(up, Float64(na))
            end
            ccall(fptr, Int32, (Ptr{Cvoid}, Int32, Int32, Ptr{Int32}, Ptr{Int32}, Ptr{Float64}, Ptr{Float64}, Ptr{Float64}),
                pin, length(lo), length(ix), st, ix, va, lo, up) == 0 || push!(errors, "addCallbackLazyConstraints failed")
            nrows[] += length(lo)
        end
        (calls[] >= maxcb || gap() <= gap_stop) && (stopped[] = true)
        return nothing
    end
    pre = function (model, z)
        z === nothing && return
        set_optimizer_attribute(model, "mip_rel_gap", 1e-7)
        JuMP.MOIU.attach_optimizer(model)
        inner = JuMP.unsafe_backend(model)
        idxmap = JuMP.backend(model).model_to_optimizer_map
        for f in axes(z, 1)
            cols[f] = Int(H.column(inner, idxmap[JuMP.index(z[f])]))
        end
        inner.callback_data = H._CallbackData((args...) -> 0)   # keep HiGHS.jl's default callback off
        cfn = @cfunction(_bl_cfn, Cvoid, (Cint, Ptr{Cchar}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
        H.Highs_setCallback(inner, cfn, C_NULL) == 0 || error("Highs_setCallback failed")
        H.Highs_startCallback(inner, Int32(8)) == 0 || error("Highs_startCallback(8) failed")
        return
    end
    _BL_CTX[] = (handle=handle, errors=errors)
    try
        resolve_complex_orders(order_book; preferred_solver=preferred_solver, verbose=verbose,
            pre_optimize=pre, block_time_limit=3600.0)
    finally
        _BL_CTX[] = nothing
    end
    lazy_calls = calls[]
    nins = 0
    path = "lazy"
    if best[] !== nothing && !stop()
        path = "lazy+r1"
        _, nins = _r1_reinsert(order_book, solve, B, best[], calls, max_calls, stop, note, trace;
            preferred_solver=preferred_solver)
    end
    wall = time() - t0
    if best[] === nothing
        verbose && println("   🧱 LAZY: no PAB-free set in $(calls[]) pricing solves — using the R1 path")
        res = solve_with_r1(order_book, solve; preferred_solver=preferred_solver, verbose=verbose)
        R1_LAST[] = merge(something(R1_LAST[], Dict{String,Any}()), Dict("path" => "lazy->" * get(R1_LAST[], "path", "r1")))
        return res
    end
    o = best[]
    LAST_COMPLEX_INFO[] = o.info
    nprb = length(o.prb); prb_eur = sum(values(o.prb); init=0.0)
    R1_LAST[] = Dict("path" => path, "calls" => calls[], "lazy_calls" => lazy_calls, "callbacks" => ncb[],
        "lazy_rows" => nrows[], "wall" => wall, "UB" => UB[], "W" => o.W, "gap" => UB[] - o.W,
        "n_accepted" => length(o.A), "n_prb" => nprb, "prb_eur" => prb_eur, "inserted" => nins,
        "errors" => first(errors, 10))
    verbose && println("   🧱 LAZY summary: path=$path, pricing solves $(calls[]) (in-tree $lazy_calls, " *
                       "$(nrows[]) lazy rows), wall $(round(wall, digits=1)) s, accepted $(length(o.A)), " *
                       "W $(round(o.W, digits=1)), gap to UB $(round(UB[] - o.W, digits=1)) €, PRB $nprb / $(round(prb_eur, digits=0)) €")
    return o.res
end
