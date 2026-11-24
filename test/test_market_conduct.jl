# DB-free unit tests of the market-conduct plug-ins (src/merit_order/conduct.jl).
# Self-contained: hand-built contexts, no database. Run alone: julia --project=. test/test_market_conduct.jl
using Euphemia, Dates, Test
using Euphemia.MarketOrders: SimpleOrder
const _MOB = Euphemia.MeritOrderBook

# The code before the plug-in, copied verbatim from book_build.jl (main 8aa0a39) as the reference.
# `layer_on` reproduces the deleted EUPHEMIA_CONDUCT_LAYER switch: on = the default, off = the #367 ablation arm.
_ref_factor(margin, nd, thr, kappa, peak_kappa, peak_exp, layer_on) =
    layer_on ? 1.0 + kappa * max(0.0, thr - margin)^2 + peak_kappa * nd^peak_exp : 1.0
function _ref_ladder(gmc, flexible_capacity, scarcity, nuc_ceil, zone, date_time, resolution_minutes, grading, layer_on)
    tranches = layer_on ? _MOB.TRANCHES : [(1.0, 1.0)]
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
_same(a::SimpleOrder, b::SimpleOrder) = a.type == b.type && a.price === b.price && a.quantity === b.quantity &&
    a.zone == b.zone && a.date_time == b.date_time && a.resolution_code == b.resolution_code
_same(a::Vector, b::Vector) = length(a) == length(b) && all(_same(x[1], y[1]) && x[2] == y[2] for (x, y) in zip(a, b))

@testset "Market conduct plug-ins (DB-free)" begin
    day = Date(2026, 9, 13)
    ts = [Dates.format(DateTime(day) + Minute(15k), "yyyymmdd-HHMM") for k in 0:95]
    margins = [0.6 + 0.9 * sin(k / 7)^2 for k in 0:95]
    nds = [(k % 24) / 23 for k in 0:95]
    dctx = DayCtx("GR", day, ts, margins, nds, 1.3, 2.5, 1.0, 4.0, nothing)

    @testset "TranchesConduct == the code before the plug-in (bitwise)" begin
        f = conduct_day_factors(TranchesConduct(), dctx)
        @test all(f[t] === _ref_factor(margins[t], nds[t], 1.3, 2.5, 1.0, 4.0, true) for t in eachindex(ts))
        dt = DateTime(day) + Hour(18)
        for grading in (1, 4), gmc in (0.0, 37.5, 112.34567, 480.1), fac in (1.0, 1.37, 3.9), nuc in (Inf, 150.0),
            cap in (0.05, 0.2, 95.0, 412.7), res in (15, 60)
            @test _same(offers(TranchesConduct(), UnitCtx(gmc, cap, fac, nuc, :GR, dt, res, grading)),
                        _ref_ladder(gmc, cap, fac, nuc, :GR, dt, res, grading, true))
        end
    end

    @testset "CompetitiveConduct == the deleted EUPHEMIA_CONDUCT_LAYER=off arm" begin
        @test all(==(1.0), conduct_day_factors(CompetitiveConduct(), dctx))
        @test conduct_day_factors(CompetitiveConduct(), dctx) ==
              [_ref_factor(margins[t], nds[t], 1.3, 2.5, 1.0, 4.0, false) for t in eachindex(ts)]
        dt = DateTime(day) + Hour(7)
        for grading in (1, 4), gmc in (0.0, 61.2, 230.0), fac in (1.0, 2.2), nuc in (Inf, 90.0), cap in (0.05, 0.2, 300.0)
            @test _same(offers(CompetitiveConduct(), UnitCtx(gmc, cap, fac, nuc, :DE_LU, dt, 15, grading)),
                        _ref_ladder(gmc, cap, fac, nuc, :DE_LU, dt, 15, grading, false))
        end
    end

    @testset "ShapeConduct: level-neutral reshape, same ladder" begin
        f = conduct_day_factors(TranchesConduct(), dctx)
        m = sum(f) / length(f)
        for a in (0.0, 0.25, 0.5, 0.75, 1.0)
            g = conduct_day_factors(ShapeConduct(a), dctx)
            @test isapprox(sum(g) / length(g), m; rtol=1e-12)                 # the day-mean factor is conserved
            @test isapprox(maximum(g) - minimum(g), a * (maximum(f) - minimum(f)); rtol=1e-9, atol=1e-12)
        end
        @test conduct_day_factors(ShapeConduct(1.0), dctx) ≈ f              # alpha = 1 is TranchesConduct
        @test ShapeConduct().alpha == _MOB.SHAPE_CONDUCT_ALPHA == 0.0
        u = UnitCtx(91.0, 380.0, 1.7, Inf, :GR, DateTime(day), 15, 4)
        @test _same(offers(ShapeConduct(0.5), u), offers(TranchesConduct(), u))
    end

    @testset "interface" begin
        @test TranchesConduct() isa MarketConduct && MarketConduct <: BiddingStrategy
        buf = Tuple{SimpleOrder,String}[]
        u = UnitCtx(80.0, 400.0, 1.5, Inf, :FR, DateTime(day), 60, 1)
        @test offers!(buf, TranchesConduct(), u) === buf && length(buf) == 4
        @test [l for (_, l) in buf] == ["srmc_base", "peak_tranche_2", "peak_tranche_3", "peak_tranche_4"]
        @test ZoneScenario().conduct === nothing && Euphemia.is_empty_scenario(ZoneScenario())
        @test !Euphemia.is_empty_scenario(ZoneScenario(conduct=CompetitiveConduct()))
    end
end
