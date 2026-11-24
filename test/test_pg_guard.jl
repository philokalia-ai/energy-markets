# Runtime Postgres guard (owner rule: DuckDB between Postgres and Julia): under EUPHEMIA_DATA_STORE=duckdb no
# Julia code may open a direct Postgres connection. `newconnection`, `preinit_pool` and `withdb` raise a
# FillGuardError (src/db/postgres_core.jl `_postgres_guard`), which no soft fallback or outer catch swallows.
# DB-free: a temp DuckDB file, no Postgres anywhere (ENERGY_CONN_STR points at a closed local port, so even a
# guard regression could not reach a real server). Runs in its own process (it configures the data store):
#   julia --project=. test/test_pg_guard.jl
using Test, Dates, DuckDB, DataFrames

const TMP = mktempdir()
const INPUTS = joinpath(TMP, "inputs.duckdb")
let db = DuckDB.DB(INPUTS); con = DBInterface.connect(db)
    DBInterface.execute(con, "CREATE SCHEMA entsoe")
    DBInterface.execute(con, "CREATE TABLE entsoe.actual_total_load (date_time_utc TIMESTAMP, area_map_code VARCHAR, actual_total_load_mw DOUBLE)")
    DBInterface.execute(con, "INSERT INTO entsoe.actual_total_load VALUES (TIMESTAMP '2026-11-20 23:00:00', 'GR', 5000.0)")
    DBInterface.close!(con); close(db)
end
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"; ENV["EUPHEMIA_DUCKDB_PATH"] = INPUTS
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"; ENV["EUPHEMIA_RESULTS_WRITABLE"] = "true"
ENV["EUPHEMIA_RESULTS_DB"] = joinpath(TMP, "results.duckdb")
ENV["ENERGY_CONN_STR"] = "host=127.0.0.1 port=1 dbname=none user=none connect_timeout=1"   # never reachable
using Euphemia, LibPQ
const E = Euphemia

@testset "Postgres guard: no direct connection under the DuckDB store" begin
    @test E.DATA_STORE[] === :duckdb
    # the three primitives raise before any connection attempt
    for (what, f) in (("newconnection", () -> E.newconnection()),
                      ("preinit_pool", () -> E.preinit_pool(1)),
                      ("withdb", () -> E.withdb(cnx -> LibPQ.execute(cnx, "SELECT 1"))))
        err = try f(); nothing catch x; x end
        @test err isa E.FillGuardError
        @test occursin("postgres guard: $what", sprint(showerror, err))
    end
    # a writer that forgot its store guard fails loudly, through a soft fallback's catch too
    forgot() = E.withdb(cnx -> LibPQ.execute(cnx, "DELETE FROM simulations.forecast_prices"))
    soft() = try forgot() catch e; E._rethrow_fill_guard(e); :swallowed end
    @test_throws E.FillGuardError soft()
    # ... and from a task (a threaded zone build)
    tfe = try wait(Threads.@spawn forgot()); nothing catch x; x end
    @test E._fill_guard_in(tfe) isa E.FillGuardError
    # the DuckDB store itself is untouched: reads and the guarded writers' DuckDB branches work
    @test E.sql2df("SELECT count(*) AS n FROM entsoe.actual_total_load").n[1] == 1
    @test E.sql2df_with_retry("SELECT max(actual_total_load_mw) AS m FROM entsoe.actual_total_load"; retry_delay=0.0).m[1] == 5000.0
    E.ensure_forecast_tables()            # guarded: returns before any withdb under duckdb
    E.ensure_run_results_tables!()
    @test E.results_to_duckdb()
    # the guard is silent on the Postgres store (no connection is made here: only the check runs)
    old = E.DATA_STORE[]
    try
        E.DATA_STORE[] = :postgres
        @test E._postgres_guard("newconnection") === nothing
    finally
        E.DATA_STORE[] = old
    end
end
