# Tests for the daily-forecast product's pure logic (bin/forecast_common.jl):
# eligibility gate, lead-day arithmetic, realized-day write guard, scoring math
# and the minimal JSON serializer. No DB, no solver — everything synthetic.

using Test, Dates, Statistics

include(joinpath(@__DIR__, "..", "bin", "forecast_common.jl"))

@testset "Forecast Tracking" begin

    @testset "footprint" begin
        @test length(FORECAST_FOOTPRINT) == 39
        @test "GR" in FORECAST_FOOTPRINT
        @test "CH" in FORECAST_FOOTPRINT
        @test allunique(FORECAST_FOOTPRINT)
    end

    @testset "lead_days arithmetic" begin
        today = Date(2026, 7, 11)
        @test forecast_lead_days(Date(2026, 7, 11), today) == 0   # nowcast
        @test forecast_lead_days(Date(2026, 7, 12), today) == 1   # day-ahead
        @test forecast_lead_days(Date(2026, 7, 18), today) == 7
        @test forecast_lead_days(Date(2026, 7, 10), today) == -1
    end

    @testset "realized-day write guard" begin
        latest_actual = Date(2026, 7, 10)
        # market day realized (or partially realized) → must throw
        @test_throws ErrorException assert_unrealized(Date(2026, 7, 10), latest_actual)
        @test_throws ErrorException assert_unrealized(Date(2026, 7, 9), latest_actual)
        @test_throws ErrorException assert_unrealized(Date(2020, 1, 1), latest_actual)
        # strictly beyond the horizon → allowed
        @test assert_unrealized(Date(2026, 7, 11), latest_actual)
        @test assert_unrealized(Date(2026, 7, 18), latest_actual)
    end

    @testset "eligibility gate" begin
        zones = ["GR", "BG", "RO"]
        full_load = Dict("GR" => 24, "BG" => 24, "RO" => 24)
        res_req = Set(["GR", "BG"])       # RO had no RES forecast on the last realized day

        # complete data → eligible
        ok, reason = eligibility_verdict(zones, full_load, res_req, Set(["GR", "BG"]), 500)
        @test ok
        @test occursin("all 3 zones", reason)

        # one zone with NO load forecast → ineligible, zone named
        ok, reason = eligibility_verdict(zones, Dict("GR" => 24, "BG" => 24), res_req,
                                         Set(["GR", "BG"]), 500)
        @test !ok
        @test occursin("RO", reason)
        @test occursin("load forecast", reason)

        # one zone with a SHORT load forecast (<20 hourly rows) → ineligible
        ok, reason = eligibility_verdict(zones, Dict("GR" => 24, "BG" => 19, "RO" => 24),
                                         res_req, Set(["GR", "BG"]), 500)
        @test !ok
        @test occursin("BG", reason)

        # exactly 20 hours passes the threshold
        ok, _ = eligibility_verdict(zones, Dict("GR" => 20, "BG" => 20, "RO" => 20),
                                    res_req, Set(["GR", "BG"]), 500)
        @test ok

        # RES forecast missing for a zone that had one on the last realized day
        ok, reason = eligibility_verdict(zones, full_load, res_req, Set(["GR"]), 500)
        @test !ok
        @test occursin("BG", reason)
        @test occursin("wind/solar", reason)

        # RO never had a RES forecast → its absence does NOT block
        ok, _ = eligibility_verdict(zones, full_load, res_req, Set(["GR", "BG"]), 500)
        @test ok

        # extra RES coverage beyond the baseline is fine
        ok, _ = eligibility_verdict(zones, full_load, res_req, Set(["GR", "BG", "RO"]), 500)
        @test ok

        # no ATC rows → ineligible
        ok, reason = eligibility_verdict(zones, full_load, res_req, Set(["GR", "BG"]), 0)
        @test !ok
        @test occursin("ATC", reason)
    end

    @testset "hourly_prices" begin
        # hourly book → identity
        hourly = Dict("20260712-0000" => 50.0, "20260712-0100" => 60.0)
        h = hourly_prices(hourly)
        @test h[DateTime(2026, 7, 12, 0)] == 50.0
        @test h[DateTime(2026, 7, 12, 1)] == 60.0
        @test length(h) == 2

        # 15-minute book → hourly mean
        quarter = Dict("20260712-0000" => 40.0, "20260712-0015" => 50.0,
                       "20260712-0030" => 60.0, "20260712-0045" => 70.0)
        h = hourly_prices(quarter)
        @test length(h) == 1
        @test h[DateTime(2026, 7, 12, 0)] ≈ 55.0
    end

    @testset "scoring math on a synthetic day" begin
        # sim = act + const → MAE = bias = const, corr = 1
        act = Float64[30, 40, 50, 60, 70, 80]
        sim = act .+ 5.0
        s = score_series(sim, act)
        @test s.n == 6
        @test s.mae ≈ 5.0
        @test s.bias ≈ 5.0
        @test s.corr ≈ 1.0

        # perfectly anti-correlated, known MAE/bias
        act2 = Float64[1, 2, 3, 4]
        sim2 = Float64[4, 3, 2, 1]
        s2 = score_series(sim2, act2)
        @test s2.corr ≈ -1.0
        @test s2.mae ≈ mean(abs.(sim2 .- act2))   # (3+1+1+3)/4 = 2
        @test s2.mae ≈ 2.0
        @test s2.bias ≈ 0.0 atol = 1e-12

        # hand-computed mixed example
        s3 = score_series([10.0, 20.0, 30.0], [12.0, 18.0, 33.0])
        @test s3.mae ≈ (2 + 2 + 3) / 3
        @test s3.bias ≈ (-2 + 2 - 3) / 3
        @test s3.corr ≈ cor([10.0, 20.0, 30.0], [12.0, 18.0, 33.0])

        # degenerate: constant series → corr is nothing (never NaN)
        s4 = score_series([50.0, 50.0, 50.0], [40.0, 45.0, 50.0])
        @test s4.corr === nothing
        @test s4.mae ≈ 5.0
        @test s4.bias ≈ 5.0

        # fewer than 3 pairs → corr nothing, MAE/bias still defined
        s5 = score_series([10.0, 20.0], [11.0, 19.0])
        @test s5.corr === nothing
        @test s5.mae ≈ 1.0

        # empty and mismatched inputs
        s6 = score_series(Float64[], Float64[])
        @test s6.n == 0 && s6.mae === nothing && s6.corr === nothing
        @test_throws ArgumentError score_series([1.0], Float64[])
    end

    @testset "json serializer" begin
        @test json_string(nothing) == "null"
        @test json_string(missing) == "null"
        @test json_string(NaN) == "null"          # JSON has no NaN
        @test json_string(Inf) == "null"
        @test json_string(1.5) == "1.5"
        @test json_string(42) == "42"
        @test json_string(true) == "true"
        @test json_string("a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\""
        @test json_string(Date(2026, 7, 12)) == "\"2026-07-12\""
        @test json_string(DateTime(2026, 7, 12, 13, 30)) == "\"2026-07-12T13:30:00Z\""
        @test json_string(Any[1, 2.5, nothing]) == "[1,2.5,null]"
        @test json_string([1.0, 2.5]) == "[1.0,2.5]"
        @test json_string(Dict("k" => [1, 2])) == "{\"k\":[1,2]}"
        s = json_string(Dict("zone" => "GR", "days" => [Dict("mae" => nothing)]))
        @test occursin("\"zone\":\"GR\"", s)
        @test occursin("\"mae\":null", s)
    end

end
