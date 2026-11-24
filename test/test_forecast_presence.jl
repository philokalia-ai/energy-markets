# bin/forecast_presence.jl: the dispatcher's view of what a daily-forecast run left in Postgres, from the run-local
# results DuckDB only. Seeded rows and rows of transferred ops count; rows of an op whose transfer did not commit
# are reported, not counted. DB-free. Own process:  julia --project=. test/test_forecast_presence.jl
using Test, Dates, DuckDB, DataFrames, JSON

const TMP = mktempdir()
const RES = joinpath(TMP, "results.duckdb")
let db = DuckDB.DB(RES); con = DBInterface.connect(db); x(s) = DBInterface.execute(con, s)
    x("CREATE SCHEMA simulations")
    x("""CREATE TABLE simulations.forecast_prices (market_date DATE, date_time_utc TIMESTAMP, bidding_zone VARCHAR,
         price_eur_mwh DOUBLE, lead_days INTEGER, input_mode VARCHAR, is_retro BOOLEAN, transfer_op_id BIGINT)""")
    x("CREATE TABLE simulations.transfer_ops (op_id BIGINT, kind VARCHAR, params VARCHAR, created_at TIMESTAMP, done_at TIMESTAMP, outcome VARCHAR)")
    ins(md, lead, mode, zones, op; retro=false) = for z in zones, h in 0:23
        x("INSERT INTO simulations.forecast_prices VALUES (DATE '$md', TIMESTAMP '$md 00:00:00' + INTERVAL $h HOUR, '$z', 1.0, $lead, '$mode', $retro, $(op === nothing ? "NULL" : op))")
    end
    ins(Date(2026, 11, 26), 2, "weather", ["GR", "BG"], nothing)            # seeded (in Postgres at fill time)
    ins(Date(2026, 11, 25), 1, "weather", ["GR", "BG", "RO"], 1)            # written + transferred
    ins(Date(2026, 11, 27), 3, "weather", ["GR"], 2)                        # written, transfer did not commit
    ins(Date(2026, 11, 25), 1, "entsoe", ["GR"], nothing)                   # other track
    ins(Date(2026, 11, 25), 1, "weather", ["HU"], nothing; retro=true)      # retro rows never count
    x("INSERT INTO simulations.transfer_ops VALUES (1, 'forecast_slice', '{}', now(), now(), 'ok'), (2, 'forecast_slice', '{}', now(), NULL, NULL)")
    DBInterface.close!(con); close(db)
end

jl = joinpath(Sys.BINDIR, Base.julia_exename())
run_presence(mode, d1) = read(`$jl --startup-file=no --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__, "..", "bin", "forecast_presence.jl")) --results-db $RES --input-mode $mode --lead1-date $d1 --out $(joinpath(TMP, "p-$mode-$d1.json")) --profile morning --dispatch-id ceres-123`, String)

@testset "forecast_presence: lead-1 from the results DB, transferred writes only" begin
    out = run_presence("weather", "2026-11-25")
    @test occursin("lead-1 2026-11-25 weather: PRESENT (72 rows, 3 zones)", out)
    @test occursin("NOT transferred: 1", out)
    p = JSON.parsefile(joinpath(TMP, "p-weather-2026-11-25.json"))
    @test p["dispatch_id"] == "ceres-123" && p["run_profile"] == "morning" && p["lead1"]["present"] == true
    src = Dict((s["market_date"], s["lead_days"]) => s["source"] for s in p["slices"])
    @test src[("2026-11-25", 1)] == "transferred" && src[("2026-11-26", 2)] == "seeded" &&
          src[("2026-11-27", 3)] == "not_transferred"
    @test all(s["input_mode"] == "weather" for s in p["slices"])
    # a day with only an untransferred write, and a track without lead 1, are MISSING
    @test occursin("MISSING", run_presence("weather", "2026-11-27"))
    out2 = run_presence("entsoe", "2026-11-25")
    @test occursin("PRESENT (24 rows, 1 zones)", out2)
end
