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

# ---------------------------------------------------------------------------
# Public open-meteo cost, on-disk previous-runs cache and a per-chunk breaker
# (#431 R3 follow-up: run 44083012266 died on an exhausted public 429).
# ---------------------------------------------------------------------------

"The free (non-commercial) open-meteo limits, in weighted calls."
openmeteo_free_limits() = (minute=600, hour=5000, day=10000)

"""
    openmeteo_call_weight(n_locations, n_vars, n_days) -> Float64

open-meteo's weighted-call count for one request, as its server computes it
(`ForecastApiResult.calculateQueryWeight`): per location
`max(1, max(v/10, v/10 · d/14))`, summed over locations, where `v` is variables ×
models and `d` the requested days. Below 10 variables and 140/v days a request
costs exactly one call per location: the number of locations per request does not
change the total, and longer date windows are free up to that bound. Pure.
"""
openmeteo_call_weight(n_locations::Integer, n_vars::Integer, n_days::Integer) =
    n_locations * max(1.0, max(n_vars / 10, n_vars / 10 * n_days / 14))

"""
    openmeteo_url_shape(url) -> (locations, variables, days) or nothing

The weight-relevant shape of an open-meteo request URL: the number of
`latitude=` entries, `hourly=` variables × `models=` entries, and days in
`start_date..end_date` (7, the API default, when absent). Pure.
"""
function openmeteo_url_shape(url::AbstractString)
    parts = split(url, '?'; limit=2)
    length(parts) == 2 || return nothing
    kv = Dict{String,String}()
    for p in split(parts[2], '&')
        i = findfirst('=', p)
        i === nothing || (kv[String(p[1:i-1])] = String(p[i+1:end]))
    end
    (haskey(kv, "latitude") && haskey(kv, "hourly")) || return nothing
    nmod = haskey(kv, "models") ? length(split(kv["models"], ',')) : 1
    nd = (haskey(kv, "start_date") && haskey(kv, "end_date")) ?
         Dates.value(Date(kv["end_date"]) - Date(kv["start_date"])) + 1 : 7
    return (locations=length(split(kv["latitude"], ',')),
            variables=length(split(kv["hourly"], ',')) * nmod, days=nd)
end

"True for a request to open-meteo's own (rate-limited) servers."
_is_public_openmeteo(url::AbstractString) = occursin(r"^https?://[^/?]*open-meteo\.com(/|$)", url)

"Directory of the on-disk previous-runs cache; empty (the default) = no cache."
openmeteo_cache_dir() = String(strip(get(ENV, "EUPHEMIA_OPENMETEO_CACHE_DIR", "")))

# 64-bit FNV-1a: stable across Julia versions and processes (Base.hash is not).
function _fnv1a64(s::AbstractString, h::UInt64)
    for b in codeunits(s)
        h = (h ⊻ UInt64(b)) * 0x00000100000001b3
    end
    return h
end
"Cache file stem for `url` (128 bits from two FNV-1a passes; the exact URL is stored beside it)."
_openmeteo_cache_key(url::AbstractString) =
    string(_fnv1a64(url, 0xcbf29ce484222325); base=16, pad=16) *
    string(_fnv1a64(url, 0x84222325cbf29ce4); base=16, pad=16)

"""
    _openmeteo_cacheable(url; today) -> Bool

Only previous-run (`_previous_dayN`) requests whose whole window lies before
`today` (UTC) are cached: that data is a fixed past vintage and never changes. The
live lag-0 forecast and any window touching today or later are never cached. Pure.
"""
function _openmeteo_cacheable(url::AbstractString; today::Date=Date(now(UTC)))
    occursin("_previous_day", url) || return false
    m = match(r"[?&]end_date=(\d{4}-\d{2}-\d{2})", url)
    return m !== nothing && Date(m[1]) < today
end

"The cached body for exactly `url`, or nothing (cache off, not cacheable, absent, unreadable)."
function _openmeteo_cache_read(url::AbstractString)
    dir = openmeteo_cache_dir()
    (isempty(dir) || !_openmeteo_cacheable(url)) && return nothing
    k = _openmeteo_cache_key(url)
    fb, fu = joinpath(dir, k * ".json"), joinpath(dir, k * ".url")
    (isfile(fb) && isfile(fu)) || return nothing
    try
        read(fu, String) == url || return nothing   # exact request only
        return read(fb, String)
    catch
        return nothing
    end
end

"Store `body` for exactly `url` (atomic renames; a failure only warns)."
function _openmeteo_cache_write(url::AbstractString, body::AbstractString)
    dir = openmeteo_cache_dir()
    (isempty(dir) || !_openmeteo_cacheable(url)) && return false
    k = _openmeteo_cache_key(url)
    try
        mkpath(dir)
        for (ext, s) in ((".json", body), (".url", url))   # body first: a reader needs both
            tmp = joinpath(dir, k * ext * ".tmp" * string(getpid()))
            write(tmp, s)
            mv(tmp, joinpath(dir, k * ext); force=true)
        end
        return true
    catch e
        @warn "open-meteo cache write failed (the fetch itself is unaffected)" exception=e
        return false
    end
end

# Per-chunk public breaker (retro only; armed by run_retro): after a public request
# failed with its retries exhausted, later public requests in the same chunk fail
# at once instead of each spending ~2 min of 429 retries. Never armed live.
isdefined(@__MODULE__, :OPENMETEO_BREAKER_ARMED) || global OPENMETEO_BREAKER_ARMED = Ref(false)
isdefined(@__MODULE__, :OPENMETEO_BREAKER_OPEN) || global OPENMETEO_BREAKER_OPEN = Ref(false)
"Arm (or disarm) the per-chunk public breaker; `reset_weather_fetch_log!` closes it."
openmeteo_breaker_arm!(on::Bool=true) = (OPENMETEO_BREAKER_ARMED[] = on; OPENMETEO_BREAKER_OPEN[] = false; on)

# Per-batch fetch record for the self-diagnosing retro skip line (#431 R3). A plain
# global (this file is included more than once; no const redefinition).
isdefined(@__MODULE__, :WEATHER_FETCH_LOG) || global WEATHER_FETCH_LOG = NamedTuple[]

"Clear the per-batch weather fetch record and close the public breaker (call before a chunk's preparation)."
reset_weather_fetch_log!() = (OPENMETEO_BREAKER_OPEN[] = false; empty!(WEATHER_FETCH_LOG))

"""
Record one fetched batch: `kind` ("res", "load", "ml-res"), sizes, what fell back,
what is still missing, and the public-API accounting: `weight` (what this batch
costs when served publicly), public requests made / their weighted calls / failed /
skipped by the breaker, and cache hits.
"""
function _log_weather_batch!(kind::AbstractString, n_cellhours::Int, primary_missing::Int,
                             action::Symbol, final_missing::Int, primary_first; public_ok::Bool=false,
                             weight::Real=0.0, nvars::Int=0, ndays::Int=0, pub_req::Int=0,
                             pub_weight::Real=0.0, pub_fail::Int=0, pub_skip::Int=0, cache_hits::Int=0)
    length(WEATHER_FETCH_LOG) >= 100_000 && popfirst!(WEATHER_FETCH_LOG)   # bounded in long processes
    push!(WEATHER_FETCH_LOG, (kind=String(kind), cellhours=n_cellhours, primary_missing=primary_missing,
                              action=action, final_missing=final_missing, primary_first=primary_first,
                              public_ok=public_ok, weight=Float64(weight), nvars=nvars, ndays=ndays,
                              pub_req=pub_req, pub_weight=Float64(pub_weight), pub_fail=pub_fail,
                              pub_skip=pub_skip, cache_hits=cache_hits))
    return nothing
end

_fmt_calls(x::Real) = string(round(Int, x))

"""
    weather_fetch_summary(log=WEATHER_FETCH_LOG) -> Vector{String}

One line per fetch kind: batches, how many the primary answered completely / all
null / with gaps, how many gap batches the public API actually filled (its request
succeeded and recovered at least one cell-hour) and how many cell-hours it recovered
(a gap attempt whose public request failed counts as attempted, not filled), the
primary's first data hour, the cell-hours still missing after the fallback (> 0
means the public API could not serve them either: rate limit after retries, or
beyond its coverage), and the public-API requests and weighted calls actually spent
plus cache hits. `action` `:primary_off` marks a batch whose primary was missing
with no fallback allowed (kill switch, explicit base_url, or the primary IS
public); `:failed` a batch whose fetch threw. Pure.
"""
function weather_fetch_summary(log::AbstractVector=WEATHER_FETCH_LOG)
    out = String[]
    for kind in unique(r.kind for r in log)
        rs = [r for r in log if r.kind == kind]
        ch = sum(r.cellhours for r in rs)
        n_ok = count(r -> r.primary_missing == 0, rs)
        n_null = count(r -> r.action == :all_null, rs)
        n_gap = count(r -> r.action == :gaps, rs)
        gaps_filled = [r for r in rs if r.action == :gaps && r.public_ok && r.final_missing < r.primary_missing]
        n_gap_ok = length(gaps_filled)
        ch_gap_ok = isempty(gaps_filled) ? 0 : sum(r.primary_missing - r.final_missing for r in gaps_filled)
        n_nofb = count(r -> r.primary_missing > 0 && r.action in (:none, :primary_off), rs)
        n_failed = count(r -> r.action == :failed, rs)
        firsts = [r.primary_first for r in rs if r.primary_first !== nothing]
        fin = sum(r.final_missing for r in rs)
        g(f) = sum((getproperty(r, f) for r in rs if hasproperty(r, f)); init=0)
        pf, ps = g(:pub_fail), g(:pub_skip)
        push!(out, "$kind: $(length(rs)) batch(es); primary complete $n_ok, all-null→public $n_null, " *
                   "gaps→public attempted $n_gap, filled $n_gap_ok ($ch_gap_ok cell-hours)" *
                   (n_nofb > 0 ? ", missing with NO fallback $n_nofb" : "") *
                   (n_failed > 0 ? ", FAILED $n_failed" : "") *
                   "; primary data from " * (isempty(firsts) ? "— (none)" : Dates.format(minimum(firsts), "yyyy-mm-dd HH:MM")) *
                   "; still missing $fin/$ch cell-hours" *
                   "; public API $(g(:pub_req)) request(s) ≈$(_fmt_calls(g(:pub_weight))) weighted call(s)" *
                   (pf > 0 ? ", $pf failed" : "") * (ps > 0 ? ", $ps skipped (breaker)" : "") *
                   ", cache hits $(g(:cache_hits))")
    end
    return out
end

"""
    openmeteo_budget_lines(log=WEATHER_FETCH_LOG; span_days, chunk_days, n_zone_calls,
                           throttle_s, limits=openmeteo_free_limits(), headroom=0.9) -> Vector{String}

The public-API cost of one retro chunk and a request size / rate that stays under
open-meteo's free limits (`limits`, weighted calls per minute / hour / day, used at
`headroom`). "Worst case" is the chunk with every batch served publicly and no cache
(each batch's request weight, `openmeteo_call_weight`); "spent" is what the public
requests of this chunk actually cost. `span_days` is the chunk's UTC span,
`n_zone_calls` the throttled per-zone fetch calls (the sleep of
`EUPHEMIA_OPENMETEO_ZONE_THROTTLE` = `throttle_s` precedes each). Pure.
"""
function openmeteo_budget_lines(log::AbstractVector=WEATHER_FETCH_LOG; span_days::Int, chunk_days::Int,
                                n_zone_calls::Int, throttle_s::Real,
                                limits=openmeteo_free_limits(), headroom::Real=0.9)
    rs = [r for r in log if hasproperty(r, :weight)]
    isempty(rs) && return String[]
    wc = sum(r.weight for r in rs)
    spent = sum(r.pub_weight for r in rs)
    nreq = sum(r.pub_req for r in rs)
    hits = sum(r.cache_hits for r in rs)
    fails = sum(r.pub_fail for r in rs); skips = sum(r.pub_skip for r in rs)
    per_min, per_h, per_d = headroom * limits.minute, headroom * limits.hour, headroom * limits.day
    out = String[]
    push!(out, "public open-meteo this chunk: $nreq request(s), ≈$(_fmt_calls(spent)) weighted call(s) spent, " *
               "$hits cache hit(s)" * (fails > 0 ? ", $fails failed" : "") * (skips > 0 ? ", $skips skipped by the breaker" : "") *
               "; free limits $(limits.minute)/min, $(limits.hour)/h, $(limits.day)/day")
    wc > 0 || return out
    partial = any(r -> r.action == :failed, rs) ? " (only the batches reached before the failure)" : ""
    push!(out, "worst case (every batch public, no cache)$partial: $(length(rs)) request(s) ≈$(_fmt_calls(wc)) weighted calls " *
               "(1 per location below 10 variables and 140/variables days) ⇒ at most " *
               "$(floor(Int, per_h / wc)) such chunk(s) per hour and $(floor(Int, per_d / wc)) per day " *
               "at $(round(Int, 100headroom))% of the limits")
    nz = max(n_zone_calls, 1)
    t_min = 60 * wc / (per_min * nz)
    t_hour = 3600 * wc / (per_h * nz)
    push!(out, "rate: a fully public chunk needs ≥ $(ceil(Int, wc / per_min)) min of fetching for the per-minute limit; " *
               "EUPHEMIA_OPENMETEO_ZONE_THROTTLE ≥ $(round(t_min; digits=1)) s over $nz zone call(s) holds it " *
               "(≥ $(round(t_hour; digits=1)) s if chunks fetch back to back within an hour); now $(throttle_s) s")
    # Request size: the weight is per location, so locations per request do not
    # change it; the date window is free while v/10·d/14 ≤ 1, i.e. d ≤ 140/v.
    nmax = minimum(floor(Int, 140 / max(r.nvars, 1)) - max(r.ndays - span_days, 0) - 1 for r in rs)
    push!(out, "request size: locations per request do not change the weight (keep ≤50 per request); a chunk of up to " *
               "$nmax day(s) (EUPHEMIA_RETRO_CHUNK_DAYS, now $chunk_days) still costs 1 call per location ⇒ a fully " *
               "public window costs ≈$(_fmt_calls(wc / max(chunk_days, 1))) calls/day at $chunk_days-day chunks, " *
               "≈$(_fmt_calls(wc / max(nmax, 1))) at $nmax")
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
Every request first consults the on-disk cache (`EUPHEMIA_OPENMETEO_CACHE_DIR`; off
by default) and stores a complete past previous-runs answer there. With the retro
breaker armed, a public request after an exhausted one in the same chunk fails at
once. Every batch is recorded in `WEATHER_FETCH_LOG` for `weather_fetch_summary`
and `openmeteo_budget_lines`, a failing one as `:failed` before the rethrow.
"""
function _fetch_batch_with_fallback(kind::AbstractString, url::String, url_base::AbstractString,
                                    public_default::AbstractString, batch::AbstractVector,
                                    hours::AbstractVector; get_fn, parse_fn, prevruns::Bool,
                                    can_fallback::Bool, http_fallback::Bool=can_fallback)
    fb_url = replace(url, url_base => public_default)
    n_ch = length(batch) * length(hours)
    shape = openmeteo_url_shape(url)
    w = shape === nothing ? 0.0 : openmeteo_call_weight(shape...)
    nv, nd = shape === nothing ? (0, 0) : (shape.variables, shape.days)
    acct = Dict(:pub_req => 0, :pub_fail => 0, :pub_skip => 0, :hits => 0)
    pub_w = Ref(0.0)
    from_cache = Set{String}()
    # Body for `u`: the cache, else the network (public accounting + breaker).
    fetch_body = function (u::String)
        b = _openmeteo_cache_read(u)
        b === nothing || (acct[:hits] += 1; push!(from_cache, u); return b)
        pub = _is_public_openmeteo(u)
        if pub && OPENMETEO_BREAKER_ARMED[] && OPENMETEO_BREAKER_OPEN[]
            acct[:pub_skip] += 1
            error("public open-meteo request skipped: an earlier public request in this chunk " *
                  "exhausted its retries (breaker open until the next chunk)")
        end
        b = try
            get_fn(u)
        catch e
            if pub && !(e isa InterruptException)
                acct[:pub_fail] += 1
                OPENMETEO_BREAKER_ARMED[] && (OPENMETEO_BREAKER_OPEN[] = true)
            end
            rethrow()
        end
        if pub
            acct[:pub_req] += 1
            s = openmeteo_url_shape(u)
            s === nothing || (pub_w[] += openmeteo_call_weight(s...))
        end
        return b
    end
    # Cache a complete answer (not one read from the cache); partial/null answers never.
    store! = (u, b, p) -> (u in from_cache || _batch_missing_cell_hours(p, batch, hours) > 0 ||
                           _openmeteo_cache_write(u, b); nothing)
    record!(action, primary_missing, final_missing, first_h; public_ok=false) =
        _log_weather_batch!(kind, n_ch, primary_missing, action, final_missing, first_h; public_ok,
                            weight=w, nvars=nv, ndays=nd, pub_req=acct[:pub_req], pub_weight=pub_w[],
                            pub_fail=acct[:pub_fail], pub_skip=acct[:pub_skip], cache_hits=acct[:hits])
    try
        http_failed = false
        used = url
        body = try
            fetch_body(url)
        catch e
            http_fallback || rethrow(e)
            @warn "open-meteo primary ($url_base) failed; falling back to public API" exception=e
            http_failed = true
            used = fb_url
            fetch_body(fb_url)
        end
        parsed = parse_fn(body)
        store!(used, body, parsed)
        if http_failed
            miss = _batch_missing_cell_hours(parsed, batch, hours)
            record!(:http_error, n_ch, miss, nothing; public_ok=true)
            return parsed
        end
        primary_missing = _batch_missing_cell_hours(parsed, batch, hours)
        primary_first = _first_hour(parsed)
        mode = _public_fallback_mode(parsed, batch, hours; prevruns, can_fallback)
        public_ok = false
        if mode === :all_null
            @warn "open-meteo primary ($url_base) returned all-null data; falling back to public API"
            pb = fetch_body(fb_url)
            parsed = parse_fn(pb)
            store!(fb_url, pb, parsed)
            public_ok = true
        elseif mode === :gaps
            @warn "open-meteo primary ($url_base) left $primary_missing/$n_ch cell-hours null " *
                  "(primary data from $primary_first); filling them from the public API"
            try
                pb = fetch_body(fb_url)
                pp = parse_fn(pb)
                store!(fb_url, pb, pp)
                _gapfill_merge!(parsed, pp, batch)
                public_ok = true
            catch e
                e isa InterruptException && rethrow()
                @warn "public gap-fill failed — keeping the partial primary answer" exception=e
            end
        end
        action = (primary_missing > 0 && mode === :none) ? :primary_off : mode
        record!(action, primary_missing, _batch_missing_cell_hours(parsed, batch, hours), primary_first; public_ok)
        return parsed
    catch e
        e isa InterruptException || record!(:failed, n_ch, n_ch, nothing)
        rethrow()
    end
end
