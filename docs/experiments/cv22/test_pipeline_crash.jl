#!/usr/bin/env julia
# #182 crash-resilience test: run a pipelined backfill and KILL -9 a solver
# worker mid-run (simulating a HiGHS SIGSEGV). The coordinator must resubmit the
# orphaned day and complete ALL days (no deadlock). Offline extract, no DB save.
#
#   EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_PATH=... EUPHEMIA_DUCKDB_READONLY=true \
#     julia --project=. docs/experiments/cv22/test_pipeline_crash.jl
using Euphemia, Distributed, Dates
const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]
days = [Date(2026,3,1), Date(2026,3,2), Date(2026,3,3), Date(2026,3,4)]

task = @async run_pipelined_backfill(days, FOOTPRINT;
    solver_workers=2, book_workers=3, in_flight=4, optimizer="highs",
    clearing_mode="multi_zone_crashtest", save_to_db=false, collect_prices=true,
    resume=false)

# Kill a BUSY (actively-solving) worker — the representative HiGHS-SIGSEGV case
# (the crash happens DURING mz_solve_pass, after take!, so it does NOT leave a
# dangling channel waiter). A worker killed while blocked on an empty take! is a
# different, non-representative Distributed artifact, so we CPU-sample to target
# a worker that is burning CPU.
read_cpu(p) = try
    parts = split(read("/proc/$p/stat", String))
    parse(Int, parts[14]) + parse(Int, parts[15])   # utime + stime (jiffies)
catch; -1 end
function busiest_worker()
    ws = workers()
    length(ws) < 2 && return nothing
    pids = Dict(w => (try; remotecall_fetch(getpid, w); catch; -1 end) for w in ws)
    t0 = Dict(w => read_cpu(pids[w]) for w in ws)
    sleep(1.0)
    d = Dict(w => read_cpu(pids[w]) - t0[w] for w in ws)
    w = argmax(x -> d[x], ws)
    d[w] > 25 ? (w, pids[w]) : nothing    # only if it burned >~0.25s CPU in 1s
end
killed = Ref(false)
for _ in 1:80
    sleep(6)
    istaskdone(task) && break
    if !killed[]
        v = busiest_worker()
        if v !== nothing
            println("\n>>> INJECTING CRASH: kill -9 busy worker $(v[1]) (os pid $(v[2]))\n")
            run(`kill -9 $(v[2])`)
            killed[] = true
        end
    end
end

res = fetch(task)
ndays = length(res.day_prices)
println("\n=== CRASH TEST RESULT ===")
println("processed=$(res.processed) saved=$(res.saved) failed=$(res.failed) days_with_prices=$ndays")
println("worker crash injected: $(killed[])")
ok = killed[] && res.processed == length(days) && ndays == length(days)
println(ok ? "PASS — crash recovered, all days completed (no deadlock)" :
             "FAIL — see counts above")
exit(ok ? 0 : 1)
