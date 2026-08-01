#!/usr/bin/env julia
#
# Export the "Predictions" page data plane (the OPEN, reproducible RES/load
# model — docs/predictions.md) as PARQUET under the additive v1 contract
# (v1/inputs/), for upload to the R2 bucket `euphemia-web-data` via
# bin/web_data_push.sh — the SAME publish step that runs bin/export_web_parquet.jl.
#
# WHAT THIS EXPORTS (per-zone-hour, trailing window + forecast horizon):
#   the model's own INPUT DRIVERS (pop-weighted temperature, GHI/shortwave,
#   cloud cover, surface pressure, mean 100 m wind speed) from the SAME cached
#   GFS previous_day1 vintages the daily forecast consumes (bin/ml_inputs.jl
#   fetch machinery, reused verbatim — no re-invention), the model's predicted
#   load / solar / wind (the per-zone-winner ML_USE_NEW config), the ENTSO-E
#   day-ahead REFERENCE forecast the market actually clears on, and the SETTLED
#   actuals where they exist. Plus the weekly reservoir fill ratio / dryness for
#   the hydro zones (the get_reservoir_* code path). Every number is
#   ex-ante-LABELLED by the weather vintage that produced it (vintage_lag: 0 =
#   the current run at the horizon, 1 = the D-1-issued previous-run vintage for
#   settled history — the honest ex-ante discipline, bin/weather_vintage.jl).
#
# This is the FULL 39-zone footprint OPEN model surface. Provenance is honest and
# per-target: the 5 ML pilot zones (GR/ES/DE_LU/SE2/NL) carry committed LightGBM
# dumps + a pure-Julia scorer (bin/input_models/, bin/ml_inputs.jl) and use the
# per-zone-winner ML prediction exactly as bin/daily_forecast.jl resolves it with
# EUPHEMIA_ML_INPUTS on (the `ML_USE_NEW` scorecard: ML load on all 5, ML solar on
# all but ES, ML wind only on NL); the other 34 zones use the SAME linear weather
# packs the daily forecast actually drives them with (bin/res_models_v2.json via
# predict_solar_hour/predict_wind_hour, bin/load_models_v1.json via predict_load).
# Every zone-row's `src_solar`/`src_wind`/`src_load` label ('ml'|'pack') records
# which model produced each target, so the page can badge the provenance.
#
# Layout (the /v1/ public data API — additive; schema changes bump /v2/):
#
#   v1/inputs/<ZONE>.parquet   one row per (zone, delivery hour): zone VARCHAR,
#                              date_time_utc TIMESTAMP, vintage_lag INT (0/1),
#                              temp_c, ghi_wm2, cloud_pct, pressure_hpa,
#                              wind100_ms DOUBLE (the drivers); pred_solar_mw,
#                              pred_wind_mw, pred_res_mw, pred_load_mw DOUBLE
#                              (our per-zone-winner prediction); src_solar,
#                              src_wind, src_load VARCHAR ('ml' | 'pack');
#                              ref_solar_mw, ref_wind_mw, ref_load_mw DOUBLE
#                              (ENTSO-E day-ahead forecast, null where
#                              unpublished); act_solar_mw, act_wind_mw,
#                              act_load_mw DOUBLE (settled actual, null until
#                              settled).
#   v1/inputs/reservoir.parquet  one row per (zone, iso_year, iso_week):
#                              week_start DATE, stored_energy_mwh, fill_ratio
#                              (stored / trailing-52-week max — the seasonal
#                              signal get_reservoir_drawdown uses), dryness
#                              (1 − stored / same-ISO-week prior-year median —
#                              get_reservoir_dryness) DOUBLE.
#   v1/inputs/manifest.json    {schema, updated_at, code_version, vintage_note,
#                              zones, pilot_zones, pack_zones, hydro_zones, window,
#                              columns, row_counts, map:[{zone,date,midday_res_mw,
#                              midday_load_mw,coverage,collapse_risk,model}]} — the
#                              per-zone freshest-day midday RES-coverage summary the
#                              map centrepiece colours by. `model` ('ml'|'pack') is
#                              the zone-level provenance summary; `zones` is every
#                              exported zone, `pilot_zones` the ML subset, and
#                              `pack_zones` the linear-pack remainder (additive).
#
# Reproducible offline (read-only extract + public open-meteo previous-runs):
#   EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true \
#   EUPHEMIA_DUCKDB_PATH=data/extracts/euphemia-live.duckdb \
#   INPUTS_HIST_DAYS=7 INPUTS_ASOF=2026-07-28 \
#     julia --project=. bin/export_prediction_inputs.jl
#
# Env:
#   WEB_PARQUET_OUT   staging root (default <repo>/data/web); objects under $/v1/inputs
#   INPUTS_BACK_DAYS  trailing history window in market days (default 30). The full
#                     39-zone pull hits open-meteo per zone (RES 4-var + load 2-var,
#                     batched ≤50 cells/call, one span fetch per zone per vintage
#                     group, throttled by EUPHEMIA_OPENMETEO_ZONE_THROTTLE with 429
#                     backoff) so the window trades history depth against the size
#                     of that pull — 30 days keeps the daily CI run well inside the
#                     public rate budget; raise it for a deeper offline backfill.
#                     (INPUTS_HIST_DAYS is still honoured as the legacy alias.)
#   INPUTS_HORIZON_DAYS  forecast horizon in market days ahead of asof (default 2)
#   INPUTS_ASOF       ex-ante "now" date override (ISO; default today UTC) — pins
#                     the D-1 vintage discipline for a reproducible historical run
#   INPUTS_ZONES      comma list of zones to export (default the 39-zone
#                     FORECAST_FOOTPRINT; the ML pilots within it use LightGBM, the
#                     rest use the linear packs)
#   UPDATED_AT        manifest updated_at override (ISO8601; default now UTC)

using Euphemia, Dates, Statistics, DataFrames, DuckDB, JSON

# The ML fetch/scorer machinery + its weather-pack dependencies, in the SAME
# include order bin/daily_forecast.jl uses so ml_inputs.jl's call-time helper
# references resolve (guarded mains — safe to include).
include(joinpath(@__DIR__, "forecast_common.jl"))
include(joinpath(@__DIR__, "weather_res.jl"))
include(joinpath(@__DIR__, "weather_load.jl"))
include(joinpath(@__DIR__, "ml_inputs.jl"))

const CV = Euphemia.ENERGY_PRICES_CODE_VERSION
const OUT_ROOT = get(ENV, "WEB_PARQUET_OUT", joinpath(dirname(@__DIR__), "data", "web"))
const INPUTS_DIR = joinpath(OUT_ROOT, "v1", "inputs")
# INPUTS_BACK_DAYS is the trailing window (default 30 for the full footprint);
# INPUTS_HIST_DAYS stays honoured as the legacy alias.
const HIST_DAYS = parse(Int, get(ENV, "INPUTS_BACK_DAYS",
                                 get(ENV, "INPUTS_HIST_DAYS", "30")))
const HORIZON_DAYS = parse(Int, get(ENV, "INPUTS_HORIZON_DAYS", "2"))
# The full open surface is the 39-zone footprint; INPUTS_ZONES overrides it.
const EXPORT_ZONES = strip(get(ENV, "INPUTS_ZONES", "")) == "" ? FORECAST_FOOTPRINT :
                     String.(strip.(split(ENV["INPUTS_ZONES"], ",")))
# ML pilots carry committed LightGBM dumps + geom.json geometry; every other
# footprint zone falls back to the linear weather packs.
const PILOT_SET = Set(ML_PILOT_ZONES)
is_ml_pilot(z::AbstractString) = z in PILOT_SET
"'ml' when the per-zone-winner scorecard (ML_USE_NEW) ships the ML model for
(zone,target), else 'pack' — the honest provenance label written on every row."
winner_src(z::AbstractString, tgt::Symbol) = get(ML_USE_NEW, (String(z), tgt), false) ? "ml" : "pack"

# nothing/missing/NaN/Inf -> missing (parquet null; JSON null downstream)
nm(x) = (x === nothing || x === missing) ? missing :
        (x isa AbstractFloat && !isfinite(x)) ? missing : x

const DUCK = DBInterface.connect(DuckDB.DB, ":memory:")

function write_parquet(df::DataFrame, path::String)
    mkpath(dirname(path))
    DuckDB.register_data_frame(DUCK, df, "staging_df")
    try
        DBInterface.execute(DUCK,
            "COPY (SELECT * FROM staging_df) TO '$(replace(path, '\'' => "''"))' " *
            "(FORMAT PARQUET, COMPRESSION ZSTD)")
    finally
        DBInterface.execute(DUCK, "DROP VIEW IF EXISTS staging_df")
    end
    return nrow(df)
end

# ---------------------------------------------------------------------------
# The driver + prediction panel — mirrors bin/ml_inputs.jl build_ml_inputs'
# inner loop EXACTLY (same fetch calls, same vintage groups, same per-zone-winner
# selection) but captures the intermediate DRIVERS and the SEPARATE solar/wind/
# load components (build_ml_inputs only returns the combined RES + load). Kept as
# a sibling so the tested daily path in ml_inputs.jl is untouched.
# ---------------------------------------------------------------------------
"""
    build_ml_input_panel(zones, first_utc, last_utc, candidates; asof) -> DataFrame

One row per (zone, UTC delivery hour) over the market days served by
[first_utc, last_utc]: the four RES drivers (ghi/cloud/pres/v100m), the load
temperature driver, the per-zone-winner predicted solar/wind/load MW, the winner
source labels, and the weather `vintage_lag` that produced the row. Ex-ante by
construction (same discipline as the daily forecast).

Provenance is resolved PER ZONE exactly as bin/daily_forecast.jl does with
EUPHEMIA_ML_INPUTS on: an ML pilot zone (geom.json + committed LightGBM dumps)
uses its per-zone-winner ML model for a target where `ML_USE_NEW` ships it and
the linear pack otherwise; every non-pilot footprint zone uses the linear packs
throughout (RES via predict_solar_hour/predict_wind_hour on res_models_v2.json,
load via predict_load on load_models_v1.json). The 4-variable RES fetch is reused
for both classes, so the cloud/pressure drivers are captured for every zone; the
pack solar/wind read the very same ghi/v100 the daily forecast's pack path reads.
"""
function build_ml_input_panel(zones::Vector{String}, first_utc::Date, last_utc::Date,
                              candidates::AbstractSet{Date}; asof::Date=Date(now(UTC)))
    pilots = String[z for z in zones if is_ml_pilot(z)]
    models = isempty(pilots) ? nothing : load_ml_models(pilots)   # LightGBM: pilots only
    geom = ml_geom()                                              # pilot geometry (5 zones)
    res_pack = load_res_models()                                  # RES linear packs (39 zones)
    load_pack = load_load_models()                                # load ridge packs (39 zones)
    load_zones = load_pack === nothing ? Dict{String,Any}() : load_pack["zones"]
    groups = vintage_groups(first_utc, last_utc, candidates; asof)
    target_days = collect(first_utc:Day(1):last_utc)
    cap = isempty(pilots) ? Dict{Tuple{String,Symbol},Dict{Date,Float64}}() :
          ml_capacity_p95(pilots, target_days)                    # cap95 only feeds ML RES
    throttle = parse(Float64, get(ENV, "EUPHEMIA_OPENMETEO_ZONE_THROTTLE", "0.6"))

    df = DataFrame(zone=String[], date_time_utc=DateTime[], vintage_lag=Int[],
                   temp_c=Union{Missing,Float64}[], ghi_wm2=Union{Missing,Float64}[],
                   cloud_pct=Union{Missing,Float64}[], pressure_hpa=Union{Missing,Float64}[],
                   wind100_ms=Union{Missing,Float64}[],
                   pred_solar_mw=Union{Missing,Float64}[], pred_wind_mw=Union{Missing,Float64}[],
                   pred_res_mw=Union{Missing,Float64}[], pred_load_mw=Union{Missing,Float64}[],
                   src_solar=String[], src_wind=String[], src_load=String[])

    for z in zones
        pilot = is_ml_pilot(z)
        zpack = get(res_pack["zones"], z, nothing)
        lz = get(load_zones, z, nothing)
        # Geometry: pilots use the committed geom.json (what the ML models expect);
        # pack zones use the RES pack cells + the load pack's weighted cities.
        if pilot
            lat0, lon0 = ml_zone_centroid(geom, z)
            cells = [(Float64(c[1]), Float64(c[2])) for c in geom[z]["cells"]]
            cities = [(Float64(c[1]), Float64(c[2]), Float64(c[3])) for c in geom[z]["cities"]]
        else
            if zpack === nothing
                println("  ⚠️ $z: no RES pack — skipped"); continue
            end
            cells = [(Float64(c[1]), Float64(c[2])) for c in zpack["cells"]]
            lat0 = mean(c[1] for c in cells); lon0 = mean(c[2] for c in cells)
            cities = lz === nothing ? Tuple{Float64,Float64,Float64}[] :
                     [(Float64(c[1]), Float64(c[2]), Float64(c[3])) for c in lz["cities"]]
        end
        ssrc = winner_src(z, :solar); wsrc = winner_src(z, :wind); lsrc = winner_src(z, :load)
        use_ml_solar = pilot && get(ML_USE_NEW, (z, :solar), false)
        use_ml_wind  = pilot && get(ML_USE_NEW, (z, :wind), false)
        use_ml_load  = pilot && get(ML_USE_NEW, (z, :load), false)
        # ml_holidays (features.py port) only for an ML-load pilot; the pack-load
        # path derives holidays itself inside predict_load (holidays_for_country).
        holset = use_ml_load ?
                 ml_holidays(String(load_zones[z]["holiday_country"]), 2024:2027) : Set{Date}()
        for (gdates, lag) in groups
            throttle > 0 && sleep(throttle)
            rweather = fetch_ml_res_weather(cells, gdates; vintage_lag=lag)
            wcells = Dict{Tuple{Float64,Float64},Dict{DateTime,Float64}}()
            for (cell, cw) in rweather
                wcells[cell] = Dict(h => tup[1] for (h, tup) in cw)
            end
            ragg = ml_res_agg(cells, rweather)
            lweather = isempty(cities) ?
                Dict{Tuple{Float64,Float64},Dict{DateTime,Tuple{Float64,Float64}}}() :
                fetch_load_weather(cells_of_cities(cities),
                                   collect((first(gdates) - Day(2)):Day(1):last(gdates));
                                   vintage_lag=lag)
            lagg = ml_load_agg(cities, lweather)
            Tseries = Dict{DateTime,Float64}(h => v[1] for (h, v) in lagg)
            ghours = collect(DateTime(first(gdates)):Hour(1):DateTime(last(gdates)) + Hour(23))
            # Pack-load zones score the whole group through the tested predict_load
            # (the exact daily-forecast pack path); ML-load pilots score per hour below.
            pack_load_pred = (!use_ml_load && lz !== nothing) ?
                predict_load(load_pack, z, ghours, lweather) : nothing
            for h in ghours
                D = Date(h)
                ra = get(ragg, h, nothing)
                ra === nothing && continue
                ghi, cloud, pres, v100m = ra
                c95s = get(get(cap, (z, :solar), Dict{Date,Float64}()), D, NaN)
                c95w = get(get(cap, (z, :wind), Dict{Date,Float64}()), D, NaN)
                feats = ml_res_features(h, lat0, lon0, ghi, cloud, pres, v100m, c95s, c95w)
                solar = use_ml_solar ? ml_predict_solar(models, z, feats) :
                        (zpack !== nothing && haskey(zpack, "solar") ?
                         predict_solar_hour(zpack["solar"], ghi, h) : 0.0)
                wind = if use_ml_wind
                    ml_predict_wind(models, z, feats)
                else
                    vv = Float64[get(get(wcells, cell, Dict{DateTime,Float64}()), h, NaN)
                                 for cell in cells]
                    (zpack !== nothing && haskey(zpack, "wind") && !any(isnan, vv)) ?
                        predict_wind_hour(zpack["wind"], vv) : 0.0
                end
                solar_v = isnan(solar) ? missing : solar
                wind_v = isnan(wind) ? missing : wind
                res_v = (isnan(solar) ? 0.0 : solar) + (isnan(wind) ? 0.0 : wind)

                # LOAD: ML pilot winner scores per hour (needs cap-independent T/AR
                # features); every pack-load zone reads its predict_load result.
                load_v = missing
                if use_ml_load
                    la = get(lagg, h, nothing)
                    if la !== nothing && !isnan(la[1])
                        T, ghiL = la
                        Tma = ml_trailing_ma48(Tseries, h)
                        if !isnan(Tma)
                            ar_series = get(_ar_cache, z, nothing)
                            ar1 = ar_series === nothing ? NaN : get(ar_series, h - Day(1), NaN)
                            ar7 = ar_series === nothing ? NaN : get(ar_series, h - Day(7), NaN)
                            is_hol = (Date(h) in holset) ? 1.0 : 0.0
                            lf = ml_load_features(h, lat0, lon0, T, ghiL, Tma, ar1, ar7, is_hol)
                            load_v = ml_predict_load(models, z, lf)
                        end
                    end
                elseif pack_load_pred !== nothing
                    load_v = get(pack_load_pred, h, missing)
                end

                push!(df, (z, h, lag,
                           nm(get(lagg, h, (NaN, NaN))[1]),         # temp_c (pop-weighted T)
                           nm(ghi), nm(cloud), nm(pres), nm(v100m),
                           nm(solar_v), nm(wind_v), nm(res_v), nm(load_v),
                           ssrc, wsrc, lsrc))
            end
        end
    end
    return df
end

# ---------------------------------------------------------------------------
# Reference (ENTSO-E day-ahead) forecast + settled actuals + reservoir queries.
# Postgres-dialect SQL; the DuckDB dialect rewrite (sql2df) handles both stores.
# ---------------------------------------------------------------------------

"ENTSO-E day-ahead RES forecast (the market's own reference), hourly, solar/wind
summed over the wind sub-types. `Dict{(zone,'solar'|'wind',hour)=>mw}`."
function ref_res_da(zones::Vector{String}, d_lo::Date, d_hi::Date)
    df = Euphemia.sql2df_with_retry("""
        WITH hourly AS (
          SELECT area_map_code AS zone, production_type AS pt,
                 date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS h,
                 avg(day_ahead_generation_forecast_mw) AS mw
          FROM entsoe.generation_forecasts_for_wind_and_solar
          WHERE area_map_code = ANY(\$1)
            AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
            AND (production_type = 'Solar' OR production_type LIKE 'Wind%')
            AND day_ahead_generation_forecast_mw IS NOT NULL
            AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
            AND date_time_utc <  ((\$3::date + 1)::timestamp AT TIME ZONE 'UTC')
          GROUP BY 1, 2, 3)
        SELECT zone, CASE WHEN pt = 'Solar' THEN 'solar' ELSE 'wind' END AS k,
               h, sum(mw) AS mw
        FROM hourly GROUP BY 1, 2, 3
    """, [zones, d_lo, d_hi])
    out = Dict{Tuple{String,String,DateTime},Float64}()
    for r in eachrow(df)
        out[(String(r.zone), String(r.k), DateTime(r.h))] = Float64(r.mw)
    end
    return out
end

"Settled actual RES generation (aggregated per type), hourly, wind summed."
function act_res(zones::Vector{String}, d_lo::Date, d_hi::Date)
    df = Euphemia.sql2df_with_retry("""
        WITH hourly AS (
          SELECT area_map_code AS zone, production_type AS pt,
                 date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS h,
                 avg(actual_generation_output_mw) AS mw
          FROM entsoe.aggregated_generation_per_type
          WHERE area_map_code = ANY(\$1)
            AND (production_type = 'Solar' OR production_type LIKE 'Wind%')
            AND actual_generation_output_mw IS NOT NULL
            AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
            AND date_time_utc <  ((\$3::date + 1)::timestamp AT TIME ZONE 'UTC')
          GROUP BY 1, 2, 3)
        SELECT zone, CASE WHEN pt = 'Solar' THEN 'solar' ELSE 'wind' END AS k,
               h, sum(mw) AS mw
        FROM hourly GROUP BY 1, 2, 3
    """, [zones, d_lo, d_hi])
    out = Dict{Tuple{String,String,DateTime},Float64}()
    for r in eachrow(df)
        out[(String(r.zone), String(r.k), DateTime(r.h))] = Float64(r.mw)
    end
    return out
end

"Settled actual total load, hourly. `Dict{(zone,hour)=>mw}`."
function act_load(zones::Vector{String}, d_lo::Date, d_hi::Date)
    df = Euphemia.sql2df_with_retry("""
        SELECT area_map_code AS zone,
               date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS h,
               avg(total_load_mw) AS mw
        FROM entsoe.actual_total_load
        WHERE area_map_code = ANY(\$1)
          AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
          AND total_load_mw IS NOT NULL
          AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc <  ((\$3::date + 1)::timestamp AT TIME ZONE 'UTC')
        GROUP BY 1, 2
    """, [zones, d_lo, d_hi])
    out = Dict{Tuple{String,DateTime},Float64}()
    for r in eachrow(df)
        out[(String(r.zone), DateTime(r.h))] = Float64(r.mw)
    end
    return out
end

"""
    reservoir_panel(zones, week_from) -> DataFrame

Weekly reservoir state per hydro `zone` from `entsoe.aggregated_hydro_storage_`
`filling_rate`, computed with the SAME definitions as get_reservoir_drawdown /
get_reservoir_dryness (src/merit_order/fleet_data.jl):
  fill_ratio = stored / trailing-52-week max  (1 − drawdown; the seasonal signal)
  dryness    = clamp(1 − stored / same-ISO-week prior-year median, 0, 1)
Both use only weeks at or before each row's week (ex-ante). Rows from `week_from`
(a `(year, week)` cutoff expressed as an ISO date) onward are emitted; the query
pulls prior years for the norms.
"""
function reservoir_panel(zones::Vector{String}, week_from::Date)
    raw = Euphemia.sql2df_with_retry("""
        SELECT area_map_code AS zone, year, week,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY stored_energy_mwh) AS stored
        FROM entsoe.aggregated_hydro_storage_filling_rate
        WHERE area_map_code = ANY(\$1) AND area_type_code LIKE 'BZN%'
          AND stored_energy_mwh IS NOT NULL
        GROUP BY 1, 2, 3
    """, [zones])
    out = DataFrame(zone=String[], iso_year=Int[], iso_week=Int[], week_start=Date[],
                    stored_energy_mwh=Union{Missing,Float64}[],
                    fill_ratio=Union{Missing,Float64}[], dryness=Union{Missing,Float64}[])
    cutoff_ord = (year(week_from), Int(Dates.week(week_from)))
    for z in sort(unique(String.(raw.zone)))
        sub = sort(raw[String.(raw.zone) .== z, :], [:year, :week])
        yrs = Int.(sub.year); wks = Int.(sub.week); st = Float64.(sub.stored)
        n = length(st)
        for i in 1:n
            (yrs[i], wks[i]) >= cutoff_ord || continue
            # trailing-52-week max (weeks strictly at/before i, back 52)
            lo_ord = _week_minus(yrs[i], wks[i], 52)
            mx = -Inf
            for j in 1:i
                (yrs[j], wks[j]) >= lo_ord && (mx = max(mx, st[j]))
            end
            fill_ratio = mx > 0 ? clamp(st[i] / mx, 0.0, 1.5) : missing
            # same-ISO-week (±0) prior-year median for dryness
            prior = Float64[st[j] for j in 1:n if wks[j] == wks[i] && yrs[j] < yrs[i]]
            dryness = isempty(prior) ? missing :
                      let med = median(prior); med > 0 ? clamp(1.0 - st[i] / med, 0.0, 1.0) : missing end
            wk_start = _iso_week_monday(yrs[i], wks[i])
            push!(out, (z, yrs[i], wks[i], wk_start, st[i], nm(fill_ratio), nm(dryness)))
        end
    end
    return out
end

"(year, week) that is `n` ISO weeks before (y, w), as an orderable tuple (approx,
52-week years — matches the get_reservoir_* trailing-window intent)."
function _week_minus(y::Int, w::Int, n::Int)
    tot = y * 52 + (w - 1) - n
    return (fld(tot, 52), mod(tot, 52) + 1)
end

"Monday of ISO (year, week) — the week's start date."
_iso_week_monday(y::Int, w::Int) =
    let jan4 = Date(y, 1, 4); Date(jan4 - Day(dayofweek(jan4) - 1) + Week(w - 1)) end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# ml_ar_load_lags is fetched once and shared into build_ml_input_panel via this
# module-level cache (keeps the panel loop's signature identical to build_ml_inputs).
const _ar_cache = Dict{String,Dict{DateTime,Float64}}()

function main()
    println("=" ^ 70)
    println("EXPORT PREDICTION INPUTS  cv=$CV  out=$INPUTS_DIR")
    println("=" ^ 70)
    mkpath(INPUTS_DIR)

    asof = haskey(ENV, "INPUTS_ASOF") ? Date(ENV["INPUTS_ASOF"]) : Date(now(UTC))
    market_first = asof - Day(HIST_DAYS)
    market_last = asof + Day(HORIZON_DAYS)
    first_utc = market_first - Day(1)
    candidates = Set(market_first:Day(1):market_last)
    zones = String.(EXPORT_ZONES)
    pilot_zones = String[z for z in zones if is_ml_pilot(z)]
    pack_zones = String[z for z in zones if !is_ml_pilot(z)]
    println("zones=$(length(zones)) (ml pilots=$(join(pilot_zones, ",")); " *
            "pack=$(length(pack_zones))) window(market days)=$market_first..$market_last asof=$asof")

    # AR load lags once (D-1/D-7 DA forecasts) — only the ML-load pilots read them
    # (the pack-load path has no AR feature); shared into the panel loop.
    span_hours = collect(DateTime(first_utc):Hour(1):DateTime(market_last) + Hour(23))
    if !isempty(pilot_zones)
        for (z, s) in ml_ar_load_lags(pilot_zones, span_hours); _ar_cache[z] = s; end
    end

    panel = build_ml_input_panel(zones, first_utc, market_last, candidates; asof)
    println("panel: $(nrow(panel)) zone-hours")

    ref = ref_res_da(zones, first_utc, market_last)
    acts = act_res(zones, first_utc, market_last)
    aload = act_load(zones, first_utc, market_last)

    counts = Dict{String,Any}()
    map_summary = Vector{Dict{String,Any}}()
    for z in zones
        zp = sort(panel[panel.zone .== z, :], :date_time_utc)
        isempty(zp) && (println("  $z: no rows"); continue)
        n = nrow(zp)
        ref_solar = Vector{Union{Missing,Float64}}(missing, n)
        ref_wind = Vector{Union{Missing,Float64}}(missing, n)
        ref_load = Vector{Union{Missing,Float64}}(missing, n)
        act_solar_v = Vector{Union{Missing,Float64}}(missing, n)
        act_wind_v = Vector{Union{Missing,Float64}}(missing, n)
        act_load_v = Vector{Union{Missing,Float64}}(missing, n)
        ars = get(_ar_cache, z, Dict{DateTime,Float64}())
        for (i, h) in enumerate(zp.date_time_utc)
            ref_solar[i] = nm(get(ref, (z, "solar", h), missing))
            ref_wind[i] = nm(get(ref, (z, "wind", h), missing))
            ref_load[i] = nm(get(ars, h, missing))
            act_solar_v[i] = nm(get(acts, (z, "solar", h), missing))
            act_wind_v[i] = nm(get(acts, (z, "wind", h), missing))
            act_load_v[i] = nm(get(aload, (z, h), missing))
        end
        zp.ref_solar_mw = ref_solar; zp.ref_wind_mw = ref_wind; zp.ref_load_mw = ref_load
        zp.act_solar_mw = act_solar_v; zp.act_wind_mw = act_wind_v; zp.act_load_mw = act_load_v
        counts["inputs/$z.parquet"] = write_parquet(zp, joinpath(INPUTS_DIR, "$z.parquet"))
        println("  wrote inputs/$z.parquet ($n rows)")

        # Map summary: freshest forecast market day, midday (UTC 09–14 ≈ Athens
        # 11–16) mean predicted RES coverage; collapse-risk when price-taker RES
        # supply approaches load (coverage ≥ 0.75, a simple ex-ante flag).
        last_day = maximum(Date.(zp.date_time_utc))
        midday = zp[(Date.(zp.date_time_utc) .== last_day) .&
                    (hour.(zp.date_time_utc) .>= 9) .& (hour.(zp.date_time_utc) .<= 14), :]
        res_vals = collect(skipmissing(midday.pred_res_mw))
        load_vals = collect(skipmissing(midday.pred_load_mw))
        rmean = isempty(res_vals) ? missing : mean(res_vals)
        lmean = isempty(load_vals) ? missing : mean(load_vals)
        cov = (rmean === missing || lmean === missing || lmean <= 0) ? missing : rmean / lmean
        push!(map_summary, Dict{String,Any}(
            "zone" => z, "date" => string(last_day),
            "midday_res_mw" => nm(rmean) === missing ? nothing : round(rmean; digits=1),
            "midday_load_mw" => nm(lmean) === missing ? nothing : round(lmean; digits=1),
            "coverage" => nm(cov) === missing ? nothing : round(cov; digits=3),
            "collapse_risk" => (cov !== missing && cov >= 0.75),
            # Zone-level provenance for the map badge/tooltip: 'ml' if this zone is
            # an ML pilot (LightGBM winner on at least one target), else 'pack'.
            "model" => is_ml_pilot(z) ? "ml" : "pack"))
    end

    # Reservoir panel — the hydro zones present in the table over the window.
    hydro_all = Euphemia.sql2df_with_retry("""
        SELECT DISTINCT area_map_code AS zone
        FROM entsoe.aggregated_hydro_storage_filling_rate
        WHERE area_type_code LIKE 'BZN%' AND stored_energy_mwh IS NOT NULL
          AND year >= \$1
        ORDER BY 1
    """, [year(asof) - 1])
    hydro_zones = String.(hydro_all.zone)
    resv = reservoir_panel(hydro_zones, market_first)
    counts["reservoir.parquet"] = write_parquet(resv, joinpath(INPUTS_DIR, "reservoir.parquet"))
    println("wrote inputs/reservoir.parquet ($(nrow(resv)) zone-weeks, $(length(hydro_zones)) zones)")

    updated_at = get(ENV, "UPDATED_AT", Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SS") * "Z")
    manifest = Dict(
        "schema" => "v1",
        "updated_at" => updated_at,
        "code_version" => CV,
        "market_day_tz" => "Europe/Athens",
        "vintage_note" => "vintage_lag: 0 = the forecast run current at the horizon; " *
            "1 = the D-1-issued GFS previous_day1 vintage for settled history. " *
            "Every driver and prediction is ex-ante (bin/weather_vintage.jl).",
        "zones" => zones,               # every exported zone (the full open surface)
        "pilot_zones" => pilot_zones,    # ML subset (LightGBM per-zone-winner)
        "pack_zones" => pack_zones,      # linear-pack remainder
        "hydro_zones" => hydro_zones,
        "window" => Dict("market_first" => string(market_first),
                         "market_last" => string(market_last), "asof" => string(asof)),
        "columns" => Dict(
            "temp_c" => "pop-weighted 2 m temperature (°C)",
            "ghi_wm2" => "global horizontal / shortwave radiation (W/m²)",
            "cloud_pct" => "total cloud cover (%)",
            "pressure_hpa" => "surface pressure (hPa)",
            "wind100_ms" => "mean 100 m wind speed over the zone cells (m/s)",
            "pred_solar_mw" => "model predicted solar (per-zone-winner)",
            "pred_wind_mw" => "model predicted wind (per-zone-winner)",
            "pred_res_mw" => "predicted solar+wind entering the clear",
            "pred_load_mw" => "model predicted load",
            "ref_*_mw" => "ENTSO-E day-ahead forecast (null where unpublished)",
            "act_*_mw" => "settled actual (null until settled)",
            "src_*" => "per-target provenance: 'ml' (LightGBM, pilot zones) or " *
                       "'pack' (linear weather pack, everywhere else)"),
        "row_counts" => counts,
        "map" => map_summary,
    )
    open(joinpath(INPUTS_DIR, "manifest.json"), "w") do io
        JSON.print(io, manifest)
    end
    println("wrote inputs/manifest.json (updated_at=$updated_at)")
    println("EXPORT COMPLETE")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
