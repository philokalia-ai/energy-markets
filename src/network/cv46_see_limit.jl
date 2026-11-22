# cv46 P2: west → south-east transfer limit (EUPHEMIA_CV46_SEE_LIMIT).
# Included by ../Network.jl inside `module Network`. Design: ~/armada/em-team/
# cv46-physics/cp-flows/STATUS.md; source: reviews/fable-physics-cv46.md §2
# source 1 and §3 F2.
#
# Why. Since JAO coverage (2022-10-31) the enriched network carries a FULL MESH
# of JAO maxBEX links between every pair of Core hubs in the footprint (e.g.
# DE_LU→RO 3.4 GW, FR→HU 3.1 GW), scaled only by each hub's own JAO net-position
# bound (HU may import 6.6 GW, SK 5.1, SI 4.9, RO 6.1). Every maxBEX and every
# net-position bound is a vertex of the flow-based domain, not jointly feasible,
# so the south-east imports its whole residual demand at the coupled price and
# clears at the German price (model p90 spread to DE_LU 0.0 in HU/SK/SI/CZ/AT;
# actual +50..+105).
#
# What. Two nested cuts around the south-east. Per cut and hour, when the summed
# capacity of the JAO-sourced Core links from Core hubs OUTSIDE the cut into hubs
# INSIDE it exceeds the cut's cap, those links are scaled down proportionally.
# A link that crosses both cuts takes the smaller factor, applied once (sorted
# keys, so the result is independent of Dict/Set order). Only bounds change: no
# new constraint type, no new rows/orders, so the MPCC and its LP certificate
# keep their form (the exact group constraint was measured to break the coupling
# complementarity, see `with_net_positions`). Non-Core links into the block
# (IT-NORTH→SI/AT, IT-SOUTH→GR, CH→AT: offered NTC / explicit capacity) are real
# offered capacities and are left untouched. Runs AFTER the JAO net-position
# scaling, so the cut is the binding last step; later passes (outage caps) only
# lower capacities, the aggregate remap touches IT only, and the pre-gate ATC
# fallback (forecast path only) fills border-hours with no row at all.
#
# Cap. p95 of the hourly GROSS physical flow summed over the Core borders from
# Core hubs outside the cut into the cut (INNER: AT→HU, AT→SI, CZ→SK, PL→SK;
# OUTER: DE_LU→AT, DE_LU→CZ, PL→CZ, PL→SK), entsoe.physical_flows, BZN on both
# sides, hourly mean of the quarter-hour rows. HR is excluded: it is outside the
# footprint, its flows enter the books as observed injections. One cap per
# cut-day, applied to every hour (hour-of-day p95s are flat within ±15%: a
# capability, not a demand profile).
#   p95                Fable §3 F2 ("trailing demonstrated p95 of physical flow")
#   28-day window      design choice (672 hourly samples; tracks grid outages and
#                      season). Not chosen by looking at prices.
#   ≥ 14×24 hours      minimum sample, else the cut is inert for the day (logged)
# As-of rule: flows with timestamps in [W−28 d, W), W = D−1 00:00 UTC, i.e. up to
# D−2 23:xx — published long before the D−1 12:00 CET gate. When a ForecastContext
# issues earlier than W (leads > 1), W moves back to the issuance hour.
#
# Off path: with the switch unset nothing here runs (the hook is guarded), so the
# transfer capacity is byte-identical.

"Core CCR hubs (JAO `core` CCR, DE mapped to DE_LU)."
const CV46_CORE_HUBS = ("AT", "BE", "CZ", "DE_LU", "FR", "HR", "HU", "NL", "PL", "RO", "SI", "SK")

"Nested south-east cuts (Core hubs inside each cut). STATUS.md design note."
const CV46_SEE_CUTS = (
    (name="INNER", hubs=("HU", "RO", "SI", "SK")),
    (name="OUTER", hubs=("AT", "CZ", "HU", "RO", "SI", "SK")),
)

"Zones of the south-east block (cut hubs plus the non-Core SEE zones behind them)."
const CV46_SEE_BLOCK_ZONES = ("AT", "BG", "CZ", "GR", "HU", "RO", "RS", "SI", "SK")

"""
    cv46_see_cuts() -> Tuple

CALIBRATION-ONLY selector (cp-orch, 2026-11-22): EUPHEMIA_CV46_SEE_CUTS =
`nested` (default: INNER and OUTER) or `inner` (INNER only). Decided once on the
calibration days 2026-01-29/04-11/06-14 by a rule fixed before the runs (MAE vs
SDAC over AT, CZ, SK, HU, SI, RO, DE_LU; nested kept unless inner is lower by more
than 0.5 €/MWh); the final P2 code keeps only the winner and drops this env.
"""
function cv46_see_cuts()
    v = lowercase(strip(get(ENV, "EUPHEMIA_CV46_SEE_CUTS", "")))
    v in ("", "nested") && return CV46_SEE_CUTS
    v == "inner" && return Tuple(c for c in CV46_SEE_CUTS if c.name == "INNER")
    error("EUPHEMIA_CV46_SEE_CUTS must be nested or inner (got \"$v\")")
end

const CV46_SEE_CAP_QUANTILE = 0.95      # Fable §3 F2
const CV46_SEE_WINDOW_DAYS = 28         # design choice, see header
const CV46_SEE_MIN_HOURS = 14 * 24      # minimum valid hourly samples

"True when P2 (EUPHEMIA_CV46_SEE_LIMIT) is on. Off when Network is loaded standalone."
cv46_see_on() = isdefined(_PARENT_MODULE, :cv46_on) && _PARENT_MODULE.cv46_on("EUPHEMIA_CV46_SEE_LIMIT")

"""
    cv46_see_noclamp(zone) -> Bool

P2 clamp change: in the south-east block's `:hydro`-anchored zones (AT, SK, SI)
observed imports price at `max(anchor_share × ref, 1)`, without the gas-SRMC
ceiling (book_build.jl, "import_fixed"). False with the switch off.
"""
cv46_see_noclamp(zone) = cv46_see_on() && String(zone) in CV46_SEE_BLOCK_ZONES

"""
    cv46_quantile(v, p) -> Float64

Linear-interpolation quantile (type 7, as SQL `percentile_cont`) on a sorted copy.
"""
function cv46_quantile(v::AbstractVector{<:Real}, p::Real)
    isempty(v) && return NaN
    s = sort(Float64.(v))
    h = (length(s) - 1) * p + 1
    lo = floor(Int, h); hi = min(lo + 1, length(s))
    return s[lo] + (h - lo) * (s[hi] - s[lo])
end

"""
    cv46_cut_caps(hourly, cuts; quantile, min_hours) -> Dict{String,Float64}

`hourly`: (hour, source, sink) => mean MW of physical flow. For each cut, sums per
hour the flow over Core borders whose source is a Core hub outside the cut (HR
excluded) and whose sink is inside, and returns the `quantile` of those hourly
sums. A cut with fewer than `min_hours` hours is absent from the result (inert).
"""
function cv46_cut_caps(hourly::AbstractDict, cuts=CV46_SEE_CUTS;
                       quantile::Real=CV46_SEE_CAP_QUANTILE,
                       min_hours::Int=CV46_SEE_MIN_HOURS)
    caps = Dict{String,Float64}()
    for cut in cuts
        inside = Set(cut.hubs)
        sums = Dict{Any,Float64}()
        for ((h, s, k), mw) in hourly
            (k in inside && !(s in inside) && s in CV46_CORE_HUBS && s != "HR") || continue
            sums[h] = get(sums, h, 0.0) + max(Float64(mw), 0.0)
        end
        length(sums) >= min_hours || continue
        hs = sort!(collect(keys(sums)))
        caps[cut.name] = cv46_quantile([sums[h] for h in hs], quantile)
    end
    return caps
end

"""
    cv46_scale_cut_links!(rows, caps, core_pairs, jao_keys, fpset; cuts) -> Vector

Scales, per cut and hour, the JAO-sourced Core links into the cut so their sum is
at most the cut's cap. `rows` are (source_zone, sink_zone, time_period, capacity)
NamedTuples, modified in place. A link is a cut link when its key is in
`jao_keys`, its pair is in `core_pairs` (the JAO core CCR's directed pairs), both
ends are in `fpset`, the source is outside the cut and the sink inside. A link in
several cuts takes the smallest factor, applied once. Returns one summary per cut:
(name, cap, pre_max, factor_min, hours_bind, links).
"""
function cv46_scale_cut_links!(rows, caps::AbstractDict, core_pairs, jao_keys, fpset;
                               cuts=CV46_SEE_CUTS)
    factors = ones(Float64, length(rows))
    summary = NamedTuple[]
    for cut in cuts
        haskey(caps, cut.name) || continue
        cap = caps[cut.name]
        inside = Set(cut.hubs)
        byhour = Dict{Int,Vector{Int}}()
        for (i, r) in enumerate(rows)
            s = String(r.source_zone); d = String(r.sink_zone)
            (d in inside && !(s in inside) && s in fpset && d in fpset) || continue
            ((s, d) in core_pairs && (s, d, Int(r.time_period)) in jao_keys) || continue
            push!(get!(byhour, Int(r.time_period), Int[]), i)
        end
        pre_max = 0.0; fmin = 1.0; nbind = 0; nlinks = 0
        for tp in sort!(collect(keys(byhour)))
            idx = sort!(byhour[tp], by=i -> (String(rows[i].source_zone), String(rows[i].sink_zone)))
            total = 0.0
            for i in idx
                total += max(rows[i].capacity, 0.0)
            end
            pre_max = max(pre_max, total)
            nlinks = max(nlinks, length(idx))
            (total > cap && total > 0.0) || continue
            f = cap / total
            fmin = min(fmin, f); nbind += 1
            for i in idx
                factors[i] = min(factors[i], f)
            end
        end
        push!(summary, (name=cut.name, cap=cap, pre_max=pre_max, factor_min=fmin,
                        hours_bind=nbind, links=nlinks))
    end
    for (i, f) in enumerate(factors)
        f < 1.0 || continue
        r = rows[i]
        rows[i] = (source_zone=r.source_zone, sink_zone=r.sink_zone,
                   time_period=r.time_period, capacity=r.capacity * f)
    end
    return summary
end

const _CV46_SEE_FLOW_CACHE = Dict{Tuple{Date,DateTime},Dict{String,Float64}}()
const _CV46_SEE_LOCK = ReentrantLock()

"""
    cv46_see_caps(date) -> Dict{String,Float64}

Cut caps for delivery day `date` from entsoe.physical_flows (as-of rule in the
file header). Day-cached per (date, window end).
"""
function cv46_see_caps(date::Date)
    wend = DateTime(date - Day(1))
    ctx = _asof_ctx()
    if ctx !== nothing
        wend = min(wend, floor(ctx.as_of_utc, Hour) - Hour(1))
        _asof_record!("cv46_see_flows", :verified)
    end
    wstart = wend - Day(CV46_SEE_WINDOW_DAYS)
    lock(_CV46_SEE_LOCK) do
        haskey(_CV46_SEE_FLOW_CACHE, (date, wend)) && return _CV46_SEE_FLOW_CACHE[(date, wend)]
        hubs = join(("'" * h * "'" for h in CV46_CORE_HUBS), ",")
        df = safe_sql2df("""
            SELECT date_trunc('hour', date_time_utc) AS h,
                   out_area_map_code AS s, in_area_map_code AS k,
                   AVG(flow_mw)::float8 AS mw
            FROM entsoe.physical_flows
            WHERE date_time_utc >= \$1::timestamp AND date_time_utc < \$2::timestamp
              AND out_area_type_code LIKE 'BZN%' AND in_area_type_code LIKE 'BZN%'
              AND flow_mw IS NOT NULL
              AND out_area_map_code IN ($hubs) AND in_area_map_code IN ($hubs)
            GROUP BY 1, 2, 3
            """, Any[wstart, wend])
        hourly = Dict{Tuple{DateTime,String,String},Float64}()
        for r in eachrow(df)
            (ismissing(r.mw) || ismissing(r.s) || ismissing(r.k) || ismissing(r.h)) && continue
            hourly[(DateTime(r.h), String(r.s), String(r.k))] = Float64(r.mw)
        end
        caps = cv46_cut_caps(hourly)
        _CV46_SEE_FLOW_CACHE[(date, wend)] = caps
        return caps
    end
end

"""
    cv46_apply_see_limit!(rows, date, jao, ccrp, fpset) -> Nothing

The P2 hook body (called only with the switch on): caps, scaling, one log line
per cut (cap MW, pre-scale inbound max, smallest factor, binding hours).
"""
function cv46_apply_see_limit!(rows, date::Date, jao::AbstractDict, ccrp::AbstractDict, fpset)
    caps = cv46_see_caps(date)
    core_pairs = get(ccrp, "core", Set{Tuple{String,String}}())
    cuts = cv46_see_cuts()
    summary = cv46_scale_cut_links!(rows, caps, core_pairs, Set(keys(jao)), fpset; cuts=cuts)
    for cut in cuts
        sm = findfirst(x -> x.name == cut.name, summary)
        if !haskey(caps, cut.name)
            println("   🧱 cv46 SEE_LIMIT $(cut.name): inert (fewer than $(CV46_SEE_MIN_HOURS) hourly flow samples)")
        elseif sm === nothing || summary[sm].links == 0
            println("   🧱 cv46 SEE_LIMIT $(cut.name): cap=$(round(Int, caps[cut.name])) MW, no JAO Core links into the cut")
        else
            x = summary[sm]
            println("   🧱 cv46 SEE_LIMIT $(x.name) $(date): cap=$(round(Int, x.cap)) MW, " *
                    "pre-scale inbound max=$(round(Int, x.pre_max)) MW over $(x.links) links, " *
                    "factor min=$(round(x.factor_min, digits=3)), binding hours=$(x.hours_bind)/24")
        end
    end
    return nothing
end
