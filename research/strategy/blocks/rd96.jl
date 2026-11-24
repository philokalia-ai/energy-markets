# Round 2: residual-demand curves on the 96-step baselines for the absorption re-run (st-impact's rd_days.jl, adapted:
# baseline96 cache, own output dir, the grid stated below). env DAYS, ZONES (comma lists).
# Writes runs/st-blocks/r2/rd96/<day>_<zone>.csv (period,hour_utc,q,price) — 96 periods.
using Euphemia, Dates, Printf
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
const ROOT = joinpath(homedir(), "armada", "em-team", "strategy", "runs")
StrategyHarness.CACHE[] = joinpath(ROOT, "baseline96")
const OUT = joinpath(ROOT, "st-blocks", "r2", "rd96")
StrategyHarness.RD_CACHE[] = joinpath(OUT, "cache")
# absorption needs q from −S (charging) to +S (discharging), S ≤ 4000 MW: round 1's grid + its +2000/+4000 extension,
# thinned in the middle to bound the 96-step re-clear count (11 points)
const QGRID = !isempty(get(ENV, "QGRID", "")) ? parse.(Float64, split(ENV["QGRID"], ",")) :
    [-4000.0, -2000.0, -1000.0, -500.0, -250.0, 0.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0]
mkpath(OUT)
for d in Date.(split(ENV["DAYS"], ",")), z in String.(split(ENV["ZONES"], ","))
    f = joinpath(OUT, "$(d)_$(z).csv")
    isfile(f) && (println("RD $d $z CACHED"); continue)
    base = load_baseline(d)
    t = time()
    rd = residual_demand(base, z; q_grid=QGRID, cache=false)
    open(f * ".tmp", "w") do io
        println(io, "period,hour_utc,q,price")
        for p in sort(collect(keys(rd))), (q, pr) in rd[p]
            @printf(io, "%s,%d,%.1f,%.6f\n", p, period_hour(p), q, pr)
        end
    end
    mv(f * ".tmp", f; force=true)
    println("RD $d $z $(length(QGRID)) pts $(round(time() - t, digits=1)) s $(Dates.format(now(UTC), "HH:MM"))Z"); flush(stdout)
end
