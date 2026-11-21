# Realized hourly quantities, deliberately outside the D-1 context. Called only
# after research_oracle validates the runtime backend and lookahead opt-in.
const ORACLE_RIVER_FUEL = Symbol("Hydro Run-of-river and pondage")
const ORACLE_RES_FUELS = ("Solar", "Wind Onshore", "Wind Offshore")

# Keep one complete resolution per series/hour. A missing native interval or a
# NULL does not become zero. If both resolutions cover the hour, prefer finer.
# A series present on both adjacent dates but absent on the delivery day is
# represented by a NULL marker. This distinguishes a feed outage from an
# unreported technology. Only D0 MW enter the book.
function _oracle_hourly(zone, day; load=false)
    source, col, kind = load ?
        ("actual_total_load", "total_load_mw", "'Load'") :
        ("aggregated_generation_per_type", "actual_generation_output_mw", "production_type")
    df = sql2df_with_retry("""
        WITH raw AS (
            SELECT date_time_utc AS t, resolution_code, $kind AS kind,
                   $col AS val, update_time_utc AS revision
            FROM entsoe.$source
            WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
              AND date_time_utc >= \$2::date - INTERVAL '1 day'
              AND date_time_utc < \$2::date + INTERVAL '2 days'
        ), published AS (
            SELECT DISTINCT * EXCLUDE (t, resolution_code, val, revision), t::date AS d FROM raw
        ), absent AS (
            SELECT * EXCLUDE (d) FROM published GROUP BY ALL
            HAVING count(*) FILTER (WHERE d <> \$2::date) = 2
               AND count(*) FILTER (WHERE d = \$2::date) = 0
        ), slots AS (
            SELECT * EXCLUDE (val, revision),
                   first(val ORDER BY revision DESC NULLS LAST, val DESC NULLS LAST) AS mw
            FROM raw WHERE t >= \$2::date AND t < \$2::date + INTERVAL '1 day'
            GROUP BY ALL
        ), candidates AS (
            SELECT * EXCLUDE (t, mw), hour(t) AS h,
                   CASE resolution_code WHEN 'PT15M' THEN 4 WHEN 'PT30M' THEN 2
                        WHEN 'PT60M' THEN 1 END AS required,
                   count(mw) AS n, avg(mw) AS hourly_mw
            FROM slots GROUP BY ALL
        )
        SELECT * EXCLUDE (resolution_code, required, n, hourly_mw),
               first(hourly_mw ORDER BY required DESC) FILTER (WHERE n = required) AS mw
        FROM candidates GROUP BY ALL
        UNION ALL BY NAME SELECT *, 0 AS h, NULL::DOUBLE AS mw FROM absent
        ORDER BY ALL
        """, [zone, day])
    series = Dict{String,Dict{Int,Float64}}()
    for r in eachrow(df)
        by_hour = get!(series, String(r.kind), Dict{Int,Float64}())
        ismissing(r.mw) || (by_hour[Int(r.h)] = Float64(r.mw))
    end
    return series
end

function _oracle_quantities(cfg, gen, actual_load)
    river = cfg.hydro_energy ? get(gen, string(ORACLE_RIVER_FUEL), Dict{Int,Float64}()) : nothing
    reservoir = cfg.hydro_energy ? get(gen, "Hydro Water Reservoir", Dict{Int,Float64}()) : nothing
    fund = if cfg.fund
        # A zone that reports other generation but has no wind or solar series
        # (e.g. NO5) legitimately contributes zero RES. Missing observations
        # in a reported series instead retain the full cv45 FUND input.
        types = [gen[k] for k in ORACLE_RES_FUELS if haskey(gen, k)]
        solar = get(gen, "Solar", Dict{Int,Float64}())
        Dict(h => (load=actual_load[h], res=sum((v[h] for v in types); init=0.0),
                   solar=get(solar, h, 0.0))
             for h in 0:23 if haskey(actual_load, h) && any(v -> haskey(v, h), values(gen)) &&
                               all(v -> haskey(v, h), types))
    end
    return (; river, reservoir, fund)
end

# Start from the complete ordinary book, including input corrections, modifiers,
# and weather solar. Override only a zone-hour with complete FUND observations.
function _apply_oracle_fund!(slots, load, res, solar, fund, day, resolution_minutes)
    for (h, obs) in fund
        solar[h] = [obs.solar]
        for minute in 0:resolution_minutes:59
            ts = Dates.format(DateTime(day) + Hour(h) + Minute(minute), "yyyymmdd-HHMM")
            load[ts] = obs.load
            res[ts] = obs.res
            ts in slots || push!(slots, ts)
        end
    end
    sort!(slots)
end

function _oracle_fallback_counts(quantities, cfg)
    fallback = 0
    river = 0
    reservoir = 0
    fund = 0
    for q in values(quantities)
        if cfg.hydro_energy
            river += 24 - length(q.river)
            reservoir += 24 - length(q.reservoir)
            fallback += count(h -> !haskey(q.river, h) || !haskey(q.reservoir, h), 0:23)
        end
        cfg.fund && (fund += 24 - length(q.fund))
    end
    return (; hydro_energy=fallback, river, reservoir, fund)
end

function oracle_day(zones, day; cfg=research_oracle(), log_coverage=true)
    cfg === nothing && return nothing
    targets = intersect(Set(zones), cfg.zones)
    isempty(targets) && return nothing
    quantities = Dict{String,NamedTuple}()
    for z in sort!(collect(targets))
        gen = _oracle_hourly(z, day)
        load = cfg.fund ? get(_oracle_hourly(z, day; load=true), "Load", Dict{Int,Float64}()) : nothing
        quantities[z] = _oracle_quantities(cfg, gen, load)
    end
    if log_coverage
        n = _oracle_fallback_counts(quantities, cfg)
        total = 24 * length(targets)
        cfg.hydro_energy && @info "Oracle fallback" day arm="HYDRO_ENERGY" zone_hours=total fallback=n.hydro_energy river=n.river reservoir=n.reservoir
        cfg.fund && @info "Oracle fallback" day arm="FUND" zone_hours=total fallback=n.fund
    end
    return quantities
end

function oracle_fixed(oracle, zones, periods)
    fixed = Dict{Tuple{String,String},Float64}()
    oracle === nothing && return fixed
    for z in zones
        qty = get(oracle, z, nothing)
        (qty === nothing || qty.river === nothing) && continue
        for t in periods
            mw = get(qty.river, parse(Int, t[10:11]), 0.0)
            iszero(mw) || (fixed[(z, t)] = mw)
        end
    end
    return fixed
end
