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
