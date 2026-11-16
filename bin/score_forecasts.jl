#!/usr/bin/env julia
#
# Score realized forecasts (invoked by .github/workflows/daily-forecast.yml
# after bin/daily_forecast.jl).
#
# For every (market_date, lead_days, code_version, input_mode) slice in
# simulations.forecast_prices whose market day now has realized actual
# day-ahead prices and no forecast_scores row yet (or RESCORE=true), computes
# per-zone MAE, bias (sim − actual) and Pearson correlation over the day's
# hours and upserts into simulations.forecast_scores. The reference
# ('entsoe') and ex-ante ('weather') tracks are scored as separate slices —
# scores are per (date, zone, lead, cv, mode).
#
# Actuals methodology: resolution-aware, exactly the iteration-4 standard from
# test/scripts/eu_eval_metrics.jl (whose `resolution_aware_actuals` is reused
# directly): dedup entsoe.energy_prices to the latest `sequence` revision per
# (zone, timestamp), then average sub-hourly (PT15M/PT30M) prices into each
# hour — a no-op for hourly zones. The auction is selected by
# EUPHEMIA_DA_TARGET via `da_target_actuals` (#431): since 2026-11-17 the
# default (unset) is sdac = the SDAC auction only; highest_seq = the rule above
# (EXAA in AT/DE_LU) is the kill switch. This scorer rewrites only the last
# RESCORE_WINDOW_DAYS, so the flip shipped with one full hourly rescore
# (.github/workflows/rescore-hourly.yml, the env vars below) —
# see docs/experiments/sdac-target-2026-11/README.md.
#
# Native 15-minute scores (additive, phase 3): in the same pass, each zone-day
# also gets n_q15 / mae_q15 / bias_q15 / corr_q15 / shape_floor_q15 (+ ≤0
# quarter counts): the HOURLY forecast replicated x4 onto its quarters (or used
# as is when the slice is natively quarter-hourly — `q15_forecast_res` records
# which) against native PT15M SDAC actuals (`native_q15_actuals`: latest
# revision, EXAA sequence dropped for AT/DE_LU), quarters of the Athens market
# day only. Zone-days without native PT15M actuals (PT60M/PT30M zones) keep the
# q15 columns NULL. Written by a separate UPDATE after the unchanged hourly
# upsert, into nullable columns added by `ensure_q15_columns` — the hourly
# columns are byte-for-byte what they were.
#
# forecast_scores is STRICTLY for forecast_prices rows — never for the
# energy_prices backfill tables (those are scored by the eval scripts).
#
# Env vars:
#   RESCORE  'true' to recompute slices that already have scores
#   RESCORE_WINDOW_DAYS  recent days always rescored (default 7)
#   MIN_SCORE_Q15  minimum paired native quarters for a 15-min score (default 48)
#   Q15_ONLY  'true' = history backfill of the 15-min columns: every realized
#             slice, q15 UPDATE only — the hourly columns are never written
#             (so ENTSO-E revisions since a day was scored cannot move them)
# Hourly rescore (rescore-hourly.yml, #431 C2; all unset = the daily behaviour):
#   HOURLY_ONLY  'true' = hourly columns only; the q15 columns are never written
#   RESCORE_START / RESCORE_END  market-date bounds (inclusive) of the slices
#   RESCORE_ZONES  comma list of zones to (re)score (others are skipped)
#   DRY_RUN  'true' = print slice and existing-row counts, write nothing
#   SCORE_LOCK_TIMEOUT  e.g. '5s': each slice's upserts run in ONE transaction
#             under SET LOCAL lock_timeout (+ statement_timeout 120s), retried
#             3x with backoff, so the rescore never queues behind a long lock

using Euphemia, Dates, Statistics, Printf, DataFrames, LibPQ

include(joinpath(@__DIR__, "forecast_common.jl"))
# Reuse the shared resolution-aware actuals (guarded __main__, safe to include).
include(joinpath(@__DIR__, "..", "test", "scripts", "eu_eval_metrics.jl"))

const Q15_ONLY = lowercase(get(ENV, "Q15_ONLY", "false")) == "true"
const RESCORE = Q15_ONLY || lowercase(get(ENV, "RESCORE", "false")) == "true"
const RESCORE_WINDOW_DAYS = parse(Int, get(ENV, "RESCORE_WINDOW_DAYS", "7"))
const HOURLY_ONLY = lowercase(get(ENV, "HOURLY_ONLY", "false")) == "true"
const DRY_RUN = lowercase(get(ENV, "DRY_RUN", "false")) == "true"
_envdate(k) = (v = strip(get(ENV, k, ""))) == "" ? nothing : Date(v)
const RESCORE_START = _envdate("RESCORE_START")
const RESCORE_END = _envdate("RESCORE_END")
# both are interpolated into SQL: validated here, not only by the workflow
const RESCORE_ZONES = let v = strip(get(ENV, "RESCORE_ZONES", ""))
    zs = v == "" || lowercase(v) == "all" ? nothing : Set(String.(strip.(split(v, ","))))
    zs === nothing || all(z -> occursin(r"^[A-Za-z0-9_-]+$", z), zs) ||
        error("RESCORE_ZONES=$(repr(v)): expected a comma list of zone codes or 'all'")
    zs
end
const SCORE_LOCK_TIMEOUT = let v = strip(get(ENV, "SCORE_LOCK_TIMEOUT", ""))
    v == "" || occursin(r"^[0-9]+(ms|s)$", v) ||
        error("SCORE_LOCK_TIMEOUT=$(repr(v)): expected e.g. 5s or 500ms")
    v
end
Q15_ONLY && HOURLY_ONLY && error("Q15_ONLY and HOURLY_ONLY are mutually exclusive")
# Minimum paired hours for a (zone, day, lead) score to be persisted. Scores
# used to be written for ANY n >= 1 (IT-* zones scored on a single 21:00 hour
# when only four PT15M actual rows had landed) and then frozen by the
# NOT-EXISTS discovery, entering every board average with full weight.
const MIN_SCORE_HOURS = parse(Int, get(ENV, "MIN_SCORE_HOURS", "12"))
const MIN_SCORE_Q15 = parse(Int, get(ENV, "MIN_SCORE_Q15", string(MIN_SCORE_Q15_DEFAULT)))

"Nullable 15-minute score columns of simulations.forecast_scores (additive, idempotent)."
const Q15_COLUMNS = [("n_q15", "INT"), ("mae_q15", "DOUBLE PRECISION"),
                     ("bias_q15", "DOUBLE PRECISION"), ("corr_q15", "DOUBLE PRECISION"),
                     ("shape_floor_q15", "DOUBLE PRECISION"), ("q15_forecast_res", "TEXT"),
                     ("n_le0_q15_actual", "INT"), ("n_le0_q15_pred", "INT"),
                     ("le0_q15_hits", "INT")]

"""
    ensure_q15_columns() -> Bool

Catalog first: read which q15 columns `simulations.forecast_scores` lacks; in the
steady state none are missing and NO DDL is issued (an `ADD COLUMN IF NOT EXISTS`
on an existing column still takes ACCESS EXCLUSIVE and can queue behind a long
reader, blocking every later reader behind it). When some are missing, add them
in ONE transaction under `SET LOCAL lock_timeout = '5s'` (reset automatically at
COMMIT/ROLLBACK, so the connection keeps its default), mirroring
`ensure_forecast_tables`. Returns whether the q15 columns are available; a lock
timeout is NOT fatal — the hourly scoring proceeds and q15 is skipped this run.
"""
function ensure_q15_columns()
    Euphemia.withdb() do cnx
        have = Set(String.(DataFrame(LibPQ.execute(cnx, """
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = 'simulations' AND table_name = 'forecast_scores'
        """)).column_name))
        missing_cols = [(c, ty) for (c, ty) in Q15_COLUMNS if !(c in have)]
        isempty(missing_cols) && return true
        LibPQ.execute(cnx, "BEGIN")
        try
            LibPQ.execute(cnx, "SET LOCAL lock_timeout = '5s'")
            LibPQ.execute(cnx, "ALTER TABLE simulations.forecast_scores " *
                               join(("ADD COLUMN IF NOT EXISTS $c $ty" for (c, ty) in missing_cols), ", "))
            LibPQ.execute(cnx, "COMMIT")
            println("added q15 columns to simulations.forecast_scores: ",
                    join(first.(missing_cols), ", "))
            return true
        catch e
            try LibPQ.execute(cnx, "ROLLBACK") catch end
            @warn "could not add the q15 columns (lock timeout?) — hourly scoring continues, " *
                  "15-min scores skipped this run" exception = e
            return false
        end
    end
end

"Write one zone-day's 15-min score into the row the hourly upsert just wrote (NULLs when not native)."
function update_q15!(market_date::Date, zone::String, lead_days::Int, cv::Int,
                     input_mode::String, is_retro::Bool, q, res::String)
    nn(x) = x === nothing ? missing : x
    Euphemia.withdb() do cnx
        LibPQ.execute(cnx, """
            UPDATE simulations.forecast_scores
            SET n_q15 = \$1, mae_q15 = \$2, bias_q15 = \$3, corr_q15 = \$4,
                shape_floor_q15 = \$5, q15_forecast_res = \$6, n_le0_q15_actual = \$7,
                n_le0_q15_pred = \$8, le0_q15_hits = \$9
            WHERE market_date = \$10 AND bidding_zone = \$11 AND lead_days = \$12
              AND code_version = \$13 AND input_mode = \$14 AND is_retro = \$15
        """, Any[q.n_q15, nn(q.mae_q15), nn(q.bias_q15), nn(q.corr_q15),
                 nn(q.shape_floor_q15), res, nn(q.n_le0_q15_actual), nn(q.n_le0_q15_pred),
                 nn(q.le0_q15_hits), market_date, zone, lead_days, cv, input_mode, is_retro])
    end
end

"Compute + write one zone-day's 15-min score (into the existing hourly row) and log it."
function score_q15_zone!(market_date, zone, lead_days, cv, input_mode, is_retro, sub, a15, qwin)
    fq, fres = q15_forecast(DateTime.(sub.t), Float64.(sub.sim))
    za = get(a15, zone, (t=DateTime[], act=Float64[], res=String[]))
    q = score_q15(fq, za.t, za.act, za.res; window=qwin, min_n=MIN_SCORE_Q15)
    update_q15!(market_date, zone, lead_days, cv, input_mode, is_retro, q, fres)
    @printf("  %-12s q15 n=%3d MAE=%s shape=%s (%s forecast, %s)\n", zone, q.n_q15,
            q.mae_q15 === nothing ? "     -" : @sprintf("%6.1f", q.mae_q15),
            q.shape_floor_q15 === nothing ? "   -" : @sprintf("%4.1f", q.shape_floor_q15),
            fres == "PT60M" ? "hourly x4" : "native 15-min", q.q15_status)
    return q
end

"Native actuals of one market day grouped by zone: zone => (t, act, res)."
function q15_actuals_by_zone(market_date::Date)
    a = native_q15_actuals(market_date - Day(1), market_date)
    out = Dict{String,NamedTuple}()
    for z in unique(String.(a.z))
        sub = a[String.(a.z) .== z, :]
        out[z] = (t=DateTime.(sub.t), act=Float64.(sub.act), res=String.(sub.res))
    end
    return out
end

"""
Slices of forecast_prices whose market day has realized actual DA prices.
market_date is the Europe/Athens market day; its window's FINAL hours fall on
UTC calendar day market_date, so EXISTS over the UTC day remains a correct
readiness trigger (DA prices for a local delivery day publish as one batch —
when any UTC-day-D row exists, the full Athens window is available).
"""
function pending_slices()
    # Self-healing window: a slice can legitimately be REWRITTEN after it was
    # scored (e.g., the -500-tail fix regenerated 2026-07-12 but its stale
    # scores survived, showing DE_LU corr -0.01 against a chart at 0.97).
    # Always rescore recent days — upsert_score! makes this idempotent and the
    # window is a handful of slices, so the cost is negligible.
    rescore_clause = RESCORE ? "" : """
        AND (fp.market_date >= CURRENT_DATE - $(RESCORE_WINDOW_DAYS)
             OR NOT EXISTS (
            SELECT 1 FROM simulations.forecast_scores s
            WHERE s.market_date = fp.market_date
              AND s.lead_days = fp.lead_days
              AND s.code_version = fp.code_version
              AND s.input_mode = fp.input_mode
              AND s.is_retro = fp.is_retro))
    """
    # TWO-STEP discovery (2026-07-23). The old single query ran a correlated
    # EXISTS against 1.9 GB entsoe.energy_prices for each of the ~80k
    # forecast_prices rows (the actuals index leads on map_code, so a pure
    # date-range probe couldn't use it) — observed running 3.5 HOURS, eating
    # the daily run's timeout and (until the #170 lock guard) wedging the
    # table for every other client. Rewritten: distinct candidate slices from
    # the small forecast_prices first, then ONE bounded scan of the actuals
    # for realized market days, intersected in Julia. Same result set.
    slices = Euphemia.sql2df_with_retry("""
        SELECT DISTINCT fp.market_date, fp.lead_days, fp.code_version, fp.input_mode,
               fp.is_retro
        FROM simulations.forecast_prices fp
        WHERE TRUE
        $(RESCORE_START === nothing ? "" : "AND fp.market_date >= DATE '$(RESCORE_START)'")
        $(RESCORE_END === nothing ? "" : "AND fp.market_date <= DATE '$(RESCORE_END)'")
        $rescore_clause
        ORDER BY 1, 2
    """)
    isempty(slices) && return slices
    realized = Euphemia.sql2df_with_retry("""
        SELECT DISTINCT (date_time_utc AT TIME ZONE 'UTC')::date AS d
        FROM entsoe.energy_prices
        WHERE contract_type = 'Day-ahead'
          AND area_type_code LIKE 'BZN%'
          AND price_currency_mwh IS NOT NULL
          AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
    """, [minimum(slices.market_date)])
    realized_days = Set(realized.d)
    return slices[[d in realized_days for d in slices.market_date], :]
end

"Sim forecast rows of one slice, keyed (zone, naive-UTC hour)."
function slice_sim(market_date::Date, lead_days::Int, cv::Int, input_mode::String)
    return Euphemia.sql2df_with_retry("""
        SELECT bidding_zone AS z, (date_time_utc AT TIME ZONE 'UTC') AS t,
               price_eur_mwh AS sim
        FROM simulations.forecast_prices
        WHERE market_date = \$1 AND lead_days = \$2 AND code_version = \$3
          AND input_mode = \$4
        ORDER BY 1, 2
    """, [market_date, lead_days, cv, input_mode])
end

function upsert_score!(market_date::Date, zone::String, lead_days::Int, cv::Int,
                       input_mode::String, n::Int, mae, bias, corr, cm;
                       is_retro::Bool=false, reset_tag::Union{Nothing,String}=nothing,
                       cnx=nothing)
    tonull(x) = x === nothing ? missing : x
    cnx === nothing && return Euphemia.withdb() do c
        upsert_score!(market_date, zone, lead_days, cv, input_mode, n, mae, bias, corr, cm;
                      is_retro=is_retro, reset_tag=reset_tag, cnx=c)
    end
    begin
        LibPQ.execute(cnx, """
            INSERT INTO simulations.forecast_scores
            (market_date, bidding_zone, lead_days, code_version, input_mode,
             n_hours, mae, bias, corr,
             n_collapse_actual, n_collapse_pred, collapse_hits,
             collapse_false_alarms, collapse_hit_rate, collapse_false_alarm_rate,
             is_retro, reset_tag, scored_at)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9,
                    \$10, \$11, \$12, \$13, \$14, \$15, \$16, \$17, now())
            ON CONFLICT (market_date, bidding_zone, lead_days, code_version, input_mode, is_retro)
            DO UPDATE SET n_hours = EXCLUDED.n_hours, mae = EXCLUDED.mae,
                          bias = EXCLUDED.bias, corr = EXCLUDED.corr,
                          n_collapse_actual = EXCLUDED.n_collapse_actual,
                          n_collapse_pred = EXCLUDED.n_collapse_pred,
                          collapse_hits = EXCLUDED.collapse_hits,
                          collapse_false_alarms = EXCLUDED.collapse_false_alarms,
                          collapse_hit_rate = EXCLUDED.collapse_hit_rate,
                          collapse_false_alarm_rate = EXCLUDED.collapse_false_alarm_rate,
                          is_retro = EXCLUDED.is_retro, reset_tag = EXCLUDED.reset_tag,
                          scored_at = now()
        """, Any[market_date, zone, lead_days, cv, input_mode,
                 n, tonull(mae), tonull(bias), tonull(corr),
                 cm.n_collapse_actual, cm.n_collapse_pred, cm.hits,
                 cm.false_alarms, tonull(cm.hit_rate), tonull(cm.false_alarm_rate),
                 is_retro, reset_tag === nothing ? missing : reset_tag])
    end
end

"""
    write_slice!(rows)

Upsert one slice's hourly scores (`rows`: NamedTuples of `upsert_score!` args).
Without SCORE_LOCK_TIMEOUT: one autocommitted upsert per row, the daily behaviour.
With it (the rescore): ONE transaction per slice under `SET LOCAL lock_timeout`
and `statement_timeout` (reset at COMMIT/ROLLBACK, the #424 pattern), retried 3x
with backoff; a slice that still cannot get its locks fails the run, which is
resumable with RESCORE_START.
"""
function write_slice!(rows)
    isempty(rows) && return
    w(r; cnx=nothing) = upsert_score!(r.market_date, r.zone, r.lead_days, r.cv, r.input_mode,
                                      r.n, r.mae, r.bias, r.corr, r.cm; is_retro=r.is_retro,
                                      reset_tag=r.reset_tag, cnx=cnx)
    if isempty(SCORE_LOCK_TIMEOUT)
        foreach(w, rows)
        return
    end
    for attempt in 1:3
        ok = Euphemia.withdb() do cnx
            LibPQ.execute(cnx, "BEGIN")
            try
                LibPQ.execute(cnx, "SET LOCAL lock_timeout = '$(SCORE_LOCK_TIMEOUT)'")
                LibPQ.execute(cnx, "SET LOCAL statement_timeout = '120s'")
                foreach(r -> w(r; cnx=cnx), rows)
                LibPQ.execute(cnx, "COMMIT")
                true
            catch e
                try LibPQ.execute(cnx, "ROLLBACK") catch end
                attempt == 3 && rethrow()
                @warn "slice write failed (attempt $attempt/3), retrying" exception = e
                false
            end
        end
        ok && return
        sleep(10 * attempt)
    end
end

"Per input_mode × lead_days × zone aggregate over all stored scores (GR first, then AGG)."
function print_summary()
    df = Euphemia.sql2df_with_retry("""
        SELECT input_mode || CASE WHEN is_retro THEN '/retro' ELSE '' END AS mode,
               lead_days, bidding_zone AS z, COUNT(*) AS n_days,
               AVG(mae) AS mae, AVG(bias) AS bias, AVG(corr) AS corr
        FROM simulations.forecast_scores
        GROUP BY 1, 2, 3
        ORDER BY 1, 2, 3
    """)
    if isempty(df)
        println("\nNo forecast scores stored yet — summary empty.")
        return
    end
    fmt(x) = (x === missing || x === nothing) ? "      -" : @sprintf("%7.2f", x)
    println("\n### Forecast accuracy summary (per input_mode × lead_days × zone, all stored scores)")
    @printf("%-8s %-6s %-12s %7s %7s %8s %7s\n", "mode", "lead", "zone", "n_days", "MAE", "bias", "corr")
    for mode in sort(unique(String.(df.mode)))
        msub = df[df.mode .== mode, :]
        for lead in sort(unique(msub.lead_days))
            sub = msub[msub.lead_days .== lead, :]
            # GR first, then the rest alphabetically
            order = vcat(findall(sub.z .== "GR"), findall(sub.z .!= "GR"))
            for i in order
                r = sub[i, :]
                @printf("%-8s %-6d %-12s %7d %s %s %s\n", mode, lead, r.z, r.n_days,
                        fmt(r.mae), fmt(r.bias), fmt(r.corr))
            end
            # aggregate row across zones for this lead
            mae_v = collect(skipmissing(sub.mae))
            bias_v = collect(skipmissing(sub.bias))
            corr_v = collect(skipmissing(sub.corr))
            @printf("%-8s %-6d %-12s %7d %s %s %s\n", mode, lead, "AGG",
                    sum(sub.n_days),
                    fmt(isempty(mae_v) ? missing : mean(mae_v)),
                    fmt(isempty(bias_v) ? missing : mean(bias_v)),
                    fmt(isempty(corr_v) ? missing : mean(corr_v)))
        end
    end
end

"""
    dry_run_report(slices)

DRY_RUN: what a rescore over `slices` would touch — slices per lead and mode, and
the existing forecast_scores rows in the same range per zone (the rows whose
hourly columns would be rewritten). Reads only.
"""
function dry_run_report(slices)
    d0, d1 = extrema(Date.(slices.market_date))
    println("DRY_RUN slices: $(nrow(slices)) over market dates $d0..$d1")
    for g in groupby(sort(DataFrame(lead=slices.lead_days, mode=slices.input_mode)), [:mode, :lead])
        @printf("  mode=%-24s lead=%d  slices=%d\n", g.mode[1], g.lead[1], nrow(g))
    end
    zf = RESCORE_ZONES === nothing ? "" :
         "AND bidding_zone IN (" * join(("'$z'" for z in sort(collect(RESCORE_ZONES))), ",") * ")"
    ex = Euphemia.sql2df_with_retry("""
        SELECT bidding_zone AS z, COUNT(*) AS n FROM simulations.forecast_scores
        WHERE market_date BETWEEN \$1 AND \$2 $zf GROUP BY 1 ORDER BY 1
    """, [d0, d1])
    println("DRY_RUN existing forecast_scores rows in range (hourly columns would be rewritten): " *
            "$(sum(ex.n; init=0))")
    for r in eachrow(ex)
        @printf("  %-12s %d\n", r.z, r.n)
    end
    println("DRY_RUN: nothing written")
end

function main()
    println("=" ^ 70)
    println("SCORE FORECASTS  rescore=$RESCORE" * (Q15_ONLY ? "  Q15_ONLY (hourly columns untouched)" : "") *
            (HOURLY_ONLY ? "  HOURLY_ONLY (q15 columns untouched)" : "") * (DRY_RUN ? "  DRY_RUN" : ""))
    # Scoring-policy provenance: forecast_scores has no policy column, so the run
    # log (and the rescore workflow's summary) records it.
    println("TARGET_POLICY=$(Q15_ONLY ? "q15 native SDAC" : da_target_policy())" *
            (RESCORE_START === nothing && RESCORE_END === nothing ? "" :
             "  range=$(something(RESCORE_START, "first"))..$(something(RESCORE_END, "last"))") *
            (RESCORE_ZONES === nothing ? "" : "  zones=$(join(sort(collect(RESCORE_ZONES)), ","))"))
    println("=" ^ 70)

    DRY_RUN || Euphemia.ensure_forecast_tables()
    q15_ok = (HOURLY_ONLY || DRY_RUN) ? false : ensure_q15_columns()
    Q15_ONLY && !q15_ok && error("Q15_ONLY: the q15 columns are missing and could not be added")

    slices = pending_slices()
    if isempty(slices)
        println("No realized, unscored forecast slices — nothing to score.")
        DRY_RUN || print_summary()
        return
    end
    println("$(nrow(slices)) slice(s) to score")
    DRY_RUN && return dry_run_report(slices)
    q15_cache = Dict{Date,Dict{String,NamedTuple}}()

    for r in eachrow(slices)
        market_date = Date(r.market_date)
        lead_days = Int(r.lead_days)
        cv = Int(r.code_version)
        input_mode = String(r.input_mode)
        is_retro = "is_retro" in names(slices) && !ismissing(r.is_retro) && Bool(r.is_retro)
        # reset_tag is uniform within a slice — read one row's value.
        reset_tag = let rt = Euphemia.sql2df_with_retry("""
                SELECT MAX(reset_tag) AS t FROM simulations.forecast_prices
                WHERE market_date = \$1 AND lead_days = \$2 AND code_version = \$3
                  AND input_mode = \$4
            """, [market_date, lead_days, cv, input_mode])
            (isempty(rt) || ismissing(rt.t[1])) ? nothing : String(rt.t[1])
        end
        println("\nScoring market_date=$market_date lead_days=$lead_days cv=$cv mode=$input_mode" *
                (is_retro ? " [RETRO $(reset_tag)]" : ""))

        sim = slice_sim(market_date, lead_days, cv, input_mode)
        # market_date is the Europe/Athens market day: its window starts at
        # 21:00/22:00 UTC on market_date-1, so actuals must cover BOTH UTC days.
        # (Q15_ONLY skips the hourly actuals: they are not used.)
        act = Q15_ONLY ? DataFrame(z=String[], t=DateTime[], act=Float64[]) :
              da_target_actuals(market_date - Day(1), market_date)  # EUPHEMIA_DA_TARGET
        actmap = Dict{Tuple{String,DateTime},Float64}(
            (String(a.z), DateTime(a.t)) => Float64(a.act) for a in eachrow(act))
        a15 = q15_ok ? get!(() -> q15_actuals_by_zone(market_date), q15_cache, market_date) :
              Dict{String,NamedTuple}()
        qwin = athens_day_quarters(market_date)

        batch = NamedTuple[]
        for zone in sort(unique(String.(sim.z)))
            RESCORE_ZONES === nothing || zone in RESCORE_ZONES || continue
            sub = sim[sim.z .== zone, :]
            if Q15_ONLY   # history backfill: q15 columns only, on rows the hourly scorer wrote
                score_q15_zone!(market_date, zone, lead_days, cv, input_mode, is_retro, sub, a15, qwin)
                continue
            end
            sv = Float64[]; av = Float64[]
            for row in eachrow(sub)
                k = (zone, trunc(DateTime(row.t), Hour))
                haskey(actmap, k) || continue
                push!(sv, Float64(row.sim)); push!(av, actmap[k])
            end
            if isempty(sv)
                println("  $zone: no realized actual prices for this day — skipped")
                continue
            elseif length(sv) < MIN_SCORE_HOURS
                println("  $zone: only $(length(sv)) paired hour(s) (< MIN_SCORE_HOURS=$MIN_SCORE_HOURS) — " *
                        "not scored yet (rescored when the actuals complete)")
                continue
            end
            s = score_series(sv, av)
            cm = collapse_metrics(sv, av)   # SCIENTIST.md §4, threshold ≤ €5
            row = (market_date=market_date, zone=zone, lead_days=lead_days, cv=cv,
                   input_mode=input_mode, n=s.n, mae=s.mae, bias=s.bias, corr=s.corr, cm=cm,
                   is_retro=is_retro, reset_tag=reset_tag)
            # daily: written now, so the q15 UPDATE below finds the row; rescore: batched
            isempty(SCORE_LOCK_TIMEOUT) ? write_slice!([row]) : push!(batch, row)
            corr_str = s.corr === nothing ? "-" : @sprintf("%.2f", s.corr)
            @printf("  %-12s n=%2d MAE=%6.1f bias=%+7.1f corr=%s  collapse[act=%d pred=%d hit=%d FA=%d]\n",
                    zone, s.n, s.mae, s.bias, corr_str,
                    cm.n_collapse_actual, cm.n_collapse_pred, cm.hits, cm.false_alarms)
            q15_ok && score_q15_zone!(market_date, zone, lead_days, cv, input_mode, is_retro, sub, a15, qwin)
        end
        write_slice!(batch)
    end

    print_summary()
    println("\nSCORING COMPLETE")
end

main()
