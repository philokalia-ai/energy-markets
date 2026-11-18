# EUPHEMIA_WEATHER_DUCKDB shim (bin/weather_duckdb.jl) + the exporter's pure parts
# (bin/export_weather_vintages.jl). A temp DuckDB built from literal open-meteo JSON; no
# network (the end-to-end fetch points at an unreachable URL), no extract, no DB.
#   julia --project=. test/test_weather_duckdb.jl

using Test, Dates, JSON, DuckDB

isdefined(@__MODULE__, :parse_openmeteo_response) ||
    include(joinpath(@__DIR__, "..", "bin", "weather_res.jl"))
isdefined(@__MODULE__, :easter_gregorian) ||
    include(joinpath(@__DIR__, "..", "bin", "weather_load.jl"))
isdefined(@__MODULE__, :parse_lgb_model) ||
    include(joinpath(@__DIR__, "..", "bin", "ml_inputs.jl"))
isdefined(@__MODULE__, :weather_vintage_cell_vars) ||
    include(joinpath(@__DIR__, "..", "bin", "export_weather_vintages.jl"))

# An open-meteo previous-runs body: 3 cells, 2 days, five variables, with nulls, ints and
# values that are not exact binary fractions.
const WXT_CELLS = [(63.5252, 15.1821), (38.3704, 23.0157), (40.42, -3.7)]
const WXT_HOURS = collect(DateTime(2026, 9, 13):Hour(1):DateTime(2026, 9, 14, 23))
const WXT_VARS = ["wind_speed_100m_previous_day1", "shortwave_radiation_previous_day1",
                  "cloud_cover_previous_day1", "surface_pressure_previous_day1",
                  "temperature_2m_previous_day1"]
function wxt_value(k, v, i)
    (k == 2 && i in (3, 4)) && return nothing                            # cell 2: two null hours
    (k == 3 && v == "cloud_cover_previous_day1" && i == 10) && return nothing
    v == "cloud_cover_previous_day1" && return 7 * i % 101                # JSON ints
    v == "shortwave_radiation_previous_day1" && return i < 6 ? 0 : 0.1 * i + 0.3
    return 963.3 + k + i / 7
end
function wxt_body()
    io = IOBuffer()
    print(io, '[')
    for (k, c) in enumerate(WXT_CELLS)
        k > 1 && print(io, ',')
        print(io, "{\"latitude\":", c[1] + 0.01, ",\"longitude\":", c[2] - 0.02, ",\"elevation\":12.0,",
              "\"hourly_units\":{},\"hourly\":{\"time\":[",
              join(("\"" * Dates.format(h, "yyyy-mm-ddTHH:MM") * "\"" for h in WXT_HOURS), ','), ']')
        for v in WXT_VARS
            vals = [wxt_value(k, v, i) for i in eachindex(WXT_HOURS)]
            print(io, ",\"", v, "\":[", join((x === nothing ? "null" : JSON.json(x) for x in vals), ','), ']')
        end
        print(io, "}}")
    end
    print(io, ']')
    return String(take!(io))
end
url(base, cells, vars; d0="2026-09-13", d1="2026-09-14", models="gfs_seamless", tz="UTC") =
    base * "?latitude=" * join((string(c[1]) for c in cells), ",") *
    "&longitude=" * join((string(c[2]) for c in cells), ",") * "&hourly=" * join(vars, ",") *
    "&models=" * models * "&start_date=" * d0 * "&end_date=" * d1 * "&timezone=" * tz

@testset "EUPHEMIA_WEATHER_DUCKDB shim" begin
    dir = mktempdir()
    path = joinpath(dir, "wx.duckdb")
    body = wxt_body()
    rows = weather_vintage_rows(body, WXT_CELLS, WXT_VARS, WXT_HOURS)
    @test rows.n_null == 2 * length(WXT_VARS) + 1                        # 2 null hours × 5 vars + 1
    @test length(rows.value) == length(WXT_CELLS) * length(WXT_VARS) * length(WXT_HOURS) - 11
    cellvars = [(c[1], c[2], v) for c in WXT_CELLS for v in WXT_VARS]
    let db = DuckDB.DB(path), con = DBInterface.connect(db)
        weather_vintages_schema!(con)
        for _ in 1:2   # a rerun of the same chunk replaces it (resumable, idempotent)
            write_weather_chunk!(con, Date(2026, 9, 13), Date(2026, 9, 14), 1, WXT_VARS, rows, cellvars;
                                 source="test", models="gfs_seamless")
        end
        n = only(only(DBInterface.execute(con, "SELECT count(*) FROM weather_vintages")))
        @test n == length(rows.value)
        @test only(only(DBInterface.execute(con, "SELECT count(*) FROM weather_vintages_chunks"))) == 1
        DBInterface.close!(con); DuckDB.close(db)
    end

    local_base = "http://localhost:30555/v1/forecast"
    withenv("EUPHEMIA_WEATHER_DUCKDB" => path) do
        res_vars = ["wind_speed_100m_previous_day1", "shortwave_radiation_previous_day1"]
        ml_vars = ["wind_speed_100m", "shortwave_radiation", "cloud_cover", "surface_pressure"] .* "_previous_day1"
        load_vars = ["temperature_2m_previous_day1", "shortwave_radiation_previous_day1"]
        sfx = "_previous_day1"

        # the three fetchers' parsers see the same Dicts as from the HTTP body
        a = weather_duckdb_answer(url(local_base, WXT_CELLS, res_vars))
        @test parse_openmeteo_response(a, WXT_CELLS; var_suffix=sfx) ==
              parse_openmeteo_response(body, WXT_CELLS; var_suffix=sfx)
        a = weather_duckdb_answer(url(local_base, WXT_CELLS, ml_vars))
        @test parse_ml_res_response(a, WXT_CELLS, sfx) == parse_ml_res_response(body, WXT_CELLS, sfx)
        a = weather_duckdb_answer(url(local_base, WXT_CELLS, load_vars))
        @test parse_load_weather_response(a, WXT_CELLS; var_suffix=sfx) ==
              parse_load_weather_response(body, WXT_CELLS; var_suffix=sfx)
        # ... including a sub-range of days and the public URL of the same family
        a = weather_duckdb_answer(url("https://previous-runs-api.open-meteo.com/v1/forecast",
                                      WXT_CELLS, res_vars; d0="2026-09-14"))
        p = parse_openmeteo_response(a, WXT_CELLS; var_suffix=sfx)
        @test all(h -> Date(h) == Date(2026, 9, 14), keys(p[WXT_CELLS[1]])) && length(p[WXT_CELLS[1]]) == 24

        # raw shape: nulls, values, multi vs single location, requested names/order
        j = JSON.parse(weather_duckdb_answer(url(local_base, WXT_CELLS, ml_vars)))
        @test j isa AbstractVector && length(j) == 3
        @test j[2]["hourly"]["wind_speed_100m_previous_day1"][3] === nothing
        @test j[3]["hourly"]["cloud_cover_previous_day1"][10] === nothing
        @test j[1]["hourly"]["surface_pressure_previous_day1"][1] == 963.3 + 1 + 1 / 7
        @test j[1]["hourly"]["time"][1] == "2026-09-13T00:00" && length(j[1]["hourly"]["time"]) == 48
        @test (j[1]["latitude"], j[1]["longitude"]) == WXT_CELLS[1]
        one = JSON.parse(weather_duckdb_answer(url(local_base, WXT_CELLS[2:2], res_vars)))
        @test one isa AbstractDict && one["longitude"] == WXT_CELLS[2][2]
        rev = reverse(WXT_CELLS)
        @test parse_openmeteo_response(weather_duckdb_answer(url(local_base, rev, res_vars)), rev; var_suffix=sfx) ==
              parse_openmeteo_response(body, WXT_CELLS; var_suffix=sfx)

        # loud failures: suffix/vintage, cell, day, model, timezone not in the file
        @test_throws ErrorException weather_duckdb_answer(url(local_base, WXT_CELLS, ["wind_speed_100m"]))
        @test_throws ErrorException weather_duckdb_answer(url(local_base, WXT_CELLS, ["wind_speed_100m_previous_day2"]))
        @test_throws ErrorException weather_duckdb_answer(url(local_base, [(1.0, 2.0)], res_vars))
        @test_throws ErrorException weather_duckdb_answer(url(local_base, WXT_CELLS, res_vars; d1="2026-09-15"))
        @test_throws ErrorException weather_duckdb_answer(url(local_base, WXT_CELLS, res_vars; models="gfs_seamless,icon_seamless"))
        @test_throws ErrorException weather_duckdb_answer(url(local_base, WXT_CELLS, res_vars; tz="Europe/Athens"))

        # not intercepted: the ERA5 archive (fit time) and non-open-meteo URLs
        @test weather_duckdb_answer(replace(url(local_base, WXT_CELLS, res_vars), "/v1/forecast" => "/v1/archive")) === nothing
        @test weather_duckdb_answer("http://example.invalid/data.json") === nothing

        # end to end through the real fetchers, primary unreachable → answered from the file
        withenv("EUPHEMIA_OPENMETEO_PREVRUNS_URL" => "http://127.0.0.1:9/v1/forecast",
                "EUPHEMIA_OPENMETEO_GAPFILL" => "0") do
            days = [Date(2026, 9, 13), Date(2026, 9, 14)]
            @test fetch_weather(WXT_CELLS, days; vintage_lag=1) ==
                  parse_openmeteo_response(body, WXT_CELLS; var_suffix=sfx)
            @test fetch_ml_res_weather(WXT_CELLS, days; vintage_lag=1) == parse_ml_res_response(body, WXT_CELLS, sfx)
            @test fetch_load_weather(WXT_CELLS, days; vintage_lag=1) ==
                  parse_load_weather_response(body, WXT_CELLS; var_suffix=sfx)
        end
    end
    # flag unset: no interception
    withenv("EUPHEMIA_WEATHER_DUCKDB" => nothing) do
        @test weather_duckdb_answer(url(local_base, WXT_CELLS, ["x_previous_day1"])) === nothing
    end
end

@testset "weather vintage export: cells, batches, URL" begin
    cv = weather_vintage_cell_vars()
    res = load_res_models()["zones"]; ld = load_load_models()["zones"]; g = ml_geom()
    @test all(c -> "wind_speed_100m" in cv[(Float64(c[1]), Float64(c[2]))], (c for z in values(res) for c in z["cells"]))
    @test all(c -> "temperature_2m" in cv[(Float64(c[1]), Float64(c[2]))], (c for z in values(ld) for c in z["cities"]))
    @test all(c -> "surface_pressure" in cv[(Float64(c[1]), Float64(c[2]))], (c for z in values(g) for c in z["cells"]))
    b = weather_vintage_batches(cv)
    @test all(x -> 1 <= length(x[2]) <= 50, b)
    @test sum(length(x[2]) for x in b) == length(cv)
    @test sort(reduce(vcat, [x[2] for x in b])) == sort(collect(keys(cv)))
    # the exporter's URL is the fetchers' URL shape (what the shim parses back)
    u = weather_vintage_url("http://h/v1/forecast", WXT_CELLS, ["a_previous_day1"], Date(2026, 9, 13), Date(2026, 9, 14), "gfs_seamless")
    r = parse_openmeteo_request(u)
    @test collect(zip(r.lats, r.lons)) == WXT_CELLS && r.hourly == ["a_previous_day1"] &&
          r.start_date == "2026-09-13" && r.end_date == "2026-09-14" && r.timezone == "UTC"
end

# The exporter's resume decisions, through the real exporter with a one-cell stub server
# (review of #459: a resume with another model, and an overlapping refill, must not skip).
@testset "weather vintage export: resume identity" begin
    calls = String[]
    stub(u) = begin
        push!(calls, u)
        r = parse_openmeteo_request(u)
        hs = openmeteo_request_hours(Date(r.start_date), Date(r.end_date))
        synthesize_openmeteo_json(r.latstr, r.lonstr, r.hourly, hs,
            (k, v, h) -> r.models == "gfs_seamless" ? 10.0 : 20.0)
    end
    base = "http://127.0.0.1:9/v1/forecast"
    one = Dict((48.0, 17.0) => ["temperature_2m"])
    run_(p, a, b; kw...) = redirect_stdout(devnull) do
        export_weather_vintages(Date(a), Date(b); out=p, base=base, ntasks=1, lags=[1],
                                get_fn=stub, kw...)
    end
    q(p, sql) = let db = DuckDB.DB(p; readonly=true), con = DBInterface.connect(db)
        try Tables_rows(DBInterface.execute(con, sql)) finally DBInterface.close!(con); DuckDB.close(db) end
    end
    dir = mktempdir()
    # 1. resume with another model: refused before anything is fetched or written
    p = joinpath(dir, "models.duckdb")
    run_(p, "2026-09-13", "2026-09-15"; chunk_days=2, models="gfs_seamless", cell_vars=one)
    empty!(calls)
    @test_throws ErrorException run_(p, "2026-09-13", "2026-09-16"; chunk_days=2,
                                     models="icon_seamless", cell_vars=one)
    @test isempty(calls)
    @test q(p, "SELECT value FROM weather_vintages_meta WHERE key='models'") == [("gfs_seamless",)]
    @test q(p, "SELECT DISTINCT value FROM weather_vintages") == [(10.0,)]
    # same model resumes normally: logged complete chunks skipped, the new tail fetched
    run_(p, "2026-09-13", "2026-09-16"; chunk_days=2, models="gfs_seamless", cell_vars=one)
    @test length(calls) == 1 && occursin("start_date=2026-09-15", calls[1])
    # 2. a changed footprint (an added cell) refetches the logged chunk
    empty!(calls)
    two = Dict((48.0, 17.0) => ["temperature_2m"], (50.0, 10.0) => ["temperature_2m"])
    run_(p, "2026-09-13", "2026-09-14"; chunk_days=2, cell_vars=two)
    @test length(calls) == 1
    @test q(p, "SELECT count(*) FROM weather_vintages_coverage WHERE lat = 50.0") == [(1,)]
    # 3. an overlapping refill: the full-window rerun repairs the dropped coverage
    p = joinpath(dir, "overlap.duckdb")
    run_(p, "2026-09-13", "2026-09-15"; chunk_days=3, cell_vars=one)
    run_(p, "2026-09-14", "2026-09-14"; chunk_days=1, redo="all", cell_vars=one)
    @test q(p, "SELECT count(*) FROM weather_vintages_chunks") == [(1,)]   # the 3-day log is gone
    empty!(calls)
    run_(p, "2026-09-13", "2026-09-15"; chunk_days=3, cell_vars=one)
    @test length(calls) == 1
    @test q(p, "SELECT count(*) FROM weather_vintages") == [(72,)]
    withenv("EUPHEMIA_WEATHER_DUCKDB" => p) do
        u = weather_vintage_url(base, [(48.0, 17.0)], ["temperature_2m_previous_day1"],
                                Date(2026, 9, 13), Date(2026, 9, 15), "gfs_seamless")
        @test JSON.parse(weather_duckdb_answer(u))["hourly"]["temperature_2m_previous_day1"] == fill(10.0, 72)
    end
    # a further rerun skips (logged and covered)
    empty!(calls)
    run_(p, "2026-09-13", "2026-09-15"; chunk_days=3, cell_vars=one)
    @test isempty(calls)
    for st in values(WEATHER_DUCKDB_STATE)
        DBInterface.close!(st.con)
    end
    empty!(WEATHER_DUCKDB_STATE)
    GC.gc()
    rm(dir; recursive=true, force=true)
end
