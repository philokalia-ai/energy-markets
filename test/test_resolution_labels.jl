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

@testset "pipeline resume: slots a saved day needs, by its resolution (cv46 D2)" begin
    E = Euphemia
    @test E.resume_slots_needed("1H", 24) == 24          # hourly days: unchanged
    @test E.resume_slots_needed(missing, 24) == 24
    @test E.resume_slots_needed("15M", 24) == 96         # a truncated quarter day (>= 24 quarters) is not complete
    @test E.resume_slots_needed("15M", 96) == 96         # also right if the default becomes 96
    @test E.resume_slots_needed("30M", 24) == 48
    @test E.resume_slots_needed(" 1H ", 20) == 20
end

@testset "pipeline resume: day counts by the finest resolution present (review of #476 #4)" begin
    E = Euphemia
    prev = (E.DATA_STORE[], E.DUCKDB_PATH[], E.DUCKDB_READ_ONLY[], E.DUCKDB_RESULTS_WRITABLE[], E.RESULTS_DB_PATH[])
    dir = mktempdir(); src = joinpath(dir, "src.duckdb"); DuckDB.close(DuckDB.DB(src))
    try
        E.RESULTS_DB_PATH[] = joinpath(dir, "results.duckdb")
        E.configure_data_store!(backend=:duckdb, duckdb_path=src, read_only=true, results_writable=true)
        E._results_exec("SELECT 1")   # attach + ensure the results energy_prices table
        ins(t, z, rc) = E._results_exec("INSERT INTO results_db.simulations.energy_prices (date_time_utc, resolution_code, bidding_zone, " *
            "contract_type, price_eur_mwh, currency, order_method, clearing_mode, code_version) VALUES (\$1, \$2, \$3, 'Day-Ahead', 1.0, 'EUR', 'merit_order', 'multi_zone_eu', 46)", Any[t, rc, z])
        for z in ("GR", "BG")
            for h in 0:23; ins(DateTime(2026, 11, 1) + Hour(h), z, "1H"); end              # full hourly day
            for k in 0:95; ins(DateTime(2026, 11, 2) + Minute(15k), z, "15M"); end         # full quarter day
            for k in 0:39; ins(DateTime(2026, 11, 3) + Minute(15k), z, "15M"); end         # truncated quarter day
            for h in 0:23; ins(DateTime(2026, 11, 4) + Hour(h), z, "1H"); end              # mixed: hourly rows ...
            for k in 0:3;  ins(DateTime(2026, 11, 4) + Minute(15k + 5), z, "15M"); end     # ... plus a few quarter rows
        end
        df = E.resume_day_counts("multi_zone_eu", 46, Date(2026, 11, 1), Date(2026, 11, 4))
        @test sort(collect(E.resume_complete_days(df, 2, 24))) == [Date(2026, 11, 1), Date(2026, 11, 2)]
        # MAX(resolution_code) would have said "1H" for 11-04 (28 slots >= 24 → skipped forever)
        r4 = only(eachrow(df[Date.(df.d) .== Date(2026, 11, 4), :]))
        @test r4.q15 && E._resume_rc(r4) == "15M"
        @test E.resume_complete_days(df, 3, 24) == Set{Date}()          # a missing zone
    finally
        try; E._duckdb_drop_connection!(); E.RESULTS_DB_PATH[] = prev[5]
             E.configure_data_store!(backend=prev[1], duckdb_path=prev[2], read_only=prev[3], results_writable=prev[4]); catch; end
    end
end
