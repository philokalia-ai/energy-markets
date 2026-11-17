# #431 R3 reproduction: the cv44 retro backfill's weather-track input build against
# a stand-in for the self-hosted open-meteo (test/scripts/openmeteo_selfhosted_stub.py)
# that answers previous-runs requests null before a cutoff. Builds the SAME inputs
# run_retro builds for one chunk (pack load fill, pack RES, ML overlay), then the
# coverage gate and the new per-input skip reasons.
#
#   ZONES=AT,SK EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_PATH=<extract> EUPHEMIA_DUCKDB_READONLY=true \
#   EUPHEMIA_OPENMETEO_PREVRUNS_URL=http://127.0.0.1:<port>/v1/forecast \
#   [EUPHEMIA_OPENMETEO_GAPFILL=0] julia --project=. test/scripts/retro_weather_gapfill_repro.jl FIRST_DAY LAST_DAY
#
# Public open-meteo is contacted for the fallback (modest volume: a few batches per zone).
ENV["EUPHEMIA_FORECAST_NO_AUTORUN"] = "1"
include(joinpath(@__DIR__, "..", "..", "bin", "daily_forecast.jl"))

days = Date(ARGS[1]):Day(1):Date(ARGS[2])
first_utc, last_utc = first(days) - Day(1), last(days)
candidates = Set(days)
println("gapfill=$(openmeteo_gapfill_enabled())  zones=$(join(ZONES, ","))  days $(first(days)) .. $(last(days))")
reset_weather_fetch_log!()
res_src = Dict{String,String}(); load_src = Dict{String,String}()
fill_pred = build_load_fills(load_load_models(), sort(copy(ZONES)), first_utc, last_utc, candidates; fixed_lag=1)
solar_preds = Dict{String,Dict{DateTime,Float64}}()
preds = build_weather_predictions(first_utc, last_utc, candidates; fixed_lag=1, solar_out=solar_preds)
pilots = [z for z in ml_pilot_zones() if z in ZONES]
if ML_INPUTS_ON && !isempty(pilots)
    ml_res, ml_load = build_ml_inputs(pilots, first_utc, last_utc, candidates; fixed_lag=1,
                                      solar_out=Dict{String,Dict{DateTime,Float64}}())
    for (z, zp) in ml_res; preds[z] = zp; res_src[z] = "ml"; end
    for (z, zp) in ml_load; fill_pred[z] = zp; load_src[z] = "ml"; end
end
for l in weather_fetch_summary(); println("  📡 weather $l"); end
for day in days
    covered = model_covered_for_day(day, fill_pred)
    res_covered = res_covered_for_day(day, preds)
    uncovered = [z for z in ZONES if !(z in covered) || !(z in res_covered)]
    if isempty(uncovered)
        println("  ✅ $day: all $(length(ZONES)) zone(s) covered")
    else
        println("  ⛔ $day: cannot cover $(length(uncovered)) zone(s) ($(join(sort(uncovered), ",")))")
        for r in input_coverage_reasons(day, uncovered, fill_pred, preds; load_src, res_src)
            println("       ↳ $r")
        end
    end
end
