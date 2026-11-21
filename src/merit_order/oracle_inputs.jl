# Realized hourly quantities, deliberately outside the D-1 context. Called only
# after research_oracle validates the runtime backend and lookahead opt-in.
const ORACLE_HYDRO_FUELS = ("Hydro Run-of-river and pondage", "Hydro Water Reservoir")
const ORACLE_RES_FUELS = ("Solar", "Wind Onshore", "Wind Offshore")

# Keep one complete resolution per series/hour. A missing native interval or a
# NULL does not become zero. If both resolutions cover the hour, prefer finer.
# A series present on both adjacent dates but absent on the delivery day is
# represented by a NULL marker. This distinguishes a feed outage from an
# unreported technology or border direction. Only D0 MW enter the book.
function _oracle_hourly_rows(source, col, dimensions, predicate, params)
    return sql2df_with_retry("""
        WITH raw AS (
            SELECT date_time_utc AS t, resolution_code, $dimensions,
                   $col AS val, update_time_utc AS revision
            FROM entsoe.$source
            WHERE ($predicate) AND date_time_utc >= \$2::date - INTERVAL '1 day'
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
        """, params)
end

function _oracle_hourly(zone, day; load=false)
    source, col, kind = load ?
        ("actual_total_load", "total_load_mw", "'Load'") :
        ("aggregated_generation_per_type", "actual_generation_output_mw", "production_type")
    df = _oracle_hourly_rows(source, col, "$kind AS kind",
        "area_map_code = \$1 AND area_type_code LIKE 'BZN%'", [zone, day])
    series = Dict{String,Dict{Int,Float64}}()
    for r in eachrow(df)
        by_hour = get!(series, String(r.kind), Dict{Int,Float64}())
        ismissing(r.mw) || (by_hour[Int(r.h)] = Float64(r.mw))
    end
    isempty(series) && error("No actual $source for $zone $day")
    return series
end

function _oracle_quantities(cfg, zone, day, gen, actual_load)
    hours = BitSet(0:23)
    # A type never reported for this zone/day contributes zero (e.g. NO5 has
    # no reported wind/solar). An entirely missing generation feed is an error.
    intersect!(hours, union((keys(v) for v in values(gen))...))
    hydro = nothing
    if cfg.hydro
        types = [gen[k] for k in ORACLE_HYDRO_FUELS if haskey(gen, k)]
        foreach(v -> intersect!(hours, keys(v)), types)
        hydro = Dict(h => sum((v[h] for v in types); init=0.0) for h in hours)
    end
    fund = nothing
    if cfg.fund
        intersect!(hours, keys(actual_load))
        types = [k for k in ORACLE_RES_FUELS if haskey(gen, k)]
        foreach(k -> intersect!(hours, keys(gen[k])), types)
        ts(h) = Dates.format(DateTime(day) + Hour(h), "yyyymmdd-HHMM")
        loads = [Load(ts(h), "PT60M", zone, actual_load[h]) for h in hours]
        res = RenewablesGenerationForecast[RenewablesGenerationForecast(ts(h), "PT60M",
            zone, k, gen[k][h]) for h in hours for k in types]
        fund = (; loads, res)
    end
    return (; hydro, fund, hours)
end

# Directed BZN power feeds have one complete MW mean per UTC hour. Deduplicate
# _IPS aliases before subtracting the two directions of a physical border.
function _oracle_borders(rows, targets, shadow, hours)
    directed = Dict{Tuple{String,String},Dict{Int,Float64}}()
    for r in rows
        a, b = _strip_ips(r.out_code), _strip_ips(r.in_code)
        (a in targets || b in targets) && !(a in shadow || b in shadow || a == b) || continue
        v = get!(directed, (a, b), Dict{Int,Float64}())
        ismissing(r.mw) || (v[r.h] = max(get(v, r.h, -Inf), r.mw))
    end
    for z in targets
        any(pair -> z in pair, keys(directed)) || error("No realized physical borders for $z")
    end
    foreach(v -> intersect!(hours, keys(v)), values(directed))
    net = Dict{Tuple{String,String},Dict{Int,Float64}}()
    for (a, b) in sort!(collect(keys(directed)))
        signed = a < b ? 1 : -1
        v = get!(net, minmax(a, b), Dict{Int,Float64}())
        for (h, mw) in directed[(a, b)]
            v[h] = get(v, h, 0.0) + signed * mw
        end
    end
    return net
end

# On modeled borders, identical lower and upper bounds force the actual flow
# in both the complex-order master and the hourly repricing solve. Other
# borders become signed fixed injections, on both ends if both are modeled.
function _oracle_exchange(net, pairs, zones, targets, hours)
    pins = Dict{Tuple{String,String,String},Float64}()
    residual = Dict(z => Dict{Int,Float64}() for z in zones)
    total = Dict(z => Dict{Int,Float64}() for z in zones)
    modeled = Set{Tuple{String,String}}()
    for (a, b) in pairs
        a in zones && b in zones && (a in targets || b in targets) || continue
        ab = minmax(a, b)
        ab in modeled && error("Oracle flows require canonical ATC borders")
        push!(modeled, ab)
        v = get(net, ab, nothing)
        for h in hours
            pins[(a, b, string(h + 1))] = v === nothing ? 0.0 : (a < b ? v[h] : -v[h])
        end
    end
    for (a, b) in sort!(collect(keys(net))), h in hours
        for (z, q) in ((a, -net[(a, b)][h]), (b, net[(a, b)][h]))
            z in zones || continue
            total[z][h] = get(total[z], h, 0.0) + q
            if (a, b) ∉ modeled
                residual[z][h] = get(residual[z], h, 0.0) + q
            end
        end
    end
    return (; pins, residual, total)
end

function oracle_day(zones, day; pairs=Tuple{String,String}[], shadow=String[], cfg=research_oracle())
    cfg === nothing && return nothing
    targets = intersect(Set(zones), cfg.zones)
    isempty(targets) && return nothing
    hours = BitSet(0:23)
    quantities = Dict{String,NamedTuple}()
    if cfg.hydro || cfg.fund
        for zone in sort!(collect(targets))
            gen = _oracle_hourly(zone, day)
            load = cfg.fund ? _oracle_hourly(zone, day; load=true)["Load"] : nothing
            quantities[zone] = _oracle_quantities(cfg, zone, day, gen, load)
        end
    end
    foreach(q -> intersect!(hours, q.hours), values(quantities))
    flow = if cfg.flows
        rows = _oracle_hourly_rows("physical_flows", "flow_mw",
            "out_area_map_code AS out_code, in_area_map_code AS in_code",
            """(out_area_map_code = ANY(\$1) OR in_area_map_code = ANY(\$1))
               AND out_area_type_code LIKE 'BZN%' AND in_area_type_code LIKE 'BZN%'""",
            Any[collect(targets), day])
        net = _oracle_borders(eachrow(rows), targets, shadow, hours)
        _oracle_exchange(net, pairs, zones, targets, hours)
    end
    isempty(hours) && error("No common complete oracle hours on $day")
    length(hours) < 24 && @warn "Oracle coverage: dropping incomplete UTC hours" day missing_hours=setdiff(0:23, hours)
    return (; targets, quantities, flow, hours)
end

function oracle_fixed(oracle, zones, periods)
    fixed = Dict{Tuple{String,String},Float64}()
    oracle === nothing && return fixed
    for z in zones, t in periods
        h = parse(Int, t[10:11])
        qty = get(oracle.quantities, z, nothing)
        hydro = qty === nothing || qty.hydro === nothing ? 0.0 : qty.hydro[h]
        exchange = oracle.flow === nothing ? 0.0 : get(oracle.flow.residual[z], h, 0.0)
        mw = hydro + exchange
        iszero(mw) || (fixed[(z, t)] = mw)
    end
    return fixed
end
