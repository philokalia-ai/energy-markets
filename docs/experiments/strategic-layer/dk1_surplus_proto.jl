# DK1 RES-surplus pricing prototype: in surplus hours the actual price falls
# far below the thermal band (export absorption / negative pricing) while the
# sim stays pinned at the thermal marginal. Prototype: an ELASTIC EXPORT
# LADDER — extra demand steps at 30/15/5 €/MWh (400 MW each) appended via the
# strategist, so surplus hours clear at the ladder instead of the thermal band.
#   SL_ZONE=DK1 julia --project=. docs/experiments/strategic-layer/dk1_surplus_proto.jl
include(joinpath(@__DIR__, "zone_common.jl"))
using Statistics, Printf

function surplus_ladder(steps::Vector{Tuple{Float64,Float64}})
    (_day::Date) -> (ctx -> begin
        out = collect(ctx.tagged_orders)
        # strategist ctx has NO resolution_minutes (only extra_orders ctx does);
        # referencing it throws and the zone is silently dropped. Take the
        # resolution from an existing order instead.
        res = isempty(ctx.tagged_orders) ? 60 : ctx.tagged_orders[1][1].resolution_code
        for ts in ctx.timeslots
            dt = DateTime(ts, dateformat"yyyymmdd-HHMM")
            for (price, mw) in steps
                push!(out, (SimpleOrder(:demand, price, mw, Symbol(ctx.zone), dt,
                    res), "EXTRA"))
            end
        end
        out
    end)
end

alldays = Date(2023,7,15):Day(1):Date(2025,6,15)
pick = [d for (i,d) in enumerate(alldays) if i % max(1, length(alldays) ÷ 20) == 3][1:20]
function dm(sim, day)
    c, m, r, n = eval_vs_actual(sim, day)
    hs = Dict{String,Vector{Float64}}()
    for (ts,p) in sim; push!(get!(hs, ts[1:9]*ts[10:11], Float64[]), p); end
    (corr=c, mae=m, resid=r, simstd=std([mean(v) for v in values(hs)]))
end
LADDER = [(30.0, 400.0), (15.0, 400.0), (5.0, 400.0)]
results = NamedTuple[]
for (i, day) in enumerate(pick)
    a = try clear_day(day) catch e; @warn "A failed" day e; continue; end
    b = try clear_day(day; strategist=surplus_ladder(LADDER)(day)) catch e; @warn "B failed" day e; continue; end
    ma, mb = dm(a, day), dm(b, day)
    (ma.mae === missing || mb.mae === missing) && (@warn "skipping day with <12 paired hours" day; continue)
    push!(results, (a=ma, b=mb))
    @printf("[%2d/20] %s  stock: corr=%s mae=%.1f std=%.1f | ladder: corr=%s mae=%.1f std=%.1f\n",
        i, day, ma.corr===missing ? "-" : round(ma.corr,digits=2), ma.mae, ma.simstd,
        mb.corr===missing ? "-" : round(mb.corr,digits=2), mb.mae, mb.simstd)
    flush(stdout)
end
ms(xs) = (v=Float64[x for x in xs if x !== missing]; isempty(v) ? NaN : mean(v))
println("\n=== DK1 surplus-ladder summary ($(length(results)) days) ===")
@printf("stock  : corr %.3f  MAE %.2f  std %.1f\n", ms(r.a.corr for r in results), ms(r.a.mae for r in results), ms(r.a.simstd for r in results))
@printf("ladder : corr %.3f  MAE %.2f  std %.1f\n", ms(r.b.corr for r in results), ms(r.b.mae for r in results), ms(r.b.simstd for r in results))
println("MAE better on $(count(r -> r.b.mae < r.a.mae, results))/$(length(results)) days")
println("DONE")
