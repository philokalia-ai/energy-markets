# Postgres check of bin/transfer_run_results.jl (NOT CI). Run ONLY against a PRIVATE throwaway Postgres
# (never production), phase by phase, each in its own process:
#   ENERGY_CONN_STR=<private> julia --project=. test/scripts/transfer_pg_check.jl setup  DIR
#   julia --project=. test/scripts/transfer_pg_check.jl write  DIR [stale]   # DuckDB-backend writers → DIR/results.duckdb
#   ENERGY_CONN_STR=<private> julia --project=. bin/transfer_run_results.jl --results-db DIR/results.duckdb
#   ENERGY_CONN_STR=<private> julia --project=. test/scripts/transfer_pg_check.jl check  DIR
#   ENERGY_CONN_STR=<private> julia --project=. test/scripts/transfer_pg_check.jl unmark DIR    # clear local done marks
# `setup` creates the forecast tables with the repo's DDL (ensure_forecast_tables), an input_corrections table, a
# realized horizon, and seeds a live slice; `write` applies the op sequence of test/test_run_results.jl; `check`
# asserts the Postgres state the transfer must leave. `write DIR stale` writes a retro op decided on a snapshot
# without live rows while Postgres has one (the transfer must refuse, leaving Postgres unchanged).
using Dates, Test
const PHASE, DIR = ARGS[1], ARGS[2]
const MD = Date(2026, 11, 25); const PM = DateTime(2026, 11, 23, 6, 30)
hours(md) = [DateTime(md - Day(1), Time(22)) + Hour(h) for h in 0:23]

if PHASE in ("setup", "check")
    ENV["EUPHEMIA_DATA_STORE"] = "postgres"; ENV["EUPHEMIA_PG_POOL"] = "2"   # test-bed limit: ≤ 4 connections
    using Euphemia, LibPQ, DataFrames
    pg(sql, args=Any[]) = Euphemia.withdb(c -> DataFrame(LibPQ.execute(c, sql, args)))
    const CV = Euphemia.ENERGY_PRICES_CODE_VERSION
end

if PHASE == "setup"
    Euphemia.ensure_forecast_tables()
    pg("""CREATE TABLE IF NOT EXISTS simulations.input_corrections (bidding_zone text NOT NULL, target text NOT NULL,
          date_time_utc timestamptz NOT NULL, corrected_mw double precision, model_tag text,
          created_at timestamptz DEFAULT now(), UNIQUE (bidding_zone, target, date_time_utc, model_tag))""")
    pg("CREATE SCHEMA IF NOT EXISTS entsoe")
    pg("CREATE TABLE IF NOT EXISTS entsoe.actual_total_load (date_time_utc timestamptz, area_map_code text, actual_total_load_mw double precision)")
    for t in ("simulations.forecast_prices", "simulations.forecast_prices_pre_reset", "simulations.forecast_scores",
              "simulations.input_corrections", "entsoe.actual_total_load")
        pg("DELETE FROM $t")
    end
    pg("DROP TABLE IF EXISTS simulations.transfer_log")
    pg("INSERT INTO entsoe.actual_total_load VALUES ('2026-11-20 23:00:00+00', 'GR', 5000.0)")
    for (z, p) in (("GR", 100.0), ("BG", 90.0)), h in hours(MD)
        pg("""INSERT INTO simulations.forecast_prices (market_date, date_time_utc, bidding_zone, price_eur_mwh,
              prediction_made_utc, lead_days, clearing_mode, code_version, input_mode, is_retro)
              VALUES (\$1, \$2, \$3, \$4, \$5, 2, 'multi_zone_eu', \$6, 'weather', false)""",
           Any[MD, Dates.format(h, "yyyy-mm-dd HH:MM:SS") * "+00", z, p, Dates.format(PM - Day(1), "yyyy-mm-dd HH:MM:SS") * "+00", CV])
    end
    println("setup done: seeded 48 live rows (GR, BG) for $MD lead 2")
end

if PHASE == "write"
    mkpath(DIR)
    inputs = joinpath(DIR, "inputs.duckdb"); results = joinpath(DIR, "results.duckdb")
    rm(results; force=true); rm(inputs; force=true)
    using DuckDB
    let db = DuckDB.DB(inputs); con = DBInterface.connect(db)
        DBInterface.execute(con, "CREATE SCHEMA entsoe")
        DBInterface.execute(con, "CREATE TABLE entsoe.actual_total_load (date_time_utc TIMESTAMP, area_map_code VARCHAR, actual_total_load_mw DOUBLE)")
        DBInterface.execute(con, "INSERT INTO entsoe.actual_total_load VALUES (TIMESTAMP '2026-11-20 23:00:00', 'GR', 5000.0)")
        DBInterface.close!(con); close(db)
    end
    ENV["EUPHEMIA_DATA_STORE"] = "duckdb"; ENV["EUPHEMIA_DUCKDB_PATH"] = inputs
    ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"; ENV["EUPHEMIA_RESULTS_WRITABLE"] = "true"
    ENV["EUPHEMIA_RESULTS_DB"] = results
    ENV["EUPHEMIA_FORECAST_NO_AUTORUN"] = "1"; ENV["INPUT_MODE"] = "weather"; ENV["EUPHEMIA_SCORE_NO_AUTORUN"] = "1"
    include(joinpath(@__DIR__, "..", "..", "bin", "daily_forecast.jl"))
    R(sql, args=Any[]) = Euphemia._results_exec(sql, args)
    Euphemia.ensure_run_results_tables!()
    slice(md, zones, p) = Dict(z => Dict(h => p for h in hours(md)) for z in zones)
    if length(ARGS) >= 3 && ARGS[3] == "stale"
        # the snapshot has no live rows for MD+3 lead 4; the check inserts one into Postgres before the transfer
        write_forecast!(MD + Day(3), 4, PM, slice(MD + Day(3), ["GR"], 3.0), "weather"; is_retro=true, reset_tag="t9")
        println("write stale done")
    else
        for (z, p) in (("GR", 100.0), ("BG", 90.0)), h in hours(MD)   # the fill's seed of the live slice
            R("INSERT INTO results_db.simulations.forecast_prices (market_date, date_time_utc, bidding_zone, price_eur_mwh, " *
              "prediction_made_utc, lead_days, clearing_mode, code_version, input_mode, is_retro) VALUES " *
              "(\$1, \$2, \$3, \$4, \$5, 2, 'multi_zone_eu', \$6, 'weather', false)", Any[MD, h, z, p, PM - Day(1), CV])
        end
        write_forecast!(MD, 2, PM, slice(MD, ["GR", "RO"], 120.0), "weather")                              # live
        write_forecast!(MD + Day(1), 3, PM, slice(MD + Day(1), ["GR"], 5.0), "weather"; is_retro=true, reset_tag="t1")
        withenv("EUPHEMIA_RETRO_SUPERSEDE" => "1") do                                                     # supersede
            write_forecast!(MD, 2, PM, slice(MD, ["GR"], 7.0), "weather"; is_retro=true, reset_tag="t2")
        end
        tag = first(ALONGSIDE_RESET_TAGS)
        write_forecast!(MD + Day(2), 1, PM, slice(MD + Day(2), ["GR"], 9.0), "weather"; is_retro=true, reset_tag=tag)
        write_forecast!(MD + Day(2), 1, PM, slice(MD + Day(2), ["GR"], 8.0), "weather"; is_retro=true, reset_tag=tag)
        Euphemia.results_transaction() do
            op = Euphemia.log_transfer_op!("input_corrections", Dict("day" => "2026-11-24", "n" => 1))
            R("INSERT INTO results_db.simulations.input_corrections VALUES ('IT-Sicily', 'solar', \$1, 900.0, 'm1', \$2)",
              Any[DateTime(2026, 11, 24, 10), op])
        end
        include(joinpath(@__DIR__, "..", "..", "bin", "score_forecasts.jl"))
        cm = (n_collapse_actual=1, n_collapse_pred=0, hits=0, false_alarms=0, hit_rate=0.0, false_alarm_rate=nothing)
        upsert_score!(MD, "GR", 2, CV, "weather", 24, 5.0, 1.0, 0.9, cm)
        update_q15!(MD, "GR", 2, CV, "weather", false, (n_q15=96, mae_q15=6.0, bias_q15=nothing, corr_q15=0.8,
                    shape_floor_q15=nothing, n_le0_q15_actual=0, n_le0_q15_pred=0, le0_q15_hits=0), "native")
        upsert_score!(MD, "GR", 2, CV, "weather", 24, 4.0, 1.0, 0.9, cm)
        log_score_transfer_ops!()
        println("write done: ", R("SELECT COUNT(*) AS n FROM results_db.simulations.transfer_ops").n[1], " op(s)")
    end
end

if PHASE == "unmark"
    using DuckDB
    db = DuckDB.DB(joinpath(DIR, "results.duckdb")); con = DBInterface.connect(db)
    DBInterface.execute(con, "UPDATE simulations.transfer_ops SET done_at = NULL, outcome = NULL")
    DBInterface.close!(con); close(db); println("unmarked")
end

if PHASE == "check"
    fp(md, lead) = pg("SELECT bidding_zone, is_retro, price_eur_mwh, reset_tag FROM simulations.forecast_prices " *
                      "WHERE market_date = \$1 AND lead_days = \$2 ORDER BY 1", Any[md, lead])
    @testset "Postgres after the transfer" begin
        s0 = fp(MD, 2)          # live GR/RO 120 + BG 90, then superseded by the t2 retro GR slice
        @test nrow(s0) == 24 && all(s0.is_retro) && all(s0.price_eur_mwh .== 7.0) && all(s0.reset_tag .== "t2")
        bk = pg("SELECT bidding_zone, COUNT(*) AS n, SUM(price_eur_mwh) AS s FROM simulations.forecast_prices_pre_reset GROUP BY 1 ORDER BY 1")
        @test bk.bidding_zone == ["BG", "GR", "RO"] && bk.n == [24, 24, 24] && bk.s == [24 * 90.0, 24 * 120.0, 24 * 120.0]
        s1 = fp(MD + Day(1), 3); @test nrow(s1) == 24 && all(s1.price_eur_mwh .== 5.0) && all(s1.is_retro)
        s2 = fp(MD + Day(2), 1); @test nrow(s2) == 24 && all(s2.price_eur_mwh .== 8.0)
        ic = pg("SELECT corrected_mw FROM simulations.input_corrections"); @test ic.corrected_mw == [900.0]
        sc = pg("SELECT mae, mae_q15, n_q15 FROM simulations.forecast_scores")
        @test nrow(sc) == 1 && sc.mae[1] == 4.0 && sc.mae_q15[1] == 6.0 && sc.n_q15[1] == 96
        tl = pg("SELECT COUNT(*) AS n FROM simulations.transfer_log"); @test tl.n[1] == 9
        tz = pg("SELECT MIN(date_time_utc AT TIME ZONE 'UTC') AS t FROM simulations.forecast_prices WHERE market_date = \$1", Any[MD])
        @test DateTime(tz.t[1]) == DateTime(MD - Day(1), Time(22))      # naive UTC → timestamptz kept the instant
        st = pg("SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_name LIKE '\\_p96t\\_%'")
        @test st.n[1] == 0                                               # stages dropped
    end
end
