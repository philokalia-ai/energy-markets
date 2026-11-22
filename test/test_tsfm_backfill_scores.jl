# Timestral fields for the "backfilled" scoreboard window (#431 R2, bin/tsfm_backfill_scores.jl).
# Pure, no DB.   julia --project=. test/test_tsfm_backfill_scores.jl

using Test, Dates, Statistics, DataFrames, JSON

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

    # --- publishing path (#450 review P2): R1's extension point -> JSON entry / parquet columns ---
    isdefined(@__MODULE__, :backfilled_entries) || include(joinpath(@__DIR__, "..", "bin", "scoreboard_windows.jl"))
    empty!(TSFM_BACKFILL_PARTS_CACHE)
    calls = Ref(0)
    stub_load = tag -> (calls[] += 1; parts)
    rowsGR = DataFrame(z=["GR", "GR"], market_date=[D, D - Day(1)], lead_days=[1, 1], mode=["weather", "weather"],
                       mae=[60.0, 62.0], bias=[-1.0, -1.0], corr=[0.8, 0.8], cv=[44, 44])
    cf = tsfm_backfill_cohort_fields("GR", 1, rowsGR; tag="cv44-backfill-2026-11", load=stub_load)
    @test cf == f
    @test isempty(tsfm_backfill_cohort_fields("GR", 2, rowsGR; tag="cv44-backfill-2026-11", load=stub_load))
    tsfm_backfill_cohort_fields("DE_LU", 1, rowsGR; tag="cv44-backfill-2026-11", load=stub_load)
    @test calls[] == 1                                    # one DB step per export, whatever the cohorts
    # R1's backfilled_extra_fields delegates here (default tag = BACKFILL_RESET_TAG, cache filled above)
    @test backfilled_extra_fields("GR", 1, "weather", rowsGR) == f
    # through R1's backfilled_entries with the JSON exporter's merge
    ents = backfilled_entries(load=() -> (rowsGR, nothing, "2026-11-18")) do zone, lead, mode, bsub, bparts, made
        merge(Dict{String,Any}("zone" => zone, "lead_days" => lead, "window" => BACKFILLED_WINDOW,
                               "input_mode" => mode, "reconstructed_utc" => made),
              backfilled_extra_fields(zone, lead, mode, bsub))
    end
    @test length(ents) == 1 && ents[1]["tsfm_mae"] ≈ f["tsfm_mae"] && ents[1]["tsfm_arm"] == lab
    # parquet columns: missing on the live rows, values on the backfilled rows; none without fields
    cols = tsfm_backfill_columns(3, [ents[1], Dict{String,Any}()])
    @test length(cols["tsfm_mae"]) == 5 && all(ismissing, cols["tsfm_mae"][[1, 2, 3, 5]])
    @test cols["tsfm_mae"][4] ≈ f["tsfm_mae"] && cols["tsfm_n"][4] == 36 && cols["tsfm_arm"][4] == lab
    @test tsfm_backfill_columns(3, [Dict{String,Any}()]) === nothing
    # golden API-row fixture consumed by workers/api/test/tsfm_backfill_fields.test.mjs (end to end)
    fx = JSON.parsefile(joinpath(@__DIR__, "fixtures", "tsfm_backfilled_row.json"))
    for c in TSFM_BACKFILL_BOARD_COLS
        @test c == "tsfm_arm" ? String(fx[c]) == cols[c][4] : isapprox(Float64(fx[c]), Float64(cols[c][4]); atol=1e-9)
    end
    empty!(TSFM_BACKFILL_PARTS_CACHE)
end

@testset "tsfm live board fields (published vintage per zone-day)" begin
    loc_price(t) = (l = athens_local(t); 10.0 * day(l) + hour(l) / 100)
    ts = DateTime[]
    for d in Date(2026, 10, 1):Day(1):Date(2026, 10, 20)
        append!(ts, expected_market_day_hours(d))
    end
    actz = Dict("GR" => Dict(t => loc_price(t) for t in ts))
    locz = Dict(z => local_price_index(collect(keys(a)), collect(values(a))) for (z, a) in actz)
    D = Date(2026, 10, 15)
    # tsfm_overlay_maps-shaped input: D post-sim (errs 2), D-1 the 06:30 issue (errs 4), D+30 unsettled
    hourly = Dict{Tuple{String,String,DateTime},Float64}()
    for t in expected_market_day_hours(D)
        hourly[("GR", "tsfm_median", t)] = loc_price(t) + 2.0
        hourly[("GR", "tsfm_q10", t)] = 0.0                      # only the median is scored
    end
    for t in expected_market_day_hours(D - Day(1))
        hourly[("GR", "tsfm_median", t)] = loc_price(t) + 4.0
    end
    for t in expected_market_day_hours(D + Day(30))
        hourly[("GR", "tsfm_median", t)] = 1.0
    end
    mk(m) = (p_any_le0=0.1, input_mode=m, issue_utc=DateTime(2026, 10, 14, 9), arm="timestral-209m")
    dayd = Dict(("GR", D) => mk("postsim"), ("GR", D - Day(1)) => mk("pregate0630"), ("GR", D + Day(30)) => mk("postsim"))
    parts, postsim = tsfm_live_parts(hourly, dayd, actz, locz)
    @test parts[("GR", D)].n == 24 && parts[("GR", D)].model ≈ 48.0
    @test parts[("GR", D - Day(1))].n == 24 && parts[("GR", D + Day(30))].n == 0
    @test postsim == Set([("GR", D), ("GR", D + Day(30))])

    f = tsfm_live_fields((parts, postsim), "GR", 1, "weather", [D, D - Day(1), D - Day(2)])
    @test f["tsfm_n"] == 48 && f["tsfm_n_days"] == 2 && f["tsfm_mae"] ≈ 3.0
    @test f["tsfm_n_days_postsim"] == 1                      # D only (D+30 is not in the cohort)
    @test f["tsfm_mae_naive_d1"] ≈ 10.0 && f["tsfm_rmae_d1"] ≈ 0.3 && f["tsfm_arm"] == "timestral-209m"
    # announced track, leads >= 2, unknown zone, no Timestral day scored -> no fields
    @test isempty(tsfm_live_fields((parts, postsim), "GR", 1, "entsoe", [D]))
    @test isempty(tsfm_live_fields((parts, postsim), "GR", 2, "weather", [D]))
    @test isempty(tsfm_live_fields((parts, postsim), "ES", 1, "weather", [D]))
    @test isempty(tsfm_live_fields((parts, postsim), "GR", 1, "weather", [D + Day(30)]))
    @test isempty(tsfm_live_fields(nothing, "GR", 1, "weather", [D]))
    # non-fatal: a failing DB step yields nothing (the board is exported without the fields)
    @test tsfm_live_parts_or_nothing(read_overlay=() -> error("db down")) === nothing
    @test tsfm_live_parts_or_nothing(read_overlay=() -> DataFrame(z=String[], d=Date[], t=DateTime[], level=String[],
        q=String[], v=Float64[], m=String[], issue=DateTime[], arm=String[])) === nothing   # no vintage yet
    # parquet columns over live + backfilled rows, including the post-sim count
    cols = tsfm_backfill_columns(0, [f, Dict{String,Any}()])
    @test cols["tsfm_n_days_postsim"][1] == 1 && ismissing(cols["tsfm_n_days_postsim"][2])
    @test cols["tsfm_mae"][1] ≈ 3.0 && Set(keys(cols)) == Set(TSFM_BOARD_COLS)
end
