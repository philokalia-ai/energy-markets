# DB-free unit tests of the market-conduct plug-ins (src/merit_order/conduct.jl).
# Run: julia --project=. test/strategy/test_conduct.jl   (loads Euphemia; touches no database)
using Euphemia, Dates, Test
using Euphemia.MarketOrders: SimpleOrder
const MOB = Euphemia.MeritOrderBook

# the code before the plug-in, copied verbatim (book_build.jl at 11bcbd7) as the reference
function ref_factor(margin, norm_demand, scarcity_threshold, scarcity_kappa, peak_kappa, peak_exponent, layer_on)
    layer_on ? 1.0 + scarcity_kappa * max(0.0, scarcity_threshold - margin)^2 + peak_kappa * norm_demand^peak_exponent : 1.0
end
function ref_ladder(gmc, flexible_capacity, scarcity, nuc_ceil, zone, date_time, resolution_minutes, grading, layer_on)
    tranches = layer_on ? MOB.TRANCHES : [(1.0, 1.0)]
    out = Tuple{SimpleOrder,String}[]
    for (i, (share, mult)) in enumerate(tranches)
        qty = flexible_capacity * share
        qty < 0.1 && continue
        K = (i == 1 || grading <= 1) ? 1 : grading
        mult_lo = K == 1 ? mult : tranches[i-1][2]
        for j in 1:K
            m_j = K == 1 ? mult : mult_lo + (mult - mult_lo) * j / K
            price = min(gmc * m_j * (i == 1 ? 1.0 : scarcity), nuc_ceil)
            push!(out, (SimpleOrder(:supply, price, qty / K, zone, date_time, resolution_minutes),
                        i == 1 ? "srmc_base" : "peak_tranche_$i"))
        end
    end
    return out
end
same(a::SimpleOrder, b::SimpleOrder) = a.type == b.type && a.price === b.price && a.quantity === b.quantity &&
    a.zone == b.zone && a.date_time == b.date_time && a.resolution_code == b.resolution_code
same(a::Vector, b::Vector) = length(a) == length(b) && all(same(x[1], y[1]) && x[2] == y[2] for (x, y) in zip(a, b))

day = Date(2026, 9, 13)
ts = [Dates.format(DateTime(day) + Minute(15k), "yyyymmdd-HHMM") for k in 0:95]
margins = [0.6 + 0.9 * sin(k / 7)^2 for k in 0:95]           # crosses typical thresholds
nds = [(k % 24) / 23 for k in 0:95]
mkday(layer) = DayCtx("GR", day, ts, margins, nds, 1.3, 2.5, 1.0, 4.0, layer, nothing)

@testset "TranchesConduct factors == the code before the plug-in" begin
    for layer in (true, false)
        f = conduct_day_factors(TranchesConduct(), mkday(layer))
        @test all(f[t] === ref_factor(margins[t], nds[t], 1.3, 2.5, 1.0, 4.0, layer) for t in eachindex(ts))
    end
end

@testset "TranchesConduct ladder == the code before the plug-in (bitwise)" begin
    dt = DateTime(day) + Hour(18)
    for layer in (true, false), grading in (1, 4), gmc in (0.0, 37.5, 112.34567, 480.1), fac in (1.0, 1.37, 3.9),
        nuc in (Inf, 150.0), cap in (0.05, 0.2, 95.0, 412.7), res in (15, 60)
        u = UnitCtx(gmc, cap, fac, nuc, :GR, dt, res, grading, layer)
        @test same(offers(TranchesConduct(), u), ref_ladder(gmc, cap, fac, nuc, :GR, dt, res, grading, layer))
    end
end

@testset "CompetitiveConduct == the EUPHEMIA_CONDUCT_LAYER=off arm" begin
    # factors: off-arm TranchesConduct gives 1.0 everywhere; Competitive gives 1.0 whatever the layer flag
    @test conduct_day_factors(CompetitiveConduct(), mkday(true)) == conduct_day_factors(TranchesConduct(), mkday(false))
    dt = DateTime(day) + Hour(7)
    for grading in (1, 4), gmc in (0.0, 61.2, 230.0), fac in (1.0, 2.2), nuc in (Inf, 90.0), cap in (0.05, 0.2, 300.0)
        off = offers(TranchesConduct(), UnitCtx(gmc, cap, fac, nuc, :DE_LU, dt, 15, grading, false))
        for layer in (true, false)
            @test same(offers(CompetitiveConduct(), UnitCtx(gmc, cap, fac, nuc, :DE_LU, dt, 15, grading, layer)), off)
        end
    end
end

@testset "interface" begin
    @test TranchesConduct() isa MarketConduct && MarketConduct <: BiddingStrategy
    buf = Tuple{SimpleOrder,String}[]
    u = UnitCtx(80.0, 400.0, 1.5, Inf, :FR, DateTime(day), 60, 1, true)
    @test offers!(buf, TranchesConduct(), u) === buf && length(buf) == 4
    @test [l for (_, l) in buf] == ["srmc_base", "peak_tranche_2", "peak_tranche_3", "peak_tranche_4"]
    @test ZoneScenario().conduct === nothing && Euphemia.is_empty_scenario(ZoneScenario())
    @test !Euphemia.is_empty_scenario(ZoneScenario(conduct=CompetitiveConduct()))
end
