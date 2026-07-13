#!/usr/bin/env julia
#
# Export the daily-forecast SPA data contract to web/data/ (invoked by
# .github/workflows/daily-forecast.yml after bin/score_forecasts.jl).
#
# Contract (consumed by a separately-built SPA — do not change shapes):
#
# web/data/scoreboard.json
#   {"generated_utc": ..., "code_version": 16, "market_day_tz": "Europe/Athens",
#    "zones": [...],
#    "scores": [{"zone","lead_days","window" ("all" or "YYYY-MM"),
#                "n_days","mae","bias","corr","input_mode"}, ...]}
#   — "input_mode" is 'entsoe' (reference track) or 'weather' (ex-ante track);
#   the SPA treats an absent input_mode as 'entsoe' (backward compatible).
#
# web/data/zones/<ZONE>.json
#   {"zone": ..., "market_day_tz": "Europe/Athens",
#    "days": [{"date","lead_days","prediction_made_utc",
#     "hours":[ISO8601...], "sim":[...], "actual":[... or null where
#     unrealized], "mae","bias","corr" (null when unrealized),
#     "input_mode"}, ...]}
#   — most recent 120 market days, newest first, one entry per
#   (date, lead_days, input_mode). "date" is the Europe/Athens market day;
#   "hours" are the window's UTC stamps (24 normally; 23/25 on DST days).
#
# web/data/map.json prefers input_mode='entsoe' rows for now (unchanged
# behavior; no input_mode field in its shape).
#
# web/data/ is git-ignored; CI uploads it as the `forecast-data` artifact.

using Euphemia, Dates, Statistics, DataFrames

include(joinpath(@__DIR__, "forecast_common.jl"))
# resolution-aware actuals (guarded __main__, safe to include)
include(joinpath(@__DIR__, "..", "test", "scripts", "eu_eval_metrics.jl"))

const CV = Euphemia.ENERGY_PRICES_CODE_VERSION
const OUT_DIR = joinpath(dirname(@__DIR__), "web", "data")
const MAX_DAYS = 120

nn(x) = (x === nothing || x === missing) ? nothing :
        (x isa AbstractFloat && !isfinite(x)) ? nothing : x

function export_scoreboard()
    scores = Euphemia.sql2df_with_retry("""
        SELECT bidding_zone AS z, lead_days, input_mode AS mode,
               to_char(market_date, 'YYYY-MM') AS month,
               market_date, mae, bias, corr
        FROM simulations.forecast_scores
        WHERE code_version = \$1
    """, [CV])
    zones = Euphemia.sql2df_with_retry("""
        SELECT DISTINCT bidding_zone AS z FROM simulations.forecast_prices
        WHERE code_version = \$1 ORDER BY 1
    """, [CV])

    agg(sub) = begin
        mae_v = collect(skipmissing(sub.mae))
        bias_v = collect(skipmissing(sub.bias))
        corr_v = collect(skipmissing(sub.corr))
        (n_days=length(unique(sub.market_date)),
         mae=isempty(mae_v) ? nothing : mean(mae_v),
         bias=isempty(bias_v) ? nothing : mean(bias_v),
         corr=isempty(corr_v) ? nothing : mean(corr_v))
    end

    entries = Any[]
    if !isempty(scores)
        for zlm in unique(collect(zip(String.(scores.z), Int.(scores.lead_days),
                                      String.(scores.mode))))
            zone, lead, mode = zlm
            sub = scores[(scores.z .== zone) .& (scores.lead_days .== lead) .&
                         (scores.mode .== mode), :]
            a = agg(sub)
            push!(entries, Dict("zone" => zone, "lead_days" => lead, "window" => "all",
                                "input_mode" => mode,
                                "n_days" => a.n_days, "mae" => nn(a.mae),
                                "bias" => nn(a.bias), "corr" => nn(a.corr)))
            for month in sort(unique(String.(sub.month)))
                m = sub[sub.month .== month, :]
                am = agg(m)
                push!(entries, Dict("zone" => zone, "lead_days" => lead, "window" => month,
                                    "input_mode" => mode,
                                    "n_days" => am.n_days, "mae" => nn(am.mae),
                                    "bias" => nn(am.bias), "corr" => nn(am.corr)))
            end
        end
    end

    doc = Dict("generated_utc" => now(UTC), "code_version" => CV,
               "market_day_tz" => "Europe/Athens",
               "zones" => String.(zones.z), "scores" => entries)
    path = joinpath(OUT_DIR, "scoreboard.json")
    open(path, "w") do io
        json_write(io, doc)
    end
    println("wrote $path ($(length(entries)) score entries, $(nrow(zones)) zones)")
end

function export_zone_files()
    prices = Euphemia.sql2df_with_retry("""
        SELECT bidding_zone AS z, market_date, lead_days, input_mode AS mode,
               (date_time_utc AT TIME ZONE 'UTC') AS t,
               price_eur_mwh AS sim,
               (prediction_made_utc AT TIME ZONE 'UTC') AS made
        FROM simulations.forecast_prices
        WHERE code_version = \$1
          AND market_date IN (
            SELECT DISTINCT market_date FROM simulations.forecast_prices
            WHERE code_version = \$1 ORDER BY market_date DESC LIMIT \$2)
        ORDER BY bidding_zone, market_date DESC, lead_days, input_mode, date_time_utc
    """, [CV, MAX_DAYS])
    if isempty(prices)
        println("no forecast_prices rows for cv=$CV — no zone files written")
        return
    end
    scores = Euphemia.sql2df_with_retry("""
        SELECT bidding_zone AS z, market_date, lead_days, input_mode AS mode,
               mae, bias, corr
        FROM simulations.forecast_scores WHERE code_version = \$1
    """, [CV])
    scoremap = Dict{Tuple{String,Date,Int,String},Any}(
        (String(r.z), Date(r.market_date), Int(r.lead_days), String(r.mode)) => r
        for r in eachrow(scores))

    sd, ed = extrema(Date.(prices.market_date))
    # market_date is the Europe/Athens market day: its window starts at
    # 21:00/22:00 UTC on the previous UTC day, so fetch actuals from sd-1.
    act = resolution_aware_actuals(sd - Day(1), ed)
    actmap = Dict{Tuple{String,DateTime},Float64}(
        (String(a.z), DateTime(a.t)) => Float64(a.act) for a in eachrow(act))

    zdir = joinpath(OUT_DIR, "zones")
    mkpath(zdir)
    nz = 0
    for zone in sort(unique(String.(prices.z)))
        zp = prices[prices.z .== zone, :]
        days = Any[]
        for key in unique(collect(zip(Date.(zp.market_date), Int.(zp.lead_days),
                                      String.(zp.mode))))
            d, lead, mode = key
            sub = sort(zp[(Date.(zp.market_date) .== d) .& (zp.lead_days .== lead) .&
                          (zp.mode .== mode), :], :t)
            hours = [DateTime(t) for t in sub.t]
            sims = Float64.(sub.sim)
            actuals = Any[get(actmap, (zone, h), nothing) for h in hours]
            sc = get(scoremap, (zone, d, lead, mode), nothing)
            push!(days, Dict(
                "date" => d,
                "lead_days" => lead,
                "input_mode" => mode,
                "prediction_made_utc" => DateTime(sub.made[1]),
                "hours" => hours,
                "sim" => sims,
                "actual" => actuals,
                "mae" => sc === nothing ? nothing : nn(sc.mae),
                "bias" => sc === nothing ? nothing : nn(sc.bias),
                "corr" => sc === nothing ? nothing : nn(sc.corr)))
        end
        # newest first, then by increasing lead ('entsoe' before 'weather' within a lead)
        sort!(days; by=e -> (e["date"], -e["lead_days"],
                             e["input_mode"] == "entsoe" ? 1 : 0), rev=true)
        path = joinpath(zdir, "$zone.json")
        open(path, "w") do io
            json_write(io, Dict("zone" => zone, "market_day_tz" => "Europe/Athens",
                                "days" => days))
        end
        nz += 1
    end
    println("wrote $nz zone files to $zdir")
end

# web/data/map.json — the map view's data contract: one entry per market day
# (last MAP_DAYS), each with per-zone day aggregates from the FRESHEST lead:
#   {"days":[{"date","zones":{"GR":{"sim","act","mae","corr","lead","made"},…}},…]}
# "sim"/"act" are day-average €/MWh (act null until settled); mae/corr are the
# day scores for that zone-day at the same lead (null until scored).
const MAP_DAYS = 60

function export_map_json()
    # map.json prefers the reference track (input_mode='entsoe') for now —
    # shape unchanged, SPA-compatible.
    prices = Euphemia.sql2df_with_retry("""
        WITH freshest AS (
            SELECT bidding_zone, market_date, MIN(lead_days) AS lead
            FROM simulations.forecast_prices
            WHERE code_version = \$1 AND input_mode = 'entsoe'
            GROUP BY 1, 2)
        SELECT p.bidding_zone AS z, p.market_date, p.lead_days,
               (p.date_time_utc AT TIME ZONE 'UTC') AS t,
               p.price_eur_mwh AS sim,
               (p.prediction_made_utc AT TIME ZONE 'UTC') AS made
        FROM simulations.forecast_prices p
        JOIN freshest f ON f.bidding_zone = p.bidding_zone
                       AND f.market_date = p.market_date AND f.lead = p.lead_days
        WHERE p.code_version = \$1
          AND p.input_mode = 'entsoe'
          AND p.market_date IN (
            SELECT DISTINCT market_date FROM simulations.forecast_prices
            WHERE code_version = \$1 AND input_mode = 'entsoe'
            ORDER BY market_date DESC LIMIT \$2)
    """, [CV, MAP_DAYS])
    if isempty(prices)
        println("no forecast_prices rows for cv=$CV — no map.json written")
        return
    end
    scores = Euphemia.sql2df_with_retry("""
        SELECT bidding_zone AS z, market_date, lead_days, mae, corr
        FROM simulations.forecast_scores
        WHERE code_version = \$1 AND input_mode = 'entsoe'
    """, [CV])
    scoremap = Dict{Tuple{String,Date,Int},Any}(
        (String(r.z), Date(r.market_date), Int(r.lead_days)) => r
        for r in eachrow(scores))

    sd, ed = extrema(Date.(prices.market_date))
    act = resolution_aware_actuals(sd - Day(1), ed)
    actmap = Dict{Tuple{String,DateTime},Float64}(
        (String(a.z), DateTime(a.t)) => Float64(a.act) for a in eachrow(act))

    days = Any[]
    for d in sort(unique(Date.(prices.market_date)))
        sub = prices[Date.(prices.market_date) .== d, :]
        zones = Dict{String,Any}()
        for zone in unique(String.(sub.z))
            zp = sub[sub.z .== zone, :]
            hours = [DateTime(t) for t in zp.t]
            acts = [get(actmap, (zone, h), nothing) for h in hours]
            settled = [a for a in acts if a !== nothing]
            lead = Int(zp.lead_days[1])
            sc = get(scoremap, (zone, d, lead), nothing)
            zones[zone] = Dict(
                "sim" => round(mean(Float64.(zp.sim)); digits=2),
                "act" => length(settled) == length(hours) ?
                         round(mean(Float64.(settled)); digits=2) : nothing,
                "mae" => sc === nothing ? nothing : nn(sc.mae),
                "corr" => sc === nothing ? nothing : nn(sc.corr),
                "lead" => lead,
                "made" => DateTime(zp.made[1]))
        end
        push!(days, Dict("date" => d, "zones" => zones))
    end
    path = joinpath(OUT_DIR, "map.json")
    open(path, "w") do io
        json_write(io, Dict("generated_utc" => now(UTC), "code_version" => CV,
                            "market_day_tz" => "Europe/Athens", "days" => days))
    end
    println("wrote $path ($(length(days)) days)")
end

function main()
    println("=" ^ 70)
    println("EXPORT FORECAST JSON  cv=$CV  out=$OUT_DIR")
    println("=" ^ 70)
    mkpath(OUT_DIR)
    export_scoreboard()
    export_zone_files()
    export_map_json()
    println("EXPORT COMPLETE")
end

main()
