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

@testset "tsfm_overlay_maps — one vintage per zone-day, lines and risk never mixed" begin
    r(z, d, t, level, q, v, m, issue, arm="timestral-209m") =
        (z=z, d=Date(d), t=DateTime(t), level=level, q=q, v=v, m=m, issue=DateTime(issue), arm=arm)
    D, H = "2026-11-15", "2026-11-15T10:00"
    rows = [
        # review P2 repro: post-sim 09:13 (median 60) and a later-written pre-gate 06:30 (median 10)
        r("GR", D, "2026-11-14T22:00", "day", "p_any_le0", 0.70, "postsim", "2026-11-14T09:13"),
        r("GR", D, H, "hour", "tsfm_median", 60.0, "postsim", "2026-11-14T09:13"),
        r("GR", D, H, "hour", "tsfm_q10", 55.0, "postsim", "2026-11-14T09:13"),
        r("GR", D, H, "hour", "tsfm_q90", 65.0, "postsim", "2026-11-14T09:13"),
        r("GR", D, H, "hour", "p_le0", 0.60, "postsim", "2026-11-14T09:13"),
        r("GR", D, "2026-11-14T22:00", "day", "p_any_le0", 0.40, "pregate0630", "2026-11-14T06:30"),
        r("GR", D, H, "hour", "tsfm_median", 10.0, "pregate0630", "2026-11-14T06:30"),
        r("GR", D, H, "hour", "p_le0", 0.30, "pregate0630", "2026-11-14T06:30"),
        r("GR", D, "2026-11-15T11:00", "hour", "tsfm_median", 11.0, "pregate0630", "2026-11-14T06:30"),  # older vintage only
        r("ES", D, "2026-11-14T22:00", "day", "p_any_le0", missing, "pregate0630", "2026-11-14T06:30"),
        r("ES", D, H, "hour", "p_le0", 0.05, "pregate0630", "2026-11-14T06:30"),
        r("DE_LU", D, H, "hour", "tsfm_median", 90.0, "pregate0630", "2026-11-14T06:30")]  # no day row
    h, d = tsfm_overlay_maps(rows)
    g = d[("GR", Date(2026, 11, 15))]
    @test (g.p_any_le0, g.input_mode, g.issue_utc) == (0.70, "postsim", DateTime(2026, 11, 14, 9, 13))
    @test h[("GR", "tsfm_median", DateTime(H))] == 60.0       # the line comes from the SAME vintage as the risk
    @test h[("GR", "tsfm_q10", DateTime(H))] == 55.0 && h[("GR", "tsfm_q90", DateTime(H))] == 65.0
    @test h[("GR", "p_le0", DateTime(H))] == 0.60
    @test !haskey(h, ("GR", "tsfm_median", DateTime(2026, 11, 15, 11)))   # nothing borrowed from the older vintage
    @test !haskey(d, ("ES", Date(2026, 11, 15)))                          # missing value -> absent (null downstream)
    @test h[("ES", "p_le0", DateTime(H))] == 0.05
    @test !haskey(h, ("DE_LU", "tsfm_median", DateTime(H)))              # no day row -> no chosen vintage
    @test all(isempty, tsfm_overlay_maps(NamedTuple[]))
    # #431 R2: a backfill vintage is never the live one — not even with a later issue, and a
    # zone-day that has ONLY backfill rows stays absent from the live maps.
    bf = "timestral-209m@cv44-backfill-2026-11"
    rows2 = vcat(rows, [
        r("GR", D, "2026-11-14T22:00", "day", "p_any_le0", 0.99, "postsim_backfill", "2026-11-14T09:59", bf),
        r("GR", D, H, "hour", "tsfm_median", 999.0, "postsim_backfill", "2026-11-14T09:59", bf),
        r("PT", D, "2026-11-14T22:00", "day", "p_any_le0", 0.50, "postsim_backfill", "2026-11-14T06:30", bf),
        r("PT", D, H, "hour", "tsfm_median", 42.0, "postsim_backfill", "2026-11-14T06:30", bf)])
    h2, d2 = tsfm_overlay_maps(rows2)
    @test d2[("GR", Date(2026, 11, 15))] == g && h2[("GR", "tsfm_median", DateTime(H))] == 60.0
    @test !haskey(d2, ("PT", Date(2026, 11, 15))) && !haskey(h2, ("PT", "tsfm_median", DateTime(H)))
    @test is_tsfm_backfill(TSFM_BACKFILL_MODE) && !is_tsfm_backfill("postsim") && !is_tsfm_backfill("pregate0630")
    @test occursin("NOT LIKE '%backfill'", TSFM_OVERLAY_SQL)
end

@testset "native 15-min scores (score_q15 / q15_forecast / athens_day_quarters)" begin
    # Market-day quarters: 96, and 92 / 100 on the DST days (UTC interval starts, Athens day).
    q = athens_day_quarters(Date(2026, 11, 13))
    @test length(q) == 96 && q[1] == DateTime(2026, 11, 12, 22) && q[end] == DateTime(2026, 11, 13, 21, 45)
    @test length(athens_day_quarters(Date(2026, 3, 29))) == 92
    q100 = athens_day_quarters(Date(2026, 10, 25))
    @test length(q100) == 100 && q100[1] == DateTime(2026, 10, 24, 21) && length(unique(q100)) == 100

    # Replication: an hourly slice -> 4 identical quarters, flagged PT60M.
    fq, res = q15_forecast([DateTime(2026, 11, 13, 5), DateTime(2026, 11, 13, 6)], [10.0, 20.0])
    @test res == "PT60M" && length(fq) == 8
    @test fq[DateTime(2026, 11, 13, 5, 45)] == 10.0 && fq[DateTime(2026, 11, 13, 6, 0)] == 20.0
    @test !haskey(fq, DateTime(2026, 11, 13, 7))
    # A natively quarter-hourly slice is used as is, flagged PT15M.
    fqn, resn = q15_forecast([DateTime(2026, 11, 13, 5), DateTime(2026, 11, 13, 5, 15)], [1.0, 2.0])
    @test resn == "PT15M" && length(fqn) == 2 && fqn[DateTime(2026, 11, 13, 5, 15)] == 2.0

    # A full DST-long day: 25 hourly stamps -> 100 paired quarters.
    hrs = expected_market_day_hours(Date(2026, 10, 25))
    fd, _ = q15_forecast(hrs, fill(100.0, length(hrs)))
    acts = q100; av = [100.0 + (i % 4) for i in eachindex(acts)]   # quarters 101,102,103,100 ...
    s = score_q15(fd, acts, av, fill("PT15M", 100); window=q100)
    @test s.n_q15 == 100
    @test s.bias_q15 ≈ -mean(i % 4 for i in 1:100)
    # Shape floor: every hour holds {101,102,103,100} -> mean 101.5, mean |dev| = 1.0
    @test s.shape_floor_q15 ≈ 1.0
    @test s.corr_q15 === nothing                     # replicated constant forecast: zero variance

    # Mask: PT60M (and PT30M) actuals never enter -> n_q15 = 0, all metrics null (not the hourly score).
    s60 = score_q15(fd, hrs, fill(90.0, length(hrs)), fill("PT60M", length(hrs)))
    @test s60.n_q15 == 0 && s60.mae_q15 === nothing && s60.shape_floor_q15 === nothing
    s30 = score_q15(fd, acts, av, fill("PT30M", 100))
    @test s30.n_q15 == 0 && s30.mae_q15 === nothing

    # Min-count rule: 47 native quarters -> null; 48 -> scored. Window restricts the pairing.
    @test score_q15(fd, acts[1:47], av[1:47], fill("PT15M", 47)).mae_q15 === nothing
    s48 = score_q15(fd, acts[1:48], av[1:48], fill("PT15M", 48))
    @test s48.n_q15 == 48 && s48.mae_q15 !== nothing
    @test score_q15(fd, acts, av, fill("PT15M", 100); window=acts[1:40]).n_q15 == 40
    @test score_q15(fd, acts, av, fill("PT15M", 100); min_n=200).mae_q15 === nothing

    # Complete hours only: an hour with 3 native quarters is skipped by EVERY metric.
    t0 = DateTime(2026, 11, 13, 10)
    ft, _ = q15_forecast([t0, t0 + Hour(1)], [25.0, 50.0])
    at = vcat([t0 + Minute(15k) for k in 0:3], [t0 + Hour(1) + Minute(15k) for k in 0:2])
    sv = score_q15(ft, at, [10.0, 20.0, 30.0, 40.0, 0.0, 100.0, 50.0], fill("PT15M", 7); min_n=3)
    @test sv.n_q15 == 4 && sv.q15_status == "ok"
    @test sv.shape_floor_q15 ≈ 10.0                  # |10-25|,|20-25|,|30-25|,|40-25| -> 10
    @test sv.mae_q15 ≈ 10.0                          # the 3-quarter hour does not enter
    @test sv.corr_q15 === nothing                    # one replicated hour: zero forecast variance
    at2 = vcat(at, [t0 + Hour(1) + Minute(45)])
    sv2 = score_q15(ft, at2, [10.0, 20.0, 30.0, 40.0, 0.0, 100.0, 50.0, 70.0], fill("PT15M", 8); min_n=3)
    @test sv2.n_q15 == 8 && sv2.corr_q15 !== nothing
    @test sv2.shape_floor_q15 ≈ mean([15, 5, 5, 15, 55, 45, 5, 15])   # hour 2: mean 55

    # Coverage (#423): duplicate (zone, ts) keys -> the zone-day is ambiguous -> null.
    sd = score_q15(fd, vcat(acts, acts[5:5]), vcat(av, [999.0]), fill("PT15M", 101))
    @test sd.mae_q15 === nothing && sd.q15_status == "duplicate_keys"
    # A non-finite actual removes its whole hour (n 100 -> 96).
    avn = copy(av); avn[10] = NaN
    @test score_q15(fd, acts, avn, fill("PT15M", 100)).n_q15 == 96
    @test score_q15(fd, acts, Any[i == 10 ? missing : x for (i, x) in enumerate(av)],
                    fill("PT15M", 100)).n_q15 == 96

    # A missing quarter must not improve the score. 13 hours: 12 with a 10 €/MWh error in every
    # quarter, one with errors [0, 0, 0, 40]. Full day: MAE = (12*40 + 40) / 52 = 10. Dropping the
    # 40-error quarter would give 480/51 = 9.41 if quarters were scored independently; under the
    # complete-hour rule the hour leaves whole: 480/48 = 10, never better than the full day.
    tq = [t0 + Minute(15k) for k in 0:51]
    fm, _ = q15_forecast([t0 + Hour(h) for h in 0:12], fill(100.0, 13))
    am = [k <= 4 ? (k == 4 ? 140.0 : 100.0) : 110.0 for k in 1:52]
    full = score_q15(fm, tq, am, fill("PT15M", 52))
    gap = score_q15(fm, tq[[1:3; 5:52]], am[[1:3; 5:52]], fill("PT15M", 51))
    @test full.mae_q15 ≈ 10.0 && full.n_q15 == 52
    @test gap.n_q15 == 48 && gap.mae_q15 >= full.mae_q15
    @test gap.shape_floor_q15 == 0.0                 # the partial hour gives no shape term
    # ... and a gap that pushes the day under the minimum makes it null (n reported).
    g2 = score_q15(fm, tq[[1:3; 5:52]], am[[1:3; 5:52]], fill("PT15M", 51); min_n=49)
    @test g2.mae_q15 === nothing && g2.n_q15 == 48 && g2.q15_status == "below_min"

    # ≤0 counts: round(p, 8) <= 0 (a -1e-10 float residue counts as 0), NOT the €5 helper.
    sz = score_q15(ft, at2, [-1e-10, 3.0, 4.0, 1.0, 0.0, 100.0, 50.0, 70.0], fill("PT15M", 8); min_n=3)
    @test sz.n_le0_q15_actual == 2 && sz.n_le0_q15_pred == 0 && sz.le0_q15_hits == 0
    fneg, _ = q15_forecast([t0], [-5.0])
    sn = score_q15(fneg, at[1:4], [-1.0, 2.0, 0.0, 3.0], fill("PT15M", 4); min_n=3)
    @test sn.n_le0_q15_pred == 4 && sn.le0_q15_hits == 2
    @test_throws ArgumentError q15_forecast([t0], Float64[])
end
