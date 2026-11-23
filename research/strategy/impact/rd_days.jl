# Residual-demand curves for the st-impact study zones (one uncarved curve per (day, zone); carve-adjusted company
# curves are derived in Python, rdopt.py). env DAYS=comma list, ZONES=comma list (default the 6 study zones),
# QGRID=comma list (default below). Writes runs/st-impact/rd/<day>_<zone>.csv (period,hour_utc,q,price).
using Euphemia, Dates, Printf
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
const HARNESS = !isempty(get(ENV, "HARNESS", "")) ? ENV["HARNESS"] : joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")
include(HARNESS); using .StrategyHarness
const OUT = joinpath(homedir(), "armada", "em-team", "strategy", "runs", "st-impact", "rd")
StrategyHarness.RD_CACHE[] = joinpath(OUT, "cache")
# st-impact RD grid (STATUS 21:0xZ): withholding up to S = 4000 MW needs q down to -4000.
const QGRID = !isempty(get(ENV, "QGRID", "")) ? parse.(Float64, split(ENV["QGRID"], ",")) :
    [-4000.0, -3000.0, -2000.0, -1500.0, -1000.0, -750.0, -500.0, -250.0, -100.0, 0.0, 100.0, 250.0, 500.0, 1000.0]
zones = !isempty(get(ENV, "ZONES", "")) ? String.(split(ENV["ZONES"], ",")) : STUDY_ZONES
mkpath(OUT)
for d in Date.(split(ENV["DAYS"], ","))
    base = try
        load_baseline(d)
    catch e
        println("RD $d NO-BASELINE: ", sprint(showerror, e)); flush(stdout); continue
    end
    for z in zones
        f = joinpath(OUT, "$(d)_$(z)$(get(ENV, "SUFFIX", "")).csv")
        isfile(f) && (println("RD $d $z CACHED"); continue)
        t = time()
        rd = residual_demand(base, z; q_grid=QGRID)
        open(f * ".tmp", "w") do io
            println(io, "period,hour_utc,q,price")
            for p in sort(collect(keys(rd)); by=period_hour), (q, pr) in rd[p]
                @printf(io, "%s,%d,%.1f,%.6f\n", p, period_hour(p), q, pr)
            end
        end
        mv(f * ".tmp", f; force=true)
        println("RD $d $z DONE n=$(length(QGRID)) wall=$(round(time()-t; digits=1))s"); flush(stdout)
    end
end
