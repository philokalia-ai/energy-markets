#!/usr/bin/env julia
# cv21 byte-identity guards. Runs three books/prices that MUST be bit-identical
# between unmodified main (cv20) and the cv21 branch with the DK1 boundary book
# DISABLED:
#   1. GR single-zone merit_order prices (SEE_PROFILE, no boundary book).
#   2. SEE 5-zone multi_zone prices (enrich_network=false → forced SEE_PROFILE).
#   3. 39-zone EU prices with EUPHEMIA_DISABLE_CV21=1 (DK1 boundary book stripped
#      ⇒ DK1_PROFILE reverts to DENMARK_PROFILE == main).
#
# Writes one TSV per guard (zone,timeslot,price sorted) to OUT_SUFFIX-tagged
# files. Run once on main (reference) and once on the branch, then diff.
#
#   GUARD_DAY=2026-04-03 OUT_SUFFIX=main julia --project=. test/scripts/cv21_guards.jl
using Euphemia, Dates, Printf

day = Date(get(ENV, "GUARD_DAY", "2026-04-03"))
suf = get(ENV, "OUT_SUFFIX", "test")
HERE = @__DIR__
FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]

writeprices(path, pd) = open(path, "w") do io
    println(io, "zone\ttimeslot\tprice")
    for z in sort(collect(keys(pd)))
        for (ts, p) in sort(collect(pd[z]))
            @printf(io, "%s\t%s\t%.10f\n", z, ts, p)
        end
    end
end

# Guard 1 — GR single-zone merit_order
println(">>> Guard 1: GR single-zone")
gr = generate_energy_prices("GR", day; order_method=:merit_order, save_to_db=false)
writeprices(joinpath(HERE, "cv21_guard_gr_$(suf).tsv"),
    Dict("GR" => gr isa Dict ? gr : Dict{String,Float64}()))

# Guard 2 — SEE 5-zone multi_zone (legacy path, enrich_network=false)
println(">>> Guard 2: SEE 5-zone multi_zone")
see = run_multi_zone_market_clearing(day; zones=["GR","BG","RO","RS","HU"],
    order_method=:merit_order, enrich_network=false, save_to_db=false)
writeprices(joinpath(HERE, "cv21_guard_see_$(suf).tsv"), see.market_prices)

# Guard 3 — 39-zone EU with boundary book disabled
println(">>> Guard 3: 39-zone EU (EUPHEMIA_DISABLE_CV21=1)")
ENV["EUPHEMIA_DISABLE_CV21"] = "1"
eu = run_multi_zone_market_clearing(day; zones=FOOTPRINT,
    order_method=:merit_order, enrich_network=true, passes=2, save_to_db=false)
writeprices(joinpath(HERE, "cv21_guard_eu_$(suf).tsv"), eu.market_prices)
println("DONE guards suffix=$suf")
