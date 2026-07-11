# Benchmark: pipeline vs. today's day-parallel 2-worker mode, on the DuckDB
# extract. Runs the same 10-day window both ways (baseline first, then
# pipeline — NEVER concurrently, to stay within the Gurobi WLS 2-session cap)
# and prints wall times, solver utilization, and H1-2026 / 3.5-year projections.
#
#   EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_PATH=<extract> \
#     julia --project=. test/scripts/pipeline_benchmark.jl [START END] [--book-workers M] [--solver-workers S]
#
# Baseline = the existing `--workers 2` path (2 read-only worker processes,
# pmap over days, each doing the full two-pass clear with save_to_db=false).

using Euphemia, Dates, Printf, Distributed, Statistics

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

sd, ed = Date(2026, 3, 1), Date(2026, 3, 10)
bw = 0; sw = 2
let i = 1
    while i <= length(ARGS)
        a = ARGS[i]
        if a == "--book-workers"; global bw = parse(Int, ARGS[i+1]); i += 1
        elseif a == "--solver-workers"; global sw = parse(Int, ARGS[i+1]); i += 1
        elseif !startswith(a, "--")
            if sd == Date(2026,3,1) && ed == Date(2026,3,10) && i == 1
                global sd = Date(a)
            else
                global ed = Date(a)
            end
        end
        i += 1
    end
end
bw <= 0 && (bw = min(10, max(1, Sys.CPU_THREADS ÷ 8)))
days = collect(sd:Day(1):ed)
N = length(days)
opt = "gurobi"

Euphemia.DATA_STORE[] == :duckdb ||
    error("benchmark expects the DuckDB extract backend (set EUPHEMIA_DATA_STORE=duckdb)")
extract = abspath(Euphemia.DUCKDB_PATH[])
println("Backend: DuckDB extract $extract")
println("Window: $sd .. $ed ($N days)  book_workers=$bw  solver_workers=$sw  optimizer=$opt")

# H1-2026 and the full 3.5-year horizon (for projections).
H1_DAYS   = length(Date(2026,1,1):Day(1):Date(2026,6,30))    # 181
FULL_DAYS = length(Date(2023,1,1):Day(1):Date(2026,6,30))    # 1277
proj(secs_per_day, ndays) = secs_per_day * ndays / 3600      # hours

# --------------------------------------------------------------------------
# Baseline: today's --workers 2 day-parallel path (read-only workers, pmap).
# --------------------------------------------------------------------------
function run_baseline(days, nworkers)
    Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract, read_only=true)
    ws = addprocs(nworkers; exeflags="--project=$(dirname(Base.active_project()))",
        env=["EUPHEMIA_DATA_STORE" => "duckdb", "EUPHEMIA_DUCKDB_PATH" => extract,
             "EUPHEMIA_DUCKDB_READONLY" => "true", "ENERGY_CONN_STR" => ""])
    local wall, solve_secs
    try
        @everywhere ws @eval using Euphemia
        t0 = time()
        results = pmap(days) do d
            res = Euphemia.run_multi_zone_market_clearing(d; zones=FOOTPRINT,
                order_method=:merit_order, optimizer=opt, enrich_network=true,
                apply_zone_profiles=true, passes=2, clearing_mode="bench",
                save_to_db=false, silent=true)
            (day=d, solve=res.solve_time, status=res.status)
        end
        wall = time() - t0
        solve_secs = isempty(results) ? 0.0 : sum(r.solve for r in results)
    finally
        rmprocs(ws)
    end
    return wall, solve_secs
end

# --------------------------------------------------------------------------
println("\n" * "="^70 * "\n▶ BASELINE (day-parallel, $sw workers)\n" * "="^70)
base_wall, base_solve = run_baseline(days, sw)
Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract, read_only=false)
@printf("baseline wall = %.0f s  (%.1f s/day, %.1f days/h)\n",
    base_wall, base_wall / N, N / base_wall * 3600)

# --------------------------------------------------------------------------
println("\n" * "="^70 * "\n▶ PIPELINE (solver_workers=$sw, book_workers=$bw)\n" * "="^70)
pr = Euphemia.run_pipelined_backfill(days, FOOTPRINT;
    solver_workers=sw, book_workers=bw, optimizer=opt, clearing_mode="bench",
    save_to_db=false, resume=false, collect_prices=false)
pipe_wall = pr.wall_seconds

# --------------------------------------------------------------------------
println("\n" * "="^70 * "\n📊 BENCHMARK SUMMARY ($N days, $sw solver workers)\n" * "="^70)
@printf("%-28s %12s %12s\n", "", "baseline", "pipeline")
@printf("%-28s %11.0fs %11.0fs\n", "wall time", base_wall, pipe_wall)
@printf("%-28s %11.1f  %11.1f\n", "days / hour", N/base_wall*3600, pr.days_per_hour)
@printf("%-28s %11.2fx %11s\n", "speedup vs baseline", 1.0, @sprintf("%.2fx", base_wall/pipe_wall))
util_str = isempty(pr.solver_utilization) ? "n/a" :
    join([@sprintf("%.0f%%", 100u) for u in pr.solver_utilization], " ")
@printf("%-28s %12s %12s\n", "pipeline solver util", "", util_str)
println()
println("Projections (per-day cost extrapolated, $sw solver workers):")
@printf("  %-22s baseline %6.1f h   pipeline %6.1f h\n",
    "H1-2026 ($(H1_DAYS)d)", proj(base_wall/N, H1_DAYS), proj(pipe_wall/N, H1_DAYS))
@printf("  %-22s baseline %6.1f h   pipeline %6.1f h\n",
    "3.5y × 39z ($(FULL_DAYS)d)", proj(base_wall/N, FULL_DAYS), proj(pipe_wall/N, FULL_DAYS))
free_gb = Sys.free_memory() / 2^30
@printf("\nRAM free at end: %.1f GB (queue-bounded; far under 256 GB)\n", free_gb)
