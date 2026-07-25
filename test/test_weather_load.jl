# Pure unit tests for the D-n LOAD model helpers (bin/weather_load.jl) — feature
# construction, EU-DST local time, holiday computus, the ridge fit/predict, and
# the open-meteo response parser. No network, no DB.

using Test, Dates, Statistics, LinearAlgebra

include(joinpath(@__DIR__, "..", "bin", "weather_load.jl"))

@testset "Weather-load model (pure)" begin
    @testset "feature vector layout" begin
        @test NFEAT_LOAD == 207
        hol = Set{Date}()
        x = load_feature_vector(DateTime(2025, 1, 15, 12), 5.0, 200.0, 6.0, 1, hol, Date(2022, 7, 1))
        @test length(x) == 207
        # exactly one hour-of-week one-hot in the first 168, holiday flag 0
        @test count(!iszero, x[1:168]) == 1
        @test sum(x[1:168]) == 1.0
        @test all(iszero, x[169:192])        # holiday×hod block (not a holiday)
        @test x[193] == 0.0                  # holiday flag
        # heating degree-hours positive (T=5 < 16.5 base), cooling zero
        @test x[194] > 0                     # HDH  (T=5 < 16.5 base)
        @test x[195] == 0.0                  # CDH  (T=5 < 21 base)
        @test x[202] == 200.0 / 100          # GHI/100 (block: 168+24+1+8 = 201, GHI at 202)
    end

    @testset "hour-of-week one-hot at local time" begin
        # 2025-01-15 12:00 UTC, tz_base=1 (CET winter) → 13:00 local, Wednesday
        hol = Set{Date}()
        x = load_feature_vector(DateTime(2025, 1, 15, 12), 5.0, 0.0, 5.0, 1, hol, Date(2022, 7, 1))
        lt = local_time_load(1, DateTime(2025, 1, 15, 12))
        @test hour(lt) == 13
        how = (dayofweek(lt) - 1) * 24 + hour(lt) + 1
        @test x[how] == 1.0
    end

    @testset "EU DST local time" begin
        # January = winter (standard offset); July = summer (+1)
        @test local_time_load(1, DateTime(2025, 1, 15, 12)) == DateTime(2025, 1, 15, 13)
        @test local_time_load(1, DateTime(2025, 7, 15, 12)) == DateTime(2025, 7, 15, 14)
        @test local_time_load(2, DateTime(2025, 1, 15, 12)) == DateTime(2025, 1, 15, 14)  # EET
        @test local_time_load(2, DateTime(2025, 7, 15, 12)) == DateTime(2025, 7, 15, 15)  # EEST
    end

    @testset "Easter computus (known values)" begin
        # 2024: Western Easter Mar 31; Orthodox Easter May 5 (they differ that year)
        @test easter_gregorian(2024) == Date(2024, 3, 31)
        @test easter_orthodox(2024) == Date(2024, 5, 5)
        # 2025: both fall on Apr 20
        @test easter_gregorian(2025) == Date(2025, 4, 20)
        @test easter_orthodox(2025) == Date(2025, 4, 20)
    end

    @testset "holiday tables" begin
        gr = holidays_for_country("GR", 2025:2025)
        @test Date(2025, 1, 1) in gr
        @test Date(2025, 8, 15) in gr           # Dormition
        @test Date(2025, 3, 25) in gr           # Independence Day
        @test (easter_orthodox(2025) + Day(1)) in gr   # Orthodox Easter Monday
        de = holidays_for_country("DE", 2025:2025)
        @test Date(2025, 10, 3) in de           # German Unity Day
        @test (easter_gregorian(2025) + Day(1)) in de  # Western Easter Monday
        @test isempty(holidays_for_country("ZZ", 2025:2025))  # unknown → empty (safe)
    end

    @testset "ridge fit/predict recovers a linear map" begin
        # y = 3 + 2*f1 - 1*f2 exactly; two informative features + noise cols
        n = 400
        f1 = randn(n); f2 = randn(n)
        X = hcat(f1, f2, randn(n), randn(n))
        y = 3.0 .+ 2.0 .* f1 .- 1.0 .* f2
        m = ridge_fit_load(X, y, 1e-8)
        yhat = ridge_predict_load(m.coef, m.mu_x, m.sd_x, m.mu_y, X)
        @test maximum(abs.(yhat .- y)) < 1e-3
    end

    @testset "open-meteo parse (single + multi location, nulls)" begin
        body = """[
          {"hourly":{"time":["2025-07-01T00:00","2025-07-01T01:00"],
                     "temperature_2m":[20.0,null],"shortwave_radiation":[0.0,5.0]}},
          {"hourly":{"time":["2025-07-01T00:00","2025-07-01T01:00"],
                     "temperature_2m":[10.0,11.0],"shortwave_radiation":[1.0,2.0]}}
        ]"""
        cells = [(1.0, 2.0), (3.0, 4.0)]
        out = parse_load_weather_response(body, cells)
        @test out[(1.0, 2.0)][DateTime(2025, 7, 1, 0)] == (20.0, 0.0)
        # hour with a null temperature is dropped
        @test !haskey(out[(1.0, 2.0)], DateTime(2025, 7, 1, 1))
        @test out[(3.0, 4.0)][DateTime(2025, 7, 1, 1)] == (11.0, 2.0)
    end

    @testset "zone_mean_series population weighting + predict skips gaps" begin
        zm = Dict("cities" => [[1.0, 2.0, 3.0], [3.0, 4.0, 1.0]])  # weights 3 and 1
        weather = Dict(
            (1.0, 2.0) => Dict(DateTime(2025, 7, 1, 0) => (10.0, 100.0)),
            (3.0, 4.0) => Dict(DateTime(2025, 7, 1, 0) => (2.0, 0.0)))
        s = zone_mean_series(zm, weather)
        # weighted mean T = (3*10 + 1*2)/4 = 8.0 ; GHI = (3*100)/4 = 75.0
        @test s[DateTime(2025, 7, 1, 0)][1] ≈ 8.0
        @test s[DateTime(2025, 7, 1, 0)][2] ≈ 75.0
        # trailing MA undefined (only 1 hour) → nothing
        @test trailing_ma_temp(s, DateTime(2025, 7, 1, 0)) === nothing
    end
end
