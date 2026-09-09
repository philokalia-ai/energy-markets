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

@testset "interval semantics fixtures (review 2026-09-09 P2)" begin
    using Euphemia: _hourly_availability, _day_level_capacity
    d = Date(2026, 8, 20); D = DateTime(d)
    function cap(rows)
        h, c, _, _ = _hourly_availability(rows, d)
        return _day_level_capacity(h["u"], c["u"])
    end
    # 00:30–11:30 full outage: eleven hours, touches twelve buckets -> no outage
    @test cap([("u", 0.0, D + Minute(30), D + Hour(11) + Minute(30))]) == Inf
    # 11:30–23:30: twelve hours -> outage at 0
    @test cap([("u", 0.0, D + Hour(11) + Minute(30), D + Hour(23) + Minute(30))]) == 0.0
    # eight-hour full outage + separate eight-hour full outage (two messages) -> 16 h -> outage
    @test cap([("u", 0.0, D, D + Hour(8)), ("u", 0.0, D + Hour(12), D + Hour(20))]) == 0.0
    # eight-hour full outage alone -> below the rule (the scalar approximation's known gap)
    @test cap([("u", 0.0, D, D + Hour(8))]) == Inf
    # partial derate 300 MW all day + 4 h at 0 -> 300 (0 holds only 4 h)
    @test cap([("u", 300.0, D, D + Day(1)), ("u", 0.0, D + Hour(2), D + Hour(6))]) == 300.0
    # the #370 example: 368 / 90 / 20 / 87 MW over four 6-hour intervals -> 87
    @test cap([("u", 368.0, D, D + Hour(6)), ("u", 90.0, D + Hour(6), D + Hour(12)),
               ("u", 20.0, D + Hour(12), D + Hour(18)), ("u", 87.0, D + Hour(18), D + Day(1))]) == 87.0
    # message crossing midnight: only the part inside the day counts (06 h in-day -> no outage)
    @test cap([("u", 0.0, D - Hour(10), D + Hour(6))]) == Inf
    @test cap([("u", 0.0, D - Hour(10), D + Hour(14))]) == 0.0
    # earliest starts
    h, c, z, a = _hourly_availability([("u", 200.0, D - Hour(30), D + Day(1)), ("u", 0.0, D + Hour(3), D + Hour(20))], d)
    @test z["u"] == D + Hour(3) && a["u"] == D - Hour(30)
end

@testset "duration rule and issuance-bounded per-unit probes (#369/#373 review)" begin
    using Euphemia: _per_unit_upper, PER_UNIT_GEN_LATENCY, with_context, gate_context, issuance_context
    # legacy: no bound
    @test _per_unit_upper(Date(2026, 8, 20)) === nothing
    # lead 1: as_of D-1 10:00 − 6 d
    @test with_context(gate_context(Date(2026, 8, 20))) do; _per_unit_upper(Date(2026, 8, 20)); end ==
          DateTime(2026, 8, 19, 10) - PER_UNIT_GEN_LATENCY
    # lead 3: as_of D-3 06:30 − 6 d
    @test with_context(issuance_context(Date(2026, 8, 20), 3)) do; _per_unit_upper(Date(2026, 8, 20)); end ==
          DateTime(2026, 8, 17, 6, 30) - PER_UNIT_GEN_LATENCY
    # the fleet-probe SQL fragment carries the literal cutoff inside a context
    frag = with_context(gate_context(Date(2026, 8, 20))) do; Euphemia._fleet_probe_upper(Date(2026, 8, 20)); end
    @test occursin("2026-08-13 10:00:00", frag)
    @test Euphemia._fleet_probe_upper(Date(2026, 8, 20)) == "\$2::timestamp"
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
