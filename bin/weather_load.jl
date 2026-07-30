# Weather+calendar LOAD prediction for the daily forecast's per-zone eligibility
# fill (bin/daily_forecast.jl). This is the INFERENCE half of the D-n load model
# (docs/experiments/dn-load-model/README.md); bin/fit_load_models.jl is the FIT
# half and writes the committed pack bin/load_models_v1.json.
#
# The model is a per-zone ridge (closed form, no new deps) on 207 features:
#   - 168 local hour-of-week one-hots (EU-DST-aware local time)
#   - public-holiday flag + holiday × local-hour-of-day one-hots (Gregorian /
#     Orthodox computus per zone country)
#   - heating/cooling degree-hours (T, T², and the same on a trailing-48h mean T
#     for thermal inertia)
#   - GHI (behind-the-meter-PV suppression proxy)
#   - day-of-year Fourier (2 harmonics) + a linear trend
# Feature construction MUST match the fit exactly (both include this file).
#
# Temperature/GHI source: the SAME public open-meteo APIs bin/weather_res.jl
# uses — the ARCHIVE (ERA5) API at fit time, the FORECAST API at predict time.
# Per-zone representative cities (population-weighted) are baked into the pack
# as "cities" (see bin/fit_load_models.jl CITIES), exactly like the RES pack.
#
# Include-able helper: pure feature/calendar functions are unit-tested in
# test/test_weather_load.jl with no network and no DB.
#
# Env vars (predict-time weather fetch):
#   EUPHEMIA_OPENMETEO_URL     forecast API base (default the public forecast API)
#   EUPHEMIA_OPENMETEO_MODELS  weather model(s), default 'gfs_seamless'
#   EUPHEMIA_LOAD_PACK         explicit pack path (rollback override)
#
# Standalone smoke test (no DB, network for weather):
#   julia --project=. bin/weather_load.jl [ZONE] [YYYY-MM-DD]

using Dates, Statistics, LinearAlgebra, Downloads, JSON

const LOAD_MODELS_PATH_V1 = joinpath(@__DIR__, "load_models_v1.json")
const OPENMETEO_FORECAST_URL_DEFAULT = "https://api.open-meteo.com/v1/forecast"
const OPENMETEO_ARCHIVE_URL_DEFAULT = "https://archive-api.open-meteo.com/v1/archive"
const LOAD_OPENMETEO_PREVRUNS_URL_DEFAULT = "https://previous-runs-api.open-meteo.com/v1/forecast"
const LOAD_OPENMETEO_USER_AGENT = "philokalia-energy/1.0 (contact: pankgeorg@gmail.com)"
const LOAD_OPENMETEO_BATCH = 50
const LOAD_OPENMETEO_RETRIES = 6
# 429 rate-limit cooldown (spans the API's per-minute window; see weather_res.jl).
const LOAD_OPENMETEO_RL_COOLDOWN_S = parse(Float64, get(ENV, "EUPHEMIA_OPENMETEO_RL_COOLDOWN", "20.0"))

# Degree-hour bases (°C). Stored per-zone in the pack too, but these are the
# fit defaults and the fallback when a pack omits them.
const HDH_BASE_DEFAULT = 16.5
const CDH_BASE_DEFAULT = 21.0

# Feature-block layout (must match the fit): 168 HoW + 24 hol×hod + 1 hol flag
# + 8 degree-hour + 1 GHI + 4 Fourier + 1 trend.
const NFEAT_LOAD = 168 + 24 + 1 + 8 + 1 + 4 + 1

"""
    default_load_models_path() -> String

`EUPHEMIA_LOAD_PACK` (explicit path, for rollback) wins; otherwise
`bin/load_models_v1.json`.
"""
function default_load_models_path()
    override = get(ENV, "EUPHEMIA_LOAD_PACK", "")
    isempty(override) || return override
    return LOAD_MODELS_PATH_V1
end

# ---------------------------------------------------------------------------
# Calendar: EU DST rule, per-zone local time, and public holidays (computus).
# Pure; unit-tested. (last_sunday is duplicated deliberately from
# forecast_common.jl so this file is include-able standalone in the fit script.)
# ---------------------------------------------------------------------------
_last_sunday(y, m) = (d = Date(y, m, daysinmonth(Date(y, m))); d - Day(dayofweek(d) % 7))
_is_eu_summer(t::DateTime) =
    (DateTime(_last_sunday(year(t), 3)) + Hour(1)) <= t < (DateTime(_last_sunday(year(t), 10)) + Hour(1))

"Local wall-clock time for a zone whose standard-time UTC offset is `tz_base` hours (all EU zones follow the EU DST rule)."
local_time_load(tz_base::Int, t::DateTime) = t + Hour(tz_base + (_is_eu_summer(t) ? 1 : 0))

"Gregorian (Western) Easter Sunday."
function easter_gregorian(y::Int)
    a = y % 19; b = y ÷ 100; c = y % 100; d = b ÷ 4; e = b % 4
    f = (b + 8) ÷ 25; g = (b - f + 1) ÷ 3; h = (19a + b - d - g + 15) % 30
    i = c ÷ 4; k = c % 4; l = (32 + 2e + 2i - h - k) % 7; m = (a + 11h + 22l) ÷ 451
    mo = (h + l - 7m + 114) ÷ 31; da = ((h + l - 7m + 114) % 31) + 1
    return Date(y, mo, da)
end

"Orthodox Easter Sunday as a Gregorian date (+13d Julian→Gregorian, valid 1900–2099)."
function easter_orthodox(y::Int)
    a = y % 4; b = y % 7; c = y % 19
    d = (19c + 15) % 30; e = (2a + 4b - d + 34) % 7
    mo = (d + e + 114) ÷ 31; da = ((d + e + 114) % 31) + 1
    return Date(y, mo, da) + Day(13)
end

_midsummer_eve(y::Int) = (d = Date(y, 6, 19); d + Day((5 - dayofweek(d) + 7) % 7))  # Friday in Jun 19–25

"""
    holidays_for_country(country::String, years) -> Set{Date}

National public holidays (LOCAL calendar dates) for a country code. Fixed
national days plus Easter-derived movable feasts (Gregorian, or Orthodox
computus for GR/BG/RO/RS). Covers the 39-zone footprint's countries. Returns an
empty set for an unknown country (holiday features simply never fire — safe).
"""
function holidays_for_country(country::String, years)
    hs = Set{Date}()
    for y in years
        eg, eo = easter_gregorian(y), easter_orthodox(y)
        fixed(md...) = foreach(x -> push!(hs, Date(y, x[1], x[2])), md)
        eastr(computus, offsets...) = foreach(o -> push!(hs, computus + Day(o)), offsets)
        if country == "GR"
            fixed((1,1),(1,6),(3,25),(5,1),(8,15),(10,28),(12,25),(12,26))
            eastr(eo, -48, -2, 1, 50)                       # Clean Mon, Good Fri, Easter Mon, Whit Mon
        elseif country == "BG"
            fixed((1,1),(3,3),(5,1),(5,6),(5,24),(9,6),(9,22),(12,24),(12,25),(12,26))
            eastr(eo, -2, 1)
        elseif country == "RO"
            fixed((1,1),(1,2),(1,24),(5,1),(6,1),(8,15),(11,30),(12,1),(12,25),(12,26))
            eastr(eo, -2, 0, 1, 50)
        elseif country == "RS"
            fixed((1,1),(1,2),(1,7),(2,15),(2,16),(5,1),(5,2),(11,11))
            eastr(eo, -2, 1)
        elseif country == "DE"
            fixed((1,1),(5,1),(10,3),(12,25),(12,26))
            eastr(eg, -2, 1, 39, 50)                        # Good Fri, Easter Mon, Ascension, Whit Mon
        elseif country == "FR"
            fixed((1,1),(5,1),(5,8),(7,14),(8,15),(11,1),(11,11),(12,25))
            eastr(eg, 1, 39, 50)
        elseif country == "ES"
            fixed((1,1),(1,6),(5,1),(8,15),(10,12),(11,1),(12,6),(12,8),(12,25))
            eastr(eg, -2)
        elseif country == "PT"
            fixed((1,1),(4,25),(5,1),(6,10),(8,15),(10,5),(11,1),(12,1),(12,8),(12,25))
            eastr(eg, -2, 0, 60)                            # Good Fri, Easter, Corpus Christi
        elseif country == "IT"
            fixed((1,1),(1,6),(4,25),(5,1),(6,2),(8,15),(11,1),(12,8),(12,25),(12,26))
            eastr(eg, 1)
        elseif country == "PL"
            fixed((1,1),(1,6),(5,1),(5,3),(8,15),(11,1),(11,11),(12,25),(12,26))
            eastr(eg, 0, 1, 60)                             # Easter, Easter Mon, Corpus Christi
        elseif country == "CZ"
            fixed((1,1),(5,1),(5,8),(7,5),(7,6),(9,28),(10,28),(11,17),(12,24),(12,25),(12,26))
            eastr(eg, -2, 1)
        elseif country == "SK"
            fixed((1,1),(1,6),(5,1),(5,8),(7,5),(8,29),(9,1),(9,15),(11,1),(11,17),(12,24),(12,25),(12,26))
            eastr(eg, -2, 1)
        elseif country == "HU"
            fixed((1,1),(3,15),(5,1),(8,20),(10,23),(11,1),(12,25),(12,26))
            eastr(eg, -2, 0, 1, 50)
        elseif country == "SI"
            fixed((1,1),(1,2),(2,8),(4,27),(5,1),(5,2),(6,25),(8,15),(10,31),(11,1),(12,25),(12,26))
            eastr(eg, 0, 1)
        elseif country == "AT"
            fixed((1,1),(1,6),(5,1),(8,15),(10,26),(11,1),(12,8),(12,25),(12,26))
            eastr(eg, 1, 39, 50, 60)                        # Easter Mon, Ascension, Whit Mon, Corpus Christi
        elseif country == "CH"
            fixed((1,1),(1,2),(5,1),(8,1),(12,25),(12,26))
            eastr(eg, -2, 1, 39, 50)
        elseif country == "BE"
            fixed((1,1),(5,1),(7,21),(8,15),(11,1),(11,11),(12,25))
            eastr(eg, 1, 39, 50)
        elseif country == "NL"
            fixed((1,1),(4,27),(5,5),(12,25),(12,26))
            eastr(eg, -2, 0, 1, 39, 50)
        elseif country == "LU"
            fixed((1,1),(5,1),(5,9),(6,23),(8,15),(11,1),(12,25),(12,26))
            eastr(eg, 1, 39, 50)
        elseif country == "DK"
            fixed((1,1),(6,5),(12,24),(12,25),(12,26),(12,31))
            eastr(eg, -3, -2, 0, 1, 39, 50)                 # Maundy Thu..Whit Mon
        elseif country == "NO"
            fixed((1,1),(5,1),(5,17),(12,25),(12,26))
            eastr(eg, -3, -2, 0, 1, 39, 50)
        elseif country == "SE"
            fixed((1,1),(1,6),(5,1),(6,6),(12,24),(12,25),(12,26),(12,31))
            eastr(eg, -2, 1, 39)
            push!(hs, _midsummer_eve(y))
        elseif country == "FI"
            fixed((1,1),(1,6),(5,1),(12,6),(12,24),(12,25),(12,26))
            eastr(eg, -2, 0, 1, 39)
            push!(hs, _midsummer_eve(y))
        elseif country == "EE"
            fixed((1,1),(2,24),(5,1),(6,23),(6,24),(8,20),(12,24),(12,25),(12,26))
            eastr(eg, -2, 0, 50)
        elseif country == "LV"
            fixed((1,1),(5,1),(5,4),(6,23),(6,24),(11,18),(12,24),(12,25),(12,26),(12,31))
            eastr(eg, -2, 1)
        elseif country == "LT"
            fixed((1,1),(2,16),(3,11),(5,1),(6,24),(7,6),(8,15),(11,1),(12,24),(12,25),(12,26))
            eastr(eg, 0, 1)
        end
    end
    return hs
end

# ---------------------------------------------------------------------------
# Feature vector (must match the fit exactly).
# ---------------------------------------------------------------------------
"""
    load_feature_vector(t_utc, T, G, Tma, tz_base, hol, trend_origin;
                        hdh_base, cdh_base) -> Vector{Float64}

Feature vector for one hour. `T`/`G` = zone temperature (°C) / GHI (W/m²) at
that hour, `Tma` = trailing-48h mean temperature, `tz_base` = standard-time UTC
offset (hours), `hol` = the zone's holiday date set, `trend_origin` = the fit's
trend zero-date (linear trend in years since it). Length `NFEAT_LOAD` (207).
"""
function load_feature_vector(t_utc::DateTime, T::Float64, G::Float64, Tma::Float64,
                             tz_base::Int, hol::Set{Date}, trend_origin::Date;
                             hdh_base::Float64=HDH_BASE_DEFAULT,
                             cdh_base::Float64=CDH_BASE_DEFAULT)
    lt = local_time_load(tz_base, t_utc)
    how = (dayofweek(lt) - 1) * 24 + hour(lt) + 1          # 1..168
    x = zeros(NFEAT_LOAD)
    x[how] = 1.0
    is_hol = Date(lt) in hol
    o = 168
    is_hol && (x[o + hour(lt) + 1] = 1.0)                  # holiday × local hour-of-day
    o += 24
    x[o + 1] = is_hol ? 1.0 : 0.0
    o += 1
    hdh, cdh = max(hdh_base - T, 0.0), max(T - cdh_base, 0.0)
    hdhm, cdhm = max(hdh_base - Tma, 0.0), max(Tma - cdh_base, 0.0)
    x[o + 1] = hdh;         x[o + 2] = cdh
    x[o + 3] = hdh^2 / 10;  x[o + 4] = cdh^2 / 10
    x[o + 5] = hdhm;        x[o + 6] = cdhm
    x[o + 7] = hdhm^2 / 10; x[o + 8] = cdhm^2 / 10
    o += 8
    x[o + 1] = G / 100                                     # behind-the-meter PV proxy
    o += 1
    doy = dayofyear(lt) / 365.25
    x[o + 1] = sin(2π * doy); x[o + 2] = cos(2π * doy)
    x[o + 3] = sin(4π * doy); x[o + 4] = cos(4π * doy)
    o += 4
    x[o + 1] = Dates.value(t_utc - DateTime(trend_origin)) / (1000.0 * 3600 * 24 * 365.25)
    return x
end

# ---------------------------------------------------------------------------
# Ridge (closed form; intercept unpenalized via centering). Shared fit+predict.
# ---------------------------------------------------------------------------
"Fit a standardized ridge: y ≈ μy + ((X-μx)/σx)·β. Returns the pack fields."
function ridge_fit_load(X::Matrix{Float64}, y::Vector{Float64}, λ::Float64)
    μx = vec(mean(X, dims=1)); σx = vec(std(X, dims=1)); σx[σx .== 0] .= 1.0
    Xs = (X .- μx') ./ σx'
    μy = mean(y)
    β = (Xs' * Xs + λ * size(X, 1) * I) \ (Xs' * (y .- μy))
    return (coef=β, mu_x=μx, sd_x=σx, mu_y=μy, lambda=λ)
end

"Predict from fitted parameters (coef, mu_x, sd_x, mu_y)."
function ridge_predict_load(coef, mu_x, sd_x, mu_y, X::Matrix{Float64})
    return ((X .- mu_x') ./ sd_x') * coef .+ mu_y
end

# ---------------------------------------------------------------------------
# Pack access + open-meteo fetch (temperature_2m + shortwave_radiation).
# ---------------------------------------------------------------------------
"""
    load_load_models(path=default_load_models_path()) -> parsed pack or nothing

Pack shape:
{"version":1, "trend_origin":"2022-07-01", "train_window":"…", "zones":
  {"<ZONE>": {"cities":[[lat,lon,weight],…], "coef":[…], "mu_x":[…], "sd_x":[…],
              "mu_y":…, "lambda":…, "hdh_base":…, "cdh_base":…, "tz_base":…,
              "holiday_country":"…", "n_train":…}}}.
Returns `nothing` if the pack file is absent (the caller then keeps INELIGIBLE).
"""
function load_load_models(path::AbstractString=default_load_models_path())
    isfile(path) || return nothing
    return JSON.parse(read(path, String))
end

"True if `e` is an open-meteo HTTP 429 (Too Many Requests) rate-limit response."
function _load_openmeteo_is_rate_limited(e)
    e isa Downloads.RequestError || return false
    resp = getfield(e, :response)
    return resp !== nothing && hasproperty(resp, :status) && resp.status == 429
end

function _load_openmeteo_get(url::String)
    last_err = nothing
    for attempt in 1:LOAD_OPENMETEO_RETRIES
        try
            buf = IOBuffer()
            Downloads.download(url, buf;
                headers=["User-Agent" => LOAD_OPENMETEO_USER_AGENT], timeout=120)
            return String(take!(buf))
        catch e
            last_err = e
            attempt == LOAD_OPENMETEO_RETRIES && break
            # 429 → fixed cooldown spanning the rate window; else exponential.
            # Jitter de-syncs concurrent per-zone fetches (see weather_res.jl).
            rl = _load_openmeteo_is_rate_limited(e)
            wait_s = (rl ? LOAD_OPENMETEO_RL_COOLDOWN_S : 2.0^attempt) * (0.75 + 0.5 * rand())
            sleep(wait_s)
        end
    end
    error("open-meteo request failed after $LOAD_OPENMETEO_RETRIES attempts: $last_err")
end

_isnull(x) = x === nothing || x === missing
function _avg_hourly_var(hourly::AbstractDict, var::String)
    keys_ = [k for k in keys(hourly)
             if k != "time" && (k == var || startswith(String(k), var * "_"))]
    isempty(keys_) && return Union{Nothing,Float64}[]
    n = maximum(length(hourly[k]) for k in keys_)
    out = Vector{Union{Nothing,Float64}}(nothing, n)
    for i in 1:n
        acc = 0.0; cnt = 0
        for k in keys_
            arr = hourly[k]
            i <= length(arr) || continue
            _isnull(arr[i]) && continue
            acc += Float64(arr[i]); cnt += 1
        end
        cnt > 0 && (out[i] = acc / cnt)
    end
    return out
end

"""
    parse_load_weather_response(body, cells) -> cell → hour → (T °C, GHI W/m²)

Parse one open-meteo response for `cells` (the (lat,lon) tuples of this batch in
request order). Multi-location → JSON array; single → one object. Multi-model
(`models=a,b`) arrays are element-wise averaged (nulls ignored). Hours where
either variable is null across all models are dropped.
"""
function parse_load_weather_response(body::AbstractString,
                                     cells::Vector{Tuple{Float64,Float64}})
    parsed = JSON.parse(String(body))
    locs = parsed isa AbstractVector ? parsed : [parsed]
    length(locs) == length(cells) ||
        error("open-meteo returned $(length(locs)) locations for $(length(cells)) cells")
    out = Dict{Tuple{Float64,Float64},Dict{DateTime,Tuple{Float64,Float64}}}()
    for (cell, loc) in zip(cells, locs)
        hourly = loc["hourly"]
        times = [DateTime(String(t), dateformat"yyyy-mm-ddTHH:MM") for t in hourly["time"]]
        temp = _avg_hourly_var(hourly, "temperature_2m")
        ghi = _avg_hourly_var(hourly, "shortwave_radiation")
        d = Dict{DateTime,Tuple{Float64,Float64}}()
        for (i, t) in enumerate(times)
            tv = i <= length(temp) ? temp[i] : nothing
            gv = i <= length(ghi) ? ghi[i] : nothing
            (tv === nothing || gv === nothing) && continue
            d[t] = (tv, gv)
        end
        out[cell] = d
    end
    return out
end

# Mirror of weather_res.jl's openmeteo_vintage_lag, defined only when this file
# is used standalone (daily_forecast.jl includes weather_res.jl first, whose
# definition then wins — the two must stay identical).
if !@isdefined(openmeteo_vintage_lag)
    function openmeteo_vintage_lag(market_day::Date; asof::Date=Date(now(UTC)))
        lag = Dates.value(asof - (market_day - Day(1)))
        lag <= 0 && return 0
        lag <= 7 && return lag
        error("openmeteo_vintage_lag: market day $market_day needs the vintage issued " *
              "$(market_day - Day(1)), $lag days before $asof — beyond the previous-runs " *
              "API's 7-day history; the D-1 vintage is not reconstructable")
    end
end

"""
    fetch_load_weather(cells, dates; archive=false, vintage_lag=0, ...) -> cell → hour → (T, GHI)

Fetch hourly (temperature_2m °C, shortwave_radiation W/m²) for `cells` covering
`dates` (UTC calendar days) from open-meteo. `archive=true` uses the ERA5
archive API (fit time); default uses the forecast API (predict time). Locations
batched ≤$(LOAD_OPENMETEO_BATCH)/call; `models=` from EUPHEMIA_OPENMETEO_MODELS.

`vintage_lag` (from `openmeteo_vintage_lag`) enforces the D-1-vintage
discipline on the forecast path exactly as in `fetch_weather`: `1..7` requests
`_previous_dayN`-suffixed variables from the previous-runs API (the run issued
N days ago); the prefix-matching parser is unchanged. Incompatible with
`archive=true` (the archive is actuals, not a forecast vintage).
"""
function fetch_load_weather(cells::Vector{Tuple{Float64,Float64}}, dates::Vector{Date};
                            archive::Bool=false,
                            vintage_lag::Int=0,
                            models::String=get(ENV, "EUPHEMIA_OPENMETEO_MODELS", "gfs_seamless"),
                            base_url::String="")
    0 <= vintage_lag <= 7 ||
        error("fetch_load_weather: vintage_lag must be 0..7 (got $vintage_lag)")
    archive && vintage_lag > 0 &&
        error("fetch_load_weather: vintage_lag is a forecast-vintage control — meaningless with archive=true")
    isempty(cells) && return Dict{Tuple{Float64,Float64},Dict{DateTime,Tuple{Float64,Float64}}}()
    isempty(dates) && error("fetch_load_weather: empty date list")
    d0, d1 = extrema(dates)
    url_base = !isempty(base_url) ? base_url :
        (archive ? get(ENV, "EUPHEMIA_OPENMETEO_ARCHIVE_URL", OPENMETEO_ARCHIVE_URL_DEFAULT) :
         vintage_lag > 0 ? get(ENV, "EUPHEMIA_OPENMETEO_PREVRUNS_URL", LOAD_OPENMETEO_PREVRUNS_URL_DEFAULT) :
                   get(ENV, "EUPHEMIA_OPENMETEO_URL", OPENMETEO_FORECAST_URL_DEFAULT))
    sfx = vintage_lag > 0 ? "_previous_day$(vintage_lag)" : ""
    out = Dict{Tuple{Float64,Float64},Dict{DateTime,Tuple{Float64,Float64}}}()
    for lo in 1:LOAD_OPENMETEO_BATCH:length(cells)
        batch = cells[lo:min(lo + LOAD_OPENMETEO_BATCH - 1, length(cells))]
        lats = join((string(c[1]) for c in batch), ",")
        lons = join((string(c[2]) for c in batch), ",")
        url = url_base * "?latitude=" * lats * "&longitude=" * lons *
              "&hourly=temperature_2m" * sfx * ",shortwave_radiation" * sfx *
              "&start_date=" * Dates.format(d0, "yyyy-mm-dd") *
              "&end_date=" * Dates.format(d1, "yyyy-mm-dd") * "&timezone=UTC"
        archive || (url *= "&models=" * models)
        body = _load_openmeteo_get(url)
        merge!(out, parse_load_weather_response(body, batch))
    end
    return out
end

# ---------------------------------------------------------------------------
# Predict.
# ---------------------------------------------------------------------------
"""
    zone_mean_series(zm, weather) -> Dict{DateTime,Tuple{Float64,Float64}}

Population-weighted zone-mean (T, GHI) per hour from per-cell `weather`
(cell → hour → (T, GHI)) and the pack zone's weighted cities. Hours missing at
any weighted city are dropped (partial coverage would bias the weighted mean).
"""
function zone_mean_series(zm, weather)
    cities = zm["cities"]
    cells = [(Float64(c[1]), Float64(c[2])) for c in cities]
    weights = [Float64(c[3]) for c in cities]
    common = nothing
    for cell in cells
        cw = get(weather, cell, nothing)
        cw === nothing && return Dict{DateTime,Tuple{Float64,Float64}}()
        hs = Set(keys(cw))
        common = common === nothing ? hs : intersect(common, hs)
    end
    common === nothing && return Dict{DateTime,Tuple{Float64,Float64}}()
    out = Dict{DateTime,Tuple{Float64,Float64}}()
    wsum = sum(weights)
    for h in common
        t = 0.0; g = 0.0
        for (i, cell) in enumerate(cells)
            v = weather[cell][h]
            t += weights[i] * v[1]; g += weights[i] * v[2]
        end
        out[h] = (t / wsum, g / wsum)
    end
    return out
end

"Trailing 48h mean of the zone-mean temperature at `h` (min 12h present, else nothing)."
function trailing_ma_temp(series::Dict{DateTime,Tuple{Float64,Float64}}, h::DateTime)
    s = 0.0; n = 0
    for k in 1:48
        v = get(series, h - Hour(k), nothing)
        v === nothing && continue
        s += v[1]; n += 1
    end
    return n >= 12 ? s / n : nothing
end

"""
    predict_load(pack, zone, hours, weather) -> Dict{DateTime,Float64}

Per-hour load MW for `zone` from the model pack and fetched `weather`
(cell → hour → (T, GHI)). Hours whose trailing-48h temperature window is
unavailable (need ≥12 of the prior 48h) are skipped. Returns an empty dict if
the zone is absent from the pack (the caller must then keep the day INELIGIBLE).
"""
function predict_load(pack, zone::String, hours::Vector{DateTime}, weather)
    zm = get(pack["zones"], zone, nothing)
    zm === nothing && return Dict{DateTime,Float64}()
    series = zone_mean_series(zm, weather)
    isempty(series) && return Dict{DateTime,Float64}()
    tz_base = Int(zm["tz_base"])
    country = String(zm["holiday_country"])
    trend_origin = Date(String(get(pack, "trend_origin", "2022-07-01")))
    hdh = Float64(get(zm, "hdh_base", HDH_BASE_DEFAULT))
    cdh = Float64(get(zm, "cdh_base", CDH_BASE_DEFAULT))
    yrs = [year(local_time_load(tz_base, h)) for h in hours]
    hol = holidays_for_country(country, minimum(yrs)-1:maximum(yrs)+1)
    coef = Float64.(zm["coef"]); mu_x = Float64.(zm["mu_x"])
    sd_x = Float64.(zm["sd_x"]); mu_y = Float64(zm["mu_y"])
    out = Dict{DateTime,Float64}()
    for h in hours
        v = get(series, h, nothing)
        v === nothing && continue
        ma = trailing_ma_temp(series, h)
        ma === nothing && continue
        x = reshape(load_feature_vector(h, v[1], v[2], ma, tz_base, hol, trend_origin;
                                        hdh_base=hdh, cdh_base=cdh), 1, :)
        out[h] = max(ridge_predict_load(coef, mu_x, sd_x, mu_y, x)[1], 0.0)
    end
    return out
end

# ---------------------------------------------------------------------------
# Guarded smoke test.
# ---------------------------------------------------------------------------
if abspath(PROGRAM_FILE) == @__FILE__
    zone = length(ARGS) >= 1 ? ARGS[1] : "GR"
    day = length(ARGS) >= 2 ? Date(ARGS[2]) : Dates.today() + Day(1)
    println("weather_load smoke: zone=$zone day=$day (UTC hours)")
    pack = load_load_models()
    pack === nothing && error("no load pack at $(default_load_models_path()) — run bin/fit_load_models.jl")
    zm = pack["zones"][zone]
    cells = [(Float64(c[1]), Float64(c[2])) for c in zm["cities"]]
    println("  $(length(cells)) cities; country=$(zm["holiday_country"]) tz_base=$(zm["tz_base"])")
    weather = fetch_load_weather(cells, [day - Day(1), day];   # -1 day for trailing MA
                                 vintage_lag=openmeteo_vintage_lag(day))
    hours = collect(DateTime(day):Hour(1):DateTime(day) + Hour(23))
    pred = predict_load(pack, zone, hours, weather)
    for t in hours
        mw = get(pred, t, nothing)
        println("  ", Dates.format(t, "yyyy-mm-dd HH:MM"), "  ",
                mw === nothing ? "(no weather)" : string(round(mw, digits=0)), " MW")
    end
end
