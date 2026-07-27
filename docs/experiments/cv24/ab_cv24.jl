#!/usr/bin/env julia
# cv24 confirm A/B: base (cv22, EUPHEMIA_DISABLE_CV24=1) vs cv24 (FR nuclear
# opportunity-cost bidding + the FR↔GB boundary pair, both ON). Full 39-zone
# coupled clear (enrich_network, passes=2, :merit_order, HiGHS decomposed),
# hourly zone prices to out_<arm>.tsv. One ARM per process (profile/cache state
# is per-process). Resumable: (day) rows already present are skipped. Offline
# extract (read-only); realized prices scored separately via score_cv24.jl.
#
#   ARM=base|cv24  DAYS=2026-07-06,2026-07-07  OUT=/path/shard.tsv \
#     julia --project=. docs/experiments/cv24/ab_cv24.jl
const ARM = get(ENV, "ARM", "cv24")
# The switch must be set BEFORE `using Euphemia` builds ZONE_PROFILES (though
# get_zone_profile also re-reads ENV per call, so this is belt-and-braces).
if ARM == "base"
    ENV["EUPHEMIA_DISABLE_CV24"] = "1"
else
    delete!(ENV, "EUPHEMIA_DISABLE_CV24")
end
using Euphemia, Dates, Printf
const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]
const HERE = @__DIR__
days = [Date(strip(d)) for d in split(ENV["DAYS"], ",")]
outf = get(ENV, "OUT", joinpath(HERE, "out_$(ARM).tsv"))
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
