# lp_certificate.jl — the LP certificate that solves an MPCC without branch-and-bound (cv46).
# Included by ../MPCC.jl inside `module MPCC`; called by `solve_mpcc_market_clearing` right
# before its optimize!.
#
# 1. Welfare LP: a copy of the MPCC with every price-side object removed (stepwise_dual,
#    market_price, congestion rents, all complementarity binaries, and every row touching
#    them). What remains is exactly the primal welfare problem — acceptances ≤ 1, ATC bounds,
#    JAO net-position rows, nodal balance with shed, same objective — so its optimum is an
#    upper bound on the MPCC welfare.
# 2. Pattern: each complementarity binary is set by rule from the LP dispatch (order rejected /
#    partially / fully accepted; link at its forward / backward cap) and fixed. The MPCC with
#    fixed binaries is an LP; if it is optimal at the welfare-LP objective, the MPCC is solved
#    to optimality and the caller skips its MIP solve.
# 3. Otherwise the binaries are unfixed and the pattern (with the best values at hand) becomes
#    the MIP start. The caller then solves the MIP; only if that MIP fails do its retry ladder
#    (solver.jl) and the per-period HiGHS rungs (`_solve_mpcc_by_period`) run.
#
# Time: the welfare LP gets the caller's `time_limit`, the fixed-pattern solve what is left of
# it, and the caller gives the fallback MIP the remainder. An exception anywhere in here is
# caught by `_lp_certify_guarded!`, which unfixes the pattern so the MIP runs on the full model.
#
# Evidence (cv45 record, docs/experiments/lp-certificate.md): 0 fallbacks in 41,614 period
# solves; prices equal to the MIP-first record except 5 equal-welfare tie cells.

"""Per-process counts of certified / fallen-back MPCC solves (read by the decomposition driver's log line)."""
const LP_CERT_COUNTS = Ref((certified=0, fallback=0))

const _PRICE_SIDE = (:stepwise_dual, :market_price, :congestion_fw, :congestion_bw,
    :stepwise_acceptance_complementarity_aux, :stepwise_dual_complementarity_aux,
    :congestion_fw_aux, :congestion_bw_aux)

"""
    _lp_certify!(model, optimizer; time_limit=Inf) -> Bool

Try to solve the MPCC `model` by the LP certificate. `true`: `model` holds an optimal
solution (binaries fixed to the certified pattern). `false`: `model` is unchanged except for
MIP start values; the caller must solve it. `time_limit` (s) bounds the welfare LP and the
fixed-pattern solve together.
"""
function _lp_certify!(model::Model, optimizer; time_limit::Real=Inf)
    t0 = time()
    obj = object_dictionary(model)
    price_side = Set{VariableRef}(v for nm in _PRICE_SIDE if haskey(obj, nm) for v in model[nm])

    # 1. welfare LP
    lp, refmap = copy_model(model)
    set_optimizer(lp, optimizer)
    set_silent(lp)
    isfinite(time_limit) && set_time_limit_sec(lp, Float64(time_limit))
    kill = Set(refmap[v] for v in price_side)
    for (F, S) in list_of_constraint_types(lp)
        F <: AffExpr || continue
        for c in all_constraints(lp, F, S)
            any(v -> v in kill, keys(constraint_object(c).func.terms)) && delete(lp, c)
        end
    end
    delete(lp, collect(kill))
    optimize!(lp)
    termination_status(lp) == MOI.OPTIMAL || return false
    lp_obj = objective_value(lp)
    x = Dict{VariableRef,Float64}(v => value(refmap[v]) for v in all_variables(model)
                                  if !(v in price_side))

    # 2. pattern from the LP dispatch
    tol_a, tol_f = 1e-9, 1e-6
    pattern = Dict{VariableRef,Float64}()
    acc = model[:stepwise_acceptance]
    aux1 = model[:stepwise_acceptance_complementarity_aux]
    aux2 = model[:stepwise_dual_complementarity_aux]
    for k in eachindex(acc)
        a = x[acc[k]]
        pattern[aux1[k]] = a > tol_a ? 1.0 : 0.0          # accepted at all  ⇒ surplus row tight
        pattern[aux2[k]] = a >= 1 - tol_a ? 1.0 : 0.0     # fully accepted   ⇒ may carry surplus
    end
    if haskey(obj, :congestion_fw_aux)
        fl = model[:flow]
        fwa, bwa = model[:congestion_fw_aux], model[:congestion_bw_aux]
        for k in eachindex(fwa)
            f = x[fl[k]]
            pattern[fwa[k]] = has_upper_bound(fl[k]) && f >= upper_bound(fl[k]) - tol_f ? 1.0 : 0.0
            pattern[bwa[k]] = has_lower_bound(fl[k]) && f <= lower_bound(fl[k]) + tol_f ? 1.0 : 0.0
        end
    end
    for (v, b) in pattern
        fix(v, b; force=true)
    end
    isfinite(time_limit) && set_time_limit_sec(model, max(time_limit - (time() - t0), 1.0))
    optimize!(model)
    if termination_status(model) == MOI.OPTIMAL &&
       abs(objective_value(model) - lp_obj) <= 1e-7 * max(1.0, abs(lp_obj))
        return true
    end

    # 3. fall back: unfix, hand the pattern to the MIP as a start
    start = has_values(model) ? Dict(v => value(v) for v in all_variables(model)) : merge(x, pattern)
    for v in keys(pattern)
        unfix(v)
    end
    for (v, s) in start
        set_start_value(v, s)
    end
    return false
end

"""Unfix every complementarity binary of `model` that is currently fixed (the certificate's pattern)."""
function _unfix_pattern!(model::Model)
    obj = object_dictionary(model)
    for nm in (:stepwise_acceptance_complementarity_aux, :stepwise_dual_complementarity_aux,
               :congestion_fw_aux, :congestion_bw_aux)
        haskey(obj, nm) || continue
        for v in model[nm]
            is_fixed(v) && unfix(v)
        end
    end
    return nothing
end

"""
    _lp_certify_guarded!(model, optimizer; time_limit=Inf) -> Bool

`_lp_certify!` that never throws: on an exception it warns, unfixes the pattern and returns
`false`, so the caller solves the full MIP as before the certificate existed.
"""
function _lp_certify_guarded!(model::Model, optimizer; time_limit::Real=Inf)
    try
        return _lp_certify!(model, optimizer; time_limit=time_limit)
    catch e
        e isa InterruptException && rethrow()
        @warn "LP certificate raised — solving the MIP instead" exception = (e, catch_backtrace())
        _unfix_pattern!(model)
        return false
    end
end
