# A/B harness for the BritNed NL↔GB boundary book (exp/nl-diagnosis).
# Arm B = book ON (default). Arm A = book OFF (EUPHEMIA_DISABLE_NLGB=1).
# 39-zone coupled footprint, :merit_order, 2-pass, HiGHS, save_to_db=false.
# Resumable: appends (day,arm,zone,ts,price) rows to OUT_CSV; already-done
# (day,arm) pairs are skipped so a HiGHS segfault can be restarted.
#
# Run (env set by the shell wrapper):
#   EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_PATH=<extract> \
#   EUPHEMIA_DUCKDB_READONLY=true NL_DAYS="2025-01-13,..." \
#   NL_OUT=<csv> julia --project=. docs/experiments/nl-diagnosis/ab_harness.jl

using Euphemia, Dates, Printf, CSV, DataFrames

const EU39 = ["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU",
              "LT","LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS",
              "SE1","SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH",
              "IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH"]
const CAPTURE = ["NL","BE","DE_LU","DK1","NO2","FR"]   # NL + coupled neighbors
const OUT = ENV["NL_OUT"]
const DAYS = Date.(split(ENV["NL_DAYS"], ","))

done = Set{Tuple{String,String}}()
if isfile(OUT)
    prev = CSV.read(OUT, DataFrame)
    for r in eachrow(prev); push!(done, (string(r.day), r.arm)); end
end

function clear_day(day)
    Euphemia.clear_generator_caches!()
    empty!(Euphemia.TTF_PRICE_CACHE); empty!(Euphemia.EUA_PRICE_CACHE)
    res = Euphemia.run_multi_zone_market_clearing(day;
        zones=EU39, order_method=:merit_order, save_to_db=false,
        enrich_network=true, apply_zone_profiles=true, passes=2, optimizer="highs")
    return res.market_prices
end

function emit(day, arm, mp)
    rows = NamedTuple[]
    for z in CAPTURE
        haskey(mp, z) || continue
        for (ts, p) in mp[z]
            push!(rows, (day=string(day), arm=arm, zone=z, ts=string(ts), price=Float64(p)))
        end
    end
    CSV.write(OUT, DataFrame(rows); append=isfile(OUT))
    @printf("  wrote %s %s: %d rows\n", day, arm, length(rows))
end

for day in DAYS
    for (arm, disable) in (("A_off","1"), ("B_on",""))
        (string(day), arm) in done && (println("skip $day $arm"); continue)
        if isempty(disable); delete!(ENV, "EUPHEMIA_DISABLE_NLGB")
        else; ENV["EUPHEMIA_DISABLE_NLGB"] = disable; end
        t0 = time()
        try
            mp = clear_day(day)
            emit(day, arm, mp)
            @printf("done %s %s (%.0fs)\n", day, arm, time()-t0)
        catch e
            @printf("FAIL %s %s: %s\n", day, arm, sprint(showerror, e))
        end
    end
end
println("HARNESS COMPLETE")
