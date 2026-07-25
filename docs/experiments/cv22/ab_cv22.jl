#!/usr/bin/env julia
# Combined cv22 confirm A/B: base (cv21, EUPHEMIA_DISABLE_CV22=1) vs cv22 (all
# four bug-fixes + the UA firm-slice boundary book, everything ON). Full 39-zone
# coupled clear (enrich_network, passes=2, :merit_order, HiGHS decomposed —
# canonical since cv20), hourly zone prices to out_<arm>.tsv. One ARM per
# process (the bug-fix reservoir/ATC caches are keyed by (zone,day) not arm, so
# arm-flipping in one process is NOT cache-safe — separate processes per arm).
# Resumable: (day) rows already present are skipped. Offline extract (read-only)
# + realized prices scored separately via score_boundary.py.
#
#   ARM=base|cv22  DAYS=2026-07-06,2026-07-07  julia --project=. .../ab_cv22.jl
using Euphemia, Dates, Printf
const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]
const ARM = get(ENV, "ARM", "cv22")
const HERE = @__DIR__
days = [Date(strip(d)) for d in split(ENV["DAYS"], ",")]
outf = get(ENV, "OUT", joinpath(HERE, "out_$(ARM).tsv"))  # per-shard file
done = Set{String}()
if isfile(outf)
    for l in Iterators.drop(eachline(outf), 1); push!(done, first(split(l,'\t'))); end
else
    open(outf,"w") do io; println(io, "day\tzone\ttimeslot\tprice"); end
end
for day in days
    string(day) in done && (println("skip $day"); continue)
    t0 = time()
    println(">>> $ARM $day")
    res = try
        run_multi_zone_market_clearing(day; zones=FOOTPRINT, order_method=:merit_order,
            enrich_network=true, passes=2, optimizer="highs", save_to_db=false)
    catch e
        @warn "day failed" ARM day error=sprint(showerror,e); nothing
    end
    res === nothing && continue
    open(outf,"a") do io
        for z in sort(collect(keys(res.market_prices))), (ts,p) in sort(collect(res.market_prices[z]))
            @printf(io, "%s\t%s\t%s\t%.6f\n", day, z, ts, p)
        end
    end
    println("<<< $ARM $day done $(round(time()-t0,digits=1))s")
end
println("ARM $ARM DONE")
