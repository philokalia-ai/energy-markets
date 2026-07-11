#!/usr/bin/env julia
#
# Export the daily-forecast SPA data contract to web/data/ (invoked by
# .github/workflows/daily-forecast.yml after bin/score_forecasts.jl).
#
# Contract (consumed by a separately-built SPA — do not change shapes):
#
# web/data/scoreboard.json
#   {"generated_utc": ..., "code_version": 16, "zones": [...],
#    "scores": [{"zone","lead_days","window" ("all" or "YYYY-MM"),
#                "n_days","mae","bias","corr"}, ...]}
#
# web/data/zones/<ZONE>.json
#   {"zone": ..., "days": [{"date","lead_days","prediction_made_utc",
#     "hours":[ISO8601...], "sim":[...], "actual":[... or null where
#     unrealized], "mae","bias","corr" (null when unrealized)}, ...]}
#   — most recent 120 market days, newest first, one entry per (date, lead_days).
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
        SELECT bidding_zone AS z, lead_days, to_char(market_date, 'YYYY-MM') AS month,
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
        for zl in unique(collect(zip(String.(scores.z), Int.(scores.lead_days))))
            zone, lead = zl
            sub = scores[(scores.z .== zone) .& (scores.lead_days .== lead), :]
            a = agg(sub)
            push!(entries, Dict("zone" => zone, "lead_days" => lead, "window" => "all",
                                "n_days" => a.n_days, "mae" => nn(a.mae),
                                "bias" => nn(a.bias), "corr" => nn(a.corr)))
            for month in sort(unique(String.(sub.month)))
                m = sub[sub.month .== month, :]
                am = agg(m)
                push!(entries, Dict("zone" => zone, "lead_days" => lead, "window" => month,
                                    "n_days" => am.n_days, "mae" => nn(am.mae),
                                    "bias" => nn(am.bias), "corr" => nn(am.corr)))
            end
        end
    end

    doc = Dict("generated_utc" => now(UTC), "code_version" => CV,
               "zones" => String.(zones.z), "scores" => entries)
    path = joinpath(OUT_DIR, "scoreboard.json")
    open(path, "w") do io
        json_write(io, doc)
    end
    println("wrote $path ($(length(entries)) score entries, $(nrow(zones)) zones)")
end

function export_zone_files()
    prices = Euphemia.sql2df_with_retry("""
        SELECT bidding_zone AS z, market_date, lead_days,
               (date_time_utc AT TIME ZONE 'UTC') AS t,
               price_eur_mwh AS sim,
               (prediction_made_utc AT TIME ZONE 'UTC') AS made
        FROM simulations.forecast_prices
        WHERE code_version = \$1
          AND market_date IN (
            SELECT DISTINCT market_date FROM simulations.forecast_prices
            WHERE code_version = \$1 ORDER BY market_date DESC LIMIT \$2)
        ORDER BY bidding_zone, market_date DESC, lead_days, date_time_utc
    """, [CV, MAX_DAYS])
    if isempty(prices)
        println("no forecast_prices rows for cv=$CV — no zone files written")
        return
    end
    scores = Euphemia.sql2df_with_retry("""
        SELECT bidding_zone AS z, market_date, lead_days, mae, bias, corr
        FROM simulations.forecast_scores WHERE code_version = \$1
    """, [CV])
    scoremap = Dict{Tuple{String,Date,Int},Any}(
        (String(r.z), Date(r.market_date), Int(r.lead_days)) => r
        for r in eachrow(scores))

    sd, ed = extrema(Date.(prices.market_date))
    act = resolution_aware_actuals(sd, ed)
    actmap = Dict{Tuple{String,DateTime},Float64}(
        (String(a.z), DateTime(a.t)) => Float64(a.act) for a in eachrow(act))

    zdir = joinpath(OUT_DIR, "zones")
    mkpath(zdir)
    nz = 0
    for zone in sort(unique(String.(prices.z)))
        zp = prices[prices.z .== zone, :]
        days = Any[]
        for key in unique(collect(zip(Date.(zp.market_date), Int.(zp.lead_days))))
            d, lead = key
            sub = sort(zp[(Date.(zp.market_date) .== d) .& (zp.lead_days .== lead), :], :t)
            hours = [DateTime(t) for t in sub.t]
            sims = Float64.(sub.sim)
            actuals = Any[get(actmap, (zone, h), nothing) for h in hours]
            sc = get(scoremap, (zone, d, lead), nothing)
            push!(days, Dict(
                "date" => d,
                "lead_days" => lead,
                "prediction_made_utc" => DateTime(sub.made[1]),
                "hours" => hours,
                "sim" => sims,
                "actual" => actuals,
                "mae" => sc === nothing ? nothing : nn(sc.mae),
                "bias" => sc === nothing ? nothing : nn(sc.bias),
                "corr" => sc === nothing ? nothing : nn(sc.corr)))
        end
        # newest first, then by increasing lead
        sort!(days; by=e -> (e["date"], -e["lead_days"]), rev=true)
        path = joinpath(zdir, "$zone.json")
        open(path, "w") do io
            json_write(io, Dict("zone" => zone, "days" => days))
        end
        nz += 1
    end
    println("wrote $nz zone files to $zdir")
end

function main()
    println("=" ^ 70)
    println("EXPORT FORECAST JSON  cv=$CV  out=$OUT_DIR")
    println("=" ^ 70)
    mkpath(OUT_DIR)
    export_scoreboard()
    export_zone_files()
    println("EXPORT COMPLETE")
end

main()
