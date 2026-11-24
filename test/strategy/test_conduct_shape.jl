# DB-free unit tests of ShapeConduct (src/strategy/conduct_shape.jl).
using Euphemia, Dates, Statistics, Test
using Euphemia.MarketOrders: SimpleOrder
include(joinpath(pkgdir(Euphemia), "src", "strategy", "conduct_shape.jl"))
day = Date(2026, 9, 13)
ts = [Dates.format(DateTime(day) + Minute(15k), "yyyymmdd-HHMM") for k in 0:95]
d(layer) = DayCtx("GR", day, ts, [0.6 + 0.9 * sin(k / 7)^2 for k in 0:95], [(k % 24) / 23 for k in 0:95],
                  1.3, 2.5, 1.0, 4.0, layer, nothing)
@testset "ShapeConduct" begin
    f = conduct_day_factors(TranchesConduct(), d(true))
    for a in (0.0, 0.25, 0.5, 0.75, 1.0)
        g = conduct_day_factors(ShapeConduct(a), d(true))
        @test isapprox(mean(g), mean(f); rtol=1e-12)                       # level-neutral: day mean conserved
        @test isapprox(std(g), a * std(f); rtol=1e-9, atol=1e-12)           # shape scaled by alpha
    end
    @test conduct_day_factors(ShapeConduct(1.0), d(true)) ≈ f              # alpha = 1 is today
    @test all(==(1.0), conduct_day_factors(ShapeConduct(0.3), d(false)))    # layer off: identity
    g0 = conduct_day_factors(ShapeConduct(0.0), d(true))
    @test maximum(g0) - minimum(g0) < 1e-12                                # alpha = 0: flat
    u = UnitCtx(91.0, 380.0, 1.7, Inf, :GR, DateTime(day), 15, 4, true)
    a = offers(ShapeConduct(0.5), u); b = offers(TranchesConduct(), u)
    @test length(a) == length(b) && all(x[1].price === y[1].price && x[2] == y[2] for (x, y) in zip(a, b))  # same ladder
    @test ShapeConduct(0.5) isa MarketConduct
end
