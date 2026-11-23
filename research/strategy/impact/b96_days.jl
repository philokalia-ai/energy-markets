# 96-step baselines for st-impact (detached worktree of cv46 3d4de9a). env DAYS. Cache: runs/st-impact/b96 (never runs/baseline).
using Euphemia, Dates
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
StrategyHarness.CACHE[] = joinpath(homedir(), "armada", "em-team", "strategy", "runs", "st-impact", "b96")
println("clear_resolution_minutes=15 CACHE=", StrategyHarness.CACHE[], " commit=", readchomp(`git -C $(pkgdir(Euphemia)) rev-parse --short HEAD`))
for d in Date.(split(ENV["DAYS"], ","))
    isfile(baseline_path(d)) && (println("B96 $d CACHED"); continue)
    t = time()
    try
        b = build_baseline(d; clear_resolution_minutes=15)
        println("B96 $d DONE pass=$(b.pass) status=$(b.meta["status"]) periods=$(length(b.book.periods)) orders=$(b.meta["n_orders"]) wall=$(round(time()-t; digits=1))s")
    catch e
        println("B96 $d FAILED: ", sprint(showerror, e))
    end
    flush(stdout)
end
