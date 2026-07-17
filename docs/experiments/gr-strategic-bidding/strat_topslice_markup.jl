# Strategy 2 — TOP-SLICE MARKUP (realistic portfolio bidding).
# A rational incumbent bids its baseload/must-run tranches near cost (it wants
# them to run) and marks up only its FLEXIBLE upper tranches — the ones that set
# the price in tight hours. Per big-firm unit and hour, we mark up only the
# tranches priced above `slice_from` × the unit's own cheapest tranche that hour.
#
# factory: topslice_markup(; markup=0.25, slice_from=1.10) -> (day -> strategist)

topslice_markup(; markup::Float64=0.25, slice_from::Float64=1.10) = (_day::Date) -> (ctx -> begin
    # cheapest tranche price per (unit tag, timeslot) among big-firm supply
    minp = Dict{Tuple{String,String},Float64}()
    for (o, tag) in ctx.tagged_orders
        (is_supply(o) && is_big(ctx.firm_of, tag)) || continue
        k = (tag, ts_of(o))
        minp[k] = min(get(minp, k, Inf), o.price)
    end
    out = Tuple{SimpleOrder,String}[]
    for (o, tag) in ctx.tagged_orders
        if is_supply(o) && is_big(ctx.firm_of, tag)
            base = get(minp, (tag, ts_of(o)), o.price)
            push!(out, (o.price > slice_from * base ? bump(o, 1 + markup) : o, tag))
        else
            push!(out, (o, tag))
        end
    end
    out
end)

if abspath(PROGRAM_FILE) == @__FILE__
    include(joinpath(@__DIR__, "common.jl"))
    acc = run_matrix(["baseline" => nothing,
                      "topslice_25%" => topslice_markup(markup=0.25),
                      "topslice_40%" => topslice_markup(markup=0.40)])
    print_table(summarize(acc))
end
