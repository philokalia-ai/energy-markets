# D-n load-model experiment: fit per-zone ridge load models on calendar +
# temperature features and evaluate at leads 1..7 against weekly persistence
# and the ENTSO-E D-1 forecast. See docs/experiments/dn-load-model/README.md.
#
# Inputs (CSV in $DN_OUT, produced by test/scripts/dn_load_fetch.py + the psql
# extracts documented in the README):
#   cities.csv          zone,city,lat,lon,weight
#   era5_cities.csv     city_key,h,temperature_2m,shortwave_radiation
#   prev_cities.csv     city_key,h,t2m_prev_day1..7,ghi_prev_day1..7
#   actual_load.csv     z,h,load_mw          (hourly, deduped, 2022-06-24..2026-06-30)
#   da_load_forecast.csv z,h,load_mw         (ENTSO-E D-1, test year)
#
# Outputs:
#   $DN_OUT/load_metrics.csv                 zone × lead × benchmark metrics
#   $DN_OUT/gr_load_pred.csv                 GR hourly predictions per lead (price test input)
#   docs/experiments/dn-load-model/load_models_proto.json  (fitted pack, if WRITE_PACK=true)
#
# Train: 2022-07-01 .. 2025-06-30 (ERA5 temperature — actuals; stated honestly:
# production would train on the same actuals, so no vintage issue in FIT).
# Test:  2025-07-01 .. 2026-06-30 with HONEST lead-n GFS vintages (previous-runs).

using CSV, DataFrames, Dates, Statistics, LinearAlgebra, Printf, JSON

const SP = get(ENV, "DN_OUT",
    "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/dn")
const ZONES = ["GR", "DE_LU", "FR", "ES", "PL", "SE3"]
const TRAIN0 = DateTime(2022, 7, 1)
const TRAIN1 = DateTime(2025, 6, 30, 23)
const VAL0 = DateTime(2025, 1, 1)              # validation slice (λ selection)
const TEST0 = DateTime(2025, 7, 1)
const TEST1 = DateTime(2026, 6, 30, 23)
const WRITE_PACK = lowercase(get(ENV, "WRITE_PACK", "false")) == "true"

# ---------------------------------------------------------------------------
# Calendar: EU DST rule + per-zone local time and public holidays
# ---------------------------------------------------------------------------
last_sunday(y, m) = (d = Date(y, m, daysinmonth(Date(y, m))); d - Day(dayofweek(d) % 7))
is_eu_summer(t::DateTime) =
    (DateTime(last_sunday(year(t), 3)) + Hour(1)) <= t < (DateTime(last_sunday(year(t), 10)) + Hour(1))
# zone → standard-time UTC offset (hours); all six zones follow the EU DST rule
const TZ_BASE = Dict("GR" => 2, "DE_LU" => 1, "FR" => 1, "ES" => 1, "PL" => 1, "SE3" => 1)
local_time(z, t::DateTime) = t + Hour(TZ_BASE[z] + (is_eu_summer(t) ? 1 : 0))

"Gregorian (Western) Easter Sunday."
function easter_gregorian(y::Int)
    a = y % 19; b = y ÷ 100; c = y % 100; d = b ÷ 4; e = b % 4
    f = (b + 8) ÷ 25; g = (b - f + 1) ÷ 3; h = (19a + b - d - g + 15) % 30
    i = c ÷ 4; k = c % 4; l = (32 + 2e + 2i - h - k) % 7; m = (a + 11h + 22l) ÷ 451
    mo = (h + l - 7m + 114) ÷ 31; da = ((h + l - 7m + 114) % 31) + 1
    return Date(y, mo, da)
end
"Orthodox Easter Sunday (Gregorian calendar date; +13d Julian→Gregorian, valid 1900–2099)."
function easter_orthodox(y::Int)
    a = y % 4; b = y % 7; c = y % 19
    d = (19c + 15) % 30; e = (2a + 4b - d + 34) % 7
    mo = (d + e + 114) ÷ 31; da = ((d + e + 114) % 31) + 1
    return Date(y, mo, da) + Day(13)
end
midsummer_eve(y::Int) = (d = Date(y, 6, 19); d + Day((5 - dayofweek(d) + 7) % 7))  # Friday in Jun 19–25

"Public holidays (national) for the zone's country, LOCAL calendar dates."
function holidays(zone::String, years)
    hs = Set{Date}()
    for y in years
        eg, eo = easter_gregorian(y), easter_orthodox(y)
        fixed(md...) = foreach(x -> push!(hs, Date(y, x[1], x[2])), md)
        if zone == "GR"
            fixed((1,1),(1,6),(3,25),(5,1),(8,15),(10,28),(12,25),(12,26))
            foreach(o -> push!(hs, eo + Day(o)), (-48, -2, 1, 50))
        elseif zone == "DE_LU"
            fixed((1,1),(5,1),(10,3),(12,24),(12,25),(12,26),(12,31))
            foreach(o -> push!(hs, eg + Day(o)), (-2, 1, 39, 50))
        elseif zone == "FR"
            fixed((1,1),(5,1),(5,8),(7,14),(8,15),(11,1),(11,11),(12,25))
            foreach(o -> push!(hs, eg + Day(o)), (1, 39, 50))
        elseif zone == "ES"
            fixed((1,1),(1,6),(5,1),(8,15),(10,12),(11,1),(12,6),(12,8),(12,25))
            foreach(o -> push!(hs, eg + Day(o)), (-2,))
        elseif zone == "PL"
            fixed((1,1),(1,6),(5,1),(5,3),(8,15),(11,1),(11,11),(12,25),(12,26))
            foreach(o -> push!(hs, eg + Day(o)), (1, 60))
        elseif zone == "SE3"
            fixed((1,1),(1,6),(5,1),(6,6),(12,24),(12,25),(12,26),(12,31))
            foreach(o -> push!(hs, eg + Day(o)), (-2, 1, 39))
            push!(hs, midsummer_eve(y))
        end
    end
    return hs
end

# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------
parse_h(s::DateTime) = s
parse_h(s) = DateTime(String(s), dateformat"yyyy-mm-ddTHH:MM")

function zone_weather_truth()
    cities = CSV.read(joinpath(SP, "cities.csv"), DataFrame)
    era5 = CSV.read(joinpath(SP, "era5_cities.csv"), DataFrame)
    wkey = Dict(string(r.zone, ":", r.city) => (String(r.zone), Float64(r.weight))
                for r in eachrow(cities))
    acc = Dict{String,Dict{DateTime,Tuple{Float64,Float64,Float64}}}()  # z → h → (Σw·T, Σw·G, Σw)
    for r in eachrow(era5)
        (ismissing(r.temperature_2m) || ismissing(r.shortwave_radiation)) && continue
        z, w = wkey[String(r.city_key)]
        h = parse_h(r.h)
        d = get!(acc, z, Dict{DateTime,Tuple{Float64,Float64,Float64}}())
        t0, g0, w0 = get(d, h, (0.0, 0.0, 0.0))
        d[h] = (t0 + w * r.temperature_2m, g0 + w * r.shortwave_radiation, w0 + w)
    end
    return Dict(z => Dict(h => (v[1] / v[3], v[2] / v[3]) for (h, v) in d)
                for (z, d) in acc)
end

function zone_weather_vintages()
    cities = CSV.read(joinpath(SP, "cities.csv"), DataFrame)
    prev = CSV.read(joinpath(SP, "prev_cities.csv"), DataFrame)
    wkey = Dict(string(r.zone, ":", r.city) => (String(r.zone), Float64(r.weight))
                for r in eachrow(cities))
    # (z, lead) → h → (T, GHI)   weighted over cities with data
    acc = Dict{Tuple{String,Int},Dict{DateTime,Tuple{Float64,Float64,Float64}}}()
    for r in eachrow(prev)
        z, w = wkey[String(r.city_key)]
        h = parse_h(r.h)
        for n in 1:7
            tv = r[Symbol("temperature_2m_previous_day$n")]
            gv = r[Symbol("shortwave_radiation_previous_day$n")]
            (ismissing(tv) || ismissing(gv)) && continue
            d = get!(acc, (z, n), Dict{DateTime,Tuple{Float64,Float64,Float64}}())
            t0, g0, w0 = get(d, h, (0.0, 0.0, 0.0))
            d[h] = (t0 + w * tv, g0 + w * gv, w0 + w)
        end
    end
    return Dict(k => Dict(h => (v[1] / v[3], v[2] / v[3]) for (h, v) in d)
                for (k, d) in acc)
end

function load_series(path)
    df = CSV.read(path, DataFrame)
    out = Dict{String,Dict{DateTime,Float64}}()
    for r in eachrow(df)
        ismissing(r.load_mw) && continue
        push!(get!(out, String(r.z), Dict{DateTime,Float64}()), parse_h(r.h) => Float64(r.load_mw))
    end
    return out
end

# ---------------------------------------------------------------------------
# Features
# ---------------------------------------------------------------------------
const HDH_BASE, CDH_BASE = 16.5, 21.0

"""
Feature vector for one hour. `T`, `G` = zone temperature (°C) / GHI (W/m²) at
that hour; `Tma` = trailing 48 h mean temperature (thermal inertia — from the
same source series, so lead-n evaluation stays lead-n-legal).
"""
function features(z::String, t_utc::DateTime, T::Float64, G::Float64,
                  Tma::Float64, hol::Set{Date})
    lt = local_time(z, t_utc)
    how = (dayofweek(lt) - 1) * 24 + hour(lt) + 1          # 1..168
    x = zeros(168 + 24 + 1 + 8 + 1 + 4 + 1)
    x[how] = 1.0
    is_hol = Date(lt) in hol
    o = 168
    is_hol && (x[o + hour(lt) + 1] = 1.0)                  # holiday × local hod
    o += 24
    x[o + 1] = is_hol ? 1.0 : 0.0
    o += 1
    hdh, cdh = max(HDH_BASE - T, 0.0), max(T - CDH_BASE, 0.0)
    hdhm, cdhm = max(HDH_BASE - Tma, 0.0), max(Tma - CDH_BASE, 0.0)
    x[o + 1] = hdh;        x[o + 2] = cdh
    x[o + 3] = hdh^2 / 10; x[o + 4] = cdh^2 / 10
    x[o + 5] = hdhm;       x[o + 6] = cdhm
    x[o + 7] = hdhm^2 / 10; x[o + 8] = cdhm^2 / 10
    o += 8
    x[o + 1] = G / 100                                     # behind-the-meter PV proxy
    o += 1
    doy = dayofyear(lt) / 365.25
    x[o + 1] = sin(2π * doy); x[o + 2] = cos(2π * doy)
    x[o + 3] = sin(4π * doy); x[o + 4] = cos(4π * doy)
    o += 4
    x[o + 1] = Dates.value(t_utc - TRAIN0) / (1000.0 * 3600 * 24 * 365.25)  # trend (years)
    return x
end
const NFEAT = 168 + 24 + 1 + 8 + 1 + 4 + 1

"Trailing 48h mean of the hour's own source series (min 12 h present)."
function trailing_ma(series::Dict{DateTime,Tuple{Float64,Float64}}, h::DateTime)
    s = 0.0; n = 0
    for k in 1:48
        v = get(series, h - Hour(k), nothing)
        v === nothing && continue
        s += v[1]; n += 1
    end
    return n >= 12 ? s / n : nothing
end

# ---------------------------------------------------------------------------
# Ridge fit (intercept unpenalized via centering)
# ---------------------------------------------------------------------------
function ridge_fit(X::Matrix{Float64}, y::Vector{Float64}, λ::Float64)
    μx = vec(mean(X, dims=1)); σx = vec(std(X, dims=1)); σx[σx .== 0] .= 1.0
    Xs = (X .- μx') ./ σx'
    μy = mean(y)
    β = (Xs' * Xs + λ * size(X, 1) * I) \ (Xs' * (y .- μy))
    return (β=β, μx=μx, σx=σx, μy=μy, λ=λ)
end
ridge_predict(m, X::Matrix{Float64}) = ((X .- m.μx') ./ m.σx') * m.β .+ m.μy

metrics(pred, act) = (n = length(act);
    (n=n, mae=mean(abs.(pred .- act)), mape=100 * mean(abs.(pred .- act) ./ act),
     corr=(n >= 3 && std(pred) > 0 && std(act) > 0) ? cor(pred, act) : NaN))

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function main()
    println("Loading data ...")
    truth = zone_weather_truth()
    vint = zone_weather_vintages()
    act = load_series(joinpath(SP, "actual_load.csv"))
    daf = load_series(joinpath(SP, "da_load_forecast.csv"))
    hol = Dict(z => holidays(z, 2022:2026) for z in ZONES)

    results = DataFrame(zone=String[], lead=Int[], bench=String[], n=Int[],
                        mae=Float64[], mape=Float64[], corr=Float64[])
    pack = Dict{String,Any}()
    gr_pred_rows = NamedTuple[]

    for z in ZONES
        haskey(truth, z) || (println("$z: no weather — skipped"); continue)
        wz = truth[z]
        az = act[z]
        # drop implausible load rows (ENTSO-E glitches: zeros / near-zeros)
        med = median(collect(values(az)))
        nbad = count(v -> v < 0.2 * med, values(az))
        nbad > 0 && println("$z: dropping $nbad hours with load < 20% of median ($((round(Int, med))) MW)")
        az = Dict(h => v for (h, v) in az if v >= 0.2 * med)
        # --- training matrix (ERA5 truth weather) ---
        hours = sort([h for h in keys(az)
                      if TRAIN0 <= h <= TRAIN1 && haskey(wz, h)])
        rows = Tuple{DateTime,Vector{Float64},Float64}[]
        for h in hours
            ma = trailing_ma(wz, h)
            ma === nothing && continue
            T, G = wz[h]
            push!(rows, (h, features(z, h, T, G, ma, hol[z]), az[h]))
        end
        Xall = permutedims(hcat([r[2] for r in rows]...))
        yall = [r[3] for r in rows]
        tr = [i for (i, r) in enumerate(rows) if r[1] < VAL0]
        va = [i for (i, r) in enumerate(rows) if r[1] >= VAL0]
        # λ selection on the validation slice, refit on the full train window
        best = (λ=NaN, mae=Inf)
        for λ in (1e-5, 1e-4, 1e-3, 1e-2, 1e-1)
            m = ridge_fit(Xall[tr, :], yall[tr], λ)
            mae = mean(abs.(ridge_predict(m, Xall[va, :]) .- yall[va]))
            mae < best.mae && (best = (λ=λ, mae=mae))
        end
        model = ridge_fit(Xall, yall, best.λ)
        @printf("%-6s trained on %d h (λ=%g, val MAE %.0f MW)\n", z, length(yall), best.λ, best.mae)
        pack[z] = Dict("coef" => model.β, "mu_x" => model.μx, "sd_x" => model.σx,
                       "mu_y" => model.μy, "lambda" => model.λ,
                       "hdh_base" => HDH_BASE, "cdh_base" => CDH_BASE,
                       "tz_base" => TZ_BASE[z],
                       "train" => string(TRAIN0, " .. ", TRAIN1))

        # --- evaluation on the test year ---
        test_hours = sort([h for h in keys(az) if TEST0 <= h <= TEST1])

        # (0) perfect-T upper bound (ERA5 actual weather)
        idx = [h for h in test_hours if haskey(wz, h) && trailing_ma(wz, h) !== nothing]
        Xp = permutedims(hcat([features(z, h, wz[h][1], wz[h][2],
                                        trailing_ma(wz, h), hol[z]) for h in idx]...))
        m0 = metrics(ridge_predict(model, Xp), [az[h] for h in idx])
        push!(results, (z, 0, "model_perfectT", m0.n, m0.mae, m0.mape, m0.corr))

        for n in 1:7
            vz = get(vint, (z, n), nothing)
            vz === nothing && continue
            idx = DateTime[]; feats = Vector{Float64}[]
            for h in test_hours
                haskey(vz, h) || continue
                ma = trailing_ma(vz, h)
                ma === nothing && continue
                push!(idx, h)
                push!(feats, features(z, h, vz[h][1], vz[h][2], ma, hol[z]))
            end
            isempty(idx) && continue
            pred = ridge_predict(model, permutedims(hcat(feats...)))
            m = metrics(pred, [az[h] for h in idx])
            push!(results, (z, n, "model_vintageT", m.n, m.mae, m.mape, m.corr))

            # weekly persistence at the same hours (T−7 legal for leads ≤6, else T−14)
            back = n <= 6 ? 7 : 14
            pidx = [i for (i, h) in enumerate(idx) if haskey(az, h - Day(back))]
            mp = metrics([az[idx[i] - Day(back)] for i in pidx], [az[idx[i]] for i in pidx])
            push!(results, (z, n, "persistence_w", mp.n, mp.mae, mp.mape, mp.corr))

            if z == "GR"
                for (i, h) in enumerate(idx)
                    push!(gr_pred_rows, (h=h, lead=n, load_mw=pred[i]))
                end
            end
        end

        # ENTSO-E D-1 benchmark (lead-1 quality ceiling)
        if haskey(daf, z)
            dz = daf[z]
            idx = [h for h in test_hours if haskey(dz, h)]
            m = metrics([dz[h] for h in idx], [az[h] for h in idx])
            push!(results, (z, 1, "entsoe_d1", m.n, m.mae, m.mape, m.corr))
        end
    end

    CSV.write(joinpath(SP, "load_metrics.csv"), results)
    gr = DataFrame(gr_pred_rows)
    CSV.write(joinpath(SP, "gr_load_pred.csv"), gr)
    if WRITE_PACK
        path = joinpath(@__DIR__, "..", "..", "docs", "experiments", "dn-load-model",
                        "load_models_proto.json")
        mkpath(dirname(path))
        open(path, "w") do io
            JSON.print(io, Dict("version" => "proto-1", "features" => "see test/scripts/dn_load_model.jl",
                                "zones" => pack))
        end
        println("pack written: $path")
    end

    # pretty print
    for z in ZONES
        sub = results[results.zone .== z, :]
        isempty(sub) && continue
        println("\n== $z ==")
        for r in eachrow(sort(sub, [:lead, :bench]))
            @printf("  lead %d  %-15s n=%5d  MAE %6.0f MW  MAPE %5.2f%%  corr %.4f\n",
                    r.lead, r.bench, r.n, r.mae, r.mape, r.corr)
        end
    end
end

main()
