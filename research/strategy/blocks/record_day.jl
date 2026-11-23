# cv46 record-mode (ENTSO-E D-1 inputs) offline clear of ONE day (or a short DAYS list), gate-matched (as_of=:gate),
# HiGHS, prices to EUPHEMIA_RESULTS_DB. Run with --project=<detached worktree>. Pattern: results/cv45-bt/record_arm.jl.
#   env: DAYS (comma list), SOLVERS BOOKS IN_FLIGHT (default 1/1/1 = deterministic log order)
ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "v2")
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"
const EXTRACT = ENV["EUPHEMIA_DUCKDB_PATH"]
using Euphemia, Dates
configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT, read_only=true, results_writable=true)
const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]
days = Date.(split(ENV["DAYS"], ","))
knobs = sort([k => v for (k, v) in ENV if startswith(k, "EUPHEMIA_") && !(k in ("EUPHEMIA_DUCKDB_PATH", "EUPHEMIA_RESULTS_DB", "EUPHEMIA_DUCKDB_TEMP"))])
println("CV46 RECORD DAY $(join(days, ",")) cv=$(Euphemia.ENERGY_PRICES_CODE_VERSION) results=$(ENV["EUPHEMIA_RESULTS_DB"]) env=$knobs")
t0 = time()
r = run_pipelined_backfill(days, FOOTPRINT;
    solver_workers=parse(Int, get(ENV, "SOLVERS", "1")),
    book_workers=parse(Int, get(ENV, "BOOKS", "1")),
    optimizer="highs", clearing_mode="multi_zone_eu", save_to_db=true,
    save_prices_only=true, resume=true, as_of=:gate,
    in_flight=parse(Int, get(ENV, "IN_FLIGHT", "1")))
println("CV46 processed=$(r.processed) saved=$(r.saved) failed=$(r.failed) wall=$(round(time() - t0, digits=1))s maxrss_master=$(round(Sys.maxrss() / 2^30, digits=2))GiB")
