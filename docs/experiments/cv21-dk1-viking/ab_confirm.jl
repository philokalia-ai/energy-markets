#!/usr/bin/env julia
# cv21 DK1/Viking confirm A/B — the SRC implementation (not the experiment
# harness). Full 39-zone coupled clear (enrich_network, passes=2, merit_order,
# HiGHS = cv20 solver-invariant canonical decomposed mode), hourly zone prices
# to per-arm TSVs. Two arms on the same 24 days (July-2026 failure 16 + March
# stable guard 8):
#
#   base — cv20 defaults: DK1 boundary book DISABLED via EUPHEMIA_DISABLE_CV21.
#   dk1  — the shipped cv21 model: DK1_PROFILE carries VIKING_GB_BOOK.
#
# Interleaved days-outer / arms-inner (wave-2 methodology): both arms of a day
# read the same per-process day-cached data snapshot. Resumable: (day, arm)
# already in an output TSV is skipped. No DB writes; score with score_boundary.py.
#
#   julia --project=. docs/experiments/cv21-dk1-viking/ab_confirm.jl
# (offline: set EUPHEMIA_DATA_STORE=duckdb + EUPHEMIA_DUCKDB_PATH + READONLY.)
using Euphemia, Dates, JSON, Printf

const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]

const HERE = @__DIR__
const ARMS = split(get(ENV, "ARMS", "base,dk1"), ",")
days = [Date(d) for d in JSON.parsefile(joinpath(HERE, get(ENV, "DAYS", "days_ab.json")))]

outfile(arm) = joinpath(HERE, "out_$(arm).tsv")
function done_days(arm)
    f = outfile(arm)
    isfile(f) || return Set{String}()
    Set{String}(first(split(l, '\t')) for l in Iterators.drop(eachline(f), 1))
end
already = Dict(String(arm) => done_days(arm) for arm in ARMS)
for arm in ARMS
    f = outfile(arm)
    isfile(f) || open(f, "w") do io
        println(io, "day\tzone\ttimeslot\tprice")
    end
end

for (i, day) in enumerate(days)
    for arm in ARMS
        arm = String(arm)
        string(day) in already[arm] && continue
        println(">>> [$i/$(length(days))] $arm $day")
        # base = cv20 (boundary book off); dk1 = shipped model (on).
        if arm == "base"
            ENV["EUPHEMIA_DISABLE_CV21"] = "1"
        else
            delete!(ENV, "EUPHEMIA_DISABLE_CV21")
        end
        t0 = time()
        result = try
            run_multi_zone_market_clearing(day; zones=FOOTPRINT,
                order_method=:merit_order, enrich_network=true, passes=2,
                optimizer="highs", save_to_db=false)
        catch e
            @warn "day failed" arm day error = sprint(showerror, e)
            nothing
        end
        result === nothing && continue
        open(outfile(arm), "a") do io
            for z in sort(collect(keys(result.market_prices)))
                for (ts, p) in sort(collect(result.market_prices[z]))
                    @printf(io, "%s\t%s\t%s\t%.6f\n", day, z, ts, p)
                end
            end
        end
        println("<<< $arm $day done in $(round(time() - t0, digits=1)) s")
    end
end
delete!(ENV, "EUPHEMIA_DISABLE_CV21")
println("ALL DONE")
