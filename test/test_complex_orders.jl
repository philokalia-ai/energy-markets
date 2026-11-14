# Complex orders (EUPHEMIA_COMPLEX_ORDERS): the energy-limited family master LP +
# fix-and-reprice. DB-free, HiGHS only, < 1 s.
using Test, Dates
using Euphemia: MPCC
using Euphemia.MarketOrders: SimpleOrder, LinkedHourlyOrder, MarketOrder

@testset "Complex orders: energy-limited family (master LP + reprice)" begin
    periods = ["20261104-0000", "20261104-0100"]
    dt = [DateTime(2026, 11, 4, 0), DateTime(2026, 11, 4, 1)]
    Z = :Z
    base = MarketOrder[]
    for (h, gas) in zip(1:2, (50.0, 150.0))
        push!(base, SimpleOrder(:demand, 3000.0, 100.0, Z, dt[h], 60))
        push!(base, SimpleOrder(:supply, 10.0, 60.0, Z, dt[h], 60))
        push!(base, SimpleOrder(:supply, gas, 100.0, Z, dt[h], 60))
    end
    fam(budget) = MarketOrder[LinkedHourlyOrder(:supply, 40.0, 50.0, Z, dt[h], 60, "ESTOR:Z", budget)
                              for h in 1:2]
    clear(orders) = MPCC.solve_mpcc_market_clearing(
        MPCC.MPCCOrderBook(orders, ["Z"], periods, (-500.0, 3000.0), nothing);
        preferred_solver="highs", decompose_periods=true, verbose=false)

    # Unconstrained energy: the storage offer is marginal in both hours (= plain orders).
    r_plain = clear(vcat(base, MarketOrder[SimpleOrder(:supply, 40.0, 50.0, Z, dt[h], 60) for h in 1:2]))
    r_big = clear(vcat(base, fam(1000.0)))
    @test r_big.status == :optimal
    @test r_big.market_prices["Z"] == r_plain.market_prices["Z"]
    @test r_big.market_prices["Z"]["20261104-0000"] ≈ 40.0
    @test r_big.market_prices["Z"]["20261104-0100"] ≈ 40.0

    # Budget 50 MWh: the master spends it in the 150-€ hour (needs only 40 there);
    # hour 0 loses the storage offer and clears on gas.
    r50 = clear(vcat(base, fam(50.0)))
    @test r50.market_prices["Z"]["20261104-0000"] ≈ 50.0
    @test r50.market_prices["Z"]["20261104-0100"] ≈ 40.0   # storage still marginal (cap not binding)

    # Budget 30 MWh: the cap binds in hour 1 → the next order (gas 150) sets the price;
    # the storage is accepted inside its cap and in the money (no paradoxical acceptance).
    r30 = clear(vcat(base, fam(30.0)))
    @test r30.market_prices["Z"]["20261104-0000"] ≈ 50.0
    @test r30.market_prices["Z"]["20261104-0100"] ≈ 150.0
    info = MPCC.LAST_COMPLEX_INFO[]
    @test info.status == :optimal
    @test info.families["ESTOR:Z"]["used"] ≈ 30.0 atol = 1e-6

    # A book without linked orders is untouched by the hook.
    ob = MPCC.MPCCOrderBook(copy(base), ["Z"], periods, (-500.0, 3000.0), nothing)
    @test MPCC.resolve_complex_orders(ob) === ob
end

@testset "Complex orders: regular thermal blocks (MILP master + PAB loop)" begin
    periods = ["20261104-0000", "20261104-0100"]
    dt = [DateTime(2026, 11, 4, 0), DateTime(2026, 11, 4, 1)]
    Z = :Z
    book(demand, blk_price, gas) = begin
        o = MarketOrder[]
        for h in 1:2
            push!(o, SimpleOrder(:demand, 3000.0, demand[h], Z, dt[h], 60))
            push!(o, SimpleOrder(:supply, gas[h], 200.0, Z, dt[h], 60))
            push!(o, LinkedHourlyOrder(:supply, blk_price, 50.0, Z, dt[h], 60, "BLK:Z:u1", NaN))
        end
        MPCC.MPCCOrderBook(o, ["Z"], periods, (-500.0, 3000.0), nothing)
    end
    clear(ob) = MPCC.solve_mpcc_market_clearing(ob; preferred_solver="highs",
        decompose_periods=true, verbose=false)

    # Block at 60 vs gas 80/100: accepted, injects 50 MW in both hours, gas sets both prices.
    r = clear(book([100.0, 100.0], 60.0, [80.0, 100.0]))
    @test r.market_prices["Z"]["20261104-0000"] ≈ 80.0
    @test haskey(MPCC.LAST_COMPLEX_INFO[].blocks, "BLK:Z:u1")

    # Block at 90 vs gas 80/100: average saving (−10 + 10)·50 = 0 → welfare-indifferent;
    # at 95: rejected (welfare loss). Hourly orders would have run in hour 2 only.
    r = clear(book([100.0, 100.0], 95.0, [80.0, 100.0]))
    @test isempty(MPCC.LAST_COMPLEX_INFO[].blocks)
    @test r.market_prices["Z"]["20261104-0100"] ≈ 100.0

    # PAB: hour 1 demand 50 with 30 MW of cheap supply at 10. The master accepts the
    # block (welfare: −1100 in hour 1, +2000 in hour 2), but with its 50 MW fixed hour 1
    # reprices to ≤ 10 and the block loses money over the day ((≤10−60)·50 + 40·50 < 0)
    # → paradoxically accepted → rejected and re-solved: hour 1 back to gas at 80.
    ob = book([50.0, 100.0], 60.0, [80.0, 100.0])
    push!(ob.orders, SimpleOrder(:supply, 10.0, 30.0, Z, dt[1], 60))
    r = clear(ob)
    info = MPCC.LAST_COMPLEX_INFO[]
    @test "BLK:Z:u1" in info.forced
    @test isempty(info.blocks)
    @test r.market_prices["Z"]["20261104-0000"] ≈ 80.0
end
