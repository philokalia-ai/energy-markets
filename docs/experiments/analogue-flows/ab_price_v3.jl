#!/usr/bin/env julia
# Stage-2 price A/B for the :v3 load-analogue flow rule (README in this dir).
# Runs the full coupled 39-zone clear (enrich_network, passes=2, merit-order)
# for the given days under one flow mode and dumps hourly zone prices to TSV.
# No DB writes — scoring happens in score_ab.py against realized DA prices.
#
#   ARM=v2 DAYS=days_ab.json julia --project=. docs/experiments/analogue-flows/ab_price_v3.jl out_v2.tsv
#   ARM=v3 DAYS=days_ab.json julia --project=. docs/experiments/analogue-flows/ab_price_v3.jl out_v3.tsv
haskey(ENV, "GRB_LICENSE_FILE") ||
    (ENV["GRB_LICENSE_FILE"] = joinpath(homedir(), "gurobi.lic"))
arm = ENV["ARM"]
ENV["EUPHEMIA_FLOW_ASOF_MODE"] = arm   # explicit env wins over the scoped default

using Euphemia, Dates, JSON, Printf

const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]

days = [Date(d) for d in JSON.parsefile(joinpath(@__DIR__, ENV["DAYS"]))]
out = ARGS[1]

open(out, "w") do io
    println(io, "day\tzone\ttimeslot\tprice")
    for (i, day) in enumerate(days)
        println(">>> [$i/$(length(days))] $arm $day")
        t0 = time()
        result = try
            run_multi_zone_market_clearing(day; zones=FOOTPRINT,
                order_method=:merit_order, enrich_network=true, passes=2,
                optimizer="gurobi", save_to_db=false)
        catch e
            @warn "day failed" day error = sprint(showerror, e)
            nothing
        end
        result === nothing && continue
        for z in sort(collect(keys(result.market_prices)))
            for (ts, p) in sort(collect(result.market_prices[z]))
                @printf(io, "%s\t%s\t%s\t%.6f\n", day, z, ts, p)
            end
        end
        flush(io)
        println("<<< $day done in $(round(time() - t0, digits=1)) s")
    end
end
println("WROTE $out")
