# SE3 night-overpricing fix prototype: lower water_value_base for SE3 only,
# runtime profile override (no src change). A/B on ~15 days.
#   SL_ZONE=SE3 julia --project=. docs/experiments/strategic-layer/se3_watervalue_proto.jl
include(joinpath(@__DIR__, "zone_common.jl"))
const MOB = Euphemia.MeritOrderBook
using Statistics, Printf

function with_wv(f, zones, wv)
    old = Dict(z => MOB.get_zone_profile(z) for z in zones)
    try
        for z in zones
            p = old[z]
            MOB.ZONE_PROFILES[z] = MOB.ZoneProfile(;
                (fn => getfield(p, fn) for fn in fieldnames(MOB.ZoneProfile))...,
                water_value_base=wv)
        end
        f()
    finally
        for (z, p) in old; MOB.ZONE_PROFILES[z] = p; end
    end
end

alldays = Date(2023,8,1):Day(1):Date(2025,6,1)
pick = [d for (i,d) in enumerate(alldays) if i % max(1, length(alldays) ÷ 15) == 5][1:15]

function dm(sim, day)
    c, m, r, n = eval_vs_actual(sim, day); (corr=c, mae=m, resid=r)
end

for wv in (0.65, 0.50)
    results = NamedTuple[]
    for day in pick
        a = try clear_day(day) catch e; @warn "A failed" day e; continue; end
        b = try with_wv(() -> clear_day(day), [ZONE], wv) catch e; @warn "B failed" day wv e; continue; end
        push!(results, (a=dm(a,day), b=dm(b,day)))
    end
    ms(xs) = (v=Float64[x for x in xs if x !== missing]; isempty(v) ? NaN : mean(v))
    @printf("wv=%.2f (%d days): stock corr %.3f MAE %.2f resid %+.1f | proto corr %.3f MAE %.2f resid %+.1f | better %d/%d\n",
        wv, length(results),
        ms(r.a.corr for r in results), ms(r.a.mae for r in results), ms(r.a.resid for r in results),
        ms(r.b.corr for r in results), ms(r.b.mae for r in results), ms(r.b.resid for r in results),
        count(r -> r.b.mae < r.a.mae, results), length(results))
    flush(stdout)
end
