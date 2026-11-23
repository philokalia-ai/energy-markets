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
    @test occursin("start_outage_utc::timestamp < '2026-01-12'::timestamp", sql)   # [d-1, d+2)
    @test occursin("end_outage_utc::timestamp >= '2026-01-09'::timestamp", sql)

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
        @test_throws ErrorException E.sql2df(q, Any["GR", Date(2026, 2, 1)])         # outside → loud
        @test_throws ErrorException E.sql2df("SELECT * FROM entsoe.physical_flows")  # not in manifest → loud
        @test nrow(E.sql2df("SELECT * FROM entsoe.production_and_generation_units WHERE area_map_code = \$1",
                            Any["GR"])) == 0                                         # full table: any date ok
        @test_throws ErrorException E.sql2df(
            "SELECT * FROM entsoe.day_ahead_total_load_forecast WHERE date_time_utc < TIMESTAMP '2027-01-01 00:00:00'")
        # the guard only covers the run-local inputs, never results_db.*
        g = E._FILL_GUARD[]
        @test g !== nothing
        @test E._fill_guard_check(g, "SELECT * FROM results_db.simulations.energy_prices", Any[Date(2030, 1, 1)]) === nothing
    finally
        try; E.configure_data_store!(backend=prev[1], duckdb_path=prev[2], read_only=prev[3], results_writable=prev[4]); catch; end
    end
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
