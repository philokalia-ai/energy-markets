# Strategy 3 — PIVOTAL MARKUP (exercise power only when needed).
# Textbook market power: the incumbent marks up only in hours where it is
# PIVOTAL — i.e. the rest of the market cannot cover demand without it
# (Residual Supply Index < 1). In non-pivotal hours it bids at cost, because a
# markup there just loses volume. Pivotality is computed per timeslot from the
# book itself: non-big supply capacity (RES + imports + rivals) vs demand.
#
# factory: pivotal_markup(; markup=0.30, rsi_thresh=1.0) -> (day -> strategist)

pivotal_markup(; markup::Float64=0.30, rsi_thresh::Float64=1.0) = (_day::Date) -> (ctx -> begin
    # per timeslot: non-big supply capacity, big-firm supply capacity, demand
    nonbig = Dict{String,Float64}(); big = Dict{String,Float64}()
    for (o, tag) in ctx.tagged_orders
        is_supply(o) || continue
        ts = ts_of(o)
        if is_big(ctx.firm_of, tag)
            big[ts] = get(big, ts, 0.0) + o.quantity
        else
            nonbig[ts] = get(nonbig, ts, 0.0) + o.quantity
        end
    end
    # demand per timeslot from load_by_time (net demand already reflected in book;
    # use gross load as the requirement the fleet must meet)
    demand(ts) = get(ctx.load_by_time, ts, 0.0)
    # pivotal iff non-big supply < rsi_thresh × demand
    pivotal = Dict(ts => get(nonbig, ts, 0.0) < rsi_thresh * demand(ts)
                   for ts in keys(big))
    [(is_supply(o) && is_big(ctx.firm_of, tag) && get(pivotal, ts_of(o), false) ?
        bump(o, 1 + markup) : o, tag)
     for (o, tag) in ctx.tagged_orders]
end)

if abspath(PROGRAM_FILE) == @__FILE__
    include(joinpath(@__DIR__, "common.jl"))
    acc = run_matrix(["baseline" => nothing,
                      "pivotal_30%" => pivotal_markup(markup=0.30),
                      "pivotal_50%" => pivotal_markup(markup=0.50)])
    print_table(summarize(acc))
end
