module MeritOrderBook

"""
Merit-Order Bidding Order Book

Deterministic order book that models how participants actually bid in
day-ahead markets, instead of adding random noise to costs:

- **Demand** is (nearly) inelastic: a large tranche at the price cap plus a
  small price-sensitive tail. The clearing price therefore comes from the
  supply stack, not from an arbitrary demand price.
- **Thermal supply** bids in tranches (bid laddering): most capacity near
  SRMC, the last MW at a premium. This produces an upward-sloping offer
  curve per unit, as in real order books.
- **Scarcity markup**: when the capacity margin over demand tightens, upper
  tranches are marked up — capturing strategic bidding in tight hours.
- **Hydro water value**: reservoir and pumped-storage hydro bid opportunity
  cost tied to the gas SRMC and the day's demand shape, not their (trivial)
  variable cost. This is what sets evening-peak prices in hydro-rich zones
  like GR.

All prices derive from SRMC (`get_marginal_cost`, TTF-based for gas), so the
order book moves with real fuel prices.
"""

using Dates
using Statistics: median
import ..get_generators, ..get_loads, ..get_generation_forecast_for_wind_and_solar
import ..get_marginal_cost, ..sql2df_with_retry, ..Generator, ..normalize_fuel_type_name
import ..MarketOrders: SimpleOrder
import ..MPCC: MPCCOrderBook
import ..disaggregate_temporal_data, ..replicate_to_finer_resolution
import ..AlternativeOrderBook: AdjustedOrderBookResult, parse_timeslot_to_datetime

"""
    get_net_imports(bidding_zone::String, day::Date) -> Dict{Int,Float64}

Net physical imports (MW, positive = importing) per UTC hour for a zone,
from `entsoe.physical_flows`. Both flow directions are summed across all
borders; rows are restricted to BZN-level areas on both sides to avoid the
double-reporting of the same border at CTA level (e.g. GR–IT vs GR–IT-SOUTH).

Returns an empty Dict when no flow data exists for the day.

`exclude_counterparties` drops borders to the listed zones — used in
multi-zone clearing, where flows to zones inside the clearing set are
endogenous (ATC-constrained MPCC variables) and only borders to zones
OUTSIDE the set should enter as observed fixed injections.

`import_only_counterparties` keeps only the IMPORT direction of the listed
borders (per hour, `GREATEST(flow, 0)`), used for Nordic flow-based borders
that were dropped from the endogenous network: the observed import supplies
a starving importer (NO1), but the corresponding observed export must NOT
become firm cap-priced demand in the exporter's book — against the thin
Nordic unit fleets that manufactures scarcity that cascades down the
endogenous SE chain (measured: SE3 bias −6.5 → +578 when its NO1/FI exports
entered as firm demand). Empty by default — the single-zone and 5-zone SEE
paths are unchanged.
"""
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
_exante_active() = FLOW_ASOF_MODE[] in (:clim, :v2) ||
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

# The ex-ante source map for the selected class, merged with same-day flows
# for the non-selected counterparties.
function _zone_border_hourly_exante(zone::String, day::Date, imponly::Set{String})
    mode = FLOW_ASOF_MODE[]
    alt = if mode == :clim
        _zone_border_hourly_clim(zone, day)
    elseif mode == :v2
        # Measured best mix: D-7 for borders touching a Nordic hydro zone
        # (regime persistence), climatology for the rest (noise averaging).
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
        mixed
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
const WATER_VALUE_FUEL_TYPES =
    [Symbol("Hydro Water Reservoir"), Symbol("Hydro Pumped Storage")]

"""
    _unit_hash01(code) -> Float64 in [0, 1)

Deterministic per-unit draw for `unit_srmc_spread` (FNV-1a over the code's
bytes). Stable across sessions, processes and Julia versions — Base.hash is
not guaranteed stable across versions, and reproducibility of the priced book
is a hard requirement (same day + same code ⇒ bit-identical prices).
"""
function _unit_hash01(code::AbstractString)
    h = 0xcbf29ce484222325
    for b in codeunits(code)
        h = (h ⊻ UInt64(b)) * 0x00000100000001b3
    end
    return (h % UInt64(1000)) / 1000.0
end

# ENTSO-E production_type strings for hydro availability lookup
const HYDRO_PRODUCTION_TYPES =
    ["Hydro Water Reservoir", "Hydro Pumped Storage", "Hydro Run-of-river and pondage"]

# =============================================================================
# ZONE PROFILES — per-region bid-construction calibration
# =============================================================================
"""
    ZoneProfile

Bundles the per-zone bid-construction / hydro / fleet / scarcity parameters of
`create_merit_order_book` (previously ~18 loose kwargs) into one named value.
The clearing machinery is region-agnostic; different European regions are
governed by different price-forming forces, so each is calibrated with its own
profile selected via `ZONE_PROFILES`, which **defaults to `SEE_PROFILE`**.

`SEE_PROFILE` holds the exact v10 defaults, so the SEE core (GR/BG/RO/RS/HU) and
Iberia are byte-identical to the pre-abstraction code — the non-negotiable
regression guard (unit-tested: a GR book with `SEE_PROFILE` equals a GR book
built with no profile). Region profiles are authored as thin deltas over SEE.

Fields are data, not logic. Two levers extend the old kwargs:
- `thermal_srmc_multiplier` scales non-hydro marginal costs (Italy's LNG /
  older-fleet efficiency premium); `1.0` = unchanged.
- `hydro_model` selects the hydro offer model: `:gas_anchored` (SEE default —
  water value tied to gas SRMC and demand shape) or `:reservoir_opportunity`
  (Nordic — water value from reservoir filling level, decoupled from gas).
"""
Base.@kwdef struct ZoneProfile
    tranches::Vector{Tuple{Float64,Float64}} =
        [(0.55, 0.95), (0.20, 1.05), (0.15, 1.25), (0.10, 1.60)]
    must_run_price_factor::Float64 = 0.05
    must_run_srmc_threshold::Float64 = 1.15
    availability_factor::Float64 = 0.80
    scarcity_threshold::Float64 = 1.4
    scarcity_kappa::Float64 = 3.0
    peak_kappa::Float64 = 1.2
    peak_exponent::Float64 = 4.0
    water_value_base::Float64 = 0.85
    water_value_dry_boost::Float64 = 1.0
    water_value_span::Float64 = 0.9
    demand_elastic_share::Float64 = 0.02
    demand_elastic_price::Float64 = 250.0
    price_cap::Float64 = 3000.0
    fleet_completion::Bool = true
    fleet_truthing::Bool = true
    derate_headroom::Float64 = 1.15
    thermal_srmc_multiplier::Float64 = 1.0
    # Per-unit SRMC spread (cv18): decorrelate thermal unit costs by a stable
    # per-unit factor 1 ± spread (deterministic FNV-1a hash of the unit code —
    # to be replaced by inferred heat rates once history supports them).
    # Without it every unit of a fuel type shares one type-level SRMC, so all
    # their same-multiplier tranches align into ONE flat multi-GW step and the
    # marginal price cannot move intraday — the measured cause of the flat
    # Italian zones (docs/experiments/it-flatline-diagnosis.md: every hour of
    # the probe day pinned at 90.90 by four units priced identically; ±8%
    # prototype corr 0.31→0.68 CSOUTH, 0.75→0.82 NORTH, 0.49→0.72 Sicily;
    # Sardinia the measured exception). 0 = off (byte-identical).
    unit_srmc_spread::Float64 = 0.0
    # Export-absorption ladder (cv18): elastic demand steps (price €/MWh, MW)
    # appended every timeslot — export/flexibility absorption of RES-surplus
    # generation below the thermal band. Without it a wind-heavy zone's price
    # stays pinned at the thermal marginal in surplus hours (DK1: prototype
    # 30/15/5 € × 400 MW → corr 0.495→0.569, MAE −2.0, binding only on
    # surplus days). Empty = off (byte-identical).
    export_absorption_steps::Vector{Tuple{Float64,Float64}} = Tuple{Float64,Float64}[]
    hydro_model::Symbol = :gas_anchored
    nuclear_srmc_floor::Float64 = 0.0
    opportunity_anchor::Symbol = :none
    anchor_share::Float64 = 0.9
    # Scarcity import credit (iter6): fraction of the zone's offered import ATC
    # to add to dispatchable capacity in the scarcity margin. A thermal zone with
    # GWs of available import capacity is NOT strategically scarce even when its
    # own derated fleet looks tight (DE_LU is a NET EXPORTER yet priced €178) —
    # the real scarcity, if any, arrives through the coupled import PRICE, not a
    # domestic mark-up. 0 = off (SEE/guard unchanged and byte-identical). Uses
    # offered ATC only (D-1 legal). Softens ONLY the scarcity margin; the actual
    # imports still clear through the MPCC.
    scarcity_import_credit::Float64 = 0.0
    # Fleet-truth mode (iter7). What each MARKET-ACTIVE fuel type's fleet is
    # trued to (completed up to by fleet completion, never derated below by
    # fleet truthing):
    #   :p95       — trailing-30d p95 (default; the byte-identical v10/iter6
    #                behaviour — GR/SEE must stay here: the crisis-honesty
    #                derate depends on it).
    #   :seasonal  — max(30d p95, trailing-365d p95): last-YEAR observed
    #                capability. Captures merit-order-idle capacity that ran in
    #                the previous winter but not the last 30 days, while
    #                excluding closed plants and grid-reserve units that never
    #                clear the market. Pure observed output, ex-ante.
    #   :installed — the ENTSO-E registry's installed capacity (activity-gated
    #                per type at 30d p95 > 100 MW). Largest fleet: also pulls
    #                in mothballed/reserve capacity with stale COMMISSIONED
    #                status (measured iter7: over-adds — broad negative bias).
    # Fixes the under-counted idle thermal of the meshed continental core:
    # units idle on merit order never enter the 30d-p95 completion, so the book
    # cleared deep in the expensive tranches (DE_LU sim €178 vs actual €109
    # with 44 GW modeled vs ~60 GW active-installed).
    fleet_truth_mode::Symbol = :p95
    # Seasonal water-value drawdown (reservoir_opportunity zones only): raise the
    # water-value floor with the absolute reservoir drawdown vs the trailing
    # 52-week peak, so winter depletion prices stored water as scarcer even when
    # the prior-year-relative dryness reads ~0. On for the mainland reservoir
    # zones (SE1/SE2); off for far-north export-congested NO4, whose low price
    # is set by export congestion, not the seasonal water value.
    seasonal_drawdown::Bool = true
    # --- cv17 import-fix mechanisms (weak-zone diagnosis,
    # docs/experiments/weak-zone-diagnosis). All defaults inert, so
    # SEE/guard/single-zone books stay byte-identical.
    #
    # Ex-ante elastic import backstop (P2 of the diagnosis). One extra supply
    # block per hour, sized by the zone's recently DEMONSTRATED import headroom
    # beyond the :v2 flow climatology the book already injects:
    #   qty(h) = max(0, max over trailing `backstop_weeks` same-weekday days of
    #                net import(h) − climatology median(h)
    #                − offered ENDOGENOUS import ATC(h))
    # (the last term avoids double counting capacity the MPCC flow variables
    # can already deliver), priced at `backstop_price_mult ×` gas SRMC — above
    # every domestic tranche multiplier (max 1.60), so it displaces nothing in
    # normal hours and only prevents the jump from ~1.6×gas straight to the
    # €3,000 cap on the ~2% tail days when the zone leans on its neighbors
    # beyond climatology (reality: more import arrives as the price rises).
    # All inputs strictly predate the D-1 auction (fully ex-ante).
    import_backstop::Bool = false
    backstop_weeks::Int = 8
    backstop_price_mult::Float64 = 1.8
    # Fraction of the hourly backstop quantity credited into the scarcity
    # margin (the backstop analogue of `scarcity_import_credit`): the scarcity
    # MARKUP otherwise cannot see the backstop supply, so restored-import days
    # can keep a residual markup overshoot. 0 = off (default).
    backstop_scarcity_credit::Float64 = 0.0
    # Two-pass anchor refs over DROPPED borders: include dropped in-footprint
    # borders in the opportunity-anchor reference, weighted by observed
    # climatology import flow. SE3's case: its real marginal supplier is
    # Norrland hydro over the dropped SE2–SE3 cut (~5 GW observed) while the
    # endogenous ref saw only DK1's ~0.3 GW border, pinning SE3 to DK1's
    # night price. Off by default.
    anchor_include_dropped::Bool = false
    # Price RETAINED-border observed net exports at the coupled/anchor
    # reference instead of firm demand at the cap (pass 2, anchored zones
    # only): a real exporter curtails its export under domestic stress
    # (SI–HR, BE–GB) instead of serving it at any price — the demand-side
    # mirror of the dropped-border `anchor_export_mw` treatment. Off by
    # default (byte-identical cap-priced exports elsewhere).
    ref_priced_exports::Bool = false
end

"""
    with_profile(p::ZoneProfile; overrides...) -> ZoneProfile

Copy of `p` with the given fields replaced — used to author zone variants of a
shared regional profile (e.g. DK1/DK2 = NORDIC + import backstop) without
duplicating the base calibration.
"""
function with_profile(p::ZoneProfile; overrides...)
    nt = NamedTuple{fieldnames(ZoneProfile)}(
        ntuple(i -> getfield(p, i), fieldcount(ZoneProfile)))
    return ZoneProfile(; merge(nt, values(overrides))...)
end

"""
    FLEET_TRUTH_OVERRIDE

Process-wide override of every profile's `fleet_truth_mode` (`nothing` = use
the profile's own mode). Set to `:p95` by the multi-zone per-day robustness
fallback: when the coupled MPCC stays infeasible through the whole retry
ladder, the day is re-cleared with baseline v10 fleet truth rather than
shipped missing. Always reset in a `finally` — never left set.
"""
const FLEET_TRUTH_OVERRIDE = Ref{Union{Nothing,Symbol}}(nothing)

_effective_fleet_truth_mode(profile) =
    something(FLEET_TRUTH_OVERRIDE[], profile.fleet_truth_mode)

"SEE / default profile — the exact v10 parameters (regression baseline)."
const SEE_PROFILE = ZoneProfile()

"Iberia — near-isolated, already the best-fit region; identical to SEE (verified)."
const IBERIA_PROFILE = SEE_PROFILE

"""
Continental core (DE/FR/BE/NL/AT/CH/PL/CZ/SK). High-RES thermal with heavy
transit; genuine scarcity should be rare, so the scarcity/peak markups are
softened relative to SEE. Adequacy is expected to come mostly from the Phase-1
network fix (endogenous flows + the CH transit hub), not bid tuning.
"""
const CONTINENTAL_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
    # iter6: DE_LU/NL/PL/CZ are meshed thermal zones with GWs of import capacity
    # and are frequently net exporters — the domestic scarcity mark-up mis-fired
    # (DE_LU +70, a NET EXPORTER, priced €178). Credit available import ATC.
    scarcity_import_credit = 1.0,
    # iter7: idle-but-existing thermal (merit-order idle, not closed) never
    # appears in the 30d-p95 completion, so the book cleared deep in the
    # expensive tranches (DE_LU modeled 44 GW vs ~60 GW active-installed;
    # measured gaps: DE hard coal 21.0 installed vs 9.8 GW modeled, lignite
    # 19.6 vs 11.2, gas 19.5 vs 15.2; PL hard coal 18.6 vs 14.1).
    #
    # iter7 measured :installed here at a TRANSFORMATIVE gain (DE_LU MAE 73→22
    # corr 0.62→0.80, PL 86→30, aggregate meanMAE 45→32) but parked it: the
    # DE_LU book made 1/36 sample days FALSELY infeasible — Big-M q×price-span
    # constants up to ~2.6e8 on multi-GW cap-priced demand blocks leak through
    # the integrality tolerance and produce false certificates that survived
    # the numeric retry ladder. iter8 fixes that at the root: a final MPCC
    # retry rung swaps the Big-M complementarity for EXACT Gurobi indicator
    # constraints (no constants), plus a per-day :p95-books fallback in
    # run_multi_zone_market_clearing as the safety net — so :installed is now
    # enabled. :seasonal (trailing-365d p95) was measured a NO-OP on winter
    # failure days (idle capacity never generates even across a year;
    # :installed stands in for offered-but-undispatched units and the unlisted
    # <100 MW CHP fleet). Evidence: docs/eu-calibration-iter7.md + iter8.
    fleet_truth_mode = :installed,
)

"""
Italy. Gas-heavy but higher SRMC than SEE — older, less-efficient CCGTs burning
premium-priced LNG — so thermal marginal costs carry an efficiency/LNG premium.
"""
const ITALY_PROFILE = ZoneProfile(
    thermal_srmc_multiplier = 1.20,
)

"""
Nordic (NO*/SE*/FI/DK*). Hydro-dominated: the price is the opportunity cost of
stored water (reservoir level + export value), NOT a gas anchor. Uses the
`:reservoir_opportunity` hydro model and softens scarcity so full reservoirs no
longer slam into the price cap.
"""
const NORDIC_PROFILE = ZoneProfile(
    hydro_model = :reservoir_opportunity,
    scarcity_threshold = 1.2,
    scarcity_kappa = 1.0,
    peak_kappa = 0.5,
    # Demand-shape band applied to the reservoir-opportunity water value
    # (see the :reservoir_opportunity branch): 0.6 at the trough → 1.1 at the
    # peak, so hydro is cheap off-peak but firms up into the evening.
    water_value_base = 0.6,
    water_value_span = 0.5,
)

"""
Far-north Norway (NO4). Same reservoir-opportunity hydro as NORDIC but with the
seasonal drawdown OFF: NO4 is congestion-isolated (actuals ≈ €29 year-round —
it exports into a constrained grid, so its price is set by the export bottleneck,
not by the winter shadow value of its still-brimming reservoirs, which stay near
80% full in February). With the drawdown on (iter6 c2), NO4 over-priced by +8.6
in winter; off, it stays centered (+0.2) while SE1/SE2 keep the drawdown lift.
"""
const NO4_PROFILE = ZoneProfile(
    hydro_model = :reservoir_opportunity,
    scarcity_threshold = 1.2,
    scarcity_kappa = 1.0,
    peak_kappa = 0.5,
    water_value_base = 0.6,
    water_value_span = 0.5,
    seasonal_drawdown = false,
)

"""
France. Nuclear-dominated exporter. Diagnostics (2026-04): the fleet picture is
CORRECT — nuclear unit fleet 50.9 GW vs trailing-30d p95 47.4 GW, within the
derate headroom, so fleet-truthing rightly stays silent — yet the hourly
residual shows a LEVEL gap concentrated off-peak: sim ≈ €10 (nuclear tranche-1
at SRMC) overnight vs actual €55–70, while midday RES-surplus hours match. The
observed French off-peak price reflects EDF's opportunity-cost *bidding* of the
modulating nuclear fleet, not the ~€10 fuel SRMC — a bidding-layer position,
which per the repo's cost-model convention belongs here, not in the SRMC table.
`nuclear_srmc_floor` lifts the nuclear bid base to that observed level; peaks
stay set by gas/hydro/scarcity as in CONTINENTAL.
"""
const FRANCE_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
    nuclear_srmc_floor = 55.0,
    opportunity_anchor = :nuclear,
    # Measured: share 0.9 → bias +33 (cal5), share 0.7 → +21 (cal6), both
    # with the coupled shape right (corr 0.76 → 0.80–0.83) — the neighbor-
    # weighted ref imports the overpricing of CH/BE/ES, so the share must
    # discount it. Extrapolating the measured share→bias line puts |bias|≤10
    # at ≈0.55: EDF's off-peak position sits just above half the coupled
    # neighbor price.
    anchor_share = 0.55,
)

"""
Southern/mid Norway (NO1/NO2/NO3/NO5). Same reservoir-opportunity hydro model
as NORDIC, plus the `:hydro` opportunity anchor for two-pass clearing: these
zones are coupled to the continent (2026-04 actuals €70–108 tracking DE/NL)
and their stored water prices at the export opportunity — the pass-1 coupled
continental price — not at a fraction of gas SRMC (iteration-1 result: flat
−58…−92 residual with full reservoirs). NO4 (far north, actuals ≈ €18, NOT
continentally coupled — congestion isolates it like SE1/SE2) deliberately
stays on plain NORDIC_PROFILE.
"""
const NORWAY_PROFILE = ZoneProfile(
    hydro_model = :reservoir_opportunity,
    scarcity_threshold = 1.2,
    scarcity_kappa = 1.0,
    peak_kappa = 0.5,
    water_value_base = 0.6,
    water_value_span = 0.5,
    opportunity_anchor = :hydro,
)

"""
Mid/south Sweden (SE3/SE4). Same structural object as southern Norway once
their flow-based-residual borders are dropped (iter5: SE2–SE3, SE3–SE4 in
`flow_based_drop_borders`): the drop cured the +128/+147 continental-scarcity
bias (MAE −99/−103) but reproduced NO1's iteration-2 failure mode — the €1
observed-import block became price-setting (SE3 sim €1–9.5 all day vs actual
€15–70, corr 0.51→−0.25). The `:hydro` opportunity anchor is the built cure:
dropped-border imports price at the border price (`share × ref`), water value
clamps to the coupled reference, and dropped-border exports re-enter as
ref-priced demand. Anchor refs come from the remaining endogenous neighbors —
DK1 for SE3, DK2/LT for SE4 — all well-calibrated after the SE drop.
"""
const SWEDEN_SOUTH_PROFILE = NORWAY_PROFILE

"""
Switzerland. Hydro-storage dominated (large reservoir + pumped fleet, thin
thermal) but was on CONTINENTAL_PROFILE, so its storage was priced
gas-anchored (~€119 base with scarcity markup) — measured cal8 residual +28
to +78 in EVERY hour, worst at peaks and in RES-surplus midday where the
actual price collapses to ~0 but the sim stays ~47. Same structural object
as Norway: storage prices at the export opportunity. NORDIC-style
reservoir-opportunity hydro plus the two-pass :hydro anchor; CH's neighbors
(DE_LU, FR, IT-NORTH) are all endogenous and well-calibrated, so the anchor
ref is the border-capacity-weighted mean of their pass-1 prices. Swiss
reservoir filling data exists in entsoe.aggregated_hydro_storage_filling_rate
(590 weekly rows, current), so dryness is real, not a proxy.

SHARED WITH AUSTRIA (iteration 4). AT is also alpine-hydro dominated (~60%
reservoir + run-of-river + pumped) and sits on the AT–CH border, so when CH
alone carried the :hydro anchor (iter3 cal10) the anchored CH book propagated a
shape regression into AT (corr 0.77→0.57). The iteration-4 fix is to roll CH
and AT out TOGETHER on the same reservoir-opportunity :hydro anchor — AT's
storage prices at the same coupled continental opportunity cost, so the two
alpine zones are anchored consistently in the same pass instead of one dragging
the other. Measured cumulatively on the HU-drop baseline (cal12→cal13):
CH corr 0.82→0.86 / MAE 40→27 / bias +39→+10; AT held at corr 0.85 with bias
improved (see docs/eu-calibration-iter4.md). Swiss/Austrian reservoir filling
data exists in entsoe.aggregated_hydro_storage_filling_rate (weekly BZN rows).
"""
const SWISS_PROFILE = ZoneProfile(
    hydro_model = :reservoir_opportunity,
    scarcity_threshold = 1.2,
    scarcity_kappa = 1.0,
    peak_kappa = 0.5,
    water_value_base = 0.6,
    water_value_span = 0.5,
    opportunity_anchor = :hydro,
    # cv17: CH starves episodically (FR→CH holiday auction gaps, e.g. the
    # 2025-01-01 DE_Amprion zero-offer day), not chronically — no border drop
    # is justified; the ex-ante backstop covers the tail days. Measured
    # (28-day benchmark): corr 0.11 → 0.74, MAE 49.9 → 24.1.
    import_backstop = true,
)

"""
Austria. Same alpine reservoir-opportunity + `:hydro` anchor as CH (the iter4
joint rollout), but with its own `anchor_share` (iter5): measured on
2026-04-01..05, CH's actual level sits AT its coupled reference (share 0.9 →
bias −2.3, near-perfect) while AT's actual (≈€100) trades ~€19 ABOVE its
coupled neighbors (DE_LU ≈€81) — a Core-FBMC premium the capacity-weighted ref
cannot see. At the shared share 0.9 AT under-priced (bias −17.9) and its
too-cheap hydro exports dragged IT-NORTH (−9.0) and SK (−11.0) negative — the
iter4 "alpine-cheapening spillover". From the measured share→bias point
(0.9 → −17.9 at sim ≈ 82), share 1.1 puts the AT hydro bid base at its
observed premium — a calibrated bidding position like FRANCE_PROFILE's 0.55
in the other direction. The water value stays clamped at gas SRMC, so a
share > 1 cannot manufacture scarcity.
"""
const AUSTRIA_PROFILE = ZoneProfile(
    hydro_model = :reservoir_opportunity,
    scarcity_threshold = 1.2,
    scarcity_kappa = 1.0,
    peak_kappa = 0.5,
    water_value_base = 0.6,
    water_value_span = 0.5,
    opportunity_anchor = :hydro,
    # iter8 re-tune attempt, measured and REJECTED: with the installed-fleet
    # fix the coupled DE ref dropped to its true level and AT under-prices
    # (bias −13.5); raising the share 1.1 → 1.25 moved AT only −0.4 MAE /
    # +0.6 bias — the water value clamps at gas SRMC, so the share is no
    # longer the binding lever under the corrected ref. AT's residual is
    # shape (corr), queued for iteration 9; the share stays at its iter5
    # calibration.
    anchor_share = 1.1,
    # cv17: AT's remaining Core import borders (CZ–AT, DE_LU–AT) carry the
    # chronic flow-based-residual ATC (p10 = 0 vs 1.6–2.0 GW physical) and are
    # now DROPPED (see flow_based_drop_borders); the backstop covers the
    # residual tail days beyond the restored climatology injection. Measured
    # (28-day production benchmark): corr 0.17 → 0.77, MAE 85.3 → 28.3.
    # The backstop scarcity credit was measured here and NOT adopted (moved
    # no target metric; cost SK/SE4 ~0.05 corr via their anchor refs).
    import_backstop = true,
)

"""
Belgium. Continental thermal zone whose Core-FBMC borders are dropped
(iter5: BE–FR/NL/DE_LU in `flow_based_drop_borders` — import ATCs collapse to
0–350 MW mid-morning while physical flows carry 1.4–1.9 GW). The drop alone
(cal17) flipped BE from +46.5 starved-overpricing to −35 (the €1
observed-import block price-setting in import-covered hours — the NO1/SE3
failure mode). The `:hydro` opportunity anchor supplies the pricing half of
the treatment: dropped-border imports at the border price (`share × ref`,
ref = DE_LU/NL continental proxy since BE has no endogenous neighbors left;
GB is outside the footprint), dropped-border exports as ref-priced demand.
BE's actual mean (≈€77) sits at ~0.9× the proxy — the default share. The
hydro side of the anchor touches only BE's small pumped fleet (ref-priced
storage — if anything more honest than gas-anchored).
"""
const BELGIUM_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
    opportunity_anchor = :hydro,
    # cv17: BE's tail-day import starvation (actual imports +2.1 GW over the
    # climatology on its spike hours) is covered by the ex-ante backstop.
    # Measured (28-day benchmark): corr 0.22 → 0.85, MAE 63.5 → 21.0. The
    # retained BE–GB border's observed exports re-price at the anchor
    # reference in pass 2 instead of firm cap-priced demand.
    import_backstop = true,
    ref_priced_exports = true,
)

"""
Slovakia (iter6). Core FBMC transit hub whose import borders' implicit offered
ATC are flow-based residuals (CZ→SK / PL→SK avg ~90 MW vs ~3 GW physical), so
the endogenous model starved SK's thin fleet (4.15 GW vs 4.37 GW peak) into
winter cap-clearing (sim €313 vs actual €118, bias +195 on the iter6 sample).
The paired treatment (see `flow_based_drop_borders`): CZ–SK and PL–SK are
dropped, restoring the real import supply as observed import-only flows, and
the `:hydro` opportunity anchor prices those imports at the coupled Core
reference (pass-1 CZ/PL/DE_LU proxy) rather than the €1 price-taker block —
which would invert SK to a deep negative bias (the NO1/BE/SE3 failure mode
seen three times when a border was dropped without re-pricing its flows).
Continental scarcity temperament otherwise; the water value clamp keeps the
anchor from manufacturing scarcity.
"""
const SLOVAKIA_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
    opportunity_anchor = :hydro,
)

"""
Slovenia (cv17). Core-FBMC member whose AT import border carries the same
chronic flow-based-residual "offered ATC" documented and dropped for
HU (iter3), BE (iter5), SK (iter6) and now AT: AT→SI averages ~150 MW with
p10 = 0 while the physical flow carries ~1.3 GW — SI capped on 47/730 days of
the cv16 baseline, the worst phantom-scarcity zone in the footprint. The
Slovakia treatment: AT–SI dropped (`flow_based_drop_borders`), continental
scarcity temperament, and the `:hydro` opportunity anchor so the restored
imports price at the coupled Core reference instead of the €1 price-taker
block. Attribution-measured (weak-zone diagnosis v3): the drop is strictly
necessary — backstop-only leaves SI at corr 0.33 vs 0.70 with the drop.
Also carries the import backstop for residual tail days, and ref-priced
retained-border exports: SI's ~1 GW HR export outlet entered as firm demand
AT THE CAP, forcing the model to serve it at any price on tight days where a
real exporter would curtail (§2c of the diagnosis).
"""
const SLOVENIA_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
    opportunity_anchor = :hydro,
    import_backstop = true,
    ref_priced_exports = true,
)

"""
Denmark (DK1/DK2, cv17). Plain NORDIC plus the ex-ante import backstop: their
starvation is EPISODIC (DE_LU→DK1 offered ATC averages ~2.5 GW but collapses
to ~295 MW exactly on tight hours; SE4→DK2 9 MW vs 698 MW physical on spike
hours), so a blanket border drop is not justified — the tail-day backstop is.
Measured (28-day benchmark): DK1 corr 0.11 → 0.75 / MAE 71.8 → 28.8,
DK2 0.32 → 0.76 / 82.6 → 29.4.
"""
const DENMARK_PROFILE = with_profile(NORDIC_PROFILE; import_backstop = true)

"""
SE3 (cv17). SWEDEN_SOUTH (anchored Nordic hydro) plus two cv17 mechanisms:
the import backstop (spike-hour imports ran +1.9 GW over climatology), and —
its structural fix — `anchor_include_dropped`: SE3's anchor reference was the
capacity-weighted price of its ENDOGENOUS neighbors, essentially only DK1
(~0.3 GW border, €82 night) after the iter5 drops, while its real marginal
supply is Norrland hydro over the dropped SE2–SE3 cut (~5 GW observed).
Including dropped in-footprint borders climatology-flow-weighted makes the
ref SE2-dominated, pulling SE3's level/shape toward its actual position
between SE2 and DK1. SE4 deliberately stays on plain SWEDEN_SOUTH (its
existing refs are already decent; measured as a gate on the benchmark).
"""
const SE3_PROFILE = with_profile(SWEDEN_SOUTH_PROFILE;
    import_backstop = true,
    # anchor_include_dropped measured and GATED OUT (28-day production
    # benchmark): the SE2-dominated ref (~5 GW climatology weight vs DK1's
    # ~0.3 GW ATC) pinned SE3 at SE2's level — bias flipped +13 → −24 and
    # corr fell 0.55 → 0.31 vs the backstop-only configuration. The
    # mechanism stays available on the profile for future calibration
    # (e.g. a tempered weight); SE3's §4b night-shape problem remains open.
    anchor_include_dropped = false)

"""
IT-CNORTH (cv17). ITALY plus the import backstop: episodic
IT-CSOUTH→IT-CNORTH offered-ATC dips (95 MW offered vs 1.2 GW physical on
spike hours; avg ~3 GW) starve it a few days a year — backstop, not drop.
"""
const ITALY_CNORTH_PROFILE = with_profile(ITALY_PROFILE; import_backstop = true)

"""
Romania / Serbia / Hungary (cv17). SEE calibration (exact v10 parameters)
plus the ex-ante import backstop AND the backstop scarcity credit. RO is the
measured case for why the backstop must stay on in SEE's east: the June-2026
tight period (one Cernavoda unit partial, wind at 45% of 2025) was covered in
reality by BG/HU/UA imports above climatology — the model capped every day of
2026-06-15..30 while actuals stayed at €200–290. The full scarcity credit
(`backstop_scarcity_credit = 1.0`, same fundamentals as the iter6
`scarcity_import_credit`: demonstrated import capability means the zone is
not domestically scarce) addresses the measured residual overpricing of the
SEE cold-snap coupled block — with the backstop supply alone the cluster
still cleared €517–591 vs actual ~€380 because the scarcity MARKUP could not
see the restored imports; the credit only acts when the margin is below the
scarcity threshold, so normal hours are untouched. HU's membership was the
documented open calibration decision (P2 measured its bias drifting
−14.6 → −28.8 with an uncredited backstop): the production benchmark shows
HU's missing backstop left the coupled SEE cluster capping through the
2026-01 cold snap, and the credit is the mechanism P2 lacked — HU carries
both. These profiles apply ONLY on the EU-footprint path
(`enrich_network=true`); the legacy SEE single-zone and 5-zone products force
SEE_PROFILE and remain byte-identical.
"""
const ROMANIA_PROFILE = with_profile(SEE_PROFILE;
    import_backstop = true, backstop_scarcity_credit = 1.0)
const SERBIA_PROFILE = with_profile(SEE_PROFILE;
    import_backstop = true, backstop_scarcity_credit = 1.0)
const HUNGARY_PROFILE = with_profile(SEE_PROFILE;
    import_backstop = true, backstop_scarcity_credit = 1.0)

"""
Baltic (EE/LT/LV). Tightly coupled to the Nordic hydro system and thermally
thin; softened scarcity like the continental core. Left close to SEE otherwise —
their residual error is expected to shrink once the Nordic zones are corrected.
"""
const BALTIC_PROFILE = ZoneProfile(
    scarcity_threshold = 1.25,
    scarcity_kappa = 1.5,
    peak_kappa = 0.6,
    # iter6: EE/LT/LV are import-dependent (thin domestic thermal riding the
    # Nordic system via Estlink/NordBalt); the scarcity margin ignored those
    # imports and priced +78-87. Credit available import ATC.
    scarcity_import_credit = 1.0,
    # iter7: true active types to registry installed capacity (LT's Kruonis
    # pumped storage is 900 MW installed but only 450 MW unit-listed / 349
    # 30d-p95; EE oil shale 1,330 installed vs 1,060 listed).
    fleet_truth_mode = :installed,
)

"""
    ZONE_PROFILES

Registry mapping bidding-zone code → `ZoneProfile`. Zones absent from the
registry fall back to `SEE_PROFILE` via `get_zone_profile`, so the default is
always the validated SEE calibration.
"""
const ZONE_PROFILES = Dict{String,ZoneProfile}(
    # SEE core. GR/BG stay on the exact v10 SEE calibration; RO/RS/HU add the
    # cv17 import backstop + full scarcity credit (EU-footprint only — the
    # single-zone / 5-zone SEE products force SEE_PROFILE and stay
    # byte-identical). HU's membership was the documented calibration
    # decision: the production benchmark showed the coupled SEE cold-snap
    # cluster keeps capping without HU's backstop, and the scarcity credit is
    # the mechanism the P2 bias-drift caution lacked. SI moves to the
    # Slovakia treatment (cv17): AT–SI drop + :hydro anchor + backstop.
    "GR" => SEE_PROFILE, "BG" => SEE_PROFILE, "RO" => ROMANIA_PROFILE,
    "RS" => SERBIA_PROFILE, "HU" => HUNGARY_PROFILE, "SI" => SLOVENIA_PROFILE,
    # Iberia
    "ES" => IBERIA_PROFILE, "PT" => IBERIA_PROFILE,
    # Italy sub-zones (IT-CNORTH: + cv17 import backstop). cv18: the mainland
    # zones + Sicily add the per-unit SRMC spread (±10% — measured prototype
    # corr 0.31→0.68 CSOUTH / 0.75→0.82 NORTH / 0.49→0.72 Sicily, plateau
    # ±8–12%); Sardinia is the measured exception (spread WORSENED it 7/20 —
    # island/SAPEI import mix) and stays on the plain profile.
    "IT-NORTH" => with_profile(ITALY_PROFILE; unit_srmc_spread = 0.10),
    "IT-CNORTH" => with_profile(ITALY_CNORTH_PROFILE; unit_srmc_spread = 0.10),
    "IT-CSOUTH" => with_profile(ITALY_PROFILE; unit_srmc_spread = 0.10),
    "IT-SOUTH" => with_profile(ITALY_PROFILE; unit_srmc_spread = 0.10),
    "IT-Calabria" => with_profile(ITALY_PROFILE; unit_srmc_spread = 0.10),
    "IT-Sicily" => with_profile(ITALY_PROFILE; unit_srmc_spread = 0.10),
    "IT-Sardinia" => ITALY_PROFILE,
    # Norway — southern/mid zones carry the :hydro opportunity anchor;
    # NO4 (far north, not continentally coupled) stays plain NORDIC
    "NO1" => NORWAY_PROFILE, "NO2" => NORWAY_PROFILE, "NO3" => NORWAY_PROFILE,
    "NO4" => NO4_PROFILE, "NO5" => NORWAY_PROFILE,
    "SE1" => NORDIC_PROFILE, "SE2" => NORDIC_PROFILE,
    # SE3/SE4: anchored after the iter5 SE2–SE3/SE3–SE4 border drop (see
    # SWEDEN_SOUTH_PROFILE docstring); SE3 adds the cv17 backstop + the
    # dropped-border (SE2-weighted) anchor ref
    "SE3" => SE3_PROFILE, "SE4" => SWEDEN_SOUTH_PROFILE,
    "FI" => NORDIC_PROFILE,
    # DK1/DK2: + cv17 import backstop (episodic starvation — see DENMARK_PROFILE).
    # cv18: DK1 adds the export-absorption ladder (prototype corr 0.495→0.569,
    # MAE −2.0, binds only in RES-surplus hours). DK2 unchanged pending its own A/B.
    "DK1" => with_profile(DENMARK_PROFILE;
        export_absorption_steps = [(30.0, 400.0), (15.0, 400.0), (5.0, 400.0)]),
    "DK2" => DENMARK_PROFILE,
    # Baltic
    "EE" => BALTIC_PROFILE, "LT" => BALTIC_PROFILE, "LV" => BALTIC_PROFILE,
    # France (nuclear-heavy: continental scarcity + nuclear bid position)
    "FR" => FRANCE_PROFILE,
    # Alpine hydro (CH + AT): reservoir-opportunity + :hydro anchor, rolled out
    # together (iter4) so the AT–CH border is anchored consistently; AT carries
    # its own anchor_share for the Core-FBMC premium (iter5)
    "CH" => SWISS_PROFILE, "AT" => AUSTRIA_PROFILE,
    # Continental core
    "DE_LU" => CONTINENTAL_PROFILE,
    # BE: dropped Core borders + :hydro anchor for import pricing (iter5)
    "BE" => BELGIUM_PROFILE, "NL" => CONTINENTAL_PROFILE,
    "PL" => CONTINENTAL_PROFILE, "CZ" => CONTINENTAL_PROFILE,
    # SK: dropped Core import borders (CZ–SK, PL–SK) + :hydro anchor for import
    # pricing (iter6) — the HU treatment applied to SK's own residual borders
    "SK" => SLOVAKIA_PROFILE,
)

"""
    get_zone_profile(zone) -> ZoneProfile

Profile for a zone, defaulting to `SEE_PROFILE` for any zone not in the registry.
"""
get_zone_profile(zone::AbstractString) = get(ZONE_PROFILES, String(zone), SEE_PROFILE)

# =============================================================================
# ZONE SCENARIO — counterfactual hooks bundled per zone
# =============================================================================
"""
    ZoneScenario

Bundles the counterfactual hooks that `create_merit_order_book` accepts into one
named value, so a scenario can be attached to a zone on the multi-zone path
(`run_multi_zone_market_clearing(...; scenario=...)`) exactly as the loose
kwargs attach on the single-zone `generate_energy_prices` path.

All fields default to `nothing`; an all-`nothing` scenario is a no-op and the
built book is byte-identical to the no-scenario book (regression-guarded).

Fields (see `create_merit_order_book`'s "Scenario hooks" docstring for the exact
`ctx` shapes):
- `load_modifier(timeslot, load_mw) -> Float64`     — reshape demand at source
- `renewable_modifier(timeslot, mw) -> Float64`     — reshape RES at source
- `extra_orders(ctx) -> Vector{SimpleOrder}`        — add supply/demand orders
- `strategist(ctx) -> Vector{Tuple{SimpleOrder,String}}` — replace the tagged book
- `fleet_modifier(zone, gens::Vector{Generator}) -> Vector{Generator}` — add /
  remove / derate physical units. Runs AFTER fleet completion/truthing (see the
  `fleet_modifier` note in `create_merit_order_book`), so a removed unit is not
  silently re-added by the `:installed`/p95 truth-up.

The `extra_orders` and `strategist` `ctx` both carry `ctx.zone`, so a single
scenario object applied to a whole footprint can gate its edits on the zone
(one function serving many zones); `load_modifier`/`renewable_modifier` reshape
whatever zone they are attached to. To target specific zones with distinct
edits, pass a `Dict{String,ZoneScenario}` — each zone gets its own scenario.
"""
Base.@kwdef struct ZoneScenario
    load_modifier::Union{Nothing,Function} = nothing
    renewable_modifier::Union{Nothing,Function} = nothing
    extra_orders::Union{Nothing,Function} = nothing
    strategist::Union{Nothing,Function} = nothing
    fleet_modifier::Union{Nothing,Function} = nothing
end

"""
    is_empty_scenario(s) -> Bool

`true` when `s` is `nothing` or a `ZoneScenario` with every hook `nothing`
(so the no-scenario code path is byte-identical). A `Dict` scenario is never
"empty" here — emptiness is resolved per zone by `zone_scenario`.
"""
is_empty_scenario(::Nothing) = true
is_empty_scenario(s::ZoneScenario) =
    s.load_modifier === nothing && s.renewable_modifier === nothing &&
    s.extra_orders === nothing && s.strategist === nothing &&
    s.fleet_modifier === nothing

"""
    zone_scenario(scenario, zone) -> Union{Nothing,ZoneScenario}

Resolve the `ZoneScenario` that applies to `zone`:
- `nothing`                 → `nothing` (no scenario anywhere),
- a single `ZoneScenario`   → the same scenario for EVERY zone (hooks gate on
  `ctx.zone` themselves),
- a `Dict{String,ZoneScenario}` → `get(dict, zone, nothing)` (per-zone targeting).
An all-`nothing` `ZoneScenario` resolves to `nothing` so the byte-identical
no-scenario path is taken.
"""
zone_scenario(::Nothing, ::AbstractString) = nothing
function zone_scenario(s::ZoneScenario, ::AbstractString)
    return is_empty_scenario(s) ? nothing : s
end
function zone_scenario(d::Dict{String,ZoneScenario}, zone::AbstractString)
    s = get(d, String(zone), nothing)
    return (s === nothing || is_empty_scenario(s)) ? nothing : s
end

"""
    get_hydro_availability(bidding_zone::String, day::Date; lookback_days=30) -> Union{Float64,Nothing}

Recent achievable hydro output as a fraction of what the fleet produced at
its best over the trailing window: the 95th-percentile hourly total hydro
output over the `lookback_days` before `day` (strictly before — no
lookahead). Hydro is energy-limited, so recent peak output is a physical
proxy for the water actually available — in dry periods (e.g. August 2024,
May 2025 in SEE) reservoirs cannot sustain nameplate output regardless of
price, which tightens the real capacity margin and drives scarcity pricing.

Returns MW (the p95 hourly output), or `nothing` when no data exists.
"""
function get_hydro_availability(bidding_zone::String, day::Date; lookback_days::Int=30)
    df = sql2df_with_retry(
        """
        SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY hydro_mw) AS p95
        FROM (
            SELECT date_time_utc, SUM(actual_generation_output_mw) AS hydro_mw
            FROM entsoe.aggregated_generation_per_type
            WHERE area_map_code = \$1
              AND production_type = ANY(\$2)
              AND area_type_code LIKE 'BZN%'
              AND actual_generation_output_mw IS NOT NULL
              AND date_time_utc >= (\$3::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$4::date::timestamp AT TIME ZONE 'UTC')
            GROUP BY date_time_utc
        ) hourly
        """,
        [bidding_zone, HYDRO_PRODUCTION_TYPES, day - Day(lookback_days), day]
    )
    (isempty(df) || ismissing(df.p95[1])) && return nothing
    return Float64(df.p95[1])
end

"""
    get_type_output_p95(bidding_zone::String, day::Date; lookback_days=30) -> Dict{String,Float64}

95th-percentile hourly actual output per production type over the trailing
window (strictly before `day` — no lookahead), from
`entsoe.aggregated_generation_per_type`. Used for fleet completion: ENTSO-E's
unit-level table only lists larger units, so for some zones (RO, BG, RS) the
per-type aggregate output demonstrably exceeds the unit-level fleet capacity.
"""
function get_type_output_p95(bidding_zone::String, day::Date; lookback_days::Int=30)
    df = sql2df_with_retry(
        """
        SELECT production_type,
               percentile_cont(0.95) WITHIN GROUP (ORDER BY mw) AS p95
        FROM (
            SELECT production_type, date_time_utc, SUM(actual_generation_output_mw) AS mw
            FROM entsoe.aggregated_generation_per_type
            WHERE area_map_code = \$1
              AND area_type_code LIKE 'BZN%'
              AND actual_generation_output_mw IS NOT NULL
              AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')
            GROUP BY production_type, date_time_utc
        ) hourly
        GROUP BY production_type
        """,
        [bidding_zone, day - Day(lookback_days), day]
    )
    return Dict{String,Float64}(row.production_type => Float64(row.p95)
                                for row in eachrow(df) if !ismissing(row.p95))
end

"""
    get_installed_capacity_by_type(bidding_zone::String) -> Dict{String,Float64}

INSTALLED capacity (MW) per fuel type from the ENTSO-E unit registry
(`entsoe.production_and_generation_units`): COMMISSIONED units deduplicated per
`generation_unit_code` (most recent `valid_from`, highest capacity tiebreaker —
the standard dedup for this table's overlapping-validity data-quality issue),
summed per `generation_unit_type`. Deliberately does NOT apply the
date-validity / recent-generation filter of `get_generators` — that filter is
what removes idle-but-existing capacity; the caller (installed-aware fleet
truth) gates each type on recent market activity instead, which is what
excludes genuinely-decommissioned capacity with stale COMMISSIONED status
(e.g. Germany's post-phase-out nuclear). Keys are normalized fuel names.
The registry is slowly-changing reference data (same ex-ante treatment as
`get_generators`' use of it).
"""
function get_installed_capacity_by_type(bidding_zone::String)
    df = sql2df_with_retry(
        """
        SELECT generation_unit_type AS t, SUM(cap) AS mw FROM (
          SELECT DISTINCT ON (generation_unit_code)
                 generation_unit_type, generation_unit_installed_capacity_mw AS cap
          FROM entsoe.production_and_generation_units
          WHERE area_map_code = \$1
            AND production_unit_status = 'COMMISSIONED'
            AND generation_unit_status = 'COMMISSIONED'
            AND generation_unit_installed_capacity_mw > 0
          ORDER BY generation_unit_code, valid_from DESC,
                   generation_unit_installed_capacity_mw DESC
        ) s
        GROUP BY generation_unit_type
        """,
        [bidding_zone]
    )
    out = Dict{String,Float64}()
    for row in eachrow(df)
        (ismissing(row.t) || ismissing(row.mw)) && continue
        k = normalize_fuel_type_name(String(row.t))
        out[k] = get(out, k, 0.0) + Float64(row.mw)
    end
    return out
end

"""
    get_reservoir_dryness(bidding_zone::String, day::Date) -> Union{Float64,Nothing}

Hydrological dryness from ENTSO-E weekly reservoir filling levels
(`entsoe.aggregated_hydro_storage_filling_rate`): the latest stored energy
strictly before `day`'s ISO week, compared to the median stored energy for
the same weeks (±2) of previous years. Returns `clamp(1 - current/norm, 0, 1)`
— 0 in normal/wet conditions, approaching 1 in severe drought — or `nothing`
when either value is unavailable.

Unlike output-based dryness, this measures the water itself, so it is not
confounded by dispatch incentives (hydro running hard *because* prices are
high looks "wet" in output terms while reservoirs are actually draining).
"""
function get_reservoir_dryness(bidding_zone::String, day::Date)
    iso_week = Int(Dates.week(day))
    iso_year = year(day)

    current = sql2df_with_retry(
        """
        SELECT stored_energy_mwh
        FROM entsoe.aggregated_hydro_storage_filling_rate
        WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
          AND stored_energy_mwh IS NOT NULL
          AND (year < \$2 OR (year = \$2 AND week < \$3))
        ORDER BY year DESC, week DESC
        LIMIT 1
        """,
        [bidding_zone, iso_year, iso_week]
    )
    (isempty(current) || ismissing(current.stored_energy_mwh[1])) && return nothing

    norm = sql2df_with_retry(
        """
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY stored_energy_mwh) AS med
        FROM entsoe.aggregated_hydro_storage_filling_rate
        WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
          AND stored_energy_mwh IS NOT NULL
          AND year < \$2
          AND week BETWEEN \$3 - 2 AND \$3 + 2
        """,
        [bidding_zone, iso_year, iso_week]
    )
    (isempty(norm) || ismissing(norm.med[1]) || Float64(norm.med[1]) <= 0.0) && return nothing

    return clamp(1.0 - Float64(current.stored_energy_mwh[1]) / Float64(norm.med[1]), 0.0, 1.0)
end

"""
    get_reservoir_drawdown(bidding_zone::String, day::Date) -> Union{Float64,Nothing}

Absolute reservoir DRAWDOWN: `clamp(1 - stored / trailing-52-week max, 0, 1)`,
using the latest stored energy strictly before `day`'s ISO week and the maximum
stored energy over the preceding 52 weeks (both ex-ante — only weeks before the
market day enter). 0 at the seasonal reservoir peak (autumn), rising toward 1 as
the reservoir empties through winter into spring.

This is the SEASONAL complement to `get_reservoir_dryness`. Dryness normalizes
against the *same week of prior years*, so a normal winter drawdown reads
dryness ≈ 0 even though the water is absolutely scarce and its shadow value is
high (measured: SE1/SE2 reservoirs draw down to 55–60% of the annual max by
February at dryness 0, yet the model priced their water at the full-reservoir
floor → SE1/SE2 clearing ≈ €18 vs actual ≈ €59). Drawdown restores that seasonal
water-value signal from fundamentals (reservoir physics), with no month dummies.
"""
function get_reservoir_drawdown(bidding_zone::String, day::Date)
    iso_week = Int(Dates.week(day))
    iso_year = year(day)
    df = sql2df_with_retry(
        """
        WITH hist AS (
          SELECT year, week, stored_energy_mwh
          FROM entsoe.aggregated_hydro_storage_filling_rate
          WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
            AND stored_energy_mwh IS NOT NULL
            AND (year < \$2 OR (year = \$2 AND week < \$3))
            AND (year > \$2 - 2 OR (year = \$2 - 1 AND week >= \$3))
        )
        SELECT (SELECT stored_energy_mwh FROM hist ORDER BY year DESC, week DESC LIMIT 1) AS cur,
               (SELECT MAX(stored_energy_mwh) FROM hist) AS mx
        """,
        [bidding_zone, iso_year, iso_week]
    )
    (isempty(df) || ismissing(df.cur[1]) || ismissing(df.mx[1]) ||
        Float64(df.mx[1]) <= 0.0) && return nothing
    return clamp(1.0 - Float64(df.cur[1]) / Float64(df.mx[1]), 0.0, 1.0)
end

"""
    create_merit_order_book(bidding_zone::String, day::Date; kwargs...)

Create a deterministic merit-order-based order book for MPCC clearing.

# Keyword arguments (bidding strategy parameters)
- `tranches`: supply tranches as (capacity share, price multiplier on SRMC)
- `scarcity_threshold`: capacity margin below which scarcity markup kicks in
- `scarcity_kappa`: quadratic scarcity markup coefficient
- `water_value_base` / `water_value_span`: hydro opportunity cost as a
  multiple of gas SRMC, scaled across the day's demand range
- `demand_elastic_share` / `demand_elastic_price`: size and price of the
  price-sensitive demand tail
- `price_cap`: price of the inelastic demand tranche
- `fleet_completion`: add aggregate capacity where the type's recent output
  (p95) exceeds the unit-level fleet (under-reported fleets: RO/BG/RS)
- `fleet_truthing` / `derate_headroom`: derate baseload types whose
  unit-level fleet exceeds `derate_headroom ×` recent p95 — phantom
  capacity from unfiled derates or fuel constraints (2022 GR lignite)

# Scenario hooks (all default `nothing`; when all are `nothing` the code path
# is byte-identical to the no-kwargs call)
- `load_modifier::Union{Nothing,Function}`: `f(timeslot::String, load_mw::Float64) -> Float64`,
  applied to every entry of `load_by_time` at the source (after temporal
  disaggregation and any hourly aggregation), so the change propagates to net
  demand, scarcity margin, water value and demand orders.
- `renewable_modifier::Union{Nothing,Function}`: same signature, applied to
  `renewable_by_time` at the same point (e.g. `(ts, v) -> v + 300` during
  daylight slots models +300 MW of solar).
- `extra_orders::Union{Nothing,Function}`: `f(ctx) -> Vector{SimpleOrder}`,
  called after all standard orders are built and BEFORE merging. `ctx` is a
  NamedTuple `(zone, day, timeslots, resolution_minutes, load_by_time,
  renewable_by_time)`. Returned orders (`:supply` or `:demand`) are appended
  (tagged `"EXTRA"`). Models "ships request more power" (cap-priced demand) or
  "a new plant" (supply).
- `strategist::Union{Nothing,Function}`: `f(ctx) -> Vector{Tuple{SimpleOrder,String}}`
  (a plain `Vector{SimpleOrder}` is also accepted and re-tagged `"STRATEGIST"`),
  called after `extra_orders` and before merging. `ctx` is a NamedTuple
  `(tagged_orders, zone, day, timeslots, load_by_time, renewable_by_time,
  firm_of)` where `firm_of` is a `Dict{String,String}` unit_code→firm from
  `simulations.unit_firms`. The returned set REPLACES the tagged order list.

  Example — "what if the incumbent PPC marked up its peakers' top tranches 20%?":
  ```julia
  strat = ctx -> [ (firm_of_ppc(ctx, o, tag) ? bump(o) : o, tag)
                   for (o, tag) in ctx.tagged_orders ]
  ```
  A strategist that finds all orders whose `firm_of[tag] == "PPC"` and
  multiplies their two top tranche prices by 1.2, returning everything else
  unchanged.
- `fleet_modifier::Union{Nothing,Function}`: `f(zone::String, gens::Vector{Generator}) -> Vector{Generator}`,
  a first-class capacity primitive — add, remove or derate physical units as
  DATA (not orders). Called AFTER fleet completion and fleet-truthing, so a
  removed unit is not re-added by the `:installed`/p95 truth-up and the offered
  fleet is exactly what the modifier returns (scenario edits are physical
  reality changes; truthing runs on the pre-scenario registry). Returning an
  empty vector fails the build gracefully.

Both the single-zone (`:merit_order`) `generate_energy_prices` path and the
multi-zone `run_multi_zone_market_clearing(...; scenario=...)` path thread these
hooks (the latter via `ZoneScenario`). When every hook is `nothing` the built
book is byte-identical to the no-hook book.
"""
function create_merit_order_book(
    bidding_zone::String,
    day::Date;
    profile::ZoneProfile=SEE_PROFILE,
    tranches::Union{Nothing,Vector{Tuple{Float64,Float64}}}=nothing,
    must_run_price_factor::Union{Nothing,Float64}=nothing,
    must_run_srmc_threshold::Union{Nothing,Float64}=nothing,
    availability_factor::Union{Nothing,Float64}=nothing,
    scarcity_threshold::Union{Nothing,Float64}=nothing,
    scarcity_kappa::Union{Nothing,Float64}=nothing,
    peak_kappa::Union{Nothing,Float64}=nothing,
    peak_exponent::Union{Nothing,Float64}=nothing,
    water_value_base::Union{Nothing,Float64}=nothing,
    water_value_dry_boost::Union{Nothing,Float64}=nothing,
    water_value_span::Union{Nothing,Float64}=nothing,
    demand_elastic_share::Union{Nothing,Float64}=nothing,
    demand_elastic_price::Union{Nothing,Float64}=nothing,
    price_cap::Union{Nothing,Float64}=nothing,
    include_net_imports::Bool=true,
    net_import_exclude::Vector{String}=String[],
    net_import_import_only::Vector{String}=String[],
    target_resolution_minutes::Union{Int,Nothing}=nothing,
    fleet_completion::Union{Nothing,Bool}=nothing,
    fleet_truthing::Union{Nothing,Bool}=nothing,
    derate_headroom::Union{Nothing,Float64}=nothing,
    thermal_srmc_multiplier::Union{Nothing,Float64}=nothing,
    hydro_model::Union{Nothing,Symbol}=nothing,
    nuclear_srmc_floor::Union{Nothing,Float64}=nothing,
    opportunity_anchor::Union{Nothing,Symbol}=nothing,
    anchor_share::Union{Nothing,Float64}=nothing,
    anchor_prices::Union{Nothing,Dict{String,Float64}}=nothing,
    anchor_export_mw::Dict{Int,Float64}=Dict{Int,Float64}(),
    res_coalesce_missing::Bool=false,
    load_modifier::Union{Nothing,Function}=nothing,
    renewable_modifier::Union{Nothing,Function}=nothing,
    extra_orders::Union{Nothing,Function}=nothing,
    strategist::Union{Nothing,Function}=nothing,
    fleet_modifier::Union{Nothing,Function}=nothing
)
    # Resolve every bid parameter from the profile, letting an explicit keyword
    # override its profile field. With no overrides and the default SEE_PROFILE
    # this reproduces the pre-abstraction defaults exactly (byte-identical).
    tranches = tranches === nothing ? profile.tranches : tranches
    must_run_price_factor = must_run_price_factor === nothing ? profile.must_run_price_factor : must_run_price_factor
    must_run_srmc_threshold = must_run_srmc_threshold === nothing ? profile.must_run_srmc_threshold : must_run_srmc_threshold
    availability_factor = availability_factor === nothing ? profile.availability_factor : availability_factor
    scarcity_threshold = scarcity_threshold === nothing ? profile.scarcity_threshold : scarcity_threshold
    scarcity_kappa = scarcity_kappa === nothing ? profile.scarcity_kappa : scarcity_kappa
    peak_kappa = peak_kappa === nothing ? profile.peak_kappa : peak_kappa
    peak_exponent = peak_exponent === nothing ? profile.peak_exponent : peak_exponent
    water_value_base = water_value_base === nothing ? profile.water_value_base : water_value_base
    water_value_dry_boost = water_value_dry_boost === nothing ? profile.water_value_dry_boost : water_value_dry_boost
    water_value_span = water_value_span === nothing ? profile.water_value_span : water_value_span
    demand_elastic_share = demand_elastic_share === nothing ? profile.demand_elastic_share : demand_elastic_share
    demand_elastic_price = demand_elastic_price === nothing ? profile.demand_elastic_price : demand_elastic_price
    price_cap = price_cap === nothing ? profile.price_cap : price_cap
    fleet_completion = fleet_completion === nothing ? profile.fleet_completion : fleet_completion
    fleet_truthing = fleet_truthing === nothing ? profile.fleet_truthing : fleet_truthing
    derate_headroom = derate_headroom === nothing ? profile.derate_headroom : derate_headroom
    thermal_srmc_multiplier = thermal_srmc_multiplier === nothing ? profile.thermal_srmc_multiplier : thermal_srmc_multiplier
    hydro_model = hydro_model === nothing ? profile.hydro_model : hydro_model
    nuclear_srmc_floor = nuclear_srmc_floor === nothing ? profile.nuclear_srmc_floor : nuclear_srmc_floor
    opportunity_anchor = opportunity_anchor === nothing ? profile.opportunity_anchor : opportunity_anchor
    anchor_share = anchor_share === nothing ? profile.anchor_share : anchor_share
    # The opportunity anchor is active only when BOTH the profile opts in AND
    # pass-1 reference prices were supplied (two-pass clearing, pass 2). With
    # either missing the whole mechanism is dead code — pass 1 and every
    # single-pass path (incl. SEE) are unchanged.
    anchor_active = opportunity_anchor != :none && anchor_prices !== nothing

    try
        println("📊 Creating merit-order order book for $bidding_zone on $day")

        generators = get_generators(bidding_zone, day)

        # Fleet completion: ENTSO-E's unit-level table only lists larger
        # units, so for some zones (RO, BG, RS) the fleet is structurally
        # undersized and the book clears at spurious shortage-cap prices.
        # When the zone's recent per-type actual output (p95, trailing 30
        # days — strictly historical) exceeds the unit-level capacity of
        # that type, the missing capacity demonstrably exists and produces:
        # add it as one aggregate generator per fuel type. Wind/solar are
        # excluded (netted via the RES forecast). Harmless for zones with
        # good unit coverage — the gap is ~0 there (verified on GR).
        # Shared by fleet completion (upward) and fleet-truthing derate
        # (downward); keys normalized once to canonical fuel names
        type_p95_raw = (fleet_completion || fleet_truthing) ?
                       get_type_output_p95(bidding_zone, day) : Dict{String,Float64}()
        type_p95 = Dict{String,Float64}(
            normalize_fuel_type_name(k) => v for (k, v) in type_p95_raw)
        # Fleet-truth mode (iter7, gated — see the ZoneProfile field docstring).
        # `fleet_truth_target` holds the per-type truth target of MARKET-ACTIVE
        # types only (trailing-30d p95 > 100 MW): those types complete UP to it
        # and are never derated below it. Types with no recent output (phantom
        # post-closure capacity with stale COMMISSIONED status) never enter —
        # that is the activity gate that replaces get_generators' validity
        # filter for this purpose. Empty for :p95 (the default) — byte-identical
        # v10/iter6 behaviour.
        fleet_truth_target = Dict{String,Float64}()
        fleet_truth_mode = _effective_fleet_truth_mode(profile)
        if fleet_completion && fleet_truth_mode != :p95
            src = fleet_truth_mode == :installed ?
                  get_installed_capacity_by_type(bidding_zone) :
                  Dict{String,Float64}(normalize_fuel_type_name(k) => v
                      for (k, v) in get_type_output_p95(bidding_zone, day;
                                                        lookback_days=365))
            for (t, cap) in src
                get(type_p95, t, 0.0) > 100.0 && (fleet_truth_target[t] = cap)
            end
        end
        if fleet_completion
            for (ptype, p95) in type_p95
                ptype in ("Wind Onshore", "Wind Offshore", "Solar") && continue
                fleet = sum((g.p_max for g in generators
                             if g.fuel_type == Symbol(ptype)); init=0.0)
                target = max(p95, get(fleet_truth_target, ptype, 0.0))
                gap = target - fleet
                gap > 100.0 || continue
                push!(generators, Generator(
                    "AGG-$(bidding_zone)-$(replace(ptype, " " => "_"))",
                    "Aggregate small units: $ptype",
                    Symbol(ptype),
                    bidding_zone,
                    gap,
                    0.0,
                    bidding_zone,
                    get_marginal_cost(day, ptype, bidding_zone)))
                src = target > p95 ? "installed $(round(Int, target))" :
                                     "recent p95 $(round(Int, p95))"
                println("  ➕ Fleet completion: +$(round(Int, gap)) MW $ptype " *
                        "($src MW vs $(round(Int, fleet)) MW unit-level)")
            end
        end

        # Fleet-truthing derate — the symmetric case of fleet completion.
        # When the unit-level fleet (after outage filtering) far exceeds
        # what the type has recently delivered, the excess is phantom
        # capacity: unfiled long-term derates, fuel-supply constraints, or
        # stale unit records. 2022 GR lignite is the canonical case — the
        # book offered ~2.2 GW at lignite SRMC while the real fleet's p95
        # was ~1.2 GW, so cheap phantom lignite displaced gas from the
        # margin and the whole crisis year cleared ~140 €/MWh low. Thermal
        # types only: hydro availability is handled by the water-value
        # offer scale, and RES never enters the thermal stack. The signal
        # (trailing 30-day p95, strictly historical) is ex-ante; 15%
        # headroom above p95 leaves room for genuinely tight days to call
        # on more of the fleet than it recently ran.
        #
        # Baseload/fuel-constrained types ONLY. For a fuel whose SRMC sits
        # below the market price, running under its capacity means it
        # genuinely could not run (mining limits, fuel supply, unfiled
        # derates) — it would have been dispatched otherwise. Mid-merit
        # and peaking fuels (gas, oil) run below capacity simply because
        # of their merit-order position; their capacity IS available at
        # its SRMC, and derating them manufactures phantom scarcity.
        derate_types = ("Fossil Brown coal/Lignite", "Fossil Hard coal",
                        "Fossil Oil shale", "Fossil Coal-derived gas",
                        "Fossil Peat", "Nuclear")
        # One scale per fuel type, applied in a single pass. Iterates the
        # FLEET's types (not type_p95's keys): a derate-listed type with a
        # p95 of zero is a fully offline fleet and derates all the way
        # down, while a type entirely absent from the aggregate table is
        # ambiguous (never-reporting type vs ETL gap) and is skipped
        # loudly rather than silently zeroed. Thermal orders offer raw
        # p_max (availability_factor only shapes the scarcity margin), so
        # the target compares against the raw fleet sum. p_min scales
        # proportionally with p_max — clamping instead would balloon the
        # must-run fraction of every derated unit.
        derate_scale = Dict{Symbol,Float64}()
        if fleet_truthing
            for ptype in derate_types
                fsym = Symbol(ptype)
                fleet_raw = sum((g.p_max for g in generators if g.fuel_type == fsym); init=0.0)
                fleet_raw > 0 || continue
                if !haskey(type_p95, ptype)
                    println("  ⚠️  Fleet-truthing: no recent output data for $ptype " *
                            "($(round(Int, fleet_raw)) MW fleet) — derate skipped")
                    continue
                end
                # Fleet-truth mode: a market-active type never derates below
                # its truth target (the completion above just trued it to
                # exactly that — derating it back to 1.15×30d-p95 would cancel
                # the mechanism for precisely the baseload derate-types it
                # targets). :p95 zones (GR/SEE) have fleet_truth_target empty —
                # byte-identical v10 behaviour.
                target = max(derate_headroom * type_p95[ptype],
                             get(fleet_truth_target, ptype, 0.0))
                fleet_raw > target + 100.0 || continue
                derate_scale[fsym] = target / fleet_raw
                println("  ➖ Fleet-truthing derate: $ptype ×$(round(target / fleet_raw, digits=2)) " *
                        "(fleet $(round(Int, fleet_raw)) MW vs recent p95 $(round(Int, type_p95[ptype])) MW)")
            end
        end
        # Thermal SRMC premium (ITALY_PROFILE): scale the marginal cost of
        # thermal fuels only — hydro/storage price at water value, not fuel
        # cost, and RES never enters the thermal stack. gas_srmc (the hydro
        # anchor) is computed separately and is unaffected. Default multiplier
        # 1.0 leaves every cost untouched (byte-identical for SEE).
        srmc_exempt_fuels = Set{Symbol}(vcat(WATER_VALUE_FUEL_TYPES,
            [Symbol("Hydro Run-of-river and pondage"), Symbol("Energy storage")]))
        apply_srmc_premium = thermal_srmc_multiplier != 1.0
        # Nuclear bid-position floor (FRANCE_PROFILE): raise the nuclear bid
        # base to at least this level — nuclear-dominated exporters price their
        # modulating fleet at opportunity cost, not fuel SRMC. Default 0.0 is a
        # no-op (byte-identical for SEE).
        # When the :nuclear anchor is ACTIVE the static floor is replaced by the
        # per-slot anchor floor in the order loop (a static floor would hold the
        # price up in exactly the RES-surplus hours where the coupled price —
        # and EDF's opportunity cost — collapses: 2026-04 weekends, FR actual
        # €9 vs the €55 floor).
        apply_nuclear_floor = nuclear_srmc_floor > 0.0 &&
                              !(anchor_active && opportunity_anchor == :nuclear)
        # Per-unit SRMC spread (cv18): thermal fuels only — hydro/storage price
        # at water value, and RES never enters the thermal stack. The factor is
        # a deterministic FNV-1a hash of the unit code (reproducible across
        # sessions and Julia versions, unlike Base.hash), uniform in 1 ± spread.
        apply_unit_spread = profile.unit_srmc_spread > 0.0
        if !isempty(derate_scale) || apply_srmc_premium || apply_nuclear_floor ||
           apply_unit_spread
            generators = [begin
                s = get(derate_scale, g.fuel_type, 1.0)
                m = (apply_srmc_premium && !(g.fuel_type in srmc_exempt_fuels)) ?
                    thermal_srmc_multiplier : 1.0
                mc = g.marginal_cost * m
                if apply_nuclear_floor && g.fuel_type == Symbol("Nuclear")
                    mc = max(mc, nuclear_srmc_floor)
                end
                if apply_unit_spread && !(g.fuel_type in srmc_exempt_fuels)
                    mc *= 1.0 + profile.unit_srmc_spread * (2.0 * _unit_hash01(g.code) - 1.0)
                end
                (s < 1.0 || mc != g.marginal_cost) ?
                    Generator(g.code, g.name, g.fuel_type, g.location,
                              g.p_max * s, g.p_min * s,
                              g.bidding_zone, mc,
                              g.ramp_up, g.ramp_down, g.min_uptime, g.min_downtime) :
                    g
            end for g in generators]
        end

        # Scenario fleet_modifier — add / remove / derate physical units as
        # DATA. Applied AFTER fleet completion and fleet-truthing (above) on
        # purpose: those two mechanisms true the registry to the zone's
        # recently-observed capability, and they must run on the PRE-scenario
        # registry. If the modifier ran first, removing a 500 MW unit would
        # enlarge the completion gap and the `:installed`/p95 truth-up would
        # silently re-add the same aggregate MW — nullifying the edit. Running
        # it last makes scenario edits genuine "physical reality changes": the
        # offered fleet reflects exactly what the modifier returns. No-op when
        # the hook is nothing (byte-identical).
        if fleet_modifier !== nothing
            generators = collect(fleet_modifier(bidding_zone, generators))
            eltype(generators) <: Generator ||
                error("fleet_modifier must return a Vector{Generator}, got eltype $(eltype(generators))")
            isempty(generators) &&
                return AdjustedOrderBookResult(false,
                    "fleet_modifier removed all generators", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end
        loads = get_loads(bidding_zone, day)
        renewables = get_generation_forecast_for_wind_and_solar(bidding_zone, day;
            coalesce_missing=res_coalesce_missing)

        if isempty(generators)
            return AdjustedOrderBookResult(false, "No generators found", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end
        if isempty(loads)
            return AdjustedOrderBookResult(false, "No load data found", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end

        target_timeslots, load_by_time, renewable_by_time, resolution_minutes =
            disaggregate_temporal_data(loads, renewables)

        # Resolution harmonization for multi-zone books: zones publish at
        # different resolutions (e.g. RO/HU 15-min, GR/BG hourly) and a
        # combined book with mixed timeslots isolates the hourly zones in
        # sub-hour slots. Aggregate MW values to the coarser target by
        # averaging sub-slots (MW is power — averaging preserves energy).
        if target_resolution_minutes !== nothing && resolution_minutes < target_resolution_minutes
            target_resolution_minutes == 60 ||
                error("Only hourly (60) target resolution is supported for down-aggregation, got $target_resolution_minutes")
            hour_key(ts) = ts[1:11] * "00"
            function aggregate_to_hours(d::Dict{String,Float64})
                sums = Dict{String,Tuple{Float64,Int}}()
                for (ts, v) in d
                    k = hour_key(ts)
                    s, n = get(sums, k, (0.0, 0))
                    sums[k] = (s + v, n + 1)
                end
                return Dict{String,Float64}(k => s / n for (k, (s, n)) in sums)
            end
            load_by_time = aggregate_to_hours(load_by_time)
            renewable_by_time = aggregate_to_hours(renewable_by_time)
            target_timeslots = sort(collect(keys(load_by_time)))
            println("  🕐 Aggregated $(resolution_minutes)-min data to hourly ($(length(target_timeslots)) slots)")
            resolution_minutes = target_resolution_minutes
        elseif target_resolution_minutes !== nothing && resolution_minutes > target_resolution_minutes
            # UPSAMPLE (piecewise-constant REPLICATION) to a finer target grid.
            # A zone whose native data is coarser than the shared clearing grid
            # (e.g. an hourly PT60M zone in a 15-min clear) has each native
            # slot's MW LEVEL copied into every finer sub-slot it spans.
            # Load and generation are power levels (MW), NOT energy (MWh): a
            # plant offering 500 MW offers 500 MW in each quarter — the energy
            # divides naturally because the period is shorter, but the level is
            # unchanged. DIVIDING by the sub-slot count would quarter both
            # demand and supply and misprice everything. Downstream per-slot
            # computations (scarcity margin, water value, demand orders, net
            # imports which are hour-keyed) then run on the shared finer grid
            # exactly as they would for a natively-fine zone.
            target_resolution_minutes in (15, 30) ||
                error("Only 15 or 30-min target resolution is supported for up-replication, got $target_resolution_minutes")
            load_by_time = replicate_to_finer_resolution(load_by_time, resolution_minutes, target_resolution_minutes)
            renewable_by_time = replicate_to_finer_resolution(renewable_by_time, resolution_minutes, target_resolution_minutes)
            target_timeslots = sort(collect(keys(load_by_time)))
            println("  🕐 Upsampled $(resolution_minutes)-min data to $(target_resolution_minutes)-min " *
                    "($(length(target_timeslots)) slots) by piecewise-constant replication")
            resolution_minutes = target_resolution_minutes
        end

        # Scenario demand/supply modifiers, applied at the SOURCE dictionaries
        # (after disaggregation and any hourly aggregation) so the change
        # propagates to net demand, scarcity margin, water value and demand
        # orders. No-op when the hooks are nothing.
        if load_modifier !== nothing
            for ts in keys(load_by_time)
                load_by_time[ts] = load_modifier(ts, load_by_time[ts])
            end
        end
        if renewable_modifier !== nothing
            for ts in keys(renewable_by_time)
                renewable_by_time[ts] = renewable_modifier(ts, renewable_by_time[ts])
            end
        end

        # Residual demand per slot (load minus renewables) drives water value
        # and scarcity. Renewables themselves are offered as near-zero-price
        # supply below, NOT netted from demand — this lets prices collapse
        # toward zero in renewable-surplus hours, as they do in reality.
        # Net physical imports as fixed injections: observed cross-border
        # schedules (positive = import). A single zone cleared in isolation
        # systematically overprices import hours and underprices export
        # hours; using the observed schedule is the standard single-zone
        # backtesting treatment. Set include_net_imports=false for a pure
        # isolated-zone simulation (or when forecasting without flow data).
        net_imports = include_net_imports ?
                      get_net_imports(bidding_zone, day;
                          exclude_counterparties=net_import_exclude,
                          import_only_counterparties=net_import_import_only) :
                      Dict{Int,Float64}()
        slot_import(ts) = get(net_imports, Dates.hour(parse_timeslot_to_datetime(ts, day)), 0.0)

        gross_demand = Dict{String,Float64}()
        net_demand = Dict{String,Float64}()
        for ts in target_timeslots
            load_value = get(load_by_time, ts, 0.0)
            renewable_gen = get(renewable_by_time, ts, 0.0)
            gross_demand[ts] = max(10.0, load_value)
            # Residual demand on domestic thermal: load - RES - net imports
            net_demand[ts] = max(10.0, load_value - renewable_gen - slot_import(ts))
        end
        nd_values = [net_demand[ts] for ts in target_timeslots]
        nd_min, nd_max = minimum(nd_values), maximum(nd_values)
        nd_span = max(nd_max - nd_min, 1.0)

        # Gas SRMC anchors hydro water value (TTF-based when data exists)
        gas_srmc = get_marginal_cost(day, "Fossil Gas", bidding_zone)

        # Ex-ante elastic import backstop (cv17, profile-gated — see the
        # `import_backstop` field docstring). Computed next to the :v2 flow
        # climatology off the same cached day relations; the offered ATC of
        # the ENDOGENOUS borders (net_import_exclude — kept-ATC neighbors plus
        # shadowed aggregate codes, whose aggregate-coded ATC the remap already
        # carries endogenously) is subtracted so MPCC-deliverable capacity is
        # never double-counted. Empty Dict for every non-backstop profile —
        # byte-identical books.
        backstop_by_hour = (profile.import_backstop && include_net_imports) ?
            get_import_backstop(bidding_zone, day;
                weeks=profile.backstop_weeks,
                endogenous_counterparties=net_import_exclude) :
            Dict{Int,Float64}()
        backstop_price = profile.backstop_price_mult * gas_srmc
        isempty(backstop_by_hour) ||
            println("  🛟 Import backstop: peak $(round(Int, maximum(values(backstop_by_hour)))) MW " *
                    "@ €$(round(backstop_price, digits=1))/MWh " *
                    "($(length(backstop_by_hour)) hours, $(profile.backstop_weeks)-week window)")

        # Hydro energy limitation: recent actual peak output caps what the
        # hydro fleet can offer (dry periods → less water → tighter margin).
        # Thermal keeps the flat availability derate; hydro gets a
        # data-driven one.
        is_hydro(g) = g.fuel_type in WATER_VALUE_FUEL_TYPES ||
                      g.fuel_type == Symbol("Hydro Run-of-river and pondage")
        hydro_pmax = sum((g.p_max for g in generators if is_hydro(g)); init=0.0)
        hydro_scale = 1.0   # offered-quantity cap (fraction of nameplate)
        hydro_dryness = 0.0 # 0 = normal water conditions, →1 = severe drought
        reservoir_drawdown = 0.0 # 0 = reservoir at seasonal peak, →1 = drawn down
        if hydro_pmax > 1.0
            hydro_avail = get_hydro_availability(bidding_zone, day)
            if hydro_avail !== nothing
                hydro_scale = clamp(hydro_avail / hydro_pmax, 0.2, 1.0)
            end
            # Dryness: prefer reservoir filling levels vs seasonal norm
            # (measures the water itself); fall back to recent-vs-1y output
            # when filling data is unavailable for the zone. Output-based
            # dryness is confounded by dispatch incentive: hydro running
            # hard because prices are high looks "wet" while reservoirs
            # are actually draining.
            reservoir_dryness = get_reservoir_dryness(bidding_zone, day)
            if reservoir_dryness !== nothing
                hydro_dryness = reservoir_dryness
            elseif hydro_avail !== nothing
                # Fallback only when no reservoir filling data: the 365-day
                # output norm is an expensive near-full scan of the per-type
                # table, so compute it lazily here rather than unconditionally.
                hydro_norm = get_hydro_availability(bidding_zone, day; lookback_days=365)
                if hydro_norm !== nothing && hydro_norm > 1.0
                    hydro_dryness = clamp(1.0 - hydro_avail / hydro_norm, 0.0, 1.0)
                end
            end
            # Reservoir-opportunity zones (Nordic) govern offered hydro QUANTITY
            # by reservoir level, not by recent output. The p95-output cap above
            # is a gas-world energy-limited heuristic; in a hydro-dominated,
            # capacity-rich system it spuriously starves the book (e.g. NO1's
            # standalone supply/demand ratio ≈ 0.95 → phantom shortage at the
            # cap) even when reservoirs are full. Tie the offered fraction to
            # reservoir fullness instead: full → near-nameplate, severe drought
            # → half (inflow-only). Scarcity here is priced through the water
            # value, not rationed through quantity.
            if hydro_model == :reservoir_opportunity
                hydro_scale = clamp(1.0 - hydro_dryness, 0.5, 1.0)
                # Seasonal water-value signal: the absolute reservoir drawdown
                # (vs the trailing-52-week peak) prices the water as scarcer
                # through winter even when the prior-year-relative dryness reads
                # ~0. Affects the PRICE (wv_frac below), never the offered
                # quantity. Only the non-anchored reservoir zones
                # (SE1/SE2/FI/DK1/DK2/NO4) reach the wv_frac branch — the
                # Norway/alpine :hydro-anchored zones price off the anchor.
                if profile.seasonal_drawdown
                    dd = get_reservoir_drawdown(bidding_zone, day)
                    dd !== nothing && (reservoir_drawdown = dd)
                end
            end
            println("  💧 Hydro: offer scale $(round(hydro_scale, digits=2)), " *
                    "dryness $(round(hydro_dryness, digits=2))" *
                    (reservoir_dryness !== nothing ? " (reservoir levels)" : " (output-based fallback)") *
                    (hydro_model == :reservoir_opportunity ? " [reservoir-opportunity]" : ""))
        end
        offered_pmax(g) = is_hydro(g) ? g.p_max * hydro_scale : g.p_max

        # Dispatchable capacity for the scarcity margin, derated for the
        # realistic availability of the fleet (unreported outages) and for
        # the hydro energy limit — nameplate capacity never looks scarce.
        dispatchable_capacity =
            availability_factor * sum((g.p_max for g in generators if !is_hydro(g)); init=0.0) +
            hydro_scale * hydro_pmax

        # Available import capacity per UTC hour, credited into the scarcity
        # margin when the profile opts in (thermal import/export zones). 0 = off.
        import_atc_by_hour = profile.scarcity_import_credit > 0.0 ?
            get_import_atc_capacity(bidding_zone, day) : Dict{Int,Float64}()

        # UC-lite commitment: only units that are actually running
        # self-schedule their minimum load. Approximate the committed set as
        # the cheapest eligible thermal units whose derated capacity covers
        # the day's peak residual demand (commitment follows the peak; the
        # p_min of that set is then must-run through the trough).
        committed = Set{String}()
        peak_residual = nd_max
        eligible = sort(
            [g for g in generators
             if !(g.fuel_type in WATER_VALUE_FUEL_TYPES) &&
                g.marginal_cost <= must_run_srmc_threshold * gas_srmc &&
                g.p_min > 0.1],
            by=g -> g.marginal_cost)
        cum_capacity = 0.0
        for g in eligible
            cum_capacity >= 1.05 * peak_residual && break
            push!(committed, g.code)
            cum_capacity += availability_factor * g.p_max
        end

        # Every order is tagged with an owner (Feature 5, strategist hook):
        # the generator code for unit orders, "RES" for the renewable
        # forecast, "IMPORT" for net-import injections, "DEMAND" for demand
        # orders, "EXTRA" for extra_orders, "STRATEGIST" for strategist
        # replacements. Tags never affect the SimpleOrder values, so with no
        # hooks the merged book is byte-identical to before.
        tagged = Tuple{SimpleOrder,String}[]
        supply_orders_count = 0
        demand_orders_count = 0
        total_demand_quantity = 0.0
        total_supply_capacity = 0.0

        for ts in target_timeslots
            date_time = parse_timeslot_to_datetime(ts, day)

            # Renewable forecast offered at near-zero price (RES bids as
            # price-taker; support schemes make it insensitive to price)
            res_qty = get(renewable_by_time, ts, 0.0)
            if res_qty > 0.1
                push!(tagged, (SimpleOrder(:supply, 1.0, res_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes), "RES"))
                supply_orders_count += 1
                total_supply_capacity += res_qty
            end

            # Net imports as price-taking supply (imports) or firm extra
            # demand (exports) — scheduled flows are committed either way
            ni = slot_import(ts)
            if ni > 0.1
                # :hydro-anchored zones (pass 2): observed imports arrive at
                # the BORDER price, not free — pricing them near zero lets the
                # import block set near-zero clearing prices in every
                # import-covered hour (NO1's flat undershoot: sim ≈ €3 at
                # night vs actual ≈ €88 tracking its neighbors). Priced at the
                # anchor level the import-marginal hours clear at the coupled
                # reference, as they do in reality. Everywhere else imports
                # stay price-taking at €1 (unchanged).
                import_price = (anchor_active && opportunity_anchor == :hydro &&
                                haskey(anchor_prices, ts)) ?
                               clamp(anchor_share * anchor_prices[ts], 1.0, gas_srmc) : 1.0
                push!(tagged, (SimpleOrder(:supply, import_price, ni,
                    Symbol(bidding_zone), date_time, resolution_minutes), "IMPORT"))
                supply_orders_count += 1
                total_supply_capacity += ni
            elseif ni < -0.1
                # cv17 ref-priced retained-border exports (profile-gated,
                # pass 2 only): a net export over RETAINED borders (SI–HR,
                # BE–GB) enters as demand at the coupled/anchor reference
                # instead of firm at the cap, so the exporter curtails under
                # domestic stress like a real one — the demand-side mirror of
                # the dropped-border anchor_export_mw treatment. Everywhere
                # else (and in pass 1) the export stays cap-priced firm demand.
                export_price = (profile.ref_priced_exports && anchor_active &&
                                haskey(anchor_prices, ts)) ?
                               max(anchor_prices[ts], 1.0) : price_cap
                push!(tagged, (SimpleOrder(:demand, export_price, -ni,
                    Symbol(bidding_zone), date_time, resolution_minutes), "IMPORT"))
                demand_orders_count += 1
                total_demand_quantity += -ni
            end

            # cv17 import-backstop supply block (profile-gated; empty Dict
            # otherwise). Priced above every domestic tranche multiplier, so
            # it binds only when the book would otherwise jump to the cap.
            backstop_qty = get(backstop_by_hour, Dates.hour(date_time), 0.0)
            if backstop_qty > 1.0
                push!(tagged, (SimpleOrder(:supply, backstop_price, backstop_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes), "BACKSTOP"))
                supply_orders_count += 1
                total_supply_capacity += backstop_qty
            end

            # :hydro-anchored zones (pass 2): the export volume observed over
            # the DROPPED flow-based borders re-enters as demand priced at the
            # coupled reference — NOT the cap. NO5 is the measured case: a
            # structural exporter whose import-only clamp removed the export
            # outlet entirely, collapsing its surplus onto a tiny local load
            # (sim €36 vs actual €104). Ref-priced demand clears only when the
            # zone's price is at/below the coupled price, so it cannot
            # manufacture cap scarcity; and it is SEPARATE from the clamped
            # import supply, so it cannot net away import energy either
            # (measured failure mode of netting: NO1 −23 → +134).
            if anchor_active && opportunity_anchor == :hydro &&
               haskey(anchor_prices, ts) && !isempty(anchor_export_mw)
                ex_mw = get(anchor_export_mw, Dates.hour(date_time), 0.0)
                if ex_mw > 0.1
                    push!(tagged, (SimpleOrder(:demand, max(anchor_prices[ts], 1.0),
                        ex_mw, Symbol(bidding_zone), date_time, resolution_minutes), "IMPORT"))
                    demand_orders_count += 1
                    total_demand_quantity += ex_mw
                end
            end

            # Normalized within-day demand position (0 = trough, 1 = peak)
            norm_demand = (net_demand[ts] - nd_min) / nd_span

            # Markup on upper supply tranches: absolute scarcity (capacity
            # margin below threshold) plus peak-hour strategic bidding —
            # participants know when the daily peak is and price their last
            # tranches accordingly, even when capacity is formally adequate.
            # The high exponent concentrates the markup in the true peak
            # hours: at norm_demand 0.5 (e.g. summer nights, where residual
            # demand is mid-range) the markup is ~6% of peak_kappa, not 25%.
            # Credit available import capacity (gated): a zone that can import
            # GWs is not domestically scarce. Only the scarcity term is relieved;
            # the peak strategic-bidding term is left intact.
            import_credit = profile.scarcity_import_credit > 0.0 ?
                profile.scarcity_import_credit *
                get(import_atc_by_hour, Dates.hour(parse_timeslot_to_datetime(ts, day)), 0.0) : 0.0
            # cv17: gated scarcity credit for the backstop quantity (the
            # scarcity MARKUP cannot otherwise see the backstop supply, so
            # restored-import days can keep a residual markup overshoot).
            # 0 (default) = off everywhere.
            backstop_credit = profile.backstop_scarcity_credit > 0.0 ?
                profile.backstop_scarcity_credit *
                get(backstop_by_hour, Dates.hour(parse_timeslot_to_datetime(ts, day)), 0.0) : 0.0
            margin = (dispatchable_capacity + import_credit + backstop_credit) / net_demand[ts]
            scarcity = 1.0 +
                       scarcity_kappa * max(0.0, scarcity_threshold - margin)^2 +
                       peak_kappa * norm_demand^peak_exponent

            for g in generators
                if g.fuel_type in WATER_VALUE_FUEL_TYPES
                    # Hydro water value. Two models:
                    #
                    # :gas_anchored (SEE default) — opportunity cost tied to gas
                    # SRMC: cheap relative to gas off-peak, premium over gas at
                    # the peak, boosted in dry periods. Correct where hydro
                    # competes against a gas-set margin.
                    #
                    # :reservoir_opportunity (Nordic) — in a hydro-dominated
                    # zone the price is the shadow value of stored water, NOT a
                    # gas anchor: near-free when reservoirs are full, rising
                    # toward the continental thermal alternative (gas SRMC as a
                    # proxy for the export-market price) as they empty. This
                    # stops full Nordic reservoirs from slamming into scarcity/
                    # cap prices.
                    # :hydro opportunity anchor (two-pass, pass 2): stored
                    # water prices at the export opportunity — the pass-1
                    # coupled reference price (level AND hourly shape) — times
                    # a share slightly below 1 when reservoirs are full
                    # (willing to undercut the continent to export), rising
                    # with dryness. Clamped to [2, gas SRMC].
                    water_value = if anchor_active && opportunity_anchor == :hydro &&
                                     haskey(anchor_prices, ts)
                        clamp(anchor_prices[ts] *
                              (anchor_share + water_value_dry_boost * hydro_dryness),
                              2.0, gas_srmc)
                    elseif hydro_model == :reservoir_opportunity
                        # Stored water is worth a FRACTION of the continental
                        # thermal price (gas SRMC proxy): an export-opportunity
                        # floor (~0.35×) when reservoirs are full, rising to the
                        # full thermal alternative (1.0×) as they empty. Then
                        # shaped by within-day demand. NOT gas-anchored at parity
                        # — full Nordic reservoirs price well below gas, which is
                        # what stops the scarcity/cap blow-up.
                        # Floor rises with EITHER prior-year dryness OR the
                        # absolute seasonal drawdown (winter reservoir depletion
                        # raises the shadow value of stored water — SE1/SE2 draw
                        # to 55–60% of the annual peak by February at dryness 0).
                        wv_frac = 0.35 + 0.65 * max(hydro_dryness, reservoir_drawdown)
                        gas_srmc * wv_frac * (water_value_base + water_value_span * norm_demand)
                    else
                        gas_srmc * (1.0 + water_value_dry_boost * hydro_dryness) *
                        (water_value_base + water_value_span * norm_demand)
                    end
                    push!(tagged, (SimpleOrder(:supply, water_value, offered_pmax(g),
                        Symbol(bidding_zone), date_time, resolution_minutes), g.code))
                    supply_orders_count += 1
                    total_supply_capacity += offered_pmax(g)
                else
                    # :nuclear opportunity anchor (two-pass, pass 2): nuclear's
                    # effective bid base per slot is the export opportunity —
                    # anchor_share × the pass-1 coupled reference price —
                    # floored at fuel SRMC. It rises with the coupled price on
                    # weekday nights and COLLAPSES with it in RES-surplus hours
                    # (weekends/midday), which a static floor cannot do.
                    # Everywhere else gmc ≡ g.marginal_cost.
                    gmc = (anchor_active && opportunity_anchor == :nuclear &&
                           g.fuel_type == Symbol("Nuclear") &&
                           haskey(anchor_prices, ts)) ?
                          max(g.marginal_cost, anchor_share * anchor_prices[ts]) :
                          g.marginal_cost
                    # Must-run self-scheduling: baseload-ish units (SRMC not
                    # far above gas) bid their minimum-load block near zero —
                    # shutting down and restarting costs more than running a
                    # few hours below cost. This is what lets midday prices
                    # collapse below thermal SRMC in renewable-surplus hours.
                    must_run_qty = 0.0
                    if g.code in committed
                        must_run_qty = min(g.p_min, offered_pmax(g))
                        # Graduated self-scheduling: the deepest block is
                        # near-free (never shut down), the rest bids below
                        # cost — real curves are convex, not a cliff. The
                        # below-cost discount is ABSOLUTE (startup-cost
                        # amortization is €/MWh over the p_min hours, not a
                        # fraction of fuel cost): a proportional 0.5×SRMC
                        # discount is benign at gas ≈ 90 (−45) but capped
                        # crisis evenings at half the real gas cost
                        # (−212 at TTF 218, 2022) and sank the whole year.
                        deep_qty = must_run_qty * 0.6
                        push!(tagged, (SimpleOrder(:supply,
                            gmc * must_run_price_factor, deep_qty,
                            Symbol(bidding_zone), date_time, resolution_minutes), g.code))
                        push!(tagged, (SimpleOrder(:supply,
                            max(gmc * 0.5, gmc - 40.0),
                            must_run_qty - deep_qty,
                            Symbol(bidding_zone), date_time, resolution_minutes), g.code))
                        supply_orders_count += 2
                        total_supply_capacity += must_run_qty
                    end

                    # Remaining capacity: tranche ladder on SRMC, scarcity
                    # markup on the upper tranches (first tranche stays at
                    # cost so mid-merit keeps clearing)
                    flexible_capacity = max(offered_pmax(g) - must_run_qty, 0.0)
                    for (i, (share, mult)) in enumerate(tranches)
                        price = gmc * mult * (i == 1 ? 1.0 : scarcity)
                        qty = flexible_capacity * share
                        qty < 0.1 && continue
                        push!(tagged, (SimpleOrder(:supply, price, qty,
                            Symbol(bidding_zone), date_time, resolution_minutes), g.code))
                        supply_orders_count += 1
                        total_supply_capacity += qty
                    end
                end
            end
        end

        # Demand: inelastic tranche at the cap + small price-sensitive tail
        for ts in target_timeslots
            date_time = parse_timeslot_to_datetime(ts, day)
            gd = gross_demand[ts]

            inelastic_qty = gd * (1.0 - demand_elastic_share)
            push!(tagged, (SimpleOrder(:demand, price_cap, inelastic_qty,
                Symbol(bidding_zone), date_time, resolution_minutes), "DEMAND"))
            demand_orders_count += 1

            elastic_qty = gd * demand_elastic_share
            if elastic_qty > 0.1
                push!(tagged, (SimpleOrder(:demand, demand_elastic_price, elastic_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes), "DEMAND"))
                demand_orders_count += 1
            end
            # Export-absorption ladder (cv18): elastic demand below the thermal
            # band that binds only in RES-surplus hours — see the profile field
            # docstring. Tagged distinctly so the bids view can label it.
            for (step_price, step_mw) in profile.export_absorption_steps
                push!(tagged, (SimpleOrder(:demand, step_price, step_mw,
                    Symbol(bidding_zone), date_time, resolution_minutes), "EXPORT_ABS"))
                demand_orders_count += 1
            end
            total_demand_quantity += gd
        end

        # Feature 3/4: extra scenario orders appended after all standard
        # orders and BEFORE merging. Both :supply and :demand are allowed.
        if extra_orders !== nothing
            ctx = (zone=bidding_zone, day=day, timeslots=target_timeslots,
                   resolution_minutes=resolution_minutes,
                   load_by_time=load_by_time, renewable_by_time=renewable_by_time)
            for o in extra_orders(ctx)
                push!(tagged, (o, "EXTRA"))
                if o.type == :supply
                    supply_orders_count += 1
                    total_supply_capacity += o.quantity
                else
                    demand_orders_count += 1
                    total_demand_quantity += o.quantity
                end
            end
        end

        # Feature 5: strategist hook, called after extra_orders and before
        # merging. It receives the full tagged order list plus a unit→firm
        # map and RETURNS the replacement tagged list.
        if strategist !== nothing
            firm_of = get_firm_of(bidding_zone)
            sctx = (tagged_orders=tagged, zone=bidding_zone, day=day,
                    timeslots=target_timeslots, load_by_time=load_by_time,
                    renewable_by_time=renewable_by_time, firm_of=firm_of)
            result = strategist(sctx)
            # Accept either Vector{Tuple{SimpleOrder,String}} or a plain
            # Vector{SimpleOrder} (re-tagged "STRATEGIST").
            tagged = Tuple{SimpleOrder,String}[
                x isa Tuple ? (x[1], x[2]) : (x, "STRATEGIST") for x in result]
            # Recount from the replacement set so summary stats stay accurate
            supply_orders_count = count(t -> t[1].type == :supply, tagged)
            demand_orders_count = count(t -> t[1].type == :demand, tagged)
            total_supply_capacity = sum((t[1].quantity for t in tagged if t[1].type == :supply); init=0.0)
            total_demand_quantity = sum((t[1].quantity for t in tagged if t[1].type == :demand); init=0.0)
        end

        orders = SimpleOrder[t[1] for t in tagged]

        # Merge orders with identical (type, price, timeslot): all units of a
        # fuel type bid the same SRMC-derived tranche prices, so a zone-day
        # book collapses ~6x with market-equivalent clearing (partial
        # acceptance of a merged block ≡ distributing it among the
        # identically-priced originals). This directly cuts the MPCC binary
        # count, which is what limits multi-zone solve times.
        merged = Dict{Tuple{Symbol,Float64,DateTime},Float64}()
        for o in orders
            key = (o.type, round(o.price, digits=2), o.date_time)
            merged[key] = get(merged, key, 0.0) + o.quantity
        end
        pre_merge_count = length(orders)
        orders = [SimpleOrder(t, p, q, Symbol(bidding_zone), dt, resolution_minutes)
                  for ((t, p, dt), q) in merged]
        println("  🔗 Merged $(pre_merge_count) orders into $(length(orders)) price-distinct blocks")

        nodes = [bidding_zone]
        # EU day-ahead floor is -500; ceiling is the demand cap so shortage
        # hours can price exactly at the cap
        price_limits = (-500.0, price_cap)
        order_book = MPCCOrderBook(orders, nodes, target_timeslots, price_limits, nothing)

        supply_per_slot = total_supply_capacity / length(target_timeslots)
        demand_per_slot = total_demand_quantity / length(target_timeslots)
        ratio = demand_per_slot > 0 ? supply_per_slot / demand_per_slot : 0.0

        println("  ✅ Merit-order book: $supply_orders_count supply / $demand_orders_count demand orders")
        println("     ⚖️  Supply/Demand ratio: $(round(ratio, digits=2))  (gas SRMC €$(round(gas_srmc, digits=1))/MWh)")

        return AdjustedOrderBookResult(
            true, "Merit-order book created successfully", order_book,
            length(generators), demand_orders_count, supply_orders_count,
            total_demand_quantity, total_supply_capacity, ratio)

    catch e
        e isa InterruptException && rethrow()
        error_msg = "Error creating merit-order book: $(sprint(showerror, e))"
        println("  ❌ $error_msg")
        return AdjustedOrderBookResult(false, error_msg, nothing, 0, 0, 0, 0.0, 0.0, 0.0)
    end
end

end  # module MeritOrderBook
