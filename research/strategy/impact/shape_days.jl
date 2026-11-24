# Experiment 2 (round 2): build + clear days with a market-conduct plug-in on every zone, main default 96-step clear.
# env DAYS (comma), ARM ("base" = TranchesConduct, or an alpha like "0.5" = ShapeConduct(alpha)).
# Writes runs/st-impact/r2/shape/<ARM>/<day>.prices.csv (zone,period,hour_utc,minute,price).
using Euphemia, Dates, Printf
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
include(joinpath(pkgdir(Euphemia), "research", "strategy", "impact", "mk_lib.jl"))
include(joinpath(pkgdir(Euphemia), "src", "strategy", "conduct_shape.jl"))
const OUT = joinpath(homedir(), "armada", "em-team", "strategy", "runs", "st-impact", "r2", "shape")
arm = ENV["ARM"]
cond = arm == "base" ? TranchesConduct() : ShapeConduct(parse(Float64, arm))
sc = ZoneScenario(conduct=cond)
mkpath(joinpath(OUT, arm))
println("SHAPE arm=$arm conduct=$cond res=$(Euphemia.CLEAR_RESOLUTION_MINUTES) commit=$(readchomp(`git -C $(pkgdir(Euphemia)) rev-parse --short HEAD`))")
for d in Date.(split(ENV["DAYS"], ","))
    out = joinpath(OUT, arm, "$(d).prices.csv")
    isfile(out) && (println("SHAPE $arm $d CACHED"); continue)
    t = time()
    p, pass = try
        build_with_scenario(d, sc; footprint=FOOTPRINT, clear_resolution_minutes=Euphemia.CLEAR_RESOLUTION_MINUTES)
    catch e
        println("SHAPE $arm $d FAILED: ", sprint(showerror, e)); flush(stdout); continue
    end
    open(out * ".tmp", "w") do io
        println(io, "zone,period,hour_utc,minute,price")
        for z in sort(collect(keys(p))), (per, v) in sort(collect(p[z]))
            @printf(io, "%s,%s,%s,%s,%.6f\n", z, per, per[10:11], per[12:13], v)
        end
    end
    mv(out * ".tmp", out; force=true)
    println("SHAPE $arm $d DONE pass=$pass wall=$(round(time() - t; digits=1))s"); flush(stdout)
end
