# PR #405 review: the pipelined backfill hands the caller back its data-store
# mode on EVERY exit (early return, failure after worker startup), and the
# results attachment's access mode follows `results_writable` both ways.
# Self-contained: a throw-away extract + results DuckDB under a temp dir.
#
# Standalone:  julia --project=. test/test_pipeline_store_restore.jl

using Test
using Euphemia
using Dates
using Distributed
using DuckDB
import DuckDB.DBInterface as DBInterface

function _psr_results_mode()
    con = Euphemia._duckdb_connection()
    r = collect(DBInterface.execute(con,
        "SELECT readonly FROM duckdb_databases() WHERE database_name = 'results_db'"))
    return isempty(r) ? nothing : Bool(r[1].readonly)
end

@testset "pipelined backfill restores the caller's store (PR #405 review)" begin
    prev = (Euphemia.DATA_STORE[], Euphemia.DUCKDB_PATH[], Euphemia.DUCKDB_READ_ONLY[],
            Euphemia.DUCKDB_RESULTS_WRITABLE[], Euphemia.RESULTS_DB_PATH[])
    dir = mktempdir()
    extract = joinpath(dir, "extract.duckdb")
    results = joinpath(dir, "results.duckdb")
    let db = DuckDB.DB(extract); con = DBInterface.connect(db)
        DBInterface.execute(con, "CREATE SCHEMA entsoe")
        DBInterface.close!(con); DuckDB.close(db)
    end
    D = Date(2026, 9, 20)
    zones = ["GR", "BG"]
    cv = Euphemia.ENERGY_PRICES_CODE_VERSION
    let db = DuckDB.DB(results); con = DBInterface.connect(db)
        DBInterface.execute(con, "CREATE SCHEMA simulations")
        DBInterface.execute(con, """
            CREATE TABLE simulations.energy_prices (
                date_time_utc TIMESTAMP, resolution_code VARCHAR, bidding_zone VARCHAR,
                contract_type VARCHAR, price_eur_mwh DOUBLE, currency VARCHAR,
                order_method VARCHAR, clearing_mode VARCHAR, optimization_run_id BIGINT,
                code_version INTEGER, update_time_utc TIMESTAMP)""")
        for z in zones, h in 0:23
            DBInterface.execute(con, """INSERT INTO simulations.energy_prices VALUES
                (TIMESTAMP '$(D) $(lpad(h, 2, '0')):00:00', 'PT60M', '$z', 'Day-ahead', 100.0,
                 'EUR', 'merit_order', 't405', NULL, $cv, NULL)""")
        end
        DBInterface.close!(con); DuckDB.close(db)
    end
    Euphemia.RESULTS_DB_PATH[] = results
    try
        # (a) resume finds every day saved -> early return; the caller's
        # (read_only=true, results_writable=false) must survive, and the
        # results attachment must not stay READ_WRITE.
        Euphemia.configure_data_store!(backend = :duckdb, duckdb_path = extract,
                                       read_only = true, results_writable = false)
        r = Euphemia.run_pipelined_backfill([D], zones; clearing_mode = "t405",
                                            resume = true, save_to_db = true)
        @test r.processed == 0
        @test Euphemia.DUCKDB_READ_ONLY[] == true
        @test Euphemia.DUCKDB_RESULTS_WRITABLE[] == false
        m = _psr_results_mode()
        @test m === nothing || m == true

        # (b) a failure AFTER worker startup (book capture dir cannot be
        # created) -> the error propagates, every added worker is removed and
        # the caller's (false, false) is restored.
        Euphemia.configure_data_store!(backend = :duckdb, duckdb_path = extract,
                                       read_only = false, results_writable = false)
        before = Set(procs())
        @test_throws Exception Euphemia.run_pipelined_backfill([D], zones;
            clearing_mode = "t405b", resume = false, save_to_db = false,
            solver_workers = 1, book_workers = 1, books_dir = "/proc/euphemia-no-such-dir")
        @test Set(procs()) == before
        @test Euphemia.DUCKDB_READ_ONLY[] == false
        @test Euphemia.DUCKDB_RESULTS_WRITABLE[] == false

        # (d) a run that reaches the end (the day fails in its book build on
        # this empty extract — counted, not thrown) returns its summary. The
        # run state is read after the outer try/finally; binding it inside
        # made every completed run throw `UndefVarError: wall0` (1dcf995).
        Euphemia.configure_data_store!(backend = :duckdb, duckdb_path = extract,
                                       read_only = true, results_writable = false)
        before = Set(procs())
        r = Euphemia.run_pipelined_backfill([D], zones; clearing_mode = "t405d",
            resume = false, save_to_db = false, solver_workers = 1, book_workers = 1)
        @test r.processed == 1
        @test r.saved + r.failed == 1
        @test r.wall_seconds > 0
        @test Set(procs()) == before
        @test Euphemia.DUCKDB_READ_ONLY[] == true

        # (c) the results attachment follows results_writable on an existing
        # connection: (true,false) -> (true,true) -> (true,false).
        Euphemia.configure_data_store!(backend = :duckdb, duckdb_path = extract,
                                       read_only = true, results_writable = false)
        Euphemia.sql2df("SELECT COUNT(*) AS n FROM simulations.energy_prices")
        @test _psr_results_mode() == true
        Euphemia.configure_data_store!(backend = :duckdb, duckdb_path = extract,
                                       read_only = true, results_writable = true)
        Euphemia.sql2df("SELECT COUNT(*) AS n FROM simulations.energy_prices")
        @test _psr_results_mode() == false
        Euphemia.configure_data_store!(backend = :duckdb, duckdb_path = extract,
                                       read_only = true, results_writable = false)
        @test _psr_results_mode() === nothing          # detached: writer lock released
        Euphemia.sql2df("SELECT COUNT(*) AS n FROM simulations.energy_prices")
        @test _psr_results_mode() == true
    finally
        Euphemia.RESULTS_DB_PATH[] = prev[5]
        try
            prev[1] == :duckdb && Euphemia.configure_data_store!(backend = :duckdb,
                duckdb_path = prev[2], read_only = prev[3], results_writable = prev[4])
        catch
        end
    end
end
