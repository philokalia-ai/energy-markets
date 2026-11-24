# bin/horizon_forecast.jl zone_complete (cv46 downstream): a weekly-persistence proxy zone-day is complete at
# its OWN resolution. Hourly sources keep the old rule exactly (count == the day's hours: 24, 23/25 on DST);
# cv46 quarter-hour sources are complete at 96 (92/100 on DST days) instead of being dropped. DB-free.
using Test, Dates
using Euphemia   # the store comes from the environment (runtests: the extract, read-only)
isdefined(Main, :zone_complete) || include(joinpath(@__DIR__, "..", "bin", "horizon_forecast.jl"))

slots(d, res) = Dict(t => 1.0 for t in expected_market_day_slots(d, res))
drop1(s) = (k = sort(collect(keys(s))); Dict(t => 1.0 for t in k[2:end]))

@testset "horizon zone_complete: hourly unchanged, quarter-hour sources complete" begin
    T = Date(2026, 11, 26)
    @test zone_complete(slots(T, 60), T) && !zone_complete(drop1(slots(T, 60)), T)          # 24 / 23
    @test zone_complete(slots(T, 15), T) && !zone_complete(drop1(slots(T, 15)), T)          # 96 / 95
    @test length(slots(T, 15)) == 96
    # DST: Europe/Athens spring-forward (23 h / 92 quarters) and fall-back (25 h / 100 quarters)
    for (d, h, q) in ((Date(2026, 3, 29), 23, 92), (Date(2026, 10, 25), 25, 100))
        @test length(slots(d, 60)) == h && length(slots(d, 15)) == q
        @test zone_complete(slots(d, 60), d) && zone_complete(slots(d, 15), d)
        @test !zone_complete(slots(T, 60), d) && !zone_complete(slots(T, 15), d)            # 24/96 on a DST day
    end
    # hourly: identical to the pre-fix rule (length(hourly) == the day's hour count) over two years of days
    # and source sizes 1..26 hours (a single stamp has no spacing and counts as hourly, as before)
    same = true
    for d in Date(2025, 1, 1):Day(1):Date(2026, 12, 31), n in 1:26
        src = Dict(DateTime(d) + Hour(k) => 1.0 for k in 0:n-1)
        same &= zone_complete(src, d) == (n == length(expected_market_day_hours(d)))
    end
    @test same
end
