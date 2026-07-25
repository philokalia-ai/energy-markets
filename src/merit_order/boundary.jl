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
back to EUA when the feed is unavailable — e.g. the offline extract) or `:eua` =
the EUA proxy (DK1/Viking's cv21 config). Validated 2026-07-23..25: the
UKA-anchored GB CCGT SRMC ≈ €146–150 tracks realized N2EX all-hours €150–159 on
the two tight days (docs/experiments/gb-borders-cv22.md). When TTF is
unavailable, back out an implied gas price from our own gas SRMC and re-scale to
GB efficiency, so the anchor still tracks fuel.
"""
function _boundary_anchor(book::BoundaryBook, day::Date, zone::String)
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
    codes = book.flow_codes
    atc_codes = boundary_atc_codes(book)
    ckey = (zone, day, join(vcat(codes, "|", atc_codes), ","))
    cached = lock(_BOUNDARY_CAP_LOCK) do
        get(_BOUNDARY_CAP_CACHE, ckey, nothing)
    end
    cached === nothing || return cached

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
    lock(_BOUNDARY_CAP_LOCK) do
        _BOUNDARY_CAP_CACHE[ckey] = out
    end
    return out
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
            for (pm, share) in book.exp_ladder
                q = qe * share
                q < 1.0 && continue
                push!(orders, SimpleOrder(:demand, clamp(anchor * pm, 1.0, price_cap),
                    q, Symbol(zone), dt, resolution_minutes))
            end
        end
    end
    return orders
end
