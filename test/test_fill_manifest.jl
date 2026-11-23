# Fill manifest + strict read guard (src/db/fill_manifest.jl, src/db/duckdb_store.jl).
# DB-free for Postgres: the generated Postgres SQL is checked as text; the guard runs on a
# throw-away DuckDB that carries a synthetic `_fill.windows`.
#
# Standalone:  julia --project=. test/test_fill_manifest.jl

using Test, Dates, Euphemia, DataFrames
using DuckDB
import DuckDB.DBInterface as DBInterface

@testset "fill manifest: windows and Postgres SQL" begin
    E = Euphemia
    # union of [d - back, d + ahead + 1), merged
    @test E.fill_windows([Date(2026, 1, 10), Date(2026, 1, 12)], 3, 0) ==
          [(Date(2026, 1, 7), Date(2026, 1, 13))]
    @test E.fill_windows([Date(2026, 1, 10), Date(2026, 3, 1)], 3, 1) ==
          [(Date(2026, 1, 7), Date(2026, 1, 12)), (Date(2026, 2, 26), Date(2026, 3, 3))]

    spec(t) = only(filter(s -> s.table == t, E.FILL_SPECS))
    cols = [("date_time_utc", "timestamp with time zone"), ("area_map_code", "text"), ("mw", "double precision")]
    sql, w = E.fill_pg_query(spec("day_ahead_total_load_forecast"), cols, [Date(2026, 1, 10)], ["GR", "BG"])
    @test w == [(Date(2025, 12, 10), Date(2026, 1, 13))]
    @test occursin("\"date_time_utc\" AT TIME ZONE 'UTC' AS \"date_time_utc\"", sql)
    @test occursin("area_map_code = ANY(ARRAY['GR', 'BG']::text[])", sql)
    @test occursin("date_time_utc >= ('2025-12-10'::date::timestamp AT TIME ZONE 'UTC')", sql)
    @test occursin("date_time_utc < ('2026-01-13'::date::timestamp AT TIME ZONE 'UTC')", sql)

    # interval tables: overlap with the run span, text timestamps cast
    tcols = [("start_outage_utc", "text"), ("end_outage_utc", "text"), ("new_ntc_mw", "double precision"),
             ("version_publication_timestamp_utc", "text")]
    sql, w = E.fill_pg_query(spec("unavailability_in_the_transmission_grid"), tcols, [Date(2026, 1, 10)], ["GR"])
    @test occursin("instance_code IN (SELECT instance_code FROM entsoe.unavailability_in_the_transmission_grid", sql)
    @test occursin("\"start_outage_utc\"::TIMESTAMP AS \"start_outage_utc\"", sql)
    @test occursin("\"start_outage_utc\"::timestamp < '2026-01-12'::timestamp", sql)   # [d-1, d+2)
    @test occursin("\"end_outage_utc\"::timestamp >= '2026-01-09'::timestamp", sql)

    # offered implicit ATC: + earliest Day-ahead row per border before the window
    acols = [("out_map_code", "text"), ("in_map_code", "text"), ("date_time_utc", "timestamp with time zone"),
             ("contract_type", "text"), ("capacity_mw", "double precision")]
    sql, _ = E.fill_pg_query(spec("offered_transfer_capacities_implicit"), acols, [Date(2026, 1, 10)], ["GR"])
    @test occursin("UNION ALL SELECT * FROM (SELECT DISTINCT ON (out_map_code, in_map_code)", sql)
    @test occursin("contract_type = 'Day-ahead' AND date_time_utc < ('2025-12-10'::date", sql)

    # per-unit generation: stale-feed zones extend below the common window
    pcols = [("generation_unit_code", "text"), ("date_time_utc", "timestamp with time zone"),
             ("actual_generation_output_mw", "double precision")]
    sql, w = E.fill_pg_query(spec("actual_generation_output_per_generation_unit"), pcols,
                             [Date(2026, 9, 20)], ["IT-NORTH", "GR"]; stale_lo=Dict("IT-NORTH" => Date(2026, 5, 19)))
    @test w == [(Date(2026, 7, 7), Date(2026, 9, 21))]
    @test occursin("area_map_code = 'IT-NORTH') AND date_time_utc >= ('2026-05-19'", sql)

    # profiles: retro = UTC days S-1..E + forecast extras; rescore = actual prices only
    z = ["GR", "BG"]
    r = E.fill_profile(:retro; start=Date(2026, 3, 10), stop=Date(2026, 3, 12), zones=z)
    @test r.days == collect(Date(2026, 3, 9):Day(1):Date(2026, 3, 12))
    @test any(s -> s.table == "uka_price", r.specs) && any(s -> s.table == "physical_flows", r.specs)
    @test [sd.table for sd in r.seeds] == ["forecast_prices", "forecast_scores", "input_corrections"]
    @test occursin("market_date BETWEEN '2026-03-10'::date AND '2026-03-12'::date", r.seeds[1].where)
    q = E.fill_profile(:rescore; start=Date(2026, 3, 10), stop=Date(2026, 3, 12), zones=z)
    @test [s.table for s in q.specs] == ["energy_prices"]
    @test occursin("bidding_zone = ANY(ARRAY['GR', 'BG']::text[])", q.seeds[1].where)
    @test q.seeds[2] == (table="forecast_scores", where="")
    @test_throws ErrorException E.fill_profile(:retro; zones=z)
    # record with a day list covers exactly the listed days' windows
    rl = E.fill_profile(:record; zones=z, days_list=[Date(2026, 1, 10), Date(2026, 3, 1)])
    @test rl.days == [Date(2026, 1, 10), Date(2026, 3, 1)]

    # quotes in zone codes cannot break out of the literal
    @test E._pg_zones(["A'B"]) == "ARRAY['A''B']::text[]"
end

@testset "fill guard: strict reads on a run-local DuckDB" begin
    E = Euphemia
    prev = (E.DATA_STORE[], E.DUCKDB_PATH[], E.DUCKDB_READ_ONLY[], E.DUCKDB_RESULTS_WRITABLE[])
    dir = mktempdir()
    path = joinpath(dir, "run.duckdb")
    let db = DuckDB.DB(path), con = DBInterface.connect(db)
        x(s) = DBInterface.execute(con, s)
        x("CREATE SCHEMA entsoe"); x("CREATE SCHEMA _fill")
        x("CREATE TABLE entsoe.day_ahead_total_load_forecast (area_map_code VARCHAR, date_time_utc TIMESTAMP, mw DOUBLE)")
        x("INSERT INTO entsoe.day_ahead_total_load_forecast VALUES ('GR', TIMESTAMP '2026-01-10 05:00:00', 5000.0)")
        x("CREATE TABLE entsoe.production_and_generation_units (area_map_code VARCHAR, generation_unit_code VARCHAR)")
        x("CREATE TABLE _fill.windows (schema_name VARCHAR, table_name VARCHAR, kind VARCHAR, lo DATE, hi DATE, n_rows BIGINT, seconds DOUBLE)")
        x("INSERT INTO _fill.windows VALUES ('entsoe', 'day_ahead_total_load_forecast', 'window', DATE '2025-12-10', DATE '2026-01-13', 1, 0.0)")
        x("INSERT INTO _fill.windows VALUES ('entsoe', 'production_and_generation_units', 'full', DATE '1900-01-01', DATE '2999-12-31', 0, 0.0)")
        DBInterface.close!(con); DuckDB.close(db)
    end
    try
        E.configure_data_store!(backend=:duckdb, duckdb_path=path, read_only=true)
        q = "SELECT mw FROM entsoe.day_ahead_total_load_forecast WHERE area_map_code = \$1 AND date_time_utc >= \$2"
        @test E.sql2df(q, Any["GR", Date(2026, 1, 10)]).mw == [5000.0]            # inside the window
        @test_throws E.FillGuardError E.sql2df(q, Any["GR", Date(2026, 2, 1)])         # outside → loud
        @test_throws E.FillGuardError E.sql2df("SELECT * FROM entsoe.physical_flows")  # not in manifest → loud
        # never retried as transient, never swallowed by sql2df_with_retry
        @test_throws E.FillGuardError E.sql2df_with_retry("SELECT * FROM entsoe.physical_flows"; retry_delay=0.0)
        @test nrow(E.sql2df("SELECT * FROM entsoe.production_and_generation_units WHERE area_map_code = \$1",
                            Any["GR"])) == 0                                         # full table: any date ok
        @test_throws E.FillGuardError E.sql2df(
            "SELECT * FROM entsoe.day_ahead_total_load_forecast WHERE date_time_utc < TIMESTAMP '2027-01-01 00:00:00'")
        # the guard only covers the run-local inputs, never results_db.*
        g = E._FILL_GUARD[]
        @test g !== nothing
        @test E._fill_guard_check(g, "SELECT * FROM results_db.simulations.energy_prices", Any[Date(2030, 1, 1)]) === nothing
    finally
        try; E.configure_data_store!(backend=prev[1], duckdb_path=prev[2], read_only=prev[3], results_writable=prev[4]); catch; end
    end
end

"The seed marker seed_run_results! writes into a results DB (results_db._fill.seeds)."
function mark_seeded(path, table; lo=Date(1900, 1, 1), hi=Date(2999, 12, 31))
    db = DuckDB.DB(path); con = DBInterface.connect(db)
    DBInterface.execute(con, "CREATE SCHEMA IF NOT EXISTS _fill")
    DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS _fill.seeds (table_name VARCHAR, lo DATE, hi DATE, n_rows BIGINT)")
    DBInterface.execute(con, "INSERT INTO _fill.seeds VALUES (?, ?, ?, 1)", Any[table, lo, hi])
    DBInterface.close!(con); DuckDB.close(db)
end

@testset "read-back redirect only in a fill; writes always to results_db" begin
    E = Euphemia
    prev = (E.DATA_STORE[], E.DUCKDB_PATH[], E.DUCKDB_READ_ONLY[], E.DUCKDB_RESULTS_WRITABLE[], E.RESULTS_DB_PATH[])
    dir = mktempdir()
    mk(path, v) = let db = DuckDB.DB(path), con = DBInterface.connect(db)
        DBInterface.execute(con, "CREATE SCHEMA simulations")
        DBInterface.execute(con, "CREATE TABLE simulations.input_corrections (target VARCHAR, date_time_utc TIMESTAMP, corrected_mw DOUBLE)")
        DBInterface.execute(con, "INSERT INTO simulations.input_corrections VALUES ('res', TIMESTAMP '2026-11-04 10:00:00', $v)")
        DBInterface.close!(con); DuckDB.close(db)
    end
    extract = joinpath(dir, "extract.duckdb"); mk(extract, 1.0)        # the extract's own corrections
    fill = joinpath(dir, "fill.duckdb"); mk(fill, 1.0)
    E.mark_run_local_fill!(fill; windows=[("simulations", "input_corrections", Date(1900, 1, 1), Date(2999, 12, 31))])
    q = "SELECT corrected_mw FROM simulations.input_corrections"
    try
        for (inputs, expect, label) in ((extract, 1.0, "extract"), (fill, 2.0, "fill"))
            results = joinpath(dir, "results-$label.duckdb"); mk(results, 2.0)   # seeded read-back copy
            mark_seeded(results, "input_corrections")
            E.RESULTS_DB_PATH[] = results
            E.configure_data_store!(backend=:duckdb, duckdb_path=inputs, read_only=true, results_writable=true)
            E._ensure_results_attached(E._duckdb_connection())
            @test E.sql2df(q).corrected_mw == [expect]                 # extract: own table; fill: results_db
            @test (E._FILL_GUARD[] !== nothing) == (label == "fill")
            w = E._duckdb_rewrite("INSERT INTO simulations.input_corrections VALUES ('x', TIMESTAMP '2026-01-01', 0)")
            @test occursin("results_db.simulations.input_corrections", w)   # writes: results_db in both modes
            u = E._duckdb_rewrite("UPDATE simulations.forecast_scores SET mae = 1")
            @test occursin("results_db.simulations.forecast_scores", u)
            E._duckdb_drop_connection!()
        end
    finally
        try; E.RESULTS_DB_PATH[] = prev[5]; E.configure_data_store!(backend=prev[1], duckdb_path=prev[2], read_only=prev[3], results_writable=prev[4]); catch; end
    end
end

@testset "rescore --start auto resolves the first forecast market date (offline source)" begin
    dir = mktempdir(); src = joinpath(dir, "src.duckdb")
    let db = DuckDB.DB(src), con = DBInterface.connect(db)
        DBInterface.execute(con, "CREATE SCHEMA simulations")
        DBInterface.execute(con, "CREATE TABLE simulations.forecast_prices (market_date DATE, bidding_zone VARCHAR)")
        DBInterface.execute(con, "INSERT INTO simulations.forecast_prices VALUES (DATE '2025-03-01', 'GR'), (DATE '2024-11-20', 'BG'), (DATE '2025-01-05', 'GR')")
        DBInterface.close!(con); DuckDB.close(db)
    end
    @test Euphemia.resolve_rescore_start(; zones=["GR"], source=:duckdb, source_path=src) == Date(2025, 1, 5)
    @test Euphemia.resolve_rescore_start(; zones=["GR", "BG"], source=:duckdb, source_path=src) == Date(2024, 11, 20)
    @test_throws ErrorException Euphemia.resolve_rescore_start(; zones=["FR"], source=:duckdb, source_path=src)
end

@testset "cv32 read-back under a fill: the process role picks the source; misses raise" begin
    E = Euphemia
    prev = (E.DATA_STORE[], E.DUCKDB_PATH[], E.DUCKDB_READ_ONLY[], E.DUCKDB_RESULTS_WRITABLE[], E.RESULTS_DB_PATH[])
    prevrole = E.RESULTS_READBACK[]
    dir = mktempdir()
    day = Date(2025, 5, 27); h = DateTime(2025, 5, 27, 8)
    # corrections: inputs copy 130 MW, results DB 150 MW, raw solar forecast 100 MW → delta 30 vs 50
    function mk(path, corrected; fc=false)
        db = DuckDB.DB(path); con = DBInterface.connect(db); x(q, a=Any[]) = DBInterface.execute(con, q, a)
        x("CREATE SCHEMA IF NOT EXISTS simulations")
        x("CREATE TABLE simulations.input_corrections (bidding_zone VARCHAR, target VARCHAR, date_time_utc TIMESTAMP, corrected_mw DOUBLE, model_tag VARCHAR, created_at TIMESTAMP)")
        x("INSERT INTO simulations.input_corrections VALUES ('IT-Sardinia', 'solar', ?, ?, 'm', ?)", Any[h, corrected, h])
        if fc
            x("CREATE SCHEMA entsoe")
            x("CREATE TABLE entsoe.generation_forecasts_for_wind_and_solar (area_map_code VARCHAR, area_type_code VARCHAR, production_type VARCHAR, date_time_utc TIMESTAMP, day_ahead_generation_forecast_mw DOUBLE)")
            x("INSERT INTO entsoe.generation_forecasts_for_wind_and_solar VALUES ('IT-Sardinia', 'BZN', 'Solar', ?, 100.0)", Any[h])
        end
        DBInterface.close!(con); DuckDB.close(db)
    end
    inputs = joinpath(dir, "inputs.duckdb"); mk(inputs, 130.0; fc=true)
    E.mark_run_local_fill!(inputs; windows=[("entsoe", "generation_forecasts_for_wind_and_solar", Date(2025, 5, 20), Date(2025, 5, 30)),
                                            ("simulations", "input_corrections", Date(2025, 5, 26), Date(2025, 5, 30))])
    results = joinpath(dir, "results.duckdb"); mk(results, 150.0)
    mark_seeded(results, "input_corrections"; lo=Date(2025, 5, 26), hi=Date(2025, 5, 30))
    unseeded = joinpath(dir, "results-unseeded.duckdb"); mk(unseeded, 150.0)
    open_store!(res; rw=true) = (E._duckdb_drop_connection!(); E.MeritOrderBook.clear_input_correction_cache!(); E.RESULTS_DB_PATH[] = res;
                                 E.configure_data_store!(backend=:duckdb, duckdb_path=inputs, read_only=true, results_writable=rw))
    deltas() = E.MeritOrderBook._input_correction_deltas("IT-Sardinia", day)
    try
        @test E._results_readback_role("") === :results
        @test E._results_readback_role("inputs") === :inputs
        @test_throws ErrorException E._results_readback_role("both")

        # single-process job (role :results): reads the seeded results DB ...
        E.RESULTS_READBACK[] = :results
        open_store!(results)
        @test deltas() == Dict("20250527-08" => 50.0)
        # ... and its own writes (the daily forecast emits corrections, then clears)
        E._results_exec("UPDATE results_db.simulations.input_corrections SET corrected_mw = 170.0")
        E.MeritOrderBook.clear_input_correction_cache!()
        @test deltas() == Dict("20250527-08" => 70.0)
        # a read-back outside the seeded window raises
        @test_throws E.FillGuardError E.sql2df("SELECT * FROM simulations.input_corrections WHERE date_time_utc >= \$1", Any[Date(2025, 6, 2)])

        # pipelined book worker (role :inputs): the fill-time copy in inputs.duckdb, no results attach
        E.RESULTS_READBACK[] = :inputs
        open_store!(results; rw=false)
        @test deltas() == Dict("20250527-08" => 30.0)
        @test !E._RESULTS_ATTACHED[]

        # results DB without the seed (--seed-results false / an old fill): raises, never reads empty
        E.RESULTS_READBACK[] = :results
        open_store!(unseeded)
        @test_throws E.FillGuardError deltas()

        # results DB that cannot be attached (here: not a DuckDB file; in the bug, another process's
        # read-write lock): the attach raises and the cv32 reader does NOT fall back to raw forecasts
        bad = joinpath(dir, "not-a-duckdb"); write(bad, "garbage bytes, not a database")
        open_store!(bad; rw=false)
        @test_throws E.FillGuardError deltas()
        open_store!(bad; rw=false)
        @test_throws E.FillGuardError E._ensure_results_attached(E._duckdb_connection())

        # off a fill (plain extract): main's behaviour, the extract's own table, no redirect, no guard
        extract = joinpath(dir, "extract.duckdb"); mk(extract, 130.0; fc=true)
        E._duckdb_drop_connection!(); E.MeritOrderBook.clear_input_correction_cache!(); E.RESULTS_DB_PATH[] = bad
        E.configure_data_store!(backend=:duckdb, duckdb_path=extract, read_only=true, results_writable=false)
        @test deltas() == Dict("20250527-08" => 30.0)
    finally
        E.RESULTS_READBACK[] = prevrole
        try; E._duckdb_drop_connection!(); E.MeritOrderBook.clear_input_correction_cache!(); E.RESULTS_DB_PATH[] = prev[5]
             E.configure_data_store!(backend=prev[1], duckdb_path=prev[2], read_only=prev[3], results_writable=prev[4]); catch; end
    end
end

@testset "fill profiles carry the inputs copy of input_corrections over the seed's window" begin
    E = Euphemia
    days = [Date(2025, 5, 27), Date(2025, 6, 26)]
    for (prof, kw) in ((:record, (days_list=days,)), (:retro, (start=Date(2025, 5, 27), stop=Date(2025, 5, 29))),
                       (:daily_forecast, (asof=Date(2025, 5, 27),)), (:export, (asof=Date(2025, 5, 27),)))
        p = E.fill_profile(prof; zones=["IT-Sardinia"], kw...)
        sp = only(filter(s -> s.table == "input_corrections", p.specs))
        sd = only(filter(s -> s.table == "input_corrections", p.seeds))
        @test E.fill_windows(p.days, sp.back, sp.ahead) == sd.win   # inputs copy == results seed
        @test !sp.ts_tz
    end
    @test isempty(filter(s -> s.table == "input_corrections", E.fill_profile(:rescore; start=Date(2025, 5, 27),
                                                                              stop=Date(2025, 5, 28), zones=["GR"]).specs))
end

@testset "fill timestamps are independent of the source session TimeZone" begin
    E = Euphemia
    spec = only(filter(s -> s.table == "unavailability_in_the_transmission_grid", E.FILL_SPECS))
    # production: outage start/end are TEXT, the publication stamp timestamptz
    cols = [("instance_code", "text"), ("start_outage_utc", "text"), ("end_outage_utc", "text"),
            ("start_time_series_utc", "timestamp with time zone"),
            ("version_publication_timestamp_utc", "timestamp with time zone"), ("version", "integer")]
    sql, _ = E.fill_pg_query(spec, cols, [Date(2026, 11, 19)], ["FR"])
    @test occursin("\"version_publication_timestamp_utc\" AT TIME ZONE 'UTC' AS", sql)   # not ::TIMESTAMP
    @test !occursin("\"version_publication_timestamp_utc\"::TIMESTAMP", sql)
    @test occursin("\"start_outage_utc\"::TIMESTAMP AS", sql)                          # text: zone-free
    @test occursin("\"start_time_series_utc\" AT TIME ZONE 'UTC' AS", sql)
    @test occursin("(\"start_outage_utc\"::timestamp < ", sql)                         # overlap on text
    # the test bed's load: the same columns as timestamptz
    tcols = [(c, t == "text" && c != "instance_code" ? "timestamp with time zone" : t) for (c, t) in cols]
    tsql, _ = E.fill_pg_query(spec, tcols, [Date(2026, 11, 19)], ["FR"])
    @test occursin("\"start_outage_utc\" AT TIME ZONE 'UTC' AS", tsql)
    @test occursin("((\"start_outage_utc\" AT TIME ZONE 'UTC') < ", tsql)
    @test !occursin("::TIMESTAMP", tsql) && !occursin("::timestamp <", tsql)
    @test E._naive_utc("c", "timestamp without time zone") == "\"c\""
end

@testset "carbon.uka_price: filled on every clearing profile; absence recorded, otherwise loud" begin
    E = Euphemia
    @test "carbon" in E._GUARDED_SCHEMAS
    for (prof, kw) in ((:record, (days_list=[Date(2025, 5, 27)],)), (:retro, (start=Date(2025, 5, 27), stop=Date(2025, 5, 28))),
                       (:daily_forecast, (asof=Date(2025, 5, 27),)), (:export, (asof=Date(2025, 5, 27),)))
        @test count(s -> (s.schema, s.table) == ("carbon", "uka_price"), E.fill_profile(prof; zones=["FR"], kw...).specs) == 1
    end
    prev = (E.DATA_STORE[], E.DUCKDB_PATH[], E.DUCKDB_READ_ONLY[], E.DUCKDB_RESULTS_WRITABLE[])
    dir = mktempdir()
    # an offline source without the carbon schema: the fill records it absent (never a silent skip)
    src = joinpath(dir, "src.duckdb")
    let db = DuckDB.DB(src), con = DBInterface.connect(db)
        DBInterface.execute(con, "CREATE SCHEMA yfinance")
        DBInterface.execute(con, "CREATE TABLE yfinance.eua_co2 (date DATE, close DOUBLE)")
        DBInterface.execute(con, "INSERT INTO yfinance.eua_co2 VALUES (DATE '2025-05-25', 71.5)")
        DBInterface.close!(con); DuckDB.close(db)
    end
    fill = joinpath(dir, "inputs.duckdb")
    specs = [only(filter(s -> s.table == t, E.FILL_SPECS)) for t in ("eua_co2", "uka_price")]
    redirect_stdout(devnull) do
        E.fill_run_duckdb(fill; days=[Date(2025, 5, 27)], zones=["FR"], specs=specs, source=:duckdb, source_path=src)
    end
    kinds = let db = DuckDB.DB(fill; readonly=true), con = DBInterface.connect(db)
        k = Dict(string(r.schema_name, ".", r.table_name) => r.kind
                 for r in DBInterface.execute(con, "SELECT schema_name, table_name, kind FROM _fill.windows"))
        DBInterface.close!(con); DuckDB.close(db); k
    end
    @test kinds["carbon.uka_price"] == "absent"
    let db = DuckDB.DB(fill; readonly=true), con = DBInterface.connect(db)
        r = collect(DBInterface.execute(con, "SELECT source_timezone, scanner_timezone FROM _fill.run"))[1]
        @test r.source_timezone == "n/a (duckdb source)"
        @test r.scanner_timezone in ("UTC", "Etc/UTC")
        DBInterface.close!(con); DuckDB.close(db)
    end
    @test kinds["yfinance.eua_co2"] == "full"
    # a fill that claims the table but lacks it (no 'absent' row): the Catalog Error is a FillGuardError
    broken = joinpath(dir, "broken.duckdb"); cp(fill, broken)
    let db = DuckDB.DB(broken), con = DBInterface.connect(db)
        DBInterface.execute(con, "UPDATE _fill.windows SET kind = 'full' WHERE table_name = 'uka_price'")
        DBInterface.close!(con); DuckDB.close(db)
    end
    uka(day) = (empty!(E.UKA_PRICE_CACHE); empty!(E.EUA_PRICE_CACHE); E.uka_price(day))
    try
        E.configure_data_store!(backend=:duckdb, duckdb_path=fill, read_only=true)
        @test E._FILL_ABSENT[] == Set(["carbon.uka_price"])
        @test uka(Date(2025, 5, 27)) == 71.5                              # recorded absent → EUA fallback
        E._duckdb_drop_connection!()
        E.configure_data_store!(backend=:duckdb, duckdb_path=broken, read_only=true)
        @test_throws E.FillGuardError uka(Date(2025, 5, 27))              # not recorded → loud
        @test_throws E.FillGuardError E.sql2df("SELECT * FROM carbon.nonexistent")   # not in manifest
    finally
        empty!(E.UKA_PRICE_CACHE); empty!(E.EUA_PRICE_CACHE)
        try; E._duckdb_drop_connection!(); E.configure_data_store!(backend=prev[1], duckdb_path=prev[2], read_only=prev[3], results_writable=prev[4]); catch; end
    end
end

@testset "offered ATC fill covers the readers' code list (footprint + remapped aggregates)" begin
    E = Euphemia
    @test E._atc_codes(["FR", "IT-NORTH"]) == ["FR", "IT", "IT-NORTH"]
    @test E._atc_codes(["FR", "GR"]) == ["FR", "GR"]                  # no representative in the footprint
    cols = [("date_time_utc", "timestamp with time zone"), ("out_map_code", "text"), ("in_map_code", "text"),
            ("capacity_mw", "double precision"), ("contract_type", "text")]
    for t in ("offered_transfer_capacities_explicit", "offered_transfer_capacities_implicit")
        sql, _ = E.fill_pg_query(only(filter(s -> s.table == t, E.FILL_SPECS)), cols, [Date(2026, 11, 19)], ["FR", "IT-NORTH"])
        @test occursin("ARRAY['FR', 'IT', 'IT-NORTH']::text[]", sql)
        @test !occursin("ATCZONES", sql)
    end
    # offline fill: an IT↔ME explicit row (aggregate ↔ non-footprint) is copied, as the reader reads it
    dir = mktempdir(); src = joinpath(dir, "src.duckdb")
    let db = DuckDB.DB(src), con = DBInterface.connect(db)
        DBInterface.execute(con, "CREATE SCHEMA entsoe")
        DBInterface.execute(con, "CREATE TABLE entsoe.offered_transfer_capacities_explicit (date_time_utc TIMESTAMP, out_map_code VARCHAR, in_map_code VARCHAR, capacity_mw DOUBLE, contract_type VARCHAR)")
        for (o, i) in (("IT", "ME"), ("ME", "IT"), ("FR", "IT-NORTH"), ("RS", "ME"))
            DBInterface.execute(con, "INSERT INTO entsoe.offered_transfer_capacities_explicit VALUES (TIMESTAMP '2026-11-19 10:00:00', '$o', '$i', 500.0, 'Day-ahead')")
        end
        DBInterface.close!(con); DuckDB.close(db)
    end
    fill = joinpath(dir, "inputs.duckdb")
    redirect_stdout(devnull) do
        E.fill_run_duckdb(fill; days=[Date(2026, 11, 19)], zones=["FR", "IT-NORTH"], source=:duckdb, source_path=src,
                          specs=[only(filter(s -> s.table == "offered_transfer_capacities_explicit", E.FILL_SPECS))])
    end
    got = let db = DuckDB.DB(fill; readonly=true), con = DBInterface.connect(db)
        r = sort([(x.out_map_code, x.in_map_code) for x in DBInterface.execute(con, "SELECT out_map_code, in_map_code FROM entsoe.offered_transfer_capacities_explicit")])
        DBInterface.close!(con); DuckDB.close(db); r
    end
    @test got == [("FR", "IT-NORTH"), ("IT", "ME"), ("ME", "IT")]      # RS↔ME: outside every reader's filter
end
