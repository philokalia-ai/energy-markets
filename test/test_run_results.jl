# DuckDB-backend result writers (fill → run → transfer, owner rule 2026-11-23): write_forecast!,
# emit_input_corrections!'s store, the scorer's upsert/q15 — applied to the run-local results DuckDB with the
# Postgres semantics, each logging transfer ops (keys/params only). DB-free: temp DuckDB files. Runs in its own
# process (it configures the data store), from runtests.jl or directly:
#   julia --project=. test/test_run_results.jl
using Test, Dates, DataFrames, DuckDB, JSON

const TMP = mktempdir()
const INPUTS = joinpath(TMP, "inputs.duckdb")
const RESULTS = joinpath(TMP, "results.duckdb")
let db = DuckDB.DB(INPUTS); con = DBInterface.connect(db)   # a filled input extract: just the realized horizon
    DBInterface.execute(con, "CREATE SCHEMA entsoe")
    DBInterface.execute(con, "CREATE TABLE entsoe.actual_total_load (date_time_utc TIMESTAMP, area_map_code VARCHAR, actual_total_load_mw DOUBLE)")
    DBInterface.execute(con, "INSERT INTO entsoe.actual_total_load VALUES (TIMESTAMP '2026-11-20 23:00:00', 'GR', 5000.0)")
    DBInterface.close!(con); close(db)
end
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"; ENV["EUPHEMIA_DUCKDB_PATH"] = INPUTS
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"; ENV["EUPHEMIA_RESULTS_WRITABLE"] = "true"
ENV["EUPHEMIA_RESULTS_DB"] = RESULTS
ENV["EUPHEMIA_FORECAST_NO_AUTORUN"] = "1"; ENV["INPUT_MODE"] = "weather"
using Euphemia
# a run-local fill (as fill_run_duckdb writes it): arms the strict read guard and the read-back redirect (the
# writers' read-backs — no-clobber checks, cv32 deltas, the scorer — see results_db, which the fill seeds)
# (Euphemia's init already opened the store: drop that connection first; the next query reopens it, guard armed)
lock(() -> Euphemia._duckdb_drop_connection!(), Euphemia._DUCKDB_LOCK)
Euphemia.mark_run_local_fill!(INPUTS; windows=[("entsoe", "actual_total_load", Date(1900, 1, 1), Date(2999, 12, 31))])
include(joinpath(@__DIR__, "..", "bin", "daily_forecast.jl"))   # write_forecast!, CV, CLEARING_MODE

R(sql, args=Any[]) = Euphemia._results_exec(sql, args)
ops() = R("SELECT op_id, kind, params FROM results_db.simulations.transfer_ops ORDER BY op_id")
fp(where="TRUE", args=Any[]) = R("SELECT * FROM results_db.simulations.forecast_prices WHERE $where " *
                                 "ORDER BY bidding_zone, date_time_utc", args)
hours(md) = [DateTime(md - Day(1), Time(22)) + Hour(h) for h in 0:23]
slice(md, zones, p) = Dict(z => Dict(h => p for h in hours(md)) for z in zones)

@testset "run-local results DuckDB writers" begin
    @test Euphemia.results_to_duckdb()
    Euphemia.ensure_run_results_tables!()
    Euphemia.mark_results_seeded!(Euphemia._READBACK_TABLES)   # what the fill's seed step records
    md = Date(2026, 11, 25); pm = DateTime(2026, 11, 23, 6, 30)
    # the fill's seed: an existing live slice for GR and BG (what Postgres held at fill time)
    for (z, p) in (("GR", 100.0), ("BG", 90.0)), h in hours(md)
        R("INSERT INTO results_db.simulations.forecast_prices (market_date, date_time_utc, bidding_zone, " *
          "price_eur_mwh, prediction_made_utc, lead_days, clearing_mode, code_version, input_mode, is_retro) " *
          "VALUES (\$1, \$2, \$3, \$4, \$5, 2, 'multi_zone_eu', \$6, 'weather', false)", Any[md, h, z, p, pm - Day(1), CV])
    end

    @testset "LIVE: per-zone clear + insert, one op" begin
        n = write_forecast!(md, 2, pm, slice(md, ["GR", "RO"], 120.0), "weather")
        @test n == 48
        live = fp("market_date = \$1 AND lead_days = 2 AND is_retro = false", Any[md])
        @test sort(unique(live.bidding_zone)) == ["BG", "GR", "RO"]        # BG (not written) kept
        @test all(live[live.bidding_zone .== "GR", :price_eur_mwh] .== 120.0)
        @test all(live[live.bidding_zone .== "BG", :price_eur_mwh] .== 90.0)
        o = ops(); @test nrow(o) == 1 && o.kind[1] == "forecast_slice"
        p = JSON.parse(o.params[1])
        @test p["plan"] == "insert" && p["zones"] == ["GR", "RO"] && p["is_retro"] == false
        @test !haskey(p, "rows") && length(o.params[1]) < 1000             # keys/params only, no row data
        @test count(==(o.op_id[1]), skipmissing(live.transfer_op_id)) == 48
        @test R("SELECT COUNT(*) AS n FROM results_db.simulations.transfer_forecast_rows WHERE transfer_op_id = \$1",
                Any[o.op_id[1]]).n[1] == 48                         # the op's own rows, kept for the transfer
    end

    @testset "LIVE guard: a realized day is refused" begin
        @test_throws Exception write_forecast!(Date(2026, 11, 20), 2, pm, slice(Date(2026, 11, 20), ["GR"], 1.0), "weather")
        @test nrow(ops()) == 1
    end

    @testset "RETRO without supersede: refused (no clobber, no op)" begin
        @test write_forecast!(md, 2, pm, slice(md, ["GR"], 1.0), "weather"; is_retro=true, reset_tag="t1") == 0
        @test nrow(ops()) == 1
        @test all(fp("market_date = \$1 AND bidding_zone = 'GR'", Any[md]).price_eur_mwh .== 120.0)
    end

    @testset "RETRO on a free slice: insert" begin
        md2 = md + Day(1)
        @test write_forecast!(md2, 3, pm, slice(md2, ["GR"], 5.0), "weather"; is_retro=true, reset_tag="t1") == 24
        @test JSON.parse(ops().params[end])["plan"] == "insert"
    end

    @testset "RETRO with EUPHEMIA_RETRO_SUPERSEDE: live rows backed up, slice replaced" begin
        withenv("EUPHEMIA_RETRO_SUPERSEDE" => "1") do
            @test write_forecast!(md, 2, pm, slice(md, ["GR"], 7.0), "weather"; is_retro=true, reset_tag="t2") == 24
        end
        p = JSON.parse(ops().params[end]); @test p["plan"] == "supersede" && p["n_live"] == 72
        bk = R("SELECT COUNT(*) AS n, SUM(price_eur_mwh) AS s FROM results_db.simulations.forecast_prices_pre_reset")
        @test bk.n[1] == 72 && bk.s[1] == 24 * (120 + 120 + 90)
        rest = fp("market_date = \$1 AND lead_days = 2", Any[md])
        @test nrow(rest) == 24 && all(rest.is_retro) && all(rest.price_eur_mwh .== 7.0)
        # the superseded live op still has its rows for the transfer (Postgres must back up the same 72)
        @test R("SELECT COUNT(*) AS n FROM results_db.simulations.transfer_forecast_rows WHERE transfer_op_id = 1").n[1] == 48
    end

    @testset "ALONGSIDE campaign: only its own rows replaced" begin
        md3 = md + Day(2); tag = first(ALONGSIDE_RESET_TAGS)
        @test write_forecast!(md3, 1, pm, slice(md3, ["GR"], 9.0), "weather"; is_retro=true, reset_tag=tag) == 24
        @test write_forecast!(md3, 1, pm, slice(md3, ["GR"], 8.0), "weather"; is_retro=true, reset_tag=tag) == 24
        r3 = fp("market_date = \$1", Any[md3]); @test nrow(r3) == 24 && all(r3.price_eur_mwh .== 8.0)
        @test JSON.parse(ops().params[end])["plan"] == "alongside"
    end

    @testset "input corrections: first vintage wins locally, one op" begin
        n0 = nrow(ops())
        h = DateTime(2026, 11, 24, 10)
        Euphemia.results_transaction() do   # what emit_input_corrections! does with its rows
            op = Euphemia.log_transfer_op!("input_corrections", Dict("day" => "2026-11-24", "n" => 1))
            R("INSERT INTO results_db.simulations.input_corrections VALUES ('IT-Sicily', 'solar', \$1, 900.0, 'm1', \$2)", Any[h, op])
        end
        @test nrow(ops()) == n0 + 1
        @test R("SELECT COUNT(*) AS n FROM results_db.simulations.input_corrections").n[1] == 1
        # the cv32 reader sees it through the redirect (simulations.input_corrections → results_db)
        @test Euphemia.sql2df("SELECT corrected_mw FROM simulations.input_corrections WHERE bidding_zone = 'IT-Sicily'").corrected_mw == [900.0]
    end

    @testset "scores: local upsert keeps q15 columns; one op per kind at the end" begin
        ENV["EUPHEMIA_SCORE_NO_AUTORUN"] = "1"
        include(joinpath(@__DIR__, "..", "bin", "score_forecasts.jl"))
        cm = (n_collapse_actual=1, n_collapse_pred=0, hits=0, false_alarms=0, hit_rate=0.0, false_alarm_rate=nothing)
        upsert_score!(md, "GR", 2, CV, "weather", 24, 5.0, 1.0, 0.9, cm)
        update_q15!(md, "GR", 2, CV, "weather", false,
                    (n_q15=96, mae_q15=6.0, bias_q15=nothing, corr_q15=0.8, shape_floor_q15=nothing,
                     n_le0_q15_actual=0, n_le0_q15_pred=0, le0_q15_hits=0), "native")
        upsert_score!(md, "GR", 2, CV, "weather", 24, 4.0, 1.0, 0.9, cm)          # re-score: hourly only
        s = R("SELECT * FROM results_db.simulations.forecast_scores")
        @test nrow(s) == 1 && s.mae[1] == 4.0 && s.mae_q15[1] == 6.0 && s.n_q15[1] == 96
        n0 = nrow(ops()); log_score_transfer_ops!(); o = ops()
        @test o.kind[n0+1:end] == ["score_upsert", "score_q15"]
        k = JSON.parse(o.params[end])["keys"]
        @test length(k) == 1 && k[1]["bidding_zone"] == "GR" && k[1]["is_retro"] == false
        # incremental (#472 review #5): logging forgets the logged keys, so the ops of each slice are logged once,
        # after that slice; a scorer stopped before its last call keeps the ops of the slices it finished
        n1 = nrow(ops()); log_score_transfer_ops!()
        @test nrow(ops()) == n1                                                     # nothing new to log
        upsert_score!(md + Day(1), "BG", 2, CV, "weather", 24, 3.0, 1.0, 0.9, cm)  # "slice 2"
        log_score_transfer_ops!(); o2 = ops()
        @test o2.kind[n1+1:end] == ["score_upsert"]
        k2 = JSON.parse(o2.params[end])["keys"]
        @test length(k2) == 1 && k2[1]["bidding_zone"] == "BG"                      # only slice 2's key
    end
end

@testset "transfer --dry-run renders one server-side block for every pending op" begin
    Euphemia._results_exec("CHECKPOINT")
    lock(Euphemia._DUCKDB_LOCK) do              # release this process's lock on the results file
        Euphemia._duckdb_drop_connection!()
    end
    GC.gc(); GC.gc()                             # finalize the dropped statements/handles: the file lock goes with them
    jl = joinpath(Sys.BINDIR, Base.julia_exename())
    # A minimal, explicit environment: a failing subprocess prints its env, and CI must never log secrets.
    env = Dict(k => ENV[k] for k in ("PATH", "HOME", "USER", "LANG", "JULIA_DEPOT_PATH", "JULIA_NUM_THREADS",
                                     "EUPHEMIA_DUCKDB_EXT_DIR", "TMPDIR") if haskey(ENV, k))
    merge!(env, Dict("EUPHEMIA_DATA_STORE" => "duckdb", "EUPHEMIA_DUCKDB_PATH" => INPUTS,
                     "EUPHEMIA_DUCKDB_READONLY" => "true", "EUPHEMIA_RESULTS_DB" => RESULTS))
    cmd = `$jl --startup-file=no --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__, "..", "bin", "transfer_run_results.jl")) --dry-run --results-db $RESULTS`
    out = read(setenv(cmd, env), String)
    o = ops()
    @test occursin("DO \$p96transfer\$", out) && occursin("END\n\$p96transfer\$;", out)
    @test all(id -> occursin("-- op $id", out), o.op_id)
    @test occursin("INSERT INTO simulations.forecast_prices_pre_reset", out)          # the supersede backup
    @test occursin("GET DIAGNOSTICS n_backed = ROW_COUNT", out)
    @test occursin("RAISE EXCEPTION", out) && occursin("ON CONFLICT DO NOTHING", out)
    @test !occursin("ENERGY_CONN_STR is not set", out)                                # dry run needs no Postgres
end
