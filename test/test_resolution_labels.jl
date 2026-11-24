# Slot resolution labels from timestamp spacing (cv46 downstream D1): energy_prices.resolution_code
# and forecast_prices.resolution_code. DB-free; the DuckDB writer runs on temp files.
#   julia --project=. test/test_resolution_labels.jl
using Test, Dates, Euphemia, DataFrames, DuckDB
import DuckDB.DBInterface as DBInterface

@testset "slot resolution from spacing, not count" begin
    E = Euphemia
    day = DateTime(2026, 11, 21)
    hrs(n) = [day + Hour(h) for h in 0:n-1]
    qtr(n) = [day + Minute(15k) for k in 0:n-1]
    @test E.slot_resolution_minutes(hrs(24)) == 60
    @test E.slot_resolution_minutes(qtr(96)) == 15
    @test E.slot_resolution_minutes(reverse(qtr(92))) == 15     # order-free
    @test E.slot_resolution_minutes([day]) === nothing
    @test E.slot_resolution_minutes([day, day]) === nothing                     # duplicates only
    # energy_prices labels: hourly days unchanged (24/23/25), quarter days 15M at ANY count
    for n in (23, 24, 25); @test E.energy_prices_resolution_code(hrs(n)) == "1H"; end
    for n in (92, 96, 100, 40); @test E.energy_prices_resolution_code(qtr(n)) == "15M"; end
    @test E.energy_prices_resolution_code([day + Minute(30k) for k in 0:47]) == "30M"
    @test E.energy_prices_resolution_code(vcat(qtr(8), [day + Hour(5)])) == "15M"   # truncated + a stray slot
    @test E.energy_prices_resolution_code([day]) == "1H"                         # undetermined → count rule
    # forecast_prices labels (ISO, as forecast_scores.q15_forecast_res)
    @test E.forecast_resolution_code(hrs(24)) == "PT60M"
    @test E.forecast_resolution_code(qtr(92)) == "PT15M"
    @test E.forecast_resolution_code([day]) == "PT60M"
end

@testset "DuckDB energy_prices writer labels by spacing (92 quarters → 15M, hourly unchanged)" begin
    E = Euphemia
    prev = (E.DATA_STORE[], E.DUCKDB_PATH[], E.DUCKDB_READ_ONLY[], E.DUCKDB_RESULTS_WRITABLE[], E.RESULTS_DB_PATH[])
    dir = mktempdir(); src = joinpath(dir, "src.duckdb")
    DuckDB.close(DuckDB.DB(src))
    try
        E.RESULTS_DB_PATH[] = joinpath(dir, "results.duckdb")
        E.configure_data_store!(backend=:duckdb, duckdb_path=src, read_only=true, results_writable=true)
        q = Dict(Dates.format(DateTime(2026, 10, 25) + Minute(15k), "yyyymmdd-HHMM") => 60.0 + k for k in 0:91)
        h = Dict(Dates.format(DateTime(2026, 11, 21) + Hour(k), "yyyymmdd-HHMM") => 50.0 + k for k in 0:23)
        @test E.save_energy_prices(q, "GR", Date(2026, 10, 25), :merit_order; clearing_mode="multi_zone_eu") > 0
        @test E.save_energy_prices(h, "GR", Date(2026, 11, 21), :merit_order; clearing_mode="multi_zone_eu") > 0
        r = E._results_exec("SELECT CAST(date_time_utc AS DATE) AS d, resolution_code AS rc, count(*) AS n FROM results_db.simulations.energy_prices GROUP BY 1, 2 ORDER BY 1")
        @test r.rc == ["15M", "1H"]
        @test r.n == [92, 24]
    finally
        try; E._duckdb_drop_connection!(); E.RESULTS_DB_PATH[] = prev[5]
             E.configure_data_store!(backend=prev[1], duckdb_path=prev[2], read_only=prev[3], results_writable=prev[4]); catch; end
    end
end
