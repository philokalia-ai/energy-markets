# cv46 P2 south-east cut limit (src/network/cv46_see_limit.jl). DB-free, < 1 s.
using Test
using Dates
using Euphemia
const NW = Euphemia.Network

row(s, d, tp, c) = (source_zone=s, sink_zone=d, time_period=tp, capacity=c)

function with_see(f, v)
    old = get(ENV, "EUPHEMIA_CV46_SEE_LIMIT", nothing)
    try
        v === nothing ? delete!(ENV, "EUPHEMIA_CV46_SEE_LIMIT") : (ENV["EUPHEMIA_CV46_SEE_LIMIT"] = v)
        f()
    finally
        old === nothing ? delete!(ENV, "EUPHEMIA_CV46_SEE_LIMIT") : (ENV["EUPHEMIA_CV46_SEE_LIMIT"] = old)
    end
end

@testset "cv46 SEE_LIMIT" begin
    @testset "switch and clamp scope" begin
        with_see(nothing) do
            @test !NW.cv46_see_on()
            @test !NW.cv46_see_noclamp("SK")
        end
        with_see("on") do
            @test NW.cv46_see_on()
            @test NW.cv46_see_noclamp("SK") && NW.cv46_see_noclamp("AT") && NW.cv46_see_noclamp("SI")
            @test !NW.cv46_see_noclamp("NO1") && !NW.cv46_see_noclamp("CH") && !NW.cv46_see_noclamp("BE")
        end
        with_see("bogus") do
            @test_throws ErrorException NW.cv46_see_on()
        end
    end

    @testset "frozen cut set: INNER only (calibration winner)" begin
        @test [c.name for c in NW.CV46_SEE_CUTS] == ["INNER"]
        @test Set(only(NW.CV46_SEE_CUTS).hubs) == Set(["HU", "RO", "SI", "SK"])
        @test !isdefined(NW, :cv46_see_cuts)
    end

    @testset "quantile matches percentile_cont" begin
        @test NW.cv46_quantile([1.0, 2.0, 3.0, 4.0, 5.0], 0.5) == 3.0
        @test NW.cv46_quantile(collect(0.0:100.0), 0.95) ≈ 95.0
        @test NW.cv46_quantile([10.0, 20.0], 0.95) ≈ 19.5
        @test isnan(NW.cv46_quantile(Float64[], 0.95))
    end

    @testset "cut caps from hourly physical flows" begin
        hourly = Dict{Tuple{DateTime,String,String},Float64}()
        t0 = DateTime(2026, 10, 1)
        for i in 0:(20 * 24 - 1)
            h = t0 + Hour(i)
            hourly[(h, "AT", "HU")] = 1000.0 + i          # INNER cut border
            hourly[(h, "CZ", "SK")] = 500.0                # INNER border (internal to OUTER)
            hourly[(h, "PL", "SK")] = 300.0                # INNER and OUTER border
            hourly[(h, "HR", "HU")] = 9999.0               # HR excluded (observed injection)
            hourly[(h, "SK", "HU")] = 7777.0               # internal to both cuts
            hourly[(h, "DE_LU", "AT")] = 2000.0            # OUTER only
            hourly[(h, "HU", "AT")] = -50.0                # negative rows floored at 0
        end
        caps = NW.cv46_cut_caps(hourly)                    # frozen default: INNER only
        inner = [1800.0 + i for i in 0:(20 * 24 - 1)]
        @test caps["INNER"] ≈ NW.cv46_quantile(inner, 0.95)
        @test !haskey(caps, "OUTER")
        # generic machinery with an explicit second cut
        OUTER = (name="OUTER", hubs=("AT", "CZ", "HU", "RO", "SI", "SK"))
        caps2 = NW.cv46_cut_caps(hourly, (only(NW.CV46_SEE_CUTS), OUTER))
        @test caps2["INNER"] ≈ caps["INNER"]
        @test caps2["OUTER"] ≈ 2300.0                      # DE_LU→AT + PL→SK; AT→HU, CZ→SK internal
        # fewer than 14×24 hours ⇒ cut inert
        short = Dict(k => v for (k, v) in hourly if k[1] < t0 + Hour(14 * 24 - 1))
        @test isempty(NW.cv46_cut_caps(short))
    end

    @testset "scaling: final inbound sum ≤ cap, min factor, untouched links" begin
        fp = Set(["DE_LU", "FR", "PL", "AT", "CZ", "SK", "HU", "SI", "RO", "IT-NORTH", "GR", "IT-SOUTH"])
        core = Set([(s, d) for s in NW.CV46_CORE_HUBS for d in NW.CV46_CORE_HUBS if s != d])
        rows = NamedTuple[]
        for tp in 1:24
            push!(rows, row("DE_LU", "HU", tp, 3000.0))   # mesh, both cuts
            push!(rows, row("FR", "RO", tp, 3000.0))      # mesh, both cuts
            push!(rows, row("AT", "HU", tp, 3000.0))      # INNER only
            push!(rows, row("CZ", "SK", tp, 2500.0))      # INNER only
            push!(rows, row("DE_LU", "AT", tp, 5000.0))   # OUTER only
            push!(rows, row("PL", "CZ", tp, 4000.0))      # OUTER only
            push!(rows, row("SK", "HU", tp, 2800.0))      # internal: untouched
            push!(rows, row("IT-NORTH", "SI", tp, 600.0)) # non-Core NTC: untouched
            push!(rows, row("IT-SOUTH", "GR", tp, 500.0)) # non-Core NTC: untouched
            push!(rows, row("HU", "DE_LU", tp, 3000.0))   # export direction: untouched
        end
        rows = [r for r in rows]
        jao_keys = Set((r.source_zone, r.sink_zone, r.time_period) for r in rows
                       if r.source_zone in NW.CV46_CORE_HUBS && r.sink_zone in NW.CV46_CORE_HUBS)
        caps = Dict("INNER" => 4400.0, "OUTER" => 6000.0)   # OUTER cap ignored by the frozen cut set
        orig = copy(rows)
        summary = NW.cv46_scale_cut_links!(rows, caps, core, jao_keys, fp)
        inbound(rs, cut, tp) = sum(r.capacity for r in rs if r.time_period == tp &&
                                   r.sink_zone in cut.hubs && !(r.source_zone in cut.hubs) &&
                                   (r.source_zone, r.sink_zone) in core)
        for cut in NW.CV46_SEE_CUTS, tp in 1:24
            @test inbound(rows, cut, tp) <= caps[cut.name] + 1e-9
        end
        cap_of(rs, s, d) = only(r.capacity for r in rs if r.source_zone == s && r.sink_zone == d && r.time_period == 1)
        get_cap(s, d) = cap_of(rows, s, d)
        f_in = 4400.0 / 11500.0; f_out = 6000.0 / 15000.0
        @test get_cap("DE_LU", "HU") ≈ 3000.0 * f_in
        @test get_cap("AT", "HU") ≈ 3000.0 * f_in
        @test get_cap("CZ", "SK") ≈ 2500.0 * f_in
        @test get_cap("DE_LU", "AT") == 5000.0                    # not into INNER: untouched
        @test get_cap("PL", "CZ") == 4000.0
        @test length(summary) == 1
        # generic machinery, two cuts: a link in both takes the smaller factor, applied once
        OUTER = (name="OUTER", hubs=("AT", "CZ", "HU", "RO", "SI", "SK"))
        two = (only(NW.CV46_SEE_CUTS), OUTER)
        rows2c = copy(orig)
        NW.cv46_scale_cut_links!(rows2c, caps, core, jao_keys, fp; cuts=two)
        for cut in two, tp in 1:24
            @test inbound(rows2c, cut, tp) <= caps[cut.name] + 1e-9
        end
        @test cap_of(rows2c, "DE_LU", "HU") ≈ 3000.0 * min(f_in, f_out)
        @test cap_of(rows2c, "AT", "HU") ≈ 3000.0 * f_in
        @test cap_of(rows2c, "DE_LU", "AT") ≈ 5000.0 * f_out
        @test get_cap("SK", "HU") == 2800.0
        @test get_cap("IT-NORTH", "SI") == 600.0
        @test get_cap("IT-SOUTH", "GR") == 500.0
        @test get_cap("HU", "DE_LU") == 3000.0
        s_in = only(x for x in summary if x.name == "INNER")
        @test s_in.hours_bind == 24 && s_in.pre_max ≈ 11500.0 && s_in.links == 4
        # order independence: reversed input gives the same capacities
        rev = reverse(copy(orig))
        NW.cv46_scale_cut_links!(rev, caps, core, jao_keys, fp)
        key(r) = (r.source_zone, r.sink_zone, r.time_period)
        @test Dict(key(r) => r.capacity for r in rev) == Dict(key(r) => r.capacity for r in rows)
        # a cap above the inbound sum is a no-op; a missing cap (inert cut) too
        rows2 = copy(orig)
        NW.cv46_scale_cut_links!(rows2, Dict("INNER" => 1e6), core, jao_keys, fp)
        @test rows2 == orig
        # non-JAO rows are never scaled
        rows3 = copy(orig)
        NW.cv46_scale_cut_links!(rows3, caps, core, Set{Tuple{String,String,Int}}(), fp)
        @test rows3 == orig
    end
end
