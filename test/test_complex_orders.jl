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

@testset "Complex orders: review fixes (fixed injections, PAB fallback, release, as-of cutoff)" begin
    t0 = ["20261104-0000"]; d0 = DateTime(2026, 11, 4, 0); Z = :Z
    # (4) the MPCC honours fixed injections (single-zone, decomposed path)
    o = MarketOrder[SimpleOrder(:demand, 3000.0, 100.0, Z, d0, 60),
                    SimpleOrder(:supply, 50.0, 100.0, Z, d0, 60),
                    SimpleOrder(:supply, 10.0, 30.0, Z, d0, 60)]
    ob = MPCC.MPCCOrderBook(o, ["Z"], t0, (-500.0, 3000.0), nothing)
    @test MPCC.solve_mpcc_market_clearing(ob; preferred_solver="highs", verbose=false).market_prices["Z"][t0[1]] ≈ 50.0
    obf = MPCC.MPCCOrderBook(o, ["Z"], t0, (-500.0, 3000.0), nothing, Dict(("Z", t0[1]) => 80.0))
    @test MPCC.solve_mpcc_market_clearing(obf; preferred_solver="highs", verbose=false).market_prices["Z"][t0[1]] ≈ 10.0

    # (2)+(3) PAB exhaustion → blocks released to the ORIGINAL must-run offers (BLKFB)
    periods = ["20261104-0000", "20261104-0100"]
    dt = [DateTime(2026, 11, 4, 0), DateTime(2026, 11, 4, 1)]
    orders = MarketOrder[]
    for (h, dem, gas) in ((1, 50.0, 80.0), (2, 100.0, 100.0))
        push!(orders, SimpleOrder(:demand, 3000.0, dem, Z, dt[h], 60))
        push!(orders, SimpleOrder(:supply, gas, 200.0, Z, dt[h], 60))
        push!(orders, LinkedHourlyOrder(:supply, 60.0, 50.0, Z, dt[h], 60, "BLK:Z:u1", NaN))
        push!(orders, LinkedHourlyOrder(:supply, 3.0, 30.0, Z, dt[h], 60, "BLKFB:Z:u1", NaN))
        push!(orders, LinkedHourlyOrder(:supply, 30.0, 20.0, Z, dt[h], 60, "BLKFB:Z:u1", NaN))
    end
    push!(orders, SimpleOrder(:supply, 10.0, 30.0, Z, dt[1], 60))
    bk = MPCC.MPCCOrderBook(orders, ["Z"], periods, (-500.0, 3000.0), nothing)
    r = MPCC.solve_with_complex_orders(bk,
        b -> MPCC.solve_mpcc_market_clearing(b; preferred_solver="highs", decompose_periods=true, verbose=false);
        verbose=false, max_pab_rounds=1)
    @test MPCC.LAST_COMPLEX_INFO[].status == :pab_fallback
    @test startswith(r.message, "COMPLEX-ORDERS PAB FALLBACK")
    # baseline book: hour 1 = 30 MW @3 + 20 MW from the 10-€ unit → 10; hour 2 = 50 MW
    # of must-run + 50 MW gas → 100
    @test r.market_prices["Z"]["20261104-0000"] ≈ 10.0
    @test r.market_prices["Z"]["20261104-0100"] ≈ 100.0

    # (3) master failure releases to exactly the baseline book (blocks dropped,
    # original must-run restored, storage uncapped) — failure injected via an
    # out-of-grid member
    bad = vcat(bk.orders, MarketOrder[LinkedHourlyOrder(:supply, 40.0, 5.0, Z,
        DateTime(2026, 11, 4, 5), 60, "ESTOR:Z", 10.0)])
    rel = MPCC.resolve_complex_orders(MPCC.MPCCOrderBook(bad, ["Z"], periods, (-500.0, 3000.0), nothing); verbose=false)
    @test MPCC.LAST_COMPLEX_INFO[].status == :fallback
    @test all(o -> o isa SimpleOrder, rel.orders)
    @test count(o -> o.price == 3.0 && o.quantity == 30.0, rel.orders) == 2   # must-run deep restored
    @test !any(o -> o.price == 60.0, rel.orders)                               # no block slices
    @test count(o -> o.price == 40.0, rel.orders) == 1                          # storage uncapped

    # (1) storage budget cutoff respects the issuance context
    D = Date(2026, 11, 20)
    @test Euphemia.MeritOrderBook._storage_cutoff_day(D) == Date(2026, 11, 19)
    Euphemia.with_context(Euphemia.gate_context(D)) do
        @test Euphemia.MeritOrderBook._storage_cutoff_day(D) == Date(2026, 11, 19)   # lead 1 = legacy
    end
    Euphemia.with_context(Euphemia.issuance_context(D, 7; issue_time=Time(6, 30))) do
        @test Euphemia.MeritOrderBook._storage_cutoff_day(D) == Date(2026, 11, 13)   # lead 7: only days < 11-13
    end
end

@testset "Complex orders: cv44 default and kill-switch" begin
    kinds() = Euphemia.MeritOrderBook.complex_order_kinds()
    withenv("EUPHEMIA_COMPLEX_ORDERS" => nothing) do
        @test kinds() == Set(["ps"])                      # cv44 default
    end
    for off in ("off", "OFF", "none", "", "  ")
        withenv("EUPHEMIA_COMPLEX_ORDERS" => off) do
            @test isempty(kinds())                        # kill-switch ⇒ cv43 book
        end
    end
    withenv("EUPHEMIA_COMPLEX_ORDERS" => "ps,blocks") do
        @test kinds() == Set(["ps", "blocks"])            # blocks stays opt-in
    end
    withenv("EUPHEMIA_COMPLEX_ORDERS" => "blocks") do
        @test kinds() == Set(["blocks"])
    end
end

@testset "PS opportunity reference: vintage-safe snapshot + true 06:30 context" begin
    include(joinpath(@__DIR__, "scripts", "blocks", "contexts.jl"))
    M = Euphemia.MeritOrderBook
    D = Date(2026, 11, 20)
    # the eval context is really 06:30 on D-1 (issuance_context lead 1 would be 10:00)
    @test pregate_0630(D).as_of_utc == DateTime(2026, 11, 19, 6, 30)
    @test Euphemia.issuance_context(D, 1; issue_time=Time(6, 30)).as_of_utc == DateTime(2026, 11, 19, 10, 0)
    f = tempname() * ".csv"
    pv(x) = join(string.(collect(range(x, x - 230; length=24))), ",")
    write(f, "zone,day,issued_utc,$(join(["p$i" for i in 1:24], ","))\n" *
             "CH,2026-11-20,2026-11-19 06:30:00,$(pv(300.0))\n" *          # the D-1 06:30 vintage
             "CH,2026-11-20,2026-11-20 23:00:00,$(pv(500.0))\n")           # a FUTURE vintage
    withenv("EUPHEMIA_PS_OPP_REF_FILE" => f, "EUPHEMIA_PS_OPP_ZONES" => "CH") do
        snap = M.ps_opp_snapshot!()
        @test snap !== nothing
        # 06:30 lead-1 issuance: the future vintage is rejected, the D-1 06:30 one used
        Euphemia.with_context(pregate_0630(D)) do
            @test M._ps_opp_prices(snap, "CH", D)[1] == 300.0
        end
        # legacy path: explicit D-1 10:00 cutoff → same admissible vintage
        @test M._ps_opp_prices(snap, "CH", D)[1] == 300.0
        # lead 7 (issued 2026-11-13 06:30): no admissible vintage → off
        Euphemia.with_context(Euphemia.issuance_context(D, 7; issue_time=Time(6, 30))) do
            @test M._ps_opp_prices(snap, "CH", D) === nothing
        end
        # a later issuance that legitimately sees both picks the latest vintage
        Euphemia.with_context(Euphemia.ForecastContext(D, DateTime(2026, 11, 21), 1, :fixed_10utc, "")) do
            @test M._ps_opp_prices(snap, "CH", D)[1] == 500.0
        end
        @test M._ps_opp_prices(snap, "AT", D) === nothing          # zone not listed
        # snapshot is immutable: rewriting the file does not change the loaded rows
        write(f, "zone,day,issued_utc,$(join(["p$i" for i in 1:24], ","))\n")
        @test M._ps_opp_prices(M.PS_OPP_SNAPSHOT[], "CH", D)[1] == 300.0
    end
    withenv("EUPHEMIA_PS_OPP_REF_FILE" => nothing, "EUPHEMIA_PS_OPP_ZONES" => nothing) do
        @test M.ps_opp_snapshot!() === nothing                      # off ⇒ fail closed
        @test M.PS_OPP_SNAPSHOT[] === nothing
    end
    # malformed file (unsorted prices) is an error, not a silent degrade
    bad = tempname() * ".csv"
    write(bad, "zone,day,issued_utc,$(join(["p$i" for i in 1:24], ","))\n" *
               "CH,2026-11-20,2026-11-19 06:30:00,$(join(string.(1.0:24.0), ","))\n")
    withenv("EUPHEMIA_PS_OPP_REF_FILE" => bad, "EUPHEMIA_PS_OPP_ZONES" => "CH") do
        @test_throws ErrorException M.ps_opp_snapshot!()
    end
end
