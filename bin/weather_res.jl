# Weather-based RES (wind + solar) prediction for the ex-ante forecast track.
#
# Loads the fitted per-zone ridge models (bin/res_models_v2.json preferred —
# wind ridge trained on GFS-vintage wind_speed_100m so training matches the
# GFS forecasts served here; solar on ERA5 shortwave_radiation, GFS-safe;
# bin/res_models_v1.json as fallback, EUPHEMIA_RES_PACK to override),
# fetches raw weather forecasts from the PUBLIC open-meteo forecast API, and
# predicts per-zone hourly wind+solar MW. Because the inputs are raw weather
# (not ENTSO-E's D-1 RES forecasts), predictions can be frozen BEFORE the
# 12:00 CET auction gate — the "ex-ante track" (INPUT_MODE=weather in
# bin/daily_forecast.jl).
#
# Include-able helper (main is guarded): pure feature/parsing functions are
# unit-tested in test/test_weather_res.jl with no network access.
#
# Feature vectors MUST match the fit exactly (analysis provenance: v1
# fit_eu_models.jl trained 2025-09-01..2026-06-30 on ERA5; v2 wind refit on
# GFS previous_day1 vintages 2024-07..2026-05 — same feature construction,
# see docs/experiments/res-forecasting/README.md "v2 pack"):
#   wind:  X = [1, pcurve.(v100_cells), v100_cells ./ 3.6]   (cells in pack order)
#   solar: X = [1, g, se, g*se, sqrt(max(g,0)),
#               (1{hod==k}*g for k in 3:19), (1{hod==k} for k in 3:19)]
# where g = mean over cells of shortwave_radiation (GHI, W/m²), se = sun
# elevation via sinel(), hod = hour-of-day UTC. Predictions clamp to ≥ 0.
#
# Env vars:
#   EUPHEMIA_OPENMETEO_URL     API base (default https://api.open-meteo.com/v1/forecast)
#   EUPHEMIA_OPENMETEO_PREVRUNS_URL  previous-runs API base for vintage_lag>0
#                              fetches (default the public previous-runs API —
#                              a self-hosted forecast mirror has no previous
#                              runs, so catch-up fetches go public)
#   EUPHEMIA_OPENMETEO_MODELS  weather model(s), default 'gfs_seamless'; a
#                              comma-separated list requests all models and
#                              averages per-model arrays element-wise (nulls
#                              ignored) — that is the ensemble.
#
# Standalone smoke test (no DB):
#   julia --project=. bin/weather_res.jl [ZONE] [YYYY-MM-DD]

using Dates, Statistics, Downloads, JSON

const OPENMETEO_URL_DEFAULT = "https://api.open-meteo.com/v1/forecast"
const OPENMETEO_PREVRUNS_URL_DEFAULT = "https://previous-runs-api.open-meteo.com/v1/forecast"
const OPENMETEO_USER_AGENT = "philokalia-energy/1.0 (contact: pankgeorg@gmail.com)"
const OPENMETEO_BATCH = 50            # max locations per API call
const OPENMETEO_RETRIES = 6
# A 429 (rate limit) needs a cooldown that spans the API's per-minute rate
# window, not the short exponential backoff a transient network error uses.
# Overridable so a self-hosted instance with no limit can shorten it.
const OPENMETEO_RL_COOLDOWN_S = parse(Float64, get(ENV, "EUPHEMIA_OPENMETEO_RL_COOLDOWN", "20.0"))
const RES_MODELS_PATH_V2 = joinpath(@__DIR__, "res_models_v2.json")
const RES_MODELS_PATH_V1 = joinpath(@__DIR__, "res_models_v1.json")

"""
    default_res_models_path() -> String

Model pack selection: `EUPHEMIA_RES_PACK` (explicit path, for rollback) wins;
otherwise prefer `res_models_v2.json` (wind refit on GFS-vintage features —
matches the GFS forecasts served at inference) with `res_models_v1.json` as
fallback.
"""
function default_res_models_path()
    override = get(ENV, "EUPHEMIA_RES_PACK", "")
    isempty(override) || return override
    return isfile(RES_MODELS_PATH_V2) ? RES_MODELS_PATH_V2 : RES_MODELS_PATH_V1
end

# ---------------------------------------------------------------------------
# Pure feature functions (unit-tested; must match the fit exactly)
# ---------------------------------------------------------------------------

"""
    pcurve(v_kmh) -> Float64

Normalized turbine power curve on wind speed in km/h: cut-in 3 m/s, rated
12 m/s, cut-out 25 m/s, cubic ramp between cut-in and rated.
"""
function pcurve(v_kmh::Real)
    x = v_kmh / 3.6
    (x < 3 || x >= 25) && return 0.0
    x >= 12 && return 1.0
    return ((x - 3) / 9)^3
end

"""
    sinel(t::DateTime, lat0::Real, lon0::Real) -> Float64

Sun elevation proxy (sine of solar elevation, clamped ≥ 0) at UTC instant `t`
for the zone centroid (`lat0`, `lon0` in degrees).
"""
function sinel(t::DateTime, lat0::Real, lon0::Real)
    doy = dayofyear(t)
    dec = 0.409 * sin(2π * (doy + 284) / 365)
    H = (hour(t) + lon0 / 15 - 12) * 15π / 180
    return max(sind(lat0) * sin(dec) + cosd(lat0) * cos(dec) * cos(H), 0.0)
end

"""
    wind_feature_vector(v100::Vector{Float64}) -> Vector{Float64}

X = [1, pcurve.(v100), v100 ./ 3.6] with cells in the model pack's order.
"""
wind_feature_vector(v100::Vector{Float64}) =
    vcat(1.0, pcurve.(v100), v100 ./ 3.6)

"""
    solar_feature_vector(g::Real, t::DateTime, lat0::Real, lon0::Real) -> Vector{Float64}

X = [1, g, se, g*se, sqrt(max(g,0)), (1{hod==k}*g for k in 3:19),
     (1{hod==k} for k in 3:19)], hod = hour(t) UTC. Length 39.
"""
function solar_feature_vector(g::Real, t::DateTime, lat0::Real, lon0::Real)
    se = sinel(t, lat0, lon0)
    hod = hour(t)
    hod_g = [hod == k ? Float64(g) : 0.0 for k in 3:19]
    hod_i = [hod == k ? 1.0 : 0.0 for k in 3:19]
    return vcat(1.0, Float64(g), se, g * se, sqrt(max(g, 0.0)), hod_g, hod_i)
end

dotv(a::AbstractVector, b::AbstractVector) = sum(Float64(x) * Float64(y) for (x, y) in zip(a, b))

"Wind MW for one hour from the zone's wind model and per-cell v100 (km/h). ≥ 0."
predict_wind_hour(wind_model, v100::Vector{Float64}) =
    max(dotv(wind_model["coef"], wind_feature_vector(v100)), 0.0)

"Solar MW for one hour from the zone's solar model and mean GHI (W/m²). ≥ 0."
predict_solar_hour(solar_model, g::Real, t::DateTime) =
    max(dotv(solar_model["coef"],
             solar_feature_vector(g, t, solar_model["lat0"], solar_model["lon0"])), 0.0)

# ---------------------------------------------------------------------------
# open-meteo response parsing (pure; unit-tested on literal JSON)
# ---------------------------------------------------------------------------

isnullv(x) = x === nothing || x === missing

"""
    average_hourly(hourly::AbstractDict, var::String) -> Vector{Union{Nothing,Float64}}

Element-wise mean over all per-model arrays of `var` in one location's
"hourly" block, ignoring nulls. With a single model the API returns the plain
key ("wind_speed_100m"); with `models=a,b,…` it returns one suffixed key per
model ("wind_speed_100m_gfs_seamless", …) — both shapes are handled, and the
multi-model average IS the ensemble. Hours where every model is null stay
`nothing`.

`var` must be the FULL requested variable name including any vintage suffix
(e.g. "wind_speed_100m_previous_day1"): matching is `k == var` or
`startswith(k, var * "_")`, so a response carrying BOTH a plain current-run
key and the requested previous-runs key can never blend vintages — the plain
key is not a match for the suffixed request.
"""
function average_hourly(hourly::AbstractDict, var::String)
    keys_ = [k for k in keys(hourly)
             if k != "time" && (k == var || startswith(String(k), var * "_"))]
    isempty(keys_) && return Union{Nothing,Float64}[]
    n = maximum(length(hourly[k]) for k in keys_)
    out = Vector{Union{Nothing,Float64}}(nothing, n)
    for i in 1:n
        acc = 0.0
        cnt = 0
        for k in keys_
            arr = hourly[k]
            i <= length(arr) || continue
            isnullv(arr[i]) && continue
            acc += Float64(arr[i])
            cnt += 1
        end
        cnt > 0 && (out[i] = acc / cnt)
    end
    return out
end

"""
    parse_openmeteo_response(body::AbstractString, cells) ->
        Dict{Tuple{Float64,Float64}, Dict{DateTime, Tuple{Float64,Float64}}}

Parse one open-meteo forecast response for `cells` (the (lat,lon) tuples of
this batch, in request order). Multi-location requests return a JSON ARRAY of
per-location objects in input order; single-location requests return one
object — both shapes are handled. Per cell: hour → (v100 km/h, GHI W/m²).
Hours where either variable is null across all models are dropped.
"""
function parse_openmeteo_response(body::AbstractString,
                                  cells::Vector{Tuple{Float64,Float64}};
                                  var_suffix::String="")
    parsed = JSON.parse(String(body))
    locs = parsed isa AbstractVector ? parsed : [parsed]
    length(locs) == length(cells) ||
        error("open-meteo returned $(length(locs)) locations for $(length(cells)) requested cells")
    out = Dict{Tuple{Float64,Float64},Dict{DateTime,Tuple{Float64,Float64}}}()
    for (cell, loc) in zip(cells, locs)
        hourly = loc["hourly"]
        times = [DateTime(String(t), dateformat"yyyy-mm-ddTHH:MM") for t in hourly["time"]]
        v100 = average_hourly(hourly, "wind_speed_100m" * var_suffix)
        ghi = average_hourly(hourly, "shortwave_radiation" * var_suffix)
        d = Dict{DateTime,Tuple{Float64,Float64}}()
        for (i, t) in enumerate(times)
            v = i <= length(v100) ? v100[i] : nothing
            g = i <= length(ghi) ? ghi[i] : nothing
            (v === nothing || g === nothing) && continue
            d[t] = (v, g)
        end
        out[cell] = d
    end
    return out
end

# ---------------------------------------------------------------------------
# Model pack + network fetch
# ---------------------------------------------------------------------------

"""
    load_res_models(path=default_res_models_path()) -> parsed model pack

{"zones": {"<ZONE>": {"cells": [[lat,lon],…], "wind": {...}, "solar": {...}}}};
zones may lack "wind" or "solar" (physically negligible there → predicted 0).
Default pack: v2 (GFS-vintage-trained wind) if present, else v1; override with
`EUPHEMIA_RES_PACK=<path>` for rollback.
"""
load_res_models(path::AbstractString=default_res_models_path()) = JSON.parse(read(path, String))

"True if `e` is an open-meteo HTTP 429 (Too Many Requests) rate-limit response."
function _openmeteo_is_rate_limited(e)
    e isa Downloads.RequestError || return false
    resp = getfield(e, :response)
    return resp !== nothing && hasproperty(resp, :status) && resp.status == 429
end

function _openmeteo_get(url::String)
    last_err = nothing
    for attempt in 1:OPENMETEO_RETRIES
        try
            buf = IOBuffer()
            Downloads.download(url, buf;
                headers=["User-Agent" => OPENMETEO_USER_AGENT],
                timeout=120)
            return String(take!(buf))
        catch e
            last_err = e
            attempt == OPENMETEO_RETRIES && break
            # 429 → a fixed cooldown long enough for the rate window to reset;
            # otherwise the short exponential backoff. Jitter de-syncs the many
            # per-zone fetches so they don't retry in lockstep and re-trip the limit.
            rl = _openmeteo_is_rate_limited(e)
            wait_s = (rl ? OPENMETEO_RL_COOLDOWN_S : 2.0^attempt) * (0.75 + 0.5 * rand())
            @warn "open-meteo request $(rl ? "rate-limited (429)" : "failed") " *
                  "(attempt $attempt/$OPENMETEO_RETRIES); retrying in $(round(wait_s, digits=1))s" exception=e
            sleep(wait_s)
        end
    end
    error("open-meteo request failed after $OPENMETEO_RETRIES attempts: $last_err")
end

include(joinpath(@__DIR__, "weather_vintage.jl"))   # openmeteo_vintage_lag (single definition)

"""
    fetch_weather(cells, dates; vintage_lag=0) ->
        Dict{Tuple{Float64,Float64}, Dict{DateTime, Tuple{Float64,Float64}}}

Fetch hourly (wind_speed_100m km/h, shortwave_radiation W/m²) forecasts for
`cells` (vector of (lat,lon)) covering `dates` (UTC calendar days) from the
public open-meteo forecast API. Locations are BATCHED (comma-separated
latitude=/longitude= lists, ≤ $(OPENMETEO_BATCH) per call); `models=` comes
from EUPHEMIA_OPENMETEO_MODELS (default gfs_seamless; multiple comma-separated
models are ensemble-averaged — see `average_hourly`). Retries ×$(OPENMETEO_RETRIES)
with backoff.

`vintage_lag` (from `openmeteo_vintage_lag`) enforces the D-1-vintage
discipline: `0` uses the live forecast API's current run; `1..7` requests the
`_previous_dayN`-suffixed variables from the previous-runs API, i.e. the run
issued N days ago (`average_hourly` matches the suffixed response keys by
prefix, so parsing is unchanged). An explicit `base_url` always wins; otherwise
the URL comes from `EUPHEMIA_OPENMETEO_URL` / `EUPHEMIA_OPENMETEO_PREVRUNS_URL`
per the selected API family.
"""
function fetch_weather(cells::Vector{Tuple{Float64,Float64}}, dates::Vector{Date};
                       vintage_lag::Int=0,
                       base_url::String="",
                       models::String=get(ENV, "EUPHEMIA_OPENMETEO_MODELS", "gfs_seamless"))
    0 <= vintage_lag <= 7 ||
        error("fetch_weather: vintage_lag must be 0..7 (got $vintage_lag)")
    isempty(cells) && return Dict{Tuple{Float64,Float64},Dict{DateTime,Tuple{Float64,Float64}}}()
    isempty(dates) && error("fetch_weather: empty date list")
    public_default = vintage_lag > 0 ? OPENMETEO_PREVRUNS_URL_DEFAULT : OPENMETEO_URL_DEFAULT
    url_base = !isempty(base_url) ? base_url :
        (vintage_lag > 0 ? get(ENV, "EUPHEMIA_OPENMETEO_PREVRUNS_URL", OPENMETEO_PREVRUNS_URL_DEFAULT) :
                           get(ENV, "EUPHEMIA_OPENMETEO_URL", OPENMETEO_URL_DEFAULT))
    sfx = vintage_lag > 0 ? "_previous_day$(vintage_lag)" : ""
    vintage_lag > 0 &&
        println("  🕰️ vintage fetch: previous_day$(vintage_lag) via $url_base")
    d0, d1 = extrema(dates)
    out = Dict{Tuple{Float64,Float64},Dict{DateTime,Tuple{Float64,Float64}}}()
    for lo in 1:OPENMETEO_BATCH:length(cells)
        batch = cells[lo:min(lo + OPENMETEO_BATCH - 1, length(cells))]
        lats = join((string(c[1]) for c in batch), ",")
        lons = join((string(c[2]) for c in batch), ",")
        url = url_base *
              "?latitude=" * lats * "&longitude=" * lons *
              "&hourly=wind_speed_100m" * sfx * ",shortwave_radiation" * sfx *
              "&models=" * models *
              "&start_date=" * Dates.format(d0, "yyyy-mm-dd") *
              "&end_date=" * Dates.format(d1, "yyyy-mm-dd") *
              "&timezone=UTC"
        body = try
            _openmeteo_get(url)
        catch e
            # Self-hosted instance down? Fall back to the public API for this
            # batch (slower, rate-limited, but keeps the morning window alive).
            # An EXPLICITLY passed base_url (e.g. the ERA5 archive in
            # refresh_duckdb_extract) never falls back — that would silently
            # cross API families.
            (!isempty(base_url) || url_base == public_default) && rethrow(e)
            fb_url = replace(url, url_base => public_default)
            @warn "open-meteo primary ($url_base) failed; falling back to public API" exception=e
            _openmeteo_get(fb_url)
        end
        merge!(out, parse_openmeteo_response(body, batch; var_suffix=sfx))
    end
    return out
end

"""
    predict_res(models, zone, hours::Vector{DateTime}, weather) -> Dict{DateTime,Float64}

Per-hour wind+solar MW for `zone` from the model pack and fetched `weather`
(cell → hour → (v100, ghi)). Components with no model in the pack predict 0
(physically negligible). Hours with incomplete weather across the zone's
cells are skipped with a warning.
"""
function predict_res(models, zone::String, hours::Vector{DateTime}, weather)
    zm = get(models["zones"], zone, nothing)
    out = Dict{DateTime,Float64}()
    if zm === nothing
        @warn "predict_res: zone $zone not in model pack — RES predicted 0"
        return out
    end
    cells = [(Float64(c[1]), Float64(c[2])) for c in zm["cells"]]
    wind_model = get(zm, "wind", nothing)
    solar_model = get(zm, "solar", nothing)
    n_skipped = 0
    for t in hours
        v100 = Vector{Float64}(undef, length(cells))
        ghi_sum = 0.0
        ok = true
        for (i, cell) in enumerate(cells)
            cw = get(weather, cell, nothing)
            hv = cw === nothing ? nothing : get(cw, t, nothing)
            if hv === nothing
                ok = false
                break
            end
            v100[i] = hv[1]
            ghi_sum += hv[2]
        end
        if !ok
            n_skipped += 1
            continue
        end
        g = ghi_sum / length(cells)
        mw = 0.0
        wind_model !== nothing && (mw += predict_wind_hour(wind_model, v100))
        solar_model !== nothing && (mw += predict_solar_hour(solar_model, g, t))
        out[t] = mw
    end
    n_skipped > 0 &&
        @warn "predict_res: $zone — $n_skipped/$(length(hours)) hour(s) skipped (incomplete weather)"
    return out
end

# ---------------------------------------------------------------------------
# Guarded main: smoke test (fetch + predict one zone, print hourly MW)
# ---------------------------------------------------------------------------

if abspath(PROGRAM_FILE) == @__FILE__
    zone = length(ARGS) >= 1 ? ARGS[1] : "GR"
    day = length(ARGS) >= 2 ? Date(ARGS[2]) : Dates.today() + Day(1)
    println("weather_res smoke: zone=$zone day=$day (UTC hours)")
    pack = load_res_models()
    zm = pack["zones"][zone]
    cells = [(Float64(c[1]), Float64(c[2])) for c in zm["cells"]]
    println("  $(length(cells)) cells; wind=$(haskey(zm, "wind")) solar=$(haskey(zm, "solar"))")
    weather = fetch_weather(cells, [day]; vintage_lag=openmeteo_vintage_lag(day))
    hours = collect(DateTime(day):Hour(1):DateTime(day) + Hour(23))
    pred = predict_res(pack, zone, hours, weather)
    for t in hours
        mw = get(pred, t, nothing)
        println("  ", Dates.format(t, "yyyy-mm-dd HH:MM"), "  ",
                mw === nothing ? "(no weather)" : string(round(mw, digits=1)), " MW")
    end
end
