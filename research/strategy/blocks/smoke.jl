using Euphemia, Dates, JSON
include(joinpath(pkgdir(Euphemia), "src", "strategy", "formats.jl")); using .StrategyFormats
const R = joinpath(homedir(), "armada/em-team/strategy/runs/st-blocks/dev")
day = Date(ARGS[1]); inp = JSON.parsefile("$R/inputs/$day.json"); rl = JSON.parsefile("$R/realised/$day.json")
for z in ["GR", "DE_LU", "ES"]
    F = Float64.(inp["dev_forecast"][z]); P = Float64.(rl["hourly"][z])
    println("== $z  F mean $(round(sum(F)/24,digits=1))  P mean $(round(sum(P)/24,digits=1))  ttf $(inp["ttf"]) eua $(inp["eua"])")
    assets = [archetype("CCGT", z; ttf=inp["ttf"], eua=inp["eua"]), archetype("BESS", z), archetype("PSP", z),
              archetype("HYDRO", z; wv=sum(F)/24), archetype("PVBAT", z; solar_fc=inp["solar_fc"][z]),
              archetype("FLEX", z; load_fc=inp["load_fc"][z])]
    z == "GR" && push!(assets, archetype("COAL", z; eua=inp["eua"]))
    for a in assets
        cls = a isa StrategyFormats.Thermal ? :thermal : a isa StrategyFormats.Storage ? :storage : a isa StrategyFormats.Hydro ? :hydro : a isa StrategyFormats.PVBat ? :pvbat : :flex
        a isa StrategyFormats.Thermal && println("   $(a.id) srmc $(round(a.srmc,digits=1)) SU $(round(a.startup)) pmin $(a.pmin) minup $(a.min_up)")
        for f in FORMATS[cls]
            o = bids(a, f, F, day)
            r = evaluate(a, o, P, day; res=60)
            println("   $(rpad(a.id,6)) $(rpad(f,10)) n=$(length(o)) profit=$(round(r.profit)) rev=$(round(r.rev)) sold=$(round(r.sold_mwh)) dev=$(round(r.dev_mwh)) starts=$(r.starts) fam=$(count(values(r.fam) .> 0))/$(length(r.fam))")
        end
    end
    # 15-min: storage on quarters
    if haskey(rl["q15"], z)
        Q = Float64.(rl["q15"][z]); a = archetype("BESS", z)
        for f in FORMATS[:storage]
            r60 = evaluate(a, bids(a, f, F, day), Q, day; res=15)
            F15 = repeat(F; inner=4); r15 = evaluate(a, bids(a, f, F15, day; res=15), Q, day; res=15)
            println("   BESS q15 $(rpad(f,10)) hourly-product $(round(r60.profit))  15-min product $(round(r15.profit))")
        end
    end
end
