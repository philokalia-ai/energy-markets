# Pass 2 reuses pass 1's transfer capacity instead of re-reading it (perf-96).
# DB-free: every zone is reused from the pass-1 cache, so a supplied network means the
# builder touches no data store at all; the MPCC result comes from a tiny HiGHS clear.
#
# Standalone:  julia --project=. test/test_pass2_network_reuse.jl

using Test, Dates
using Euphemia
using Euphemia: MPCC, MarketOrders
using Euphemia.MarketOrders: SimpleOrder, MarketOrder
using Euphemia.Network: TransferCapacity

@testset "pass 2 reuses pass-1 transfer capacity (no re-fetch)" begin
    day = Date(2026, 11, 4)
    zones = ["A", "B"]
    dts = [DateTime(day) + Hour(h) for h in 0:1]
    periods = [Dates.format(t, "yyyymmdd-HHMM") for t in dts]
    cached = Dict{String,Vector{MarketOrder}}(
        "A" => MarketOrder[o for t in dts for o in (SimpleOrder(:supply, 20.0, 100.0, :A, t, 60),
                                                    SimpleOrder(:demand, 3000.0, 40.0, :A, t, 60))],
        "B" => MarketOrder[o for t in dts for o in (SimpleOrder(:supply, 80.0, 100.0, :B, t, 60),
                                                    SimpleOrder(:demand, 3000.0, 60.0, :B, t, 60))])
    fwd = Dict{Tuple{String,String,String},Float64}(("A", "B", string(h)) => 30.0 for h in 1:24)
    bwd = Dict{Tuple{String,String,String},Float64}(("A", "B", string(h)) => 30.0 for h in 1:24)
    tc = TransferCapacity(zones, [string(h) for h in 1:24], fwd, bwd)

    # No anchored zone (empty refs) + a supplied network: nothing is built or fetched.
    ob = redirect_stdout(devnull) do
        Euphemia._create_multi_zone_order_book_merit(zones, day;
            enrich_network=false, cached_zone_orders=cached, transfer_capacity=tc)
    end
    @test ob.network_topology === tc
    @test ob.nodes == zones
    @test ob.periods == periods
    @test length(ob.orders) == 8

    # The anchor-input stage hands the pass-1 network to pass 2.
    r = MPCC.solve_mpcc_market_clearing(ob; preferred_solver="highs", silent=true,
                                        decompose_periods=true, verbose=false)
    @test r.status == :optimal
    @test r.market_prices["A"][periods[1]] ≈ 20.0   # 30 MW export fits: A's cheap supply sets A
    @test r.market_prices["B"][periods[1]] ≈ 80.0   # B still needs its own 80 € supply
    ai = mz_extract_anchor_inputs(ob, r; apply_zone_profiles=false)
    @test isempty(ai.anchored)
    @test ai.network === ob.network_topology

    # mz_rebuild_anchored threads the keyword through (all zones reused → no fetch).
    ob2 = redirect_stdout(devnull) do
        mz_rebuild_anchored(zones, day, Dict{String,Dict{String,Float64}}(), cached;
                            transfer_capacity=ai.network)
    end
    @test ob2.network_topology === tc
    @test ob2.orders == ob.orders
end

@testset "pass-2 reuse replays the transfer-capacity build's as-of audit (#470 review)" begin
    day = Date(2026, 11, 4)
    zones = ["A", "B"]
    t = DateTime(day)
    cached = Dict{String,Vector{MarketOrder}}(
        "A" => MarketOrder[SimpleOrder(:supply, 20.0, 100.0, :A, t, 60), SimpleOrder(:demand, 3000.0, 40.0, :A, t, 60)],
        "B" => MarketOrder[SimpleOrder(:supply, 80.0, 100.0, :B, t, 60), SimpleOrder(:demand, 3000.0, 60.0, :B, t, 60)])
    tc = TransferCapacity(zones, [string(h) for h in 1:24],
                          Dict(("A", "B", string(h)) => 30.0 for h in 1:24),
                          Dict(("A", "B", string(h)) => 30.0 for h in 1:24))
    @test isempty(tc.asof_audit)                      # every constructor starts empty
    tc.asof_audit[("outages_transmission", :verified)] = 7
    tc.asof_audit[("jao_maxbex", :verified)] = 2
    Euphemia.with_context(Euphemia.gate_context(day)) do
        Euphemia.reset_asof_audit!()
        redirect_stdout(devnull) do
            Euphemia._create_multi_zone_order_book_merit(zones, day; enrich_network=false,
                cached_zone_orders=cached, transfer_capacity=tc)
        end
        a = Euphemia.asof_audit()
        @test a["outages_transmission"][:verified] == 7
        @test a["jao_maxbex"][:verified] == 2
        Euphemia.reset_asof_audit!()
    end
end

