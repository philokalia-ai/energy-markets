# Tests for the DuckDB query-path performance changes (perf/duckdb-query-paths).
#
# The load-bearing guarantee is behavioral IDENTITY: the day-level physical-flow
# cache (get_net_imports / get_dropped_border_exports) must return exactly what
# the pre-change per-zone SQL returned. This file proves it against the ORIGINAL
# per-zone SQL (embedded verbatim below as the oracle) on a synthetic DuckDB
# extract with INTEGER flows — so the AVG/SUM are exact and the comparison is
# bit-for-bit (no floating-point tolerance needed). Fully self-contained: no
# Postgres, no published extract.
#
# Standalone:  julia --project=. test/test_duckdb_perf_paths.jl

using Test
using Euphemia
using Dates
using DataFrames
using DuckDB
import DuckDB.DBInterface as DBInterface

const MOB = Euphemia.MeritOrderBook

# --- The ORIGINAL per-zone queries, verbatim (pre-change), as the oracle ------
function _old_net_imports(zone, day; exclude=String[], import_only=String[])
    df = Euphemia.sql2df_with_retry(
        """
        WITH border_hourly AS (
            SELECT DISTINCT ON (h, counterparty, direction)
                   h, counterparty, direction, avg_flow
            FROM (
                SELECT EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int AS h,
                       regexp_replace(
                           CASE WHEN in_area_map_code = \$1
                                THEN out_area_map_code ELSE in_area_map_code END,
                           '_IPS\$', '') AS counterparty,
                       CASE WHEN in_area_map_code = \$1 THEN 1 ELSE -1 END AS direction,
                       AVG(flow_mw) AS avg_flow
                FROM entsoe.physical_flows
                WHERE (in_area_map_code = \$1 OR out_area_map_code = \$1)
                  AND in_area_type_code LIKE 'BZN%' AND out_area_type_code LIKE 'BZN%'
                  AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
                  AND date_time_utc < ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
                GROUP BY 1,
                         CASE WHEN in_area_map_code = \$1
                              THEN out_area_map_code ELSE in_area_map_code END,
                         CASE WHEN in_area_map_code = \$1 THEN 1 ELSE -1 END
            ) per_code
            ORDER BY h, counterparty, direction, avg_flow DESC
        )
        SELECT h, SUM(CASE WHEN counterparty = ANY(\$4)
                           THEN GREATEST(direction * avg_flow, 0)
                           ELSE direction * avg_flow END) AS net_import
        FROM border_hourly
        WHERE counterparty <> ALL(\$3)
        GROUP BY h
        """,
        [zone, day, exclude, import_only])
    return Dict{Int,Float64}(row.h => row.net_import for row in eachrow(df))
end

function _old_dropped_exports(zone, day, counterparties)
    isempty(counterparties) && return Dict{Int,Float64}()
    df = Euphemia.sql2df_with_retry(
        """
        WITH border_hourly AS (
            SELECT DISTINCT ON (h, counterparty, direction)
                   h, counterparty, direction, avg_flow
            FROM (
                SELECT EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int AS h,
                       regexp_replace(
                           CASE WHEN in_area_map_code = \$1
                                THEN out_area_map_code ELSE in_area_map_code END,
                           '_IPS\$', '') AS counterparty,
                       CASE WHEN in_area_map_code = \$1 THEN 1 ELSE -1 END AS direction,
                       AVG(flow_mw) AS avg_flow
                FROM entsoe.physical_flows
                WHERE (in_area_map_code = \$1 OR out_area_map_code = \$1)
                  AND in_area_type_code LIKE 'BZN%' AND out_area_type_code LIKE 'BZN%'
                  AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
                  AND date_time_utc < ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
                GROUP BY 1,
                         CASE WHEN in_area_map_code = \$1
                              THEN out_area_map_code ELSE in_area_map_code END,
                         CASE WHEN in_area_map_code = \$1 THEN 1 ELSE -1 END
            ) per_code
            ORDER BY h, counterparty, direction, avg_flow DESC
        )
        SELECT h, SUM(GREATEST(-direction * avg_flow, 0)) AS export_mw
        FROM border_hourly
        WHERE counterparty = ANY(\$3)
        GROUP BY h
        """,
        [zone, day, counterparties])
    return Dict{Int,Float64}(row.h => row.export_mw for row in eachrow(df))
end

# Build a synthetic extract with a crafted physical_flows table exercising:
# PT15M sub-hour averaging, _IPS alias dedup, both flow directions, a non-BZN
# row that must be filtered, and borders not involving the probed zone.
function _build_flows_extract(path)
    db = DuckDB.DB(path); con = DBInterface.connect(db)
    DBInterface.execute(con, "CREATE SCHEMA entsoe")
    DBInterface.execute(con, """
        CREATE TABLE entsoe.physical_flows(
            date_time_utc TIMESTAMP, in_area_map_code VARCHAR, out_area_map_code VARCHAR,
            in_area_type_code VARCHAR, out_area_type_code VARCHAR, flow_mw DOUBLE)""")
    rows = String[]
    add(ts, ic, oc, f) = push!(rows,
        "('2026-04-03 $ts', '$ic', '$oc', 'BZN', 'BZN', $f)")
    # hour 0
    add("00:00:00", "GR", "BG", 100)                 # GR imports BG +100
    add("00:00:00", "IT-SOUTH", "GR", 50)            # GR exports IT-SOUTH -50
    add("00:00:00", "GR", "TR", 300)                 # GR imports TR +300
    add("00:00:00", "TR", "GR", 80)                  # GR exports TR (dir -1) -80
    add("00:00:00", "GR", "UA", 40)                  # alias: strip -> UA +40
    add("00:00:00", "GR", "UA_IPS", 70)              # alias: strip -> UA +70 (max wins)
    add("00:00:00", "BG", "RO", 500)                 # unrelated to GR
    # hour 1: BG at PT15M (4 equal rows -> AVG 200, exact)
    for q in ("01:00:00", "01:15:00", "01:30:00", "01:45:00")
        add(q, "GR", "BG", 200)
    end
    # a non-BZN row that MUST be excluded (would otherwise swamp hour 0)
    push!(rows, "('2026-04-03 00:00:00', 'GR', 'BG', 'CTA', 'BZN', 9999)")
    DBInterface.execute(con, "INSERT INTO entsoe.physical_flows VALUES " * join(rows, ", "))
    DBInterface.close!(con); close(db)
end

@testset "DuckDB perf paths" begin
    prev = Euphemia.DATA_STORE[]
    tmp = mktempdir()
    extract = joinpath(tmp, "flows.duckdb")
    _build_flows_extract(extract)

    try
        Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract)
        day = Date(2026, 4, 3)

        @testset "get_net_imports day-cache == original per-zone SQL (exact)" begin
            cases = [
                ("GR", String[], String[]),
                ("GR", ["BG"], String[]),
                ("GR", ["TR"], String[]),
                ("GR", String[], ["TR"]),          # import-only clamp
                ("GR", String[], ["BG", "TR"]),
                ("GR", ["UA"], String[]),          # exclude the aliased counterparty
                ("BG", String[], String[]),        # zone on the out-side of GR-BG
                ("TR", String[], String[]),        # zone reached only as counterparty
            ]
            for (z, ex, io) in cases
                Euphemia.clear_net_imports_cache!()   # force a fresh day scan
                new = MOB.get_net_imports(z, day;
                    exclude_counterparties=ex, import_only_counterparties=io)
                old = _old_net_imports(z, day; exclude=ex, import_only=io)
                @test new == old   # integer flows -> bit-identical
            end
        end

        @testset "day cache is scanned once, reused across zones" begin
            Euphemia.clear_net_imports_cache!()
            @test isempty(Euphemia.MeritOrderBook._NET_IMPORTS_DAY_CACHE)
            MOB.get_net_imports("GR", day)
            @test haskey(Euphemia.MeritOrderBook._NET_IMPORTS_DAY_CACHE, day)
            # a second zone on the same day must NOT add another day entry
            MOB.get_net_imports("BG", day)
            @test length(Euphemia.MeritOrderBook._NET_IMPORTS_DAY_CACHE) == 1
        end

        @testset "get_dropped_border_exports day-cache == original SQL (exact)" begin
            for (z, cps) in [("GR", ["BG"]), ("GR", ["TR"]), ("GR", ["UA"]),
                             ("GR", ["IT-SOUTH"]), ("GR", ["BG", "TR"])]
                Euphemia.clear_net_imports_cache!()
                new = MOB.get_dropped_border_exports(z, day, cps)
                old = _old_dropped_exports(z, day, cps)
                @test new == old
            end
            # empty counterparties -> empty (no scan)
            @test MOB.get_dropped_border_exports("GR", day, String[]) == Dict{Int,Float64}()
        end

        @testset "sql2df_with_retry stays off LibPQ under DuckDB" begin
            @test Euphemia.DATA_STORE[] == :duckdb
            # A bad query must fail FAST (no LibPQ preinit / connect_timeout stalls).
            t = @elapsed begin
                @test_throws Exception Euphemia.sql2df_with_retry(
                    "SELECT * FROM entsoe.does_not_exist", [];
                    max_retries=1, retry_delay=0.0)
            end
            @test t < 5.0
        end
    finally
        if prev == :postgres
            try; Euphemia.configure_data_store!(backend=:postgres); catch; end
        end
        try; rm(tmp, recursive=true, force=true); catch; end
    end
end
