# Re-clear evaluation days with the markup model applied through the strategist hook (full 2-pass rebuild).
# env DAYS (comma), VARIANT (A|B). Reads runs/st-impact/mk/<V>/<day>.json, writes runs/st-impact/mk/<V>/<day>.prices.csv.
using Euphemia, Dates, Printf, JSON
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
include(joinpath(pkgdir(Euphemia), "research", "strategy", "impact", "mk_lib.jl"))
const MK = joinpath(homedir(), "armada", "em-team", "strategy", "runs", "st-impact", "mk")
V = ENV["VARIANT"]
for d in Date.(split(ENV["DAYS"], ","))
    out = joinpath(MK, V, "$(d).prices.csv")
    isfile(out) && (println("MK $V $d CACHED"); continue)
    js = JSON.parsefile(joinpath(MK, V, "$(d).json"))
    sc = Dict(String(z) => ZoneScenario(strategist=markup_strategist(Dict(parse(Int, h) => Float64(m) for (h, m) in mm)))
              for (z, mm) in js)
    t = time()
    p, pass = try
        build_with_scenario(d, sc; footprint=FOOTPRINT)
    catch e
        println("MK $V $d FAILED: ", sprint(showerror, e)); flush(stdout); continue
    end
    open(out * ".tmp", "w") do io
        println(io, "zone,period,hour_utc,price")
        for z in sort(collect(keys(p))), (per, v) in sort(collect(p[z]); by=x -> period_hour(x[1]))
            @printf(io, "%s,%s,%d,%.6f\n", z, per, period_hour(per), v)
        end
    end
    mv(out * ".tmp", out; force=true)
    println("MK $V $d DONE pass=$pass zones=$(join(sort(collect(keys(sc))), ";")) wall=$(round(time()-t; digits=1))s"); flush(stdout)
end
