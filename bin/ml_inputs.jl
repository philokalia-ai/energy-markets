# ML INPUT MODELS — pure-Julia serve-time port of the input-upgrade LightGBM
# stack (docs/experiments/input-upgrade, PR #252). Keeps the daily Julia
# workflow dependency-free: a ~self-contained GBDT evaluator reads the committed
# LightGBM text dumps in bin/input_models/*.txt, and the feature construction
# replicates docs/experiments/input-upgrade/features.py + predict_inputs.py
# EXACTLY as the models were trained. Wired into bin/daily_forecast.jl's weather
# track behind EUPHEMIA_ML_INPUTS: for the 5 pilot zones the per-zone-winner ML
# predictions REPLACE the linear-pack (weather_res.jl / weather_load.jl)
# predictions; the other 34 zones keep the packs.
#
# ── TRAIN/SERVE CONSISTENCY (critical correctness rule) ────────────────────────
# The feature port replicates features.py AS TRAINED, INCLUDING its known
# imperfections. Do NOT "fix" a feature here — the models learned on the trained
# feature, so a serve-time fix would introduce train/serve skew. Fixes happen at
# the next RETRAIN, never in this port. The specific carried-over imperfections:
#   • GR (Orthodox) holidays use the WESTERN Gregorian Easter as an approximation
#     (features.py `holidays()` derives GR's movable feasts from the Gregorian
#     `easter()`, NOT the Orthodox computus that weather_load.jl uses). `ml_holidays`
#     below deliberately mirrors that — it is NOT `holidays_for_country`.
#   • Only GR/ES/DE/SE carry a fixed-holiday map in features.py; every other
#     country (incl. NL) gets an EMPTY holiday set → `is_hol` ≡ 0 there. Mirrored.
#   • Degree-hour bases are the hard-coded 21.0 / 16.5 °C from features.py, not the
#     per-zone pack bases.
#   • `is_hol` keys on the UTC calendar date of the hour (features.py normalizes the
#     UTC timestamp), not local date.
# The GFS weather is fetched at the D-1 vintage via the SAME machinery as
# weather_res.jl/weather_load.jl (openmeteo_vintage_lag, batched previous-runs
# fetch); cap95 and AR lags come from the store with strictly ex-ante windows.
#
# This file is include-d by bin/daily_forecast.jl AFTER weather_res.jl and
# weather_load.jl, so it reuses their in-scope helpers (openmeteo_vintage_lag,
# _openmeteo_get, easter_gregorian, predict_solar_hour, predict_wind_hour,
# wind_feature_vector, load_res_models, fetch_load_weather). Pure functions are
# unit/equivalence-tested (test/scripts/ml_inputs_equivalence.jl, DB-free
# test/test_ml_inputs.jl).

using Dates, Statistics, JSON

const ML_MODELS_DIR = joinpath(@__DIR__, "input_models")
const ML_S0 = 1361.0                       # solar constant proxy (features.py S0)
const ML_ZERO_THRESHOLD = 1e-35            # LightGBM kZeroThreshold
const ML_PILOT_ZONES = ["GR", "ES", "DE_LU", "SE2", "NL"]

# Per-zone-winner ship config (#252 scorecard, task directive): which of {NEW ML,
# committed pack} supplies each (zone, target). NEW load on all 5; NEW solar on
# all but ES (its pack ridge is already near-perfect); NEW wind only on the
# offshore-heavy NL (the physical power curve wins the onshore zones). A zone/
# target absent here (or a non-pilot zone) keeps the pack. Read at call time.
const ML_USE_NEW = Dict{Tuple{String,Symbol},Bool}(
    ("GR", :load) => true,  ("GR", :solar) => true,  ("GR", :wind) => false,
    ("ES", :load) => true,  ("ES", :solar) => false, ("ES", :wind) => false,
    ("DE_LU", :load) => true, ("DE_LU", :solar) => true, ("DE_LU", :wind) => false,
    ("SE2", :load) => true, ("SE2", :solar) => true,  ("SE2", :wind) => false,
    ("NL", :load) => true,  ("NL", :solar) => true,   ("NL", :wind) => true,
)

# ---------------------------------------------------------------------------
# LightGBM text-dump parser + GBDT evaluator (numerical splits only; the pipeline
# trained num_cat=0). Prediction = Σ over trees of the reached leaf value — the
# boost-from-average constant is folded into tree 0 and the learning rate is
# already baked into every stored leaf, exactly as LightGBM's own predictor sums.
# ---------------------------------------------------------------------------

"One decision tree from a LightGBM dump. Internal-node arrays are length
num_leaves-1; leaf_value is length num_leaves. A child index ≥0 is an internal
node; <0 encodes leaf `-child-1`."
struct LGBTree
    split_feature::Vector{Int}
    threshold::Vector{Float64}
    decision_type::Vector{Int}
    left_child::Vector{Int}
    right_child::Vector{Int}
    leaf_value::Vector{Float64}
end

"A parsed LightGBM booster: its trees and the trained feature-name order."
struct LGBModel
    trees::Vector{LGBTree}
    feature_names::Vector{String}
end

_lgb_floats(line::AbstractString) = [parse(Float64, t) for t in split(strip(line))]
_lgb_ints(line::AbstractString) = [parse(Int, t) for t in split(strip(line))]

"Value after `key=` on the first matching line in `block` (whitespace-trimmed)."
function _lgb_field(block::AbstractString, key::AbstractString)
    for ln in split(block, '\n')
        startswith(ln, key * "=") && return strip(ln[length(key)+2:end])
    end
    error("LightGBM dump: field '$key' not found in tree block")
end

"""
    parse_lgb_model(path) -> LGBModel

Parse a LightGBM text model dump. Asserts num_cat=0 on every tree (the input
pipeline is purely numerical; a categorical split would need dedicated routing).
"""
function parse_lgb_model(path::AbstractString)
    text = read(path, String)
    # Split into the header and each "Tree=N ... " block on the Tree= markers.
    parts = split(text, r"(?m)^Tree=\d+$")     # parts[1] = header, parts[2:] = tree bodies
    length(parts) >= 2 || error("LightGBM dump $path has no Tree= blocks")
    feature_names = String.(split(_lgb_field(parts[1], "feature_names")))
    trees = LGBTree[]
    for blk in parts[2:end]
        occursin("num_leaves", blk) || continue
        num_cat = parse(Int, _lgb_field(blk, "num_cat"))
        num_cat == 0 || error("LightGBM dump $path: num_cat=$num_cat (categorical splits unsupported)")
        push!(trees, LGBTree(
            _lgb_ints(_lgb_field(blk, "split_feature")),
            _lgb_floats(_lgb_field(blk, "threshold")),
            _lgb_ints(_lgb_field(blk, "decision_type")),
            _lgb_ints(_lgb_field(blk, "left_child")),
            _lgb_ints(_lgb_field(blk, "right_child")),
            _lgb_floats(_lgb_field(blk, "leaf_value")),
        ))
    end
    isempty(trees) && error("LightGBM dump $path parsed zero trees")
    return LGBModel(trees, feature_names)
end

"""
    lgb_node_decision(fval, decision_type, threshold, left, right) -> Int

LightGBM's NumericalDecision, ported bit-for-bit. `decision_type` bits: bit0
categorical (unused here), bit1 default-left, bits2-3 missing-type (0 none / 1
zero / 2 NaN). Returns the chosen child index.
"""
@inline function lgb_node_decision(fval::Float64, dt::Int, thr::Float64, left::Int, right::Int)
    missing_type = (dt >> 2) & 0x03
    default_left = (dt & 0x02) != 0
    if isnan(fval) && missing_type != 2
        fval = 0.0
    end
    is_zero = (fval > -ML_ZERO_THRESHOLD) & (fval <= ML_ZERO_THRESHOLD)
    if (missing_type == 1 && is_zero) || (missing_type == 2 && isnan(fval))
        return default_left ? left : right
    end
    return fval <= thr ? left : right
end

"Raw prediction of one tree for feature vector `x` (1-based; split_feature is 0-based)."
function lgb_tree_predict(t::LGBTree, x::AbstractVector{Float64})
    node = 0
    while node >= 0
        fval = x[t.split_feature[node+1] + 1]
        node = lgb_node_decision(fval, t.decision_type[node+1], t.threshold[node+1],
                                 t.left_child[node+1], t.right_child[node+1])
    end
    return t.leaf_value[-node]         # leaf index = -child-1 → +1 (1-based) = -child
end

"Booster prediction: Σ tree outputs. `x` in the model's feature_names order."
lgb_predict(m::LGBModel, x::AbstractVector{Float64}) =
    sum(lgb_tree_predict(t, x) for t in m.trees)

# ---------------------------------------------------------------------------
# Feature construction — replicates features.py / baseline.add_cal EXACTLY.
# ---------------------------------------------------------------------------

"features.py `sinel(hod, doy, lat0, lon0)` (array form): clamped sine of solar
elevation. `doy`/`hod` are floats (day-of-year, hour-of-day UTC)."
function ml_sinel(hod::Float64, doy::Float64, lat0::Float64, lon0::Float64)
    dec = 0.409 * sin(2π * (doy + 284) / 365.0)
    H = (hod + lon0 / 15.0 - 12.0) * 15 * π / 180.0
    return max(sind(lat0) * sin(dec) + cosd(lat0) * cos(dec) * cos(H), 0.0)
end

"""
    ml_holidays(country, years) -> Set{Date}

EXACT port of features.py `holidays()` — see the TRAIN/SERVE CONSISTENCY note at
the top. GR's movable feasts derive from the WESTERN Gregorian Easter (the
Orthodox approximation the models were trained on); only GR/ES/DE/SE carry a
fixed map, every other country returns an empty set. Do NOT substitute the
correct Orthodox computus (`holidays_for_country`) here.
"""
function ml_holidays(country::AbstractString, years)
    hs = Set{Date}()
    for y in years
        E = easter_gregorian(y)                    # WESTERN Easter, deliberately (approx)
        fixed(mds...) = foreach(md -> push!(hs, Date(y, md[1], md[2])), mds)
        eastr(offsets...) = foreach(o -> push!(hs, E + Day(o)), offsets)
        if country == "GR"
            fixed((1,1),(1,6),(3,25),(5,1),(8,15),(10,28),(12,25),(12,26)); eastr(-48,-2,0,1,50)
        elseif country == "ES"
            fixed((1,1),(1,6),(5,1),(8,15),(10,12),(11,1),(12,6),(12,8),(12,25)); eastr(-2,0)
        elseif country == "DE"
            fixed((1,1),(5,1),(10,3),(12,25),(12,26)); eastr(-2,1,39,50)
        elseif country == "SE"
            fixed((1,1),(1,6),(5,1),(6,6),(12,25),(12,26)); eastr(-2,0,1,39,49)
        end
    end
    return hs
end

"Calendar features shared by RES and load (features.py add_cal). Returns a NamedTuple."
function ml_calendar(h::DateTime, lat0::Float64, lon0::Float64)
    doy = Float64(dayofyear(h)); hod = Float64(hour(h)); dow = Float64(dayofweek(h) - 1)
    return (hod=hod, dow=dow, se=ml_sinel(hod, doy, lat0, lon0),
            doy_s=sin(2π * doy / 365.25), doy_c=cos(2π * doy / 365.25),
            doy_s2=sin(4π * doy / 365.25), doy_c2=cos(4π * doy / 365.25))
end

"RES feature dict for one hour (features.py names). `agg`=(ghi,cloud,pres,v100m)."
function ml_res_features(h::DateTime, lat0::Float64, lon0::Float64,
                         ghi::Float64, cloud::Float64, pres::Float64, v100m::Float64,
                         cap95_solar::Float64, cap95_wind::Float64)
    c = ml_calendar(h, lat0, lon0)
    clearness = clamp(ghi / max(ML_S0 * c.se, 1.0), 0.0, 1.3)
    return Dict{String,Float64}(
        "ghi" => ghi, "cloud" => cloud, "pres" => pres, "v100m" => v100m,
        "se" => c.se, "clearness" => clearness, "hod" => c.hod, "dow" => c.dow,
        "doy_s" => c.doy_s, "doy_c" => c.doy_c, "doy_s2" => c.doy_s2, "doy_c2" => c.doy_c2,
        "cap95_solar" => cap95_solar, "cap95_wind" => cap95_wind)
end

"Load feature dict for one hour (features.py names). Degree-hour bases hard-coded
21.0/16.5 °C as trained; `is_hol` from `ml_holidays` on the UTC date."
function ml_load_features(h::DateTime, lat0::Float64, lon0::Float64,
                          T::Float64, ghi::Float64, Tma::Float64,
                          ar1::Float64, ar7::Float64, is_hol::Float64)
    c = ml_calendar(h, lat0, lon0)
    cdh = max(T - 21.0, 0.0); hdh = max(16.5 - T, 0.0)
    return Dict{String,Float64}(
        "T" => T, "Tma" => Tma, "cdh" => cdh, "hdh" => hdh,
        "cdh2" => cdh^2 / 10, "hdh2" => hdh^2 / 10, "ghi" => ghi,
        "hod" => c.hod, "dow" => c.dow, "is_hol" => is_hol,
        "doy_s" => c.doy_s, "doy_c" => c.doy_c, "doy_s2" => c.doy_s2, "doy_c2" => c.doy_c2,
        "ar1" => ar1, "ar7" => ar7)
end

"Assemble the feature vector in a model's trained feature_names order from a name→value dict."
ml_feature_vector(m::LGBModel, feats::Dict{String,Float64}) =
    Float64[get(feats, n, NaN) for n in m.feature_names]

# ---------------------------------------------------------------------------
# Model bundle (parsed once per process).
# ---------------------------------------------------------------------------
struct MLModels
    solar::Dict{String,LGBModel}
    wind::Dict{String,LGBModel}
    load::Dict{String,LGBModel}
    meta::Dict{String,Any}
end

"Load the committed ML models + meta for the given zones from bin/input_models/."
function load_ml_models(zones::Vector{String}=ML_PILOT_ZONES; dir::AbstractString=ML_MODELS_DIR)
    meta = JSON.parsefile(joinpath(dir, "meta.json"))
    s = Dict{String,LGBModel}(); w = Dict{String,LGBModel}(); l = Dict{String,LGBModel}()
    for z in zones
        s[z] = parse_lgb_model(joinpath(dir, "$(z)_solar.txt"))
        w[z] = parse_lgb_model(joinpath(dir, "$(z)_wind.txt"))
        l[z] = parse_lgb_model(joinpath(dir, "$(z)_load.txt"))
    end
    return MLModels(s, w, l, meta)
end

"Geometry (cells / weighted cities / centroid) for a zone from bin/input_models/geom.json."
function ml_geom(dir::AbstractString=ML_MODELS_DIR)
    g = JSON.parsefile(joinpath(dir, "geom.json"))
    return g
end
ml_zone_centroid(g, z) = (mean(Float64(c[1]) for c in g[z]["cells"]),
                          mean(Float64(c[2]) for c in g[z]["cells"]))

# ---------------------------------------------------------------------------
# Post-processed single-model predictions (mirror predict_inputs.py).
# ---------------------------------------------------------------------------

"NEW solar MW for one hour: ratio-model × cap95 ref, floored at 0, night-clamped
(se≤1e-6 → 0). Returns NaN when a required feature (e.g. cap95) is NaN."
function ml_predict_solar(m::MLModels, z::String, feats::Dict{String,Float64})
    ref = m.meta["$(z)_solar"]["ref_col"]
    x = ml_feature_vector(m.solar[z], feats)
    p = lgb_predict(m.solar[z], x)
    ref === nothing || (p *= feats[ref])
    p = max(p, 0.0)
    return feats["se"] <= 1e-6 ? 0.0 : p
end

"NEW wind MW for one hour: ratio-model × cap95 ref, floored at 0."
function ml_predict_wind(m::MLModels, z::String, feats::Dict{String,Float64})
    ref = m.meta["$(z)_wind"]["ref_col"]
    x = ml_feature_vector(m.wind[z], feats)
    p = lgb_predict(m.wind[z], x)
    ref === nothing || (p *= feats[ref])
    return max(p, 0.0)
end

"NEW load MW for one hour: model output floored at 0."
ml_predict_load(m::MLModels, z::String, feats::Dict{String,Float64}) =
    max(lgb_predict(m.load[z], ml_feature_vector(m.load[z], feats)), 0.0)

# ---------------------------------------------------------------------------
# Store queries — cap95 capacity signal + AR load lags (strictly ex-ante).
# ---------------------------------------------------------------------------

"numpy-`percentile(...,95)` with the default linear interpolation, on a copy."
function _np_percentile95(v::Vector{Float64})
    isempty(v) && return NaN
    s = sort(v)
    n = length(s)
    n == 1 && return s[1]
    rank = 0.95 * (n - 1)
    lo = floor(Int, rank); frac = rank - lo
    return s[lo + 1] + frac * (s[lo + 2] - s[lo + 1])
end

"""
    ml_capacity_p95(zones, target_days) -> Dict{Tuple{String,Symbol},Dict{Date,Float64}}

cap95 (features.py `capacity_p95`): for target day D the 95th-percentile of the
per-type actual hourly generation over days D-3..D-32 (i.e. the trailing-30d
window that ends at D-2, then the extra shift-by-2 the training used). Solar uses
production_type='Solar'; wind pools 'Wind Onshore'+'Wind Offshore'. Ex-ante: the
latest day read is D-3. Queries `entsoe.aggregated_generation_per_type` with the
same hourly-avg aggregation as the training pull.
"""
function ml_capacity_p95(zones::Vector{String}, target_days::Vector{Date})
    d_lo = minimum(target_days) - Day(32)
    d_hi = maximum(target_days) - Day(3)
    df = Euphemia.sql2df_with_retry("""
        SELECT area_map_code AS zone, production_type AS pt,
               date_trunc('hour', date_time_utc) AS h,
               avg(actual_generation_output_mw) AS mw
        FROM entsoe.aggregated_generation_per_type
        WHERE area_map_code = ANY(\$1)
          AND (production_type = 'Solar' OR production_type LIKE 'Wind%')
          AND actual_generation_output_mw IS NOT NULL
          AND date_time_utc >= (\$2::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc <  ((\$3::date + 1)::timestamp AT TIME ZONE 'UTC')
        GROUP BY 1, 2, 3
    """, [zones, DateTime(d_lo), d_hi])
    # (zone, pt_key) → day → Vector of hourly mw values that day
    daily = Dict{Tuple{String,Symbol},Dict{Date,Vector{Float64}}}()
    for r in eachrow(df)
        z = String(r.zone)
        ptk = String(r.pt) == "Solar" ? :solar : :wind
        d = Date(r.h)
        push!(get!(get!(daily, (z, ptk), Dict{Date,Vector{Float64}}()), d, Float64[]),
              Float64(r.mw))
    end
    out = Dict{Tuple{String,Symbol},Dict{Date,Float64}}()
    for z in zones, ptk in (:solar, :wind)
        dd = get(daily, (z, ptk), Dict{Date,Vector{Float64}}())
        m = Dict{Date,Float64}()
        for D in target_days
            win = Float64[]
            for k in 3:32
                vals = get(dd, D - Day(k), nothing)
                vals === nothing || append!(win, vals)
            end
            m[D] = isempty(win) ? NaN : _np_percentile95(win)
        end
        out[(z, ptk)] = m
    end
    return out
end

"""
    ml_ar_load_lags(zones, hours) -> Dict{String,Dict{DateTime,Float64}}

Hourly-mean day-ahead load forecast series per zone over `[min(hours)-7d, max(hours)]`
(the ar1/ar7 source). ar1 for hour t = series[t-1d], ar7 = series[t-7d]; both
forecasts publish before the D-1 gate. Returns the raw series (the caller reads
the lags). Mirrors the training pull (`day_ahead_total_load_forecast`, BZN-family,
hourly avg of `total_load_mw`).
"""
function ml_ar_load_lags(zones::Vector{String}, hours::Vector{DateTime})
    t_lo = minimum(hours) - Day(7)
    t_hi = maximum(hours) + Hour(1)
    df = Euphemia.sql2df_with_retry("""
        SELECT area_map_code AS zone, date_trunc('hour', date_time_utc) AS h,
               avg(total_load_mw) AS load_da
        FROM entsoe.day_ahead_total_load_forecast
        WHERE area_map_code = ANY(\$1)
          AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
          AND total_load_mw IS NOT NULL
          AND date_time_utc >= (\$2::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc <  (\$3::timestamp AT TIME ZONE 'UTC')
        GROUP BY 1, 2
    """, [zones, t_lo, t_hi])
    out = Dict{String,Dict{DateTime,Float64}}(z => Dict{DateTime,Float64}() for z in zones)
    for r in eachrow(df)
        out[String(r.zone)][DateTime(r.h)] = Float64(r.load_da)
    end
    return out
end

# ---------------------------------------------------------------------------
# Weather aggregation (per-cell fetch → zone-hour features), matching features.py.
# ---------------------------------------------------------------------------

"""
    ml_res_agg(cells, weather) -> Dict{DateTime,NTuple{4,Float64}}

Zone-hour (ghi, cloud, pres, v100m) = simple mean over the cells PRESENT for that
variable at that hour (features.py res_weather groupby-mean ignores per-variable
NaNs). `weather`: cell → hour → (v100, ghi, cloud, pres).
"""
function ml_res_agg(cells::Vector{Tuple{Float64,Float64}},
                    weather::Dict{Tuple{Float64,Float64},Dict{DateTime,NTuple{4,Float64}}})
    # accumulate per hour: sums + counts for each of the 4 variables
    acc = Dict{DateTime,NTuple{8,Float64}}()   # (sv,cv,cnt over v100,ghi,cloud,pres)
    for cell in cells
        cw = get(weather, cell, nothing); cw === nothing && continue
        for (h, tup) in cw
            s = get(acc, h, (0.0,0.0,0.0,0.0, 0.0,0.0,0.0,0.0))
            v100, ghi, cloud, pres = tup
            acc[h] = (
                s[1] + (isnan(v100) ? 0.0 : v100), s[2] + (isnan(ghi) ? 0.0 : ghi),
                s[3] + (isnan(cloud) ? 0.0 : cloud), s[4] + (isnan(pres) ? 0.0 : pres),
                s[5] + (isnan(v100) ? 0.0 : 1.0), s[6] + (isnan(ghi) ? 0.0 : 1.0),
                s[7] + (isnan(cloud) ? 0.0 : 1.0), s[8] + (isnan(pres) ? 0.0 : 1.0))
        end
    end
    out = Dict{DateTime,NTuple{4,Float64}}()
    for (h, s) in acc
        out[h] = (s[2]/max(s[6],1), s[3]/max(s[7],1), s[4]/max(s[8],1), s[1]/max(s[5],1))
    end
    return out   # (ghi, cloud, pres, v100m)
end

"""
    ml_load_agg(cities, weather) -> Dict{DateTime,Tuple{Float64,Float64}}

Population-weighted zone-hour (T, GHI) over the cities present for each variable
(features.py load_weather weighted mean, per-variable NaN handling). `cities`:
vector of (lat, lon, weight); `weather`: cell → hour → (T, GHI).
"""
function ml_load_agg(cities::Vector{Tuple{Float64,Float64,Float64}},
                     weather::Dict{Tuple{Float64,Float64},Dict{DateTime,Tuple{Float64,Float64}}})
    acc = Dict{DateTime,NTuple{4,Float64}}()   # (wT, wwT, wG, wwG)
    for (lat, lon, w) in cities
        cw = get(weather, (lat, lon), nothing); cw === nothing && continue
        for (h, tup) in cw
            T, G = tup
            s = get(acc, h, (0.0,0.0,0.0,0.0))
            acc[h] = (s[1] + (isnan(T) ? 0.0 : w*T), s[2] + (isnan(T) ? 0.0 : w),
                      s[3] + (isnan(G) ? 0.0 : w*G), s[4] + (isnan(G) ? 0.0 : w))
        end
    end
    out = Dict{DateTime,Tuple{Float64,Float64}}()
    for (h, s) in acc
        out[h] = (s[2] > 0 ? s[1]/s[2] : NaN, s[4] > 0 ? s[3]/s[4] : NaN)
    end
    return out
end

"pandas `rolling(48,min_periods=1).mean()` of T at hour `h`, over the contiguous
hourly `Tseries` (current hour + up to 47 preceding present hours)."
function ml_trailing_ma48(Tseries::Dict{DateTime,Float64}, h::DateTime)
    s = 0.0; n = 0
    for k in 0:47
        v = get(Tseries, h - Hour(k), nothing)
        v === nothing && continue
        s += v; n += 1
    end
    return n > 0 ? s / n : NaN
end

# ---------------------------------------------------------------------------
# Production weather fetch: GFS previous_day1 vintages, 4 RES vars per cell.
# Reuses weather_res.jl's _openmeteo_get + openmeteo_vintage_lag (in scope).
# ---------------------------------------------------------------------------
const ML_RES_VARS = ["wind_speed_100m", "shortwave_radiation", "cloud_cover", "surface_pressure"]

"""
    fetch_ml_res_weather(cells, dates; vintage_lag, models) -> cell → hour → (v100,ghi,cloud,pres)

The 4-variable RES fetch the ML solar/wind models need (the baseline pack fetch
in weather_res.jl carries only 2). Batched ≤50/call, D-1 vintage via the
previous-runs API when `vintage_lag>0`, same retry/URL conventions.
"""
function fetch_ml_res_weather(cells::Vector{Tuple{Float64,Float64}}, dates::Vector{Date};
                              vintage_lag::Int=0,
                              models::String=get(ENV, "EUPHEMIA_OPENMETEO_MODELS", "gfs_seamless"))
    0 <= vintage_lag <= 7 || error("fetch_ml_res_weather: vintage_lag must be 0..7 (got $vintage_lag)")
    isempty(cells) && return Dict{Tuple{Float64,Float64},Dict{DateTime,NTuple{4,Float64}}}()
    url_base = vintage_lag > 0 ?
        get(ENV, "EUPHEMIA_OPENMETEO_PREVRUNS_URL", OPENMETEO_PREVRUNS_URL_DEFAULT) :
        get(ENV, "EUPHEMIA_OPENMETEO_URL", OPENMETEO_URL_DEFAULT)
    sfx = vintage_lag > 0 ? "_previous_day$(vintage_lag)" : ""
    hourly = join((v * sfx for v in ML_RES_VARS), ",")
    d0, d1 = extrema(dates)
    out = Dict{Tuple{Float64,Float64},Dict{DateTime,NTuple{4,Float64}}}()
    for lo in 1:OPENMETEO_BATCH:length(cells)
        batch = cells[lo:min(lo + OPENMETEO_BATCH - 1, length(cells))]
        lats = join((string(c[1]) for c in batch), ",")
        lons = join((string(c[2]) for c in batch), ",")
        url = url_base * "?latitude=" * lats * "&longitude=" * lons *
              "&hourly=" * hourly * "&models=" * models *
              "&start_date=" * Dates.format(d0, "yyyy-mm-dd") *
              "&end_date=" * Dates.format(d1, "yyyy-mm-dd") * "&timezone=UTC"
        body = _openmeteo_get(url)
        parsed = JSON.parse(body)
        locs = parsed isa AbstractVector ? parsed : [parsed]
        length(locs) == length(batch) ||
            error("open-meteo returned $(length(locs)) locations for $(length(batch)) cells")
        for (cell, loc) in zip(batch, locs)
            hb = loc["hourly"]
            times = [DateTime(String(t), dateformat"yyyy-mm-ddTHH:MM") for t in hb["time"]]
            v = average_hourly(hb, ML_RES_VARS[1] * sfx)
            g = average_hourly(hb, ML_RES_VARS[2] * sfx)
            c = average_hourly(hb, ML_RES_VARS[3] * sfx)
            p = average_hourly(hb, ML_RES_VARS[4] * sfx)
            d = Dict{DateTime,NTuple{4,Float64}}()
            for (i, t) in enumerate(times)
                (i <= length(v) && v[i] !== nothing && i <= length(g) && g[i] !== nothing &&
                 i <= length(c) && c[i] !== nothing && i <= length(p) && p[i] !== nothing) || continue
                d[t] = (Float64(v[i]), Float64(g[i]), Float64(c[i]), Float64(p[i]))
            end
            out[cell] = d
        end
    end
    return out
end

# ---------------------------------------------------------------------------
# Top-level: per-zone ML RES (combined) + load predictions with the ship config.
# ---------------------------------------------------------------------------
"""
    build_ml_inputs(zones, first_utc, last_utc, candidates; asof) -> (res_preds, load_preds)

For each pilot `zone`, produce hourly combined-RES MW (solar + wind, each the
NEW model or the committed pack per `ML_USE_NEW`) and load MW (NEW model),
covering UTC `first_utc..last_utc`. The baseline components reuse the SAME pack
functions the weather track already uses (predict_solar_hour / predict_wind_hour
from weather_res.jl). Weather is fetched at the admissible D-1 vintage
(`vintage_groups`); cap95 + AR lags come from the store. These dicts overlay the
pilot zones in `preds`/`load_preds` before `weather_scenario`.
"""
function build_ml_inputs(zones::Vector{String}, first_utc::Date, last_utc::Date,
                         candidates::AbstractSet{Date}; asof::Date=Date(now(UTC)))
    models = load_ml_models(zones)
    geom = ml_geom()
    res_pack = load_res_models()
    groups = vintage_groups(first_utc, last_utc, candidates; asof)
    span_hours = collect(DateTime(first_utc):Hour(1):DateTime(last_utc) + Hour(23))
    target_days = collect(first_utc:Day(1):last_utc)
    cap = ml_capacity_p95(zones, target_days)
    ar = ml_ar_load_lags(zones, span_hours)
    throttle = parse(Float64, get(ENV, "EUPHEMIA_OPENMETEO_ZONE_THROTTLE", "0.6"))  # avoid 429

    res_preds = Dict{String,Dict{DateTime,Float64}}()
    load_preds = Dict{String,Dict{DateTime,Float64}}()
    for z in zones
        lat0, lon0 = ml_zone_centroid(geom, z)
        cells = [(Float64(c[1]), Float64(c[2])) for c in geom[z]["cells"]]
        cities = [(Float64(c[1]), Float64(c[2]), Float64(c[3])) for c in geom[z]["cities"]]
        zpack = get(res_pack["zones"], z, nothing)
        holset = ml_holidays(String(load_load_models()["zones"][z]["holiday_country"]),
                             2024:2027)
        rp = Dict{DateTime,Float64}(); lp = Dict{DateTime,Float64}()
        for (gdates, lag) in groups
            throttle > 0 && sleep(throttle)
            rweather = fetch_ml_res_weather(cells, gdates; vintage_lag=lag)
            # per-cell v100 dict for the baseline wind power curve
            wcells = Dict{Tuple{Float64,Float64},Dict{DateTime,Float64}}()
            for (cell, cw) in rweather
                wcells[cell] = Dict(h => tup[1] for (h, tup) in cw)
            end
            ragg = ml_res_agg(cells, rweather)
            # load weather covers 2 extra days back for the trailing-48h MA
            lweather = fetch_load_weather(cells_of_cities(cities),
                                          collect((first(gdates) - Day(2)):Day(1):last(gdates));
                                          vintage_lag=lag)
            lagg = ml_load_agg(cities, lweather)
            Tseries = Dict{DateTime,Float64}(h => v[1] for (h, v) in lagg)
            ghours = collect(DateTime(first(gdates)):Hour(1):DateTime(last(gdates)) + Hour(23))
            for h in ghours
                D = Date(h)
                # ── RES ──
                ra = get(ragg, h, nothing)
                if ra !== nothing
                    ghi, cloud, pres, v100m = ra
                    c95s = get(get(cap, (z, :solar), Dict{Date,Float64}()), D, NaN)
                    c95w = get(get(cap, (z, :wind), Dict{Date,Float64}()), D, NaN)
                    feats = ml_res_features(h, lat0, lon0, ghi, cloud, pres, v100m, c95s, c95w)
                    solar = ML_USE_NEW[(z, :solar)] ? ml_predict_solar(models, z, feats) :
                            (zpack !== nothing && haskey(zpack, "solar") ?
                             predict_solar_hour(zpack["solar"], ghi, h) : 0.0)
                    wind = if ML_USE_NEW[(z, :wind)]
                        ml_predict_wind(models, z, feats)
                    else
                        # baseline power curve needs per-cell v100 in pack order
                        vv = Float64[get(get(wcells, cell, Dict{DateTime,Float64}()), h, NaN)
                                     for cell in cells]
                        (zpack !== nothing && haskey(zpack, "wind") && !any(isnan, vv)) ?
                            predict_wind_hour(zpack["wind"], vv) : 0.0
                    end
                    v = (isnan(solar) ? 0.0 : solar) + (isnan(wind) ? 0.0 : wind)
                    rp[h] = v
                end
                # ── LOAD ──
                la = get(lagg, h, nothing)
                if la !== nothing && !isnan(la[1])
                    T, ghiL = la
                    Tma = ml_trailing_ma48(Tseries, h)
                    isnan(Tma) && continue
                    ar1 = get(get(ar, z, Dict{DateTime,Float64}()), h - Day(1), NaN)
                    ar7 = get(get(ar, z, Dict{DateTime,Float64}()), h - Day(7), NaN)
                    # Only overlay load where the NEW model is the winner; a
                    # pack-load pilot is left out of load_preds entirely so the
                    # caller keeps its committed-pack fill (never clobbered empty).
                    if ML_USE_NEW[(z, :load)]
                        is_hol = (Date(h) in holset) ? 1.0 : 0.0
                        lf = ml_load_features(h, lat0, lon0, T, ghiL, Tma, ar1, ar7, is_hol)
                        lp[h] = ml_predict_load(models, z, lf)
                    end
                end
            end
        end
        res_preds[z] = rp
        ML_USE_NEW[(z, :load)] && (load_preds[z] = lp)   # pack-load pilots keep their fill
    end
    return res_preds, load_preds
end

"City (lat,lon) tuples from (lat,lon,weight) triples (for the load-weather fetch)."
cells_of_cities(cities::Vector{Tuple{Float64,Float64,Float64}}) =
    [(c[1], c[2]) for c in cities]

# ---------------------------------------------------------------------------
# Guarded smoke test (needs network + store): predict one pilot zone for a day.
# ---------------------------------------------------------------------------
if abspath(PROGRAM_FILE) == @__FILE__
    using Euphemia
    include(joinpath(@__DIR__, "weather_res.jl"))
    include(joinpath(@__DIR__, "weather_load.jl"))
    include(joinpath(@__DIR__, "forecast_common.jl"))
    zone = length(ARGS) >= 1 ? ARGS[1] : "GR"
    day = length(ARGS) >= 2 ? Date(ARGS[2]) : Dates.today() + Day(1)
    println("ml_inputs smoke: zone=$zone day=$day")
    res, load = build_ml_inputs([zone], day, day, Set([day]); asof=Date(now(UTC)))
    for h in DateTime(day):Hour(1):DateTime(day)+Hour(23)
        println("  ", Dates.format(h, "yyyy-mm-dd HH:MM"),
                "  RES=", round(get(res[zone], h, NaN), digits=1),
                "  LOAD=", round(get(load[zone], h, NaN), digits=1))
    end
end
