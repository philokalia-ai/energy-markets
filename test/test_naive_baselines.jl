# Naive baselines + rMAE for the scoreboard (#431, bin/naive_baselines.jl): the
# weekday rule, availability by lead, Athens wall-clock keying on 23/25-hour days,
# missing lags leaving both sums, ratio-of-sums pooling. Pure, no DB.
#   julia --project=. test/test_naive_baselines.jl

using Test, Dates, Statistics, DataFrames

isdefined(@__MODULE__, :athens_market_day_window) ||
    include(joinpath(@__DIR__, "..", "bin", "forecast_common.jl"))
include(joinpath(@__DIR__, "..", "bin", "naive_baselines.jl"))

# Synthetic actuals with hand-checkable naive errors: price = 10 * (local day of
# month) + local hour / 100, so a D-1 lag errs by exactly 10, a D-7 lag by 70
# (within October). UTC hour starts over the Athens market days d0..d1.
loc_price(t) = (l = athens_local(t); 10.0 * day(l) + hour(l) / 100)
function panel(d0::Date, d1::Date; drop::Vector{Date}=Date[])
    ts = DateTime[]
    for d in d0:Day(1):d1
        d in drop && continue
        append!(ts, expected_market_day_hours(d))
    end
    return ts, loc_price.(ts)
end
actdict(ts, vs) = Dict(zip(ts, vs))
# the model: actual + 5 on every hour of the target day
sim_of(d) = (h = expected_market_day_hours(d); (h, loc_price.(h) .+ 5.0))

@testset "naive baselines (#431)" begin

    @testset "epftoolbox weekday rule (Athens market-day weekday)" begin
        @test dayofweek(Date(2026, 10, 25)) == Dates.Sunday     # last Sunday of October
        @test naive_lag_days("epf", Date(2026, 10, 24)) == 7     # Sat
        @test naive_lag_days("epf", Date(2026, 10, 25)) == 7     # Sun
        @test naive_lag_days("epf", Date(2026, 10, 26)) == 7     # Mon
        @test naive_lag_days("epf", Date(2026, 10, 27)) == 1     # Tue
        @test naive_lag_days("epf", Date(2026, 10, 23)) == 1     # Fri
        @test naive_lag_days("d1", Date(2026, 10, 26)) == 1
        @test naive_lag_days("d7", Date(2026, 10, 27)) == 7
        @test_throws ArgumentError naive_lag_days("d2", Date(2026, 10, 27))
    end

    @testset "availability at issue: d1/epf only at lead 1, d7 up to lead 7" begin
        @test naive_kinds_at(1) == ("d1", "d7", "epf")
        @test naive_kinds_at(2) == ("d7",)
        @test naive_kinds_at(7) == ("d7",)
        @test naive_kinds_at(8) == ()
        @test !naive_available("epf", 2) && !naive_available("d1", 2) && naive_available("d7", 7)
    end

    @testset "normal day, lead 1: errors 10 / 70 / weekday rule; model +5" begin
        ts, vs = panel(Date(2026, 10, 10), Date(2026, 10, 23))
        act = actdict(ts, vs); loc = local_price_index(ts, vs)
        st, sv = sim_of(Date(2026, 10, 23))                       # Friday: epf = D-1
        p = naive_zone_day(st, sv, act, loc, Date(2026, 10, 23), 1)
        @test p.n == 24
        @test p.model ≈ 5 * 24
        @test p.d1 ≈ 10 * 24
        @test p.d7 ≈ 70 * 24
        @test p.epf ≈ 10 * 24
        f = naive_board_fields([p], 1)
        @test f["n_naive"] == 24
        @test f["mae_paired"] ≈ 5
        @test f["mae_naive_d1"] ≈ 10 && f["mae_naive_d7"] ≈ 70 && f["mae_naive_epf"] ≈ 10
        @test f["rmae_d1"] ≈ 0.5 && f["rmae_d7"] ≈ 5 / 70 && f["rmae_epf"] ≈ 0.5
        # a Monday uses D-7 under the weekday rule
        ts2, vs2 = panel(Date(2026, 10, 12), Date(2026, 10, 19))
        st2, sv2 = sim_of(Date(2026, 10, 19))
        p2 = naive_zone_day(st2, sv2, actdict(ts2, vs2), local_price_index(ts2, vs2),
                            Date(2026, 10, 19), 1)
        @test p2.n == 24 && p2.epf ≈ 70 * 24 && p2.d1 ≈ 10 * 24
    end

    @testset "cv46: hourly_means, and a quarter slice scores as its hourly means" begin
        h0 = DateTime(2026, 10, 22, 21)
        ht = [h0 + Hour(k) for k in 0:3]
        hv = [1.5, 2.25, -3.0, 7.125]
        o, m = hourly_means(ht, hv)
        @test o == ht && m == hv && all(m .=== hv)               # hourly: identity, same order
        qt = [h0 + Minute(15k) for k in 0:15]
        qv = vcat(([v - 1, v + 1, v - 2, v + 2] for v in hv)...)
        o, m = hourly_means(qt, qv)
        @test o == ht && m ≈ hv                                   # quarters: the hour's mean
        o, m = hourly_means(vcat(ht, [h0]), vcat([missing, NaN], hv[3:4], [9.0]))
        @test o == [ht[3], ht[4], h0] && m == [hv[3], hv[4], 9.0] # missing/NaN skipped
        # naive_zone_day: a quarter slice whose quarters average to the hourly sim gives the
        # hourly slice's cells and sums (one cell per hour, not four)
        ts, vs = panel(Date(2026, 10, 10), Date(2026, 10, 23))
        act = actdict(ts, vs); loc = local_price_index(ts, vs)
        st, sv = sim_of(Date(2026, 10, 23))
        p = naive_zone_day(st, sv, act, loc, Date(2026, 10, 23), 1)
        qst = [t + Minute(15k) for t in st for k in 0:3]
        qsv = [v + d for v in sv for d in (-4.0, 4.0, -1.0, 1.0)]
        pq = naive_zone_day(qst, qsv, act, loc, Date(2026, 10, 23), 1)
        @test pq.n == p.n == 24
        @test pq.model ≈ p.model && pq.d1 ≈ p.d1 && pq.d7 ≈ p.d7 && pq.epf ≈ p.epf
    end

    @testset "q15_forecast_by_day: native decided per UTC day (review of #476 #2)" begin
        hd = Date(2025, 9, 30); qd = Date(2025, 10, 1)
        ht = [DateTime(hd) + Hour(h) for h in 0:23]; hv = [10.0 + h for h in 0:23]
        qt = [DateTime(qd) + Minute(15k) for k in 0:95]; qv = [100.0 + k for k in 0:95]
        fq, res = q15_forecast_by_day(vcat(ht, qt), vcat(hv, qv))
        @test res == "mixed"
        @test length(fq) == 96 + 96                              # hourly day replicated x4, quarter day native
        @test fq[DateTime(hd) + Hour(5) + Minute(30)] == 15.0    # hourly value on its quarter
        @test fq[DateTime(qd) + Minute(15 * 7)] == 107.0         # native quarter kept
        # the whole-window decision dropped the hourly day's :15/:30/:45 quarters
        fw, rw = q15_forecast(vcat(ht, qt), vcat(hv, qv))
        @test rw == "PT15M" && length(fw) == 24 + 96
        # single-type windows equal q15_forecast
        @test q15_forecast_by_day(ht, hv) == q15_forecast(ht, hv)
        @test q15_forecast_by_day(qt, qv) == q15_forecast(qt, qv)
    end

    @testset "leads 2-7: D-7 only, d1/epf absent" begin
        ts, vs = panel(Date(2026, 10, 10), Date(2026, 10, 23))
        st, sv = sim_of(Date(2026, 10, 23))
        for lead in (2, 7)
            p = naive_zone_day(st, sv, actdict(ts, vs), local_price_index(ts, vs),
                               Date(2026, 10, 23), lead)
            @test p.n == 24 && p.d7 ≈ 70 * 24
            @test p.d1 === nothing && p.epf === nothing
            f = naive_board_fields([p], lead)
            @test f["mae_naive_d7"] ≈ 70 && f["rmae_d7"] ≈ 5 / 70
            @test !haskey(f, "mae_naive_d1") && !haskey(f, "mae_naive_epf")
            @test !haskey(f, "rmae_d1") && !haskey(f, "rmae_epf")
        end
        p8 = naive_zone_day(st, sv, actdict(ts, vs), local_price_index(ts, vs), Date(2026, 10, 23), 8)
        @test p8.n == 0                                           # nothing known at issue
    end

    @testset "25-hour day (2026-10-25): repeated local hour" begin
        ts, vs = panel(Date(2026, 10, 17), Date(2026, 10, 26))
        # make the two occurrences of local 03:00 on the 25th differ: UTC 00:00 (EEST)
        # and UTC 01:00 (EET) both read 03:00 on the Athens wall clock
        i0 = findfirst(==(DateTime(2026, 10, 25, 0)), ts)
        i1 = findfirst(==(DateTime(2026, 10, 25, 1)), ts)
        @test athens_local(ts[i0]) == athens_local(ts[i1]) == DateTime(2026, 10, 25, 3)
        vs[i0] = 300.0; vs[i1] = 200.0
        loc = local_price_index(ts, vs)
        @test loc[DateTime(2026, 10, 25, 3)] ≈ 250.0               # lag day: mean of the two
        # target Monday 26th, lead 1, d1 at local 03:00 (01:00 UTC, EET) reads that mean
        @test naive_value(loc, DateTime(2026, 10, 26, 1), 1) ≈ 250.0
        # target = the 25-hour day itself: all 25 hours scored, both 03:00s share one lag
        st, sv = sim_of(Date(2026, 10, 25))
        @test length(st) == 25
        p = naive_zone_day(st, sv, actdict(ts, vs), loc, Date(2026, 10, 25), 1)
        @test p.n == 25
        @test naive_value(loc, DateTime(2026, 10, 25, 0), 1) == naive_value(loc, DateTime(2026, 10, 25, 1), 1)
    end

    @testset "23-hour day (2026-03-29): skipped local hour" begin
        ts, vs = panel(Date(2026, 3, 20), Date(2026, 3, 31))
        loc = local_price_index(ts, vs)
        @test !haskey(loc, DateTime(2026, 3, 29, 3))               # 03:00 local never happens
        # target = the 23-hour day: lags 03-28 / 03-22 are normal days -> 23 cells
        st, sv = sim_of(Date(2026, 3, 29))
        @test length(st) == 23
        @test naive_zone_day(st, sv, actdict(ts, vs), loc, Date(2026, 3, 29), 1).n == 23
        # target Monday 30th: d1 at local 03:00 has no lag -> that cell leaves both sums
        st, sv = sim_of(Date(2026, 3, 30))
        p = naive_zone_day(st, sv, actdict(ts, vs), loc, Date(2026, 3, 30), 1)
        @test p.n == 23
        @test p.model ≈ 5 * 23                                     # model sum on the same 23 cells
        @test naive_value(loc, DateTime(2026, 3, 30, 0), 1) === missing   # 00:00 UTC = 03:00 EEST on the 30th
        # at lead 2 only D-7 (03-23, a normal day) is needed -> all 24 cells
        @test naive_zone_day(st, sv, actdict(ts, vs), loc, Date(2026, 3, 30), 2).n == 24
    end

    @testset "missing lag: the naive is missing and the cell leaves both sums" begin
        ts, vs = panel(Date(2026, 10, 10), Date(2026, 10, 28); drop=[Date(2026, 10, 20)])
        act = actdict(ts, vs); loc = local_price_index(ts, vs)
        # Tue 27th, lead 1: D-7 = 20th missing -> no cell (d1 alone is not enough)
        st, sv = sim_of(Date(2026, 10, 27))
        p = naive_zone_day(st, sv, act, loc, Date(2026, 10, 27), 1)
        @test p.n == 0 && p.model == 0.0
        @test naive_zone_day(st, sv, act, loc, Date(2026, 10, 27), 3).n == 0
        # Wed 21st: lead 1 needs D-1 = 20th (missing) -> 0; lead 3 needs only D-7 -> 24
        st, sv = sim_of(Date(2026, 10, 21))
        @test naive_zone_day(st, sv, act, loc, Date(2026, 10, 21), 1).n == 0
        @test naive_zone_day(st, sv, act, loc, Date(2026, 10, 21), 3).n == 24
        # one non-finite lag price drops exactly one cell; a NaN sim drops one cell
        vs2 = copy(vs); vs2[findfirst(==(DateTime(2026, 10, 22, 10)), ts)] = NaN
        loc2 = local_price_index(ts, vs2)
        st, sv = sim_of(Date(2026, 10, 23))
        @test naive_zone_day(st, sv, act, loc2, Date(2026, 10, 23), 1).n == 23
        sv2 = copy(sv); sv2[5] = NaN
        @test naive_zone_day(st, sv2, act, loc, Date(2026, 10, 23), 1).n == 23
        # an unrealized target hour (no actual) is not a cell either
        act2 = copy(act); delete!(act2, st[1])
        @test naive_zone_day(st, sv, act2, loc, Date(2026, 10, 23), 1).n == 23
        # and a day with no cells leaves the cohort sums untouched
        good = naive_zone_day(st, sv, act, loc, Date(2026, 10, 23), 1)
        f = naive_board_fields([good, p], 1)
        @test f["n_naive"] == 24 && f["mae_paired"] ≈ 5 && f["rmae_d1"] ≈ 0.5
    end

    @testset "pooling: ratio of sums, never a mean of daily ratios; zero denominator" begin
        a = (n=10, model=100.0, d1=50.0, d7=100.0, epf=50.0)
        b = (n=20, model=100.0, d1=200.0, d7=100.0, epf=200.0)
        f = naive_board_fields([a, b], 1)
        @test f["rmae_d1"] ≈ 200 / 250                             # 0.8, not mean(2.0, 0.5) = 1.25
        @test f["mae_naive_d1"] ≈ 250 / 30
        @test f["mae_paired"] ≈ 200 / 30
        @test f["rmae_d7"] ≈ 1.0
        z = naive_board_fields([(n=3, model=6.0, d1=0.0, d7=0.0, epf=0.0)], 1)
        @test z["mae_naive_d1"] == 0.0 && z["rmae_d1"] === nothing && z["rmae_d7"] === nothing
        e = naive_board_fields(NamedTuple[], 1)
        @test e["n_naive"] == 0 && e["mae_paired"] === nothing && e["rmae_epf"] === nothing
        @test rmae(nothing, 3.0) === nothing && rmae(1.0, nothing) === nothing
    end

    @testset "cohort lookup and kill switch" begin
        parts = Dict(("GR", 1, "weather", Date(2026, 10, 23)) => (n=24, model=120.0, d1=240.0, d7=1680.0, epf=240.0),
                     ("GR", 1, "weather", Date(2026, 10, 24)) => (n=24, model=120.0, d1=240.0, d7=1680.0, epf=1680.0))
        sub = DataFrame(z=["GR", "GR", "GR"], lead_days=[1, 1, 1], mode=fill("weather", 3),
                        market_date=[Date(2026, 10, 23), Date(2026, 10, 24), Date(2026, 10, 25)])
        f = naive_cohort_fields(parts, sub)                        # 25th has no part: skipped
        @test f["n_naive"] == 48 && f["rmae_epf"] ≈ 240 / 1920
        @test naive_cohort_fields(nothing, sub) === nothing
        withenv("EXPORT_NAIVE" => "0") do
            @test !naive_enabled()
            @test naive_parts_or_nothing(sub) === nothing          # no query attempted
        end
        withenv("EXPORT_NAIVE" => nothing) do
            @test naive_enabled()
        end
    end
end
