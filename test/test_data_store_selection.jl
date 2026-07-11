# Tests for the data-store backend selection logic and the writable offline
# results database (DuckDB backend). Pure logic tests need no external services;
# the writable-results test builds a tiny synthetic DuckDB extract on the fly, so
# the whole file runs with no Postgres.
#
# Standalone:  julia --project=. test/test_data_store_selection.jl

using Test
using Euphemia
using Dates
using DuckDB
import DuckDB.DBInterface as DBInterface

@testset "Data store backend selection" begin
    # exists predicates
    yes(_) = true
    no(_) = false

    @testset "explicit env always wins" begin
        # explicit duckdb -> duckdb, even if no file and no conn string
        b, p = Euphemia._resolve_data_store(data_store="duckdb", duckdb_path="",
            energy_conn_str="", exists=no)
        @test b == :duckdb
        @test p == Euphemia.DEFAULT_PUBLIC_EXTRACT

        # explicit duckdb honors EUPHEMIA_DUCKDB_PATH override
        b, p = Euphemia._resolve_data_store(data_store="DuckDB", duckdb_path="/x/y.duckdb",
            energy_conn_str="", exists=no)
        @test b == :duckdb
        @test p == "/x/y.duckdb"

        # explicit postgres -> postgres, even if the extract file exists
        b, p = Euphemia._resolve_data_store(data_store="postgres", duckdb_path="",
            energy_conn_str="conn", exists=yes)
        @test b == :postgres

        # invalid explicit value errors
        @test_throws ErrorException Euphemia._resolve_data_store(data_store="mysql",
            duckdb_path="", energy_conn_str="conn", exists=yes)
    end

    @testset "auto-detect (env unset)" begin
        # extract present -> duckdb (wins over Postgres, even if conn set)
        b, p = Euphemia._resolve_data_store(data_store="", duckdb_path="",
            energy_conn_str="conn", exists=yes)
        @test b == :duckdb
        @test p == Euphemia.DEFAULT_PUBLIC_EXTRACT

        # extract present at overridden path -> duckdb at that path
        b, p = Euphemia._resolve_data_store(data_store="  ", duckdb_path="/data/e.duckdb",
            energy_conn_str="", exists=(x -> x == "/data/e.duckdb"))
        @test b == :duckdb
        @test p == "/data/e.duckdb"

        # no extract, conn present -> postgres (unchanged product/CI behavior)
        b, p = Euphemia._resolve_data_store(data_store="", duckdb_path="",
            energy_conn_str="postgresql://u@h/db", exists=no)
        @test b == :postgres

        # no extract, no conn -> actionable error
        @test_throws ErrorException Euphemia._resolve_data_store(data_store="",
            duckdb_path="", energy_conn_str="", exists=no)
    end
end

@testset "Writable offline results (DuckDB backend)" begin
    tmp = mktempdir()
    extract = joinpath(tmp, "extract.duckdb")
    results = joinpath(tmp, "results.duckdb")

    # Build a minimal synthetic extract: the schemas the library expects, and one
    # extract-owned simulations table (unit_firms) that must NOT be shadowed by the
    # results redirect.
    let db = DuckDB.DB(extract), con = DBInterface.connect(db)
        DBInterface.execute(con, "CREATE SCHEMA entsoe")
        DBInterface.execute(con, "CREATE SCHEMA yfinance")
        DBInterface.execute(con, "CREATE SCHEMA simulations")
        DBInterface.execute(con, "CREATE TABLE simulations.unit_firms(zone VARCHAR, unit_code VARCHAR, firm VARCHAR)")
        DBInterface.execute(con, "INSERT INTO simulations.unit_firms VALUES ('GR','U1','PPC')")
        DBInterface.close!(con); close(db)
    end

    prev = Euphemia.DATA_STORE[]
    prev_results = Euphemia.RESULTS_DB_PATH[]
    try
        Euphemia.RESULTS_DB_PATH[] = results
        Euphemia._RESULTS_ATTACHED[] = false
        Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract)

        day = Date(2026, 4, 2)
        prices = Dict("$(Dates.format(day, "yyyymmdd"))-$(lpad(h,2,'0'))00" => 50.0 + h
                      for h in 0:23)

        # optimization_runs write returns a fresh id
        run_id = Euphemia.save_optimization_run("GR", day, :merit_order, :mpcc, "highs", :optimal;
            objective_value=1.0, solve_time_seconds=0.5, num_orders=10, num_price_periods=24)
        @test run_id isa Integer

        # energy_prices write persists offline and reads back
        n = Euphemia.save_energy_prices(prices, "GR", day, :merit_order;
            clearing_mode="single_zone", optimization_run_id=run_id)
        @test n == 24

        back = Euphemia.sql2df("""
            SELECT bidding_zone AS z, date_time_utc AS t, price_eur_mwh AS sim
            FROM simulations.energy_prices
            WHERE code_version = \$1 AND clearing_mode = \$2
            """, Any[Euphemia.ENERGY_PRICES_CODE_VERSION, "single_zone"])
        @test size(back, 1) == 24
        @test Set(String.(back.z)) == Set(["GR"])

        # re-save replaces (no duplicates)
        Euphemia.save_energy_prices(prices, "GR", day, :merit_order;
            clearing_mode="single_zone", optimization_run_id=run_id)
        back2 = Euphemia.sql2df("SELECT count(*) c FROM simulations.energy_prices", Any[])
        @test back2.c[1] == 24

        # transmission_flows write
        flows = Dict("GR_to_BG" => Dict("$(Dates.format(day,"yyyymmdd"))-1200" => 100.0))
        nf = Euphemia.save_transmission_flows(flows, day; code_version=10)
        @test nf == 1

        # the extract's own simulations table is untouched by the redirect
        uf = Euphemia.sql2df("SELECT count(*) c FROM simulations.unit_firms", Any[])
        @test uf.c[1] == 1

        # source-data writes still no-op under the read-only extract
        @test Euphemia.ensure_indexes() === nothing

        # the results live in the SEPARATE file, not the extract
        @test isfile(results)

        # --- read-only shared mode (multi-process parallel workers) ---
        # Reopen the same extract read-only: reads still work, but result writes
        # must fail loudly (workers are required to run save_to_db=false).
        Euphemia._RESULTS_ATTACHED[] = false
        Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract, read_only=true)
        @test Euphemia.DUCKDB_READ_ONLY[]
        uf_ro = Euphemia.sql2df("SELECT count(*) c FROM simulations.unit_firms", Any[])
        @test uf_ro.c[1] == 1
        @test_throws ErrorException Euphemia.save_optimization_run(
            "GR", day, :merit_order, :mpcc, "highs", :optimal)
        # a second read-only PROCESS can share the file concurrently
        code = """using DuckDB
                  import DuckDB.DBInterface as DBI
                  db = DuckDB.DB(raw"$extract"; readonly=true)
                  con = DBI.connect(db)
                  r = DBI.execute(con, "SELECT count(*) c FROM simulations.unit_firms")
                  print(first(r).c)"""
        out = read(`$(Base.julia_cmd()) --project=$(dirname(Base.active_project())) -e $code`, String)
        @test strip(out) == "1"
        # --- coordinator mode: read-only SOURCE + writable RESULTS ---------
        # The pipelined-backfill coordinator shares the source read-only with its
        # workers but must still persist results to the separate results_db. It
        # opts in via results_writable=true; writes must succeed (unlike a plain
        # read-only worker, tested just above, which still throws).
        Euphemia._RESULTS_ATTACHED[] = false
        Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract,
            read_only=true, results_writable=true)
        @test Euphemia.DUCKDB_READ_ONLY[]
        @test Euphemia.DUCKDB_RESULTS_WRITABLE[]
        coord_id = Euphemia.save_optimization_run("GR", day, :merit_order, :mpcc, "highs", :optimal)
        @test coord_id isa Integer
        # source data is still untouched by the coordinator's writes
        uf_c = Euphemia.sql2df("SELECT count(*) c FROM simulations.unit_firms", Any[])
        @test uf_c.c[1] == 1

        # back to read-write: result writes work again
        Euphemia._RESULTS_ATTACHED[] = false
        Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract, read_only=false)
        rw_id = Euphemia.save_optimization_run("GR", day, :merit_order, :mpcc, "highs", :optimal)
        @test rw_id isa Integer
    finally
        Euphemia._RESULTS_ATTACHED[] = false
        Euphemia.RESULTS_DB_PATH[] = prev_results
        Euphemia.DUCKDB_READ_ONLY[] = false
        Euphemia.DUCKDB_RESULTS_WRITABLE[] = false
        if prev == :postgres
            try; Euphemia.configure_data_store!(backend=:postgres); catch; end
        end
        try; rm(tmp, recursive=true, force=true); catch; end
    end
end
