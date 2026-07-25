#!/usr/bin/env julia
# cv22 FR↔GB double-count + GB premium A/B (paired lever). Full 39-zone coupled
# clear (enrich_network, passes=2, merit_order, HiGHS = cv20 solver-invariant
# canonical decomposed mode). Two arms on the same days:
#
#   base  — cv21 baseline: DK1/Viking ON, FR↔GB book OFF (EUPHEMIA_DISABLE_CV22GB).
#            FR keeps the double-counted GB injection, no GB ladder.
#   treat — cv22 candidate: DK1/Viking ON *and* FR↔GB book ON (double-count fixed,
#            GB priced by the elastic UKA-anchored ladder).
#
# DK1's Viking book stays ON in BOTH arms (we never set EUPHEMIA_DISABLE_CV21),
# so the A/B isolates only the FR pair — the pre-registered gate baseline is cv21.
#
# UKA seeding: the offline extract carries no `carbon.uka_price`, so the shipped
# UKA carbon leg would fall back to EUA. We pre-seed the REAL per-day UKA close
# (uka_seed.json, queried from Postgres up front) into UKA_PRICE_CACHE so the fast
# offline path uses the true shipped anchor. Everything else is offline.
#
#   DAYS="2026-03-04,..." SUFFIX=".s0" ARMS="base,treat" \
#   EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_PATH=... EUPHEMIA_DUCKDB_READONLY=1 \
#   julia --project=. docs/experiments/gb-borders-cv22/ab_run.jl
using Euphemia, Dates, JSON, Printf

const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]

const HERE = @__DIR__
const ARMS = split(get(ENV, "ARMS", "base,treat"), ",")
const SUFFIX = get(ENV, "SUFFIX", "")

# Seed the real per-day UKA closes so the offline path uses the shipped anchor.
seed = JSON.parsefile(joinpath(HERE, "uka_seed.json"))
for (ds, v) in seed
    Euphemia.UKA_PRICE_CACHE[Date(ds)] = Float64(v)
end

days = if haskey(ENV, "DAYS")
    [Date(strip(d)) for d in split(ENV["DAYS"], ",") if !isempty(strip(d))]
else
    [Date(d) for d in JSON.parsefile(joinpath(HERE, "days_ab.json"))]
end

outfile(arm) = joinpath(HERE, "out_$(arm)$(SUFFIX).tsv")
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
        if arm == "base"
            ENV["EUPHEMIA_DISABLE_CV22GB"] = "1"   # strip FR book (DK1 stays on)
        else
            delete!(ENV, "EUPHEMIA_DISABLE_CV22GB")
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
delete!(ENV, "EUPHEMIA_DISABLE_CV22GB")
println("ALL DONE$(SUFFIX)")
