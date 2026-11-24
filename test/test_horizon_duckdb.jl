# bin/horizon_forecast.jl under the DuckDB store (fill → run → transfer): the weekly-persistence leads 2..7
# read the seeded forecast_prices and actual_total_load from the run-local fill and write each slice to the
# results DuckDB plus one forecast_slice transfer op (delete_scope "slice"); never LibPQ (the Postgres guard
# would raise). DB-free: temp DuckDB files. Own process (it configures the data store):
#   julia --project=. test/test_horizon_duckdb.jl
using Test, Dates, DataFrames, DuckDB, JSON

const TMP = mktempdir()
const INPUTS = joinpath(TMP, "inputs.duckdb")
const RESULTS = joinpath(TMP, "results.duckdb")
let db = DuckDB.DB(INPUTS); con = DBInterface.connect(db)   # the fill: the realized horizon only
    DBInterface.execute(con, "CREATE SCHEMA entsoe")
    DBInterface.execute(con, "CREATE TABLE entsoe.actual_total_load (date_time_utc TIMESTAMP, area_map_code VARCHAR, actual_total_load_mw DOUBLE)")
    DBInterface.execute(con, "INSERT INTO entsoe.actual_total_load VALUES (TIMESTAMP '2026-11-14 22:00:00', 'GR', 5000.0)")
    DBInterface.close!(con); close(db)
end
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"; ENV["EUPHEMIA_DUCKDB_PATH"] = INPUTS
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"; ENV["EUPHEMIA_RESULTS_WRITABLE"] = "true"; ENV["EUPHEMIA_RESULTS_DB"] = RESULTS
ENV["ENERGY_CONN_STR"] = "host=127.0.0.1 port=1 dbname=none user=none connect_timeout=1"   # never reachable
using Euphemia
const E = Euphemia
lock(() -> E._duckdb_drop_connection!(), E._DUCKDB_LOCK)
E.mark_run_local_fill!(INPUTS; windows=[("entsoe", "actual_total_load", Date(1900, 1, 1), Date(2999, 12, 31))])
include(joinpath(@__DIR__, "..", "bin", "horizon_forecast.jl"))

R(sql, args=Any[]) = E._results_exec(sql, args)
@testset "horizon_forecast on the DuckDB store" begin
    E.ensure_run_results_tables!()
    E.mark_results_seeded!(E._READBACK_TABLES)
    base = Date(2026, 11, 14)
    # the fill's seed: lead-1 entsoe slices for the proxies P = T - 7 (T = base + 2..7), two zones; GR also
    # carries a newer-cv duplicate for one P (earliest-frozen wins) and lead 3 already has a persistence slice
    for n in 2:7
        P = base + Day(n) - Day(7)
        for (z, p0) in (("GR", 100.0), ("BG", 50.0)), (k, h) in enumerate(expected_market_day_hours(P))
            R("INSERT INTO results_db.simulations.forecast_prices (market_date, date_time_utc, bidding_zone, " *
              "price_eur_mwh, prediction_made_utc, lead_days, clearing_mode, code_version, input_mode, is_retro) " *
              "VALUES (\$1, \$2, \$3, \$4, \$5, 1, 'multi_zone_eu', 45, 'entsoe', false)",
              Any[P, h, z, p0 + n + k / 100, DateTime(P - Day(1), Time(17))])
        end
        for (k, q) in enumerate(expected_market_day_slots(P, 15))   # RO: a cv46 quarter-hour lead-1 slice
            R("INSERT INTO results_db.simulations.forecast_prices (market_date, date_time_utc, bidding_zone, " *
              "price_eur_mwh, prediction_made_utc, lead_days, clearing_mode, code_version, input_mode, is_retro, " *
              "resolution_code) VALUES (\$1, \$2, 'RO', \$3, \$4, 1, 'multi_zone_eu', 45, 'entsoe', false, 'PT15M')",
              Any[P, q, 70.0 + n + k / 1000, DateTime(P - Day(1), Time(17))])
        end
    end
    P4 = base + Day(4) - Day(7)
    for h in expected_market_day_hours(P4)
        R("INSERT INTO results_db.simulations.forecast_prices (market_date, date_time_utc, bidding_zone, price_eur_mwh, " *
          "prediction_made_utc, lead_days, clearing_mode, code_version, input_mode, is_retro) VALUES " *
          "(\$1, \$2, 'GR', -1.0, \$3, 1, 'multi_zone_eu', 46, 'entsoe', false)", Any[P4, h, DateTime(P4 - Day(1), Time(19))])
    end
    T3 = base + Day(3)
    for h in expected_market_day_hours(T3)
        R("INSERT INTO results_db.simulations.forecast_prices (market_date, date_time_utc, bidding_zone, price_eur_mwh, " *
          "prediction_made_utc, lead_days, clearing_mode, code_version, input_mode, is_retro) VALUES " *
          "(\$1, \$2, 'GR', 7.0, \$3, 3, 'multi_zone_eu', 45, 'entsoe_persist', false)", Any[T3, h, DateTime(base - Day(1))])
    end
    redirect_stdout(devnull) do; main(; asof=DateTime(2026, 11, 14, 7)); end
    ops = R("SELECT op_id, kind, params FROM results_db.simulations.transfer_ops ORDER BY op_id")
    @test nrow(ops) == 5 && all(ops.kind .== "forecast_slice")                 # leads 2,4,5,6,7 (3: no-clobber)
    p = [JSON.parse(x) for x in ops.params]
    @test [q["lead_days"] for q in p] == [2, 4, 5, 6, 7]
    @test all(q["delete_scope"] == "slice" && q["plan"] == "insert" && q["input_mode"] == "entsoe_persist" &&
              q["is_retro"] == false && q["zones"] == ["BG", "GR", "RO"] for q in p)
    pers = R("SELECT * FROM results_db.simulations.forecast_prices WHERE input_mode = 'entsoe_persist' ORDER BY market_date, bidding_zone, date_time_utc")
    @test nrow(pers) == 5 * (2 * 24 + 96) + 24                                     # + the untouched lead-3 slice
    T2 = base + Day(2)
    g2 = pers[(pers.market_date .== T2) .& (pers.bidding_zone .== "GR"), :]
    P2 = T2 - Day(7)
    @test g2.date_time_utc == expected_market_day_hours(P2) .+ Day(7)            # hours shifted +7 days
    @test g2.price_eur_mwh == [100.0 + 2 + k / 100 for k in 1:24]                  # the proxy's prices
    @test all(g2.prediction_made_utc .== DateTime(2026, 11, 14, 7)) && all(g2.code_version .== CV)
    @test all(pers[(pers.market_date .!= T3) .& (pers.bidding_zone .!= "RO"), :resolution_code] .== "PT60M")
    r2 = pers[(pers.market_date .== T2) .& (pers.bidding_zone .== "RO"), :]   # quarter sources are complete too
    @test nrow(r2) == 96 && all(r2.resolution_code .== "PT15M")
    @test r2.date_time_utc == expected_market_day_slots(P2, 15) .+ Day(7)
    @test all(pers[pers.market_date .== base + Day(4) .&& pers.bidding_zone .== "GR", :price_eur_mwh] .> 0)   # cv45 (earliest) wins
    @test all(pers[pers.market_date .== T3, :price_eur_mwh] .== 7.0)              # lead 3 not clobbered
    @test R("SELECT count(*) AS n FROM results_db.simulations.transfer_forecast_rows").n[1] == 5 * (2 * 24 + 96)
end

@testset "the transfer renders the slice-wide delete for these ops" begin
    E._results_exec("CHECKPOINT")
    lock(E._DUCKDB_LOCK) do; E._duckdb_drop_connection!(); end
    GC.gc(); GC.gc()
    jl = joinpath(Sys.BINDIR, Base.julia_exename())
    env = Dict(k => ENV[k] for k in ("PATH", "HOME", "USER", "LANG", "JULIA_DEPOT_PATH", "JULIA_NUM_THREADS",
                                     "EUPHEMIA_DUCKDB_EXT_DIR", "TMPDIR") if haskey(ENV, k))
    cmd = `$jl --startup-file=no --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__, "..", "bin", "transfer_run_results.jl")) --dry-run --results-db $RESULTS`
    out = read(setenv(cmd, env), String)
    T2 = Date(2026, 11, 16)
    @test occursin("DELETE FROM simulations.forecast_prices WHERE market_date = DATE '$T2' AND lead_days = 2 AND input_mode = 'entsoe_persist';", out)
    @test !occursin("input_mode = 'entsoe_persist' AND is_retro = false AND bidding_zone", out)
    @test occursin("REFUSING, the market day has realized", out)                  # the live guards apply
    @test count("-- op ", out) == 5
end
