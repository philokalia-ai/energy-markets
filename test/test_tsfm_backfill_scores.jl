# Timestral fields for the "backfilled" scoreboard window (#431 R2, bin/tsfm_backfill_scores.jl).
# Pure, no DB.   julia --project=. test/test_tsfm_backfill_scores.jl

using Test, Dates, Statistics, DataFrames

isdefined(@__MODULE__, :athens_market_day_window) ||
    include(joinpath(@__DIR__, "..", "bin", "forecast_common.jl"))
isdefined(@__MODULE__, :naive_zone_day) || include(joinpath(@__DIR__, "..", "bin", "naive_baselines.jl"))
include(joinpath(@__DIR__, "..", "bin", "tsfm_backfill_scores.jl"))

@testset "tsfm backfill fields (#431 R2)" begin
    # actuals: price = 10 * (local day of month) + local hour / 100 -> d1 errs by 10, d7 by 70
    loc_price(t) = (l = athens_local(t); 10.0 * day(l) + hour(l) / 100)
    ts = DateTime[]
    for d in Date(2026, 10, 1):Day(1):Date(2026, 10, 20)
        append!(ts, expected_market_day_hours(d))
    end
    act = Dict(t => loc_price(t) for t in ts)
    loc = local_price_index(collect(keys(act)), collect(values(act)))
    D = Date(2026, 10, 15)                       # a Thursday: epf = d1
    hrs = expected_market_day_hours(D)
    tsfm_v = [loc_price(t) + 2.0 for t in hrs]  # Timestral errs by exactly 2

    # only hours carrying a retro physics row are scored (same cells as the physics backfill)
    phys = Set(hrs[1:12])
    p = tsfm_backfill_zone_day(hrs, tsfm_v, phys, act, loc, D)
    @test p.n == 12 && p.model ≈ 24.0 && p.d1 ≈ 120.0 && p.d7 ≈ 840.0 && p.epf ≈ 120.0
    @test tsfm_backfill_zone_day(hrs, tsfm_v, Set{DateTime}(), act, loc, D).n == 0

    parts = Dict(("GR", D) => p,
                 ("GR", D - Day(1)) => tsfm_backfill_zone_day(expected_market_day_hours(D - Day(1)),
                     [loc_price(t) + 4.0 for t in expected_market_day_hours(D - Day(1))],
                     Set(expected_market_day_hours(D - Day(1))), act, loc, D - Day(1)))
    lab = tsfm_backfill_label("cv44-backfill-2026-11")
    @test lab == "timestral-209m@cv44-backfill-2026-11"
    f = tsfm_backfilled_fields(parts, "GR", [D, D - Day(1), D - Day(2)]; label=lab)
    @test f["tsfm_n"] == 36 && f["tsfm_n_days"] == 2
    @test f["tsfm_mae"] ≈ (24.0 + 24 * 4.0) / 36                 # ratio of sums over the paired cells
    @test f["tsfm_mae_naive_d1"] ≈ 10.0 && f["tsfm_mae_naive_d7"] ≈ 70.0
    @test f["tsfm_rmae_d1"] ≈ f["tsfm_mae"] / 10.0
    @test f["tsfm_arm"] == lab
    @test Set(keys(f)) == Set(TSFM_BACKFILL_BOARD_COLS)
    # absent cohort / switched off / failed step -> no fields at all (board unchanged)
    @test isempty(tsfm_backfilled_fields(parts, "ES", [D]))
    @test isempty(tsfm_backfilled_fields(nothing, "GR", [D]))
    withenv("EXPORT_TSFM_BACKFILL" => "0") do
        @test tsfm_backfill_parts_or_nothing("cv44-backfill-2026-11", DataFrame(z=["GR"], market_date=[D])) === nothing
    end
    # the backfill vintage is exactly the mode the live selection drops
    @test is_tsfm_backfill(TSFM_BACKFILL_MODE)
end
