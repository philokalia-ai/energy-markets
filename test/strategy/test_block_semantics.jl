# st-blocks: MAR / linked / exclusive / loop company blocks in the complex-order master (DB-free, HiGHS, seconds).
# run: research/strategy/blocks/jl.sh tests $PWD/test/strategy/test_block_semantics.jl
using Test, Dates
using Euphemia
using Euphemia: MPCC
using Euphemia.MarketOrders: SimpleOrder, LinkedHourlyOrder, MarketOrder
include(joinpath(pkgdir(Euphemia), "src", "strategy", "formats.jl")); using .StrategyFormats

const PER = ["20261104-0000", "20261104-0100"]
const DT = [DateTime(2026, 11, 4, 0), DateTime(2026, 11, 4, 1)]
# market: 300 MW inelastic demand, 100 MW cheap at 10, 400 MW gas at 80 (h1) / gas2 (h2): gas is marginal
function book(company; gas2=100.0)
    o = MarketOrder[]
    for h in 1:2
        push!(o, SimpleOrder(:demand, 3000.0, 300.0, :Z, DT[h], 60))
        push!(o, SimpleOrder(:supply, 10.0, 100.0, :Z, DT[h], 60))
        push!(o, SimpleOrder(:supply, h == 1 ? 80.0 : gas2, 400.0, :Z, DT[h], 60))
    end
    MPCC.MPCCOrderBook(vcat(o, company), ["Z"], PER, (-500.0, 3000.0), nothing)
end
blk(side, p, q, h, fam) = LinkedHourlyOrder(side, p, q, :Z, DT[h], 60, fam, NaN)
clear(c; kw...) = MPCC.solve_mpcc_market_clearing(book(c; kw...); preferred_solver="highs", decompose_periods=true,
                                                 verbose=false)
P(r) = [r.market_prices["Z"][t] for t in PER]
acc() = MPCC.LAST_COMPLEX_INFO[].blocks
# the price-taker evaluator's acceptance at the cleared prices must agree with the clear
pt(c, r) = StrategyFormats.accept(c, P(r), Date(2026, 11, 4); res=60)[2]

@testset "MAR fully accepted" begin
    c = [blk(:supply, 70.0, 100.0, h, "BLKM:Z:m:mar=0.5") for h in 1:2]
    r = clear(c)
    @test P(r) ≈ [80.0, 100.0]
    @test acc()["BLKM:Z:m:mar=0.5"].ratio ≈ 1.0
    @test pt(c, r)["BLKM:Z:m:mar=0.5"] == 1.0
end

@testset "MAR partially accepted sets the price" begin
    c = [blk(:supply, 70.0, 400.0, h, "BLKM:Z:m:mar=0.25") for h in 1:2]
    r = clear(c)
    @test acc()["BLKM:Z:m:mar=0.25"].ratio ≈ 0.5 atol = 1e-6
    @test P(r) ≈ [70.0, 70.0]
end

@testset "MAR below its minimum ratio is rejected" begin
    c = [blk(:supply, 70.0, 400.0, h, "BLKM:Z:m:mar=0.75") for h in 1:2]
    r = clear(c)
    @test isempty(acc())
    @test P(r) ≈ [80.0, 100.0]
end

@testset "linked: child pays for its parent" begin
    c = MarketOrder[blk(:supply, 95.0, 50.0, h, "BLKL:Z:p") for h in 1:2]
    push!(c, blk(:supply, 60.0, 100.0, 2, "BLKL:Z:c:parent=p"))
    r = clear(c)
    @test Set(keys(acc())) == Set(["BLKL:Z:p", "BLKL:Z:c:parent=p"])
    @test P(r) ≈ [80.0, 100.0]
    f = pt(c, r)
    @test f["BLKL:Z:p"] == 1.0 && f["BLKL:Z:c:parent=p"] == 1.0
end

@testset "linked: a child is never accepted without its parent" begin
    c = MarketOrder[blk(:supply, 200.0, 50.0, h, "BLKL:Z:p") for h in 1:2]
    push!(c, blk(:supply, 60.0, 100.0, 2, "BLKL:Z:c:parent=p"))
    r = clear(c)
    @test isempty(acc())
    @test P(r) ≈ [80.0, 100.0]
    @test all(==(0.0), values(pt(c, r)))
end

@testset "exclusive: at most one, the welfare-best" begin
    c = MarketOrder[blk(:supply, 70.0, 100.0, 1, "BLKX:Z:x1:group=g"), blk(:supply, 70.0, 100.0, 2, "BLKX:Z:x2:group=g")]
    r = clear(c)
    @test Set(keys(acc())) == Set(["BLKX:Z:x2:group=g"])
    f = pt(c, r)
    @test f["BLKX:Z:x2:group=g"] == 1.0 && f["BLKX:Z:x1:group=g"] == 0.0
end

@testset "loop (charge + discharge) in an exclusive group" begin
    c = MarketOrder[blk(:demand, 0.0, 100.0, 1, "BLKX:Z:s1:group=s"), blk(:supply, 0.0, 80.0, 2, "BLKX:Z:s1:group=s")]
    r = clear(c; gas2=150.0)
    @test haskey(acc(), "BLKX:Z:s1:group=s")
    @test P(r) ≈ [80.0, 150.0]
    @test pt(c, r)["BLKX:Z:s1:group=s"] == 1.0
    # an unprofitable loop (h2 cheaper than h1) is rejected
    r2 = clear(c; gas2=60.0)
    @test isempty(acc())
end

@testset "no company blocks: BLK path untouched" begin
    c = [blk(:supply, 70.0, 100.0, h, "BLK:Z:u") for h in 1:2]
    r = clear(c)
    @test haskey(acc(), "BLK:Z:u")
    @test !hasproperty(acc()["BLK:Z:u"], :ratio)
    @test P(r) ≈ [80.0, 100.0]
end
