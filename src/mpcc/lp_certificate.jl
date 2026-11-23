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
#    the MIP start. The caller then solves the MIP; only if that MIP fails do the per-period
#    HiGHS retry rungs (`_solve_mpcc_by_period`) run.
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
    _WelfareSource(inner, drop)

A read-only view of the MOI model `inner` without the variables in `drop` and without every constraint
whose function touches one of them. `MOI.copy_to(dest, src)` from this view builds the welfare LP in one
pass: the kept variables and rows arrive in the same relative order as in `inner`, so the result is the
model that copying everything and then deleting those rows and variables gives (identical MPS), without
the per-row deletes and the vector variable delete (whose first call compiled for ~75 s per process).
"""
struct _WelfareSource{T} <: MOI.ModelLike
    inner::T
    drop::Set{MOI.VariableIndex}
end
_touches(s::_WelfareSource, f::MOI.VariableIndex) = f in s.drop
_touches(s::_WelfareSource, f::MOI.VectorOfVariables) = any(in(s.drop), f.variables)
_touches(s::_WelfareSource, f::MOI.ScalarAffineFunction) = any(t -> t.variable in s.drop, f.terms)
_touches(::_WelfareSource, f::MOI.AbstractFunction) =
    error("welfare LP: unsupported constraint function $(typeof(f))")
MOI.get(s::_WelfareSource, ::MOI.ListOfVariableIndices) =
    filter(v -> !(v in s.drop), MOI.get(s.inner, MOI.ListOfVariableIndices()))
MOI.get(s::_WelfareSource, ::MOI.NumberOfVariables) = length(MOI.get(s, MOI.ListOfVariableIndices()))
MOI.get(s::_WelfareSource, attr::MOI.ListOfConstraintIndices) =
    filter(ci -> !_touches(s, MOI.get(s.inner, MOI.ConstraintFunction(), ci)), MOI.get(s.inner, attr))
MOI.get(s::_WelfareSource, ::MOI.NumberOfConstraints{F,S}) where {F,S} =
    length(MOI.get(s, MOI.ListOfConstraintIndices{F,S}()))
MOI.get(s::_WelfareSource, ::MOI.ListOfConstraintTypesPresent) =
    [(F, S) for (F, S) in MOI.get(s.inner, MOI.ListOfConstraintTypesPresent())
     if !isempty(MOI.get(s, MOI.ListOfConstraintIndices{F,S}()))]
MOI.get(s::_WelfareSource, attr::MOI.AbstractModelAttribute) = MOI.get(s.inner, attr)
MOI.get(s::_WelfareSource, attr::MOI.AbstractVariableAttribute, x::MOI.VariableIndex) = MOI.get(s.inner, attr, x)
MOI.get(s::_WelfareSource, attr::MOI.AbstractConstraintAttribute, ci::MOI.ConstraintIndex) =
    MOI.get(s.inner, attr, ci)
MOI.is_empty(s::_WelfareSource) = MOI.is_empty(s.inner)

"""
    _welfare_lp(model, price_side) -> (lp, refmap)

The welfare LP: a new JuMP model holding `model` without the `price_side` variables and every row that
touches them, built by one `MOI.copy_to` from a `_WelfareSource`. `refmap[v]` is the copy of each kept
variable `v`.
"""
function _welfare_lp(model::Model, price_side::Set{VariableRef})
    lp = Model()
    src = _WelfareSource(backend(model), Set{MOI.VariableIndex}(index(v) for v in price_side))
    imap = MOI.copy_to(backend(lp), src)
    refmap = Dict{VariableRef,VariableRef}(v => VariableRef(lp, imap[index(v)])
                                           for v in all_variables(model) if !(v in price_side))
    return lp, refmap
end

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
    lp, refmap = _welfare_lp(model, price_side)
    set_optimizer(lp, optimizer)
    set_silent(lp)
    isfinite(time_limit) && set_time_limit_sec(lp, Float64(time_limit))
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
