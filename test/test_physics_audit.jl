# Tests for the physics-consistency data audit (src/db/physics_audit.jl).
#
# Fully self-contained: builds a synthetic DuckDB extract with PLANTED
# violations of each physical invariant next to clean data, points the library
# at it, and asserts every planted anomaly is found — and nothing else is. The
# planted cases mirror the ledgered incidents the audit exists to catch
# proactively (the PT shifted solar bell, the SI missing load-forecast hours,
# the IT-CSOUTH 13 GW·10³ registry row, the SI reservoir zero-glitch weeks,
# the FR mixed-resolution day).
#
# Standalone:  julia --project=. test/test_physics_audit.jl

using Test
using Euphemia
using Dates
using DataFrames
using DuckDB
import DuckDB.DBInterface as DBInterface

function _build_audit_extract(path)
    db = DuckDB.DB(path)
    con = DBInterface.connect(db)
    DBInterface.execute(con, "CREATE SCHEMA entsoe")

    # --- RES forecasts: GR June 2026, a normal solar bell every day (clean
    # climatology), EXCEPT day 15 whose bell is shifted 13 h into the night
    # (the PT 2025-06-01/02 incident shape). ES gets 600 MW CSP night rows,
    # which must NOT be flagged (below the documented CSP tolerance).
    DBInterface.execute(
        con,
        """
CREATE TABLE entsoe.generation_forecasts_for_wind_and_solar(
    date_time_utc TIMESTAMP, resolution_code VARCHAR, area_map_code VARCHAR,
    area_type_code VARCHAR, production_type VARCHAR,
    day_ahead_generation_forecast_mw DOUBLE)""",
    )
    bell(h) = max(0.0, 3000.0 * sin(π * (h - 4) / 15))   # >0 for UTC hours 5..18
    # Day 15's planted shape: the entire bell displaced into the deep-night
    # block (22:00–02:00) with zero everywhere else — daytime fully lost.
    shifted(h) = (h >= 22 || h <= 2) ? 3000.0 : 0.0
    rows = String[]
    for d = 1:28, h = 0:23
        fc = d == 15 ? shifted(h) : bell(h)
        # day 25: GR carries NO solar rows at all (the ES 2026-06-11 class)
        d == 25 || push!(
            rows,
            "('2026-06-$(lpad(d, 2, '0')) $(lpad(h, 2, '0')):00:00', 'PT60M', " *
            "'GR', 'BZN', 'Solar', $fc)",
        )
        # ES: same bell plus genuine CSP output at night (clean)
        es = max(bell(h), 600.0)
        push!(
            rows,
            "('2026-06-$(lpad(d, 2, '0')) $(lpad(h, 2, '0')):00:00', 'PT60M', " *
            "'ES', 'BZN', 'Solar', $es)",
        )
    end
    # day 20: a second resolution for GR solar (resolution_mix)
    for q in ("00:00:00", "00:15:00", "00:30:00", "00:45:00")
        push!(rows, "('2026-06-20 $q', 'PT15M', 'GR', 'BZN', 'Solar', 0.0)")
    end
    DBInterface.execute(
        con,
        "INSERT INTO entsoe.generation_forecasts_for_wind_and_solar VALUES " *
        join(rows, ","),
    )

    # --- Load forecasts: GR constant 5000 MW June 2026; planted:
    # day 10 hour 7 at 10 MW (bounds low), day 12 hour 12 at 20000 MW (bounds
    # high), day 18 missing hours 6 and 7 (incomplete interior day).
    DBInterface.execute(
        con,
        """
CREATE TABLE entsoe.day_ahead_total_load_forecast(
    date_time_utc TIMESTAMP, resolution_code VARCHAR, area_map_code VARCHAR,
    area_type_code VARCHAR, total_load_mw DOUBLE)""",
    )
    rows = String[]
    for d = 1:28, h = 0:23
        d == 18 && h in (6, 7) && continue
        mw = d == 10 && h == 7 ? 10.0 : (d == 12 && h == 12 ? 20000.0 : 5000.0)
        push!(
            rows,
            "('2026-06-$(lpad(d, 2, '0')) $(lpad(h, 2, '0')):00:00', 'PT60M', " *
            "'GR', 'BZN', $mw)",
        )
    end
    DBInterface.execute(
        con,
        "INSERT INTO entsoe.day_ahead_total_load_forecast VALUES " * join(rows, ","),
    )

    # --- Registry: one plausible unit, one 13,068,005 MW row (the cv24
    # incident), one unit with overlapping validity windows at different caps.
    DBInterface.execute(
        con,
        """
CREATE TABLE entsoe.production_and_generation_units(
    area_map_code VARCHAR, generation_unit_code VARCHAR,
    generation_unit_installed_capacity_mw DOUBLE,
    valid_from DATE, valid_to DATE)""",
    )
    DBInterface.execute(
        con,
        """
INSERT INTO entsoe.production_and_generation_units VALUES
('GR', 'UNIT-CLEAN', 400.0, DATE '2020-01-01', NULL),
('IT-CSOUTH', 'UNIT-CORRUPT', 13068005.0, DATE '2025-12-31', NULL),
('GR', 'UNIT-OVERLAP', 200.0, DATE '2020-01-01', DATE '2026-01-01'),
('GR', 'UNIT-OVERLAP', 250.0, DATE '2025-06-01', NULL),
('GR', 'UNIT-OVERLAP2', 100.0, DATE '2019-01-01', NULL),
('GR', 'UNIT-OVERLAP2', 120.0, DATE '2024-01-01', NULL),
('GR', 'UNIT-UPRATED', 100.0, DATE '2020-01-01', NULL),
('GR', 'UNIT-MIXUP', 100.0, DATE '2020-01-01', NULL)""",
    )

    # --- Per-unit output: UNIT-UPRATED runs at 130 MW for 3 h (1.3x cap →
    # :warn), UNIT-MIXUP hits 250 MW (2.5x → :error), UNIT-CLEAN stays below.
    DBInterface.execute(
        con,
        """
CREATE TABLE entsoe.actual_generation_output_per_generation_unit(
    generation_unit_code VARCHAR, date_time_utc TIMESTAMP,
    actual_generation_output_mw DOUBLE)""",
    )
    DBInterface.execute(
        con,
        """
INSERT INTO entsoe.actual_generation_output_per_generation_unit VALUES
('UNIT-UPRATED', TIMESTAMP '2026-06-05 10:00:00', 130.0),
('UNIT-UPRATED', TIMESTAMP '2026-06-05 11:00:00', 130.0),
('UNIT-UPRATED', TIMESTAMP '2026-06-05 12:00:00', 130.0),
('UNIT-MIXUP',   TIMESTAMP '2026-06-06 10:00:00', 250.0),
('UNIT-CLEAN',   TIMESTAMP '2026-06-05 10:00:00', 390.0)""",
    )

    # --- Reservoirs: NO5 clean seasonal series; SI one zero-glitch week
    # (drops 2600 → 0 → 2600, the ledgered shape).
    DBInterface.execute(
        con,
        """
CREATE TABLE entsoe.aggregated_hydro_storage_filling_rate(
    area_map_code VARCHAR, area_type_code VARCHAR, year INTEGER,
    week INTEGER, stored_energy_mwh DOUBLE)""",
    )
    rows = String[]
    for w = 1:40
        push!(rows, "('NO5', 'BZN', 2026, $w, $(1.0e6 + 2.0e4 * w))")
        push!(rows, "('SI', 'BZN', 2026, $w, $(w == 20 ? 0.0 : 2600.0))")
    end
    DBInterface.execute(
        con,
        "INSERT INTO entsoe.aggregated_hydro_storage_filling_rate VALUES " *
        join(rows, ","),
    )

    # --- Physical flows: GR→BG ~1000 MW for 28 days with ONE 5000 MW hour
    # (unit-error spike); BG→RS a 30 MW trickle border with a 200 MW hour that
    # must be ignored (p99 below the floor).
    DBInterface.execute(
        con,
        """
CREATE TABLE entsoe.physical_flows(
    date_time_utc TIMESTAMP, out_area_map_code VARCHAR, in_area_map_code VARCHAR,
    out_area_type_code VARCHAR, in_area_type_code VARCHAR, flow_mw DOUBLE)""",
    )
    rows = String[]
    for d = 1:28, h = 0:23
        f = d == 21 && h == 3 ? 5000.0 : 1000.0
        push!(
            rows,
            "('2026-06-$(lpad(d, 2, '0')) $(lpad(h, 2, '0')):00:00', " *
            "'GR', 'BG', 'BZN', 'BZN', $f)",
        )
        push!(
            rows,
            "('2026-06-$(lpad(d, 2, '0')) $(lpad(h, 2, '0')):00:00', " *
            "'BG', 'RS', 'BZN', 'BZN', $(d == 21 && h == 3 ? 200.0 : 30.0))",
        )
    end
    DBInterface.execute(con, "INSERT INTO entsoe.physical_flows VALUES " * join(rows, ","))

    # --- Prices: clean except one 9999 €/MWh row (above the harmonized cap).
    DBInterface.execute(
        con,
        """
CREATE TABLE entsoe.energy_prices(
    date_time_utc TIMESTAMP, map_code VARCHAR, contract_type VARCHAR,
    currency VARCHAR, price_currency_mwh DOUBLE)""",
    )
    DBInterface.execute(
        con,
        """
INSERT INTO entsoe.energy_prices VALUES
(TIMESTAMP '2026-06-05 10:00:00', 'GR', 'Day-ahead', 'EUR', 95.0),
(TIMESTAMP '2026-06-05 11:00:00', 'GR', 'Day-ahead', 'EUR', 9999.0),
(TIMESTAMP '2026-06-05 11:00:00', 'GR', 'Intraday', 'EUR', 99999.0),
(TIMESTAMP '2026-06-05 11:00:00', 'UA_IPS', 'Day-ahead', 'UAH', 14614.0)""",
    )

    DBInterface.execute(con, "CHECKPOINT")
    DBInterface.close!(con)
    close(db)
end

@testset "Physics audit" begin
    extract = joinpath(mktempdir(), "audit_test.duckdb")
    _build_audit_extract(extract)
    Euphemia.configure_data_store!(backend = :duckdb, duckdb_path = extract)

    try
        findings = run_physics_audit(Date(2026, 6, 1), Date(2026, 6, 29); verbose = false)

        @testset "solar_night — the shifted-bell day, and only it" begin
            f = findings[findings.check .== "solar_night", :]
            @test nrow(f) == 1
            @test f.zone[1] == "GR" && f.period[1] == "2026-06-15"
            @test f.severity[1] == "error"
            @test f.value[1] ≈ 3000.0 atol = 50   # the displaced peak
            # ES's 600 MW CSP nights stay below the documented tolerance
            @test !any(findings.zone .== "ES")
        end

        @testset "solar_day_missing — shifted day + fully absent day" begin
            f = sort(findings[findings.check .== "solar_day_missing", :], :period)
            @test nrow(f) == 2
            @test all(f.zone .== "GR")
            @test f.period == ["2026-06-15", "2026-06-25"]
            @test occursin("no usable solar forecast", f.detail[2])
        end

        @testset "load_bounds — planted low and high hours" begin
            f = sort(findings[findings.check .== "load_bounds", :], :period)
            @test nrow(f) == 2
            @test f.period == ["2026-06-10", "2026-06-12"]
            @test f.value[1] ≈ 10.0      # the 10 MW hour
            @test f.value[2] ≈ 20000.0   # the 20 GW hour
        end

        @testset "load_day_incomplete — interior day with 22/24 hours" begin
            f = findings[findings.check .== "load_day_incomplete", :]
            @test nrow(f) == 1
            @test f.period[1] == "2026-06-18" && f.value[1] == 22
        end

        @testset "resolution_mix — the two-resolution day" begin
            f = findings[findings.check .== "resolution_mix", :]
            @test nrow(f) == 1
            @test f.zone[1] == "GR" && f.period[1] == "2026-06-20"
        end

        @testset "registry — corrupt capacity + overlapping validity" begin
            f = findings[findings.check .== "registry_bounds", :]
            @test nrow(f) == 1
            @test f.zone[1] == "IT-CSOUTH" && f.value[1] == 13068005.0
            @test f.severity[1] == "error"
            o = findings[findings.check .== "registry_overlap", :]
            # UNIT-OVERLAP (dated windows) and UNIT-OVERLAP2 (both valid_to
            # NULL — the `missing` path that real registries exercise)
            @test nrow(o) == 2
            @test any(occursin.("UNIT-OVERLAP:", o.detail))
            @test any(occursin.("UNIT-OVERLAP2:", o.detail))
            @test all(o.severity .== "warn")
        end

        @testset "unit_output_above_capacity — uprate warn, mix-up error" begin
            f = findings[findings.check .== "unit_output_above_capacity", :]
            @test nrow(f) == 2
            warn = f[occursin.("UNIT-UPRATED", f.detail), :]
            err = f[occursin.("UNIT-MIXUP", f.detail), :]
            @test nrow(warn) == 1 && warn.severity[1] == "warn" && warn.n[1] == 3
            @test nrow(err) == 1 && err.severity[1] == "error"
            @test !any(occursin.("UNIT-CLEAN", f.detail))
        end

        @testset "reservoir_anomaly — the zero-glitch week, clean zone silent" begin
            f = findings[findings.check .== "reservoir_anomaly", :]
            @test nrow(f) == 2            # the drop into week 20 and the recovery
            @test all(f.zone .== "SI")
            @test Set(f.period) == Set(["2026-W20", "2026-W21"])
        end

        @testset "flow_spike — unit-error hour; trickle border ignored" begin
            f = findings[findings.check .== "flow_spike", :]
            @test nrow(f) == 1
            @test f.zone[1] == "GR->BG" && f.n[1] == 1 && f.value[1] ≈ 5000.0
            @test f.severity[1] == "warn"
        end

        @testset "price_caps — Day-ahead only, info severity" begin
            f = findings[findings.check .== "price_caps", :]
            @test nrow(f) == 1
            @test f.zone[1] == "GR" && f.n[1] == 1 && f.value[1] ≈ 9999.0
            @test f.severity[1] == "info"
        end

        @testset "summary + JSON report round-trip" begin
            s = audit_summary(findings)
            @test sum(s.findings) == nrow(findings)
            path = joinpath(mktempdir(), "audit.json")
            write_audit_json(findings, path; window_start = Date(2026, 6, 1))
            txt = read(path, String)
            @test occursin("\"solar_night\"", txt) && occursin("\"summary\"", txt)
        end

        @testset "check subset + zone filter" begin
            only_load = run_physics_audit(
                Date(2026, 6, 1),
                Date(2026, 6, 29);
                checks = [:load_bounds],
                verbose = false,
            )
            @test all(only_load.check .== "load_bounds")
            no_gr = run_physics_audit(
                Date(2026, 6, 1),
                Date(2026, 6, 29);
                zones = ["ES"],
                checks = [:solar_night, :load_bounds],
                verbose = false,
            )
            @test isempty(no_gr)
        end
    finally
        # Restore whatever backend the suite was running under (same pattern
        # as test_duckdb_perf_paths.jl).
        try
            Euphemia.configure_data_store!(backend = :postgres)
        catch
        end
    end
end
