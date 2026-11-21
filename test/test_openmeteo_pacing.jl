# Public open-meteo pacing (#455 review P2): the real retro input-preparation loops
# (build_load_fills and build_weather_predictions from bin/daily_forecast.jl,
# build_ml_inputs from bin/ml_inputs.jl), with the real fetchers and fetch driver,
# against a stub HTTP layer: the self-hosted primary answers all-null, so every batch
# falls back to the public API (tonight's case). A virtual clock replaces the pacer's
# clock and sleep; responses take zero time and the per-zone throttle is 0, the worst
# case. Checks every sliding 60 s / 3600 s window of public weighted calls against
# 90% of open-meteo's free limits. No network, no DB.
#   julia --project=. test/test_openmeteo_pacing.jl

using Test, Dates

module PacingLoops
using Test, Dates
const BIN = joinpath(@__DIR__, "..", "bin")
include(joinpath(BIN, "weather_res.jl"))
include(joinpath(BIN, "weather_load.jl"))
include(joinpath(BIN, "ml_inputs.jl"))
include(joinpath(BIN, "forecast_common.jl"))

# The two loops live in daily_forecast.jl (which loads Euphemia + the data store at
# top level): evaluate exactly their source definitions here.
const DF_SRC = read(joinpath(BIN, "daily_forecast.jl"), String)
for name in ("build_load_fills", "build_weather_predictions")
    ex, _ = Meta.parse(DF_SRC, first(findfirst("function " * name * "(", DF_SRC)))
    Core.eval(@__MODULE__, ex)
end
const ZONES = copy(FORECAST_FOOTPRINT)
const OPENMETEO_ZONE_THROTTLE_S = 0.0     # worst case: no per-zone sleep at all

const PRIMARY = "http://selfhosted.test/v1/forecast"
const clock = Ref(0.0)
const sent = Tuple{Float64,Float64}[]       # (virtual send time, weight) of public requests

# Stub HTTP layer (replaces the Downloads-based getters of weather_res/weather_load):
# echo the requested locations/variables/hours, all-null from the primary.
function stub_body(url::String)
    q = Dict(String(k) => String(v) for (k, v) in (split(p, '=', limit=2) for p in split(split(url, '?')[2], '&')))
    lats = split(q["latitude"], ','); lons = split(q["longitude"], ',')
    vars = split(q["hourly"], ',')
    hours = collect(DateTime(Date(q["start_date"])):Hour(1):DateTime(Date(q["end_date"])) + Hour(23))
    isnull = startswith(url, PRIMARY)
    t = join(("\"" * Dates.format(h, "yyyy-mm-ddTHH:MM") * "\"" for h in hours), ",")
    vals = join((isnull ? "null" : "5.0" for _ in hours), ",")
    locs = ["{\"latitude\":$la,\"longitude\":$lo,\"hourly\":{\"time\":[$t]," *
            join(("\"$v\":[$vals]" for v in vars), ",") * "}}" for (la, lo) in zip(lats, lons)]
    _is_public_openmeteo(url) && push!(sent, (clock[], openmeteo_call_weight(openmeteo_url_shape(url)...)))
    return "[" * join(locs, ",") * "]"
end
_openmeteo_get(url::String) = stub_body(url)
_load_openmeteo_get(url::String) = stub_body(url)
# Store-backed ML inputs → empty (predictions are not under test, the requests are).
ml_capacity_p95(zones::Vector{String}, target_days::Vector{Date}) = Dict()
ml_ar_load_lags(zones::Vector{String}, hours::Vector{DateTime}) = Dict()

"Max weighted calls sent within any window [t, t+span)."
peak(span) = maximum(sum(w for (ti, w) in sent if t <= ti < t + span) for (t, _) in sent)

"One retro chunk's input preparation (lead 1), exactly as run_retro calls it."
function prepare_chunk(first_utc::Date, last_utc::Date)
    cands = Set(collect(first_utc + Day(1):Day(1):last_utc))
    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        redirect_stdout(devnull) do
            build_load_fills(load_load_models(), sort(copy(ZONES)), first_utc, last_utc, cands; fixed_lag=1)
            build_weather_predictions(first_utc, last_utc, cands; fixed_lag=1)
            build_ml_inputs(ml_pilot_zones(), first_utc, last_utc, cands; fixed_lag=1)
        end
    end
end

function reset!(; armed::Bool)
    clock[] = 0.0; empty!(sent); empty!(OPENMETEO_PACE_LOG); reset_weather_fetch_log!()
    OPENMETEO_PACE_CLOCK[] = () -> clock[]
    OPENMETEO_PACE_SLEEP[] = d -> (clock[] += d)
    openmeteo_pacer_arm!(armed)
end

withenv("EUPHEMIA_OPENMETEO_PREVRUNS_URL" => PRIMARY, "EUPHEMIA_OPENMETEO_URL" => PRIMARY,
        "EUPHEMIA_OPENMETEO_ZONE_THROTTLE" => "0", "EUPHEMIA_OPENMETEO_CACHE_DIR" => nothing,
        "EUPHEMIA_OPENMETEO_GAPFILL" => nothing, "EUPHEMIA_OPENMETEO_PUBLIC_PACE" => nothing,
        "EUPHEMIA_OPENMETEO_MODELS" => nothing, "EUPHEMIA_OPENMETEO_PACE_SHARE" => nothing) do
    lim = openmeteo_free_limits()
    d0, d1 = Date(2026, 9, 13), Date(2026, 9, 27)     # one 14-day chunk's UTC span
    @testset "public pacing on the real retro fetch loops (#455 review)" begin
        @testset "unpaced: the review's finding reproduces" begin
            reset!(armed=false)
            prepare_chunk(d0, d1)
            @test sum(last, sent) == 3200          # 1,425 RES cells ×2 fetches + 175 cities ×2
            @test length(sent) == 178
            @test clock[] == 0.0
            @test peak(60.0) > lim.minute           # everything in one instant
        end
        @testset "paced: two back-to-back fully public chunks" begin
            reset!(armed=true)
            prepare_chunk(d0, d1)
            t1 = clock[]
            @test sum(last, sent) == 3200
            @test peak(60.0) <= 0.9 * lim.minute
            @test t1 >= 60 * (3200 / (0.9 * lim.minute) - 1)     # ≥ ~5 min of virtual fetching
            @test sum(r.pace_wait for r in WEATHER_FETCH_LOG) ≈ t1
            bl = openmeteo_budget_lines(; span_days=15, chunk_days=14)
            @test occursin("paced by weight to ≤ 540/min and ≤ 4500/h (waited $(round(Int, t1)) s", bl[3])
            reset_weather_fetch_log!()
            prepare_chunk(d1 + Day(1), d1 + Day(15))         # next chunk, same process
            @test sum(last, sent) == 6400
            @test peak(60.0) <= 0.9 * lim.minute
            @test peak(3600.0) <= 0.9 * lim.hour
            @test clock[] > 3600                     # the hourly window made chunk 2 wait
            println("  pacing: chunk 1 fully public in $(round(t1 / 60; digits=1)) virtual min, " *
                    "two chunks in $(round(clock[] / 60; digits=1)); peak 60 s window $(peak(60.0)), " *
                    "peak 3600 s window $(peak(3600.0)) weighted calls")
        end
        @testset "two workers: each process paces to half (EUPHEMIA_OPENMETEO_PACE_SHARE=0.5)" begin
            # bin/run_retro_backfill.py --workers 2 runs two such processes at once; each
            # bounded by half the caps, their sum stays within 540/min and 4,500/h.
            withenv("EUPHEMIA_OPENMETEO_PACE_SHARE" => "0.5") do
                reset!(armed=true)
                prepare_chunk(d0, d1)
                @test sum(last, sent) == 3200
                @test peak(60.0) <= 0.5 * 0.9 * lim.minute
                @test clock[] >= 60 * (3200 / (0.45 * lim.minute) - 1)
                println("  pacing (share 0.5): chunk fully public in $(round(clock[] / 60; digits=1)) virtual min, " *
                        "peak 60 s window $(peak(60.0))")
            end
        end
        @testset "kill switch EUPHEMIA_OPENMETEO_PUBLIC_PACE=0" begin
            withenv("EUPHEMIA_OPENMETEO_PUBLIC_PACE" => "0") do
                reset!(armed=true)
                @test !openmeteo_pacer_active()
                prepare_chunk(d0, d1)
                @test clock[] == 0.0 && sum(last, sent) == 3200
                @test occursin("public pacing OFF", openmeteo_budget_lines(; span_days=15, chunk_days=14)[3])
            end
        end
    end
    openmeteo_pacer_arm!(false)
    OPENMETEO_PACE_CLOCK[] = time; OPENMETEO_PACE_SLEEP[] = sleep
end
end # module PacingLoops
