# Naive day-ahead baselines and rMAE for the public scoreboard (#431, export-side only).
#
# Included by bin/export_forecast_json.jl and bin/export_web_parquet.jl AFTER
# bin/forecast_common.jl (Athens time helpers, CHOSEN_SLICE_CTE) and
# test/scripts/eu_eval_metrics.jl (`da_target_actuals`, the scorer's actuals; it follows
# EUPHEMIA_DA_TARGET, default sdac; highest_seq = `resolution_aware_actuals`).
# No DDL, no new tables, no stored score changes: the naive is recomputed at export
# time on exactly the zone-days and hours the board's physics score covers, so it
# follows whatever actuals function the scorer uses.
#
# THE THREE NAIVES (forecast of zone z, market day D, UTC hour t):
#   d1   the settled price of the same Europe/Athens wall-clock hour on D-1
#   d7   the same wall-clock hour on D-7 (same weekday last week)
#   epf  the epftoolbox weekday rule: d7 when D (the Athens market day) is a
#        Saturday, Sunday or Monday, d1 otherwise (Lago et al. 2021)
# Keyed by market-local wall clock, never by row offsets: lag k of UTC hour t is
# the Athens wall-clock stamp local(t) - k days, looked up in an Athens wall-clock
# index of the actuals.
#
# DST POLICY (23/25-hour days):
#   * A 25-hour lag day (October): its repeated wall-clock hour (03:00 local) holds
#     the MEAN of its two settled prices (as epftoolbox's 24-hour data preparation
#     does); both occurrences of that hour on a 25-hour TARGET day look up the same
#     lagged wall-clock hour.
#   * A 23-hour lag day (March): its skipped wall-clock hour (03:00 local) does not
#     exist, so the naive is MISSING for that target hour.
#   * Any missing lag (absent or non-finite actual) makes the naive missing for
#     that cell, and the cell leaves BOTH sums (model and naive).
#
# AVAILABILITY (what was known when the forecast was issued): a lead-L forecast for
# day D is issued before the gate on D-L, when settled prices reach day D-L (cleared
# on D-L-1). D-k is therefore known iff k >= L: d1 and epf only at lead <= 1, d7 at
# lead <= 7. For leads 2-7 the board carries d7 only; d1/epf fields are absent.
#
# COMMON MASK: per board cohort (zone, lead, input_mode, window) every naive figure
# and the model's paired MAE use the SAME cells: hours the scorer pairs (sim row +
# finite actual) where every naive available at that lead exists. Aggregates are
# ratios of sums over those cells (pooled cell means), never means of daily ratios.
# rMAE = sum|model err| / sum|naive err|; a zero naive error sum gives null rMAE.
#
# Kill switch: EXPORT_NAIVE=0 skips the computation entirely (no query, no fields).

"Naive kinds exported on the board (the order of the parquet columns)."
const NAIVE_KINDS = ("d1", "d7", "epf")

"Whether the naive baselines are exported (`EXPORT_NAIVE=0` switches them off)."
naive_enabled() = get(ENV, "EXPORT_NAIVE", "1") != "0"

"Europe/Athens wall-clock stamp of UTC instant `t`."
athens_local(t::DateTime) = t + athens_utc_offset(t)

"""
    naive_lag_days(kind, market_date) -> Int

Days back for naive `kind` ("d1", "d7", "epf") on Athens market day `market_date`.
"epf" is 7 on Saturday, Sunday and Monday, else 1 (the weekday of the market day).
"""
function naive_lag_days(kind::AbstractString, market_date::Date)
    kind == "d1" && return 1
    kind == "d7" && return 7
    kind == "epf" && return dayofweek(market_date) in (Dates.Saturday, Dates.Sunday, Dates.Monday) ? 7 : 1
    throw(ArgumentError("unknown naive kind '$kind'"))
end

"""
    naive_available(kind, lead_days) -> Bool

Whether every lag naive `kind` can use was settled when a `lead_days` forecast was
issued (D-k is known iff k >= lead): d1 and epf at lead <= 1, d7 at lead <= 7.
"""
naive_available(kind::AbstractString, lead_days::Integer) =
    lead_days <= (kind == "d7" ? 7 : 1)

"Naive kinds available at `lead_days` (in NAIVE_KINDS order)."
naive_kinds_at(lead_days::Integer) = Tuple(k for k in NAIVE_KINDS if naive_available(k, lead_days))

"""
    local_price_index(ts, vals) -> Dict{DateTime,Float64}

Hourly actuals (UTC hour starts `ts`, prices `vals`) re-keyed by Europe/Athens
wall-clock hour. Non-finite or missing prices are dropped. The repeated wall-clock
hour of a 25-hour day (two UTC hours, one local stamp) holds the mean of the
present prices.
"""
function local_price_index(ts::AbstractVector, vals::AbstractVector)
    acc = Dict{DateTime,Tuple{Float64,Int}}()
    for (t, v) in zip(ts, vals)
        (v === missing || v === nothing) && continue
        x = Float64(v)
        isfinite(x) || continue
        k = athens_local(trunc(DateTime(t), Hour))
        s, n = get(acc, k, (0.0, 0))
        acc[k] = (s + x, n + 1)
    end
    return Dict(k => s / n for (k, (s, n)) in acc)
end

"""
    naive_value(loc, t, lag_days) -> Union{Float64,Missing}

Naive price for UTC hour `t` with a lag of `lag_days` market days: the Athens
wall-clock index `loc` (see `local_price_index`) at local(t) - lag_days days.
`missing` when that wall-clock hour has no settled price (absent, or skipped on
a 23-hour day).
"""
naive_value(loc::AbstractDict, t::DateTime, lag_days::Integer) =
    get(loc, athens_local(trunc(t, Hour)) - Day(lag_days), missing)

"""
    naive_zone_day(sim_t, sim_v, act, loc, market_date, lead_days)
        -> (n, model, d1, d7, epf)

Paired absolute-error SUMS for one scored zone-day. The sim is first averaged to the
hour (`hourly_means`: a quarter-hour slice gives one cell per hour, as the scorer
pairs it; an hourly slice is unchanged). A cell is a sim hour that has a finite actual in `act`
(UTC hour => price) and a value for EVERY naive available at `lead_days`.
`model` is sum|sim - actual| on those cells; `d1`/`d7`/`epf` the naive sums, or
`nothing` when that naive is unavailable at this lead. `n` is the cell count.
"""
function naive_zone_day(sim_t::AbstractVector, sim_v::AbstractVector,
                        act::AbstractDict, loc::AbstractDict,
                        market_date::Date, lead_days::Integer)
    sim_t, sim_v = hourly_means(sim_t, sim_v)   # cv46: quarter rows → one cell per hour
    kinds = naive_kinds_at(lead_days)
    sums = Dict{String,Float64}(k => 0.0 for k in kinds)
    lags = Dict{String,Int}(k => naive_lag_days(k, market_date) for k in kinds)
    n = 0
    model = 0.0
    if !isempty(kinds)
        for (t, s) in zip(sim_t, sim_v)
            (s === missing || s === nothing) && continue
            sv = Float64(s)
            isfinite(sv) || continue
            h = trunc(DateTime(t), Hour)
            a = get(act, h, missing)
            (a === missing || !isfinite(a)) && continue
            nv = Dict{String,Float64}()
            ok = true
            for k in kinds
                v = naive_value(loc, h, lags[k])
                if v === missing
                    ok = false
                    break
                end
                nv[k] = v
            end
            ok || continue
            n += 1
            model += abs(sv - a)
            for k in kinds
                sums[k] += abs(nv[k] - a)
            end
        end
    end
    pick(k) = haskey(sums, k) ? sums[k] : nothing
    return (n=n, model=model, d1=pick("d1"), d7=pick("d7"), epf=pick("epf"))
end

"""
    rmae(sum_abs_model, sum_abs_naive) -> Union{Float64,Nothing}

Relative MAE as a ratio of sums over the same cells. `nothing` (null) when the
naive error sum is zero or either input is unavailable — never Inf.
"""
function rmae(sum_model, sum_naive)
    (sum_model === nothing || sum_naive === nothing) && return nothing
    (sum_naive > 0 && isfinite(sum_naive) && isfinite(sum_model)) || return nothing
    return sum_model / sum_naive
end

"""
    naive_board_fields(parts, lead_days) -> Dict{String,Any}

Pool zone-day sums (`naive_zone_day` results) into one board cohort. Always has
`n_naive` (paired cells) and `mae_paired` (the model's MAE on those cells), plus
`mae_naive_<k>` and `rmae_<k>` for every naive available at `lead_days`; d1/epf
keys are ABSENT at leads >= 2. Values are `nothing` when there are no cells.
"""
function naive_board_fields(parts, lead_days::Integer)
    n = 0
    model = 0.0
    kinds = naive_kinds_at(lead_days)
    sums = Dict{String,Float64}(k => 0.0 for k in kinds)
    for p in parts
        n += p.n
        model += p.model
        for k in kinds
            v = getproperty(p, Symbol(k))
            v === nothing || (sums[k] += v)
        end
    end
    out = Dict{String,Any}("n_naive" => n, "mae_paired" => n > 0 ? model / n : nothing)
    for k in kinds
        out["mae_naive_$k"] = n > 0 ? sums[k] / n : nothing
        out["rmae_$k"] = n > 0 ? rmae(model, sums[k]) : nothing
    end
    return out
end

"Ordered board columns (parquet) of the naive fields."
const NAIVE_BOARD_COLS = ("n_naive", "mae_paired", "mae_naive_d1", "mae_naive_d7",
                          "mae_naive_epf", "rmae_d1", "rmae_d7", "rmae_epf")

"""
    naive_zone_day_parts(scores) -> Dict{(zone, lead, mode, market_date), NamedTuple}

DB step: per-zone-day naive sums for every row of the board's chosen-slice score
frame `scores` (columns z, lead_days, mode, market_date). Reads the chosen slices'
hourly sim rows and the scorer's actuals (`da_target_actuals`, EUPHEMIA_DA_TARGET) over the
scored dates plus the 8 days before (lag 7 of the first local hour).

The default reads LIVE sim rows only (`live_only_sql`, #431 R1). With
`reset_tag`/`code_version` it reads that retro campaign's rows instead (the
"backfilled" window): the same pure functions and paired-cell rules.
"""
function naive_zone_day_parts(scores::AbstractDataFrame;
                              reset_tag::Union{Nothing,String}=nothing,
                              code_version::Union{Nothing,Int}=nothing)
    parts = Dict{Tuple{String,Int,String,Date},NamedTuple}()
    isempty(scores) && return parts
    dates = Date.(scores.market_date)
    sd, ed = minimum(dates), maximum(dates)
    keep = Set(zip(String.(scores.z), Int.(scores.lead_days), String.(scores.mode), dates))
    sim = reset_tag === nothing ? Euphemia.sql2df_with_retry("""
        WITH $(CHOSEN_SLICE_CTE)
        SELECT f.bidding_zone AS z, f.lead_days, f.input_mode AS mode, f.market_date,
               (f.date_time_utc AT TIME ZONE 'UTC') AS t, f.price_eur_mwh AS sim
        FROM simulations.forecast_prices f
        JOIN chosen c ON c.market_date = f.market_date AND c.lead_days = f.lead_days
                     AND c.input_mode = f.input_mode AND c.code_version = f.code_version
        WHERE f.market_date BETWEEN \$1 AND \$2$(live_only_sql("f"))
    """, [sd, ed]) : Euphemia.sql2df_with_retry("""
        SELECT f.bidding_zone AS z, f.lead_days, f.input_mode AS mode, f.market_date,
               (f.date_time_utc AT TIME ZONE 'UTC') AS t, f.price_eur_mwh AS sim
        FROM simulations.forecast_prices f
        WHERE f.market_date BETWEEN \$1 AND \$2
          AND f.is_retro = true AND f.reset_tag = \$3 AND f.code_version = \$4
    """, [sd, ed, reset_tag, something(code_version, -1)])
    act = da_target_actuals(sd - Day(8), ed)  # EUPHEMIA_DA_TARGET (default sdac; highest_seq = kill switch)
    actz = Dict{String,Dict{DateTime,Float64}}()
    for r in eachrow(act)
        (r.act === missing || r.act === nothing) && continue
        x = Float64(r.act)
        isfinite(x) || continue
        get!(Dict{DateTime,Float64}, actz, String(r.z))[DateTime(r.t)] = x
    end
    locz = Dict(z => local_price_index(collect(keys(d)), collect(values(d))) for (z, d) in actz)
    empty_d = Dict{DateTime,Float64}()
    for g in groupby(sim, [:z, :lead_days, :mode, :market_date])
        key = (String(g.z[1]), Int(g.lead_days[1]), String(g.mode[1]), Date(g.market_date[1]))
        key in keep || continue
        parts[key] = naive_zone_day(g.t, g.sim, get(actz, key[1], empty_d),
                                    get(locz, key[1], empty_d), key[4], key[2])
    end
    return parts
end

"""
    naive_parts_or_nothing(scores) -> Union{Dict,Nothing}

`naive_zone_day_parts` behind the kill switch and a non-fatal guard: returns
`nothing` (the board then carries no naive fields) when `EXPORT_NAIVE=0` or when
anything fails — a warning is logged and the daily export continues unchanged.
"""
function naive_parts_or_nothing(scores::AbstractDataFrame)
    naive_enabled() || (println("naive baselines: skipped (EXPORT_NAIVE=0)"); return nothing)
    try
        t0 = time()
        parts = naive_zone_day_parts(scores)
        println("naive baselines: $(length(parts)) zone-days, " *
                "$(sum((p.n for p in values(parts)); init=0)) paired hours, " *
                "$(round(time() - t0; digits=1)) s")
        return parts
    catch e
        @warn "naive baselines failed — board exported without naive fields" exception = (e, catch_backtrace())
        return nothing
    end
end

"""
    naive_cohort_fields(parts, sub) -> Union{Dict,Nothing}

Board fields for one cohort (`sub` = its score rows, one lead) from the zone-day
parts; `nothing` when the naive step was skipped or failed.
"""
function naive_cohort_fields(parts, sub::AbstractDataFrame)
    parts === nothing && return nothing
    lead = Int(sub.lead_days[1])
    ps = NamedTuple[]
    for k in unique(zip(String.(sub.z), Int.(sub.lead_days), String.(sub.mode), Date.(sub.market_date)))
        haskey(parts, k) && push!(ps, parts[k])
    end
    return naive_board_fields(ps, lead)
end
