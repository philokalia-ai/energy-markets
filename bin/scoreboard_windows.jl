# The "since freeze" scoreboard window (#431 PR G; owner decision 2026-11-16).
#
# Included by bin/export_forecast_json.jl and bin/export_web_parquet.jl after
# bin/naive_baselines.jl. Export-side only: no DDL, no stored-score change.
#
# THE FREEZE RULE: the 43 characteristics (40 price-informed) are frozen from the cv44
# adoption, 2026-11-15. Any change to a price-informed characteristic bumps
# code_version and restarts the clock — update FREEZE_CODE_VERSION / FREEZE_DATE
# here AND the label in web/app.js (FREEZE_LABEL) together when that happens.
# Scores in this window are the only out-of-sample physics record: the
# characteristics were fixed before any of these market days were priced.
#
# Window "since_freeze": per board cohort (zone, lead, input_mode), the chosen-slice
# scores with code_version >= FREEZE_CODE_VERSION and market_date >= FREEZE_DATE,
# aggregated exactly like "all" and the months (n_days, mae/bias/corr, q15 fields,
# and the #437 naive fields on the same zone-days — so it follows the scorer's
# actuals function, `da_target_actuals` / EUPHEMIA_DA_TARGET). Cohorts with no row in
# the window are absent. The export emits any n_days >= 1; the site shows
# "insufficient data" below FREEZE_MIN_DAYS.
#
# Non-fatal: a failure logs a warning and the board is exported without the window.
# Kill switch: EXPORT_SINCE_FREEZE=0.

const SINCE_FREEZE_WINDOW = "since_freeze"
const FREEZE_CODE_VERSION = 44
const FREEZE_DATE = Date(2026, 11, 15)
"Minimum scored days before the site shows since-freeze numbers (display rule only)."
const FREEZE_MIN_DAYS = 14

"Whether the since-freeze window is exported (`EXPORT_SINCE_FREEZE=0` switches it off)."
since_freeze_enabled() = get(ENV, "EXPORT_SINCE_FREEZE", "1") != "0"

"Rows of a score frame (columns `cv`, `market_date`) inside the freeze window."
since_freeze_rows(scores::AbstractDataFrame) =
    scores[(Int.(scores.cv) .>= FREEZE_CODE_VERSION) .& (Date.(scores.market_date) .>= FREEZE_DATE), :]

"""
    since_freeze_entries(build, scores) -> Vector{Any}

For every board cohort (zone, lead, input_mode) with rows in the freeze window,
`build(zone, lead, mode, rows)` -> one board entry. Empty when switched off, when
no row is in the window, or when anything fails (a warning is logged and NO
since-freeze entry is returned — never a partial window, never a failed export).
"""
function since_freeze_entries(build, scores::AbstractDataFrame)
    since_freeze_enabled() || (println("since-freeze window: skipped (EXPORT_SINCE_FREEZE=0)"); return Any[])
    try
        out = Any[]
        isempty(scores) && return out
        f = since_freeze_rows(scores)
        for (zone, lead, mode) in unique(zip(String.(f.z), Int.(f.lead_days), String.(f.mode)))
            sub = f[(f.z .== zone) .& (f.lead_days .== lead) .& (f.mode .== mode), :]
            push!(out, build(zone, lead, mode, sub))
        end
        nd = isempty(f) ? 0 : length(unique(f.market_date))
        println("since-freeze window (cv >= $FREEZE_CODE_VERSION, from $FREEZE_DATE): " *
                "$(length(out)) cohorts, $nd market day(s)")
        return out
    catch e
        @warn "since-freeze window failed — board exported without it" exception = (e, catch_backtrace())
        return Any[]
    end
end

# ---------------------------------------------------------------------------
# The "backfilled" window (#431 R1; owner decision 2026-11-16).
#
# The cv44 physics lead-1 weather-track RECONSTRUCTION of 2026-09-14..2026-11-15
# (bin/daily_forecast.jl run_retro, reset_tag BACKFILL_RESET_TAG, written alongside
# the live slices; scored into its own is_retro=true score rows). It is IN-SAMPLE:
# the cv44 characteristics were calibrated on data that overlaps these days. So it is
# published only as this separate window — never pooled into "all", the months or
# "since_freeze" (those read live rows only, `live_only_sql`).
#
# Per cohort (zone, lead 1, input_mode): n_days, mae/bias/corr, the q15 fields, the
# #437 naive fields (same paired-cell rules, on the campaign's own sim rows),
# code_version 44, and "reconstructed_utc" (the reconstruction date, YYYY-MM-DD).
# EXTENSION POINT (R2, tsfm): `backfilled_extra_fields` returns the Timestral fields
# for a cohort; it returns nothing today.
#
# Non-fatal and all-or-nothing (warning, window omitted). Kill switch EXPORT_BACKFILLED=0.

const BACKFILLED_WINDOW = "backfilled"
const BACKFILL_RESET_TAG = "cv44-backfill-2026-11"
const BACKFILL_CODE_VERSION = 44
const BACKFILL_LEAD = 1

"Whether the backfilled window is exported (`EXPORT_BACKFILLED=0` switches it off)."
backfilled_enabled() = get(ENV, "EXPORT_BACKFILLED", "1") != "0"

"""
    backfilled_extra_fields(zone, lead, mode, rows) -> Dict{String,Any}

EXTENSION POINT for R2 (tsfm): additional per-cohort fields of the backfilled
window (e.g. the reconstructed Timestral MAE / rMAE on the same zone-days). Empty
today; whatever it returns is merged into the JSON entry. A parquet column needs
the matching addition in export_web_parquet.jl and workers/api/src/shape.js.
"""
backfilled_extra_fields(zone, lead, mode, rows) =
    # R2 (#431, bin/tsfm_backfill_scores.jl): the Timestral fields, when that file is included
    # (both exporters include it; pure tests of this file may not).
    isdefined(@__MODULE__, :tsfm_backfill_cohort_fields) ?
        tsfm_backfill_cohort_fields(zone, lead, rows) : Dict{String,Any}()

"""
    backfilled_cohorts(build, scores, parts, reconstructed) -> Vector{Any}

Pure: one `build(zone, lead, mode, rows, parts, reconstructed)` per (zone, lead,
input_mode) cohort of the campaign's score rows.
"""
function backfilled_cohorts(build, scores::AbstractDataFrame, parts, reconstructed)
    out = Any[]
    isempty(scores) && return out
    for (zone, lead, mode) in unique(zip(String.(scores.z), Int.(scores.lead_days), String.(scores.mode)))
        sub = scores[(scores.z .== zone) .& (scores.lead_days .== lead) .& (scores.mode .== mode), :]
        push!(out, build(zone, lead, mode, sub, parts, reconstructed))
    end
    return out
end

"""
    backfilled_entries(build; load=backfilled_load) -> Vector{Any}

The backfilled window behind the kill switch and a non-fatal guard: `load()` reads
the campaign's score rows, naive parts and reconstruction date; `build` makes one
board entry per cohort (see `backfilled_cohorts`). Any failure -> warning, no entry.
"""
function backfilled_entries(build; load=backfilled_load)
    backfilled_enabled() || (println("backfilled window: skipped (EXPORT_BACKFILLED=0)"); return Any[])
    try
        sc, parts, made = load()
        out = backfilled_cohorts(build, sc, parts, made)
        println("backfilled window ($BACKFILL_RESET_TAG, cv$BACKFILL_CODE_VERSION, lead $BACKFILL_LEAD): " *
                "$(length(out)) cohorts, $(isempty(sc) ? 0 : length(unique(sc.market_date))) market day(s)" *
                (made === nothing ? "" : ", reconstructed $made"))
        return out
    catch e
        @warn "backfilled window failed — board exported without it" exception = (e, catch_backtrace())
        return Any[]
    end
end

"DB step of the backfilled window: (score rows, naive parts or nothing, reconstruction date or nothing)."
function backfilled_load()
    sc = Euphemia.sql2df_with_retry("""
        SELECT s.bidding_zone AS z, s.lead_days, s.input_mode AS mode,
               to_char(s.market_date, 'YYYY-MM') AS month,
               s.market_date, s.code_version AS cv, s.mae, s.bias, s.corr,
               $(q15_select("s"))
        FROM simulations.forecast_scores s
        WHERE s.is_retro = true AND s.reset_tag = \$1 AND s.code_version = \$2
          AND s.lead_days = \$3
    """, [BACKFILL_RESET_TAG, BACKFILL_CODE_VERSION, BACKFILL_LEAD])
    isempty(sc) && return (sc, nothing, nothing)
    parts = nothing
    if naive_enabled()
        try
            parts = naive_zone_day_parts(sc; reset_tag=BACKFILL_RESET_TAG, code_version=BACKFILL_CODE_VERSION)
        catch e
            @warn "backfilled naive baselines failed — window exported without naive fields" exception = (e, catch_backtrace())
        end
    end
    m = Euphemia.sql2df_with_retry("""
        SELECT MAX(prediction_made_utc AT TIME ZONE 'UTC') AS made FROM simulations.forecast_prices
        WHERE is_retro = true AND reset_tag = \$1 AND code_version = \$2
    """, [BACKFILL_RESET_TAG, BACKFILL_CODE_VERSION])
    made = (isempty(m) || ismissing(m.made[1])) ? nothing : Dates.format(Date(DateTime(m.made[1])), "yyyy-mm-dd")
    return (sc, parts, made)
end
