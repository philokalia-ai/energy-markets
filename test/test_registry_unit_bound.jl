# cv42: the unit bound applies to the raw registry row, before the dedupe and
# before the outage derate. Runs the real get_generators queries against a tiny
# synthetic DuckDB extract, so it needs no Postgres.
#
# Standalone:  julia --project=. test/test_registry_unit_bound.jl

using Test
using Euphemia
using Dates
using DataFrames
using DuckDB
import DuckDB.DBInterface as DBInterface

const _DAY = Date(2026, 9, 20)

function _unit_row(code; cap, valid_from="2020-01-01", valid_to="NULL")
    vt = valid_to == "NULL" ? "NULL" : "TIMESTAMP '$valid_to'"
    return """('$code', 'Unit $code', 'Fossil Gas', 'IT-NORTH', 'BZN', 'COMMISSIONED',
               'COMMISSIONED', $cap, TIMESTAMP '$valid_from', $vt)"""
end

function _build_extract(path)
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
    rows = [
        _unit_row("OK";      cap=400.0),                               # plain valid unit
        _unit_row("LARGE";   cap=1600.0),                              # real large unit stays
        _unit_row("CORRUPT"; cap=22600.0),                             # only a corrupt row
        # A corrupt row that would win the dedupe (newest valid_from) over a valid one.
        _unit_row("SHADOW";  cap=800.0,   valid_from="2020-01-01"),
        _unit_row("SHADOW";  cap=23940.0, valid_from="2026-09-17"),
        # A corrupt row that an outage would derate below the bound.
        _unit_row("DERATED"; cap=24000.0),
    ]
    for r in rows
        run("""
            INSERT INTO entsoe.production_and_generation_units
                (generation_unit_code, generation_unit_name, generation_unit_type,
                 area_map_code, area_type_code, production_unit_status,
                 generation_unit_status, generation_unit_installed_capacity_mw,
                 valid_from, valid_to)
            VALUES $r
            """)
    end
    run("UPDATE entsoe.production_and_generation_units SET area_display_name = 'Italy', generation_unit_location = 'x'")
    DBInterface.close!(con)
    DuckDB.close(db)
end

@testset "cv42 registry unit bound on the raw row" begin
    G = parentmodule(Euphemia.get_generators)
    prev = Euphemia.DATA_STORE[]
    prev_path = Euphemia.DUCKDB_PATH[]
    mktempdir() do dir
        extract = joinpath(dir, "extract.duckdb")
        _build_extract(extract)
        Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract)
        G.clear_generator_caches!()

        @testset "no outages: corrupt rows go, valid rows stay" begin
            gens = Euphemia.get_generators("IT-NORTH", _DAY; exclude_unavailable=false)
            caps = Dict(g.code => g.p_max for g in gens)
            @test caps["OK"] == 400.0
            @test caps["LARGE"] == 1600.0
            @test !haskey(caps, "CORRUPT")
            @test !haskey(caps, "DERATED")
            # the dedupe keeps the valid row instead of losing the unit
            @test caps["SHADOW"] == 800.0
        end

        @testset "a partial outage cannot launder a corrupt row" begin
            # Seed the day's outages directly: the unavailability table is not
            # what is under test. Without the raw bound, LEAST(4000, 24000) = 4000
            # would pass as a plausible unit.
            G.clear_generator_caches!()
            lock(G._OUTAGE_DAY_CACHE_LOCK) do
                G._OUTAGE_DAY_CACHE[(_DAY, G.ctx_key())] = DataFrame(
                    asset_code=["DERATED", "OK"],
                    available_capacity_mw=[4000.0, 300.0],
                    stale_override=[false, false])
            end
            gens = Euphemia.get_generators("IT-NORTH", _DAY; exclude_unavailable=true)
            caps = Dict(g.code => g.p_max for g in gens)
            @test !haskey(caps, "DERATED")
            @test caps["OK"] == 300.0        # a real derate still applies
            @test caps["SHADOW"] == 800.0
        end

        @testset "rejected rows are reported" begin
            @test_logs (:warn, "Rejected corrupt registry capacity") (:warn, "Rejected corrupt registry capacity") (:warn, "Rejected corrupt registry capacity") match_mode=:any G._warn_quarantined_capacity_rows("IT-NORTH", _DAY)
        end
        G.clear_generator_caches!()
        try; Euphemia.configure_data_store!(backend=prev, duckdb_path=prev_path); catch; end
    end
end
