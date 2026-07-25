#!/usr/bin/env julia
#
# Fit the per-zone LOAD models used by the daily forecast's eligibility fill
# (bin/daily_forecast.jl -> bin/weather_load.jl) and write the committed pack
# bin/load_models_v1.json. Mirrors bin/weather_res.jl / res_models_v*.json:
# a versioned JSON artifact with a provenance header and refit instructions.
#
# The model is a per-zone ridge (closed form) mapping weather + calendar to
# hourly load; feature construction is SHARED with inference via
# bin/weather_load.jl (included below). See docs/experiments/dn-load-model.
#
# Target:   entsoe.actual_total_load (deduped to hourly by averaging sub-hourly
#           rows; hours < 20% of the zone median dropped as ENTSO-E glitches).
# Weather:  open-meteo ERA5 archive (temperature_2m + shortwave_radiation) at
#           per-zone representative cities (CITIES below, population-weighted).
# Holidays: computed in code (Gregorian / Orthodox computus, weather_load.jl).
#
# λ is selected on a trailing validation slice, then refit on the full train
# window (identical procedure to the prototype test/scripts/dn_load_model.jl).
#
# ── REFIT INSTRUCTIONS ────────────────────────────────────────────────────
#   julia --project=. bin/fit_load_models.jl            # all footprint zones
#   ZONES="LT,SI,CH" julia --project=. bin/fit_load_models.jl   # a subset
# Env:
#   TRAIN_START   default 2022-07-01
#   TRAIN_END     default 2026-06-30  (ERA5 archive lags ~5 days; keep a margin,
#                 and leave a tail out of sample for validation)
#   OUT           default bin/load_models_v1.json
#   ZONES         comma-separated subset (default = the 39-zone footprint)
# Cadence: annual (with the inference-cache refresh) or quarterly if the trend
# term drifts; bump the pack version (load_models_v2.json, …) like the RES pack.
# ---------------------------------------------------------------------------

using Euphemia, Dates, Statistics, LinearAlgebra, JSON, DataFrames

include(joinpath(@__DIR__, "weather_load.jl"))          # features, ridge, fetch, holidays
include(joinpath(@__DIR__, "forecast_common.jl"))       # FORECAST_FOOTPRINT

const TRAIN_START = Date(get(ENV, "TRAIN_START", "2022-07-01"))
const TRAIN_END = Date(get(ENV, "TRAIN_END", "2026-06-30"))
const OUT_PATH = get(ENV, "OUT", joinpath(@__DIR__, "load_models_v1.json"))
const FIT_ZONES = let z = [String(strip(s)) for s in split(get(ENV, "ZONES", ""), ",") if !isempty(strip(s))]
    isempty(z) ? FORECAST_FOOTPRINT : z
end

# Zone → holiday country and standard-time UTC offset (hours). All footprint
# zones follow the EU DST rule; only the base offset differs.
const ZONE_COUNTRY = Dict(
    "AT"=>"AT","BE"=>"BE","BG"=>"BG","CZ"=>"CZ","DE_LU"=>"DE","DK1"=>"DK","DK2"=>"DK",
    "EE"=>"EE","ES"=>"ES","FI"=>"FI","FR"=>"FR","GR"=>"GR","HU"=>"HU","LT"=>"LT",
    "LV"=>"LV","NL"=>"NL","NO1"=>"NO","NO2"=>"NO","NO3"=>"NO","NO4"=>"NO","NO5"=>"NO",
    "PL"=>"PL","PT"=>"PT","RO"=>"RO","RS"=>"RS","SE1"=>"SE","SE2"=>"SE","SE3"=>"SE",
    "SE4"=>"SE","SI"=>"SI","SK"=>"SK","IT-NORTH"=>"IT","IT-CNORTH"=>"IT",
    "IT-CSOUTH"=>"IT","IT-SOUTH"=>"IT","IT-Calabria"=>"IT","IT-Sicily"=>"IT",
    "IT-Sardinia"=>"IT","CH"=>"CH")
const ZONE_TZ = Dict(z => (c in ("GR","BG","RO","FI","EE","LV","LT") ? 2 : c == "PT" ? 0 : 1)
                     for (z, c) in ZONE_COUNTRY)

# Per-zone representative cities: (name, lat, lon, metro population weight in
# millions — rough). GR/DE_LU/FR/ES/PL/SE3 reuse the prototype list
# (test/scripts/dn_load_fetch.py); the other 33 footprint zones are new,
# picked as the zone's biggest population centres (regional for the split
# NO/SE/DK/IT zones). Weighting is population-only — good enough for a
# temperature aggregate that only needs to track the zone's demand-weighted
# climate.
const CITIES = Dict{String,Vector{Tuple{String,Float64,Float64,Float64}}}(
    "GR" => [("athens",37.98,23.73,3.6),("thessaloniki",40.64,22.94,1.1),("patras",38.25,21.73,0.26),("heraklion",35.34,25.13,0.21),("larissa",39.64,22.42,0.16)],
    "DE_LU" => [("berlin",52.52,13.40,3.7),("hamburg",53.55,10.00,1.9),("munich",48.14,11.58,1.5),("cologne",50.94,6.96,1.1),("frankfurt",50.11,8.68,0.77),("stuttgart",48.78,9.18,0.63),("essen",51.46,7.01,2.0),("leipzig",51.34,12.37,0.6),("luxembourg",49.61,6.13,0.66)],
    "FR" => [("paris",48.86,2.35,11.0),("lyon",45.76,4.84,1.7),("marseille",43.30,5.37,1.6),("toulouse",43.60,1.44,1.0),("lille",50.63,3.07,1.2),("bordeaux",44.84,-0.58,1.0),("nantes",47.22,-1.55,0.7),("strasbourg",48.57,7.75,0.5)],
    "ES" => [("madrid",40.42,-3.70,6.7),("barcelona",41.39,2.17,5.6),("valencia",39.47,-0.38,1.6),("seville",37.39,-5.99,1.5),("bilbao",43.26,-2.93,1.0),("zaragoza",41.65,-0.89,0.7),("malaga",36.72,-4.42,0.85)],
    "PL" => [("warsaw",52.23,21.01,3.1),("krakow",50.06,19.94,1.0),("lodz",51.76,19.46,0.9),("wroclaw",51.11,17.03,0.8),("poznan",52.41,16.93,0.7),("gdansk",54.35,18.65,1.0)],
    "SE3" => [("stockholm",59.33,18.07,2.4),("gothenburg",57.71,11.97,1.0),("uppsala",59.86,17.64,0.25),("orebro",59.27,15.21,0.16),("linkoping",58.41,15.62,0.17)],
    # --- new footprint zones ---
    "AT" => [("vienna",48.21,16.37,2.0),("graz",47.07,15.44,0.3),("linz",48.31,14.29,0.2),("salzburg",47.81,13.04,0.15),("innsbruck",47.27,11.39,0.13)],
    "BE" => [("brussels",50.85,4.35,2.1),("antwerp",51.22,4.40,1.05),("ghent",51.05,3.72,0.55),("liege",50.63,5.57,0.6),("charleroi",50.41,4.44,0.4)],
    "BG" => [("sofia",42.70,23.32,1.4),("plovdiv",42.14,24.75,0.55),("varna",43.20,27.91,0.5),("burgas",42.51,27.47,0.3)],
    "CZ" => [("prague",50.08,14.44,1.3),("brno",49.20,16.61,0.4),("ostrava",49.82,18.26,0.35),("plzen",49.75,13.38,0.2)],
    "EE" => [("tallinn",59.44,24.75,0.55),("tartu",58.38,26.72,0.1),("narva",59.38,28.19,0.06)],
    "FI" => [("helsinki",60.17,24.94,1.3),("tampere",61.50,23.79,0.35),("turku",60.45,22.27,0.3),("oulu",65.01,25.47,0.21)],
    "HU" => [("budapest",47.50,19.04,1.8),("debrecen",47.53,21.63,0.2),("szeged",46.25,20.15,0.16),("miskolc",48.10,20.79,0.15)],
    "LT" => [("vilnius",54.69,25.28,0.58),("kaunas",54.90,23.90,0.3),("klaipeda",55.70,21.14,0.15),("siauliai",55.93,23.32,0.1)],
    "LV" => [("riga",56.95,24.11,0.8),("daugavpils",55.87,26.51,0.08),("liepaja",56.51,21.01,0.07)],
    "NL" => [("amsterdam",52.37,4.90,1.5),("rotterdam",51.92,4.48,1.2),("thehague",52.08,4.30,1.0),("utrecht",52.09,5.12,0.7),("eindhoven",51.44,5.48,0.55)],
    "NO1" => [("oslo",59.91,10.75,1.1),("drammen",59.74,10.20,0.15),("fredrikstad",59.22,10.93,0.12),("lillestrom",59.96,11.05,0.1)],
    "NO2" => [("kristiansand",58.15,7.99,0.15),("stavanger",58.97,5.73,0.25),("sandnes",58.85,5.74,0.08),("skien",59.21,9.61,0.1)],
    "NO3" => [("trondheim",63.43,10.39,0.21),("alesund",62.47,6.15,0.07),("molde",62.74,7.16,0.03)],
    "NO4" => [("tromso",69.65,18.96,0.08),("bodo",67.28,14.40,0.05),("narvik",68.44,17.43,0.02),("alta",69.97,23.27,0.02)],
    "NO5" => [("bergen",60.39,5.32,0.28),("haugesund",59.41,5.27,0.06),("forde",61.45,5.86,0.02)],
    "PT" => [("lisbon",38.72,-9.14,2.9),("porto",41.15,-8.61,1.3),("braga",41.55,-8.43,0.2),("coimbra",40.21,-8.43,0.14),("faro",37.02,-7.93,0.12)],
    "RO" => [("bucharest",44.43,26.10,1.9),("cluj",46.77,23.60,0.32),("timisoara",45.75,21.23,0.32),("iasi",47.16,27.59,0.32),("constanta",44.18,28.63,0.28)],
    "RS" => [("belgrade",44.79,20.45,1.4),("novisad",45.25,19.85,0.3),("nis",43.32,21.90,0.26),("kragujevac",44.01,20.91,0.15)],
    "SE1" => [("lulea",65.58,22.15,0.08),("kiruna",67.86,20.23,0.02),("pitea",65.32,21.48,0.04),("boden",65.83,21.69,0.03)],
    "SE2" => [("sundsvall",62.39,17.31,0.1),("umea",63.83,20.26,0.13),("ostersund",63.18,14.64,0.06),("gavle",60.67,17.14,0.1)],
    "SE4" => [("malmo",55.60,13.00,0.35),("helsingborg",56.05,12.69,0.15),("lund",55.70,13.19,0.13),("kalmar",56.66,16.36,0.07)],
    "SI" => [("ljubljana",46.06,14.51,0.29),("maribor",46.55,15.65,0.11),("celje",46.23,15.27,0.05),("kranj",46.24,14.36,0.06)],
    "SK" => [("bratislava",48.15,17.11,0.5),("kosice",48.72,21.26,0.24),("presov",48.99,21.24,0.09),("zilina",49.22,18.74,0.08)],
    "CH" => [("zurich",47.37,8.54,1.4),("geneva",46.20,6.14,0.6),("basel",47.56,7.59,0.55),("bern",46.95,7.44,0.42),("lausanne",46.52,6.63,0.42)],
    "DK1" => [("aarhus",56.16,10.20,0.35),("aalborg",57.05,9.92,0.14),("odense",55.40,10.39,0.18),("esbjerg",55.47,8.46,0.07),("kolding",55.49,9.47,0.06)],
    "DK2" => [("copenhagen",55.68,12.57,1.3),("roskilde",55.64,12.08,0.06),("helsingor",56.04,12.61,0.06),("naestved",55.23,11.76,0.04)],
    "IT-NORTH" => [("milan",45.46,9.19,3.2),("turin",45.07,7.69,1.7),("venice",45.44,12.32,0.6),("bologna",44.49,11.34,0.8),("genoa",44.41,8.93,0.8),("verona",45.44,10.99,0.5)],
    "IT-CNORTH" => [("florence",43.77,11.26,1.0),("ancona",43.62,13.52,0.3),("perugia",43.11,12.39,0.35),("livorno",43.55,10.31,0.25)],
    "IT-CSOUTH" => [("rome",41.90,12.50,4.3),("naples",40.85,14.27,3.0),("pescara",42.46,14.22,0.35),("latina",41.47,12.90,0.35)],
    "IT-SOUTH" => [("bari",41.13,16.87,1.0),("taranto",40.46,17.24,0.35),("foggia",41.46,15.55,0.28),("lecce",40.35,18.17,0.25)],
    "IT-Calabria" => [("reggiocalabria",38.11,15.66,0.35),("catanzaro",38.91,16.59,0.15),("cosenza",39.30,16.25,0.2)],
    "IT-Sicily" => [("palermo",38.12,13.36,0.85),("catania",37.51,15.08,0.75),("messina",38.19,15.55,0.35),("syracuse",37.07,15.29,0.2)],
    "IT-Sardinia" => [("cagliari",39.22,9.12,0.43),("sassari",40.73,8.56,0.16),("olbia",40.92,9.50,0.06)],
)

# ---------------------------------------------------------------------------
# Load target: entsoe.actual_total_load, hourly, deduped.
# ---------------------------------------------------------------------------
"Hour → load MW for a zone over [t0, t1), sub-hourly rows averaged into each hour."
function fetch_actual_load(zone::String, t0::Date, t1::Date)
    df = Euphemia.sql2df_with_retry("""
        SELECT date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS h,
               AVG(total_load_mw) AS load_mw
        FROM entsoe.actual_total_load
        WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND area_map_code = \$3
          AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
          AND total_load_mw IS NOT NULL
        GROUP BY 1
        ORDER BY 1
    """, [t0, t1, zone])
    out = Dict{DateTime,Float64}()
    for r in eachrow(df)
        ismissing(r.load_mw) && continue
        out[DateTime(r.h)] = Float64(r.load_mw)
    end
    return out
end

# ---------------------------------------------------------------------------
# Fit one zone.
# ---------------------------------------------------------------------------
function fit_zone(zone::String)
    haskey(CITIES, zone) || (println("  ⚠️ $zone: no city list — skipped"); return nothing)
    tz_base = ZONE_TZ[zone]
    country = ZONE_COUNTRY[zone]
    cities = CITIES[zone]
    cells = [(c[2], c[3]) for c in cities]
    weights = [c[4] for c in cities]

    # Weather (ERA5 archive) over the training window + 2 lead-in days so the
    # trailing-48h MA is defined from the first training hour.
    weather = fetch_load_weather(cells, [TRAIN_START - Day(2), TRAIN_END]; archive=true)
    # Zone-mean (T,GHI) series (population-weighted, hours common to all cities).
    zm = Dict("cities" => [[c[2], c[3], c[4]] for c in cities])
    series = zone_mean_series(zm, weather)
    isempty(series) && (println("  ❌ $zone: no weather returned"); return nothing)

    # Target load.
    load = fetch_actual_load(zone, TRAIN_START, TRAIN_END + Day(1))
    isempty(load) && (println("  ❌ $zone: no load rows"); return nothing)
    med = median(collect(values(load)))
    nbad = count(v -> v < 0.2 * med, values(load))
    nbad > 0 && println("  $zone: dropping $nbad glitch hours (load < 20% of $(round(Int, med)) MW)")
    load = Dict(h => v for (h, v) in load if v >= 0.2 * med)

    hol = holidays_for_country(country, year(TRAIN_START):year(TRAIN_END))
    trend_origin = TRAIN_START

    hours = sort([h for h in keys(load)
                  if DateTime(TRAIN_START) <= h <= DateTime(TRAIN_END, Time(23)) && haskey(series, h)])
    rows = Tuple{DateTime,Vector{Float64},Float64}[]
    for h in hours
        ma = trailing_ma_temp(series, h)
        ma === nothing && continue
        T, G = series[h]
        push!(rows, (h, load_feature_vector(h, T, G, ma, tz_base, hol, trend_origin), load[h]))
    end
    length(rows) < 1000 && (println("  ❌ $zone: only $(length(rows)) training rows — skipped"); return nothing)

    X = permutedims(hcat([r[2] for r in rows]...))
    y = [r[3] for r in rows]
    # λ selection on the last 6 months as validation, refit on the whole window.
    val0 = DateTime(TRAIN_END - Day(182))
    tr = [i for (i, r) in enumerate(rows) if r[1] < val0]
    va = [i for (i, r) in enumerate(rows) if r[1] >= val0]
    best = (λ=1e-3, mae=Inf)
    if !isempty(va) && !isempty(tr)
        for λ in (1e-5, 1e-4, 1e-3, 1e-2, 1e-1)
            m = ridge_fit_load(X[tr, :], y[tr], λ)
            mae = mean(abs.(ridge_predict_load(m.coef, m.mu_x, m.sd_x, m.mu_y, X[va, :]) .- y[va]))
            mae < best.mae && (best = (λ=λ, mae=mae))
        end
    end
    model = ridge_fit_load(X, y, best.λ)
    # In-sample fit quality (a sanity signal only — real OOS is the validation script).
    insample = mean(abs.(ridge_predict_load(model.coef, model.mu_x, model.sd_x, model.mu_y, X) .- y))
    mape = 100 * mean(abs.(ridge_predict_load(model.coef, model.mu_x, model.sd_x, model.mu_y, X) .- y) ./ y)
    println("  ✅ $zone: $(length(y)) rows, λ=$(best.λ), val MAE $(round(best.mae)) MW, " *
            "in-sample MAE $(round(insample)) MW / MAPE $(round(mape, digits=1))%")

    return Dict(
        "cities" => [[c[2], c[3], c[4]] for c in cities],
        "coef" => model.coef, "mu_x" => model.mu_x, "sd_x" => model.sd_x,
        "mu_y" => model.mu_y, "lambda" => model.lambda,
        "hdh_base" => HDH_BASE_DEFAULT, "cdh_base" => CDH_BASE_DEFAULT,
        "tz_base" => tz_base, "holiday_country" => country,
        "n_train" => length(y))
end

function main()
    println("=" ^ 70)
    println("FIT LOAD MODELS  train $(TRAIN_START) .. $(TRAIN_END)  zones=$(length(FIT_ZONES))")
    println("  out=$OUT_PATH")
    println("=" ^ 70)
    zones = Dict{String,Any}()
    for zone in FIT_ZONES
        println("\n$zone")
        try
            z = fit_zone(zone)
            z !== nothing && (zones[zone] = z)
        catch e
            e isa InterruptException && rethrow()
            println("  ❌ $zone: fit failed: $(sprint(showerror, e))")
        end
    end
    isempty(zones) && error("no zones fitted — nothing to write")

    pack = Dict(
        "version" => 1,
        "features" => "207: 168 hour-of-week + holiday flag/×hour + degree-hours(T,T²,48h-MA) + GHI + DOY-Fourier + trend; see bin/weather_load.jl",
        "target" => "entsoe.actual_total_load (hourly, deduped)",
        "weather" => "open-meteo ERA5 archive temperature_2m + shortwave_radiation at per-zone population-weighted cities",
        "trend_origin" => Dates.format(TRAIN_START, "yyyy-mm-dd"),
        "train_window" => Dates.format(TRAIN_START, "yyyy-mm-dd") * ".." * Dates.format(TRAIN_END, "yyyy-mm-dd"),
        "fitted_utc" => Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SS") * "Z",
        "refit" => "julia --project=. bin/fit_load_models.jl (see header)",
        "zones" => zones)
    open(OUT_PATH, "w") do io
        JSON.print(io, pack)
    end
    println("\n" * "=" ^ 70)
    println("WROTE $(length(zones)) zone models -> $OUT_PATH ($(round(filesize(OUT_PATH)/1024, digits=0)) KB)")
    println("=" ^ 70)
end

main()
