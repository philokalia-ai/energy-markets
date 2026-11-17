# Timestral fields for the "backfilled" scoreboard window (#431 R2; the window itself is R1's).
#
# Included by bin/export_forecast_json.jl and bin/export_web_parquet.jl AFTER
# bin/naive_baselines.jl (it reuses `naive_zone_day` / `naive_board_fields` and the scorer's
# actuals `da_target_actuals`). Export-side only: no DDL, no stored-score change.
#
# WHAT IT SCORES: the backfill vintages written by `emit_tsfm_overlay.py --backfill-tag TAG`
# (simulations.tsfm_overlay, input_mode 'postsim_backfill', model_version '<arm>@<TAG>'), hourly
# tsfm_median, lead 1. Cells are the hours where BOTH the cv44 retro physics row of the same tag
# (simulations.forecast_prices is_retro AND reset_tag = TAG, lead 1, weather) and the Timestral
# median exist and the actual is finite, and every lead-1 naive (d1, d7, epf) exists — the #437
# common-mask rule, so the Timestral MAE and its naives are paired on the same cells and those
# cells are a subset of the physics backfill's own.
#
# WIRING: R1's `backfilled_extra_fields(zone, lead, mode, rows)` (bin/scoreboard_windows.jl)
# delegates to `tsfm_backfill_cohort_fields`, which loads every zone-day ONCE per export
# (cached by tag) and pools the cohort's market days. The JSON exporter merges the fields into
# the entry; the parquet exporter adds them as columns (TSFM_BACKFILL_BOARD_COLS) on the
# backfilled rows; workers/api/src/shape.js passes them through. Fields, all prefixed tsfm_:
# tsfm_arm, tsfm_n_days, tsfm_n, tsfm_mae, tsfm_mae_naive_{d1,d7,epf}, tsfm_rmae_{d1,d7,epf}.
# An empty Dict (no fields) when switched off (EXPORT_TSFM_BACKFILL=0), when no backfill rows
# exist, or when anything fails — the board is then exported exactly as without this file.

const TSFM_BACKFILL_ARM = "timestral-209m"
const TSFM_BACKFILL_BOARD_COLS = ("tsfm_arm", "tsfm_n_days", "tsfm_n", "tsfm_mae", "tsfm_mae_naive_d1",
                                  "tsfm_mae_naive_d7", "tsfm_mae_naive_epf", "tsfm_rmae_d1",
                                  "tsfm_rmae_d7", "tsfm_rmae_epf")

"Whether the Timestral backfill fields are exported (`EXPORT_TSFM_BACKFILL=0` switches them off)."
tsfm_backfill_enabled() = get(ENV, "EXPORT_TSFM_BACKFILL", "1") != "0"

"model_version of the backfill vintage built from reset_tag `tag` (as emit_tsfm_overlay.backfill_label)."
tsfm_backfill_label(tag::AbstractString; arm::AbstractString=TSFM_BACKFILL_ARM) = "$(arm)@$(tag)"

"""
    tsfm_backfill_zone_day(tsfm_t, tsfm_v, phys_hours, act, loc, market_date) -> NamedTuple

`naive_zone_day` (lead 1) on the Timestral hours that also carry a retro physics row
(`phys_hours`, a Set of UTC hour starts of this zone-day).
"""
function tsfm_backfill_zone_day(tsfm_t::AbstractVector, tsfm_v::AbstractVector, phys_hours,
                                act::AbstractDict, loc::AbstractDict, market_date::Date)
    keep = [trunc(DateTime(t), Hour) in phys_hours for t in tsfm_t]
    return naive_zone_day(tsfm_t[keep], tsfm_v[keep], act, loc, market_date, 1)
end

"""
    tsfm_backfilled_fields(parts, zone, dates; label) -> Dict{String,Any}

Pool the zone-day parts of `zone` over `dates` into the tsfm_* board fields (empty when
`parts === nothing` or no zone-day of the cohort has a backfill vintage).
"""
function tsfm_backfilled_fields(parts, zone::AbstractString, dates; label=nothing)
    parts === nothing && return Dict{String,Any}()
    ps = NamedTuple[]
    for d in unique(Date.(dates))
        p = get(parts, (String(zone), d), nothing)
        p === nothing || push!(ps, p)
    end
    isempty(ps) && return Dict{String,Any}()
    f = naive_board_fields(ps, 1)
    out = Dict{String,Any}("tsfm_n_days" => count(p -> p.n > 0, ps), "tsfm_n" => f["n_naive"],
                           "tsfm_mae" => f["mae_paired"])
    for k in NAIVE_KINDS
        out["tsfm_mae_naive_$k"] = f["mae_naive_$k"]
        out["tsfm_rmae_$k"] = f["rmae_$k"]
    end
    label === nothing || (out["tsfm_arm"] = label)
    return out
end

"""
    tsfm_backfill_parts(tag, rows; arm) -> Dict{(zone, market_date), NamedTuple}

DB step: Timestral backfill medians of `tsfm_backfill_label(tag)`, the retro physics hours of
`tag`, and the scorer's actuals, over the zone-days of `rows` (columns z, market_date).
"""
function tsfm_backfill_parts(tag::AbstractString, rows::Union{Nothing,AbstractDataFrame}=nothing;
                             arm=TSFM_BACKFILL_ARM)
    parts = Dict{Tuple{String,Date},NamedTuple}()
    rows !== nothing && isempty(rows) && return parts
    ts = Euphemia.sql2df_with_retry("""
        SELECT bidding_zone AS z, market_date, (date_time_utc AT TIME ZONE 'UTC') AS t, value AS v
        FROM simulations.tsfm_overlay
        WHERE input_mode = '$(TSFM_BACKFILL_MODE)' AND model_version = \$1 AND level = 'hour'
          AND quantity = 'tsfm_median'
    """, [tsfm_backfill_label(tag; arm=arm)])
    isempty(ts) && return parts
    dates = Date.(ts.market_date)
    sd, ed = minimum(dates), maximum(dates)
    keep = rows === nothing ? nothing : Set(zip(String.(rows.z), Date.(rows.market_date)))
    ph = Euphemia.sql2df_with_retry("""
        SELECT bidding_zone AS z, market_date, (date_time_utc AT TIME ZONE 'UTC') AS t
        FROM simulations.forecast_prices
        WHERE is_retro AND reset_tag = \$1 AND lead_days = 1 AND input_mode LIKE 'weather%'
          AND market_date BETWEEN \$2 AND \$3
    """, [tag, sd, ed])
    phys = Dict{Tuple{String,Date},Set{DateTime}}()
    for r in eachrow(ph)
        push!(get!(Set{DateTime}, phys, (String(r.z), Date(r.market_date))), trunc(DateTime(r.t), Hour))
    end
    act = da_target_actuals(sd - Day(8), ed)
    actz = Dict{String,Dict{DateTime,Float64}}()
    for r in eachrow(act)
        (r.act === missing || r.act === nothing) && continue
        x = Float64(r.act)
        isfinite(x) && (get!(Dict{DateTime,Float64}, actz, String(r.z))[DateTime(r.t)] = x)
    end
    locz = Dict(z => local_price_index(collect(keys(d)), collect(values(d))) for (z, d) in actz)
    empty_d, empty_s = Dict{DateTime,Float64}(), Set{DateTime}()
    for g in groupby(ts, [:z, :market_date])
        key = (String(g.z[1]), Date(g.market_date[1]))
        keep === nothing || key in keep || continue
        parts[key] = tsfm_backfill_zone_day(g.t, g.v, get(phys, key, empty_s), get(actz, key[1], empty_d),
                                            get(locz, key[1], empty_d), key[2])
    end
    return parts
end

"""
    tsfm_backfill_parts_or_nothing(tag, rows) -> Union{Dict,Nothing}

`tsfm_backfill_parts` behind the kill switch and a non-fatal guard (`nothing` = no tsfm fields).
"""
function tsfm_backfill_parts_or_nothing(tag::AbstractString, rows::Union{Nothing,AbstractDataFrame}=nothing)
    tsfm_backfill_enabled() || (println("tsfm backfill fields: skipped (EXPORT_TSFM_BACKFILL=0)"); return nothing)
    try
        parts = tsfm_backfill_parts(tag, rows)
        println("tsfm backfill fields ($tag): $(length(parts)) zone-days, " *
                "$(sum((p.n for p in values(parts)); init=0)) paired hours")
        return parts
    catch e
        @warn "tsfm backfill fields failed — backfilled window exported without them" exception = (e, catch_backtrace())
        return nothing
    end
end

"Per-export cache: tag => parts (or nothing). One DB step per export, whatever the cohort count."
const TSFM_BACKFILL_PARTS_CACHE = Dict{String,Any}()

"""
    tsfm_backfill_cohort_fields(zone, lead, rows; tag, load) -> Dict{String,Any}

The tsfm_* fields of one backfilled cohort (lead 1 only), pooled over the cohort's market days
(`rows.market_date`, the physics backfill's own zone-days). `load(tag)` (default
`tsfm_backfill_parts_or_nothing`, non-fatal) runs once per tag per process.
"""
function tsfm_backfill_cohort_fields(zone, lead, rows; tag=BACKFILL_RESET_TAG,
                                     load=tsfm_backfill_parts_or_nothing)
    Int(lead) == 1 || return Dict{String,Any}()
    parts = get!(() -> load(tag), TSFM_BACKFILL_PARTS_CACHE, tag)
    return tsfm_backfilled_fields(parts, String(zone), rows.market_date; label=tsfm_backfill_label(tag))
end

"""
    tsfm_backfill_columns(n_live, extras) -> Union{Nothing,Dict{String,Vector}}

Parquet columns for TSFM_BACKFILL_BOARD_COLS: `n_live` leading rows (the live windows) are missing,
then one value per backfilled row from its extra-fields Dict (missing where absent). `nothing` (no
columns, the parquet stays as before) when no backfilled row carries Timestral fields.
"""
function tsfm_backfill_columns(n_live::Integer, extras)
    any(x -> haskey(x, "tsfm_mae"), extras) || return nothing
    cols = Dict{String,Vector}()
    for c in TSFM_BACKFILL_BOARD_COLS
        T = c == "tsfm_arm" ? String : c in ("tsfm_n_days", "tsfm_n") ? Int : Float64
        v = Vector{Union{Missing,T}}(missing, n_live)
        for x in extras
            y = get(x, c, missing)
            push!(v, (y === nothing || y === missing) ? missing : convert(T, y))
        end
        cols[c] = v
    end
    return cols
end
