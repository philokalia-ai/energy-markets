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
    @test occursin("\"start_outage_utc\"::TIMESTAMP AS \"start_outage_utc\"", sql)
    @test occursin("start_outage_utc::timestamp < '2026-01-12'::timestamp", sql)
    @test occursin("end_outage_utc::timestamp >= '2024-12-06'::timestamp", sql)

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
