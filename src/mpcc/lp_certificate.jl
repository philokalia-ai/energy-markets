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

lp_cert_enabled() = !isempty(get(ENV, "EUPHEMIA_MPCC_LP_CERT", ""))

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
        info["outcome"] = "lp_failed"
        return (false, info)
    end
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
        info["outcome"] = "start"
    end
    info["total_secs"] = time() - t0
    return (certified, info)
end
