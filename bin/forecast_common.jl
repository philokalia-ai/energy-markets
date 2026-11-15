# Shared pure logic for the daily-forecast product
# (bin/daily_forecast.jl, bin/score_forecasts.jl, bin/export_forecast_json.jl).
#
# Everything here is deliberately DB-free so test/test_forecast_tracking.jl can
# unit-test the eligibility gate, the lead-day arithmetic, the realized-day
# write guard and the scoring math on synthetic data without a live solve.

using Dates, Statistics

# The 39-zone EU footprint (same list as bin/eu_calibration_run.jl / CLAUDE.md).
const FORECAST_FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

"""
    CHOSEN_SLICE_CTE

The forecast product's slice-selection rule, as a SQL CTE body shared by the
exporters (bin/export_forecast_json.jl, bin/export_web_parquet.jl).

THE DESIGN RULE: the forecast product's record spans code versions. Slice
identity for the product is (market_date, lead_days, input_mode);
`code_version` is per-row PROVENANCE, not a display filter. Where a slice was
written under more than one code_version (e.g. a mid-run cv bump between two
pipeline invocations), the EARLIEST-FROZEN slice wins — the first commitment
is the honest ex-ante one. Selection is by the SLICE-LEVEL
MIN(prediction_made_utc) (never per-row, so a chosen slice stays internally
consistent across zones), with the lowest code_version as a deterministic
tiebreaker.

Usage: `WITH \$(CHOSEN_SLICE_CTE) SELECT ... JOIN chosen c ON c.market_date =
… AND c.lead_days = … AND c.input_mode = … AND c.code_version = …`.
"""
const CHOSEN_SLICE_CTE = """
    chosen AS (
        SELECT DISTINCT ON (market_date, lead_days, input_mode)
               market_date, lead_days, input_mode, code_version
        FROM (SELECT market_date, lead_days, input_mode, code_version,
                     MIN(prediction_made_utc) AS made_min
              FROM simulations.forecast_prices
              GROUP BY 1, 2, 3, 4) slice_versions
        ORDER BY market_date, lead_days, input_mode, made_min, code_version)"""

"""
    forecast_lead_days(market_date::Date, today_utc::Date) -> Int

Lead time in whole days: 0 = same-day nowcast, 1 = day-ahead, etc.
`today_utc` should be the Europe/Athens calendar date of the prediction
instant (see `athens_date`), so that "day-ahead" means the next MARKET day.
"""
forecast_lead_days(market_date::Date, today_utc::Date) =
    Dates.value(market_date - today_utc)

# ---------------------------------------------------------------------------
# Europe/Athens market-day window (DST-aware, pure).
#
# ENTSO-E publishes day-ahead data per LOCAL market day. Greece is
# Europe/Athens: EET (UTC+2) in winter, EEST (UTC+3) in summer. The EU DST
# rule (Directive 2000/84/EC, unchanged as of 2026): summer time runs from
# the last Sunday of March 01:00 UTC to the last Sunday of October 01:00 UTC.
# TimeZones.jl is deliberately NOT a project dependency, so the rule is
# implemented here as small pure functions with unit tests
# (test/test_forecast_tracking.jl).
# ---------------------------------------------------------------------------

"Last Sunday of `month` in `year` (pure helper for the EU DST rule)."
function last_sunday(year::Int, month::Int)
    d = Date(year, month, Dates.daysinmonth(Date(year, month)))
    return d - Day(dayofweek(d) % 7)   # Sunday has dayofweek 7 → shift 0
end

"EU summer-time interval [start, end) in UTC for `year`."
eu_dst_window(year::Int) =
    (DateTime(last_sunday(year, 3)) + Hour(1),
     DateTime(last_sunday(year, 10)) + Hour(1))

"Whether EU summer time (EEST for Athens) is in force at UTC instant `t`."
function is_eu_summer_time(t::DateTime)
    s, e = eu_dst_window(Dates.year(t))
    return s <= t < e
end

"Europe/Athens UTC offset (Hour) at UTC instant `t`: +3 in EEST, +2 in EET."
athens_utc_offset(t::DateTime) = is_eu_summer_time(t) ? Hour(3) : Hour(2)

"Europe/Athens calendar date of UTC instant `t`."
athens_date(t::DateTime) = Date(t + athens_utc_offset(t))

"""
    athens_day_start_utc(d::Date) -> DateTime

UTC instant at which the Europe/Athens market day `d` begins (local midnight):
21:00 UTC on d-1 under EEST, 22:00 UTC on d-1 under EET. The candidate EEST
instant is checked against the EU DST window, which resolves the transition
days correctly (local midnight of the switch Sunday is still in the old
regime — the clocks change at 01:00 UTC that morning).
"""
function athens_day_start_utc(d::Date)
    candidate = DateTime(d - Day(1)) + Hour(21)   # midnight if EEST
    return is_eu_summer_time(candidate) ? candidate : candidate + Hour(1)
end

"""
    athens_market_day_window(d::Date) -> (start_utc, end_utc)

Half-open UTC window [start, end) of Europe/Athens market day `d`.
Normally 24 h; 23 h on the March DST-transition Sunday, 25 h in October.
"""
athens_market_day_window(d::Date) =
    (athens_day_start_utc(d), athens_day_start_utc(d + Day(1)))

"Expected hourly UTC stamps of Europe/Athens market day `d` (24; 23/25 on DST days)."
function expected_market_day_hours(d::Date)
    t0, t1 = athens_market_day_window(d)
    return collect(t0:Hour(1):(t1 - Hour(1)))
end

"""
    stitch_market_day(d::Date, hourly_prev::Dict{DateTime,Float64},
                      hourly_curr::Dict{DateTime,Float64})
        -> (stitched, missing_hours, expected)

Assemble the full Europe/Athens market day `d` from two UTC-day clears:
`hourly_prev` = hourly prices of the UTC-day d-1 clear (contributes only
hours ≥ athens_day_start_utc(d), i.e. the late-evening UTC tail that belongs
to market day `d`), `hourly_curr` = hourly prices of the UTC-day d clear
(contributes only hours < athens_day_start_utc(d+1); its unpublished local
tail is expected to be absent). `missing_hours` is empty iff the stitched
day is complete — callers MUST refuse to persist an incomplete day.
"""
function stitch_market_day(d::Date, hourly_prev::Dict{DateTime,Float64},
                           hourly_curr::Dict{DateTime,Float64})
    t0, t1 = athens_market_day_window(d)
    utc_midnight = DateTime(d)
    stitched = Dict{DateTime,Float64}()
    for (h, p) in hourly_prev
        (t0 <= h < utc_midnight) && (stitched[h] = p)
    end
    for (h, p) in hourly_curr
        (utc_midnight <= h < t1) && (stitched[h] = p)
    end
    expected = collect(t0:Hour(1):(t1 - Hour(1)))
    missing_hours = [h for h in expected if !haskey(stitched, h)]
    return (stitched=stitched, missing_hours=missing_hours, expected=expected)
end

"""
    assert_hours_unrealized(hours, prediction_made_utc::DateTime)

HOUR-LEVEL HARD GUARD for honest forecasting: refuse any forecast row whose
delivery hour is not strictly in the future of the prediction instant
(date_time_utc ≤ prediction_made_utc). Complements the day-level
`assert_unrealized` (kept for the fully-realized case). Throws on violation.
"""
function assert_hours_unrealized(hours, prediction_made_utc::DateTime)
    bad = sort([h for h in hours if h <= prediction_made_utc])
    if !isempty(bad)
        error("REFUSING to write forecast rows for $(length(bad)) hour(s) at or " *
              "before prediction_made_utc=$prediction_made_utc (first: $(bad[1]), " *
              "last: $(bad[end])). A prediction for a delivery hour that has " *
              "already begun would be fake.")
    end
    return true
end

"""
    assert_unrealized(market_date::Date, latest_actual_date::Date)

HARD GUARD for honest forecasting: refuse to write a "prediction" for a market
day that has already realized (market_date ≤ latest actual_total_load date) —
a prediction written now for a realized day would be fake. Throws on violation.
"""
function assert_unrealized(market_date::Date, latest_actual_date::Date)
    if market_date <= latest_actual_date
        error("REFUSING to write forecast for $market_date: the day has already " *
              "realized (latest actual_total_load date = $latest_actual_date). " *
              "A prediction written now would be fake.")
    end
    return true
end

"""
    eligibility_verdict(zones, load_hours_by_zone, res_zones_required,
                        res_zones_present, atc_rows;
                        min_load_hours=20, load_fill_zones=Set{String}(),
                        res_fill_zones=Set{String}())
        -> (eligible::Bool, reason::String)

Pure eligibility gate for one candidate market day. A day is eligible iff
1. EVERY footprint zone has ≥ `min_load_hours` hourly-equivalent rows of
   day-ahead load forecast (`load_hours_by_zone`: zone → distinct hours), OR the
   zone is in `load_fill_zones` (its load will be model-filled — the
   `bin/daily_forecast.jl` eligibility fill; a zone is only added there when the
   model can actually produce the window, so a filled zone is genuinely covered);
2. every zone that had a wind/solar forecast on the most recent fully-realized
   day (`res_zones_required`) also has one for this day (`res_zones_present`), OR
   the zone is in `res_fill_zones` (its wind/solar will be weather-model-filled —
   the symmetric RES fill; again only added when the model can cover the window);
3. offered implicit ATC rows exist for the day (`atc_rows` > 0).

Never degrades on ATC. A short LOAD or missing RES zone only passes when it is
model-fillable — a zone the fill cannot cover (absent from the pack / no weather)
keeps the day ineligible.
"""
function eligibility_verdict(zones::Vector{String},
                             load_hours_by_zone::AbstractDict{String,<:Integer},
                             res_zones_required::AbstractSet{String},
                             res_zones_present::AbstractSet{String},
                             atc_rows::Integer;
                             min_load_hours::Integer=20,
                             load_fill_zones::AbstractSet{String}=Set{String}(),
                             res_fill_zones::AbstractSet{String}=Set{String}())
    missing_load = [z for z in zones
                    if get(load_hours_by_zone, z, 0) < min_load_hours && !(z in load_fill_zones)]
    if !isempty(missing_load)
        return (false, "load forecast missing/short (<$(min_load_hours)h) and not " *
                       "model-fillable for $(length(missing_load)) zone(s): " *
                       "$(join(missing_load, ","))")
    end
    missing_res = sort(collect(setdiff(res_zones_required, union(res_zones_present, res_fill_zones))))
    if !isempty(missing_res)
        return (false, "wind/solar forecast missing (and not model-fillable) for " *
                       "zone(s) that had one on the last realized day: " *
                       "$(join(missing_res, ","))")
    end
    n_lfill = count(z -> get(load_hours_by_zone, z, 0) < min_load_hours, zones)
    n_rfill = length(intersect(res_zones_required, res_fill_zones))
    notes = String[]
    n_lfill > 0 && push!(notes, "$n_lfill load model-filled")
    n_rfill > 0 && push!(notes, "$n_rfill RES model-filled")
    fill_note = isempty(notes) ? "" : " (" * join(notes, ", ") * ")"
    if atc_rows <= 0
        return (false, "no offered ATC (implicit) rows for the day")
    end
    return (true, "all $(length(zones)) zones have load + RES coverage$fill_note, " *
                  "RES baseline the last realized day " *
                  "($(length(res_zones_required)) zones), ATC present ($atc_rows rows)")
end

"""
    hourly_prices(prices::Dict{String,Float64}) -> Dict{DateTime,Float64}

Collapse a market-clearing price dict keyed by "yyyymmdd-HHMM" timeslots to
hourly prices (mean of sub-hourly slots within each hour; identity for hourly
books, which is what the merit-order clear produces).
"""
function hourly_prices(prices::Dict{String,Float64})
    acc = Dict{DateTime,Vector{Float64}}()
    for (ts, p) in prices
        dt = DateTime(ts, dateformat"yyyymmdd-HHMM")
        h = trunc(dt, Hour)
        push!(get!(acc, h, Float64[]), p)
    end
    return Dict(h => mean(v) for (h, v) in acc)
end

"""
    score_series(sim::Vector{Float64}, act::Vector{Float64})
        -> (n, mae, bias, corr)

Scoring math for one zone-day: MAE, bias (sim − actual, so + = model too
expensive) and Pearson correlation over paired hours. `corr` is `nothing` when
either series is degenerate (zero variance) or fewer than 3 pairs — never NaN.
Requires equal lengths; returns `nothing` for all metrics when n == 0.
"""
function score_series(sim::Vector{Float64}, act::Vector{Float64})
    length(sim) == length(act) ||
        throw(ArgumentError("sim and act must be paired (got $(length(sim)) vs $(length(act)))"))
    n = length(sim)
    n == 0 && return (n=0, mae=nothing, bias=nothing, corr=nothing)
    mae = mean(abs.(sim .- act))
    bias = mean(sim .- act)
    c = (n >= 3 && std(sim) > 0 && std(act) > 0) ? cor(sim, act) : nothing
    c isa Float64 && !isfinite(c) && (c = nothing)
    return (n=n, mae=mae, bias=bias, corr=c)
end

# ---------------------------------------------------------------------------
# Native 15-minute scores (phase 3, planner-p3 option (ii)): the HOURLY forecast
# replicated x4 onto its quarters, scored against native PT15M SDAC actuals, in
# ADDITION to the hourly score (which is unchanged). Pure; DB access lives in
# test/scripts/eu_eval_metrics.jl (`native_q15_actuals`).
# ---------------------------------------------------------------------------

"Minimum paired native quarters for a 15-min zone-day score (analogous to MIN_SCORE_HOURS)."
const MIN_SCORE_Q15_DEFAULT = 48

"UTC quarter starts of Europe/Athens market day `d`: 96 (92 / 100 on DST days)."
function athens_day_quarters(d::Date)
    t0, t1 = athens_market_day_window(d)
    return collect(t0:Minute(15):(t1 - Minute(15)))
end

"""
    q15_forecast(ts, vals) -> (Dict{DateTime,Float64}, res::String)

The 15-minute view of one zone's forecast slice. An hourly slice (every stamp on
the hour) is replicated onto its four quarters (`res = "PT60M"`, recorded so a
replicated score is never mistaken for a native one); a slice with any
sub-hourly stamp is natively quarter-hourly and used as is (`res = "PT15M"`).
"""
function q15_forecast(ts::AbstractVector, vals::AbstractVector)
    length(ts) == length(vals) || throw(ArgumentError("ts/vals length mismatch"))
    native = any(t -> minute(DateTime(t)) != 0, ts)
    out = Dict{DateTime,Float64}()
    for (t, v) in zip(ts, vals)
        t = DateTime(t)
        if native
            out[t] = Float64(v)
        else
            for q in 0:3
                out[t + Minute(15q)] = Float64(v)
            end
        end
    end
    return out, native ? "PT15M" : "PT60M"
end

"""
    score_q15(fq, act_t, act_v, act_res; window=nothing, min_n=MIN_SCORE_Q15_DEFAULT)
        -> NamedTuple

One zone-day's native 15-minute score. `fq` is the quarter forecast from
`q15_forecast`; `act_*` are the zone's deduplicated actual rows (UTC interval
start, price, ENTSO-E resolution code); `window` optionally restricts to a set
of quarter starts (the Athens market day).

Complete coverage is enforced (the #423 review):
- only natively PT15M actual rows are considered. PT60M/PT30M rows never enter,
  so a PT60M-only zone gets `n_q15 = 0` and null metrics, never a copy of its
  hourly score;
- (zone, ts) keys must be unique. A duplicated PT15M quarter makes the whole
  zone-day ambiguous, so all metrics are null and `q15_status = "duplicate_keys"`;
- a quarter counts only with a finite actual AND a finite forecast;
- an hour enters ONLY when all 4 of its quarters qualify. Every metric (MAE,
  bias, corr, shape floor, ≤0 counts) is computed on those complete hours, so a
  missing quarter removes its whole hour instead of silently dropping one
  (possibly large-error) quarter;
- the zone-day is scored when `n_q15` (quarters in complete hours) ≥ `min_n`.
  `n_q15` is always reported, so partial days are visible.

Fields: `n_q15`, `mae_q15`, `bias_q15` (forecast − actual), `corr_q15`
(`nothing` if n < 3 or either side has zero variance, the `score_series`
semantics), `shape_floor_q15` = mean |a − ā_hour| over the complete hours, i.e.
the error a perfect hourly level would still make (a hindsight diagnostic, not a
forecast skill). ≤0 counts use `round(p, digits=8) <= 0`, explicitly NOT the €5
collapse helper: `n_le0_q15_actual`, `n_le0_q15_pred`, `le0_q15_hits`.
`q15_status` ∈ "ok" | "below_min" | "duplicate_keys".
"""
function score_q15(fq::AbstractDict, act_t::AbstractVector, act_v::AbstractVector,
                   act_res::AbstractVector; window=nothing,
                   min_n::Int=MIN_SCORE_Q15_DEFAULT)
    win = window === nothing ? nothing : Set(DateTime.(window))
    seen = Dict{DateTime,Float64}()
    dup = false
    for (t, v, r) in zip(act_t, act_v, act_res)
        t = DateTime(t)
        (r isa AbstractString && strip(r) == "PT15M") || continue
        win === nothing || t in win || continue
        haskey(seen, t) && (dup = true)
        seen[t] = (v === missing || v === nothing) ? NaN : Float64(v)
    end
    none(n, status) = (n_q15=n, mae_q15=nothing, bias_q15=nothing, corr_q15=nothing,
                       shape_floor_q15=nothing, n_le0_q15_actual=nothing,
                       n_le0_q15_pred=nothing, le0_q15_hits=nothing, q15_status=status)
    dup && return none(0, "duplicate_keys")
    ok(t) = haskey(seen, t) && isfinite(seen[t]) && haskey(fq, t) && isfinite(fq[t])
    ts = DateTime[]; f = Float64[]; a = Float64[]; dev = Float64[]
    for h in sort(unique(trunc.(collect(keys(seen)), Hour)))
        qs = [h + Minute(15k) for k in 0:3]
        all(ok, qs) || continue
        av = [seen[q] for q in qs]
        m = mean(av)
        append!(ts, qs); append!(f, [fq[q] for q in qs]); append!(a, av)
        append!(dev, abs.(av .- m))
    end
    n = length(ts)
    n < max(min_n, 1) && return none(n, "below_min")
    s = score_series(f, a)
    le0(x) = round(x; digits=8) <= 0
    return (n_q15=n, mae_q15=s.mae, bias_q15=s.bias, corr_q15=s.corr,
            shape_floor_q15=mean(dev),
            n_le0_q15_actual=count(le0, a), n_le0_q15_pred=count(le0, f),
            le0_q15_hits=count(i -> le0(a[i]) && le0(f[i]), 1:n), q15_status="ok")
end

# ---------------------------------------------------------------------------
# Native 15-minute score columns of forecast_scores (added by
# bin/score_forecasts.jl `ensure_q15_columns`). Selected only when present, so
# the exporters keep working against a database the new scorer has not run on
# yet (the q15 fields are then all null).
# ---------------------------------------------------------------------------
const Q15_SCORE_COLS = ("n_q15", "mae_q15", "bias_q15", "corr_q15", "shape_floor_q15")

function q15_select(alias::String="s")
    have = try
        df = Euphemia.sql2df_with_retry("""
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = 'simulations' AND table_name = 'forecast_scores'
              AND column_name = 'mae_q15'""")
        !isempty(df)
    catch
        false
    end
    have && return join(("$alias.$c" for c in Q15_SCORE_COLS), ", ")
    return "NULL::int AS n_q15, " *
           join(("NULL::double precision AS $c" for c in Q15_SCORE_COLS[2:end]), ", ")
end

"""
    load_weighted_err_pct(sim, act, load; min_den_eur=1.0) -> Union{Float64,Nothing}

Load-weighted absolute percentage error for one zone-day (a load-weighted
WAPE), the map view's "Error %" metric:

    Σ_h load_h·|sim_h − act_h| / Σ_h load_h·|act_h| × 100

All three vectors must be hour-paired and equal-length (throws otherwise).
Returns `nothing` — never a fabricated number — when the day is empty, when
total load is not positive, or when the DENOMINATOR is degenerate: the
load-weighted mean |settled price| below `min_den_eur` €/MWh (a day whose
settled prices sit at ~0 would turn any € error into an arbitrarily huge %,
so the metric is honestly undefined there).
"""
function load_weighted_err_pct(sim::Vector{Float64}, act::Vector{Float64},
                               load::Vector{Float64}; min_den_eur::Float64=1.0)
    (length(sim) == length(act) == length(load)) ||
        throw(ArgumentError("sim/act/load must be hour-paired (got " *
                            "$(length(sim))/$(length(act))/$(length(load)))"))
    isempty(sim) && return nothing
    wsum = sum(load)
    wsum > 0 || return nothing
    den = sum(load .* abs.(act))
    den / wsum < min_den_eur && return nothing   # near-zero settled prices → undefined
    return 100 * sum(load .* abs.(sim .- act)) / den
end

"""
    HOURLY_LOAD_FC_SQL

Hourly D-1 load forecast per zone over a half-open date window [\$1, \$2) —
the WEIGHTS of `load_weighted_err_pct` (shared by both map exporters, so the
parquet and JSON planes stay value-identical). Hour-averaged so PT15M/PT30M
zones weigh like PT60M ones; same area_type_code filter as src/Loads.jl.
"""
const HOURLY_LOAD_FC_SQL = """
    SELECT area_map_code AS z,
           date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS t,
           AVG(total_load_mw) AS load_mw
    FROM entsoe.day_ahead_total_load_forecast
    WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
      AND date_time_utc < (\$2::date::timestamp AT TIME ZONE 'UTC')
      AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
    GROUP BY 1, 2
"""

"""
    collapse_metrics(sim::Vector{Float64}, act::Vector{Float64}; threshold=5.0)
        -> (n, n_collapse_actual, n_collapse_pred, hits, false_alarms,
            hit_rate, false_alarm_rate)

First-class collapse classification for one zone-day/-slice (SCIENTIST.md §4).
A price "collapses" when it is ≤ `threshold` €/MWh (default €5 — the
solar-surplus / negative-hour regime). Ground truth = the settled actual; the
prediction is scored as a binary detector of that event:

- `n_collapse_actual` — hours the ACTUAL price collapsed (the positives),
- `n_collapse_pred`   — hours the model PREDICTED a collapse,
- `hits`              — predicted ∧ actual collapse,
- `false_alarms`      — predicted collapse ∧ actual did NOT,
- `hit_rate`          — hits / actual collapses (recall; `nothing` when no
                        actual collapse — undefined, never a fake 0/1),
- `false_alarm_rate`  — false_alarms / actual NON-collapses (fall-out;
                        `nothing` when every hour actually collapsed).

Matches `docs/experiments/input-upgrade/collapse_metrics.py`'s `confusion` at
the €5 threshold. Pure and DB-free (unit-tested in test_forecast_tracking.jl).
"""
function collapse_metrics(sim::Vector{Float64}, act::Vector{Float64};
                          threshold::Float64=5.0)
    length(sim) == length(act) ||
        throw(ArgumentError("sim and act must be paired (got $(length(sim)) vs $(length(act)))"))
    n = length(sim)
    n_ca = count(<=(threshold), act)
    n_cp = count(<=(threshold), sim)
    hits = count(i -> sim[i] <= threshold && act[i] <= threshold, 1:n)
    fa = count(i -> sim[i] <= threshold && act[i] > threshold, 1:n)
    n_neg = n - n_ca          # actual non-collapses
    hit_rate = n_ca > 0 ? hits / n_ca : nothing
    fa_rate = n_neg > 0 ? fa / n_neg : nothing
    return (n=n, n_collapse_actual=n_ca, n_collapse_pred=n_cp, hits=hits,
            false_alarms=fa, hit_rate=hit_rate, false_alarm_rate=fa_rate)
end

"""
    retro_write_plan(; is_retro::Bool, supersede::Bool, has_live::Bool) -> Symbol

Pure decision for `write_forecast!`'s three paths (DB-free, unit-tested). Given
whether the slice is a retro reconstruction, whether SUPERSEDE mode is on, and
whether a genuine LIVE (`is_retro=false`) row already exists in the slice:

- `:insert`    — write straight in. LIVE writes always; a retro fill when no
                 live vintage exists (delete prior retro, then insert).
- `:refuse`    — retro fill blocked by an existing live vintage (default
                 additive-fill contract, #280).
- `:supersede` — retro REPLACES an existing live vintage: back the live rows up
                 to `simulations.forecast_prices_pre_reset` first, then
                 delete-then-insert the retro rows (EUPHEMIA_RETRO_SUPERSEDE=1).

Truth table:
| is_retro | supersede | has_live | plan       |
|----------|-----------|----------|------------|
| false    | *         | *        | :insert    |
| true     | *         | false    | :insert    |
| true     | false     | true     | :refuse    |
| true     | true      | true     | :supersede |
"""
function retro_write_plan(; is_retro::Bool, supersede::Bool, has_live::Bool)
    is_retro || return :insert
    has_live || return :insert
    return supersede ? :supersede : :refuse
end

# ---------------------------------------------------------------------------
# Minimal JSON serializer (avoids adding a package dependency). Handles the
# restricted value universe of the export contract: Dict / NamedTuple /
# Vector / String / Real / Bool / Nothing / Missing / Date / DateTime.
# Non-finite floats (NaN/Inf) are emitted as null — JSON has no NaN.
# ---------------------------------------------------------------------------
function json_write(io::IO, v)
    if v === nothing || v === missing
        print(io, "null")
    elseif v isa Bool
        print(io, v ? "true" : "false")
    elseif v isa AbstractFloat
        isfinite(v) ? print(io, v) : print(io, "null")
    elseif v isa Real
        print(io, v)
    elseif v isa AbstractString || v isa Symbol
        json_write_string(io, string(v))
    elseif v isa Date
        json_write_string(io, Dates.format(v, "yyyy-mm-dd"))
    elseif v isa DateTime
        json_write_string(io, Dates.format(v, "yyyy-mm-ddTHH:MM:SS") * "Z")
    elseif v isa AbstractDict
        print(io, "{")
        first = true
        for (k, val) in v
            first || print(io, ",")
            first = false
            json_write_string(io, string(k)); print(io, ":")
            json_write(io, val)
        end
        print(io, "}")
    elseif v isa NamedTuple
        print(io, "{")
        first = true
        for (k, val) in pairs(v)
            first || print(io, ",")
            first = false
            json_write_string(io, string(k)); print(io, ":")
            json_write(io, val)
        end
        print(io, "}")
    elseif v isa AbstractVector || v isa Tuple
        print(io, "[")
        for (i, val) in enumerate(v)
            i > 1 && print(io, ",")
            json_write(io, val)
        end
        print(io, "]")
    else
        throw(ArgumentError("json_write: unsupported type $(typeof(v))"))
    end
end

function json_write_string(io::IO, s::String)
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c < ' '
            print(io, "\\u", string(UInt16(c), base=16, pad=4))
        else
            print(io, c)
        end
    end
    print(io, '"')
end

json_string(v) = sprint(json_write, v)

"""
    vintage_groups(first_utc::Date, last_utc::Date, candidates; asof=Date(now(UTC)))
        -> Vector{Tuple{Vector{Date},Int}}

Partition the UTC days `first_utc..last_utc` into runs of consecutive days
sharing one admissible open-meteo vintage lag (`openmeteo_vintage_lag`, so lag
is 0 or 1), for the D-1-vintage fetch discipline. A UTC day's governing market
day is itself when it is a candidate, else the next day (the earliest candidate
its hours serve — Athens market day D consumes UTC days D-1 and D, and the
earlier candidate's vintage is the stricter, admissible-for-both choice). On a
normal D-1 morning run every day resolves to lag 0 and one group — the fetch
pattern is then identical to the pre-vintage code; only late/catch-up runs
split. Pass ONE `asof` captured at run start to every caller: per-builder
`Date(now(UTC))` defaults can straddle midnight UTC and hand the builders
different vintages for the same day.

RETRO/pre-gate note: pass `fixed_lag` to force EVERY UTC day into ONE group at
that exact vintage lag — the retro reconstruction of a single lead `n` fetches
the whole window at `previous_day{n}` (`openmeteo_retro_vintage_lag(n)`), so no
per-day `asof` split applies. `nothing` (default) keeps the live D-1 discipline
above, byte-identical to the pre-existing code.
"""
function vintage_groups(first_utc::Date, last_utc::Date, candidates::AbstractSet{Date};
                        asof::Date=Date(now(UTC)),
                        fixed_lag::Union{Nothing,Int}=nothing)
    if fixed_lag !== nothing
        # RETRO/pre-gate: the caller reconstructs ONE lead at a fixed vintage; a
        # single group over the whole span (no candidate/asof split).
        return Tuple{Vector{Date},Int}[(collect(first_utc:Day(1):last_utc), fixed_lag)]
    end
    groups = Vector{Tuple{Vector{Date},Int}}()
    for u in first_utc:Day(1):last_utc
        g = u in candidates ? u : u + Day(1)
        g in candidates ||
            error("vintage_groups: UTC day $u serves no candidate market day " *
                  "(candidates $(sort(collect(candidates))))")
        lag = openmeteo_vintage_lag(g; asof)
        if !isempty(groups) && groups[end][2] == lag && groups[end][1][end] == u - Day(1)
            push!(groups[end][1], u)
        else
            push!(groups, ([u], lag))
        end
    end
    return groups
end

# ---------------------------------------------------------------------------
# TSFM overlay (bin/emit_tsfm_overlay.py → simulations.tsfm_overlay): per
# zone-day VINTAGES (input_mode, arm, issue_utc), each holding the hourly lines
# tsfm_median / tsfm_q10 / tsfm_q90, the hourly P(price ≤ 0) and the day-level
# P(any hour ≤ 0). Read by both exporters (zone JSON + zone parquet).
const TSFM_OVERLAY_QUANTITIES = ("tsfm_median", "tsfm_q10", "tsfm_q90", "p_le0")
const TSFM_OVERLAY_SQL = """
    SELECT bidding_zone AS z, market_date AS d,
           (date_time_utc AT TIME ZONE 'UTC') AS t, level, quantity AS q, value AS v,
           input_mode AS m, (issue_utc AT TIME ZONE 'UTC') AS issue, model_version AS arm
    FROM simulations.tsfm_overlay
    WHERE market_date >= \$1::date
      AND quantity IN ('tsfm_median', 'tsfm_q10', 'tsfm_q90', 'p_le0', 'p_any_le0')
    """

"""
    tsfm_overlay_maps(rows) -> (hourly, day)

Pure selection over simulations.tsfm_overlay rows (fields z, d, t, level, q, v,
m, issue, arm). Per (zone, market_date) ONE vintage is chosen — the one with
the latest issue among those carrying a day row — and every published value
(the three lines, hourly p_le0, day p_any_le0) comes from that vintage only, so
a line of one issue is never shown with the risk of another.
`hourly[(zone, quantity, t)]` for quantity ∈ TSFM_OVERLAY_QUANTITIES;
`day[(zone, date)] = (p_any_le0, input_mode, issue_utc, arm)`. Missing values
stay absent (the exporters write null).
"""
function tsfm_overlay_maps(rows)
    rows = collect(rows)
    best = Dict{Tuple{String,Date},Tuple{DateTime,String,String}}()
    for r in rows
        (r.level == "day" && r.q == "p_any_le0") || continue
        k = (String(r.z), Date(r.d))
        cand = (DateTime(r.issue), String(r.m), String(r.arm))
        (!haskey(best, k) || cand[1] > best[k][1]) && (best[k] = cand)
    end
    hourly = Dict{Tuple{String,String,DateTime},Float64}()
    day = Dict{Tuple{String,Date},NamedTuple{(:p_any_le0, :input_mode, :issue_utc, :arm),
                                            Tuple{Float64,String,DateTime,String}}}()
    for r in rows
        k = (String(r.z), Date(r.d))
        b = get(best, k, nothing)
        (b === nothing || (DateTime(r.issue), String(r.m), String(r.arm)) != b) && continue
        (r.v === missing || r.v === nothing) && continue
        if r.level == "hour" && String(r.q) in TSFM_OVERLAY_QUANTITIES
            hourly[(k[1], String(r.q), DateTime(r.t))] = Float64(r.v)
        elseif r.level == "day" && r.q == "p_any_le0"
            day[k] = (p_any_le0=Float64(r.v), input_mode=b[2], issue_utc=b[1], arm=b[3])
        end
    end
    return hourly, day
end
