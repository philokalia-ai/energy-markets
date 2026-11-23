# Day caches that were write-only (perf-96): jao_maxbex, jao_net_positions and
# tx_outage_caps stored their result but checked the cache with `return` inside a
# `lock() do` block, which returns from the closure, so every call re-queried. A hit
# now returns the cached object itself; the values are what a fresh query gives.
# Self-contained: a throw-away DuckDB extract under a temp dir.
#
# Standalone:  julia --project=. test/test_day_cache_hits.jl

using Test, Dates
using Euphemia
using DuckDB
import DuckDB.DBInterface as DBInterface

@testset "day caches return hits (no re-query)" begin
    N = Euphemia.Network
    prev = (Euphemia.DATA_STORE[], Euphemia.DUCKDB_PATH[], Euphemia.DUCKDB_READ_ONLY[],
            Euphemia.DUCKDB_RESULTS_WRITABLE[])
    day = Date(2026, 11, 4)
    dir = mktempdir()
    extract = joinpath(dir, "extract.duckdb")
    let db = DuckDB.DB(extract), con = DBInterface.connect(db)
        run(sql) = DBInterface.execute(con, sql)
        run("CREATE SCHEMA jao"); run("CREATE SCHEMA entsoe")
        run("""CREATE TABLE jao.max_exchanges (ccr VARCHAR, border_from VARCHAR, border_to VARCHAR,
                   date_time_utc TIMESTAMP, max_exchange_mw DOUBLE)""")
        run("""INSERT INTO jao.max_exchanges VALUES
                   ('core', 'AT', 'CZ', TIMESTAMP '2026-11-04 00:00:00', 1000.0),
                   ('core', 'AT', 'CZ', TIMESTAMP '2026-11-04 00:15:00', 1200.0)""")
        run("""CREATE TABLE jao.hub_net_positions (ccr VARCHAR, hub VARCHAR, date_time_utc TIMESTAMP,
                   min_np_mw DOUBLE, max_np_mw DOUBLE)""")
        run("""INSERT INTO jao.hub_net_positions VALUES
                   ('core', 'AT', TIMESTAMP '2026-11-04 00:00:00', -3000.0, 4000.0)""")
        run("""CREATE TABLE entsoe.unavailability_in_the_transmission_grid (
                   instance_code VARCHAR, version INTEGER, status VARCHAR,
                   start_outage_utc TIMESTAMP, end_outage_utc TIMESTAMP,
                   start_time_series_utc TIMESTAMP, end_time_series_utc TIMESTAMP,
                   version_publication_timestamp_utc TIMESTAMP,
                   out_area_map_code VARCHAR, in_area_map_code VARCHAR, new_ntc_mw DOUBLE)""")
        run("""INSERT INTO entsoe.unavailability_in_the_transmission_grid VALUES
                   ('X1', 1, 'Active', TIMESTAMP '2026-11-03 00:00:00', TIMESTAMP '2026-11-05 00:00:00',
                    TIMESTAMP '2026-11-03 00:00:00', TIMESTAMP '2026-11-05 00:00:00',
                    TIMESTAMP '2026-10-01 00:00:00', 'AT', 'CZ', 150.0)""")
        DBInterface.close!(con); DuckDB.close(db)
    end
    try
        Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract, read_only=true)
        N.clear_jao_cache!()
        empty!(N._JAO_NP_CACHE); empty!(N._TX_OUTAGE_DAY_CACHE)

        m1 = N.jao_maxbex(day)
        @test m1[("AT", "CZ", 1)] == 1100.0
        @test N.jao_maxbex(day) === m1                       # cache hit, same object

        np1 = N.jao_net_positions(day)
        @test np1[("core", "AT", 1)] == (-3000.0, 4000.0)
        @test N.jao_net_positions(day) === np1

        c1 = N.tx_outage_caps(day)
        @test c1[("AT", "CZ", 1)] == 150.0 && length(c1) == 24
        @test N.tx_outage_caps(day) === c1

        # the cached value equals a fresh computation
        N.clear_jao_cache!(); empty!(N._JAO_NP_CACHE); empty!(N._TX_OUTAGE_DAY_CACHE)
        @test N.jao_maxbex(day) == m1
        @test N.jao_net_positions(day) == np1
        @test N.tx_outage_caps(day) == c1
    finally
        N.clear_jao_cache!(); empty!(N._JAO_NP_CACHE); empty!(N._TX_OUTAGE_DAY_CACHE)
        try; Euphemia.configure_data_store!(backend=prev[1], duckdb_path=prev[2], read_only=prev[3],
                                            results_writable=prev[4]); catch; end
    end
end

@testset "single-flight day-cache fill (_fill_once)" begin
    M = Euphemia.MeritOrderBook
    cache = Dict{Int,Vector{Int}}(); lk = ReentrantLock()
    calls = Threads.Atomic{Int}(0)
    fill() = (Threads.atomic_add!(calls, 1); sleep(0.3); [1, 2, 3])
    tasks = [Threads.@spawn M._fill_once(fill, lk, cache, 7) for _ in 1:8]
    vals = fetch.(tasks)
    @test calls[] == 1                          # one fill, seven waiters
    @test all(v -> v === vals[1], vals)
    @test M._fill_once(fill, lk, cache, 7) === vals[1] && calls[] == 1
    # a failed fill is not cached; the next caller retries
    @test_throws ErrorException M._fill_once(() -> error("db down"), lk, cache, 8)
    @test !haskey(cache, 8)
    @test M._fill_once(() -> [9], lk, cache, 8) == [9]
end
