# Feed-anchored rescue window: a stale-registry unit stays in the fleet when
# the zone's per-unit generation FEED went silent (missing telemetry is not a
# retired plant), never through data newer than the D-1 gate minus the
# per-unit publication latency, and the window is unchanged for a healthy feed.
# Runs the real get_generators queries against a tiny synthetic DuckDB extract.
#
# Standalone:  julia --project=. test/test_registry_feed_anchor.jl

using Test
using Euphemia
using Dates
using DataFrames
using DuckDB
import DuckDB.DBInterface as DBInterface

const _FA_DAY = Date(2026, 9, 20)   # gate 09-19 10:00, anchor bound 09-13 10:00

function _fa_build(path; gen_rows)
    db = DuckDB.DB(path)
    con = DBInterface.connect(db)
    run(sql) = DBInterface.execute(con, sql)
    run("CREATE SCHEMA entsoe")
    run("""
        CREATE TABLE entsoe.production_and_generation_units (
            valid_from TIMESTAMP, valid_to TIMESTAMP,
            production_unit_code VARCHAR, production_unit_name VARCHAR,
            production_unit_status VARCHAR, production_unit_type VARCHAR,
            production_unit_location VARCHAR, production_unit_installed_capacity_mw DOUBLE,
            production_unit_voltage_kv DOUBLE, area_code VARCHAR, area_display_name VARCHAR,
            area_type_code VARCHAR, area_map_code VARCHAR, generation_unit_code VARCHAR,
            generation_unit_name VARCHAR, generation_unit_status VARCHAR,
            generation_unit_type VARCHAR, generation_unit_location VARCHAR,
            generation_unit_installed_capacity_mw DOUBLE, update_time_utc TIMESTAMP,
            source VARCHAR)
        """)
    run("""
        CREATE TABLE entsoe.actual_generation_output_per_generation_unit (
            generation_unit_code VARCHAR, date_time_utc TIMESTAMP,
            actual_generation_output_mw DOUBLE)
        """)
    # CURRENT: registry row covers the day. STALE: last row ended 2025-12-30.
    for (code, vt) in (("CURRENT", "NULL"), ("STALE", "TIMESTAMP '2025-12-30'"))
        run("""
            INSERT INTO entsoe.production_and_generation_units
                (generation_unit_code, generation_unit_name, generation_unit_type,
                 area_map_code, area_type_code, production_unit_status,
                 generation_unit_status, generation_unit_installed_capacity_mw,
                 valid_from, valid_to, area_display_name, generation_unit_location)
            VALUES ('$code', 'Unit $code', 'Fossil Gas', 'IT-NORTH', 'BZN',
                    'COMMISSIONED', 'COMMISSIONED', 500.0, TIMESTAMP '2020-01-01', $vt,
                    'Italy', 'x')
            """)
    end
    for (code, ts) in gen_rows
        run("""INSERT INTO entsoe.actual_generation_output_per_generation_unit
               VALUES ('$code', TIMESTAMP '$ts', 300.0)""")
    end
    DBInterface.close!(con)
    DuckDB.close(db)
end

function _fa_fleet(gen_rows; disable=false)
    G = parentmodule(Euphemia.get_generators)
    codes = String[]
    mktempdir() do dir
        extract = joinpath(dir, "extract.duckdb")
        _fa_build(extract; gen_rows=gen_rows)
        Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract)
        G.clear_generator_caches!()
        withenv("EUPHEMIA_DISABLE_FEED_ANCHOR" => (disable ? "1" : nothing)) do
            codes = sort([g.code for g in Euphemia.get_generators("IT-NORTH", _FA_DAY;
                                                                exclude_unavailable=false)])
        end
        G.clear_generator_caches!()
    end
    return codes
end

@testset "feed-anchored rescue window" begin
    prev = Euphemia.DATA_STORE[]
    prev_path = Euphemia.DUCKDB_PATH[]
    prev_ro = Euphemia.DUCKDB_READ_ONLY[]   # never reopen a shared extract writable
    prev_rw = Euphemia.DUCKDB_RESULTS_WRITABLE[]
    # Feed silent since 07-19 (> 60 days before the day): both units last seen then.
    silent = [("STALE", "2026-07-19 12:00:00"), ("CURRENT", "2026-07-19 12:00:00")]
    @test _fa_fleet(silent; disable=true) == ["CURRENT"]          # the defect
    @test _fa_fleet(silent) == ["CURRENT", "STALE"]               # the fix
    # Healthy feed (CURRENT reported up to the bound): STALE last generated in
    # June is outside the unchanged 60-day window and stays out.
    healthy = [("STALE", "2026-06-01 12:00:00"), ("CURRENT", "2026-09-12 12:00:00")]
    @test _fa_fleet(healthy) == ["CURRENT"]
    @test _fa_fleet(healthy) == _fa_fleet(healthy; disable=true)
    # Ex-ante: observations after the anchor bound (gate − latency) cannot move
    # the anchor. Here the only post-silence data point is 09-15 (after the
    # 09-13 10:00 bound), so the anchor stays at 07-19 and STALE (last seen
    # 05-01, before 07-19 − 60 d) stays out.
    leak = [("STALE", "2026-05-01 12:00:00"), ("CURRENT", "2026-07-19 12:00:00"),
            ("CURRENT", "2026-09-15 12:00:00")]
    G = parentmodule(Euphemia.get_generators)
    mktempdir() do dir
        extract = joinpath(dir, "extract.duckdb")
        _fa_build(extract; gen_rows=leak)
        Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract)
        G.clear_generator_caches!()
        lower = G._rescue_window_lower("IT-NORTH", _FA_DAY)
        @test occursin("2026-05-20", lower)                      # 07-19 12:00 − 60 d
        G.clear_generator_caches!()
    end
    @test_logs (:warn, r"feed stale") match_mode=:any _fa_fleet(silent)
    try; Euphemia.configure_data_store!(backend=prev, duckdb_path=prev_path, read_only=prev_ro, results_writable=prev_rw); catch; end
end
