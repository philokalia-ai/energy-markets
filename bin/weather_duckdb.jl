# Open-meteo answers from a local DuckDB of exported weather vintages (flag-gated, default off).
#
#   EUPHEMIA_WEATHER_DUCKDB=<path>   (unset/empty = HTTP, today's behaviour)
#
# When set, every open-meteo FORECAST-family request (`.../v1/forecast`: the live
# forecast API and the previous-runs API, local or public) made by the three weather
# fetchers (`fetch_weather` RES pack, `fetch_load_weather` load, `fetch_ml_res_weather`
# ML RES) is answered from that file instead of HTTP. The shim sits at the HTTP layer
# (`_openmeteo_get` / `_load_openmeteo_get` call `weather_duckdb_answer` first), parses
# the request URL and synthesizes the JSON open-meteo would have returned: same
# locations in request order (one object for one location, an array otherwise), the
# requested hours, the requested variable names (`_previous_dayN` suffix included),
# `null` where the exported instance had no value. No fetcher logic changes, so the
# parsed Dicts are identical to the HTTP path's whenever the file holds what the
# instance served (bin/export_weather_vintages.jl writes it from that instance).
#
# Fails loudly (error, never silent nulls) when the request needs a (cell, variable,
# day) the file does not cover, more than one model, or a non-UTC timezone. The ERA5
# archive (`/v1/archive`, load-model fitting) and any other URL pass through to HTTP.
#
# Layout (written by bin/export_weather_vintages.jl):
#   weather_vintages(lat DOUBLE, lon DOUBLE, var VARCHAR, time_utc TIMESTAMP, value DOUBLE)
#       non-null values only; `var` is the requested name, e.g. "temperature_2m_previous_day1"
#   weather_vintages_coverage(lat, lon, var, start_date DATE, end_date DATE)
#       the UTC days exported per cell × variable (an absent row inside a covered
#       range is a null the instance served)
#   weather_vintages_meta(key VARCHAR, value VARCHAR)   -- models, source URL
#
# Included from weather_vintage.jl (itself included more than once): plain function
# definitions and an isdefined-guarded global only, no consts.

using Dates, DuckDB   # `using DuckDB` also brings DBInterface into scope

"The EUPHEMIA_WEATHER_DUCKDB path, or \"\" (HTTP)."
weather_duckdb_path() = strip(get(ENV, "EUPHEMIA_WEATHER_DUCKDB", ""))

isdefined(@__MODULE__, :WEATHER_DUCKDB_STATE) ||
    global WEATHER_DUCKDB_STATE = Dict{String,Any}()   # path => (con, coverage, models)
isdefined(@__MODULE__, :WEATHER_DUCKDB_LOCK) || global WEATHER_DUCKDB_LOCK = ReentrantLock()

"""
    parse_openmeteo_request(url) -> NamedTuple or nothing

Split an open-meteo request URL into (base, path, lats, lons, latstr, lonstr, hourly,
models, start_date, end_date, timezone). `nothing` when the URL has no query. Pure.
"""
function parse_openmeteo_request(url::AbstractString)
    i = findfirst('?', url)
    i === nothing && return nothing
    base = url[1:prevind(url, i)]
    q = Dict{String,String}()
    for kv in split(url[nextind(url, i):end], '&'; keepempty=false)
        k, v = occursin('=', kv) ? split(kv, '='; limit=2) : (kv, "")
        q[String(k)] = String(v)
    end
    latstr = split(get(q, "latitude", ""), ','; keepempty=false)
    lonstr = split(get(q, "longitude", ""), ','; keepempty=false)
    return (base=base, path=String(last(split(base, "://"; limit=2))),
            latstr=String.(latstr), lonstr=String.(lonstr),
            lats=parse.(Float64, latstr), lons=parse.(Float64, lonstr),
            hourly=String.(split(get(q, "hourly", ""), ','; keepempty=false)),
            models=get(q, "models", ""), start_date=get(q, "start_date", ""),
            end_date=get(q, "end_date", ""), timezone=get(q, "timezone", ""))
end

"Whether `weather_duckdb_answer` serves this request (forecast family only). Pure."
is_openmeteo_forecast_request(req) =
    req !== nothing && endswith(req.base, "/v1/forecast")

_wx_num(io, x) = (x === nothing || !isfinite(x)) ? print(io, "null") : print(io, x)

"""
    synthesize_openmeteo_json(lats, lons, vars, hours, value) -> String

The open-meteo JSON body for these locations (request order; one object for one
location, an array otherwise), hourly `time` = `hours` (\"yyyy-mm-ddTHH:MM\") and one
array per name in `vars`; `value(k, var, hour)` returns a Float64 or `nothing` (→ null)
for location index `k`. Floats print in Julia's shortest round-trip form, so
JSON.parse returns the same Float64 that was stored. Pure.
"""
function synthesize_openmeteo_json(lats::AbstractVector, lons::AbstractVector,
                                   vars::AbstractVector, hours::AbstractVector, value)
    io = IOBuffer()
    n = length(lats)
    n > 1 && print(io, '[')
    tstr = join(("\"" * Dates.format(h, "yyyy-mm-ddTHH:MM") * "\"" for h in hours), ',')
    for k in 1:n
        k > 1 && print(io, ',')
        print(io, "{\"latitude\":", lats[k], ",\"longitude\":", lons[k],
              ",\"utc_offset_seconds\":0,\"timezone\":\"GMT\",\"hourly\":{\"time\":[", tstr, ']')
        for v in vars
            print(io, ",\"", v, "\":[")
            for (j, h) in enumerate(hours)
                j > 1 && print(io, ',')
                _wx_num(io, value(k, v, h))
            end
            print(io, ']')
        end
        print(io, "}}")
    end
    n > 1 && print(io, ']')
    return String(take!(io))
end

function _weather_duckdb_state(path::AbstractString)
    get!(WEATHER_DUCKDB_STATE, String(path)) do
        isfile(path) || error("EUPHEMIA_WEATHER_DUCKDB=$path: no such file")
        db = DuckDB.DB(String(path); readonly=true)
        con = DBInterface.connect(db)
        # many backfill workers each open the file: keep every reader's memory small
        # (`SET threads` is refused below the process's external Julia threads)
        DBInterface.execute(con, "SET memory_limit = '" *
            replace(get(ENV, "EUPHEMIA_WEATHER_DUCKDB_MEMORY", "1GB"), "'" => "") * "'")
        cov =Dict{Tuple{Float64,Float64,String},Vector{Tuple{Date,Date}}}()
        for r in Tables_rows(DBInterface.execute(con,
                "SELECT lat, lon, var, start_date, end_date FROM weather_vintages_coverage"))
            push!(get!(Vector{Tuple{Date,Date}}, cov, (Float64(r[1]), Float64(r[2]), String(r[3]))),
                  (Date(r[4]), Date(r[5])))
        end
        meta = Dict{String,String}(String(r[1]) => String(r[2]) for r in Tables_rows(
            DBInterface.execute(con, "SELECT key, value FROM weather_vintages_meta")))
        (con=con, coverage=cov, models=get(meta, "models", "gfs_seamless"))
    end
end

"Rows of a DuckDB result as tuples (no DataFrames dependency here)."
function Tables_rows(res)
    cols = DuckDB.Tables.columns(res)
    names_ = DuckDB.Tables.columnnames(cols)
    vecs = [DuckDB.Tables.getcolumn(cols, nm) for nm in names_]
    return [Tuple(v[i] for v in vecs) for i in 1:(isempty(vecs) ? 0 : length(vecs[1]))]
end

"True when `ranges` (inclusive Date pairs) cover every day of d0..d1. Pure."
function _wx_covers(ranges::AbstractVector, d0::Date, d1::Date)
    for d in d0:Day(1):d1
        any(r -> r[1] <= d <= r[2], ranges) || return false
    end
    return true
end

"""
    weather_duckdb_answer(url) -> String or nothing

`nothing` when EUPHEMIA_WEATHER_DUCKDB is unset or the URL is not an open-meteo
forecast-family request (the caller then does HTTP). Otherwise the synthesized
JSON body from the file, or an error when the file does not cover the request.
"""
function weather_duckdb_answer(url::AbstractString)
    path = weather_duckdb_path()
    isempty(path) && return nothing
    req = parse_openmeteo_request(url)
    is_openmeteo_forecast_request(req) || return nothing
    return lock(WEATHER_DUCKDB_LOCK) do
        st = _weather_duckdb_state(path)
        length(req.lats) == length(req.lons) && !isempty(req.lats) ||
            error("weather duckdb: bad latitude/longitude lists in $url")
        isempty(req.hourly) && error("weather duckdb: no hourly variables in $url")
        req.timezone in ("UTC", "GMT") || error("weather duckdb: timezone must be UTC (got '$(req.timezone)')")
        m = isempty(req.models) ? st.models : req.models
        m == st.models || error("weather duckdb: file holds models=$(st.models); request asks models=$m")
        all(v -> occursin(r"^[a-z0-9_]+$", v), req.hourly) || error("weather duckdb: bad variable list in $url")
        d0, d1 = Date(req.start_date), Date(req.end_date)
        d0 <= d1 || error("weather duckdb: start_date after end_date in $url")
        cells = collect(zip(req.lats, req.lons))
        for c in cells, v in req.hourly
            rs = get(st.coverage, (c[1], c[2], v), nothing)
            (rs !== nothing && _wx_covers(rs, d0, d1)) ||
                error("weather duckdb: $path does not cover $v at $(c) for $d0..$d1 " *
                      "(export it with bin/export_weather_vintages.jl, or unset EUPHEMIA_WEATHER_DUCKDB)")
        end
        hours = collect(DateTime(d0):Hour(1):DateTime(d1) + Hour(23))
        # Cell filter on the URL's own decimal strings, parsed by DuckDB's
        # correctly-rounded string→DOUBLE cast (= Julia's parse): exact equality.
        latin = join(("CAST('" * s * "' AS DOUBLE)" for s in unique(req.latstr)), ",")
        varin = join(("'" * v * "'" for v in req.hourly), ",")
        sql = """SELECT lat, lon, var, time_utc, value FROM weather_vintages
                 WHERE var IN ($varin) AND lat IN ($latin)
                   AND time_utc >= TIMESTAMP '$(d0)' AND time_utc < TIMESTAMP '$(d1 + Day(1))'"""
        vals = Dict{Tuple{Float64,Float64,String},Dict{DateTime,Float64}}()
        want = Set(cells)
        for r in Tables_rows(DBInterface.execute(st.con, sql))
            c = (Float64(r[1]), Float64(r[2]))
            c in want || continue
            get!(Dict{DateTime,Float64}, vals, (c[1], c[2], String(r[3])))[DateTime(r[4])] = Float64(r[5])
        end
        empty_ = Dict{DateTime,Float64}()
        synthesize_openmeteo_json(req.latstr, req.lonstr, req.hourly, hours,
            (k, v, h) -> get(get(vals, (cells[k][1], cells[k][2], v), empty_), h, nothing))
    end
end
