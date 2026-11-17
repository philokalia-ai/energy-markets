# Export the open-meteo weather vintages the forecast's three weather fetchers read into a
# local DuckDB file, so they can be answered offline (EUPHEMIA_WEATHER_DUCKDB, see
# bin/weather_duckdb.jl). Reads a (self-hosted) open-meteo; writes ONLY the output file.
#
#   julia --project=. bin/export_weather_vintages.jl [START [END]]
#
# Env:
#   WEATHER_VINTAGES_OUT   output DuckDB (default data/weather-vintages.duckdb, git-ignored;
#                          created if missing; must not be open by a reader while exporting)
#   WEATHER_VINTAGES_URL   open-meteo forecast-family base of the instance to export
#                          (default EUPHEMIA_OPENMETEO_PREVRUNS_URL; one of the two is
#                          required, so the export never hits the public API by accident)
#   WEATHER_VINTAGES_LAGS  vintage lags, comma-separated (default "1": `_previous_day1`;
#                          "0" = the plain current-run variables)
#   WEATHER_VINTAGES_CHUNK_DAYS  days per chunk / transaction (default 31)
#   WEATHER_VINTAGES_REDO  "nulls" (default): redo logged chunks that had nulls (the
#                          instance may have filled them since) | "none" | "all"
#   WEATHER_VINTAGES_TASKS concurrent requests (default 8)
#   EUPHEMIA_OPENMETEO_MODELS  model (default gfs_seamless; exactly one)
# START/END: UTC days, default 2024-11-13 .. yesterday.
#
# Cells × variables = exactly what the fetchers request (`weather_vintage_cell_vars`):
#   RES pack cells (default pack and v1)  wind_speed_100m, shortwave_radiation   (fetch_weather)
#   ML geom cells                          + cloud_cover, surface_pressure         (fetch_ml_res_weather)
#   load pack cities, ML geom cities       temperature_2m, shortwave_radiation   (fetch_load_weather)
# each with the lag's suffix, queried in ≤50-cell batches with the fetchers' URL shape.
# Resumable: every chunk is one transaction (values + per-cell coverage + a log row);
# a rerun skips logged complete chunks.
using Dates, JSON, DataFrames, DuckDB

isdefined(@__MODULE__, :parse_openmeteo_response) || include(joinpath(@__DIR__, "weather_res.jl"))
isdefined(@__MODULE__, :easter_gregorian) || include(joinpath(@__DIR__, "weather_load.jl"))
isdefined(@__MODULE__, :ml_geom) || include(joinpath(@__DIR__, "ml_inputs.jl"))

const WX_RES_VARS = ["wind_speed_100m", "shortwave_radiation"]
const WX_ML_VARS = ML_RES_VARS
const WX_LOAD_VARS = ["temperature_2m", "shortwave_radiation"]

"""
    weather_vintage_cell_vars() -> Dict{(lat, lon), Vector{String}}

Every (lat, lon) the RES pack, load pack and ML-input fetchers request, with the base
variables each requests there (no vintage suffix), from the same pack files the
fetchers load.
"""
function weather_vintage_cell_vars(; res_paths=unique(filter(isfile, [default_res_models_path(), RES_MODELS_PATH_V1])),
                                     load_path=default_load_models_path(), geom=ml_geom())
    cv = Dict{Tuple{Float64,Float64},Set{String}}()
    add!(c, vars) = union!(get!(Set{String}, cv, (Float64(c[1]), Float64(c[2]))), vars)
    for p in res_paths, (_, z) in JSON.parsefile(p)["zones"], c in z["cells"]
        add!(c, WX_RES_VARS)
    end
    for (_, z) in JSON.parsefile(load_path)["zones"], c in z["cities"]
        add!(c, WX_LOAD_VARS)
    end
    for (_, z) in geom
        foreach(c -> add!(c, WX_ML_VARS), z["cells"])
        foreach(c -> add!(c, WX_LOAD_VARS), z["cities"])
    end
    return Dict(c => sort(collect(v)) for (c, v) in cv)
end

"Batches of ≤`n` cells sharing one variable set, in a stable order. Pure."
function weather_vintage_batches(cv::AbstractDict, n::Int=50)
    groups = Dict{Vector{String},Vector{Tuple{Float64,Float64}}}()
    for (c, vs) in cv
        push!(get!(Vector{Tuple{Float64,Float64}}, groups, vs), c)
    end
    out = Tuple{Vector{String},Vector{Tuple{Float64,Float64}}}[]
    for vs in sort(collect(keys(groups))), cs in Iterators.partition(sort(groups[vs]), n)
        push!(out, (vs, collect(cs)))
    end
    return out
end

"The fetchers' URL shape for one batch. Pure."
weather_vintage_url(base, cells, vars, d0::Date, d1::Date, models) =
    base * "?latitude=" * join((string(c[1]) for c in cells), ",") *
    "&longitude=" * join((string(c[2]) for c in cells), ",") *
    "&hourly=" * join(vars, ",") * "&models=" * models *
    "&start_date=" * Dates.format(d0, "yyyy-mm-dd") *
    "&end_date=" * Dates.format(d1, "yyyy-mm-dd") * "&timezone=UTC"

"""
    weather_vintage_rows(body, cells, vars, hours) -> (lat, lon, var, time_utc, value, n_null)

Long rows of one open-meteo answer (non-null values only, as the JSON's Float64) and the
number of null cell-var-hours. Errors when the answer's shape or hours differ from the
request. Pure.
"""
function weather_vintage_rows(body::AbstractString, cells, vars, hours)
    parsed = JSON.parse(String(body))
    locs = parsed isa AbstractVector ? parsed : [parsed]
    length(locs) == length(cells) || error("open-meteo returned $(length(locs)) locations for $(length(cells)) cells")
    lat = Float64[]; lon = Float64[]; var = String[]; t = DateTime[]; val = Float64[]
    nnull = 0
    for (c, loc) in zip(cells, locs)
        hb = loc["hourly"]
        times = [DateTime(String(s), dateformat"yyyy-mm-ddTHH:MM") for s in hb["time"]]
        times == hours || error("open-meteo answered hours $(first(times))..$(last(times)) for $(first(hours))..$(last(hours))")
        for v in vars
            arr = get(hb, v, nothing)
            arr === nothing && error("open-meteo answer lacks variable $v")
            for (i, h) in enumerate(hours)
                x = arr[i]
                if x === nothing
                    nnull += 1
                else
                    push!(lat, c[1]); push!(lon, c[2]); push!(var, v); push!(t, h); push!(val, Float64(x))
                end
            end
        end
    end
    return (lat=lat, lon=lon, var=var, time_utc=t, value=val, n_null=nnull)
end

function weather_vintages_schema!(con)
    for s in ("CREATE TABLE IF NOT EXISTS weather_vintages (lat DOUBLE, lon DOUBLE, var VARCHAR, time_utc TIMESTAMP, value DOUBLE)",
              "CREATE TABLE IF NOT EXISTS weather_vintages_coverage (lat DOUBLE, lon DOUBLE, var VARCHAR, start_date DATE, end_date DATE)",
              "CREATE TABLE IF NOT EXISTS weather_vintages_meta (key VARCHAR, value VARCHAR)",
              "CREATE TABLE IF NOT EXISTS weather_vintages_chunks (start_date DATE, end_date DATE, lag INTEGER, n_cells INTEGER, n_cellvars INTEGER, n_values BIGINT, n_null BIGINT, source VARCHAR, finished_at TIMESTAMP)")
        DBInterface.execute(con, s)
    end
end

"""
    write_weather_chunk!(con, d0, d1, lag, sfx_vars, rows, cellvars; source, models)

One chunk as ONE transaction: replace the values of these variables in d0..d1, replace
the coverage of these variables overlapping d0..d1 (a partly overlapped older range is
dropped whole: those days read as uncovered, i.e. a loud error, never as nulls), and log.
"""
function write_weather_chunk!(con, d0::Date, d1::Date, lag::Int, sfx_vars::AbstractVector,
                              rows, cellvars::AbstractVector; source::AbstractString, models::AbstractString)
    varin = join(("'" * v * "'" for v in sfx_vars), ",")
    df = DataFrame(lat=rows.lat, lon=rows.lon, var=rows.var, time_utc=rows.time_utc, value=rows.value)
    cov = DataFrame(lat=[c[1] for c in cellvars], lon=[c[2] for c in cellvars], var=[c[3] for c in cellvars],
                    start_date=fill(d0, length(cellvars)), end_date=fill(d1, length(cellvars)))
    DBInterface.execute(con, "BEGIN TRANSACTION")
    try
        DBInterface.execute(con, """DELETE FROM weather_vintages WHERE var IN ($varin)
            AND time_utc >= TIMESTAMP '$d0' AND time_utc < TIMESTAMP '$(d1 + Day(1))'""")
        DBInterface.execute(con, """DELETE FROM weather_vintages_coverage WHERE var IN ($varin)
            AND start_date <= DATE '$d1' AND end_date >= DATE '$d0'""")
        DBInterface.execute(con, "DELETE FROM weather_vintages_chunks WHERE lag = $lag AND start_date = DATE '$d0' AND end_date = DATE '$d1'")
        DuckDB.register_data_frame(con, df, "wx_chunk")
        DuckDB.register_data_frame(con, cov, "wx_cov")
        DBInterface.execute(con, "INSERT INTO weather_vintages SELECT * FROM wx_chunk ORDER BY var, time_utc, lat, lon")
        DBInterface.execute(con, "INSERT INTO weather_vintages_coverage SELECT * FROM wx_cov")
        DuckDB.unregister_data_frame(con, "wx_chunk")
        DuckDB.unregister_data_frame(con, "wx_cov")
        DBInterface.execute(con, """INSERT INTO weather_vintages_chunks VALUES (DATE '$d0', DATE '$d1', $lag,
            $(length(unique((c[1], c[2]) for c in cellvars))), $(length(cellvars)), $(length(rows.value)),
            $(rows.n_null), '$(replace(source, "'" => "''"))', now()::TIMESTAMP)""")
        DBInterface.execute(con, "DELETE FROM weather_vintages_meta WHERE key = 'models'")
        DBInterface.execute(con, "INSERT INTO weather_vintages_meta VALUES ('models', '$models')")
        DBInterface.execute(con, "COMMIT")
    catch
        try DBInterface.execute(con, "ROLLBACK") catch end
        rethrow()
    end
end

"Fetch one chunk (all batches, `ntasks` concurrent) → merged rows. Network only."
function fetch_weather_chunk(base, batches, sfx, d0, d1, models; ntasks::Int=8, get_fn=_openmeteo_get)
    hours = openmeteo_request_hours(d0, d1)
    parts = asyncmap(batches; ntasks=ntasks) do (vs, cells)
        vars = [v * sfx for v in vs]
        weather_vintage_rows(get_fn(weather_vintage_url(base, cells, vars, d0, d1, models)), cells, vars, hours)
    end
    cat(f) = reduce(vcat, (getfield(p, f) for p in parts))
    return (lat=cat(:lat), lon=cat(:lon), var=cat(:var), time_utc=cat(:time_utc), value=cat(:value),
            n_null=sum(p.n_null for p in parts))
end

function export_weather_vintages(start::Date, stop::Date;
                                 out=get(ENV, "WEATHER_VINTAGES_OUT", joinpath(dirname(@__DIR__), "data", "weather-vintages.duckdb")),
                                 base=get(ENV, "WEATHER_VINTAGES_URL", get(ENV, "EUPHEMIA_OPENMETEO_PREVRUNS_URL", "")),
                                 lags=parse.(Int, split(get(ENV, "WEATHER_VINTAGES_LAGS", "1"), ',')),
                                 chunk_days=parse(Int, get(ENV, "WEATHER_VINTAGES_CHUNK_DAYS", "31")),
                                 redo=get(ENV, "WEATHER_VINTAGES_REDO", "nulls"),
                                 ntasks=parse(Int, get(ENV, "WEATHER_VINTAGES_TASKS", "8")),
                                 models=get(ENV, "EUPHEMIA_OPENMETEO_MODELS", "gfs_seamless"))
    isempty(base) && error("set WEATHER_VINTAGES_URL (or EUPHEMIA_OPENMETEO_PREVRUNS_URL) to the open-meteo instance to export")
    occursin(',', models) && error("export one model at a time (got models=$models)")
    redo in ("nulls", "none", "all") || error("WEATHER_VINTAGES_REDO must be nulls|none|all")
    all(l -> 0 <= l <= 7, lags) || error("lags must be 0..7")
    delete!(ENV, "EUPHEMIA_WEATHER_DUCKDB")   # never answer the export from a file
    cv = weather_vintage_cell_vars()
    batches = weather_vintage_batches(cv)
    println("EXPORT cells=$(length(cv)) cell-vars=$(sum(length, values(cv))) batches/chunk=$(length(batches)) " *
            "lags=$lags $start..$stop chunk=$(chunk_days)d -> $out (source $base, models=$models)")
    db = DuckDB.DB(out)
    con = DBInterface.connect(db)
    weather_vintages_schema!(con)
    done = DataFrame(DBInterface.execute(con, "SELECT start_date, end_date, lag, n_null FROM weather_vintages_chunks"))
    try
        for lag in lags
            sfx = lag > 0 ? "_previous_day$lag" : ""
            cellvars = [(c[1], c[2], v * sfx) for (c, vs) in sort(collect(cv)) for v in vs]
            sfx_vars = sort(unique(c[3] for c in cellvars))
            d0 = start
            while d0 <= stop
                d1 = min(d0 + Day(chunk_days - 1), stop)
                prev = done[(Date.(done.start_date) .== d0) .& (Date.(done.end_date) .== d1) .& (done.lag .== lag), :]
                if !isempty(prev) && (redo == "none" || (redo == "nulls" && prev.n_null[1] == 0))
                    println("  skip $d0..$d1 lag $lag (logged, n_null=$(prev.n_null[1]))")
                else
                    t = time()
                    rows = fetch_weather_chunk(base, batches, sfx, d0, d1, models; ntasks)
                    write_weather_chunk!(con, d0, d1, lag, sfx_vars, rows, cellvars; source=base, models)
                    n = length(rows.value)
                    println("  $d0..$d1 lag $lag: values=$n null=$(rows.n_null) " *
                            "($(round(100 * rows.n_null / max(n + rows.n_null, 1), digits=2))%) in $(round(time() - t, digits=1)) s")
                end
                flush(stdout)
                d0 = d1 + Day(1)
            end
        end
    finally
        DBInterface.close!(con)
        DuckDB.close(db)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    start = isempty(ARGS) ? Date(2024, 11, 13) : Date(ARGS[1])
    stop = length(ARGS) < 2 ? Date(now(UTC)) - Day(1) : Date(ARGS[2])
    export_weather_vintages(start, stop)
end
