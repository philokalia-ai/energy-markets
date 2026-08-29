#!/usr/bin/env julia
#
# Export the daily-forecast SPA data contract to web/data/ (invoked by
# .github/workflows/daily-forecast.yml after bin/score_forecasts.jl).
#
# Contract (consumed by a separately-built SPA — do not change shapes):
#
# RECORD SPANS VERSIONS (honesty note): the exported record is the product's
# full history across code versions — slice identity is (market_date,
# lead_days, input_mode); code_version is per-row PROVENANCE, not a display
# filter. Where a slice exists under more than one code_version, the
# EARLIEST-FROZEN slice wins (slice-level MIN(prediction_made_utc) — the
# first commitment is the honest ex-ante vintage); see CHOSEN_SLICE_CTE in
# bin/forecast_common.jl. The top-level "code_version" in scoreboard.json /
# map.json is the CURRENT model version for display; each zone-file day entry
# carries the code_version that produced it.
#
# web/data/scoreboard.json
#   {"generated_utc": ..., "code_version": <current cv>, "market_day_tz":
#    "Europe/Athens", "zones": [...],
#    "scores": [{"zone","lead_days","window" ("all" or "YYYY-MM"),
#                "n_days","mae","bias","corr","input_mode"}, ...]}
#   — "input_mode" is 'entsoe' (reference track) or 'weather' (ex-ante track);
#   the SPA treats an absent input_mode as 'entsoe' (backward compatible).
#   Scores aggregate ONLY the chosen slices (duplicates that were scored twice
#   across cvs are never double-counted).
#
# web/data/zones/<ZONE>.json
#   {"zone": ..., "market_day_tz": "Europe/Athens",
#    "days": [{"date","lead_days","prediction_made_utc",
#     "hours":[ISO8601...], "sim":[...], "actual":[... or null where
#     unrealized], "mae","bias","corr" (null when unrealized),
#     "input_mode","code_version"}, ...]}
#   — most recent 120 market days, newest first, one entry per
#   (date, lead_days, input_mode). "date" is the Europe/Athens market day;
#   "hours" are the window's UTC stamps (24 normally; 23/25 on DST days).
#   "code_version" is the provenance of that day entry's chosen slice.
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
    # Chosen-slice join: aggregate ONLY the earliest-frozen slice's scores per
    # (market_date, lead_days, input_mode) — a duplicate slice scored under a
    # second code_version must not double-count.
    scores = Euphemia.sql2df_with_retry("""
        WITH $(CHOSEN_SLICE_CTE)
        SELECT s.bidding_zone AS z, s.lead_days, s.input_mode AS mode,
               to_char(s.market_date, 'YYYY-MM') AS month,
               s.market_date, s.code_version AS cv, s.mae, s.bias, s.corr
        FROM simulations.forecast_scores s
        JOIN chosen c ON c.market_date = s.market_date AND c.lead_days = s.lead_days
                     AND c.input_mode = s.input_mode AND c.code_version = s.code_version
    """)
    zones = Euphemia.sql2df_with_retry("""
        SELECT DISTINCT bidding_zone AS z FROM simulations.forecast_prices
        ORDER BY 1
    """)

    agg(sub) = begin
        mae_v = collect(skipmissing(sub.mae))
        bias_v = collect(skipmissing(sub.bias))
        corr_v = collect(skipmissing(sub.corr))
        # code_version = per-cell provenance for the same-cv pairing guard (single
        # value when the cell is single-cv, else nothing = mixed → chip shows n/a).
        cvs = unique(Int.(sub.cv))
        (n_days=length(unique(sub.market_date)),
         mae=isempty(mae_v) ? nothing : mean(mae_v),
         bias=isempty(bias_v) ? nothing : mean(bias_v),
         corr=isempty(corr_v) ? nothing : mean(corr_v),
         cv=length(cvs) == 1 ? cvs[1] : nothing)
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
                                "bias" => nn(a.bias), "corr" => nn(a.corr),
                                "code_version" => a.cv))
            for month in sort(unique(String.(sub.month)))
                m = sub[sub.month .== month, :]
                am = agg(m)
                push!(entries, Dict("zone" => zone, "lead_days" => lead, "window" => month,
                                    "input_mode" => mode,
                                    "n_days" => am.n_days, "mae" => nn(am.mae),
                                    "bias" => nn(am.bias), "corr" => nn(am.corr),
                                    "code_version" => am.cv))
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
    # Cross-version record: one chosen slice per (market_date, lead_days,
    # input_mode), earliest-frozen-wins; code_version carried as provenance.
    prices = Euphemia.sql2df_with_retry("""
        WITH $(CHOSEN_SLICE_CTE)
        SELECT p.bidding_zone AS z, p.market_date, p.lead_days, p.input_mode AS mode,
               p.code_version AS cv,
               (p.date_time_utc AT TIME ZONE 'UTC') AS t,
               p.price_eur_mwh AS sim,
               (p.prediction_made_utc AT TIME ZONE 'UTC') AS made
        FROM simulations.forecast_prices p
        JOIN chosen c ON c.market_date = p.market_date AND c.lead_days = p.lead_days
                     AND c.input_mode = p.input_mode AND c.code_version = p.code_version
        WHERE p.market_date IN (
            SELECT DISTINCT market_date FROM simulations.forecast_prices
            ORDER BY market_date DESC LIMIT \$1)
        ORDER BY p.bidding_zone, p.market_date DESC, p.lead_days, p.input_mode,
                 p.date_time_utc
    """, [MAX_DAYS])
    if isempty(prices)
        println("no forecast_prices rows — no zone files written")
        return
    end
    scores = Euphemia.sql2df_with_retry("""
        WITH $(CHOSEN_SLICE_CTE)
        SELECT s.bidding_zone AS z, s.market_date, s.lead_days, s.input_mode AS mode,
               s.mae, s.bias, s.corr
        FROM simulations.forecast_scores s
        JOIN chosen c ON c.market_date = s.market_date AND c.lead_days = s.lead_days
                     AND c.input_mode = s.input_mode AND c.code_version = s.code_version
    """)
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
                "code_version" => Int(sub.cv[1]),
                "prediction_made_utc" => DateTime(sub.made[1]),
                "hours" => hours,
                "sim" => sims,
                "actual" => actuals,
                "mae" => sc === nothing ? nothing : nn(sc.mae),
                "bias" => sc === nothing ? nothing : nn(sc.bias),
                "corr" => sc === nothing ? nothing : nn(sc.corr),
                "gbm" => Any[get(mlmap, (zone, "hybrid_gbm", h), nothing) for h in hours],
                "stats" => Any[get(mlmap, (zone, "stats_gbm", h), nothing) for h in hours]))
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
#   {"days":[{"date","zones":{"GR":{"sim","act","err_pct","mae","corr","lead","made"},…}},…]}
# "sim"/"act" are day-average €/MWh (act null until settled); "err_pct" is the
# load-weighted WAPE % (load_weighted_err_pct — null until the day fully
# settles, or when the denominator is degenerate); mae/corr are the day scores
# for that zone-day at the same lead (null until scored).
const MAP_DAYS = 60

map_track_expr(col) = "CASE WHEN $(col) LIKE 'weather%' THEN 'predicted' ELSE 'announced' END"

function export_map_json()
    # map.json carries BOTH tracks (the global Predicted / As-announced lens):
    # each day has `tracks = {predicted:{zone:{…}}, announced:{zone:{…}}}` plus a
    # flat `zones` pointing at the predicted track (default lens; the SPA repoints
    # it on a flip). `track` derived from input_mode ('weather%' -> predicted).
    # Cross-version record: rows come from the chosen (earliest-frozen) slice per
    # (market_date, lead_days, input_mode), freshest lead per (zone, date, track).
    prices = Euphemia.sql2df_with_retry("""
        WITH $(CHOSEN_SLICE_CTE),
        src AS (
            SELECT p.bidding_zone, p.market_date, p.lead_days,
                   $(map_track_expr("p.input_mode")) AS track,
                   p.date_time_utc, p.price_eur_mwh, p.prediction_made_utc
            FROM simulations.forecast_prices p
            JOIN chosen c ON c.market_date = p.market_date AND c.lead_days = p.lead_days
                         AND c.input_mode = p.input_mode AND c.code_version = p.code_version),
        freshest AS (
            SELECT bidding_zone, market_date, track, MIN(lead_days) AS lead
            FROM src
            GROUP BY 1, 2, 3)
        SELECT s.bidding_zone AS z, s.market_date, s.lead_days, s.track,
               (s.date_time_utc AT TIME ZONE 'UTC') AS t,
               s.price_eur_mwh AS sim,
               (s.prediction_made_utc AT TIME ZONE 'UTC') AS made
        FROM src s
        JOIN freshest f ON f.bidding_zone = s.bidding_zone
                       AND f.market_date = s.market_date AND f.track = s.track
                       AND f.lead = s.lead_days
        WHERE s.market_date IN (
            SELECT DISTINCT market_date FROM simulations.forecast_prices
            ORDER BY market_date DESC LIMIT \$1)
    """, [MAP_DAYS])
    if isempty(prices)
        println("no forecast_prices rows — no map.json written")
        return
    end
    scores = Euphemia.sql2df_with_retry("""
        WITH $(CHOSEN_SLICE_CTE)
        SELECT s.bidding_zone AS z, s.market_date, s.lead_days,
               $(map_track_expr("s.input_mode")) AS track, s.mae, s.corr
        FROM simulations.forecast_scores s
        JOIN chosen c ON c.market_date = s.market_date AND c.lead_days = s.lead_days
                     AND c.input_mode = s.input_mode AND c.code_version = s.code_version
    """)
    scoremap = Dict{Tuple{String,Date,Int,String},Any}(
        (String(r.z), Date(r.market_date), Int(r.lead_days), String(r.track)) => r
        for r in eachrow(scores))

    sd, ed = extrema(Date.(prices.market_date))
    act = resolution_aware_actuals(sd - Day(1), ed)
    actmap = Dict{Tuple{String,DateTime},Float64}(
        (String(a.z), DateTime(a.t)) => Float64(a.act) for a in eachrow(act))

    # Model-line overlays (docs/experiments/forecast-eval-2026-08): the
    # [physics + ex-ante GBM] and [pure-stats GBM] hourly series from
    # simulations.model_lines — optional per day; the SPA draws them as the
    # pink / yellow lines. Absent hours stay null (honest gaps).
    ml = try
        Euphemia.sql2df_with_retry("""
            SELECT bidding_zone AS z, model,
                   (date_time_utc AT TIME ZONE 'UTC') AS t, price_eur_mwh AS p
            FROM simulations.model_lines
            WHERE date_time_utc >= (\$1::date - INTERVAL '1 day')::timestamp
            """, [sd])
    catch e
        @warn "model_lines unavailable — overlays skipped" error=e
        DataFrame(z=String[], model=String[], t=DateTime[], p=Float64[])
    end
    mlmap = Dict{Tuple{String,String,DateTime},Float64}(
        (String(r.z), String(r.model), DateTime(r.t)) => Float64(r.p) for r in eachrow(ml))
    # Hourly D-1 load forecast: the weights of err_pct (load-weighted WAPE).
    loads = Euphemia.sql2df_with_retry(HOURLY_LOAD_FC_SQL, [sd - Day(1), ed + Day(1)])
    loadmap = Dict{Tuple{String,DateTime},Float64}(
        (String(r.z), DateTime(r.t)) => Float64(r.load_mw) for r in eachrow(loads))

    zone_agg(zp, d, track) = begin
        zone = String(zp.z[1])
        hours = [DateTime(t) for t in zp.t]
        acts = [get(actmap, (zone, h), nothing) for h in hours]
        settled = [a for a in acts if a !== nothing]
        lead = Int(zp.lead_days[1])
        sc = get(scoremap, (zone, d, lead, track), nothing)
        # err_pct: only for fully-settled days with full load coverage (the
        # metric is undefined otherwise — never fabricated).
        loadv = [get(loadmap, (zone, h), nothing) for h in hours]
        ep = (length(settled) == length(hours) && all(!isnothing, loadv)) ?
            load_weighted_err_pct(Float64.(zp.sim), Float64.(settled), Float64.(loadv)) :
            nothing
        Dict(
            "sim" => round(mean(Float64.(zp.sim)); digits=2),
            "act" => length(settled) == length(hours) ?
                     round(mean(Float64.(settled)); digits=2) : nothing,
            "err_pct" => ep === nothing ? nothing : round(ep; digits=2),
            "mae" => sc === nothing ? nothing : nn(sc.mae),
            "corr" => sc === nothing ? nothing : nn(sc.corr),
            "lead" => lead,
            "made" => DateTime(zp.made[1]))
    end

    days = Any[]
    for d in sort(unique(Date.(prices.market_date)))
        sub = prices[Date.(prices.market_date) .== d, :]
        tracks = Dict("predicted" => Dict{String,Any}(), "announced" => Dict{String,Any}())
        for track in unique(String.(sub.track))
            st = sub[String.(sub.track) .== track, :]
            for zone in unique(String.(st.z))
                zp = st[st.z .== zone, :]
                tracks[track][zone] = zone_agg(zp, d, track)
            end
        end
        # Flat zones = predicted where present, else announced (single-track).
        flat = !isempty(tracks["predicted"]) ? tracks["predicted"] : tracks["announced"]
        push!(days, Dict("date" => d, "zones" => flat, "tracks" => tracks))
    end
    path = joinpath(OUT_DIR, "map.json")
    open(path, "w") do io
        json_write(io, Dict("generated_utc" => now(UTC), "code_version" => CV,
                            "market_day_tz" => "Europe/Athens",
                            "tracks" => ["predicted", "announced"], "days" => days))
    end
    println("wrote $path ($(length(days)) days, both tracks)")
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
