# lp_certificate.jl — research-only (highs-blocks M1): LP-derived certificate /
# MIP start for one MPCC solve. Included by ../MPCC.jl inside `module MPCC`.
#
# Off unless EUPHEMIA_MPCC_LP_CERT is set (then `solve_mpcc_market_clearing`
# calls `_lp_certify!` right before its optimize!); the default path never
# reaches this file.
#
# 1. Welfare LP: a copy of the MPCC with every price-side object removed
#    (stepwise_dual, market_price, congestion rents, all complementarity
#    binaries, and every row touching them). What remains is exactly the
#    primal welfare problem: acceptances ≤ 1, ATC bounds, JAO net-position rows,
#    nodal balance with shed, same objective. Its optimum is an upper bound on
#    the MPCC welfare.
# 2. Pattern: each complementarity binary is set by rule from the LP dispatch
#    (order rejected / partial / full; link at its forward / backward cap) and
#    fixed. The MPCC with fixed binaries is an LP. If it is feasible with the
#    welfare-LP objective, the MPCC is solved to optimality without
#    branch-and-bound (certificate) and the caller skips its own optimize!.
# 3. Otherwise the binaries are unfixed and the pattern + LP values are handed to
#    the MIP as a start.

"""Per-solve M1 diagnostics (research). Appended per call while LP_CERT_LOG[] isa Vector."""
const LP_CERT_LOG = Ref{Any}(nothing)

import JSON

"""`:off` (unset/0/off), `:shadow`, or `:on` (any other value, e.g. `1`)."""
function lp_cert_mode()
    v = lowercase(strip(get(ENV, "EUPHEMIA_MPCC_LP_CERT", "")))
    v in ("", "0", "off", "false") && return :off
    return v == "shadow" ? :shadow : :on
end
lp_cert_enabled() = lp_cert_mode() !== :off

"""Research context for the per-period JSONL (day/pass/round/call), set by the
decomposition driver and the complex-order loop only when the flag is on."""
const CERT_CTX = Dict{String,Any}()
_cert_day(periods) = first(first(periods), 8)

function _lp_certify!(model::Model, optimizer)
    t0 = time()
    price_side = Set{VariableRef}()
    for nm in (:stepwise_dual, :market_price, :congestion_fw, :congestion_bw,
               :stepwise_acceptance_complementarity_aux, :stepwise_dual_complementarity_aux,
               :congestion_fw_aux, :congestion_bw_aux)
        haskey(object_dictionary(model), nm) || continue
        for v in model[nm]
            push!(price_side, v)
        end
    end
    lp, refmap = copy_model(model)
    set_optimizer(lp, optimizer)
    set_silent(lp)
    kill_lp = Set(refmap[v] for v in price_side)
    for (F, S) in list_of_constraint_types(lp)
        F <: AffExpr || continue
        for c in all_constraints(lp, F, S)
            f = constraint_object(c).func
            any(v -> v in kill_lp, keys(f.terms)) && delete(lp, c)
        end
    end
    delete(lp, collect(kill_lp))
    optimize!(lp)
    t_lp = time() - t0
    info = Dict{String,Any}("lp_status" => string(termination_status(lp)), "lp_secs" => t_lp)
    if termination_status(lp) != MOI.OPTIMAL
        info["outcome"] = "fallback"; info["reason"] = "lp_status"
        return (false, info)
    end
    # diagnostics: JAO net-position rows (the only Interval rows left) at a bound,
    # shed in use
    n_np = 0; n_np_act = 0
    for (F, S) in list_of_constraint_types(lp)
        (F <: AffExpr && S <: MOI.Interval) || continue
        for c in all_constraints(lp, F, S)
            n_np += 1
            v = value(c); set = constraint_object(c).set
            (v <= set.lower + 1e-6 || v >= set.upper - 1e-6) && (n_np_act += 1)
        end
    end
    info["n_np_rows"] = n_np; info["n_np_active"] = n_np_act
    info["n_shed"] = haskey(object_dictionary(lp), :load_shed) ?
        count(v -> value(v) > 1e-6, lp[:load_shed]) : 0
    lp_obj = objective_value(lp)
    info["lp_obj"] = lp_obj
    xval = Dict{VariableRef,Float64}()
    for v in all_variables(model)
        v in price_side && continue
        xval[v] = value(refmap[v])
    end

    # Pattern from the LP dispatch.
    tol_a = 1e-9; tol_f = 1e-6
    pattern = Dict{VariableRef,Float64}()
    acc = model[:stepwise_acceptance]
    aux1 = model[:stepwise_acceptance_complementarity_aux]
    aux2 = model[:stepwise_dual_complementarity_aux]
    n_part = 0
    for k in eachindex(acc)
        a = xval[acc[k]]
        pattern[aux1[k]] = a > tol_a ? 1.0 : 0.0
        pattern[aux2[k]] = a >= 1 - tol_a ? 1.0 : 0.0
        (tol_a < a < 1 - tol_a) && (n_part += 1)
    end
    info["n_partial"] = n_part
    if haskey(object_dictionary(model), :flow)
        fl = model[:flow]
        fwa = model[:congestion_fw_aux]; bwa = model[:congestion_bw_aux]
        for k in eachindex(fwa)
            f = xval[fl[k]]
            fwa_v = has_upper_bound(fl[k]) && f >= upper_bound(fl[k]) - tol_f
            bwa_v = has_lower_bound(fl[k]) && f <= lower_bound(fl[k]) + tol_f
            pattern[fwa[k]] = fwa_v ? 1.0 : 0.0
            pattern[bwa[k]] = bwa_v ? 1.0 : 0.0
        end
    end
    for (v, b) in pattern
        fix(v, b; force=true)
    end
    t1 = time()
    optimize!(model)
    info["fixed_secs"] = time() - t1
    st = termination_status(model)
    info["fixed_status"] = string(st)
    certified = st == MOI.OPTIMAL &&
        abs(objective_value(model) - lp_obj) <= 1e-7 * max(1.0, abs(lp_obj))
    if certified
        info["outcome"] = "certified"
        info["fixed_obj"] = objective_value(model)
    else
        info["reason"] = st == MOI.OPTIMAL ? "obj_mismatch" :
            st in (MOI.INFEASIBLE, MOI.INFEASIBLE_OR_UNBOUNDED) ? "pattern_infeasible" :
            "fixed_status"
        st == MOI.OPTIMAL && (info["obj_rel_gap"] = abs(objective_value(model) - lp_obj) / max(1.0, abs(lp_obj)))
        # Hand the pattern (and the best values we have) to the MIP as a start.
        st == MOI.OPTIMAL && (info["fixed_obj"] = objective_value(model))
        start = Dict{VariableRef,Float64}()
        if has_values(model)
            for v in all_variables(model)
                start[v] = value(v)
            end
        else
            merge!(start, xval, pattern)
        end
        for v in keys(pattern)
            unfix(v)
        end
        for (v, x) in start
            set_start_value(v, x)
        end
        info["outcome"] = "fallback"
    end
    info["total_secs"] = time() - t0
    return (certified, info)
end

function _lp_certify_safe!(model::Model, optimizer)
    try
        return _lp_certify!(model, optimizer)
    catch e
        e isa InterruptException && rethrow()
        @warn "LP certificate raised — MIP path" exception = (e, catch_backtrace())
        return (false, Dict{String,Any}("outcome" => "fallback", "reason" => "error",
                                        "error" => sprint(showerror, e)))
    end
end

# Shadow mode: certificate on a COPY, so the caller's MIP runs untouched.
function _lp_certify_shadow(model::Model, optimizer, silent::Bool, time_limit, mip_gap)
    t = time()
    mc, rmap = copy_model(model)
    set_optimizer(mc, optimizer)
    set_silent(mc)
    set_time_limit_sec(mc, time_limit)
    ok, info = _lp_certify_safe!(mc, optimizer)
    info["cert_s"] = time() - t
    return (ok=ok, info=info, mc=mc, rmap=rmap)
end

# One JSONL line per MPCC solve (+ the per-call accumulator the decomposition
# driver prints). Never throws.
function _lp_cert_record!(info, shadow, model, book, mip_prices, zone_pairs, flow_caps,
                          orders_by_node_time, simple_orders, order_ids, acc, flow, mp)
    try
        mode = lp_cert_mode()
        day = _cert_day(book.periods)
        line = Dict{String,Any}("day" => day, "pid" => getpid(), "mode" => string(mode),
            "pass" => get(CERT_CTX, "pass_" * day, 0), "round" => get(CERT_CTX, "round", 0),
            "call" => get(CERT_CTX, "seq_" * day, 0), "period" => join(book.periods, ","))
        for k in ("outcome", "reason", "cert_s", "mip_s", "lp_secs", "fixed_secs", "n_partial",
                  "n_np_rows", "n_np_active", "n_shed", "lp_obj", "fixed_obj", "obj_rel_gap",
                  "lp_status", "fixed_status", "error")
            haskey(info, k) && (line[k] = info[k])
        end
        haskey(line, "cert_s") || (line["cert_s"] = get(info, "total_secs", NaN))
        line["mip_status"] = string(termination_status(model))
        line["obj_mip"] = has_values(model) ? objective_value(model) : NaN
        if shadow !== nothing && shadow.ok && mip_prices !== nothing
            rmap = shadow.rmap
            sacc = Dict{String,Float64}(oid => value(rmap[acc[oid]]) for oid in order_ids)
            sflow = Dict{Tuple{Tuple{String,String},String},Float64}()
            if flow !== nothing && !isempty(zone_pairs)
                for pair in zone_pairs, t in book.periods
                    sflow[(pair, t)] = value(rmap[flow[pair, t]])
                end
            end
            sraw = Dict{String,Dict{String,Float64}}(z => Dict{String,Float64}(
                t => value(rmap[mp[z, t]]) for t in book.periods) for z in book.nodes)
            srec = _reconstruct_component_prices(book.nodes, book.periods, zone_pairs, sflow,
                flow_caps, orders_by_node_time, simple_orders, order_ids, sacc,
                book.price_limits, sraw)
            n = 0; nid = 0; mx = 0.0
            for z in book.nodes, t in book.periods
                a = mip_prices[z][t]; b = srec.prices[z][t]
                n += 1; a == b && (nid += 1); mx = max(mx, abs(a - b))
            end
            line["n_cells"] = n; line["n_identical"] = nid; line["max_abs_dprice"] = mx
            line["obj_cert"] = objective_value(shadow.mc)
        end
        a = get!(CERT_CTX, "acc", Dict{String,Any}())
        a["n"] = get(a, "n", 0) + 1
        key = line["outcome"] == "certified" ? "certified" : "fallback:" * get(line, "reason", "?")
        a[key] = get(a, key, 0) + 1
        a["cells"] = get(a, "cells", 0) + get(line, "n_cells", 0)
        a["identical"] = get(a, "identical", 0) + get(line, "n_identical", 0)
        a["cert_s"] = get(a, "cert_s", 0.0) + (isnan(line["cert_s"]) ? 0.0 : line["cert_s"])
        a["mip_s"] = get(a, "mip_s", 0.0) + get(line, "mip_s", 0.0)
        a["max_abs_dprice"] = max(get(a, "max_abs_dprice", 0.0), get(line, "max_abs_dprice", 0.0))
        dir = get(ENV, "EUPHEMIA_MPCC_LP_CERT_LOG", "")
        if !isempty(dir)
            mkpath(dir)
            open(joinpath(dir, "cert-$(getpid()).jsonl"), "a") do io
                println(io, JSON.json(line))
            end
        end
    catch e
        e isa InterruptException && rethrow()
        @warn "LP-cert record failed" exception = (e, catch_backtrace())
    end
    return nothing
end

function _lp_cert_call_begin!(periods)
    day = _cert_day(periods)
    CERT_CTX["seq_" * day] = get(CERT_CTX, "seq_" * day, 0) + 1
    CERT_CTX["acc"] = Dict{String,Any}()
end

function _lp_cert_call_end!(periods)
    a = get(CERT_CTX, "acc", Dict{String,Any}())
    day = _cert_day(periods)
    fb = join(["$(k[10:end])=$(v)" for (k, v) in sort(collect(a)) if startswith(k, "fallback:")], ",")
    println("   🧾 LP-CERT($(lp_cert_mode())) day=$day pass=$(get(CERT_CTX, "pass_" * day, 0)) " *
            "round=$(get(CERT_CTX, "round", 0)) call=$(get(CERT_CTX, "seq_" * day, 0)): " *
            "certified $(get(a, "certified", 0))/$(get(a, "n", 0))" *
            (isempty(fb) ? "" : " fallback[$fb]") *
            (lp_cert_mode() === :shadow ? ", identical cells $(get(a, "identical", 0))/$(get(a, "cells", 0)) " *
                "(max |dp| $(get(a, "max_abs_dprice", 0.0)))" : "") *
            ", cert $(round(get(a, "cert_s", 0.0), digits=2)) s vs MIP $(round(get(a, "mip_s", 0.0), digits=2)) s")
end
