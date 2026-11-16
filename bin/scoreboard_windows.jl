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
