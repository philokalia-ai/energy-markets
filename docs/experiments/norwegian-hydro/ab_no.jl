#!/usr/bin/env julia
# cv23 interior-Norway A/B: base (EUPHEMIA_DISABLE_CV23=1) vs cv23 (default).
# 39-zone coupled clear (enrich_network, passes=2, :merit_order, HiGHS decomposed),
# offline extract read-only. One ARM per process (caches keyed by (zone,day), not
# arm — flipping in one process is not cache-safe). Resumable per (day).
#   ARM=base|cv23  DAYS=2026-05-17,2026-05-18  OUT=out_base_s1.tsv julia --project=. ab_no.jl
using Euphemia, Dates, Printf
const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]
const ARM = get(ENV, "ARM", "cv23")
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
    t0 = time(); println(">>> $ARM $day")
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
println("ARM $ARM DONE ($outf)")
