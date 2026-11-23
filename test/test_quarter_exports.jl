# Quarter-hour forecast days (cv46) in the exporters (bin/forecast_common.jl helpers used by bin/export_forecast_json.jl
# and bin/export_web_parquet.jl): per-day resolution from the stamps, step replication of hourly series, the actuals rule
# (native PT15M, else hourly replicated, flagged), and hourly days exactly as before. Pure, no DB.
#   julia --project=. test/test_quarter_exports.jl

using Test, Dates, DataFrames

isdefined(@__MODULE__, :athens_market_day_window) ||
    include(joinpath(@__DIR__, "..", "bin", "forecast_common.jl"))

@testset "quarter-hour days in the exporters" begin
    t0 = DateTime(2026, 12, 13, 23)
    hourly = [t0 + Hour(i) for i in 0:23]
    quarter = [t0 + Minute(15i) for i in 0:95]
    dst_q = [t0 + Minute(15i) for i in 0:99]          # a 25-hour DST day at quarter resolution

    @testset "day_resolution from the day's own stamps (mixed history: per day)" begin
        @test day_resolution(hourly) == RES_HOURLY == "PT60M"
        @test day_resolution(quarter) == RES_QUARTER == "PT15M"
        @test day_resolution(dst_q) == RES_QUARTER
        @test day_resolution(reverse(quarter)) == RES_QUARTER   # order-free
        @test day_resolution(hourly[1:1]) == RES_HOURLY         # degenerate day: hourly (the old behaviour)
        @test day_resolution(DateTime[]) == RES_HOURLY
    end

    @testset "slot_hour: hourly series read at the slot's hour on quarter days only" begin
        @test slot_hour(t0 + Minute(45), RES_QUARTER) == t0
        @test slot_hour(t0 + Minute(15), RES_QUARTER) == t0
        @test slot_hour(t0 + Hour(1), RES_QUARTER) == t0 + Hour(1)
        @test slot_hour(t0 + Hour(5), RES_HOURLY) == t0 + Hour(5)
        @test slot_hour(t0 + Minute(30), RES_HOURLY) == t0 + Minute(30)   # hourly days: exact stamp, never floored
    end

    actmap = Dict(("DE_LU", h) => 100.0 + Dates.hour(h) for h in hourly)
    q15map = Dict(("DE_LU", t) => 200.0 + Dates.minute(t) for t in quarter[1:90])   # last 6 quarters not native

    @testset "slot_actuals" begin
        a, r = slot_actuals("DE_LU", hourly, RES_HOURLY, actmap, q15map)          # hourly day: as before
        @test r == RES_HOURLY && a == Any[100.0 + Dates.hour(h) for h in hourly]
        a, r = slot_actuals("DE_LU", quarter, RES_QUARTER, actmap, q15map)        # native quarters
        @test r == RES_QUARTER && length(a) == 96
        @test a[2] == 215.0 && a[90] == 200.0 + Dates.minute(quarter[90])
        # slot by slot: a quarter without a native actual takes its hour's actual (#474 review #1)
        @test all(i -> a[i] == 100.0 + Dates.hour(floor(quarter[i], Hour)), 91:96)
        # 2025-10-01: the first Athens hour still PT60M, the rest native quarters
        first_hourly = Dict(("GR", t) => 300.0 + Dates.minute(t) for t in quarter[5:96])
        hr = Dict(("GR", h) => 50.0 + Dates.hour(h) for h in hourly)
        a, r = slot_actuals("GR", quarter, RES_QUARTER, hr, first_hourly)
        @test r == RES_QUARTER
        @test a[1:4] == fill(50.0 + Dates.hour(t0), 4)                             # hour 0: hourly, replicated
        @test a[5] == 300.0 && a[96] == 300.0 + Dates.minute(quarter[96])          # native from 00:00 Athens + 1 h
        a, r = slot_actuals("DE_LU", quarter, RES_QUARTER, Dict{Tuple{String,DateTime},Float64}(), q15map)
        @test all(isnothing, a[91:96])                                             # neither published: null
        a, r = slot_actuals("GR", quarter, RES_QUARTER,
                            Dict(("GR", h) => 50.0 + Dates.hour(h) for h in hourly), q15map)   # no native: hourly x4
        @test r == RES_HOURLY && all(i -> a[i] == 50.0 + Dates.hour(floor(quarter[i], Hour)), 1:96)
        @test a[1] == a[4] != a[5]
        a, r = slot_actuals("PL", quarter, RES_QUARTER, actmap, q15map)            # nothing settled at all
        @test r == RES_HOURLY && all(isnothing, a)
    end

    @testset "any_quarter_day over an export's price frame (grouped per zone-day-lead-mode)" begin
        mk(ts, d) = DataFrame(z="GR", market_date=d, lead_days=1, mode="weather", t=ts)
        mixed = vcat(mk(hourly, Date(2026, 12, 13)), mk(quarter, Date(2026, 12, 14)))
        @test any_quarter_day(mixed)
        @test !any_quarter_day(mk(hourly, Date(2026, 12, 13)))
        @test !any_quarter_day(mk(DateTime[], Date(2026, 12, 13)))
        # two hourly days whose stamps interleave do not look like a quarter day (grouped per day)
        @test !any_quarter_day(vcat(mk(hourly, Date(2026, 12, 13)), mk(hourly .+ Minute(15), Date(2026, 12, 14))))
        tr = select(mixed, :z, :market_date, :lead_days, :mode => :track, :t)        # the map frames carry `track`
        @test any_quarter_day(tr)
        @test quarter_days(mixed) == [Date(2026, 12, 14)]                           # only the quarter day's date
    end

    @testset "q15_actual_map reads the quarter days only, once per window (#474 review #7)" begin
        calls = Tuple{Date,Date}[]
        stub(lo, hi) = (push!(calls, (lo, hi));
                        DataFrame(z=["GR", "GR"], t=[quarter[1], hourly[2]], act=[1.5, 9.0], res=["PT15M", "PT60M"]))
        @test isempty(q15_actual_map(Date[]; reader=stub)) && isempty(calls)       # no quarter day: no read
        m = q15_actual_map([Date(2026, 12, 14), Date(2026, 12, 16)]; reader=stub)
        @test calls == [(Date(2026, 12, 13), Date(2026, 12, 16))]                   # day before the first .. last
        @test m == Dict(("GR", quarter[1]) => 1.5)                                  # PT15M rows only
        q15_actual_map([Date(2026, 12, 14), Date(2026, 12, 16)]; reader=stub)
        @test length(calls) == 1                                                    # memoised: the map pass reuses it
    end
end
