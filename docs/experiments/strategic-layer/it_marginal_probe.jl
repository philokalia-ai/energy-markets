# Marginal-attribution probe: for one flat IT-CSOUTH day, capture the tagged
# book via a pass-through strategist, clear the baseline, and per hour list the
# supply orders whose price sits within ±0.5 € of the cleared price — who pins it?
#   SL_ZONE=IT-CSOUTH julia --project=. docs/experiments/strategic-layer/it_marginal_probe.jl
include(joinpath(@__DIR__, "zone_common.jl"))
using Printf
day = Date(2023, 7, 17)

captured = Ref{Vector{Tuple{SimpleOrder,String}}}(Tuple{SimpleOrder,String}[])
probe = ctx -> (captured[] = collect(ctx.tagged_orders); ctx.tagged_orders)
prices = clear_day(day; strategist=probe)
book = captured[]
println("book orders: ", length(book), "; cleared hours: ", length(prices))
supply = [(o, t) for (o, t) in book if o.type == :supply]

for hh in 0:23
    ts = Dates.format(DateTime(day) + Hour(hh), "yyyymmdd-HHMM")
    p = get(prices, ts, nothing); p === nothing && continue
    at = [(o, t) for (o, t) in supply if Dates.format(o.date_time, "yyyymmdd-HHMM") == ts &&
          abs(o.price - p) <= 0.5]
    below = sum(o.quantity for (o, t) in supply
                if Dates.format(o.date_time, "yyyymmdd-HHMM") == ts && o.price < p - 0.5; init=0.0)
    tags = join(unique([(@sprintf "%s@%.1f(%.0fMW)" t o.price o.quantity) for (o, t) in at])[1:min(end,4)], " | ")
    @printf("h%02d  clear=%7.2f  below=%6.0fMW  marginal: %s\n", hh, p, below, isempty(at) ? "NONE within ±0.5" : tags)
end
# price histogram of the supply book at noon
ts12 = Dates.format(DateTime(day) + Hour(12), "yyyymmdd-HHMM")
noon = sort([(o.price, o.quantity, t) for (o, t) in supply if Dates.format(o.date_time, "yyyymmdd-HHMM") == ts12])
println("\nnoon supply ladder (price, MW, tag) — first 25 distinct prices:")
seen = Set{Float64}()
for (p, q, t) in noon
    p in seen && continue; push!(seen, p)
    @printf("  %8.2f  %7.0f  %s\n", p, q, t)
    length(seen) >= 25 && break
end
