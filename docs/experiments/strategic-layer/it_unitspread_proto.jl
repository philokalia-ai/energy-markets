# IT flat-line fix, take 2 — PER-UNIT EFFICIENCY SPREAD.
# The marginal probe showed every gas unit's tranches price IDENTICALLY (one
# type-level SRMC), so the whole fleet forms one flat step and net load never
# leaves it. This prototype decorrelates unit costs via the strategist hook:
# every gas-unit supply order is scaled by a stable per-unit factor drawn from
# a ±8% efficiency spread (hash of the unit code — deterministic, day-stable).
#   SL_ZONE=IT-CSOUTH julia --project=. .../it_unitspread_proto.jl
include(joinpath(@__DIR__, "zone_common.jl"))
using Statistics, Printf

function unit_spread(spread::Float64)
    (_day::Date) -> (ctx -> begin
        out = Tuple{SimpleOrder,String}[]
        for (o, tag) in ctx.tagged_orders
            if o.type == :supply && !(tag in ("RES", "IMPORT", "DEMAND", "EXTRA", "STRATEGIST"))
                h = mod(hash(tag), 1000) / 1000.0          # stable in [0,1)
                f = 1.0 + spread * (2h - 1.0)               # 1±spread
                push!(out, (SimpleOrder(o.type, o.price * f, o.quantity, o.zone,
                    o.date_time, o.resolution_code), tag))
            else
                push!(out, (o, tag))
            end
        end
        out
    end)
end

alldays = Date(2023,7,15):Day(1):Date(2025,6,15)
pick = [d for (i,d) in enumerate(alldays) if i % max(1, length(alldays) ÷ 20) == 3][1:20]

function day_metrics(sim, day)
    c, m, r, n = eval_vs_actual(sim, day)
    hs = Dict{String,Vector{Float64}}()
    for (ts,p) in sim; push!(get!(hs, ts[1:9]*ts[10:11], Float64[]), p); end
    (corr=c, mae=m, resid=r, simstd=std([mean(v) for v in values(hs)]))
end

results = NamedTuple[]
for (i, day) in enumerate(pick)
    a = try clear_day(day) catch e; @warn "A failed" day e; continue; end
    SPREAD = parse(Float64, get(ENV, "SL_SPREAD", "0.08"))
    b = try clear_day(day; strategist=unit_spread(SPREAD)(day)) catch e; @warn "B failed" day e; continue; end
    ma, mb = day_metrics(a, day), day_metrics(b, day)
    push!(results, (day=day, a=ma, b=mb))
    @printf("[%2d/20] %s  stock: corr=%s mae=%.1f std=%.1f | spread: corr=%s mae=%.1f std=%.1f\n",
        i, day, ma.corr===missing ? "-" : round(ma.corr,digits=2), ma.mae, ma.simstd,
        mb.corr===missing ? "-" : round(mb.corr,digits=2), mb.mae, mb.simstd)
    flush(stdout)
end
ms(xs) = (v=Float64[x for x in xs if x !== missing]; isempty(v) ? NaN : mean(v))
println("\n=== $ZONE unit-spread ±$(get(ENV,"SL_SPREAD","0.08")) summary ($(length(results)) days) ===")
@printf("stock  : corr %.3f  MAE %.2f  sim-std %.1f\n", ms(r.a.corr for r in results), ms(r.a.mae for r in results), ms(r.a.simstd for r in results))
@printf("spread : corr %.3f  MAE %.2f  sim-std %.1f\n", ms(r.b.corr for r in results), ms(r.b.mae for r in results), ms(r.b.simstd for r in results))
println("MAE better on $(count(r -> r.b.mae < r.a.mae, results))/$(length(results)) days")
