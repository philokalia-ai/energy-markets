# Tests for the daily-forecast product's pure logic (bin/forecast_common.jl):
# eligibility gate, lead-day arithmetic, realized-day write guard, scoring math
# and the minimal JSON serializer. No DB, no solver — everything synthetic.

using Test, Dates, Statistics

include(joinpath(@__DIR__, "..", "bin", "weather_vintage.jl"))
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

    @testset "EU DST rule (pure, no TimeZones.jl)" begin
        # last Sundays, hand-checked against a calendar
        @test last_sunday(2026, 3) == Date(2026, 3, 29)
        @test last_sunday(2026, 10) == Date(2026, 10, 25)
        @test last_sunday(2025, 3) == Date(2025, 3, 30)
        @test last_sunday(2025, 10) == Date(2025, 10, 26)
        @test last_sunday(2024, 3) == Date(2024, 3, 31)   # month ends on Sunday

        s, e = eu_dst_window(2026)
        @test s == DateTime(2026, 3, 29, 1)    # last Sunday of March, 01:00 UTC
        @test e == DateTime(2026, 10, 25, 1)   # last Sunday of October, 01:00 UTC

        @test is_eu_summer_time(DateTime(2026, 7, 12, 20))          # mid-summer
        @test !is_eu_summer_time(DateTime(2026, 1, 15, 12))         # mid-winter
        @test !is_eu_summer_time(DateTime(2026, 3, 29, 0, 59))      # 1 min before switch
        @test is_eu_summer_time(DateTime(2026, 3, 29, 1))           # at the switch
        @test is_eu_summer_time(DateTime(2026, 10, 25, 0, 59))      # 1 min before fallback
        @test !is_eu_summer_time(DateTime(2026, 10, 25, 1))         # at the fallback

        @test athens_utc_offset(DateTime(2026, 7, 12, 20)) == Hour(3)
        @test athens_utc_offset(DateTime(2026, 1, 15, 12)) == Hour(2)
    end

    @testset "athens_date" begin
        # 22:30 UTC in summer = 01:30 Athens next day
        @test athens_date(DateTime(2026, 7, 12, 22, 30)) == Date(2026, 7, 13)
        # 20:00 UTC in summer = 23:00 Athens same day
        @test athens_date(DateTime(2026, 7, 12, 20, 0)) == Date(2026, 7, 12)
        # 22:30 UTC in winter = 00:30 Athens next day
        @test athens_date(DateTime(2026, 1, 15, 22, 30)) == Date(2026, 1, 16)
        # 21:30 UTC in winter = 23:30 Athens same day
        @test athens_date(DateTime(2026, 1, 15, 21, 30)) == Date(2026, 1, 15)
    end

    @testset "athens_day_start_utc (both regimes + transition days)" begin
        # summer (EEST, UTC+3): local midnight = 21:00 UTC previous day
        @test athens_day_start_utc(Date(2026, 7, 13)) == DateTime(2026, 7, 12, 21)
        # winter (EET, UTC+2): local midnight = 22:00 UTC previous day
        @test athens_day_start_utc(Date(2026, 1, 15)) == DateTime(2026, 1, 14, 22)

        # March transition Sunday (2026-03-29): midnight is still EET → 22:00 UTC
        @test athens_day_start_utc(Date(2026, 3, 29)) == DateTime(2026, 3, 28, 22)
        # the day after: EEST is in force → 21:00 UTC
        @test athens_day_start_utc(Date(2026, 3, 30)) == DateTime(2026, 3, 29, 21)
        # October transition Sunday (2026-10-25): midnight is still EEST → 21:00 UTC
        @test athens_day_start_utc(Date(2026, 10, 25)) == DateTime(2026, 10, 24, 21)
        # the day after: back to EET → 22:00 UTC
        @test athens_day_start_utc(Date(2026, 10, 26)) == DateTime(2026, 10, 25, 22)

        # window lengths: 24 h normally, 23 h spring-forward, 25 h fall-back
        @test length(expected_market_day_hours(Date(2026, 7, 13))) == 24
        @test length(expected_market_day_hours(Date(2026, 1, 15))) == 24
        @test length(expected_market_day_hours(Date(2026, 3, 29))) == 23
        @test length(expected_market_day_hours(Date(2026, 10, 25))) == 25

        # window is half-open and contiguous
        t0, t1 = athens_market_day_window(Date(2026, 7, 13))
        @test t0 == DateTime(2026, 7, 12, 21) && t1 == DateTime(2026, 7, 13, 21)
        hrs = expected_market_day_hours(Date(2026, 7, 13))
        @test hrs[1] == t0 && hrs[end] == t1 - Hour(1)
        @test all(diff(hrs) .== Hour(1))
    end

    @testset "stitch_market_day" begin
        d = Date(2026, 7, 13)           # window 2026-07-12T21:00 → 2026-07-13T21:00
        # synthetic UTC-day clears: prev = full 24 h of UTC day 07-12,
        # curr = UTC day 07-13 with the unpublished local tail (21:00–23:00) absent
        prev = Dict(DateTime(2026, 7, 12, h) => 100.0 + h for h in 0:23)
        curr = Dict(DateTime(2026, 7, 13, h) => 200.0 + h for h in 0:20)

        st = stitch_market_day(d, prev, curr)
        @test isempty(st.missing_hours)
        @test length(st.stitched) == 24
        @test length(st.expected) == 24
        # head: last 3 hours of the prev UTC-day clear
        @test st.stitched[DateTime(2026, 7, 12, 21)] == 121.0
        @test st.stitched[DateTime(2026, 7, 12, 23)] == 123.0
        # body: hours 00–20 of the curr UTC-day clear
        @test st.stitched[DateTime(2026, 7, 13, 0)] == 200.0
        @test st.stitched[DateTime(2026, 7, 13, 20)] == 220.0
        # out-of-window hours never leak in
        @test !haskey(st.stitched, DateTime(2026, 7, 12, 20))
        @test !haskey(st.stitched, DateTime(2026, 7, 13, 21))

        # a missing hour inside the window → refusal signal (missing_hours named)
        curr_short = copy(curr)
        delete!(curr_short, DateTime(2026, 7, 13, 5))
        st2 = stitch_market_day(d, prev, curr_short)
        @test st2.missing_hours == [DateTime(2026, 7, 13, 5)]
        @test length(st2.stitched) == 23

        # missing head (prev clear truncated) is also caught
        st3 = stitch_market_day(d, Dict{DateTime,Float64}(), curr)
        @test length(st3.missing_hours) == 3
        @test st3.missing_hours[1] == DateTime(2026, 7, 12, 21)

        # prev never contributes hours that belong to the curr UTC day, even if
        # both clears carry them (curr wins by window partition, values differ)
        prev_overlap = merge(prev, Dict(DateTime(2026, 7, 13, 0) => -1.0))
        st4 = stitch_market_day(d, prev_overlap, curr)
        @test st4.stitched[DateTime(2026, 7, 13, 0)] == 200.0
    end

    @testset "hour-level write guard" begin
        made = DateTime(2026, 7, 12, 20, 5)
        future = [DateTime(2026, 7, 12, 21) + Hour(k) for k in 0:23]
        @test assert_hours_unrealized(future, made)
        # an hour equal to the prediction instant → refused (strictly-after rule)
        @test_throws ErrorException assert_hours_unrealized(
            vcat(future, [DateTime(2026, 7, 12, 20, 5)]), made)
        # an hour before the prediction instant → refused
        @test_throws ErrorException assert_hours_unrealized(
            vcat(future, [DateTime(2026, 7, 12, 19)]), made)
        # empty input is fine (vacuous)
        @test assert_hours_unrealized(DateTime[], made)
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

        # LOAD FILL: a short zone that IS model-fillable no longer blocks the day
        short_ro = Dict("GR" => 24, "BG" => 24, "RO" => 3)
        ok, reason = eligibility_verdict(zones, short_ro, res_req, Set(["GR", "BG"]), 500;
                                         load_fill_zones=Set(["RO"]))
        @test ok
        @test occursin("model-filled", reason)

        # a short zone that is NOT in the fill set still blocks (no silent fallback)
        ok, reason = eligibility_verdict(zones, short_ro, res_req, Set(["GR", "BG"]), 500;
                                         load_fill_zones=Set(["BG"]))
        @test !ok
        @test occursin("RO", reason)
        @test occursin("model-fillable", reason)

        # empty fill set (default) is byte-identical to the pre-fill gate
        ok1, r1 = eligibility_verdict(zones, full_load, res_req, Set(["GR", "BG"]), 500)
        ok2, r2 = eligibility_verdict(zones, full_load, res_req, Set(["GR", "BG"]), 500;
                                      load_fill_zones=Set{String}())
        @test ok1 == ok2 == true
        @test r1 == r2

        # RES FILL: a required zone MISSING its wind/solar that IS model-fillable
        # no longer blocks the day (BG required, present only GR, but BG res-filled)
        ok, reason = eligibility_verdict(zones, full_load, res_req, Set(["GR"]), 500;
                                         res_fill_zones=Set(["BG"]))
        @test ok
        @test occursin("RES model-filled", reason)

        # a required-missing RES zone NOT in the res-fill set still blocks
        ok, reason = eligibility_verdict(zones, full_load, res_req, Set(["GR"]), 500;
                                         res_fill_zones=Set(["RO"]))  # RO not required
        @test !ok
        @test occursin("BG", reason)
        @test occursin("wind/solar", reason)

        # both fills compose: short-load RO + RES-missing BG, both fillable → eligible
        ok, reason = eligibility_verdict(zones, short_ro, res_req, Set(["GR"]), 500;
                                         load_fill_zones=Set(["RO"]),
                                         res_fill_zones=Set(["BG"]))
        @test ok
        @test occursin("load model-filled", reason)
        @test occursin("RES model-filled", reason)

        # empty res-fill set (default) is byte-identical to the pre-fill gate
        okr1, rr1 = eligibility_verdict(zones, full_load, res_req, Set(["GR", "BG"]), 500)
        okr2, rr2 = eligibility_verdict(zones, full_load, res_req, Set(["GR", "BG"]), 500;
                                        res_fill_zones=Set{String}())
        @test okr1 == okr2 == true
        @test rr1 == rr2
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

    @testset "load-weighted err % (map metric)" begin
        # uniform load → plain WAPE: Σ|err| / Σ|act| × 100
        act = Float64[100, 100]
        sim = Float64[110, 90]
        w1 = Float64[500, 500]
        @test load_weighted_err_pct(sim, act, w1) ≈ 10.0

        # weights matter: all the error in the high-load hour counts more
        act2 = Float64[100, 100]
        sim2 = Float64[120, 100]
        w2 = Float64[900, 100]
        # (900·20 + 100·0) / (900·100 + 100·100) × 100 = 18
        @test load_weighted_err_pct(sim2, act2, w2) ≈ 18.0
        # …and with the weights flipped the same errors weigh less
        @test load_weighted_err_pct(sim2, act2, reverse(w2)) ≈ 2.0

        # negative settled prices enter by magnitude (|act|), not sign
        @test load_weighted_err_pct([0.0], [-50.0], [1000.0]) ≈ 100.0

        # near-zero denominator (settled prices ≈ 0) → nothing, never a huge %
        @test load_weighted_err_pct([30.0, 30.0], [0.1, -0.2], [1000.0, 1000.0]) === nothing
        # …but a denominator at the guard is fine
        @test load_weighted_err_pct([2.0, 2.0], [1.0, 1.0], [1000.0, 1000.0]) ≈ 100.0

        # degenerate inputs → nothing / throw (never fabricated)
        @test load_weighted_err_pct(Float64[], Float64[], Float64[]) === nothing
        @test load_weighted_err_pct([10.0], [20.0], [0.0]) === nothing
        @test_throws ArgumentError load_weighted_err_pct([1.0], [1.0], Float64[])
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

    # --- pre-gate/7-lead additions -----------------------------------------
    @testset "retro vintage lag (lead ⇒ previous_day{lead})" begin
        @test openmeteo_retro_vintage_lag(1) == 1
        @test openmeteo_retro_vintage_lag(7) == 7
        @test openmeteo_retro_vintage_lag(9) == 7    # clamped to API coverage
        @test openmeteo_retro_vintage_lag(0) == 1    # min 1 (a lead-0 nowcast is D-1 at least)
        # LIVE lag is unchanged (0 for a future day, 1 for a past/today day)
        @test openmeteo_vintage_lag(Date(2026,8,2); asof=Date(2026,8,1)) == 0
        @test openmeteo_vintage_lag(Date(2026,7,25); asof=Date(2026,8,1)) == 1
    end

    @testset "vintage_groups fixed_lag (retro/pre-gate one-group)" begin
        cands = Set(Date(2026,7,1):Day(1):Date(2026,7,5))
        # fixed_lag ⇒ ONE group over the whole span at that exact lag
        g = vintage_groups(Date(2026,6,30), Date(2026,7,5), cands; fixed_lag=3)
        @test length(g) == 1
        @test g[1][2] == 3
        @test g[1][1] == collect(Date(2026,6,30):Day(1):Date(2026,7,5))
        # nothing (default) keeps the live D-1 discipline — byte-identical shape
        g0 = vintage_groups(Date(2026,6,30), Date(2026,7,5), cands;
                            asof=Date(2026,6,30))
        @test all(grp -> grp[2] in (0, 1), g0)
    end

    @testset "collapse metrics (SCIENTIST.md §4, ≤€5)" begin
        # act collapses at hours 1,2,4 (≤5); sim predicts collapse at 1,2,3
        act = [3.0, 0.0, 50.0, -2.0, 80.0]
        sim = [4.0, 1.0, 2.0, 60.0, 90.0]
        cm = collapse_metrics(sim, act)
        @test cm.n == 5
        @test cm.n_collapse_actual == 3        # 3.0, 0.0, -2.0
        @test cm.n_collapse_pred == 3          # 4.0, 1.0, 2.0
        @test cm.hits == 2                     # hours 1,2
        @test cm.false_alarms == 1             # hour 3 (sim 2 ≤5, act 50 >5)
        @test cm.hit_rate == 2 / 3
        @test cm.false_alarm_rate == 1 / 2     # 1 FA over 2 actual non-collapses
        # no actual collapse ⇒ hit_rate undefined (nothing, never a fake 0)
        cm2 = collapse_metrics([1.0, 2.0], [50.0, 60.0])
        @test cm2.n_collapse_actual == 0 && cm2.hit_rate === nothing
        @test cm2.false_alarm_rate == 1.0      # both predicted-collapse are FAs
        # all actual collapse ⇒ false_alarm_rate undefined
        cm3 = collapse_metrics([1.0, 2.0], [1.0, 2.0])
        @test cm3.hits == 2 && cm3.false_alarm_rate === nothing
        @test cm3.hit_rate == 1.0
        @test_throws ArgumentError collapse_metrics([1.0], Float64[])
    end

    @testset "retro_write_plan (three writer paths)" begin
        # LIVE write always inserts, regardless of supersede/live presence
        @test retro_write_plan(is_retro=false, supersede=false, has_live=false) == :insert
        @test retro_write_plan(is_retro=false, supersede=true,  has_live=true)  == :insert
        # RETRO with no live conflict inserts (delete prior retro, insert)
        @test retro_write_plan(is_retro=true, supersede=false, has_live=false) == :insert
        @test retro_write_plan(is_retro=true, supersede=true,  has_live=false) == :insert
        # RETRO + live conflict + NO supersede ⇒ refuse (additive-fill contract, #280)
        @test retro_write_plan(is_retro=true, supersede=false, has_live=true) == :refuse
        # RETRO + live conflict + supersede ⇒ back up + replace
        @test retro_write_plan(is_retro=true, supersede=true, has_live=true) == :supersede
    end

end
