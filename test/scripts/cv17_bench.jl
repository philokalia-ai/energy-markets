# cv17 gate benchmark: the weak-zone diagnosis 28-day stratified benchmark run
# through the PRODUCTION code path (no runtime overrides — the cv17 mechanisms
# are in flow_based_drop_borders / ZONE_PROFILES / create_merit_order_book).
#
#   julia --project=. test/scripts/cv17_bench.jl
#
# Offline (DuckDB extract, read-only), Gurobi, enrich_network + passes=2 —
# exactly the run_multi_zone_market_clearing configuration of the cv17 EU
# backfill. Writes zone,ts,price CSV (resumable) for weak_zone_eval.py.
#
# Env: VARIANT (default "cv17") names the output CSV; DAYS overrides the day
# list; OUTDIR overrides the output directory.

ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
const REPO = normpath(joinpath(@__DIR__, "..", ".."))
const EXTRACT_PATH = get(ENV, "EUPHEMIA_DUCKDB_PATH",
    joinpath(REPO, "data", "extracts", "euphemia-live.duckdb"))
ENV["EUPHEMIA_DUCKDB_PATH"] = EXTRACT_PATH
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"
ENV["EUPHEMIA_RESULTS_DB"] = get(ENV, "EUPHEMIA_RESULTS_DB",
    joinpath(tempdir(), "cv17_bench_results.duckdb"))
haskey(ENV, "GRB_LICENSE_FILE") ||
    (ENV["GRB_LICENSE_FILE"] = joinpath(homedir(), "gurobi.lic"))

using Euphemia, Dates

configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT_PATH,
    read_only=true, results_writable=true)

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

# The weak-zone diagnosis stratified benchmark (16 spike + 12 normal days).
const SPIKE_DAYS = Date[
    Date(2024, 8, 22), Date(2024, 10, 14), Date(2024, 12, 11), Date(2025, 1, 1),
    Date(2025, 1, 14), Date(2025, 2, 11), Date(2025, 4, 8), Date(2025, 7, 3),
    Date(2025, 8, 27), Date(2025, 10, 5), Date(2025, 11, 18), Date(2025, 12, 1),
    Date(2026, 1, 13), Date(2026, 1, 28), Date(2026, 2, 18), Date(2026, 6, 20),
]
const NORMAL_DAYS = Date[
    Date(2024, 7, 10), Date(2024, 9, 14), Date(2024, 10, 22), Date(2024, 11, 24),
    Date(2025, 2, 25), Date(2025, 3, 26), Date(2025, 5, 14), Date(2025, 6, 21),
    Date(2025, 9, 16), Date(2025, 12, 14), Date(2026, 3, 10), Date(2026, 5, 20),
]
const BENCH_DAYS = vcat(SPIKE_DAYS, NORMAL_DAYS)

const VARIANT = get(ENV, "VARIANT", "cv17")
const DAYS = haskey(ENV, "DAYS") ?
    [Date(strip(s)) for s in split(ENV["DAYS"], ",")] : BENCH_DAYS
const OUTDIR = get(ENV, "OUTDIR",
    joinpath(REPO, "docs", "experiments", "weak-zone-diagnosis", "evidence"))
mkpath(OUTDIR)

outfile = joinpath(OUTDIR, "prices_$(VARIANT).csv")
done = Set{String}()
if isfile(outfile)   # resumable
    for line in Iterators.drop(eachline(outfile), 1)
        push!(done, split(line, ",")[2][1:8])
    end
else
    open(outfile, "w") do io
        println(io, "zone,ts,price")
    end
end

for day in DAYS
    key = Dates.format(day, "yyyymmdd")
    key in done && (println("skip $day (already done)"); continue)
    println("\n===== $VARIANT $day =====")
    t0 = time()
    result = run_multi_zone_market_clearing(day;
        zones=FOOTPRINT, order_method=:merit_order, optimizer="gurobi",
        enrich_network=true, passes=2, save_to_db=false)
    if result === nothing || isempty(result.market_prices)
        @warn "no prices for $day"
        continue
    end
    open(outfile, "a") do io
        for (zone, prices) in result.market_prices
            for (ts, p) in prices
                println(io, "$zone,$ts,$p")
            end
        end
    end
    println("day $day done in $(round(time() - t0, digits=1)) s")
end
println("\nAll requested days done → $outfile")
