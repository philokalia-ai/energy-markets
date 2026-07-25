#!/usr/bin/env julia
# Byte-identity guard: GR single-zone, SEE 5-zone, 39-zone EU. Writes a sorted
# TSV of every price. Run on cv22 (EUPHEMIA_DISABLE_CV22=1) and on cv21 base;
# the two TSVs must be identical.  ARG1 = output tsv, ARG2 = day (yyyy-mm-dd).
using Euphemia, Dates, Printf
const SEE5 = ["GR","BG","RO","RS","HU"]
const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]
out = ARGS[1]; day = Date(ARGS[2])
rows = Tuple{String,String,String,Float64}[]
# GR single-zone
gr = generate_energy_prices("GR", day; order_method=:merit_order, save_to_db=false)
for (ts,p) in gr; push!(rows, ("GR1","GR",ts,p)); end
# SEE 5-zone (legacy, enrich_network=false)
see = run_multi_zone_market_clearing(day; zones=SEE5, order_method=:merit_order,
    enrich_network=false, save_to_db=false)
for z in sort(collect(keys(see.market_prices))), (ts,p) in sort(collect(see.market_prices[z]))
    push!(rows, ("SEE5",z,ts,p)); end
# 39-zone EU
eu = run_multi_zone_market_clearing(day; zones=FOOTPRINT, order_method=:merit_order,
    enrich_network=true, passes=2, save_to_db=false)
for z in sort(collect(keys(eu.market_prices))), (ts,p) in sort(collect(eu.market_prices[z]))
    push!(rows, ("EU",z,ts,p)); end
sort!(rows)
open(out,"w") do io
    for (m,z,ts,p) in rows; @printf(io,"%s\t%s\t%s\t%.10f\n",m,z,ts,p); end
end
println("WROTE $out  ($(length(rows)) rows)")
