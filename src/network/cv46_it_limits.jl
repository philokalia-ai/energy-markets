# cv46 P3b: Italian internal transfer limits floored at trailing demonstrated
# physical flow (EUPHEMIA_CV46_IT_LIMITS). Included by ../Network.jl inside
# `module Network`, after cv46_see_limit.jl (uses `cv46_quantile`). Source:
# reviews/fable-physics-cv46.md §2 source 4 and §3 F4.
#
# Why. Offered Day-ahead ATC on the Italian internal borders dips in single
# hours (e.g. IT-CSOUTH→IT-CNORTH below its own trailing demonstrated flow in
# 191 hours at 08–13 UTC over 2026-08..11) and the model splits Italy where the
# market does not: 2,648 "phantom collapse" cells (model < 30, actual > 70),
# IT-SOUTH/Calabria/Sicily/Sardinia at 5–11 while IT-NORTH clears 82–95.
#
# What. For every directed border with both ends Italian sub-zones of the
# footprint, capacity := max(offered capacity, floor), floor = p95 of the hourly
# physical flow over the same border and direction in the SAME UTC hour of the
# day over the trailing 28 days. Only existing border-hours are raised (no rows
# are added), so the MPCC keeps its form. Runs before the transmission-outage
# cap, so a TSO's remaining-NTC message still wins over the floor.
#   p95                 as P2 (Fable §3 F2/F4 "trailing demonstrated flow")
#   same hour of day    a FLOOR is the cautious direction here: Terna's limits
#                       vary by hour, and a pooled p95 would lift night hours to
#                       a midday level (P2's cap pools hours, the generous
#                       direction for a cap)
#   28 days             as P2; ≥ 14 samples for the hour, else no floor
# As-of rule: flows with timestamps in [W−28 d, W), W = D−1 00:00 UTC (≤ D−2
# 23:xx); earlier when a ForecastContext issues before W.
# Off path: nothing here runs with the switch unset (guarded hook).

const CV46_IT_ZONES = ("IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH",
                       "IT-Calabria", "IT-Sicily", "IT-Sardinia")
const CV46_IT_FLOOR_QUANTILE = 0.95
const CV46_IT_WINDOW_DAYS = 28
const CV46_IT_MIN_SAMPLES = 14

"True when P3b (EUPHEMIA_CV46_IT_LIMITS) is on. Off when Network is loaded standalone."
cv46_it_on() = isdefined(_PARENT_MODULE, :cv46_on) && _PARENT_MODULE.cv46_on("EUPHEMIA_CV46_IT_LIMITS")

"""
    cv46_it_floors(hourly; quantile, min_samples) -> Dict{(s, k, time_period), MW}

`hourly`: (hour::DateTime, source, sink) => mean MW. Per Italian directed border
and UTC hour of day (time_period = hour + 1), the `quantile` of the samples,
negative values floored at 0; fewer than `min_samples` samples ⇒ no floor.
"""
function cv46_it_floors(hourly::AbstractDict; quantile::Real=CV46_IT_FLOOR_QUANTILE,
                        min_samples::Int=CV46_IT_MIN_SAMPLES)
    samples = Dict{Tuple{String,String,Int},Vector{Float64}}()
    for ((h, s, k), mw) in hourly
        (s in CV46_IT_ZONES && k in CV46_IT_ZONES && s != k) || continue
        push!(get!(samples, (s, k, Dates.hour(h) + 1), Float64[]), max(Float64(mw), 0.0))
    end
    floors = Dict{Tuple{String,String,Int},Float64}()
    for (key, v) in samples
        length(v) >= min_samples || continue
        floors[key] = cv46_quantile(v, quantile)
    end
    return floors
end

"""
    cv46_floor_it_rows!(rows, floors, fpset) -> Vector{NamedTuple}

Raises each Italian internal border-hour of `rows` (both ends in `fpset`) to its
floor when the floor is higher. Returns per directed border:
(border, hours_raised, mw_added) for borders with at least one raised hour.
"""
function cv46_floor_it_rows!(rows, floors::AbstractDict, fpset)
    raised = Dict{Tuple{String,String},Tuple{Int,Float64}}()
    for i in eachindex(rows)
        r = rows[i]
        s = String(r.source_zone); d = String(r.sink_zone)
        (s in CV46_IT_ZONES && d in CV46_IT_ZONES && s in fpset && d in fpset) || continue
        fl = get(floors, (s, d, Int(r.time_period)), 0.0)
        fl > r.capacity || continue
        n, mw = get(raised, (s, d), (0, 0.0))
        raised[(s, d)] = (n + 1, mw + (fl - max(r.capacity, 0.0)))
        rows[i] = (source_zone=r.source_zone, sink_zone=r.sink_zone,
                   time_period=r.time_period, capacity=fl)
    end
    return [(border=b, hours_raised=raised[b][1], mw_added=raised[b][2])
            for b in sort!(collect(keys(raised)))]
end

const _CV46_IT_CACHE = Dict{Tuple{Date,DateTime},Dict{Tuple{String,String,Int},Float64}}()
const _CV46_IT_LOCK = ReentrantLock()

"Italian internal floors for delivery day `date` (as-of rule in the header), day-cached."
function cv46_it_floors(date::Date)
    wend = DateTime(date - Day(1))
    ctx = _asof_ctx()
    if ctx !== nothing
        wend = min(wend, floor(ctx.as_of_utc, Hour) - Hour(1))
        _asof_record!("cv46_it_flows", :verified)
    end
    wstart = wend - Day(CV46_IT_WINDOW_DAYS)
    lock(_CV46_IT_LOCK) do
        haskey(_CV46_IT_CACHE, (date, wend)) && return _CV46_IT_CACHE[(date, wend)]
        zs = join(("'" * z * "'" for z in CV46_IT_ZONES), ",")
        df = safe_sql2df("""
            SELECT date_trunc('hour', date_time_utc) AS h,
                   out_area_map_code AS s, in_area_map_code AS k,
                   AVG(flow_mw)::float8 AS mw
            FROM entsoe.physical_flows
            WHERE date_time_utc >= \$1::timestamp AND date_time_utc < \$2::timestamp
              AND out_area_type_code LIKE 'BZN%' AND in_area_type_code LIKE 'BZN%'
              AND flow_mw IS NOT NULL
              AND out_area_map_code IN ($zs) AND in_area_map_code IN ($zs)
            GROUP BY 1, 2, 3
            """, Any[wstart, wend])
        hourly = Dict{Tuple{DateTime,String,String},Float64}()
        for r in eachrow(df)
            (ismissing(r.mw) || ismissing(r.s) || ismissing(r.k) || ismissing(r.h)) && continue
            hourly[(DateTime(r.h), String(r.s), String(r.k))] = Float64(r.mw)
        end
        fl = cv46_it_floors(hourly)
        _CV46_IT_CACHE[(date, wend)] = fl
        return fl
    end
end

"P3b hook body (switch on only): floors + one log line per raised border."
function cv46_apply_it_limits!(rows, date::Date, fpset)
    floors = cv46_it_floors(date)
    summary = cv46_floor_it_rows!(rows, floors, fpset)
    tot = sum((x.hours_raised for x in summary); init=0)
    println("   🇮🇹 cv46 IT_LIMITS $(date): $(length(floors)) border-hour floors, " *
            "$(tot) border-hours raised on $(length(summary)) border(s)")
    for x in summary
        println("   🇮🇹 cv46 IT_LIMITS $(x.border[1])>$(x.border[2]): $(x.hours_raised) h raised, " *
                "+$(round(Int, x.mw_added / max(x.hours_raised, 1))) MW mean")
    end
    return nothing
end
