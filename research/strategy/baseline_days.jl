# Build + cache the strategy baselines (st-orch). env DAYS=comma list. Run via research/strategy/baseline.sh.
ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "v2")
using Euphemia, Dates
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
for d in Date.(split(ENV["DAYS"], ","))
    if isfile(baseline_path(d)) && isempty(get(ENV, "REBUILD", ""))
        println("BASELINE $d CACHED"); continue
    end
    t = time()
    try
        b = build_baseline(d)
        println("BASELINE $d DONE pass=$(b.pass) status=$(b.meta["status"]) orders=$(b.meta["n_orders"]) wall=$(round(time()-t; digits=1))s")
    catch e
        println("BASELINE $d FAILED: ", sprint(showerror, e))
    end
    flush(stdout)
end
