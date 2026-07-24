# flows_imports.jl — Physical-flow day cache, net imports (d0/ex-ante), import ATC capacity, import backstop, unit->firm map.
# Included by ../MeritOrderBook.jl inside `module MeritOrderBook` (definition order preserved).

# --- Day-level physical-flow cache (shared by get_net_imports and
#     get_dropped_border_exports) ---------------------------------------------
# `entsoe.physical_flows` is scanned ONCE per day for ALL zones and cached; each
# per-zone call then slices and filters the cached border relation in Julia.
# Previously every zone (× two functions, × two passes) re-scanned the whole
# day's flows, so a 39-zone book paid ~50 near-identical scans. Errors are never
# cached (transient failures must be retried). Thread/process-safe via a lock;
# each reproduce worker is its own process with its own per-day cache.
const _NetBorderRow = NamedTuple{(:h, :in_code, :out_code, :avg_flow),
                                 Tuple{Int,String,String,Float64}}
const _NET_IMPORTS_DAY_CACHE = Dict{Date,Vector{_NetBorderRow}}()
const _NET_IMPORTS_CACHE_LOCK = ReentrantLock()

# --- Ex-ante flow lag (issue: same-day observed physical flows are the ONE
# forward-looking leak in the book). `entsoe.physical_flows` for the target day
# are the REALIZED flows of that day — not knowable at the D-1 auction. When
# FLOW_ASOF_LAG[] > 0, `_net_imports_day_relation` reads the flows of `day - lag`
# instead (D-2, or D-7 for the same weekday), so the observed-import supply,
# the dropped-border import-only clamp, and the ref-priced exports all use only
# information available before the auction. Default 0 = byte-identical to the
# D-0 product (the counterfactual's committed behaviour is unchanged until a
# forward product opts in). See docs/ex-ante-audit.md.
# Initialized to 0 here (precompile time); Euphemia.__init__ sets it from
# EUPHEMIA_FLOW_ASOF_LAG at RUNTIME so a cached precompiled image can't bake in
# a stale value.
const FLOW_ASOF_LAG = Ref{Int}(0)

# Which border CLASS the ex-ante lag applies to (env EUPHEMIA_FLOW_ASOF_CLASS,
# set at runtime in Euphemia.__init__; only meaningful when FLOW_ASOF_LAG > 0):
#   :all      — every observed flow lags (the iter6 audit variant, default)
#   :dropped  — only DROPPED flow-based borders lag (the import-only clamp and
#               the ref-priced dropped-border exports); every retained
#               injection stays same-day
#   :retained — only the RETAINED observed injections lag (out-of-footprint
#               counterparties like TR/AL/UA/GB plus in-footprint borders with
#               no usable ATC); dropped borders stay same-day
# Used by the ex-ante Phase-2 diagnosis to attribute the D-lag accuracy cost
# per border class (docs/ex-ante-flows.md).
const FLOW_ASOF_CLASS = Ref{Symbol}(:all)

# Ex-ante flow SOURCE mode (env EUPHEMIA_FLOW_ASOF_MODE, runtime-set):
#   :d0   — same-day observed flows (default; the committed byte-identical
#           product for the backward-looking analytical counterfactual)
#   :dlag — the flows of `day - FLOW_ASOF_LAG` (D-2 / D-7 audit variants)
#   :clim — flow climatology: per (border, hour) MEDIAN over the trailing
#           8 same-weekday days (D-7, D-14, …, D-56 — all strictly before
#           the D-1 auction). Interpretable, no fitting, versioned here.
#   :v3   — :v2 plus load-analogue blending on non-Nordic borders
#           (docs/experiments/analogue-flows): thermal-regime analogue days
#           selected by D-1 load-forecast similarity. Opt-in (env/kwarg).
#   :v2   — the measured best ex-ante mix (docs/ex-ante-flows.md): D-7 for
#           borders touching a NORDIC hydro zone (regime-switching flows —
#           reservoir state persists week to week, so recency wins; the
#           8-week median mis-states the current regime and blew NO1 up
#           +99 MAE), flow climatology for everything else (thermal/transit
#           borders are noisy — the median beats any single lagged draw; it
#           healed HU/SK where D-7 cost −0.4/−0.6 corr).
# FLOW_ASOF_CLASS selects WHICH borders get the ex-ante replacement; the rest
# stay same-day. See docs/ex-ante-flows.md.
const FLOW_ASOF_MODE = Ref{Symbol}(:d0)

# Whether FLOW_ASOF_MODE was set EXPLICITLY (env EUPHEMIA_FLOW_ASOF_MODE
# present, or a caller passed ex_ante_mode). When false, the EU-footprint
# multi-zone path (enrich_network=true) defaults to :v2 — the forward product —
# while the SEE legacy paths (single-zone, 5-zone multi_zone with
# enrich_network=false) keep :d0 and their byte-identity. See
# docs/ex-ante-flows.md and run_multi_zone_market_clearing.
const FLOW_ASOF_MODE_EXPLICIT = Ref{Bool}(false)

# Norwegian reservoir zones for the :v2 border split (recency beats
# climatology there). Measured refinement: with the full Nordic set (incl.
# FI/SE/DK) FI regressed −0.13 corr — its SE1/SE3 imports prefer the
# climatology; only the NO* reservoir regimes need the D-7 recency.
const NORDIC_FLOW_ZONES = Set(["NO1", "NO2", "NO3", "NO4", "NO5"])

"""
    set_flow_asof_lag!(n::Int)

Days to lag the observed-physical-flow read (0 = same-day/D-0, the default and
byte-identical product; 2 = D-2; 7 = D-7 same-weekday). Ex-ante correctness for
the forward product — same-day realized flows are not knowable at the D-1
auction. Clears the flow cache so the next build re-reads at the new lag.
"""
function set_flow_asof_lag!(n::Int)
    FLOW_ASOF_LAG[] = n
    clear_net_imports_cache!()
    return n
end

"""
    clear_net_imports_cache!()

Empty the day-level physical-flow border cache (tests / cold-start profiling).
"""
function clear_net_imports_cache!()
    lock(_NET_IMPORTS_CACHE_LOCK) do
        empty!(_NET_IMPORTS_DAY_CACHE)
    end
    return nothing
end

_strip_ips(s::AbstractString) = replace(String(s), r"_IPS$" => "")

# The day's BZN-both-sides directed border relation: one AVG(flow_mw) per
# (hour, in_area_map_code, out_area_map_code). This is the union, over all
# zones, of every per-zone query's inner per-code aggregation — the group
# membership (and therefore the AVG) for any (hour, self, counterparty) pair is
# identical to what the old per-zone query computed.
# Fetch (and cache) the border relation for an EXPLICIT queried day.
function _net_imports_day_relation_at(qday::Date)
    cached = lock(_NET_IMPORTS_CACHE_LOCK) do
        get(_NET_IMPORTS_DAY_CACHE, qday, nothing)
    end
    cached !== nothing && return cached
    df = sql2df_with_retry(
        """
        SELECT EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int AS h,
               in_area_map_code AS in_code,
               out_area_map_code AS out_code,
               AVG(flow_mw) AS avg_flow
        FROM entsoe.physical_flows
        WHERE in_area_type_code LIKE 'BZN%' AND out_area_type_code LIKE 'BZN%'
          AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
        GROUP BY 1, in_area_map_code, out_area_map_code
        """,
        [qday])
    rows = _NetBorderRow[]
    for r in eachrow(df)
        ismissing(r.avg_flow) && continue
        push!(rows, (h=Int(r.h), in_code=String(r.in_code),
                     out_code=String(r.out_code), avg_flow=Float64(r.avg_flow)))
    end
    lock(_NET_IMPORTS_CACHE_LOCK) do
        _NET_IMPORTS_DAY_CACHE[qday] = rows
    end
    return rows
end

# Reconstruct the per-zone `border_hourly` CTE from the cached day relation:
# `(hour, counterparty, direction) => avg_flow`, with the _IPS-alias dedup
# resolved to the largest flow (the old `DISTINCT ON ... ORDER BY avg_flow
# DESC`). `direction` = +1 when the zone is the importing (in) side, -1 when
# exporting (out) side.
function _zone_border_hourly(zone::String, day::Date; lag::Int=FLOW_ASOF_LAG[])
    rel = _net_imports_day_relation_at(day - Day(lag))
    best = Dict{Tuple{Int,String,Int},Float64}()
    for r in rel
        if r.in_code == zone
            cp = _strip_ips(r.out_code); dir = 1
        elseif r.out_code == zone
            cp = _strip_ips(r.in_code); dir = -1
        else
            continue
        end
        key = (r.h, cp, dir)
        prev = get(best, key, nothing)
        (prev === nothing || r.avg_flow > prev) && (best[key] = r.avg_flow)
    end
    return best
end

# Does the ex-ante lag apply to this counterparty under the current class
# setting? (Only consulted when FLOW_ASOF_LAG > 0.)
_lag_applies(cp::String, imponly::Set{String}) =
    FLOW_ASOF_CLASS[] == :all ||
    ((FLOW_ASOF_CLASS[] == :dropped) == (cp in imponly))

# Is any ex-ante replacement active at all?
_exante_active() = FLOW_ASOF_MODE[] in (:clim, :v2, :v3) ||
                   (FLOW_ASOF_MODE[] == :dlag && FLOW_ASOF_LAG[] > 0) ||
                   # legacy: LAG>0 with mode :d0 keeps the iter6 audit behaviour
                   FLOW_ASOF_LAG[] > 0

"""
    _zone_border_hourly_clim(zone, day; weeks=8) -> Dict{(h,cp,dir),Float64}

Flow climatology for a zone's borders: per (hour, counterparty, direction) the
MEDIAN of the observed hourly flow over the trailing `weeks` same-weekday days
(D-7 … D-7·weeks — every input strictly predates the D-1 auction). Borders
absent on some of those days use the median of the days where they exist.
"""
function _zone_border_hourly_clim(zone::String, day::Date; weeks::Int=8)
    acc = Dict{Tuple{Int,String,Int},Vector{Float64}}()
    for k in 1:weeks
        for (key, avg) in _zone_border_hourly(zone, day; lag=7 * k)
            push!(get!(acc, key, Float64[]), avg)
        end
    end
    return Dict{Tuple{Int,String,Int},Float64}(
        key => median(v) for (key, v) in acc)
end

# --- :v3 load-analogue selection (docs/experiments/analogue-flows) ----------
# The delivery day's published D-1 load-forecast vector is matched (L2, 24 UTC
# hours) against the realized load of the trailing 365 days (candidates
# <= day-2, so their load AND flows are published strictly before the D-1
# auction). Flows then come from the per-(hour,border) MEDIAN over the K
# nearest analogue days. Load is the ex-ante thermometer: it is a monotone
# function of temperature (GR: 195 MW/°C below 25°C, 354 above), embeds
# weekday/holiday/tourism, and exists for every zone — so a heatwave week
# finds last summer's analogue days instead of dragging the calendar median
# through a regime flip (measured failure: July 2026 SEE, GR evening bias
# +60..+79 €/MWh at 93-100% day consistency under :v2's 8-week median).
const ANALOGUE_K = Ref{Int}(16)
const _ANALOGUE_DAYS_CACHE = Dict{Tuple{String,Date},Vector{Date}}()
const _ANALOGUE_DAYS_LOCK = ReentrantLock()

function clear_analogue_days_cache!()
    lock(_ANALOGUE_DAYS_LOCK) do
        empty!(_ANALOGUE_DAYS_CACHE)
    end
end

function _load_day_vectors(zone::String, day::Date)
    # Realized 24h load vectors for candidate days [day-365, day-2], plus the
    # delivery day's D-1 forecast vector. Both hourly UTC averages.
    fdf = sql2df_with_retry("""
        SELECT EXTRACT(hour FROM date_time_utc AT TIME ZONE 'UTC')::int AS h,
               AVG(total_load_mw) AS mw
        FROM entsoe.day_ahead_total_load_forecast
        WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
          AND area_map_code = \$2
          AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
        GROUP BY 1
        """, [day, zone])
    adf = sql2df_with_retry("""
        SELECT (date_time_utc AT TIME ZONE 'UTC')::date AS d,
               EXTRACT(hour FROM date_time_utc AT TIME ZONE 'UTC')::int AS h,
               AVG(total_load_mw) AS mw
        FROM entsoe.actual_total_load
        WHERE date_time_utc >= ((\$1::date - 365)::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$1::date - 1)::timestamp AT TIME ZONE 'UTC')
          AND area_map_code = \$2
          AND area_type_code IN ('BZN', 'BZN/CTA', 'BZN/CTY', 'BZN/CTA/CTY')
        GROUP BY 1, 2
        """, [day, zone])
    return fdf, adf
end

"""
    _analogue_days(zone, day; k=ANALOGUE_K[]) -> Vector{Date}

The k candidate days (trailing 365, ≤ day-2) whose realized 24h load vector is
L2-closest to `day`'s published D-1 load forecast vector. Empty when the
forecast or the candidate pool is unavailable — callers fall back to the
calendar climatology (the :v2 source), so :v3 degrades gracefully to :v2.
"""
function _analogue_days(zone::String, day::Date; k::Int=ANALOGUE_K[])
    key = (zone, day)
    # NOTE: a bare `return` inside `lock() do` returns from the CLOSURE and
    # its value is discarded — the original code recomputed on every call
    # (found by the 2026-07-24 performance review: the :v3 analogue queries
    # re-ran per call instead of once per zone-day). Capture and test.
    cached = lock(_ANALOGUE_DAYS_LOCK) do
        get(_ANALOGUE_DAYS_CACHE, key, nothing)
    end
    cached !== nothing && return cached
    had_error = false
    days = try
        fdf, adf = _load_day_vectors(zone, day)
        fv = fill(NaN, 24)
        for r in eachrow(fdf)
            0 <= r.h <= 23 && (fv[r.h+1] = r.mw)
        end
        if any(isnan, fv)
            Date[]
        else
            byday = Dict{Date,Vector{Float64}}()
            for r in eachrow(adf)
                v = get!(byday, r.d, fill(NaN, 24))
                0 <= r.h <= 23 && (v[r.h+1] = r.mw)
            end
            cands = [(d, v) for (d, v) in byday if !any(isnan, v)]
            if length(cands) < k
                Date[]
            else
                sort!(cands, by=t -> sum(abs2, t[2] .- fv))
                sort!([t[1] for t in cands[1:k]])
            end
        end
    catch e
        @warn "analogue-day selection failed for $zone $day — falling back to climatology" error = sprint(showerror, e)
        had_error = true
        Date[]
    end
    # Cache only genuine results (incl. legitimately-empty pools). Errors are
    # NEVER cached — the repo-wide cache rule — so a transient DB failure
    # doesn't silently pin this zone-day to the :v2 fallback for the process.
    if !had_error
        lock(_ANALOGUE_DAYS_LOCK) do
            _ANALOGUE_DAYS_CACHE[key] = days
        end
    end
    return days
end

# Per-(hour,border) MEDIAN of the flows on the analogue days. Reuses the
# day-level relation cache, so the K days are shared across all zones of a
# footprint build.
function _zone_border_hourly_analogue(zone::String, day::Date)
    days = _analogue_days(zone, day)
    isempty(days) && return Dict{Tuple{Int,String,Int},Float64}()
    acc = Dict{Tuple{Int,String,Int},Vector{Float64}}()
    for d in days
        for (key, avg) in _zone_border_hourly(zone, day; lag=Dates.value(day - d))
            push!(get!(acc, key, Float64[]), avg)
        end
    end
    return Dict{Tuple{Int,String,Int},Float64}(
        key => median(v) for (key, v) in acc)
end

# The :v2 source map — measured best ex-ante mix (docs/ex-ante-flows.md):
# D-7 for borders touching a Nordic hydro zone (regime persistence),
# climatology for the rest (noise averaging). Shared by :v2 and :v3.
function _v2_border_map(zone::String, day::Date)
    clim = _zone_border_hourly_clim(zone, day)
    d7 = _zone_border_hourly(zone, day; lag=7)
    mixed = Dict{Tuple{Int,String,Int},Float64}()
    nordic_side(cp) = zone in NORDIC_FLOW_ZONES || cp in NORDIC_FLOW_ZONES
    for (key, avg) in clim
        nordic_side(key[2]) || (mixed[key] = avg)
    end
    for (key, avg) in d7
        nordic_side(key[2]) && (mixed[key] = avg)
    end
    return mixed
end

# The ex-ante source map for the selected class, merged with same-day flows
# for the non-selected counterparties.
function _zone_border_hourly_exante(zone::String, day::Date, imponly::Set{String})
    mode = FLOW_ASOF_MODE[]
    alt = if mode == :clim
        _zone_border_hourly_clim(zone, day)
    elseif mode == :v3
        # anad2 (docs/experiments/analogue-flows, stage-1 round 2): per (hour,
        # border), the MEAN of the load-analogue median and the D-2 observed
        # flow — "half what thermally-similar days did, half what the border
        # did the day before yesterday". D-2 is the fastest admissible signal
        # (realized + published before the D-1 auction) and catches a NEW
        # regime within 48 h; the analogue term supplies stability. Measured
        # footprint net-import MAE: 391 vs v2's 459 overall, 373 vs 445
        # evenings, 388 vs 494 in the July-2026 flip window (GR 589→322).
        # The earlier v2-blend definition scored 437/425/478 and only shaved
        # 3 of GR's +57 evening price bias; a 3-year analogue pool was also
        # measured and REJECTED (structural border drift: 454→479). Borders
        # with only one of {analogue, D-2} use that one; borders with neither
        # keep the :v2 value exactly — graceful degradation to :v2.
        v2map = _v2_border_map(zone, day)
        ana = _zone_border_hourly_analogue(zone, day)
        d2 = _zone_border_hourly(zone, day; lag=2)
        Dict{Tuple{Int,String,Int},Float64}(
            key => (haskey(ana, key) && haskey(d2, key)) ?
                       0.5 * ana[key] + 0.5 * d2[key] :
                   haskey(ana, key) ? ana[key] :
                   haskey(d2, key) ? d2[key] : avg
            for (key, avg) in v2map)
    elseif mode == :v2
        _v2_border_map(zone, day)
    else
        _zone_border_hourly(zone, day; lag=FLOW_ASOF_LAG[])
    end
    bh0 = _zone_border_hourly(zone, day; lag=0)
    chosen = Dict{Tuple{Int,String,Int},Float64}()
    for (key, avg) in bh0
        _lag_applies(key[2], imponly) || (chosen[key] = avg)
    end
    for (key, avg) in alt
        _lag_applies(key[2], imponly) && (chosen[key] = avg)
    end
    return chosen
end

# Group border rows by hour with a deterministic per-hour ordering so the
# floating-point SUM is reproducible run to run.
function _border_rows_by_hour(bh::Dict{Tuple{Int,String,Int},Float64})
    byh = Dict{Int,Vector{Tuple{String,Int,Float64}}}()
    for ((h, cp, dir), avg) in bh
        push!(get!(byh, h, Tuple{String,Int,Float64}[]), (cp, dir, avg))
    end
    for v in values(byh)
        sort!(v)
    end
    return byh
end

function get_net_imports(bidding_zone::String, day::Date;
    exclude_counterparties::Vector{String}=String[],
    import_only_counterparties::Vector{String}=String[])
    # Two normalizations, both required for a correct MW value:
    # 1. AVG per border within the hour — flow_mw is a power value, so a
    #    border published at PT15M has 4 rows/hour; summing rows directly
    #    would inflate that border 4x relative to a PT60M border.
    # 2. Dedup counterparty aliases — some borders are reported twice under
    #    two map codes for the same area (e.g. UA and UA_IPS); strip the
    #    _IPS suffix and keep one row per (hour, counterparty, direction),
    #    deterministically preferring the larger flow.
    # Both are done off the once-per-day cached border relation; the per-zone
    # exclude / import-only filters are applied here in Julia.
    excl = Set(exclude_counterparties)
    imponly = Set(import_only_counterparties)
    # Ex-ante replacement (mode :dlag / :clim, class-selective): each selected
    # counterparty's flow comes from the ex-ante source; the rest stay same-day.
    # Default (:d0, lag 0) keeps the original single-map path bit-identical.
    bh = _exante_active() ?
         _zone_border_hourly_exante(bidding_zone, day, imponly) :
         _zone_border_hourly(bidding_zone, day; lag=0)
    out = Dict{Int,Float64}()
    for (h, rows) in _border_rows_by_hour(bh)
        s = 0.0
        any_kept = false
        for (cp, dir, avg) in rows
            cp in excl && continue
            any_kept = true
            s += (cp in imponly) ? max(dir * avg, 0.0) : dir * avg
        end
        any_kept && (out[h] = s)
    end
    return out
end

"""
    get_dropped_border_exports(zone, day, counterparties) -> Dict{Int,Float64}

Per-UTC-hour EXPORT volume (MW, positive) over the borders to the listed
counterparties, from `entsoe.physical_flows` — the mirror of the import-only
clamp in `get_net_imports`. Used by the two-pass :hydro anchor to give
structural exporters (NO5) their outlet back as ref-priced demand while the
import supply stays separately clamped.
"""
function get_dropped_border_exports(bidding_zone::String, day::Date,
    counterparties::Vector{String})
    isempty(counterparties) && return Dict{Int,Float64}()
    # Dropped-border flows: the ex-ante replacement applies under classes
    # :all and :dropped (these ARE the dropped borders).
    keep = Set(counterparties)
    bh = (_exante_active() && FLOW_ASOF_CLASS[] in (:all, :dropped)) ?
         _zone_border_hourly_exante(bidding_zone, day, keep) :
         _zone_border_hourly(bidding_zone, day; lag=0)
    out = Dict{Int,Float64}()
    for (h, rows) in _border_rows_by_hour(bh)
        s = 0.0
        any_kept = false
        for (cp, dir, avg) in rows
            cp in keep || continue
            any_kept = true
            s += max(-dir * avg, 0.0)
        end
        any_kept && (out[h] = s)
    end
    return out
end

"""
    get_import_atc_capacity(bidding_zone, day) -> Dict{Int,Float64}

Per-UTC-hour total OFFERED import ATC into the zone (MW), summed over all its
borders (`in_map_code = zone`) from `offered_transfer_capacities_implicit`. Used
by the gated `scarcity_import_credit` to credit available import capacity in the
scarcity margin — a zone that can import GWs is not domestically scarce. Offered
ATC is published D-1, so this is ex-ante. AVG per (border, hour) before summing
so a border reported sub-hourly is not over-counted.

"""
function get_import_atc_capacity(bidding_zone::String, day::Date)
    df = sql2df_with_retry(
        """
        SELECT h, SUM(cap) AS total FROM (
          SELECT EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int AS h,
                 out_map_code, AVG(capacity_mw) AS cap
          FROM entsoe.offered_transfer_capacities_implicit
          WHERE in_map_code = \$1
            AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
            AND date_time_utc <  ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
          GROUP BY 1, out_map_code
        ) s
        GROUP BY h
        """,
        [bidding_zone, day])
    out = Dict{Int,Float64}()
    for r in eachrow(df)
        ismissing(r.total) || (out[Int(r.h)] = Float64(r.total))
    end
    return out
end

"""
    _endogenous_import_atc(zone, day, counterparties) -> Dict{Int,Float64}

Per-UTC-hour offered import ATC into `zone` summed over the listed
counterparties (`out_map_code`), matching the enriched network's border
sourcing: `offered_transfer_capacities_implicit` unioned with the explicit
table's Day-ahead rows, implicit preferred where a border exists in both.
Used by the import backstop to size what the MPCC flow variables can already
deliver over the zone's ENDOGENOUS borders.
"""
function _endogenous_import_atc(bidding_zone::String, day::Date,
    counterparties::Vector{String})
    per_border(table, ct_filter, params) = begin
        df = sql2df_with_retry(
            """
            SELECT EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int AS h,
                   out_map_code AS cp, AVG(capacity_mw) AS cap
            FROM entsoe.$table
            WHERE in_map_code = \$1 AND out_map_code = ANY(\$3)
              AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc <  ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
              AND capacity_mw IS NOT NULL
              $ct_filter
            GROUP BY 1, out_map_code
            """, params)
        d = Dict{Tuple{Int,String},Float64}()
        for r in eachrow(df)
            ismissing(r.cap) || (d[(Int(r.h), String(r.cp))] = Float64(r.cap))
        end
        d
    end
    params = Any[bidding_zone, day, counterparties]
    impl = per_border("offered_transfer_capacities_implicit", "", params)
    expl = per_border("offered_transfer_capacities_explicit",
        "AND contract_type = 'Day-ahead'", params)
    # Implicit preferred per (hour, border); explicit fills the gaps (CH/RS).
    merged = merge(expl, impl)
    out = Dict{Int,Float64}()
    for ((h, _), cap) in merged
        out[h] = get(out, h, 0.0) + cap
    end
    return out
end

"""
    get_import_backstop(bidding_zone, day; weeks=8, endogenous_counterparties=[])
        -> Dict{Int,Float64}

Per-UTC-hour ex-ante elastic import-backstop quantity (MW) — the import
capability the zone has recently DEMONSTRATED beyond what the book already
carries, split by border class so nothing is double-counted:

- **Non-endogenous borders** (retained observed injections + dropped
  flow-based borders): the book injects their `:v2` climatology, so the
  headroom is the demonstrated flow beyond it —
  `max(0, max_{k=1..weeks} net_ne(day−7k, h) − clim_ne(h))`.
- **Endogenous borders** (`endogenous_counterparties`: kept-ATC neighbors plus
  shadowed aggregate codes the remap carries): the book injects nothing — the
  MPCC flow variables deliver up to the OFFERED ATC — so the headroom is the
  demonstrated flow beyond that ATC (implicit ∪ explicit-Day-ahead, exactly
  the network's sourcing): `max(0, max_k net_endo(day−7k, h) − atc_endo(h))`.
  This is what covers episodic offered-ATC collapses (CH holiday auction
  gaps, DE_LU→DK1 tight-hour dips) without double-counting normal hours.

The max/median run over the trailing `weeks` same-weekday days (D-7 …
D-7·weeks) and the offered ATC is published D-1, so every input strictly
predates the auction; the flow reads reuse the cached `:v2` day relations.
Zero/negative headroom hours are omitted. See the `import_backstop` field of
`ZoneProfile` for pricing and the measured rationale.
"""
function get_import_backstop(bidding_zone::String, day::Date;
    weeks::Int=8, endogenous_counterparties::Vector{String}=String[])
    endo = Set(endogenous_counterparties)
    # Per-hour (non-endogenous, endogenous) net flows of a (h,cp,dir)=>flow
    # map, deterministically ordered for reproducible float sums.
    function nets(bh)
        rows = sort!(Tuple{Int,String,Int,Float64}[
            (h, cp, dir, v) for ((h, cp, dir), v) in bh])
        ne = Dict{Int,Float64}(); e = Dict{Int,Float64}()
        for (h, cp, dir, v) in rows
            d = (cp in endo) ? e : ne
            d[h] = get(d, h, 0.0) + dir * v
        end
        return (ne, e)
    end
    lagged = [nets(_zone_border_hourly(bidding_zone, day; lag=7k)) for k in 1:weeks]
    clim_ne, _ = nets(_zone_border_hourly_clim(bidding_zone, day; weeks=weeks))
    atc_endo = isempty(endo) ? Dict{Int,Float64}() :
        _endogenous_import_atc(bidding_zone, day, endogenous_counterparties)
    out = Dict{Int,Float64}()
    isempty(lagged) && return out
    for h in 0:23
        mx_ne = maximum(get(l[1], h, 0.0) for l in lagged)
        mx_e = maximum(get(l[2], h, 0.0) for l in lagged)
        headroom = max(0.0, mx_ne - get(clim_ne, h, 0.0)) +
                   max(0.0, mx_e - get(atc_endo, h, 0.0))
        headroom > 0.0 && (out[h] = headroom)
    end
    return out
end

"""
    get_firm_of(bidding_zone::String) -> Dict{String,String}

Map of `unit_code => firm` for a zone, from `simulations.unit_firms` (a small
read-only reference table, present on both backends). Returns an empty Dict
(and warns once) when the table is missing — the strategist hook then simply
has no firm information to key on.
"""
function get_firm_of(bidding_zone::String)
    try
        df = sql2df_with_retry(
            """
            SELECT unit_code, firm
            FROM simulations.unit_firms
            WHERE zone = \$1 AND unit_code IS NOT NULL AND firm IS NOT NULL
            """,
            [bidding_zone]
        )
        return Dict{String,String}(String(row.unit_code) => String(row.firm)
                                   for row in eachrow(df))
    catch e
        @warn "simulations.unit_firms unavailable; strategist firm_of will be empty" exception=e
        return Dict{String,String}()
    end
end

# Fuel types priced at water value instead of SRMC
