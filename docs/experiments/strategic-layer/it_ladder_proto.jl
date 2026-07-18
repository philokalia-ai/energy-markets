# IT flat-line fix prototype (docs/experiments/it-flatline-diagnosis.md):
# split the wide gas tranche into a finer efficiency ladder — pure PROFILE DATA
# change, applied here as a runtime ZONE_PROFILES override (no src change, the
# product is untouched; cv18 decides adoption with the standard guards).
#
#   SL_ZONE=IT-CSOUTH julia --project=. docs/experiments/strategic-layer/it_ladder_proto.jl
#
# A/B on ~20 days spread across the eu17_base window: stock ITALY profile vs
# a 10-step tranche ladder (0.85..1.60 x SRMC, same rough average). Metrics:
# intraday shape ratio (sim std / act std), per-day corr, MAE vs settled.

include(joinpath(@__DIR__, "zone_common.jl"))

# ~20 evenly spaced days across the record (shape problem is universal — no
# corr-band selection here)
alldays = Date(2023,7,15):Day(1):Date(2025,6,15)
pick = [d for (i,d) in enumerate(alldays) if i % max(1, length(alldays) ÷ 20) == 3][1:20]

const FINE_TRANCHES = [(0.12,0.85),(0.12,0.90),(0.12,0.95),(0.12,1.00),(0.12,1.05),
                       (0.10,1.12),(0.10,1.20),(0.08,1.30),(0.07,1.42),(0.05,1.60)]
@assert abs(sum(first.(FINE_TRANCHES)) - 1.0) < 1e-9

function with_fine_profile(f, zones)
    old = Dict(z => MeritOrderBook.get_zone_profile(z) for z in zones)
    try
        for z in zones
            p = old[z]
            MeritOrderBook.ZONE_PROFILES[z] = MeritOrderBook.ZoneProfile(;
                (fn => getfield(p, fn) for fn in fieldnames(MeritOrderBook.ZoneProfile))...,
                tranches=FINE_TRANCHES)
        end
        f()
    finally
        for (z, p) in old
            MeritOrderBook.ZONE_PROFILES[z] = p
        end
    end
end

using Statistics
function day_metrics(sim, day)
    c, m, r, n = eval_vs_actual(sim, day)
    # intraday std of hour-averaged sim
    hs = Dict{String,Vector{Float64}}()
    for (ts,p) in sim; push!(get!(hs, ts[1:9]*ts[10:11], Float64[]), p); end
    ssd = std([mean(v) for v in values(hs)])
    (corr=c, mae=m, resid=r, simstd=ssd)
end

const MOB = Euphemia.MeritOrderBook
results = NamedTuple[]
for (i, day) in enumerate(pick)
    a = try clear_day(day) catch e; @warn "A failed" day e; continue; end
    ma = day_metrics(a, day)
    b = try
        with_fine_profile(() -> clear_day(day), [ZONE, get(PARTNER, ZONE, "IT-SOUTH")])
    catch e; @warn "B failed" day e; continue; end
    mb = day_metrics(b, day)
    push!(results, (day=day, a=ma, b=mb))
    @printf("[%2d/20] %s  stock: corr=%s mae=%.1f std=%.1f | fine: corr=%s mae=%.1f std=%.1f\n",
        i, day, ma.corr===missing ? "-" : round(ma.corr,digits=2), ma.mae, ma.simstd,
        mb.corr===missing ? "-" : round(mb.corr,digits=2), mb.mae, mb.simstd)
    flush(stdout)
end

ms(xs) = mean(collect(skipmissing(xs)))
println("\n=== $ZONE ladder prototype summary ($(length(results)) days) ===")
@printf("stock : corr %.3f  MAE %.2f  sim-std %.1f\n",
    ms(r.a.corr for r in results), ms(r.a.mae for r in results), ms(r.a.simstd for r in results))
@printf("fine  : corr %.3f  MAE %.2f  sim-std %.1f\n",
    ms(r.b.corr for r in results), ms(r.b.mae for r in results), ms(r.b.simstd for r in results))
better = count(r -> r.b.mae !== missing && r.a.mae !== missing && r.b.mae < r.a.mae, results)
println("MAE better on $better/$(length(results)) days")
