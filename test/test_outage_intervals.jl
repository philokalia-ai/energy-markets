# test_outage_intervals.jl — issue #370: per-interval outage reading.
# Pure: the majority-of-day rule on hourly values. DB: the interval path is
# deterministic across fresh queries and keeps the legacy schema; the legacy
# kill-switch path still runs.

using Test, Dates, DataFrames
using Euphemia
using Euphemia: _majority_available

@testset "majority-of-day rule on hourly availability" begin
    # no outage at all
    @test _majority_available(fill(Inf, 24)) == Inf
    # 11 affected hours -> no outage (legacy: < 12 h coverage does not count)
    v = fill(Inf, 24); v[1:11] .= 0.0
    @test _majority_available(v) == Inf
    # 12 affected hours at 0 -> full outage
    v = fill(Inf, 24); v[1:12] .= 0.0
    @test _majority_available(v) == 0.0
    # single interval covering the whole day at 90 MW -> 90 (legacy MIN)
    @test _majority_available(fill(90.0, 24)) == 90.0
    # the #370 example: 368 / 90 / 20 / 87 MW over four 6-hour intervals ->
    # the level that holds for at least 12 hours is 87 (20 x6, 87 x6 = 12 h)
    v = vcat(fill(368.0, 6), fill(90.0, 6), fill(20.0, 6), fill(87.0, 6))
    @test _majority_available(v) == 87.0
    # two messages of 8 h each at 0 on disjoint hours -> 16 h out -> outage
    v = fill(Inf, 24); v[1:8] .= 0.0; v[13:20] .= 0.0
    @test _majority_available(v) == 0.0
    # partial derate 300 for 20 h and 0 for 4 h -> 300 (0 holds only 4 h)
    v = fill(300.0, 24); v[1:4] .= 0.0
    @test _majority_available(v) == 300.0
    @test _majority_available(Float64[]) == Inf
end

@testset "DB: interval path deterministic, legacy schema, kill-switch" begin
    d = Date(2026, 8, 20)
    Euphemia.clear_generator_caches!()
    a = Euphemia.get_day_outages(d)
    Euphemia.clear_generator_caches!()
    b = Euphemia.get_day_outages(d)
    @test names(a) == ["asset_code", "available_capacity_mw", "stale_override"]
    @test a == b                                   # fresh queries agree
    @test issorted(a.asset_code)
    @test all(a.available_capacity_mw .>= 0)
    @test nrow(a) > 100
    # transmission caps: two fresh computations agree
    Euphemia.Network._TX_OUTAGE_DAY_CACHE |> empty!
    t1 = Euphemia.Network.tx_outage_caps(d)
    empty!(Euphemia.Network._TX_OUTAGE_DAY_CACHE)
    t2 = Euphemia.Network.tx_outage_caps(d)
    @test t1 == t2 && length(t1) > 0
    # legacy path still runs and returns the same schema
    withenv("EUPHEMIA_DISABLE_OUTAGE_INTERVALS" => "1") do
        Euphemia.clear_generator_caches!()
        l = Euphemia.get_day_outages(d)
        @test names(l) == names(a)
        # The asset SETS differ legitimately: the hourly majority rule counts
        # two 8-hour messages on disjoint hours (16 h out) where the legacy
        # message-level >= 12 h rule counted neither, and vice versa for a
        # long message whose reduced intervals cover < 12 h. They must still
        # be mostly the same fleet.
        la = Set(String.(skipmissing(l.asset_code))); aa = Set(a.asset_code)
        @info "legacy vs interval outage sets" legacy=length(la) intervals=length(aa) common=length(intersect(la, aa))
        @test length(intersect(la, aa)) / length(union(la, aa)) >= 0.8
    end
    Euphemia.clear_generator_caches!()
end
