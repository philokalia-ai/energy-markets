# Strategy 6 — SHARE-PROPORTIONAL MARKUP (Cournot / Lerner).
# The optimal static markup for a Cournot player is (Lerner index) = share /
# elasticity: the bigger your hourly supply share, the more you mark up. We
# compute the big firm's supply share per timeslot and apply markup =
# clamp(share / elasticity, 0, cap) to its orders that hour. This makes the
# markup endogenous and time-varying rather than a hand-set constant.
#
# factory: share_proportional(; elasticity=1.5, cap=0.6) -> (day -> strategist)

share_proportional(; elasticity::Float64=1.5, cap::Float64=0.6) = (_day::Date) -> (ctx -> begin
    bigq = Dict{String,Float64}(); totq = Dict{String,Float64}()
    for (o, tag) in ctx.tagged_orders
        is_supply(o) || continue
        ts = ts_of(o)
        totq[ts] = get(totq, ts, 0.0) + o.quantity
        is_big(ctx.firm_of, tag) && (bigq[ts] = get(bigq, ts, 0.0) + o.quantity)
    end
    markup = Dict(ts => clamp((get(bigq, ts, 0.0) / max(totq[ts], 1e-6)) / elasticity,
                              0.0, cap) for ts in keys(totq))
    [(is_supply(o) && is_big(ctx.firm_of, tag) ?
        bump(o, 1 + get(markup, ts_of(o), 0.0)) : o, tag)
     for (o, tag) in ctx.tagged_orders]
end)

if abspath(PROGRAM_FILE) == @__FILE__
    include(joinpath(@__DIR__, "common.jl"))
    acc = run_matrix(["baseline" => nothing,
                      "share_e2.0" => share_proportional(elasticity=2.0),
                      "share_e1.0" => share_proportional(elasticity=1.0)])
    print_table(summarize(acc))
end
