module Network

using JuMP, Dates, DataFrames

"""
Helper function to check if database functionality is available.
"""
function is_database_available()
    return isdefined(Main, :Euphemia) && isdefined(Main.Euphemia, :sql2df) && hasmethod(Main.Euphemia.sql2df, (String,))
end

"""
Helper function to safely call database query.
"""
function safe_sql2df(query::String, params=[])
    if !is_database_available()
        throw(ErrorException("Database function not available - Main.Euphemia.sql2df not found"))
    end
    return Main.Euphemia.sql2df(query, params)
end

# =============================================================================
# PHYSICAL NETWORK APPROACH (Line-based modeling)
# =============================================================================

"""
Network topology and constraints data structures for EUPHEMIA
Based on Section 4.3 (ATC Model) of the Euphemia Public Description
"""
struct NetworkTopology
    lines::Vector{String}                          # Line identifiers  
    time_periods::Vector{String}                   # Time period identifiers
    ATC_UP::Dict{Tuple{String,String},Float64}     # Upper ATC limits [line, period] → MW
    ATC_DOWN::Dict{Tuple{String,String},Float64}   # Lower ATC limits [line, period] → MW
    source_zone::Dict{String,String}               # Line → source bidding zone
    sink_zone::Dict{String,String}                 # Line → sink bidding zone
end

"""
    create_example_network()

Creates an example network topology based on Figure 2 from Section 4.3 (ATC Model).
Includes bidding zones A, C, H, J with interconnectors as shown in the documentation.
"""
function create_example_network()
    return NetworkTopology(
        # Line identifiers (source→sink naming convention)
        ["A_to_C", "H_to_C", "H_to_J"],

        # Time periods (would typically be 24 hourly periods for day-ahead)
        ["1", "2", "3"],

        # ATC_UP: Upper limits for each [line, time_period] (MW)
        Dict(
            ("A_to_C", "1") => 250.0, ("A_to_C", "2") => 250.0, ("A_to_C", "3") => 250.0,
            ("H_to_C", "1") => 600.0, ("H_to_C", "2") => 600.0, ("H_to_C", "3") => 600.0,
            ("H_to_J", "1") => 1600.0, ("H_to_J", "2") => 1600.0, ("H_to_J", "3") => 1600.0
        ),

        # ATC_DOWN: Lower limits for each [line, time_period] (MW, negative values)
        Dict(
            ("A_to_C", "1") => -300.0, ("A_to_C", "2") => -300.0, ("A_to_C", "3") => -300.0,
            ("H_to_C", "1") => -500.0, ("H_to_C", "2") => -500.0, ("H_to_C", "3") => -500.0,
            ("H_to_J", "1") => -900.0, ("H_to_J", "2") => -900.0, ("H_to_J", "3") => -900.0
        ),

        # Source bidding zone for each line
        Dict("A_to_C" => "A", "H_to_C" => "H", "H_to_J" => "H"),

        # Sink bidding zone for each line  
        Dict("A_to_C" => "C", "H_to_C" => "C", "H_to_J" => "J")
    )
end

"""
    add_atc_constraints!(model::Model, network::NetworkTopology, FLOW)

Adds ATC (Available Transfer Capacity) constraints to a JuMP model.
Based on Section 4.3.1 of the Euphemia Public Description.

# Arguments
- `model::Model`: JuMP optimization model
- `network::NetworkTopology`: Network topology data
- `FLOW`: JuMP variable array for line flows [line, time_period]

# Constraints Added
For each line l and time period t:
```
ATC_DOWN[l, t] ≤ FLOW[l, t] ≤ ATC_UP[l, t]
```

# Flow Convention
- Positive flow: source zone → sink zone
- Negative flow: sink zone → source zone
- ATC_UP: limit in line direction (positive flows)
- ATC_DOWN: limit in reverse direction (negative flows, stored as negative values)

# Examples
From documentation Section 4.3.1:
- Line A→C with ATC_UP=250, ATC_DOWN=-300: flow ∈ [-300, 250]
- Negative ATC forces flow direction (e.g., ATC_UP=-250: flow ∈ [-300, -250])
"""
function add_atc_constraints!(model::Model, network::NetworkTopology, FLOW)
    lines = network.lines
    time_periods = network.time_periods
    ATC_UP = network.ATC_UP
    ATC_DOWN = network.ATC_DOWN

    # ATC Constraints (Section 4.3.1)
    # For each line l and time period t, flow must be within ATC limits
    @constraint(model, atc_constraints[l in lines, t in time_periods],
        ATC_DOWN[l, t] <= FLOW[l, t] <= ATC_UP[l, t]
    )

    return model
end

# =============================================================================
# TRANSFER CAPACITY APPROACH (Zone-based modeling) - RECOMMENDED FOR ENTSO-E
# =============================================================================

"""
Transfer capacity data structure for market clearing between bidding zones.
This represents the available transfer capacity between bidding zones without 
needing to model individual transmission lines.
"""
struct TransferCapacity
    bidding_zones::Vector{String}                   # All bidding zones in the system
    time_periods::Vector{String}                    # Time period identifiers
    # Positive capacity: from source_zone → sink_zone
    capacity_forward::Dict{Tuple{String,String,String},Float64}  # [source, sink, period] → MW
    # Negative capacity: from sink_zone → source_zone (stored as positive values)
    capacity_backward::Dict{Tuple{String,String,String},Float64} # [source, sink, period] → MW
end

"""
    add_transfer_capacity_constraints!(model::Model, transfer_capacity::TransferCapacity, FLOW)

Adds transfer capacity constraints to a JuMP model for bidding zone transfers.

# Arguments
- `model::Model`: JuMP optimization model
- `transfer_capacity::TransferCapacity`: Transfer capacity data between bidding zones
- `FLOW`: JuMP variable array for flows between zones [source_zone, sink_zone, time_period]

# Constraints Added
For each bidding zone pair (source, sink) and time period t:
```
-capacity_backward[source, sink, t] ≤ FLOW[source, sink, t] ≤ capacity_forward[source, sink, t]
```

# Flow Convention
- Positive FLOW[source, sink, t]: transfer from source → sink
- Negative FLOW[source, sink, t]: transfer from sink → source
- capacity_forward: maximum transfer source → sink
- capacity_backward: maximum transfer sink → source (stored as positive)
"""
function add_transfer_capacity_constraints!(model::Model, transfer_capacity::TransferCapacity, FLOW)
    zones = transfer_capacity.bidding_zones
    time_periods = transfer_capacity.time_periods
    capacity_forward = transfer_capacity.capacity_forward
    capacity_backward = transfer_capacity.capacity_backward

    # Transfer capacity constraints for all zone pairs
    @constraint(model, transfer_capacity_constraints[source in zones, sink in zones, t in time_periods; source != sink],
        -get(capacity_backward, (source, sink, t), 0.0) <= FLOW[source, sink, t] <= get(capacity_forward, (source, sink, t), 0.0)
    )

    return model
end

"""
    create_example_transfer_capacity()

Creates an example TransferCapacity structure for testing.
Based on the same bidding zones as the example network.
"""
function create_example_transfer_capacity()
    zones = ["A", "C", "H", "J"]
    periods = ["1", "2", "3"]

    capacity_forward = Dict{Tuple{String,String,String},Float64}()
    capacity_backward = Dict{Tuple{String,String,String},Float64}()

    # A ↔ C interconnection
    for period in periods
        capacity_forward[("A", "C", period)] = 250.0   # A → C
        capacity_backward[("A", "C", period)] = 300.0  # C → A
    end

    # H ↔ C interconnection  
    for period in periods
        capacity_forward[("H", "C", period)] = 600.0   # H → C
        capacity_backward[("H", "C", period)] = 500.0  # C → H
    end

    # H ↔ J interconnection
    for period in periods
        capacity_forward[("H", "J", period)] = 1600.0  # H → J
        capacity_backward[("H", "J", period)] = 900.0  # J → H
    end

    return TransferCapacity(zones, periods, capacity_forward, capacity_backward)
end

# =============================================================================
# ENTSO-E DATA INTEGRATION (Both approaches support real data)
# =============================================================================

"""
    create_transfer_capacity_from_entsoe(date::Date, bidding_zones::Vector{String}=String[])

Creates a TransferCapacity structure using real ENTSO-E data.
More suitable for market clearing applications than NetworkTopology.

# Arguments
- `date::Date`: The date for which to retrieve transfer capacities
- `bidding_zones::Vector{String}`: Optional filter for specific bidding zones (empty = all zones)

# Returns
- `TransferCapacity`: Transfer capacity data between bidding zones
"""
function create_transfer_capacity_from_entsoe(date::Date, bidding_zones::Vector{String}=String[];
    include_explicit::Bool=false,
    aggregate_remap::AbstractDict=Dict{String,String}(),
    drop_borders::Vector{Tuple{String,String}}=Tuple{String,String}[])

    # ENRICHED PATH (opt-in): union the explicit (LT+DA-auction) ATC table,
    # remap aggregate-country borders onto a representative sub-zone, and drop
    # specific borders whose published ATC is a stale residual (flow-based
    # regions). Kept strictly behind these keyword flags so the default call —
    # used by the 5-zone SEE product — takes the original implicit-only path
    # below and is byte-identical.
    if include_explicit || !isempty(aggregate_remap) || !isempty(drop_borders)
        return _create_transfer_capacity_enriched(date, bidding_zones;
            include_explicit=include_explicit, aggregate_remap=aggregate_remap,
            drop_borders=drop_borders)
    end

    # Build SQL query to get transfer capacities for the specified date
    # Use out_map_code/in_map_code for short zone codes (e.g., "GR") instead of EIC codes
    zone_filter = isempty(bidding_zones) ? "" :
                  "AND (out_map_code IN ('" * join(bidding_zones, "','") * "') OR in_map_code IN ('" * join(bidding_zones, "','") * "'))"

    # cv22 bug-fix (gated by EUPHEMIA_DISABLE_CV22): when the implicit table
    # carries MULTIPLE capacity rows for the same border-hour (sub-hourly or
    # duplicate sequences), the raw SELECT + `build_transfer_capacity_from_dataframe`
    # kept whichever row sorted LAST by date_time_utc — order-dependent and
    # non-deterministic. Aggregate to one hourly AVG per (source, sink, hour),
    # matching the enriched path's `_fetch_atc_aggregated`. This deliberately
    # ENDS the SEE 5-zone byte-identity chain (unbroken since cv10); the delta is
    # tiny/zero on days without duplicate rows (see docs/experiments/cv22.md).
    # NOTE: the cv26 Day-ahead preference (EUPHEMIA_DISABLE_ATC_DAPREF) only
    # exists in this aggregated branch — under EUPHEMIA_DISABLE_CV22 the raw
    # last-row-wins query below ignores it, so an A/B arm combining the two
    # switches does not isolate DAPREF on this legacy path.
    if isempty(get(ENV, "EUPHEMIA_DISABLE_CV22", ""))
        query = """
        SELECT out_map_code AS source_zone,
               in_map_code AS sink_zone,
               (EXTRACT(HOUR FROM date_time_utc) + 1)::int AS time_period,
               $(isempty(get(ENV, "EUPHEMIA_DISABLE_ATC_DAPREF", "")) ?
                 "COALESCE(AVG(capacity_mw) FILTER (WHERE contract_type = 'Day-ahead'), AVG(capacity_mw))" :
                 "AVG(capacity_mw)")::float8 AS capacity
        FROM entsoe.offered_transfer_capacities_implicit
        WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
              AND capacity_mw IS NOT NULL
        $zone_filter
        GROUP BY out_map_code, in_map_code, (EXTRACT(HOUR FROM date_time_utc) + 1)::int
        """
    else
        query = """
        SELECT
            out_map_code as source_zone,
            in_map_code as sink_zone,
            EXTRACT(HOUR FROM date_time_utc) + 1 as time_period,
            capacity_mw as capacity
        FROM entsoe.offered_transfer_capacities_implicit
        WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
        $zone_filter
        ORDER BY out_map_code, in_map_code, date_time_utc
        """
    end

    println("📊 Fetching ENTSO-E transfer capacity data for $date...")
    df = safe_sql2df(query, [date])

    if nrow(df) == 0
        zones_str = isempty(bidding_zones) ? "all zones" : join(bidding_zones, ", ")
        error("No ENTSO-E transfer capacity data found for $date (zones: $zones_str). " *
              "Check that data exists in entsoe.offered_transfer_capacities_implicit table.")
    end

    println("✅ Found $(nrow(df)) transfer capacity records")
    return build_transfer_capacity_from_dataframe(df)
end

"""
    _fetch_atc_aggregated(date, table, codes; contract_type=nothing) -> DataFrame

Fetch directional ATC from an ENTSO-E offered-transfer-capacity table,
averaged per (out_map_code, in_map_code, hour). Averaging collapses
sub-hourly rows and duplicate sequences to one value per border-hour. When
`contract_type` is given (used for the explicit table) only that auction
horizon is kept — `'Day-ahead'` isolates the day-ahead offered capacity,
excluding already-allocated long-term (year/month-ahead) products that would
otherwise double-count.
"""
function _fetch_atc_aggregated(date::Date, table::String, codes::Vector{String};
    contract_type::Union{String,Nothing}=nothing)
    ct_filter = contract_type === nothing ? "" : "AND contract_type = \$3"
    params = contract_type === nothing ? Any[date, codes] : Any[date, codes, contract_type]
    # Day-ahead preference (2026-07 EE diagnosis): the implicit table mixes
    # Intraday rows (often 0, and the ONLY rows on FBMC borders since late
    # 2024) with the Day-ahead offered capacity. Per border-hour, use the
    # Day-ahead average when Day-ahead rows exist; otherwise keep the
    # all-rows average (FBMC borders keep today's behaviour until their
    # capacity source is redesigned). Killable for A/Bs.
    cap_expr = contract_type === nothing && isempty(get(ENV, "EUPHEMIA_DISABLE_ATC_DAPREF", "")) ?
        "COALESCE(AVG(capacity_mw) FILTER (WHERE contract_type = 'Day-ahead'), AVG(capacity_mw))" :
        "AVG(capacity_mw)"
    query = """
    SELECT out_map_code AS source_zone,
           in_map_code AS sink_zone,
           (EXTRACT(HOUR FROM date_time_utc) + 1)::int AS time_period,
           $cap_expr::float8 AS capacity,
           (COUNT(*) FILTER (WHERE contract_type = 'Day-ahead'))::int AS n_da
    FROM entsoe.$table
    WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
      AND (out_map_code = ANY(\$2) OR in_map_code = ANY(\$2))
      AND capacity_mw IS NOT NULL
      $ct_filter
    GROUP BY out_map_code, in_map_code, (EXTRACT(HOUR FROM date_time_utc) + 1)::int
    """
    return safe_sql2df(query, params)
end

# cv27 T1 (docs/cv27-import-hydro-prereg.md): demonstrated interconnector
# capability for Day-ahead-free (FBMC) borders — trailing-366d p95 of observed
# gross flow per 4h block, the cv21/cv22 boundary-book recipe generalized.
# Computed ONCE per delivery day for ALL borders (one grouped scan of
# physical_flows) and cached, day-level, like the outage cache. Never cached
# on error.
# The 7 physical borders accepted by the cv27 border campaign
# (docs/experiments/cv27-borders/, Set A -0.44 MAE/+0.009 corr, Set B
# -0.41/-0.004, zero caps/breaches; both directions each).
const CV27_SHIPPED_BORDERS = join([
    "DE_LU>FR", "FR>DE_LU", "CH>FR", "FR>CH", "CZ>PL", "PL>CZ",
    "SE1>SE2", "SE2>SE1", "IT-CNORTH>IT-NORTH", "IT-NORTH>IT-CNORTH",
    "DK1>SE3", "SE3>DK1", "IT-Calabria>IT-Sicily", "IT-Sicily>IT-Calabria"], ",")

const _FBMC_CAP_DAY_CACHE = Dict{Date,Dict{Tuple{String,String,Int},Float64}}()
const _FBMC_CAP_LOCK = ReentrantLock()

# T1b scoping (declared post-Set-A amendment, disclosed in the results): the
# demonstrated capability applies ONLY to borders that HAD Day-ahead offered
# rows at some point before the delivery day and have none on it — capacity
# CONTINUITY where the DA product disappeared (the Nordic post-FBMC case).
# Borders that never published DA rows in our history (Core FBMC since 2022)
# keep the calibrated intraday-blend behaviour; measured Set A showed re-basing
# them breaches DE_LU/AT. Strictly ex-ante (only pre-delivery history).
const _DA_EVER_CACHE = Dict{Date,Set{Tuple{String,String}}}()

function _da_ever_borders(date::Date)
    lock(_FBMC_CAP_LOCK) do
        haskey(_DA_EVER_CACHE, date) && return _DA_EVER_CACHE[date]
        df = safe_sql2df("""
            SELECT DISTINCT out_map_code AS s, in_map_code AS k
            FROM entsoe.offered_transfer_capacities_implicit
            WHERE contract_type = 'Day-ahead'
              AND date_time_utc < (\$1::date::timestamp AT TIME ZONE 'UTC')
            """, Any[date])
        st = Set{Tuple{String,String}}((String(r.s), String(r.k)) for r in eachrow(df))
        _DA_EVER_CACHE[date] = st
        return st
    end
end

function _fbmc_capability(date::Date)
    lock(_FBMC_CAP_LOCK) do
        haskey(_FBMC_CAP_DAY_CACHE, date) && return _FBMC_CAP_DAY_CACHE[date]
        df = safe_sql2df("""
            SELECT out_area_map_code AS s, in_area_map_code AS k,
                   FLOOR(EXTRACT(HOUR FROM date_time_utc) / 4)::int AS blk,
                   percentile_cont(0.95) WITHIN GROUP (ORDER BY flow_mw) AS cap
            FROM entsoe.physical_flows
            WHERE date_time_utc >= ((\$1::date - 366)::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$1::date::timestamp AT TIME ZONE 'UTC')
              AND flow_mw IS NOT NULL AND flow_mw > 0
            GROUP BY 1, 2, 3
            """, Any[date])
        cap = Dict{Tuple{String,String,Int},Float64}()
        for r in eachrow(df)
            (ismissing(r.cap) || ismissing(r.s) || ismissing(r.k)) && continue
            cap[(String(r.s), String(r.k), Int(r.blk))] = Float64(r.cap)
        end
        _FBMC_CAP_DAY_CACHE[date] = cap
        return cap
    end
end

"Clear the cv27 demonstrated-capability day cache (tests / long processes)."
clear_fbmc_capability_cache!() = (lock(_FBMC_CAP_LOCK) do; empty!(_FBMC_CAP_DAY_CACHE); end; nothing)

"""
    _subzones_of(aggregate, footprint) -> Vector{String}

Footprint nodes that are bidding-zone sub-nodes of an aggregate country code,
identified by the `AGG-` or `AGG_` code prefix (e.g. aggregate `IT` →
`IT-NORTH`, `IT-SOUTH`, …; aggregate `DE` → `DE_LU`).
"""
function _subzones_of(aggregate::String, footprint)
    return [z for z in footprint
            if z != aggregate &&
               (startswith(z, aggregate * "-") || startswith(z, aggregate * "_"))]
end

"""
    _create_transfer_capacity_enriched(date, bidding_zones; include_explicit, aggregate_remap)

Enriched transfer-capacity build (opt-in via `create_transfer_capacity_from_entsoe`).

Two extensions over the implicit-only default:

1. **Explicit union.** When `include_explicit`, the day-ahead offered capacity
   from `offered_transfer_capacities_explicit` is unioned in for directed
   borders the implicit table does not cover (implicit is preferred where a
   border exists in both). This restores borders that clear via explicit
   auctions rather than SDAC implicit coupling — notably every Swiss border
   (CH is outside implicit coupling) and Serbia's borders.

2. **Aggregate → sub-zone remap.** Some countries file their *external*
   borders only under an aggregate control-area code (e.g. Italy's
   continental borders IT–FR/AT/SI/CH sit under `IT`, whose sub-zones are the
   real bidding nodes). For each `aggregate => representative` entry, an
   aggregate border `aggregate ↔ X` is rewritten to `representative ↔ X` —
   *unless* `X` already borders one of the aggregate's sub-zones directly
   (e.g. GR↔IT is physically GR↔IT-SOUTH and already present as a sub-zone
   border), which prevents a phantom line to the representative.
"""
function _create_transfer_capacity_enriched(date::Date, bidding_zones::Vector{String};
    include_explicit::Bool=false,
    aggregate_remap::AbstractDict=Dict{String,String}(),
    drop_borders::Vector{Tuple{String,String}}=Tuple{String,String}[])

    isempty(bidding_zones) &&
        error("Enriched transfer-capacity build requires an explicit footprint (bidding_zones)")

    fpset = Set(bidding_zones)
    codes = collect(union(fpset, Set(keys(aggregate_remap))))

    println("📊 Fetching ENTSO-E transfer capacity (enriched: explicit=$include_explicit, " *
            "remap=$(isempty(aggregate_remap) ? "none" : join(["$a→$s" for (a,s) in aggregate_remap], ","))) for $date...")

    imp = _fetch_atc_aggregated(date, "offered_transfer_capacities_implicit", codes)
    nrow(imp) == 0 && include_explicit == false &&
        error("No implicit transfer capacity data for $date (footprint: $(join(bidding_zones, ", ")))")

    # Directed borders already covered by implicit — explicit only fills gaps.
    imp_pairs = Set{Tuple{String,String}}(
        (r.source_zone, r.sink_zone) for r in eachrow(imp))

    # cv27 T1: a border-hour with NO Day-ahead rows (n_da == 0 — the FBMC
    # borders since late 2024) sizes by demonstrated capability instead of the
    # intraday-blend fallback. Borders WITH Day-ahead rows are untouched by
    # construction (the falsifier the prereg names).
    cv27_t1 = isempty(get(ENV, "EUPHEMIA_DISABLE_CV27", "")) &&
              isempty(get(ENV, "EUPHEMIA_DISABLE_CV27_T1", ""))
    # cv27-borders (Phase 0): per-border scoping of the T1 override.
    # When EUPHEMIA_CV27_T1_BORDERS is PRESENT in the environment it selects the
    # border-list mode: the demonstrated-capability override applies ONLY to the
    # listed directed borders (comma-separated "A>B,B>A,..."), regardless of
    # da_ever — both physical directions are symmetrized in code as a safety.
    # An empty value = no borders = treatment OFF. When the var is ABSENT the
    # legacy T1b behaviour (override every n_da==0 border in da_ever) is
    # unchanged, so the existing guards stay bit-identical.
    # cv27 SHIP (2026-07-31, owner decision on the border campaign's Set A/B):
    # the accepted 7-border set is the DEFAULT. The env var still overrides for
    # A/Bs (present-and-empty = treatment OFF); the campaign's measured combo
    # arm is bit-identical to this default (ship guard).
    border_list_mode = true
    border_env = get(ENV, "EUPHEMIA_CV27_T1_BORDERS", CV27_SHIPPED_BORDERS)
    border_set = Set{Tuple{String,String}}()
    if border_list_mode
        for tok in split(border_env, ',')
            t = strip(tok); isempty(t) && continue
            parts = split(t, '>')
            length(parts) == 2 || error("bad EUPHEMIA_CV27_T1_BORDERS token: $t")
            a = String(strip(parts[1])); b = String(strip(parts[2]))
            push!(border_set, (a, b)); push!(border_set, (b, a))  # both directions
        end
    end
    fbmc_cap = (cv27_t1 && "n_da" in names(imp) && any(imp.n_da .== 0) &&
                (!border_list_mode || !isempty(border_set))) ?
        _fbmc_capability(date) : nothing
    da_ever = (fbmc_cap === nothing || border_list_mode) ?
        Set{Tuple{String,String}}() : _da_ever_borders(date)
    n_fbmc_override = 0
    rows = NamedTuple{(:source_zone, :sink_zone, :time_period, :capacity),
                      Tuple{String,String,Int,Float64}}[]
    for r in eachrow(imp)
        capacity = Float64(r.capacity)
        pair = (String(r.source_zone), String(r.sink_zone))
        eligible = border_list_mode ? (pair in border_set) : (pair in da_ever)
        if fbmc_cap !== nothing && Int(r.n_da) == 0 && eligible
            blk = (Int(r.time_period) - 1) ÷ 4
            demo = get(fbmc_cap, (String(r.source_zone), String(r.sink_zone), blk), 0.0)
            demo > 0.0 && (capacity = demo; n_fbmc_override += 1)
        end
        push!(rows, (source_zone=r.source_zone, sink_zone=r.sink_zone,
                     time_period=Int(r.time_period), capacity=capacity))
    end
    n_fbmc_override > 0 &&
        println("   🔁 cv27 T1: $(n_fbmc_override) Day-ahead-free border-hours sized by demonstrated capability")
    n_explicit_added = 0
    if include_explicit
        exp = _fetch_atc_aggregated(date, "offered_transfer_capacities_explicit", codes;
                                    contract_type="Day-ahead")
        for r in eachrow(exp)
            (r.source_zone, r.sink_zone) in imp_pairs && continue
            push!(rows, (source_zone=r.source_zone, sink_zone=r.sink_zone,
                         time_period=Int(r.time_period), capacity=Float64(r.capacity)))
            n_explicit_added += 1
        end
    end

    # Apply aggregate → sub-zone remap. Precompute, per aggregate, the set of
    # counterparties that already border one of its sub-zones directly (those
    # aggregate borders are physically the sub-zone border and must be dropped
    # rather than remapped, to avoid a phantom line to the representative).
    remap_direct = Dict{String,Set{String}}()
    for (agg, _) in aggregate_remap
        subz = Set(_subzones_of(agg, bidding_zones))
        direct = Set{String}()
        for row in rows
            if row.source_zone in subz && row.sink_zone in fpset &&
               !(row.sink_zone in subz) && row.sink_zone != agg
                push!(direct, row.sink_zone)
            end
            if row.sink_zone in subz && row.source_zone in fpset &&
               !(row.source_zone in subz) && row.source_zone != agg
                push!(direct, row.source_zone)
            end
        end
        remap_direct[agg] = direct
    end

    final = NamedTuple{(:source_zone, :sink_zone, :time_period, :capacity),
                       Tuple{String,String,Int,Float64}}[]
    n_remapped = 0
    for row in rows
        s, d = row.source_zone, row.sink_zone
        # Decide, for any aggregate endpoint, whether to drop (double-counted
        # by a sub-zone border, or counterparty outside footprint) or remap.
        drop = false
        if haskey(aggregate_remap, s)
            X = d
            if X in get(remap_direct, s, Set{String}()) || !(X in fpset)
                drop = true
            else
                s = String(aggregate_remap[s]); n_remapped += 1
            end
        end
        if !drop && haskey(aggregate_remap, d)
            X = row.source_zone
            if X in get(remap_direct, d, Set{String}()) || !(X in fpset)
                drop = true
            else
                d = String(aggregate_remap[d]); n_remapped += 1
            end
        end
        drop && continue
        # Keep only borders fully inside the footprint; drop self-loops.
        (s in fpset && d in fpset && s != d) || continue
        push!(final, (source_zone=s, sink_zone=d,
                      time_period=row.time_period, capacity=row.capacity))
    end

    # Drop specific borders whose published ATC is a stale residual of a
    # flow-based capacity-calculation region (Nordic CCR, flow-based DA since
    # Oct 2024) and therefore cannot carry the real flows (audited 2026-04:
    # SE3→NO1 published as 0 MW, SE1→FI as 4 MW, NO2→NO1 as ~733 MW vs a
    # ~3,500 MW physical border). Keeping such a border endogenous starves
    # import-dependent zones (NO1, FI) into phantom scarcity. With the border
    # dropped entirely (both directions), the multi-zone book falls back to
    # observed net imports for it — the same honest treatment as other borders
    # the ATC data cannot reproduce (RS, HU–RO). The drop set is chosen by the
    # caller; borders not listed (including other Nordic-internal ones and the
    # NTC DC links to the continent) stay endogenous.
    n_fb_dropped = 0
    if !isempty(drop_borders)
        dropset = Set{Tuple{String,String}}()
        for (a, b) in drop_borders
            push!(dropset, (a, b)); push!(dropset, (b, a))
        end
        before = length(final)
        final = [row for row in final if !((row.source_zone, row.sink_zone) in dropset)]
        n_fb_dropped = before - length(final)
    end

    isempty(final) &&
        error("Enriched transfer capacity produced no in-footprint borders for $date")

    df = DataFrame(final)
    println("✅ Enriched transfer capacity: $(nrow(imp)) implicit rows, " *
            "+$n_explicit_added explicit-only rows, $n_remapped aggregate endpoints remapped, " *
            "-$n_fb_dropped stale flow-based border-hours dropped, " *
            "$(nrow(df)) in-footprint border-hours")
    return build_transfer_capacity_from_dataframe(df)
end

"""
    build_transfer_capacity_from_dataframe(df::DataFrame)

Converts ENTSO-E transfer capacity DataFrame into TransferCapacity structure.

ENTSO-E data provides directional capacities, so:
- A→B record with capacity X means forward capacity from A to B is X
- B→A record with capacity Y means forward capacity from B to A is Y

For the flow variable flow[A,B,t]:
- Positive flow: A→B direction, bounded by capacity_forward[(A,B,t)]
- Negative flow: B→A direction, bounded by capacity_backward[(A,B,t)] = capacity_forward[(B,A,t)]
"""
function build_transfer_capacity_from_dataframe(df::DataFrame)
    zones = Set{String}()
    time_periods = Set{String}()
    capacity_forward = Dict{Tuple{String,String,String},Float64}()

    # First pass: collect all forward capacities from the data
    for row in eachrow(df)
        source = row.source_zone
        sink = row.sink_zone
        period = string(Int(row.time_period))
        capacity = row.capacity

        # Collect unique zones and time periods
        push!(zones, source, sink)
        push!(time_periods, period)

        # Store forward capacity (source → sink)
        capacity_forward[(source, sink, period)] = capacity
    end

    # Convert to sorted vectors
    zones_vec = sort(collect(zones))
    periods_vec = sort(collect(time_periods), by=x -> parse(Int, x))

    # Second pass: compute backward capacities
    # For flow[A,B,t], backward capacity = forward capacity of reverse direction (B→A)
    capacity_backward = Dict{Tuple{String,String,String},Float64}()

    for (source, sink, period) in keys(capacity_forward)
        # Backward capacity for (A,B) = forward capacity for (B,A)
        reverse_key = (sink, source, period)
        if haskey(capacity_forward, reverse_key)
            capacity_backward[(source, sink, period)] = capacity_forward[reverse_key]
        else
            # No reverse direction data - assume 0 (unidirectional link)
            capacity_backward[(source, sink, period)] = 0.0
        end
    end

    # Count bidirectional links
    bidirectional_count = count(v -> v > 0, values(capacity_backward))
    unidirectional_count = length(capacity_forward) - bidirectional_count

    println("✅ Created transfer capacity structure:")
    println("   🌍 Bidding zones: $(length(zones_vec)) ($(join(zones_vec, ", ")))")
    println("   🕐 Time periods: $(length(periods_vec))")
    println("   ➡️  Forward capacities: $(length(capacity_forward)) entries")
    println("   ↔️  Bidirectional links: $bidirectional_count")
    println("   ➡️  Unidirectional links: $unidirectional_count")

    return TransferCapacity(
        zones_vec,
        periods_vec,
        capacity_forward,
        capacity_backward
    )
end

"""
    create_greek_transfer_capacity_from_entsoe(date::Date)

Creates a TransferCapacity focused on Greek (GR) interconnections using real ENTSO-E data.
Includes connections to neighboring countries (BG, IT, AL, MK, TR).
"""
function create_greek_transfer_capacity_from_entsoe(date::Date)
    # Greek neighboring zones based on typical interconnections
    greek_zones = ["GR", "BG", "IT", "AL", "MK", "TR"]
    return create_transfer_capacity_from_entsoe(date, greek_zones)
end

"""
    get_entsoe_transfer_capacities(date::Date, source_zone::String, sink_zone::String)

Retrieves specific transfer capacity data for a bidding zone pair on a given date.

# Returns
- `DataFrame`: Hourly transfer capacities with columns: hour, capacity_forward, capacity_backward
"""
function get_entsoe_transfer_capacities(date::Date, source_zone::String, sink_zone::String)
    try
        query = """
        SELECT 
            EXTRACT(HOUR FROM date_time_utc) + 1 as hour,
            capacity_mw as capacity_forward,
            0.0 as capacity_backward
        FROM entsoe.offered_transfer_capacities_implicit 
        WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
          AND out_area_code = \$2
          AND in_area_code = \$3
        ORDER BY hour
        """

        return safe_sql2df(query, [date, source_zone, sink_zone])
    catch e
        @error "Failed to fetch transfer capacity data for $source_zone → $sink_zone on $date: $e"
        return DataFrame(hour=Int[], capacity_forward=Float64[], capacity_backward=Float64[])
    end
end

# =============================================================================
# COMMON UTILITY FUNCTIONS
# =============================================================================

"""
    get_bidding_zones(network::NetworkTopology)

Returns the set of all bidding zones in the network topology.
"""
function get_bidding_zones(network::NetworkTopology)
    zones = Set{String}()
    for zone in values(network.source_zone)
        push!(zones, zone)
    end
    for zone in values(network.sink_zone)
        push!(zones, zone)
    end
    return collect(zones)
end

"""
    get_bidding_zones(transfer_capacity::TransferCapacity)

Returns the set of all bidding zones in the transfer capacity structure.
"""
function get_bidding_zones(transfer_capacity::TransferCapacity)
    return transfer_capacity.bidding_zones
end

"""
    get_outgoing_lines(network::NetworkTopology, zone::String)

Returns lines originating from the specified bidding zone.
"""
function get_outgoing_lines(network::NetworkTopology, zone::String)
    return [line for (line, source) in network.source_zone if source == zone]
end

"""
    get_incoming_lines(network::NetworkTopology, zone::String)

Returns lines terminating at the specified bidding zone.
"""
function get_incoming_lines(network::NetworkTopology, zone::String)
    return [line for (line, sink) in network.sink_zone if sink == zone]
end

# =============================================================================
# MULTI-ZONE SUPPORT FUNCTIONS
# =============================================================================

"""
    get_zones_with_transfer_capacity(date::Date)

Discovers bidding zones that have cross-border transfer capacity data for a given date.
These are zones connected by transmission links in the ENTSO-E data.

Note: This is different from `get_available_zones()` which finds zones with generators.
For multi-zone market clearing, you need zones that have BOTH generators AND transfer capacity.

# Arguments
- `date::Date`: The date for which to discover interconnected zones

# Returns
- `Vector{String}`: Sorted list of zone codes with transfer capacity data
"""
function get_zones_with_transfer_capacity(date::Date)
    try
        # Use out_map_code/in_map_code for short zone codes (e.g., "GR") instead of EIC codes
        query = """
        SELECT DISTINCT zone_code FROM (
            SELECT out_map_code as zone_code FROM entsoe.offered_transfer_capacities_implicit
            WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
            UNION
            SELECT in_map_code as zone_code FROM entsoe.offered_transfer_capacities_implicit
            WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
        ) AS zones
        ORDER BY zone_code
        """

        df = safe_sql2df(query, [date])

        if nrow(df) == 0
            @warn "No transfer capacity data found for $date - no zones discovered"
            return String[]
        end

        zones = String.(df.zone_code)
        println("🌍 Discovered $(length(zones)) bidding zones from ENTSO-E data: $(join(zones, ", "))")
        return zones

    catch e
        @error "Failed to discover zones from ENTSO-E data: $e"
        return String[]
    end
end

"""
    get_connected_zones(transfer_capacity::TransferCapacity, zone::String)

Returns zones connected to the specified zone via transfer capacity.

# Returns
- Tuple of two vectors: (zones_with_flow_to_this_zone, zones_with_flow_from_this_zone)
  - zones_with_flow_to: zones that can send power TO the specified zone
  - zones_with_flow_from: zones that can receive power FROM the specified zone
"""
function get_connected_zones(transfer_capacity::TransferCapacity, zone::String)
    zones_with_flow_to = String[]   # Zones that can send TO this zone
    zones_with_flow_from = String[] # Zones that can receive FROM this zone

    # Get a sample period to check connectivity
    sample_period = isempty(transfer_capacity.time_periods) ? "1" : first(transfer_capacity.time_periods)

    for other_zone in transfer_capacity.bidding_zones
        if other_zone == zone
            continue
        end

        # Check if other_zone can send TO this zone (other_zone → zone)
        if haskey(transfer_capacity.capacity_forward, (other_zone, zone, sample_period)) ||
           haskey(transfer_capacity.capacity_backward, (zone, other_zone, sample_period))
            push!(zones_with_flow_to, other_zone)
        end

        # Check if this zone can send TO other_zone (zone → other_zone)
        if haskey(transfer_capacity.capacity_forward, (zone, other_zone, sample_period)) ||
           haskey(transfer_capacity.capacity_backward, (other_zone, zone, sample_period))
            push!(zones_with_flow_from, other_zone)
        end
    end

    return (zones_with_flow_to, zones_with_flow_from)
end

"""
    get_zone_pairs(transfer_capacity::TransferCapacity)

Returns the physical borders that have transfer capacity defined, ONE ORIENTED
PAIR PER UNORDERED BORDER. Each pair is represented as a (source_zone,
sink_zone) tuple defining the positive-flow direction of that border's single
flow variable, with the `± ` bound semantics of
`build_transfer_capacity_from_dataframe`:

    flow[(A,B),t] ∈ [-capacity_backward[(A,B,t)], +capacity_forward[(A,B,t)]]

where `capacity_backward[(A,B,t)] == capacity_forward[(B,A,t)]`.

**Canonicalisation (bug fix).** ENTSO-E publishes one ATC row per DIRECTION, so
a normally-coupled border yields BOTH `(A,B)` and `(B,A)` keys in
`capacity_forward`. Returning both made the MPCC solver create two INDEPENDENT
full-range flow variables for the same physical line, with nothing linking
them: zone A's nodal balance carries `+flow[(A,B)] - flow[(B,A)]`, so the net
transfer ranged over ±2× the offered ATC — and on a congested border the two
congestion-rent conditions force exactly 2×. We therefore keep exactly one
orientation per unordered border: `(s,d)` with `s < d` when both directions are
published, otherwise whichever single orientation exists (a genuinely
unidirectional link).

# Returns
- `Vector{Tuple{String,String}}`: one oriented pair per physical border
"""
function get_zone_pairs(transfer_capacity::TransferCapacity)
    directed = Set{Tuple{String,String}}()

    for key in keys(transfer_capacity.capacity_forward)
        source, sink, _ = key
        push!(directed, (source, sink))
    end

    # Kill-switch for A/B measurement: restores the pre-fix behaviour in which
    # each published DIRECTION became its own independent flow variable.
    !isempty(get(ENV, "EUPHEMIA_DISABLE_ATC_CANON", "")) &&
        return collect(directed)

    pairs = Set{Tuple{String,String}}()
    for (source, sink) in directed
        if source < sink || !((sink, source) in directed)
            push!(pairs, (source, sink))
        end
    end

    return collect(pairs)
end

# =============================================================================
# LEGACY SUPPORT FOR PHYSICAL NETWORK APPROACH
# =============================================================================

"""
    create_network_from_entsoe(date::Date, bidding_zones::Vector{String}=String[])

Creates a NetworkTopology using real ENTSO-E transfer capacity data from the database.
Note: This approach is less suitable for ENTSO-E data than TransferCapacity.
"""
function create_network_from_entsoe(date::Date, bidding_zones::Vector{String}=String[])
    try
        # Build SQL query to get transfer capacities for the specified date
        zone_filter = isempty(bidding_zones) ? "" :
                      "AND (out_area_code IN ('" * join(bidding_zones, "','") * "') OR in_area_code IN ('" * join(bidding_zones, "','") * "'))"

        query = """
        SELECT 
            out_area_code as source_zone,
            in_area_code as sink_zone,
            EXTRACT(HOUR FROM date_time_utc) + 1 as time_period,
            capacity_mw as capacity
        FROM entsoe.offered_transfer_capacities_implicit 
        WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
        $zone_filter
        ORDER BY out_area_code, in_area_code, date_time_utc
        """

        println("📊 Fetching ENTSO-E transfer capacity data for $date...")
        df = safe_sql2df(query, [date])

        if nrow(df) == 0
            @warn "No ENTSO-E transfer capacity data found for $date"
            return create_example_network()  # Fallback to example
        end

        println("✅ Found $(nrow(df)) transfer capacity records")
        return build_network_from_dataframe(df)

    catch e
        @error "Failed to fetch ENTSO-E transfer capacity data: $e"
        @warn "Falling back to example network"
        return create_example_network()
    end
end

"""
    build_network_from_dataframe(df::DataFrame)

Converts ENTSO-E transfer capacity DataFrame into NetworkTopology structure.
"""
function build_network_from_dataframe(df::DataFrame)
    # Extract unique bidding zone pairs and time periods
    lines = String[]
    time_periods = String[]
    ATC_UP = Dict{Tuple{String,String},Float64}()
    ATC_DOWN = Dict{Tuple{String,String},Float64}()
    source_zone = Dict{String,String}()
    sink_zone = Dict{String,String}()

    for row in eachrow(df)
        source = row.source_zone
        sink = row.sink_zone
        period = string(Int(row.time_period))
        capacity = row.capacity

        # Create line identifier
        line_id = "$(source)_to_$(sink)"

        # Add to collections if not already present
        if !(line_id in lines)
            push!(lines, line_id)
            source_zone[line_id] = source
            sink_zone[line_id] = sink
        end

        if !(period in time_periods)
            push!(time_periods, period)
        end

        # Since ENTSO-E data represents directional capacity (source→sink),
        # we store it as ATC_UP (positive direction) and set ATC_DOWN to 0
        # For bidirectional capacity, there would be separate records for each direction
        ATC_UP[(line_id, period)] = capacity
        ATC_DOWN[(line_id, period)] = 0.0  # No reverse capacity unless explicitly defined
    end

    # Fill missing values with zero capacity
    for line in lines, period in time_periods
        if !haskey(ATC_UP, (line, period))
            ATC_UP[(line, period)] = 0.0
        end
        if !haskey(ATC_DOWN, (line, period))
            ATC_DOWN[(line, period)] = 0.0
        end
    end

    # Sort time periods numerically
    time_periods = sort(time_periods, by=x -> parse(Int, x))

    println("✅ Created network topology:")
    println("   📊 Lines: $(length(lines))")
    println("   🕐 Time periods: $(length(time_periods))")
    println("   🔌 ATC_UP entries: $(count(v -> v > 0, values(ATC_UP)))")
    println("   🔌 ATC_DOWN entries: $(count(v -> v < 0, values(ATC_DOWN)))")

    return NetworkTopology(
        lines,
        time_periods,
        ATC_UP,
        ATC_DOWN,
        source_zone,
        sink_zone
    )
end

"""
    create_greek_network_from_entsoe(date::Date)

Creates a NetworkTopology focused on Greek (GR) interconnections using real ENTSO-E data.
Includes connections to neighboring countries (BG, IT, AL, MK, TR).
"""
function create_greek_network_from_entsoe(date::Date)
    # Greek neighboring zones based on typical interconnections
    greek_zones = ["GR", "BG", "IT", "AL", "MK", "TR"]
    return create_network_from_entsoe(date, greek_zones)
end

"""
    Network Module Documentation

This module provides two approaches for modeling electricity network constraints:

## 1. TransferCapacity (Zone-based modeling) - RECOMMENDED
- Models transfer capacity between bidding zones
- Perfect alignment with ENTSO-E data structure
- Used by default in main Euphemia algorithm
- Best for: Market clearing, ENTSO-E data integration

## 2. NetworkTopology (Line-based modeling) - LEGACY
- Models individual transmission lines
- Forced abstraction of zone-level data
- Best for: Detailed transmission analysis, academic studies

## Usage Examples

### Recommended: TransferCapacity Approach
```julia
using .Network
transfer_cap = create_transfer_capacity_from_entsoe(Date("2025-01-01"))
model = Model()
zones = transfer_cap.bidding_zones
periods = transfer_cap.time_periods
@variable(model, TRANSFER_FLOW[s in zones, d in zones, t in periods; s != d])
add_transfer_capacity_constraints!(model, transfer_cap, TRANSFER_FLOW)
```

### Legacy: Physical Network Approach
```julia
using .Network
network = create_example_network()
model = Model()
@variable(model, FLOW[l in network.lines, t in network.time_periods])
add_atc_constraints!(model, network, FLOW)
```
"""

end # module Network