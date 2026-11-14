using Euphemia, Dates
const MOB = Euphemia.MeritOrderBook
for z in ARGS[2:end]
    for flag in ("", "1")
        ENV["EUPHEMIA_INMERIT_TRUTH"] = flag
        cap = Ref{Any}(nothing)
        MOB.BOOK_SINK[] = (zone, day, tagged, res, strat) -> (cap[] = tagged)
        MOB.create_merit_order_book(z, Date(ARGS[1]); profile=MOB.get_zone_profile(z))
        hc = Dict{String,Float64}()
        n = length(unique(o.date_time for (o, _) in cap[]))
        for (o, own) in cap[]
            o.type == :supply || continue
            k = occursin("Hard_coal", own) ? "hc_agg" : own
            hc[k] = get(hc, k, 0.0) + o.quantity / n
        end
        println("RESULT $z flag=$(flag) total_supply=$(round(Int, sum(values(hc)))) hc_agg=$(round(Int, get(hc, "hc_agg", 0.0)))")
    end
end
