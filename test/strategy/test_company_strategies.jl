# st-blocks round 2: the CompanyStrategy plug-in interface (DB-free, seconds).
# run: research/strategy/blocks/jl.sh tests -e 'using Euphemia; include("test/strategy/test_company_strategies.jl")'
using Test, Dates
using Euphemia
using Euphemia: MPCC
using Euphemia.MarketOrders: SimpleOrder, LinkedHourlyOrder, MarketOrder
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
include(joinpath(pkgdir(Euphemia), "src", "strategy", "formats.jl")); using .StrategyFormats
include(joinpath(pkgdir(Euphemia), "src", "strategy", "CompanyScore.jl")); using .CompanyScore
const SF = StrategyFormats

const DAY = Date(2026, 11, 4)
# a forecast with a cheap night and an expensive day (hourly), and the same at 15 minutes
const F24 = [60.0 .+ 80.0 * (8 <= h <= 21) .+ 10.0 * sin(h) for h in 0:23]
const F96 = repeat(F24; inner=4)
ccgt() = archetype("CCGT", "GR"; ttf=40.0, eua=70.0)
ALL = Dict(
    "thermal" => (ccgt(), [HourlyMC(), HourlyAC(0.75), Block(1.0), Linked(0.5), Exclusive(1.0, 5), MarFull(1.0), BlockHAC(1.0)]),
    "storage" => (archetype("PSP", "GR"), [HourlyOC(), HourlySched(), Block(), Exclusive()]),
    "hydro" => (archetype("HYDRO", "GR"; wv=100.0), [HourlyOC(), HourlySched(), Block(), Linked(), Exclusive(), MarFull(1.0, 0.5)]),
    "pvbat" => (archetype("PVBAT", "GR"; solar_fc=[max(0.0, 10 - abs(h - 12)) for h in 0:23], solar_peak=10.0),
                [HourlyOC(), HourlySched(), Block(), Exclusive()]),
    "flex" => (archetype("FLEX", "GR"; load_fc=[500.0 + 100 * (8 <= h <= 21) for h in 0:23]),
               [HourlyOC(), HourlySched(), Block(), Exclusive()]))

@testset "every strategy: tagged orders, bids() is the thin wrapper, 24 and 96 steps" begin
    for (cls, (a, ss)) in ALL, s in ss, (F, res) in ((F24, 60), (F96, 15))
        t = offers(s, CompanyCtx(a, F, DAY, res))
        @test !isempty(t)
        @test all(l == label(s) for (_, l) in t)
        @test all(o.zone == Symbol(a.zone) && o.resolution_code == res for (o, _) in t)
        fmt = label(s) == "mar_full" && a isa SF.Hydro ? "mar" : label(s)
        b = bids(a, fmt, F, DAY; res=res, k_su=hasproperty(s, :k_su) ? s.k_su : 1.0)
        @test length(b) == length(t)
        @test all(x === y || (x.price == y.price && x.quantity == y.quantity && x.date_time == y.date_time &&
                              typeof(x) == typeof(y)) for (x, (y, _)) in zip(b, t))
    end
end

@testset "cost-reflective trait and k_su ≤ 1" begin
    @test all(cost_reflective(s) for (_, (_, ss)) in ALL for s in ss)
    @test !cost_reflective(MarMin(1.0))
    @test_throws ErrorException Block(1.25)
    @test_throws ErrorException HourlyAC(1.5)
    # a thermal block's price never exceeds its average cost incl. start-up and no-load over the block
    a = ccgt()
    for s in (Block(1.0), Exclusive(1.0, 5), MarFull(1.0), BlockHAC(1.0))
        fams = Dict{String,Vector{LinkedHourlyOrder}}()
        for (o, _) in offers(s, CompanyCtx(a, F24, DAY, 60))
            o isa LinkedHourlyOrder && push!(get!(fams, o.family, LinkedHourlyOrder[]), o)
        end
        for (_, m) in fams
            L = length(m); E = sum(o.quantity for o in m)
            @test first(m).price * E <= a.srmc * E + a.startup + a.noload * L + 1e-6
        end
    end
end

@testset "structure: linked parents, exclusive groups, signed loops" begin
    a = ccgt()
    lk = [o for (o, _) in offers(Linked(1.0), CompanyCtx(a, F24, DAY, 60))]
    @test count(o -> o.family == "BLKL:GR:CCGT-p", lk) >= a.min_up
    @test all(occursin("parent=CCGT-p", o.family) for o in lk if o.family != "BLKL:GR:CCGT-p")
    ex = [o for (o, _) in offers(Exclusive(1.0, 5), CompanyCtx(a, F24, DAY, 60))]
    @test all(endswith(o.family, ":group=CCGT") for o in ex)
    p = archetype("PSP", "GR")
    lp = [o for (o, _) in offers(Block(), CompanyCtx(p, F24, DAY, 60))]
    @test all(startswith(o.family, "BLKL:") for o in lp)           # a loop must be signed (BLKL), never BLK
    @test any(o.type == :demand for o in lp) && any(o.type == :supply for o in lp)
    ch = sum(o.quantity for o in lp if o.type == :demand); di = sum(o.quantity for o in lp if o.type == :supply)
    @test isapprox(ch * sqrt(p.eta), di / sqrt(p.eta); rtol=1e-6)  # energy-balanced day (empty at both ends)
end

@testset "score(): price-taker and with impact on a hand-built 1-zone baseline" begin
    periods = [Dates.format(DateTime(DAY) + Hour(h), "yyyymmdd-HHMM") for h in 0:23]
    o = MarketOrder[]
    for h in 0:23
        t = DateTime(DAY) + Hour(h)
        push!(o, SimpleOrder(:demand, 3000.0, 600.0 + 400.0 * (8 <= h <= 21), :GR, t, 60))
        push!(o, SimpleOrder(:supply, 20.0, 500.0, :GR, t, 60))
        push!(o, SimpleOrder(:supply, 150.0, 2000.0, :GR, t, 60))
    end
    book = MPCC.MPCCOrderBook(o, ["GR"], periods, (-500.0, 3000.0), nothing)
    r0 = mz_solve_pass(book; optimizer="highs", silent=true, decompose_periods=true)
    base = BaselineDay(DAY, book, Dict("GR" => Dict(p => r0.market_prices["GR"][p] for p in periods)), 1, Dict{String,Any}())
    a = ccgt()
    realised = forecast_vector(base, "GR") .+ 5.0
    for s in (HourlyMC(), Block(1.0), Linked(1.0), Exclusive(1.0, 5), MarFull(1.0))
        r = score(s, a, base; realised=realised)
        @test r.res == 60 && length(r.F) == 24
        @test r.pricetaker !== nothing && isfinite(r.pricetaker.profit)
        @test r.impact.status in (:optimal, :time_limit)
        @test length(r.impact.P) == 24 && all(isfinite, r.impact.dp)
    end
    @test_throws ErrorException score(MarMin(1.0), a, base; realised=realised, impact=false)
    @test score(MarMin(1.0), a, base; realised=realised, impact=false, allow_flagged=true).impact === nothing
end
