# Strategy 7 — PEAK-HOUR MARKUP (temporal targeting).
# Market power is easiest to exercise when demand is high and the fleet is
# tight. The incumbent marks up its supply only in the `topk` highest-load hours
# of the day and bids at cost otherwise — a coarse, purely time-of-day version
# of the pivotal strategy that needs no capacity accounting.
#
# factory: peak_hour_markup(; markup=0.30, topk=6) -> (day -> strategist)

peak_hour_markup(; markup::Float64=0.30, topk::Int=6) = (_day::Date) -> (ctx -> begin
    # rank timeslots by gross load, take the topk
    tss = collect(keys(ctx.load_by_time))
    order = sort(tss, by=ts -> -get(ctx.load_by_time, ts, 0.0))
    peak = Set(order[1:min(topk, length(order))])
    [(is_supply(o) && is_big(ctx.firm_of, tag) && ts_of(o) in peak ?
        bump(o, 1 + markup) : o, tag)
     for (o, tag) in ctx.tagged_orders]
end)

if abspath(PROGRAM_FILE) == @__FILE__
    include(joinpath(@__DIR__, "common.jl"))
    acc = run_matrix(["baseline" => nothing,
                      "peak6_30%" => peak_hour_markup(markup=0.30, topk=6),
                      "peak10_30%" => peak_hour_markup(markup=0.30, topk=10)])
    print_table(summarize(acc))
end
