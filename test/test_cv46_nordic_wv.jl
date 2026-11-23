# cv46 P1 Nordic water value (src/merit_order/cv46_nordic_wv.jl). DB-free, < 1 s.
using Test
using Dates
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

    @testset "as-of cuts: record mode unchanged, contexts bounded (#477 finding 2)" begin
        D = Date(2026, 11, 13)
        # record mode (no context): the legacy cuts, and nothing is audited
        @test NWV._nwv_flow_cutoff(D) == D - Day(1)
        @test NWV._nwv_reservoir_ref(D) == D - Day(14)
        # lead 1 at the gate (either rule) resolves to the legacy cuts exactly
        for rule in (:fixed_10utc, :auction_local)
            Euphemia.with_context(Euphemia.gate_context(D; rule=rule)) do
                @test NWV._nwv_flow_cutoff(D) == D - Day(1)
                @test NWV._nwv_reservoir_ref(D) == D - Day(14)
            end
        end
        # retro lead 7 (issued D-7 06:30 UTC): no flow after the issuance date,
        # reservoir week w−2 seen from the issuance; both recorded as :latency_policy
        Euphemia.reset_asof_audit!()
        Euphemia.with_context(Euphemia.issuance_context(D, 7)) do
            c = NWV._nwv_flow_cutoff(D)
            @test c == D - Day(7)                       # last day read: D-8
            @test DateTime(c) <= Euphemia.current_context().as_of_utc
            @test NWV._nwv_reservoir_ref(D) == D - Day(7) + Day(1) - Day(14)
        end
        a = Euphemia.asof_audit()
        @test get(get(a, "physical_flows", Dict()), :latency_policy, 0) >= 1
        @test get(get(a, "hydro_fill", Dict()), :latency_policy, 0) >= 1
        # an issuance just after midnight never reads its own (incomplete) day
        ctx = Euphemia.ForecastContext(D, DateTime(2026, 11, 10, 0, 30), 3, :fixed_10utc, "t")
        Euphemia.with_context(ctx) do
            @test NWV._nwv_flow_cutoff(D) == Date(2026, 11, 9)
        end
        Euphemia.reset_asof_audit!()
    end

    @testset "ISO-week gap is W53-safe (#477 minor)" begin
        g = NWV._nwv_iso_week_gap
        @test NWV._nwv_iso_monday(2026, 1) == Date(2025, 12, 29)
        @test NWV._nwv_iso_monday(2026, 53) == Date(2026, 12, 28)
        @test g(2026, 46, 2026, 45) == 1
        @test g(2026, 1, 2025, 52) == 1                 # 2025 has 52 weeks: as the old 52·Δyear
        @test g(2027, 1, 2026, 53) == 1                 # old form: 52 + 1 − 53 = 0
        @test g(2027, 2, 2026, 52) == 3                 # old form: 2
        @test g(2021, 1, 2020, 53) == 1
        # identical to the old form whenever the earlier year has 52 weeks
        old(y1, w1, y2, w2) = 52 * (y1 - y2) + w1 - w2
        for (y1, w1, y2, w2) in ((2025, 3, 2024, 51), (2024, 10, 2024, 8), (2026, 1, 2025, 50))
            @test g(y1, w1, y2, w2) == old(y1, w1, y2, w2)
        end
    end

    @testset "short inputs are reported, never silent (#477 finding 3)" begin
        res = (S_now=5e6, S_prev=4.9e6, S_cap=9e6, gap=1, stale=0)
        out = (G=2000.0, R_min=1500.0)
        full = (n_cap=364 * 24, n_sample=336, res=res, out=out)
        @test isempty(NWV.nwv_input_gaps(full, 3000.0))
        # no flows at all ⇒ h = 1 (pre-cv46 value), reported
        g = NWV.nwv_input_gaps((; full..., n_cap=0, n_sample=0), 3000.0)
        @test length(g) == 1 && occursin("no hours", g[1])
        # thin windows
        g = NWV.nwv_input_gaps((; full..., n_cap=7000, n_sample=200), 3000.0)
        @test length(g) == 2 && occursin("7000/8736", g[1]) && occursin("200/336", g[2])
        @test isempty(NWV.nwv_input_gaps((; full..., n_cap=8000, n_sample=310), 3000.0))   # ≥ 90 %
        # reservoir / lagged output: reported only where the zone offers reservoir MW
        bad = (; full..., res=nothing, out=nothing)
        @test length(NWV.nwv_input_gaps(bad, 3000.0)) == 2
        @test isempty(NWV.nwv_input_gaps(bad, 0.0))                  # FI, DK1/DK2: structural
        @test length(NWV.nwv_input_gaps((; full..., res=(; res..., gap=2, stale=1)), 3000.0)) == 2
    end
end
