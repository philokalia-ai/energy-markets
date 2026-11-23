# cv46 P1 Nordic water value (src/merit_order/cv46_nordic_wv.jl). DB-free, < 1 s.
using Test
using Euphemia
const NWV = Euphemia.MeritOrderBook

@testset "cv46 P1 Nordic water value" begin
    @testset "scope" begin
        gp = NWV.get_zone_profile
        @test all(z -> NWV.nwv_in_scope(gp(z)), ["NO4", "SE1", "SE2", "FI"])
        @test !any(z -> NWV.nwv_in_scope(gp(z)), ["NO1", "NO2", "NO3", "NO5", "SE3", "SE4", "CH", "AT", "DE_LU", "GR"])
    end

    @testset "headroom" begin
        nx = Float64[100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]
        @test NWV.nwv_headroom(nx, 850.0, 0.0) == 0.8
        @test NWV.nwv_headroom(nx, 850.0, 300.0) == 0.5        # outage cut 850 → 550
        @test NWV.nwv_headroom(nx, 850.0, 2000.0) == 0.0       # corridor closed
        @test NWV.nwv_headroom(nx, 30.0, 0.0) == 1.0           # net importer
        @test NWV.nwv_headroom(Float64[], 850.0, 0.0) == 1.0   # no data
        Eb = Dict("SE3" => 7000.0, "NO3" => 500.0, "FI" => 300.0)
        @test NWV.nwv_capability_cut(Eb, Dict{String,Float64}()) == 0.0
        @test NWV.nwv_capability_cut(Eb, Dict("SE3" => 5000.0, "FI" => 400.0)) == 2000.0
    end

    @testset "unavoidable release" begin
        # Rising, far from full: overflow 0 ⇒ the lagged lower envelope.
        @test NWV.nwv_unavoidable_base(; S_now=5e6, S_prev=4.9e6, S_cap=9e6, G=2000.0, R_min=1500.0) == 1500.0
        # Near full: inflow (2000 + 168000/168 = 3000 MW) minus room/168 (84000/168 = 500) = 2500.
        @test NWV.nwv_unavoidable_base(; S_now=8.916e6, S_prev=8.748e6, S_cap=9e6, G=2000.0, R_min=1500.0) ≈ 2500.0
        # Above demonstrated capacity: all inflow must run.
        @test NWV.nwv_unavoidable_base(; S_now=9.1e6, S_prev=9.1e6, S_cap=9.1e6, G=2000.0, R_min=0.0) == 2000.0
        # Per hour: capped by Q, net of spill and dropped-border exports.
        @test NWV.nwv_unavoidable_hour(2500.0, 2000.0, 0.0, 0.0) == 2000.0
        @test NWV.nwv_unavoidable_hour(2500.0, 4000.0, 600.0, 900.0) == 1000.0
        @test NWV.nwv_unavoidable_hour(1500.0, 4000.0, 0.0, 5000.0) == 0.0
    end

    @testset "storable value" begin
        gas, p_s = 95.0, 1.0
        for shape in (0.6, 0.85, 1.1), m in (0.0, 0.3, 1.0)
            old = gas * (0.35 + 0.65 * m) * shape
            # pass 1, h = 1: the pre-cv46 expression bit for bit
            @test NWV.nwv_storable_value(gas, shape, m, 1.0, nothing, p_s) === old
            # pass 1, h < 1: never above the old value, never above cap, ≥ p_s
            for h in (0.0, 0.5, 0.9)
                wv, B, cap = NWV.nwv_storable_parts(gas, shape, m, h, nothing, p_s)
                @test wv <= old + 1e-12 && wv <= cap && wv >= p_s
                @test B ≈ h * 0.35 * gas * shape + (1 - h) * p_s
            end
            # m → 1 ⇒ cap whatever h or X (2026 Q1 drawdown preserved)
            @test NWV.nwv_storable_value(gas, shape, 1.0, 0.0, 500.0, p_s) ≈ gas * shape
        end
        # pass 2: B = h·X + (1−h)·p_s, clamped to [p_s, cap]
        wv, B, cap = NWV.nwv_storable_parts(95.0, 1.0, 0.0, 0.9, 30.0, 1.0)
        @test B ≈ 0.9 * 30 + 0.1 && wv ≈ B && cap == 95.0
        wv, B, cap = NWV.nwv_storable_parts(95.0, 1.0, 0.5, 1.0, 400.0, 1.0)
        @test B == cap && wv == cap                           # never above cap
        wv, B, _ = NWV.nwv_storable_parts(95.0, 1.0, 0.0, 1.0, -20.0, 1.0)
        @test B == 1.0 && wv == 1.0                           # never below the spill price
        wv, B, cap = NWV.nwv_storable_parts(95.0, 0.6, 0.4, 0.8, 40.0, 1.0)
        @test wv ≈ B + 0.4 * (cap - B)
    end

    @testset "reachable displaced supply" begin
        @test NWV.nwv_reference(20.0, 1000.0, Dict("SE3" => 60.0), Dict("SE3" => 3000.0)) ≈ 50.0
        # counterparties without a pass-1 price are ignored
        @test NWV.nwv_reference(20.0, 1000.0, Dict{String,Float64}(), Dict("SE3" => 3000.0)) ≈ 20.0
        @test NWV.nwv_reference(nothing, 0.0, Dict("FI" => 40.0), Dict("FI" => 0.0)) === nothing
    end

    @testset "pass-2 refs: anchor refs untouched, P1 zones added" begin
        nodes = ["DE_LU", "NO2", "SE2", "SE3", "NO4", "GR"]
        prices = Dict(z => Dict("20261019-0000" => 10.0 * i, "20261019-0100" => 11.0 * i)
                      for (i, z) in enumerate(nodes))
        ob = Euphemia.MPCC.MPCCOrderBook(Euphemia.MarketOrders.MarketOrder[], nodes,
                                         ["1", "2"], (-500.0, 4000.0), nothing)
        r = Euphemia.MPCC.MPCCResult(:optimal, 0.0, prices, Dict{String,Float64}(),
            Dict{String,Float64}(), Dict{String,Float64}(),
            Dict{String,Dict{String,Float64}}(), 0.0, 0.0, "test", "")
        x = Euphemia.mz_extract_anchor_inputs(ob, r; apply_zone_profiles=true)
        @test sort(x.anchored) == ["NO2", "SE3"]                        # anchored set unchanged
        base = Euphemia.compute_opportunity_anchor_refs(x.anchored, prices, nothing)
        for z in x.anchored
            @test x.refs[z] == base[z]                                  # anchor refs untouched
        end
        @test x.refs["SE2"] == prices["SE2"] && x.refs["NO4"] == prices["NO4"]   # P1 zones rebuilt
        @test !haskey(x.refs, "GR") && !haskey(x.refs, "DE_LU")
        p1 = NWV.nwv_unpack_prices(x.refs)
        @test p1 !== nothing && sort(collect(keys(p1))) == sort(nodes) && p1["SE3"] == prices["SE3"]
        @test NWV.nwv_unpack_prices(base) === nothing
        # profiles off ⇒ nothing packed
        @test isempty(Euphemia.mz_extract_anchor_inputs(ob, r; apply_zone_profiles=false).refs)
    end
end
