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
#   Additive (#431, bin/naive_baselines.jl; absent when EXPORT_NAIVE=0 or the
#   naive step failed): "n_naive", "mae_paired", "mae_naive_d7", "rmae_d7", and
#   at lead <= 1 also "mae_naive_d1", "mae_naive_epf", "rmae_d1", "rmae_epf" —
#   pooled over the cohort's paired hours, rMAE as a ratio of sums.
#   "window" may also be "since_freeze" (#431 G, bin/scoreboard_windows.jl): the
#   cv >= 44, market_date >= 2026-11-15 rows only (the out-of-sample record).
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
# naive baselines + rMAE for the scoreboard (#431; EXPORT_NAIVE=0 skips them)
include(joinpath(@__DIR__, "naive_baselines.jl"))
# the "since_freeze" window (#431 G; EXPORT_SINCE_FREEZE=0 skips it)
include(joinpath(@__DIR__, "scoreboard_windows.jl"))

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
               s.market_date, s.code_version AS cv, s.mae, s.bias, s.corr,
               $(q15_select("s"))
        FROM simulations.forecast_scores s
        JOIN chosen c ON c.market_date = s.market_date AND c.lead_days = s.lead_days
                     AND c.input_mode = s.input_mode AND c.code_version = s.code_version
    """)
    zones = Euphemia.sql2df_with_retry("""
        SELECT DISTINCT bidding_zone AS z FROM simulations.forecast_prices
        ORDER BY 1
    """)

    naive_parts = naive_parts_or_nothing(scores)   # nothing = no naive fields
    # No naive fields -> merge exactly the arguments main merged (same Dict, same bytes).
    naive_or_empty(x) = x === nothing ? () : (x,)
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
         cv=length(cvs) == 1 ? cvs[1] : nothing,
         q15=q15_board_fields(sub), naive=naive_cohort_fields(naive_parts, sub))
    end
    # 15-min: mean over the zone-days that HAVE a native-15 score only (same as the parquet).
    q15_board_fields(sub) = begin
        q = sub[.!ismissing.(sub.mae_q15), :]
        qm(col) = (v = collect(skipmissing(q[!, col])); isempty(v) ? nothing : mean(v))
        Dict{String,Any}("n_days_q15" => length(unique(q.market_date)),
                         "mae_q15" => qm(:mae_q15), "bias_q15" => qm(:bias_q15),
                         "corr_q15" => qm(:corr_q15), "shape_floor_q15" => qm(:shape_floor_q15))
    end

    entries = Any[]
    if !isempty(scores)
        for zlm in unique(collect(zip(String.(scores.z), Int.(scores.lead_days),
                                      String.(scores.mode))))
            zone, lead, mode = zlm
            sub = scores[(scores.z .== zone) .& (scores.lead_days .== lead) .&
                         (scores.mode .== mode), :]
            a = agg(sub)
            push!(entries, merge(Dict{String,Any}("zone" => zone, "lead_days" => lead, "window" => "all",
                                "input_mode" => mode,
                                "n_days" => a.n_days, "mae" => nn(a.mae),
                                "bias" => nn(a.bias), "corr" => nn(a.corr),
                                "code_version" => a.cv), a.q15, naive_or_empty(a.naive)...))
            for month in sort(unique(String.(sub.month)))
                m = sub[sub.month .== month, :]
                am = agg(m)
                push!(entries, merge(Dict{String,Any}("zone" => zone, "lead_days" => lead, "window" => month,
                                    "input_mode" => mode,
                                    "n_days" => am.n_days, "mae" => nn(am.mae),
                                    "bias" => nn(am.bias), "corr" => nn(am.corr),
                                    "code_version" => am.cv), am.q15, naive_or_empty(am.naive)...))
            end
        end
    end
    # "since_freeze" (bin/scoreboard_windows.jl): same aggregation on the cv >= 44,
    # >= 2026-11-15 rows; appended last, all-or-nothing, never fails the export.
    append!(entries, since_freeze_entries(scores) do zone, lead, mode, fsub
        af = agg(fsub)
        merge(Dict{String,Any}("zone" => zone, "lead_days" => lead, "window" => SINCE_FREEZE_WINDOW,
                               "input_mode" => mode,
                               "n_days" => af.n_days, "mae" => nn(af.mae),
                               "bias" => nn(af.bias), "corr" => nn(af.corr),
                               "code_version" => af.cv), af.q15, naive_or_empty(af.naive)...)
    end)

    doc = Dict("generated_utc" => now(UTC), "code_version" => CV,
               "market_day_tz" => "Europe/Athens",
               "zones" => String.(zones.z), "scores" => entries)
    path = joinpath(OUT_DIR, "scoreboard.json")
    open(path, "w") do io
        json_write(io, doc)
    end
    println("wrote $path ($(length(entries)) score entries, $(nrow(zones)) zones)")
end

# Model-line overlays (docs/experiments/forecast-eval-2026-08): the
# [physics + ex-ante GBM] and [pure-stats GBM] hourly series from
# simulations.model_lines — optional per day; the SPA draws them as the
# pink / yellow lines. Absent hours stay null (honest gaps). Shared by the
# per-zone files and the map JSON (a per-function copy left `mlmap`
# undefined in export_zone_files and broke the daily export 2026-08-30..09-07).
function model_lines_map(sd::Date)
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
    return Dict{Tuple{String,String,DateTime},Float64}(
        (String(r.z), String(r.model), DateTime(r.t)) => Float64(r.p) for r in eachrow(ml))
end

# TSFM overlay (lines + P(≤0) hourly + P(any hour ≤0) per zone-day, one vintage
# per zone-day) — see tsfm_overlay_maps in forecast_common.jl. Optional: an
# absent table → empty maps (fields null; the emitter's first run creates it).
function tsfm_overlay(sd::Date)
    ov = try
        Euphemia.sql2df_with_retry(TSFM_OVERLAY_SQL, [sd - Day(1)])
    catch e
        @warn "tsfm_overlay unavailable — tsfm fields null" error=e
        return (Dict{Tuple{String,String,DateTime},Float64}(), Dict{Tuple{String,Date},Any}())
    end
    return tsfm_overlay_maps(eachrow(ov))
end

# The additive TSFM fields of one zone-day entry (new optional keys; older
# consumers ignore them). All values come from the zone-day's chosen vintage.
function tsfm_fields(zone, d, hours, ovh, ovd)
    od = get(ovd, (zone, d), nothing)
    line(q) = Any[get(ovh, (zone, q, h), nothing) for h in hours]
    return Dict{String,Any}(
        "tsfm" => line("tsfm_median"),
        "tsfm_q10" => line("tsfm_q10"),
        "tsfm_q90" => line("tsfm_q90"),
        "p_le0" => line("p_le0"),
        "p_any_le0" => od === nothing ? nothing : od.p_any_le0,
        "tsfm_input_mode" => od === nothing ? nothing : od.input_mode,
        "tsfm_issue_utc" => od === nothing ? nothing : od.issue_utc,
        "tsfm_arm" => od === nothing ? nothing : od.arm)
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
               s.mae, s.bias, s.corr, $(q15_select("s"))
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
    act = da_target_actuals(sd - Day(1), ed)  # EUPHEMIA_DA_TARGET (default highest_seq)
    actmap = Dict{Tuple{String,DateTime},Float64}(
        (String(a.z), DateTime(a.t)) => Float64(a.act) for a in eachrow(act))

    mlmap = model_lines_map(sd)
    ovh, ovd = tsfm_overlay(sd)

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
            push!(days, merge(Dict{String,Any}(
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
                # native 15-min day score (null without native PT15M actuals)
                "n_q15" => (sc === nothing || ismissing(sc.n_q15)) ? nothing : Int(sc.n_q15),
                "mae_q15" => sc === nothing ? nothing : nn(sc.mae_q15),
                "bias_q15" => sc === nothing ? nothing : nn(sc.bias_q15),
                "corr_q15" => sc === nothing ? nothing : nn(sc.corr_q15),
                "shape_floor_q15" => sc === nothing ? nothing : nn(sc.shape_floor_q15),
                "gbm" => Any[get(mlmap, (zone, "hybrid_gbm", h), nothing) for h in hours],
                "stats" => Any[get(mlmap, (zone, "stats_gbm", h), nothing) for h in hours]),
                tsfm_fields(zone, d, hours, ovh, ovd)))
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
    act = da_target_actuals(sd - Day(1), ed)  # EUPHEMIA_DA_TARGET (default highest_seq)
    actmap = Dict{Tuple{String,DateTime},Float64}(
        (String(a.z), DateTime(a.t)) => Float64(a.act) for a in eachrow(act))

    mlmap = model_lines_map(sd)
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
