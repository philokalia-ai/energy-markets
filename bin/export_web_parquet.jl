#!/usr/bin/env julia
#
# Export the daily-forecast SPA data contract as PARQUET to a staging dir
# (default data/web/v1), for upload to the R2 bucket `euphemia-web-data`
# via bin/web_data_push.sh (issue #152 — live data backend).
#
# RECORD SPANS VERSIONS (honesty note): the exported record is the product's
# full history across code versions — slice identity is (market_date,
# lead_days, input_mode); code_version is per-row PROVENANCE, not a display
# filter. Where a slice exists under more than one code_version, the
# EARLIEST-FROZEN slice wins (slice-level MIN(prediction_made_utc) — the first
# commitment is the honest ex-ante vintage); see CHOSEN_SLICE_CTE in
# bin/forecast_common.jl. The manifest's "code_version" is the CURRENT model
# version; each zone-parquet row carries the code_version that produced it.
#
# Layout (the /v1/ public data API — stable; schema changes bump /v2/):
#
#   v1/zones/<ZONE>.parquet   one row per (market_date, lead_days, input_mode,
#                             delivery hour): market_date DATE, lead_days INT,
#                             input_mode VARCHAR, code_version INT (provenance,
#                             additive column), prediction_made_utc TIMESTAMP,
#                             date_time_utc TIMESTAMP, sim DOUBLE,
#                             actual DOUBLE (null until settled), and the
#                             day-level scores mae/bias/corr DOUBLE (null until
#                             scored; repeated on each hourly row).
#   v1/scoreboard.parquet     zone, lead_days, window ("all" | "YYYY-MM"),
#                             input_mode, n_days, mae, bias, corr.
#   v1/map.parquet            market_date, zone, track, sim, act, err_pct, mae,
#                             corr, lead, made — freshest-lead day aggregates,
#                             BOTH tracks (track = 'predicted' | 'announced';
#                             the global lens), matching web/data/map.json.
#                             err_pct = load-weighted WAPE % (null until the day
#                             fully settles / when the denominator is degenerate).
#   v1/manifest.json          {updated_at, code_version, market_day_tz, zones,
#                              row_counts, tracks, track_freshness} — freshness,
#                              discovery + the two-track lens.
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
        # code_version is per-cell PROVENANCE for the SAME-CV pairing guard: the
        # cross-track gap chip may only compare two aggregates cleared under the
        # SAME model version. A single value when the cell is single-cv, else
        # missing (mixed) so the SPA shows the chip as "n/a (cv mismatch)".
        cvs = unique(Int.(sub.cv))
        (n_days=length(unique(sub.market_date)),
         mae=isempty(mae_v) ? missing : mean(mae_v),
         bias=isempty(bias_v) ? missing : mean(bias_v),
         corr=isempty(corr_v) ? missing : mean(corr_v),
         cv=length(cvs) == 1 ? cvs[1] : missing)
    end

    df = DataFrame(zone=String[], lead_days=Int[], window=String[],
                   input_mode=String[], n_days=Int[],
                   mae=Union{Missing,Float64}[], bias=Union{Missing,Float64}[],
                   corr=Union{Missing,Float64}[], code_version=Union{Missing,Int}[])
    if !isempty(scores)
        for zlm in unique(collect(zip(String.(scores.z), Int.(scores.lead_days),
                                      String.(scores.mode))))
            zone, lead, mode = zlm
            sub = scores[(scores.z .== zone) .& (scores.lead_days .== lead) .&
                         (scores.mode .== mode), :]
            a = agg(sub)
            push!(df, (zone, lead, "all", mode, a.n_days,
                       nm(a.mae), nm(a.bias), nm(a.corr), a.cv))
            for month in sort(unique(String.(sub.month)))
                m = sub[sub.month .== month, :]
                am = agg(m)
                push!(df, (zone, lead, month, mode, am.n_days,
                           nm(am.mae), nm(am.bias), nm(am.corr), am.cv))
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
    # Cross-version record: one chosen slice per (market_date, lead_days,
    # input_mode), earliest-frozen-wins; code_version carried as provenance.
    prices = Euphemia.sql2df_with_retry("""
        WITH $(CHOSEN_SLICE_CTE)
        SELECT p.bidding_zone AS z, p.market_date, p.lead_days, p.input_mode AS mode,
               p.code_version AS cv,
               (p.date_time_utc AT TIME ZONE 'UTC') AS t,
               p.price_eur_mwh AS sim,
               (p.prediction_made_utc AT TIME ZONE 'UTC') AS made,
               p.is_retro, p.reset_tag
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
        println("no forecast_prices rows — no zone parquets written")
        return Dict{String,Int}()
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

    counts = Dict{String,Int}()
    for zone in sort(unique(String.(prices.z)))
        zp = prices[prices.z .== zone, :]
        df = DataFrame(market_date=Date[], lead_days=Int[], input_mode=String[],
                       code_version=Int[],
                       prediction_made_utc=DateTime[], date_time_utc=DateTime[],
                       sim=Float64[], actual=Union{Missing,Float64}[],
                       mae=Union{Missing,Float64}[], bias=Union{Missing,Float64}[],
                       corr=Union{Missing,Float64}[],
                       is_retro=Bool[], reset_tag=Union{Missing,String}[])
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
            slice_cv = Int(sub.cv[1])
            slice_retro = !ismissing(sub.is_retro[1]) && Bool(sub.is_retro[1])
            slice_tag = ismissing(sub.reset_tag[1]) ? missing : String(sub.reset_tag[1])
            for r in eachrow(sub)
                h = DateTime(r.t)
                push!(df, (d, lead, mode, slice_cv, made, h, Float64(r.sim),
                           get(actmap, (zone, h), missing), mae, bias, corr,
                           slice_retro, slice_tag))
            end
        end
        counts["zones/$zone.parquet"] =
            write_parquet(df, joinpath(V1_DIR, "zones", "$zone.parquet"))
    end
    println("wrote $(length(counts)) zone parquets to v1/zones/")
    return counts
end

# ---------------------------------------------------------------------------
# map.parquet — day aggregates per zone, BOTH tracks (the global Predicted /
# As-announced lens). `track` column: 'predicted' (input_mode LIKE 'weather%')
# or 'announced' (everything else). Freshest lead per (zone, market_date, track).
# ---------------------------------------------------------------------------
map_track_expr(col) = "CASE WHEN $(col) LIKE 'weather%' THEN 'predicted' ELSE 'announced' END"

function export_map_parquet()
    # Cross-version record: rows come from the chosen (earliest-frozen) slice
    # per (market_date, lead_days, input_mode); freshest lead computed per track.
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
        println("no forecast_prices rows — no map.parquet written")
        return 0
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
    # Hourly D-1 load forecast: the weights of err_pct (load-weighted WAPE).
    loads = Euphemia.sql2df_with_retry(HOURLY_LOAD_FC_SQL, [sd - Day(1), ed + Day(1)])
    loadmap = Dict{Tuple{String,DateTime},Float64}(
        (String(r.z), DateTime(r.t)) => Float64(r.load_mw) for r in eachrow(loads))

    df = DataFrame(market_date=Date[], zone=String[], track=String[], sim=Float64[],
                   act=Union{Missing,Float64}[], err_pct=Union{Missing,Float64}[],
                   mae=Union{Missing,Float64}[],
                   corr=Union{Missing,Float64}[], lead=Int[], made=DateTime[])
    for d in sort(unique(Date.(prices.market_date)))
        sub = prices[Date.(prices.market_date) .== d, :]
        for track in sort(unique(String.(sub.track)))
            st = sub[String.(sub.track) .== track, :]
            for zone in sort(unique(String.(st.z)))
                zp = st[st.z .== zone, :]
                hours = [DateTime(t) for t in zp.t]
                acts = [get(actmap, (zone, h), nothing) for h in hours]
                settled = Float64[a for a in acts if a !== nothing]
                lead = Int(zp.lead_days[1])
                sc = get(scoremap, (zone, d, lead, track), nothing)
                # err_pct: only for fully-settled days with full load coverage
                # (the metric is undefined otherwise — never fabricated).
                loadv = [get(loadmap, (zone, h), nothing) for h in hours]
                ep = (length(settled) == length(hours) && all(!isnothing, loadv)) ?
                    load_weighted_err_pct(Float64.(zp.sim), settled, Float64.(loadv)) :
                    nothing
                push!(df, (d, zone, track,
                           round(mean(Float64.(zp.sim)); digits=2),
                           length(settled) == length(hours) ?
                               round(mean(settled); digits=2) : missing,
                           ep === nothing ? missing : round(ep; digits=2),
                           sc === nothing ? missing : nm(sc.mae),
                           sc === nothing ? missing : nm(sc.corr),
                           lead, DateTime(zp.made[1])))
            end
        end
    end
    n = write_parquet(df, joinpath(V1_DIR, "map.parquet"))
    println("wrote v1/map.parquet ($n zone-day-track rows)")
    return n
end

# ---------------------------------------------------------------------------
# Per-track freshness for the manifest: latest market_date + scored-day count
# per track, so the SPA can surface honest per-track presence/recency.
# ---------------------------------------------------------------------------
function track_freshness()
    df = Euphemia.sql2df_with_retry("""
        SELECT $(map_track_expr("input_mode")) AS track,
               COUNT(DISTINCT market_date) AS n_days,
               MAX(market_date) AS latest_market_date,
               MIN(lead_days) AS min_lead, MAX(lead_days) AS max_lead
        FROM simulations.forecast_prices
        GROUP BY 1
    """)
    out = Dict{String,Any}()
    for r in eachrow(df)
        out[String(r.track)] = Dict(
            "n_days" => Int(r.n_days),
            "latest_market_date" => Dates.format(Date(r.latest_market_date), "yyyy-mm-dd"),
            "min_lead" => Int(r.min_lead),
            "max_lead" => Int(r.max_lead),
        )
    end
    return out
end

function main()
    println("=" ^ 70)
    println("EXPORT WEB PARQUET  cv=$CV  out=$V1_DIR")
    println("=" ^ 70)
    mkpath(V1_DIR)
    zones, n_scores = export_scoreboard_parquet()
    zone_counts = export_zone_parquets()
    n_map = export_map_parquet()

    # v1/units.parquet — static unit reference (code -> name/fuel/firm) for the
    # order-book view. ADDITIVE and NON-FATAL: a registry hiccup must never fail
    # the forecast data export. bin/web_data_push.sh's root `for f in v1/*.parquet`
    # loop picks it up (additive cp, outside the destructive sync scope).
    n_units = 0
    try
        include(joinpath(@__DIR__, "export_units_parquet.jl"))  # defines export_units_parquet
        # invokelatest: the include happens inside this function body, so a
        # direct call sees a pre-include world (MethodError at runtime —
        # exactly what the non-fatal warn swallowed in run 30704653032).
        n_units = Base.invokelatest(export_units_parquet, V1_DIR)
    catch e
        @warn "units export failed (web data unaffected)" exception = (e, catch_backtrace())
    end

    # v1/flows/<date>.parquet — coupled cross-border flows for the Order-book
    # TRADE WEDGE. ADDITIVE and NON-FATAL. Only record/backfill days persist
    # transmission_flows (the daily forecast run does not), so this writes files
    # only for dates in the recent window that actually have flows — dormant on
    # pure-forecast windows until the persist-forecast-flows follow-up. invokelatest
    # for the same in-function-include world-age reason as units above.
    n_flows = 0
    try
        include(joinpath(@__DIR__, "export_flows_parquet.jl"))  # defines export_flows_parquet
        n_flows = Base.invokelatest(export_flows_parquet, V1_DIR;
            dates=collect((Dates.today() - Day(MAX_DAYS)):Day(1):Dates.today()))
    catch e
        @warn "flows export failed (web data unaffected)" exception = (e, catch_backtrace())
    end

    updated_at = get(ENV, "UPDATED_AT", Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SS") * "Z")
    counts = Dict{String,Any}("scoreboard.parquet" => n_scores,
                              "map.parquet" => n_map,
                              "units.parquet" => n_units,
                              "flows" => n_flows)
    for (k, v) in zone_counts
        counts[k] = v
    end
    # data_reset (pre-gate/7-lead γ): summarize the retro-reconstruction campaign
    # so the SPA can render the reset notice ("Data reset at 1 Aug 2026,
    # retroactively"). ADDITIVE — absent-null on a record with no retro rows.
    # Retro rows are additive gap-fills; genuine live vintages are preserved and
    # are NOT flagged here.
    data_reset = nothing
    try
        rs = Euphemia.sql2df_with_retry("""
            SELECT reset_tag AS tag, COUNT(DISTINCT (market_date, lead_days)) AS n_slices,
                   MIN(market_date) AS d0, MAX(market_date) AS d1,
                   COUNT(DISTINCT lead_days) AS n_leads
            FROM simulations.forecast_prices
            WHERE is_retro = true AND reset_tag IS NOT NULL
            GROUP BY reset_tag ORDER BY 2 DESC LIMIT 1
        """)
        if !isempty(rs)
            data_reset = Dict(
                "reset_tag" => String(rs.tag[1]),
                "label" => "Data reset at 1 Aug 2026, retroactively",
                "retro_slices" => Int(rs.n_slices[1]),
                "leads" => Int(rs.n_leads[1]),
                "window_start" => Dates.format(Date(rs.d0[1]), "yyyy-mm-dd"),
                "window_end" => Dates.format(Date(rs.d1[1]), "yyyy-mm-dd"),
                "note" => "Retro rows are ex-ante reconstructions (historical " *
                          "previous_dayN weather vintages) filling gaps in the " *
                          "live record; genuine live vintages are preserved.",
            )
        end
    catch e
        @warn "data_reset manifest summary failed (web data unaffected)" exception = (e, catch_backtrace())
    end
    # Track discovery + per-track freshness for the global Predicted / As-announced
    # lens. ADDITIVE and NON-FATAL — a query hiccup must never fail the export.
    track_fresh = Dict{String,Any}()
    try
        track_fresh = track_freshness()
    catch e
        @warn "track freshness summary failed (web data unaffected)" exception = (e, catch_backtrace())
    end
    manifest = Dict(
        "updated_at" => updated_at,
        "code_version" => CV,
        "market_day_tz" => "Europe/Athens",
        "zones" => zones,
        "row_counts" => counts,
        "data_reset" => data_reset,
        # The global track lens: the two tracks the SPA switch offers + their
        # freshness. Both tracks are carried in every zones/scoreboard parquet
        # (input_mode column) and in map.parquet (track column).
        "tracks" => ["predicted", "announced"],
        "track_freshness" => track_fresh,
        "schema" => "v1",
    )
    open(joinpath(V1_DIR, "manifest.json"), "w") do io
        json_write(io, manifest)
    end
    println("wrote v1/manifest.json (updated_at=$updated_at)")
    println("EXPORT COMPLETE")
end

main()
