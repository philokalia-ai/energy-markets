# Unit tests for the 15-minute-resolution upsample primitive.
#
# `replicate_to_finer_resolution` is the load-bearing rule of the 15-min coupled
# clear: a coarser (hourly) zone's per-slot MW LEVEL is copied verbatim into each
# finer sub-slot — REPLICATE, never divide. These tests pin that contract; the
# full coupled reduces-to-hourly proof lives in test/scripts/test_15min_clearing.jl
# (needs the DuckDB extract + a MILP solver).

using Test
using Euphemia: replicate_to_finer_resolution

@testset "15-min upsample (replicate, not divide)" begin
    @testset "hourly → quarter-hourly replicates the level" begin
        d = Dict("20260403-0000" => 500.0, "20260403-0100" => 480.0)
        up = replicate_to_finer_resolution(d, 60, 15)
        @test length(up) == 8                       # 2 hours × 4 quarters
        # every quarter of hour 00 carries the SAME 500 MW (not 125)
        for mm in ("0000", "0015", "0030", "0045")
            @test up["20260403-$mm"] == 500.0
        end
        for mm in ("0100", "0115", "0130", "0145")
            @test up["20260403-$mm"] == 480.0
        end
        # energy conservation as a total-level invariant: sum of levels scales
        # by the sub-slot count (4), NOT preserved — because MW is a power level
        @test sum(values(up)) == 4 * sum(values(d))
    end

    @testset "30-min → 15-min" begin
        d = Dict("20260403-0000" => 100.0, "20260403-0030" => 200.0)
        up = replicate_to_finer_resolution(d, 30, 15)
        @test length(up) == 4
        @test up["20260403-0000"] == 100.0
        @test up["20260403-0015"] == 100.0
        @test up["20260403-0030"] == 200.0
        @test up["20260403-0045"] == 200.0
    end

    @testset "no hour/date rollover; slots stay within their hour" begin
        d = Dict("20260403-2300" => 42.0)
        up = replicate_to_finer_resolution(d, 60, 15)
        @test sort(collect(keys(up))) ==
              ["20260403-2300", "20260403-2315", "20260403-2330", "20260403-2345"]
    end

    @testset "identity when native == target" begin
        d = Dict("20260403-0000" => 1.0, "20260403-0015" => 2.0)
        @test replicate_to_finer_resolution(d, 15, 15) == d
    end

    @testset "target must divide native" begin
        @test_throws ErrorException replicate_to_finer_resolution(
            Dict("20260403-0000" => 1.0), 60, 45)
    end
end

using Dates
using Euphemia: MPCC

@testset "extract_time_period: timeslot ids (compile-time DateFormat)" begin
    old_id(dt) = "$(Dates.format(dt, "yyyymmdd"))-$(Dates.format(dt, "HHMM"))"   # the previous construction
    d0 = DateTime(2026, 3, 29)                                                    # a DST-change UTC day
    P96 = [old_id(d0 + Minute(15k)) for k in 0:95]
    @test all(MPCC.extract_time_period(d0 + Minute(15k), P96) == P96[k+1] for k in 0:95)
    P24 = [old_id(d0 + Hour(h)) for h in 0:23]
    @test MPCC.extract_time_period(d0 + Minute(30), P24) == "20260329-0100"       # fallback: next slot at/after
    @test_throws ErrorException MPCC.extract_time_period(d0 + Hour(22), P24[1:11])  # after the last slot (time of day)
    @test MPCC.extract_time_period(d0 + Hour(5), ["1", "2"]) == "6"                 # hourly-number periods
    @test all(Dates.format(dt, MPCC._TIMESLOT_FORMAT) == old_id(dt)
              for dt in DateTime(2024, 1, 1):Minute(15):DateTime(2024, 12, 31, 23, 45))
end
