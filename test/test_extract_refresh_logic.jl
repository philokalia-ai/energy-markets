# Pure-logic tests for the extract builder/refresher helpers in
# bin/extract_common.jl: where-clause construction (build window + incremental
# watermark), month chunking, the open-meteo cell fetch window, and the
# append/seed machinery against an IN-MEMORY DuckDB with a stubbed source —
# no Postgres, no network, no extract file.

using Test
using Dates
using DataFrames
using DuckDB

include(joinpath(@__DIR__, "..", "bin", "extract_common.jl"))

@testset "Extract refresh logic" begin

    @testset "build_where_args — windowed tstz spec (historical SQL preserved)" begin
        spec = mkspec(schema="entsoe", table="day_ahead_total_load_forecast",
                      base_where="area_map_code = ANY(\$1)", base_args=Any[["GR", "BG"]],
                      ts_col="date_time_utc",
                      window=(Date(2026, 1, 1), Date(2026, 2, 1)),
                      sort_by="area_map_code, date_time_utc")
        (w, args) = build_where_args(spec)
        # Exactly the WHERE shape the original builder emitted — extracts stay
        # byte-comparable across the refactor.
        @test w == "area_map_code = ANY(\$1) AND " *
                   "date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC') AND " *
                   "date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')"
        @test args == Any[["GR", "BG"], Date(2026, 1, 1), Date(2026, 2, 1)]
        @test spec.refresh == :append   # ts_col present → append by default
    end

    @testset "build_where_args — full-table specs" begin
        # No window → base filter only (yfinance full history).
        spec = mkspec(schema="yfinance", table="ttf_f", ts_col="date", ts_tz=false)
        (w, args) = build_where_args(spec)
        @test w == "" && isempty(args)

        # No ts_col → :replace by default (mutable registry).
        reg = mkspec(schema="entsoe", table="production_and_generation_units",
                     base_where="area_map_code = ANY(\$1)", base_args=Any[["GR"]])
        @test reg.refresh == :replace
        @test build_where_args(reg)[1] == "area_map_code = ANY(\$1)"
    end

    @testset "incremental_where_args — watermark bounds" begin
        spec = mkspec(schema="entsoe", table="physical_flows",
                      base_where="(out_map_code = ANY(\$1))", base_args=Any[["GR"]],
                      ts_col="date_time_utc")
        wm = DateTime(2026, 7, 1, 22, 0, 0)
        (w, args) = incremental_where_args(spec, wm, Date(2026, 7, 1), Date(2026, 8, 1))
        # tz-aware source: naive-UTC watermark converted with AT TIME ZONE 'UTC'.
        @test w == "(out_map_code = ANY(\$1)) AND " *
                   "date_time_utc > (\$2::timestamp AT TIME ZONE 'UTC') AND " *
                   "date_time_utc >= (\$3::date::timestamp AT TIME ZONE 'UTC') AND " *
                   "date_time_utc < (\$4::date::timestamp AT TIME ZONE 'UTC')"
        @test args[2] == "2026-07-01 22:00:00.000"
        @test args[3] == Date(2026, 7, 1) && args[4] == Date(2026, 8, 1)

        # Naive source (weather measure_ts / yfinance date): no tz conversion.
        wspec = mkspec(source=:weather, schema="weather", table="city_forecast",
                       ts_col="measure_ts", ts_tz=false)
        (w2, _) = incremental_where_args(wspec, wm, Date(2026, 7, 1), Date(2026, 8, 1))
        @test w2 == "measure_ts > (\$1::timestamp) AND " *
                    "measure_ts >= (\$2::date::timestamp) AND " *
                    "measure_ts < (\$3::date::timestamp)"

        # ts_col-less specs cannot be appended.
        @test_throws ErrorException incremental_where_args(
            mkspec(schema="s", table="t"), wm, Date(2026, 7, 1), Date(2026, 8, 1))
    end

    @testset "month_ranges" begin
        @test month_ranges(Date(2026, 1, 15), Date(2026, 3, 10)) ==
              [(Date(2026, 1, 15), Date(2026, 2, 1)),
               (Date(2026, 2, 1), Date(2026, 3, 1)),
               (Date(2026, 3, 1), Date(2026, 3, 10))]
        @test month_ranges(Date(2026, 5, 1), Date(2026, 5, 1)) == Tuple{Date,Date}[]
        @test month_ranges(Date(2026, 5, 3), Date(2026, 5, 4)) ==
              [(Date(2026, 5, 3), Date(2026, 5, 4))]
    end

    @testset "cell_fetch_window (ERA5 ~5-day lag)" begin
        today = Date(2026, 7, 13)
        # Fresh extract: watermark covers up to the lag boundary → nothing.
        @test cell_fetch_window(DateTime(2026, 7, 8, 23), today) === nothing
        @test cell_fetch_window(DateTime(2026, 7, 10, 23), today) === nothing
        # Behind: fetch from the watermark's (possibly partial) day to today-5.
        @test cell_fetch_window(DateTime(2026, 7, 1, 23), today) ==
              (Date(2026, 7, 1), Date(2026, 7, 8))
        # Partial last day is re-fetched (caller filters h > watermark).
        @test cell_fetch_window(DateTime(2026, 7, 8, 11), today) ==
              (Date(2026, 7, 8), Date(2026, 7, 8))
        # Empty table bootstraps a 400-day window.
        @test cell_fetch_window(nothing, today) == (Date(2025, 6, 3), Date(2026, 7, 8))
        # Custom lag.
        @test cell_fetch_window(DateTime(2026, 7, 1, 23), today; lag_days=10) ==
              (Date(2026, 7, 1), Date(2026, 7, 3))
    end

    @testset "entsoe/weather spec wiring" begin
        specs = entsoe_table_specs(["GR", "BG"]; start_date=Date(2026, 1, 1),
                                   end_date=Date(2026, 6, 30), agen_back_days=90)
        byname = Dict("$(s.schema).$(s.table)" => s for s in specs)
        # Mutable registry-like tables are replaced, time series appended.
        @test byname["entsoe.production_and_generation_units"].refresh == :replace
        @test byname["entsoe.unavailability_of_production_and_generation_units"].refresh == :replace
        @test byname["entsoe.aggregated_hydro_storage_filling_rate"].refresh == :replace
        @test byname["entsoe.physical_flows"].refresh == :append
        agen = byname["entsoe.actual_generation_output_per_generation_unit"]
        @test agen.window == (Date(2026, 1, 1) - Day(90), Date(2026, 7, 1))
        @test byname["entsoe.aggregated_generation_per_type"].window ==
              (Date(2026, 1, 1) - Day(400), Date(2026, 7, 1))

        wspecs = weather_table_specs(back_days=400, today=Date(2026, 7, 13))
        wby = Dict(s.table => s for s in wspecs)
        @test wby["city"].refresh == :replace
        @test wby["city_forecast"].refresh == :append && !wby["city_forecast"].ts_tz
        @test wby["city_forecast"].window == (Date(2025, 6, 8), Date(2026, 7, 30))
        @test wby["city_forecast_vintage"].window === nothing   # full history
        @test all(s.source == :weather for s in wspecs)
    end

    @testset "seed_cell_hourly! + append machinery (in-memory DuckDB)" begin
        db = DuckDB.DB()   # in-memory
        con = DBInterface.connect(db)

        # --- seed from a tiny CSV, zone-filtered, source='era5' ---
        csv = joinpath(mktempdir(), "cells.csv")
        write(csv,
              "zone,lat,lon,h,v100,ghi\n" *
              "GR,38.0,23.7,2026-07-01T00:00,12.5,0.0\n" *
              "GR,38.0,23.7,2026-07-01T01:00,13.1,0.0\n" *
              "BG,42.7,23.3,2026-07-01T00:00,8.0,0.0\n" *
              "DE_LU,52.5,13.4,2026-07-01T00:00,20.0,0.0\n")
        n = seed_cell_hourly!(con, csv; zones=["GR", "BG"])
        @test n == 3   # DE_LU filtered out
        df = DataFrame(DBInterface.execute(con,
            "SELECT zone, h, v100, source FROM weather.cell_hourly ORDER BY zone, h"))
        @test df.zone == ["BG", "GR", "GR"]
        @test all(df.source .== "era5")
        @test df.h[2] == DateTime(2026, 7, 1, 0)
        @test df.v100[3] == 13.1

        # --- duckdb helpers ---
        chspec = mkspec(source=:fake, schema="weather", table="cell_hourly", ts_col="h")
        @test duckdb_table_exists(con, "weather", "cell_hourly")
        @test !duckdb_table_exists(con, "weather", "nope")
        @test duckdb_max_ts(con, chspec) == DateTime(2026, 7, 1, 1)

        # --- append_incremental! with a stubbed source: verifies the watermark
        #     is threaded into the source SQL and new rows are inserted ---
        DBInterface.execute(con, "CREATE SCHEMA IF NOT EXISTS entsoe")
        DBInterface.execute(con,
            "CREATE TABLE entsoe.tiny(zone TEXT, date_time_utc TIMESTAMP, mw DOUBLE)")
        DBInterface.execute(con,
            "INSERT INTO entsoe.tiny VALUES ('GR', TIMESTAMP '2026-07-01 22:00:00', 1.0)")
        seen_sql = String[]
        seen_args = Any[]
        QUERY_FNS[:fake] = function (sql, args=Any[])
            push!(seen_sql, String(sql))
            push!(seen_args, args)
            if occursin("information_schema", sql)
                return DataFrame(column_name=["zone", "date_time_utc", "mw"],
                                 data_type=["text", "timestamp with time zone", "double precision"])
            end
            return DataFrame(zone=["GR"], date_time_utc=[DateTime(2026, 7, 2, 5)], mw=[2.0])
        end
        spec = mkspec(source=:fake, schema="entsoe", table="tiny",
                      base_where="zone = ANY(\$1)", base_args=Any[["GR"]],
                      ts_col="date_time_utc", sort_by="zone, date_time_utc")
        n = append_incremental!(con, spec; today=Date(2026, 7, 2), horizon_days=3)
        # rewindow_days=14 (default): rows from watermark−14d on are deleted and
        # re-fetched, and the fetch is split per month range (Jun 17.., Jul 1..).
        # The stub answers every range with the same one row, so 2 inserts.
        @test n == 2
        @test duckdb_rowcount(con, spec) == 2
        @test duckdb_max_ts(con, spec) == DateTime(2026, 7, 2, 5)
        # The data query carried the naive-UTC watermark + tz conversion.
        data_sql = last(seen_sql)
        @test occursin("date_time_utc > (\$2::timestamp AT TIME ZONE 'UTC')", data_sql)
        @test occursin("\"date_time_utc\" AT TIME ZONE 'UTC' AS \"date_time_utc\"", data_sql)  # projection
        # watermark = (max_ts − rewindow_days) − 1 s, as naive UTC text
        @test last(seen_args)[2] == "2026-06-16 23:59:59.000"

        # Errors cleanly when a source has no registered query function.
        badspec = mkspec(source=:nope, schema="entsoe", table="tiny", ts_col="date_time_utc")
        @test_throws ErrorException append_incremental!(con, badspec; today=Date(2026, 7, 2))

        DBInterface.close!(con)
        close(db)
        delete!(QUERY_FNS, :fake)
    end
end

println("Extract refresh logic tests passed.")
