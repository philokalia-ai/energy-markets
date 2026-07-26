# boundary.jl — cv21 virtual boundary-counterparty book (DK1/Viking Link, GB).
# Included by ../MeritOrderBook.jl AFTER zone_profiles.jl (needs BoundaryBook)
# and BEFORE book_build.jl (which calls get_boundary_orders). "Model the
# country, not the flow": an out-of-footprint neighbor on one physical border is
# priced as an elastic counterparty whose willingness to pay/sell is ITS OWN
# fundamental SRMC, laddered over the border's DEMONSTRATED capability. See
# docs/experiments/cv21-dk1-viking.md and the BoundaryBook docstring.
#
# All of this is dead code unless a zone's profile carries a `boundary_book`
# (only DK1 does in cv21) — so every other zone's book is byte-identical.

const GB_CCGT_EFFICIENCY = 0.52   # GB CCGT fleet efficiency (LHV) — the anchor
                                  # divisor for the GB fundamental SRMC.

"""
    _boundary_anchor(book::BoundaryBook, day::Date, zone::String) -> Float64

The NEIGHBOR's own fundamental marginal cost (€/MWh) the boundary ladder is
anchored on — never our price, never a fixed multiple of our SRMC (the
boundary-program standing rule). `:gb_ccgt_srmc` is GB CCGT SRMC: TTF/η +
UK-carbon/η + €2 O&M (η = `GB_CCGT_EFFICIENCY`). The carbon leg uses
`book.carbon_source`: `:uka` = the real UK-ETS price (`uka_price(day)`, falling
back to EUA when the feed is unavailable — e.g. the offline extract) or `:eua`
= the EUA proxy (DK1/Viking's cv21 config). Validated 2026-07-23..25: the
UKA-anchored GB CCGT SRMC ≈ €146–150 tracks realized N2EX all-hours €150–159 on
the two tight days (docs/experiments/gb-borders-cv22.md). When TTF is
unavailable, back out an implied gas price from our own gas SRMC and re-scale to
GB efficiency, so the anchor still tracks fuel.
"""
function _boundary_anchor(book::BoundaryBook, day::Date, zone::String)
    # :zone_gas_srmc (cv22/UA) — our OWN zone gas SRMC. UA has no fundamentals
    # feed, so this is the documented wave-1 generic-anchor compromise; the firm
    # slice, not the elastic anchor, does the load-bearing work.
    book.anchor === :zone_gas_srmc && return get_marginal_cost(day, "Fossil Gas", zone)
    book.anchor === :gb_ccgt_srmc ||
        error("unknown boundary anchor $(book.anchor)")
    carbon = book.carbon_source === :uka ? uka_price(day) : eua_price(day)
    ttf = get_ttf_price(day)
    if ttf === nothing
        gas = get_marginal_cost(day, "Fossil Gas", zone)
        return (gas - GAS_VOM_COST) *
               (GAS_PLANT_EFFICIENCY / GB_CCGT_EFFICIENCY) + GAS_VOM_COST
    end
    return ttf / GB_CCGT_EFFICIENCY +
           GAS_EMISSION_FACTOR / GB_CCGT_EFFICIENCY * carbon +
           GAS_VOM_COST
end

# --- Boundary-capability day cache (like _NET_IMPORTS_DAY_CACHE): the runtime
# capability query scans a 366-day flow window + the day's offered ATC, so cache
# per (zone, day). Keyed on the flow-code set too, so distinct borders never
# collide. Errors are never cached (transient DB failures must retry). -----------
const _BOUNDARY_CAP_CACHE = Dict{Tuple{String,Date,String},Dict{Int,Tuple{Float64,Float64}}}()
const _BOUNDARY_CAP_LOCK = ReentrantLock()

"clear_boundary_cap_cache!() — empty the per-(zone,day) boundary-capability cache."
function clear_boundary_cap_cache!()
    lock(_BOUNDARY_CAP_LOCK) do
        empty!(_BOUNDARY_CAP_CACHE)
        empty!(_BOUNDARY_FIRM_CACHE)
    end
    return nothing
end

"""
    get_boundary_capability(zone, book, day) -> Dict{Int,Tuple{Float64,Float64}}

Per-UTC-hour demonstrated interconnector capability `(imp, exp)` MW on the
border, where `imp` = capacity TOWARD the footprint zone (import-supply ladder)
and `exp` = capacity AWAY from it (export-demand ladder). This is the wave-2
quantity recipe (docs/experiments/boundary-refine, build_inputs_w2.py) ported
to a runtime query so it generalizes to every backfill day:

  cap(dir, h) = the day's offered Day-ahead EXPLICIT ATC in that direction,
                capped at the trailing-366-day demonstrated max gross flow;
                where no DA-ATC row was published for hour h, the trailing-366d
                p95 gross flow of h's 4-hour block (the demonstrated-capability
                floor — the wave-1 Mechanism-A definition, regime-independent).

All inputs strictly predate the delivery day's D-1 auction (ATC is the day's
published offer; flows are ≤ D-2). The per-hour p95 fallback (vs the
experiment's whole-day-only fallback) keeps the book active when ATC publication
is late/partial in the data — a shipped feature must not go inert on a data gap.
On days with full DA-ATC coverage this reproduces the experiment's precomputed
capability bit-identically (verified on the confirm window).
"""
function get_boundary_capability(zone::String, book::BoundaryBook, day::Date)
    ckey = (zone, day, join(vcat(book.flow_codes, "|", boundary_atc_codes(book)), ","))
    cached = lock(_BOUNDARY_CAP_LOCK) do
        get(_BOUNDARY_CAP_CACHE, ckey, nothing)
    end
    cached === nothing || return cached
    out = book.capability_mode === :p95_block ?
          _boundary_capability_p95(zone, book, day) :
          _boundary_capability_atc(zone, book, day)
    lock(_BOUNDARY_CAP_LOCK) do
        _BOUNDARY_CAP_CACHE[ckey] = out
    end
    return out
end

# cv21/DK1 capability: the day's offered DA explicit ATC capped at the
# trailing-366d demonstrated max, with the per-hour p95 block as the floor on
# ATC gaps. (Unchanged from cv21 — byte-identical for VIKING_GB_BOOK.)
function _boundary_capability_atc(zone::String, book::BoundaryBook, day::Date)
    codes = book.flow_codes
    atc_codes = boundary_atc_codes(book)
    # (1) The day's offered Day-ahead explicit ATC per direction. A border can be
    # published as multiple parallel cables (FR↔GB: IFA/IFA2/ElecLink, no
    # aggregate ATC), so AVG within (cable, hour) then SUM across cables — the
    # total border capability. A single-code border (DK1: "GB") sums one cable ⇒
    # bit-identical to the old per-(dir,hour) AVG.
    atc_df = sql2df_with_retry(
        """
        SELECT dir, h, SUM(cap) AS cap FROM (
          SELECT CASE WHEN in_map_code = \$1 THEN 'imp' ELSE 'exp' END AS dir,
                 EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int AS h,
                 CASE WHEN in_map_code = \$1 THEN out_map_code ELSE in_map_code END AS cbl,
                 AVG(capacity_mw) AS cap
          FROM entsoe.offered_transfer_capacities_explicit
          WHERE contract_type = 'Day-ahead' AND capacity_mw IS NOT NULL
            AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
            AND date_time_utc <  ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
            AND ((in_map_code = \$1 AND out_map_code = ANY(\$3))
              OR (out_map_code = \$1 AND in_map_code = ANY(\$3)))
          GROUP BY 1, 2, 3
        ) s
        GROUP BY 1, 2
        """,
        Any[zone, day, atc_codes])
    atc = Dict{Tuple{String,Int},Float64}()
    for r in eachrow(atc_df)
        ismissing(r.cap) || (atc[(String(r.dir), Int(r.h))] = Float64(r.cap))
    end

    # (2) Trailing-366d hourly-avg gross flow per direction (window [D-366, D-1)
    #     — strictly pre-D-1). p95/max computed in Julia (cross-dialect: no SQL
    #     percentile / integer-division to worry about).
    flow_df = sql2df_with_retry(
        """
        SELECT dir, EXTRACT(HOUR FROM ts)::int AS h, f FROM (
          SELECT CASE WHEN in_area_map_code = \$1 THEN 'imp' ELSE 'exp' END AS dir,
                 date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS ts,
                 AVG(flow_mw) AS f
          FROM entsoe.physical_flows
          WHERE in_area_type_code LIKE 'BZN%' AND out_area_type_code LIKE 'BZN%'
            AND date_time_utc >= ((\$2::date - 366)::timestamp AT TIME ZONE 'UTC')
            AND date_time_utc <  ((\$2::date - 1)::timestamp AT TIME ZONE 'UTC')
            AND ((in_area_map_code = \$1 AND out_area_map_code = ANY(\$3))
              OR (out_area_map_code = \$1 AND in_area_map_code = ANY(\$3)))
          GROUP BY 1, 2
        ) s
        """,
        Any[zone, day, codes])
    # Per-direction: all hourly flows (for the demonstrated max) and per-4h-block
    # buckets (for the p95 fallback).
    fmax = Dict{String,Float64}()
    blockvals = Dict{Tuple{String,Int},Vector{Float64}}()
    for r in eachrow(flow_df)
        ismissing(r.f) && continue
        d = String(r.dir); h = Int(r.h); f = Float64(r.f)
        fmax[d] = max(get(fmax, d, 0.0), f)
        push!(get!(blockvals, (d, h ÷ 4), Float64[]), f)
    end
    p95block = Dict{Tuple{String,Int},Float64}()
    for (k, vs) in blockvals
        p95block[k] = quantile(vs, 0.95)   # type-7 == numpy/percentile_cont linear
    end

    out = Dict{Int,Tuple{Float64,Float64}}()
    for h in 0:23
        dirvals = ntuple(2) do i
            dir = i == 1 ? "imp" : "exp"
            if haskey(atc, (dir, h))
                min(atc[(dir, h)], get(fmax, dir, 0.0))
            else
                get(p95block, (dir, h ÷ 4), 0.0)   # demonstrated-capability floor
            end
        end
        out[h] = (round(dirvals[1], digits=1), round(dirvals[2], digits=1))
    end
    return out
end

# --- Combined directed gross flow over a window (cv22/UA multi-code borders) ---
# Returns Dict{(dir, hour_ts) => MW}: per direction, per hour-truncated UTC
# timestamp, the border's gross flow combined across `book.flow_codes`. Alias
# codes (`X_IPS`) are collapsed into `X` by MAX per hour (the duplicate-alias
# dedup of `get_net_imports`); the resulting distinct canonical codes are SUMMED
# (genuinely-separate radials, e.g. PL's UA + UA_DobTPP). `dir = "imp"` when the
# footprint zone is the sink (flow toward it), `"exp"` when it is the source.
function _boundary_combined_flows(zone::String, book::BoundaryBook,
    start_date::Date, stop_date::Date)
    # Query the canonical codes and their _IPS aliases.
    qcodes = String[]
    for c in book.flow_codes
        push!(qcodes, c); push!(qcodes, c * "_IPS")
    end
    df = sql2df_with_retry(
        """
        SELECT CASE WHEN in_area_map_code = \$1 THEN 'imp' ELSE 'exp' END AS dir,
               CASE WHEN in_area_map_code = \$1 THEN out_area_map_code
                    ELSE in_area_map_code END AS code,
               date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS ts,
               AVG(flow_mw) AS f
        FROM entsoe.physical_flows
        WHERE in_area_type_code LIKE 'BZN%' AND out_area_type_code LIKE 'BZN%'
          AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc <  (\$3::date::timestamp AT TIME ZONE 'UTC')
          AND ((in_area_map_code = \$1 AND out_area_map_code = ANY(\$4))
            OR (out_area_map_code = \$1 AND in_area_map_code = ANY(\$4)))
        GROUP BY 1, 2, 3
        """,
        Any[zone, start_date, stop_date, qcodes])
    canon = Set(book.flow_codes)
    # Step 1: alias-collapse to canonical, MAX per (dir, canonical, ts).
    bycanon = Dict{Tuple{String,String,DateTime},Float64}()
    for r in eachrow(df)
        ismissing(r.f) && continue
        raw = String(r.code)
        c = raw in canon ? raw : _strip_ips(raw)
        c in canon || continue
        k = (String(r.dir), c, DateTime(r.ts)); v = Float64(r.f)
        bycanon[k] = max(get(bycanon, k, -Inf), v)
    end
    # Step 2: SUM canonical codes per (dir, ts).
    out = Dict{Tuple{String,DateTime},Float64}()
    for ((dir, _, ts), v) in bycanon
        k = (dir, ts)
        out[k] = get(out, k, 0.0) + v
    end
    return out
end

# cv22/UA capability: the pure trailing-366d p95 gross flow per 4h block, per
# direction — the wave-1 Mechanism-A / BG–TR definition (UA explicit ATC is
# stale/absent and understates realized flows ~4×, so the demonstrated floor is
# used uniformly, no ATC). Window [D-366, D-1), strictly pre-D-1.
function _boundary_capability_p95(zone::String, book::BoundaryBook, day::Date)
    flows = _boundary_combined_flows(zone, book, day - Day(366), day - Day(1))
    blockvals = Dict{Tuple{String,Int},Vector{Float64}}()
    for ((dir, ts), v) in flows
        push!(get!(blockvals, (dir, Dates.hour(ts) ÷ 4), Float64[]), v)
    end
    p95 = Dict{Tuple{String,Int},Float64}(
        k => quantile(vs, 0.95) for (k, vs) in blockvals)
    out = Dict{Int,Tuple{Float64,Float64}}()
    for h in 0:23
        qi = get(p95, ("imp", h ÷ 4), 0.0)
        qe = get(p95, ("exp", h ÷ 4), 0.0)
        out[h] = (round(qi, digits=1), round(qe, digits=1))
    end
    return out
end

# --- Firm-slice day cache (like _BOUNDARY_CAP_CACHE): trailing-window p-quantile
# of the daily block-mean export flow. Keyed on (zone, day, flow_codes). --------
const _BOUNDARY_FIRM_CACHE = Dict{Tuple{String,Date,String},Dict{Int,Float64}}()

"""
    get_boundary_firm(zone, book, day) -> Dict{Int,Float64}

Per-UTC-hour FIRM export-demand slice (MW) for a `firm_slice` boundary book: the
`firm_quantile` (p10) over the trailing `firm_window_days` days of the daily
4h-block-MEAN gross EXPORT flow zone→counterparty. This is UA's demonstrated
persistent import need — the level it takes on ~90% of recent days, structural
(grid damage + deficit) rather than price-elastic, so it bids as a price-taker
at the cap and does not curtail when the exporting zone's price spikes (the
mechanism that kills the wave-2 HU March breach; sizing rationale in
docs/experiments/cv22.md / build_inputs_refine.py). Window [D-firm_window_days-1,
D-1), strictly pre-D-1. When the direction flips (June/July: UA exports to HU),
the trailing p10 collapses to ~0 by itself and the book reverts to the pure
elastic ladder.
"""
function get_boundary_firm(zone::String, book::BoundaryBook, day::Date)
    ckey = (zone, day, join(book.flow_codes, ","))
    cached = lock(_BOUNDARY_CAP_LOCK) do
        get(_BOUNDARY_FIRM_CACHE, ckey, nothing)
    end
    cached === nothing || return cached
    flows = _boundary_combined_flows(zone, book,
        day - Day(book.firm_window_days + 1), day - Day(1))
    # Daily 4h-block MEAN of the EXPORT flow, then the p-quantile over days.
    byblockday = Dict{Tuple{Int,Date},Vector{Float64}}()
    for ((dir, ts), v) in flows
        dir == "exp" || continue
        push!(get!(byblockday, (Dates.hour(ts) ÷ 4, Date(ts)), Float64[]), v)
    end
    blockday_mean = Dict{Tuple{Int,Date},Float64}(
        k => sum(vs) / length(vs) for (k, vs) in byblockday)
    byblock = Dict{Int,Vector{Float64}}()
    for ((b, _), m) in blockday_mean
        push!(get!(byblock, b, Float64[]), m)
    end
    firm = Dict{Int,Float64}()
    for h in 0:23
        vs = get(byblock, h ÷ 4, Float64[])
        firm[h] = isempty(vs) ? 0.0 : round(quantile(vs, book.firm_quantile), digits=1)
    end
    lock(_BOUNDARY_CAP_LOCK) do
        _BOUNDARY_FIRM_CACHE[ckey] = firm
    end
    return firm
end

"""
    get_boundary_orders(book, zone, day, timeslots, resolution_minutes, price_cap)
        -> Vector{SimpleOrder}

The elastic boundary counterparty ladder for one zone-day: an import-supply
stack (the neighbor sells into the zone at `price_mult × anchor` for its share
of the demonstrated import capability) and an export-demand stack (symmetric).
`anchor = book.anchor_mult × neighbor-fundamental SRMC`. Rungs below 1 MW are
dropped; prices clamp to `[1, price_cap]`.
"""
function get_boundary_orders(book::BoundaryBook, zone::String, day::Date,
    timeslots::Vector{String}, resolution_minutes::Int, price_cap::Float64)
    anchor = book.anchor_mult * _boundary_anchor(book, day, zone)
    cap = get_boundary_capability(zone, book, day)
    firm = book.firm_slice ? get_boundary_firm(zone, book, day) :
           Dict{Int,Float64}()
    orders = SimpleOrder[]
    for ts in timeslots
        dt = parse_timeslot_to_datetime(ts, day)
        h = Dates.hour(dt)
        qi, qe = get(cap, h, (0.0, 0.0))
        if qi > 1.0                     # import supply: neighbor sells to us
            for (pm, share) in book.imp_ladder
                q = qi * share
                q < 1.0 && continue
                push!(orders, SimpleOrder(:supply, clamp(anchor * pm, 1.0, price_cap),
                    q, Symbol(zone), dt, resolution_minutes))
            end
        end
        if qe > 1.0                     # export demand: neighbor buys from us
            # cv22 firm slice: a war-constrained importer's demonstrated
            # persistent need bids as a price-taker at the cap (does not curtail
            # on price); only the tail above it stays on the elastic ladder.
            qf = book.firm_slice ? min(get(firm, h, 0.0), qe) : 0.0
            qt = qe - qf
            qf > 1.0 && push!(orders, SimpleOrder(:demand,
                clamp(book.firm_price, 1.0, price_cap), qf, Symbol(zone), dt,
                resolution_minutes))
            for (pm, share) in book.exp_ladder
                q = qt * share
                q < 1.0 && continue
                push!(orders, SimpleOrder(:demand, clamp(anchor * pm, 1.0, price_cap),
                    q, Symbol(zone), dt, resolution_minutes))
            end
        end
    end
    return orders
end
