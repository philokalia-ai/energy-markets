#!/usr/bin/env julia
#
# Export the daily-forecast SPA data contract as PARQUET to a staging dir
# (default data/web/v1), for upload to the R2 bucket `euphemia-web-data`
# via bin/web_data_push.sh (issue #152 — live data backend).
#
# Layout (the /v1/ public data API — stable; schema changes bump /v2/):
#
#   v1/zones/<ZONE>.parquet   one row per (market_date, lead_days, input_mode,
#                             delivery hour): market_date DATE, lead_days INT,
#                             input_mode VARCHAR, prediction_made_utc TIMESTAMP,
#                             date_time_utc TIMESTAMP, sim DOUBLE,
#                             actual DOUBLE (null until settled), and the
#                             day-level scores mae/bias/corr DOUBLE (null until
#                             scored; repeated on each hourly row).
#   v1/scoreboard.parquet     zone, lead_days, window ("all" | "YYYY-MM"),
#                             input_mode, n_days, mae, bias, corr.
#   v1/map.parquet            market_date, zone, sim, act, mae, corr, lead,
#                             made — freshest-lead day aggregates, reference
#                             (entsoe) track only, matching web/data/map.json.
#   v1/manifest.json          {updated_at, code_version, market_day_tz, zones,
#                              row_counts} — freshness + discovery.
#
# The COLUMNAR CONTENT is value-identical to bin/export_forecast_json.jl's
# JSON output (same queries, same window, same aggregation); the Cloudflare
# Worker in workers/api/ re-emits the exact JSON shapes web/app.js consumes.
# Anyone can also query the objects directly, e.g.:
#   duckdb -c "SELECT * FROM 'https://…/v1/zones/GR.parquet' LIMIT 5"
#
# Env:
#   WEB_PARQUET_OUT   staging root (default <repo>/data/web); objects land
#                     under $WEB_PARQUET_OUT/v1/
#   UPDATED_AT        manifest updated_at override (ISO8601; default now UTC)

using Euphemia, Dates, Statistics, DataFrames, DuckDB   # DuckDB re-exports DBInterface

include(joinpath(@__DIR__, "forecast_common.jl"))
# resolution-aware actuals (guarded __main__, safe to include)
include(joinpath(@__DIR__, "..", "test", "scripts", "eu_eval_metrics.jl"))

const CV = Euphemia.ENERGY_PRICES_CODE_VERSION
const OUT_ROOT = get(ENV, "WEB_PARQUET_OUT", joinpath(dirname(@__DIR__), "data", "web"))
const V1_DIR = joinpath(OUT_ROOT, "v1")
const MAX_DAYS = 120   # same recent window as export_forecast_json.jl
const MAP_DAYS = 60

# nothing/missing/NaN/Inf -> missing (parquet null; JSON null downstream)
nm(x) = (x === nothing || x === missing) ? missing :
        (x isa AbstractFloat && !isfinite(x)) ? missing : x

# One in-memory DuckDB connection for all COPY ... TO parquet writes.
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
# scoreboard.parquet — same aggregation as export_scoreboard()
# ---------------------------------------------------------------------------
function export_scoreboard_parquet()
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
         mae=isempty(mae_v) ? missing : mean(mae_v),
         bias=isempty(bias_v) ? missing : mean(bias_v),
         corr=isempty(corr_v) ? missing : mean(corr_v))
    end

    df = DataFrame(zone=String[], lead_days=Int[], window=String[],
                   input_mode=String[], n_days=Int[],
                   mae=Union{Missing,Float64}[], bias=Union{Missing,Float64}[],
                   corr=Union{Missing,Float64}[])
    if !isempty(scores)
        for zlm in unique(collect(zip(String.(scores.z), Int.(scores.lead_days),
                                      String.(scores.mode))))
            zone, lead, mode = zlm
            sub = scores[(scores.z .== zone) .& (scores.lead_days .== lead) .&
                         (scores.mode .== mode), :]
            a = agg(sub)
            push!(df, (zone, lead, "all", mode, a.n_days,
                       nm(a.mae), nm(a.bias), nm(a.corr)))
            for month in sort(unique(String.(sub.month)))
                m = sub[sub.month .== month, :]
                am = agg(m)
                push!(df, (zone, lead, month, mode, am.n_days,
                           nm(am.mae), nm(am.bias), nm(am.corr)))
            end
        end
    end
    sort!(df, [:zone, :lead_days, :input_mode, :window])
    n = write_parquet(df, joinpath(V1_DIR, "scoreboard.parquet"))
    println("wrote v1/scoreboard.parquet ($n score entries, $(nrow(zones)) zones)")
    return String.(zones.z), n
end

# ---------------------------------------------------------------------------
# zones/<ZONE>.parquet — same content as export_zone_files()
# ---------------------------------------------------------------------------
function export_zone_parquets()
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
        println("no forecast_prices rows for cv=$CV — no zone parquets written")
        return Dict{String,Int}()
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

    counts = Dict{String,Int}()
    for zone in sort(unique(String.(prices.z)))
        zp = prices[prices.z .== zone, :]
        df = DataFrame(market_date=Date[], lead_days=Int[], input_mode=String[],
                       prediction_made_utc=DateTime[], date_time_utc=DateTime[],
                       sim=Float64[], actual=Union{Missing,Float64}[],
                       mae=Union{Missing,Float64}[], bias=Union{Missing,Float64}[],
                       corr=Union{Missing,Float64}[])
        keys_ = unique(collect(zip(Date.(zp.market_date), Int.(zp.lead_days),
                                   String.(zp.mode))))
        # newest first, then by increasing lead ('entsoe' before 'weather'
        # within a lead) — same day ordering as the JSON exporter.
        sort!(keys_; by=k -> (k[1], -k[2], k[3] == "entsoe" ? 1 : 0), rev=true)
        for (d, lead, mode) in keys_
            sub = sort(zp[(Date.(zp.market_date) .== d) .& (zp.lead_days .== lead) .&
                          (zp.mode .== mode), :], :t)
            sc = get(scoremap, (zone, d, lead, mode), nothing)
            mae = sc === nothing ? missing : nm(sc.mae)
            bias = sc === nothing ? missing : nm(sc.bias)
            corr = sc === nothing ? missing : nm(sc.corr)
            made = DateTime(sub.made[1])
            for r in eachrow(sub)
                h = DateTime(r.t)
                push!(df, (d, lead, mode, made, h, Float64(r.sim),
                           get(actmap, (zone, h), missing), mae, bias, corr))
            end
        end
        counts["zones/$zone.parquet"] =
            write_parquet(df, joinpath(V1_DIR, "zones", "$zone.parquet"))
    end
    println("wrote $(length(counts)) zone parquets to v1/zones/")
    return counts
end

# ---------------------------------------------------------------------------
# map.parquet — same day aggregates as export_map_json() (entsoe track,
# freshest lead per zone-day)
# ---------------------------------------------------------------------------
function export_map_parquet()
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
        println("no forecast_prices rows for cv=$CV — no map.parquet written")
        return 0
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

    df = DataFrame(market_date=Date[], zone=String[], sim=Float64[],
                   act=Union{Missing,Float64}[], mae=Union{Missing,Float64}[],
                   corr=Union{Missing,Float64}[], lead=Int[], made=DateTime[])
    for d in sort(unique(Date.(prices.market_date)))
        sub = prices[Date.(prices.market_date) .== d, :]
        for zone in sort(unique(String.(sub.z)))
            zp = sub[sub.z .== zone, :]
            hours = [DateTime(t) for t in zp.t]
            acts = [get(actmap, (zone, h), nothing) for h in hours]
            settled = Float64[a for a in acts if a !== nothing]
            lead = Int(zp.lead_days[1])
            sc = get(scoremap, (zone, d, lead), nothing)
            push!(df, (d, zone,
                       round(mean(Float64.(zp.sim)); digits=2),
                       length(settled) == length(hours) ?
                           round(mean(settled); digits=2) : missing,
                       sc === nothing ? missing : nm(sc.mae),
                       sc === nothing ? missing : nm(sc.corr),
                       lead, DateTime(zp.made[1])))
        end
    end
    n = write_parquet(df, joinpath(V1_DIR, "map.parquet"))
    println("wrote v1/map.parquet ($n zone-day rows)")
    return n
end

function main()
    println("=" ^ 70)
    println("EXPORT WEB PARQUET  cv=$CV  out=$V1_DIR")
    println("=" ^ 70)
    mkpath(V1_DIR)
    zones, n_scores = export_scoreboard_parquet()
    zone_counts = export_zone_parquets()
    n_map = export_map_parquet()

    updated_at = get(ENV, "UPDATED_AT", Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SS") * "Z")
    counts = Dict{String,Any}("scoreboard.parquet" => n_scores,
                              "map.parquet" => n_map)
    for (k, v) in zone_counts
        counts[k] = v
    end
    manifest = Dict(
        "updated_at" => updated_at,
        "code_version" => CV,
        "market_day_tz" => "Europe/Athens",
        "zones" => zones,
        "row_counts" => counts,
        "schema" => "v1",
    )
    open(joinpath(V1_DIR, "manifest.json"), "w") do io
        json_write(io, manifest)
    end
    println("wrote v1/manifest.json (updated_at=$updated_at)")
    println("EXPORT COMPLETE")
end

main()
