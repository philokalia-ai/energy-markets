# D-1 vintage discipline for open-meteo forecast fetches — single definition,
# included by weather_res.jl AND weather_load.jl (idempotent: a plain function
# redefinition, no consts), so the two fetch layers cannot drift.

using Dates

"""
    _batch_all_empty(parsed, batch) -> Bool

True when a parsed open-meteo batch carries NO usable hour for ANY requested
cell — i.e. every cell's hour series is empty. This is the exact shape a
self-hosted instance returns for `previous_dayN` it cannot serve: HTTP 200 with
all-null arrays that the parser then drops. Pure; the trigger for the null-data
public fallback shared by `fetch_weather` and `fetch_load_weather`. Defined here
(the single shared include) so the two fetch layers cannot drift.
"""
_batch_all_empty(parsed::AbstractDict, batch::AbstractVector) =
    all(c -> isempty(get(parsed, c, ())), batch)

"""
    openmeteo_vintage_lag(market_day::Date; asof::Date=Date(now(UTC))) -> Int

D-1-vintage discipline: for market day D the admissible weather input is the
forecast ISSUED on D-1 (or earlier, at longer leads). Returns `0` when running
on or before D-1 — the live forecast API's *current* run is then itself an
admissible vintage — and `1` when running on or after D: the previous-runs
API's `_previous_day1` variables are **per-timestamp** (for hour h of day D
they carry the value predicted by the run issued on D-1 — the semantics
measured and documented in `test/scripts/dn_load_fetch.py` and
`docs/experiments/dn-load-model/README.md`, NOT "the run N days before now"),
so a constant lag of 1 pins the D-1-issued vintage for ANY past day the API's
history covers (dense from ~2024-07 for gfs_seamless). Days beyond that
coverage degrade per-day (null hours → the zone-day goes ineligible loudly),
never by killing the run.

Deliberate looseness, documented: admissibility is Date-granular ("issued on
D-1"), not gate-granular — a lag-0 fetch late on D-1 may use a run initialized
after the 12:00 CET auction gate. The discipline excludes delivery-day
lookahead; it does not reconstruct the bidders' exact pre-gate information set.
"""
openmeteo_vintage_lag(market_day::Date; asof::Date=Date(now(UTC))) =
    asof <= market_day - Day(1) ? 0 : 1

"""
    openmeteo_retro_vintage_lag(lead_days::Int) -> Int

RETRO reconstruction discipline (docs/experiments/pregate-7lead.md): to
reconstruct "what the forecast would have said at lead `n` for a PAST delivery
day D", every weather feature must come from the run issued `n` days before D —
the open-meteo previous-runs API's `_previous_day{n}` variable (per-timestamp:
for hour h it carries the value predicted by the run issued issue-date(h) − n).
So the admissible vintage lag for a lead-`n` retro slice is simply `n`, clamped
to the API's 1..7 previous-runs coverage.

Unlike the LIVE lag (`openmeteo_vintage_lag`, 0/1 — a FUTURE day's current run
is already horizon-natural, and lag 0 IS the run issued D−lead), the retro lag
EQUALS the lead: for a past D the D−n-issued run is recovered only through
`_previous_day{n}`. Models were trained on `previous_day1`; serving day-n
vintages of the SAME variables is the declared convention whose skill cost the
per-lead scoreboard measures — that IS the validation.
"""
openmeteo_retro_vintage_lag(lead_days::Int) = clamp(lead_days, 1, 7)

# ---------------------------------------------------------------------------
# Public GAP-FILL for a self-hosted primary (#431 R3).
#
# The cv44 retro backfill (run 43990408427) skipped 2026-09-14..10-17 because the
# self-hosted instance holds previous-run data only from ~2026-10-17 03:00 UTC:
#   * older batches came back HTTP 200 all-null — the pack fetchers fell back to
#     the public previous-runs API, but the ML overlay's 4-variable RES fetch
#     (`fetch_ml_res_weather`) had NO fallback, so the overlay replaced every
#     pilot zone's RES with an EMPTY series and `res_covered_for_day` failed for
#     all 39 zones;
#   * the batch straddling the boundary came back PARTIAL (null before 10-17
#     03:00, values after) — not "all empty", so nothing fell back and the market
#     days before the boundary went ineligible on every input.
# The fix: every previous-runs fetch (pack RES, pack load, ML RES) asks the public
# API for the batch whenever the primary leaves ANY requested cell-hour empty, and
# fills ONLY those cell-hours (a primary hour is never overwritten). Both serve the
# same `<var>_previous_day{n}` of the same `models=` (gfs_seamless), so the vintage
# discipline is unchanged; only the server differs. The live lag-0 path keeps the
# all-null-only fallback (a partial live answer is not gap-filled).
# Kill switch: EUPHEMIA_OPENMETEO_GAPFILL=0 restores the previous behaviour exactly
# (pack fetchers: all-null fallback only; ML RES fetch: no fallback at all).
# ---------------------------------------------------------------------------

"Whether the public gap-fill is on (`EUPHEMIA_OPENMETEO_GAPFILL=0` switches it off)."
openmeteo_gapfill_enabled() = get(ENV, "EUPHEMIA_OPENMETEO_GAPFILL", "1") != "0"

"The UTC hours a `start_date=d0 .. end_date=d1` open-meteo request asks for."
openmeteo_request_hours(d0::Date, d1::Date) = collect(DateTime(d0):Hour(1):DateTime(d1) + Hour(23))

"Requested (cell, hour) pairs of `batch` × `hours` with no usable value in `parsed`. Pure."
function _batch_missing_cell_hours(parsed::AbstractDict, batch::AbstractVector, hours::AbstractVector)
    n = 0
    for c in batch
        s = get(parsed, c, nothing)
        n += s === nothing ? length(hours) : count(h -> !haskey(s, h), hours)
    end
    return n
end

"""
    _public_fallback_mode(parsed, batch, hours; prevruns, can_fallback) -> Symbol

What to do with a primary batch answer: `:all_null` (nothing usable — replace with
the public answer; the pre-R3 behaviour), `:gaps` (some cell-hours missing on a
previous-runs fetch — fill them from the public answer; R3, behind the kill
switch) or `:none`. Pure.
"""
function _public_fallback_mode(parsed::AbstractDict, batch::AbstractVector, hours::AbstractVector;
                               prevruns::Bool, can_fallback::Bool)
    can_fallback || return :none
    _batch_all_empty(parsed, batch) && return :all_null
    (prevruns && openmeteo_gapfill_enabled() &&
     _batch_missing_cell_hours(parsed, batch, hours) > 0) && return :gaps
    return :none
end

"""
    _gapfill_merge!(primary, public, batch) -> Int

Add to each `batch` cell's series in `primary` the hours it lacks, taken from
`public`; a primary hour is never overwritten. Returns the cell-hours filled. Pure.
"""
function _gapfill_merge!(primary::AbstractDict, public::AbstractDict, batch::AbstractVector)
    n = 0
    for c in batch
        pub = get(public, c, nothing)
        pub === nothing && continue
        pri = get!(() -> empty(pub), primary, c)
        for (h, v) in pub
            haskey(pri, h) || (pri[h] = v; n += 1)
        end
    end
    return n
end

"Earliest hour any cell of `parsed` carries (nothing when empty) — where the primary's data starts."
function _first_hour(parsed::AbstractDict)
    f = nothing
    for s in values(parsed), h in keys(s)
        (f === nothing || h < f) && (f = h)
    end
    return f
end

# Per-batch fetch record for the self-diagnosing retro skip line (#431 R3). A plain
# global (this file is included more than once; no const redefinition).
isdefined(@__MODULE__, :WEATHER_FETCH_LOG) || global WEATHER_FETCH_LOG = NamedTuple[]

"Clear the per-batch weather fetch record (call before a chunk's preparation)."
reset_weather_fetch_log!() = empty!(WEATHER_FETCH_LOG)

"Record one fetched batch: `kind` (\"res\", \"load\", \"ml-res\"), sizes, what fell back, what is still missing."
function _log_weather_batch!(kind::AbstractString, n_cellhours::Int, primary_missing::Int,
                             action::Symbol, final_missing::Int, primary_first)
    length(WEATHER_FETCH_LOG) >= 100_000 && popfirst!(WEATHER_FETCH_LOG)   # bounded in long processes
    push!(WEATHER_FETCH_LOG, (kind=String(kind), cellhours=n_cellhours, primary_missing=primary_missing,
                              action=action, final_missing=final_missing, primary_first=primary_first))
    return nothing
end

"""
    weather_fetch_summary(log=WEATHER_FETCH_LOG) -> Vector{String}

One line per fetch kind: batches, how many the primary answered completely / all
null / with gaps (and what the public API filled), the primary's first data hour,
and the cell-hours still missing after the fallback (> 0 means the public API
could not serve them either: rate limit after retries, or beyond its coverage).
`action` `:primary_off` marks a batch whose primary was missing with no fallback
allowed (kill switch, explicit base_url, or the primary IS public). Pure.
"""
function weather_fetch_summary(log::AbstractVector=WEATHER_FETCH_LOG)
    out = String[]
    for kind in unique(r.kind for r in log)
        rs = [r for r in log if r.kind == kind]
        ch = sum(r.cellhours for r in rs)
        n_ok = count(r -> r.primary_missing == 0, rs)
        n_null = count(r -> r.action == :all_null, rs)
        n_gap = count(r -> r.action == :gaps, rs)
        n_nofb = count(r -> r.primary_missing > 0 && r.action in (:none, :primary_off), rs)
        firsts = [r.primary_first for r in rs if r.primary_first !== nothing]
        fin = sum(r.final_missing for r in rs)
        push!(out, "$kind: $(length(rs)) batch(es); primary complete $n_ok, all-null→public $n_null, " *
                   "gaps→public-filled $n_gap" * (n_nofb > 0 ? ", missing with NO fallback $n_nofb" : "") *
                   "; primary data from " * (isempty(firsts) ? "— (none)" : Dates.format(minimum(firsts), "yyyy-mm-dd HH:MM")) *
                   "; still missing $fin/$ch cell-hours")
    end
    return out
end

"""
    _fetch_batch_with_fallback(kind, url, url_base, public_default, batch, hours;
                               get_fn, parse_fn, prevruns, can_fallback, http_fallback=can_fallback)

One open-meteo batch with the local-instance-first fallbacks, shared by
`fetch_weather`, `fetch_load_weather` and `fetch_ml_res_weather` so they cannot
drift (the R3 bug was exactly such a drift):
1. HTTP failure of the primary → the same request on `public_default`
   (when `http_fallback`; otherwise rethrown);
2. all-null primary answer → replaced by the public answer (pre-R3 behaviour);
3. partial primary answer on a previous-runs fetch → the missing cell-hours are
   filled from the public answer, primary hours kept (R3; kill switch
   `EUPHEMIA_OPENMETEO_GAPFILL=0`). A failing public request here keeps the
   partial primary answer (what pre-R3 returned) with a warning.
Every batch is recorded in `WEATHER_FETCH_LOG` for `weather_fetch_summary`.
"""
function _fetch_batch_with_fallback(kind::AbstractString, url::String, url_base::AbstractString,
                                    public_default::AbstractString, batch::AbstractVector,
                                    hours::AbstractVector; get_fn, parse_fn, prevruns::Bool,
                                    can_fallback::Bool, http_fallback::Bool=can_fallback)
    fb_url = replace(url, url_base => public_default)
    n_ch = length(batch) * length(hours)
    http_failed = false
    body = try
        get_fn(url)
    catch e
        http_fallback || rethrow(e)
        @warn "open-meteo primary ($url_base) failed; falling back to public API" exception=e
        http_failed = true
        get_fn(fb_url)
    end
    parsed = parse_fn(body)
    if http_failed
        miss = _batch_missing_cell_hours(parsed, batch, hours)
        _log_weather_batch!(kind, n_ch, n_ch, :http_error, miss, nothing)
        return parsed
    end
    primary_missing = _batch_missing_cell_hours(parsed, batch, hours)
    primary_first = _first_hour(parsed)
    mode = _public_fallback_mode(parsed, batch, hours; prevruns, can_fallback)
    if mode === :all_null
        @warn "open-meteo primary ($url_base) returned all-null data; falling back to public API"
        parsed = parse_fn(get_fn(fb_url))
    elseif mode === :gaps
        @warn "open-meteo primary ($url_base) left $primary_missing/$n_ch cell-hours null " *
              "(primary data from $primary_first); filling them from the public API"
        try
            _gapfill_merge!(parsed, parse_fn(get_fn(fb_url)), batch)
        catch e
            @warn "public gap-fill failed — keeping the partial primary answer" exception=e
        end
    end
    action = (primary_missing > 0 && mode === :none) ? :primary_off : mode
    _log_weather_batch!(kind, n_ch, primary_missing, action,
                        _batch_missing_cell_hours(parsed, batch, hours), primary_first)
    return parsed
end
