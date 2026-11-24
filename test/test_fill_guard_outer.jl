# "Fail loudly" reaches the outer catches (cb-joint's review of 1d50392): under a run-local fill a
# FillGuardError raised deep in a clear (threaded zone builds wrap it) must fail the forecast process,
# never become "UTC day clearing FAILED" with the day silently missing. DB-free: temp DuckDB files.
# Runs in its own process (it configures the data store and loads bin/daily_forecast.jl):
#   julia --project=. test/test_fill_guard_outer.jl
using Test, Dates, DuckDB, DataFrames

const TMP = mktempdir()
const INPUTS = joinpath(TMP, "inputs.duckdb")
let db = DuckDB.DB(INPUTS); con = DBInterface.connect(db)   # a fill that holds almost nothing
    DBInterface.execute(con, "CREATE SCHEMA entsoe")
    DBInterface.execute(con, "CREATE TABLE entsoe.actual_total_load (date_time_utc TIMESTAMP, area_map_code VARCHAR, actual_total_load_mw DOUBLE)")
    DBInterface.close!(con); close(db)
end
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"; ENV["EUPHEMIA_DUCKDB_PATH"] = INPUTS
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"; ENV["EUPHEMIA_RESULTS_WRITABLE"] = "true"
ENV["EUPHEMIA_RESULTS_DB"] = joinpath(TMP, "results.duckdb")
ENV["EUPHEMIA_FORECAST_NO_AUTORUN"] = "1"; ENV["INPUT_MODE"] = "weather"; ENV["ZONES"] = "GR,BG"
using Euphemia
lock(() -> Euphemia._duckdb_drop_connection!(), Euphemia._DUCKDB_LOCK)
Euphemia.mark_run_local_fill!(INPUTS; windows=[("entsoe", "actual_total_load", Date(1900, 1, 1), Date(2999, 12, 31))])
include(joinpath(@__DIR__, "..", "bin", "daily_forecast.jl"))

@testset "FillGuardError is found through task / composite / remote wrappers" begin
    E = Euphemia
    g = E.FillGuardError("fill guard: test")
    t = Threads.@spawn throw(g)
    tfe = try wait(t); nothing catch x; x end
    @test tfe isa TaskFailedException
    @test E._fill_guard_in(tfe) === g
    @test E._fill_guard_in(CompositeException([ErrorException("other"), tfe])) === g
    @test E._fill_guard_in(CapturedException(g, [])) === g
    @test E._fill_guard_in(ErrorException("fill guard: plain text is not a guard error")) === nothing
    @test_throws E.FillGuardError E._rethrow_fill_guard(CompositeException([tfe]))
    @test E._rethrow_fill_guard(ErrorException("x")) === nothing
end

@testset "a guard hit in a UTC-day clear fails the forecast process (no silently missing day)" begin
    cache = Dict{Date,Union{Nothing,Dict{String,Dict{DateTime,Float64}}}}()
    err = try
        redirect_stdout(devnull) do
            Euphemia.with_context(Euphemia.gate_context(Date(2026, 11, 25))) do
                clear_utc_day!(cache, Date(2026, 11, 25))
            end
        end
        nothing
    catch x
        x
    end
    @test err isa Euphemia.FillGuardError
    @test !haskey(cache, Date(2026, 11, 25))          # the day was not recorded as a soft failure
    # off a fill the same failure stays the documented soft path (main's behaviour)
    lock(() -> Euphemia._duckdb_drop_connection!(), Euphemia._DUCKDB_LOCK)
    plain = joinpath(TMP, "plain.duckdb"); cp(INPUTS, plain)
    let db = DuckDB.DB(plain); con = DBInterface.connect(db)
        DBInterface.execute(con, "DROP SCHEMA _fill CASCADE"); DBInterface.close!(con); close(db)
    end
    Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=plain, read_only=true, results_writable=true)
    r = redirect_stdout(devnull) do
        clear_utc_day!(cache, Date(2026, 11, 26))
    end
    @test r === nothing && cache[Date(2026, 11, 26)] === nothing
end

@testset "naive_parts_or_nothing does not swallow a FillGuardError (review of #472 #7)" begin
    isdefined(@__MODULE__, :da_target_actuals) || include(joinpath(@__DIR__, "scripts", "eu_eval_metrics.jl"))
    include(joinpath(@__DIR__, "..", "bin", "naive_baselines.jl"))
    lock(() -> Euphemia._duckdb_drop_connection!(), Euphemia._DUCKDB_LOCK)
    Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=INPUTS, read_only=true, results_writable=true)
    scores = DataFrame(z=["GR"], lead_days=[1], mode=["weather"], market_date=[Date(2026, 11, 20)])
    # the sim read-back (forecast_prices, unseeded results DB) / the actuals (not in this fill) raise
    @test_throws Euphemia.FillGuardError redirect_stdout(devnull) do; naive_parts_or_nothing(scores); end
end
