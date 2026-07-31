# One (border-arm, day) cell of the cv27 BORDER PROGRAM.
# ARGS: <arm_label> <border_spec|""> <day> <out.tsv>
# arm isolates T1 to the given directed borders (T2/T3 off); "" = empty (guard).
# Fresh process; switches set at launch.
arm  = ARGS[1]
spec = ARGS[2]
ENV["EUPHEMIA_DISABLE_CV27_T2"] = "1"
ENV["EUPHEMIA_DISABLE_CV27_T3"] = "1"
ENV["EUPHEMIA_CV27_T1_BORDERS"] = spec   # present (even if empty) => border-list mode
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
ENV["EUPHEMIA_DUCKDB_PATH"] = "/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"
ENV["EUPHEMIA_DUCKDB_NPROCS_HINT"] = get(ENV, "P7_NPROCS_HINT", "12")

using Euphemia, Dates, Printf
include(joinpath(dirname(dirname(pathof(Euphemia))), "bin", "forecast_common.jl"))

function main()
    day = Date(ARGS[3]); out = ARGS[4]
    res = run_multi_zone_market_clearing(day; zones=FORECAST_FOOTPRINT,
        order_method=:merit_order, enrich_network=true, passes=2,
        save_to_db=false, optimizer="highs")
    @assert res.status == :optimal "non-optimal status $(res.status) for $arm $day"
    @assert length(res.market_prices) == 39 "expected 39 zones got $(length(res.market_prices)) for $arm $day"
    n = 0
    tmp = out * ".part"
    open(tmp, "w") do io
        for z in sort(collect(keys(res.market_prices)))
            for (ts, p) in sort(collect(res.market_prices[z]); by=first)
                @printf(io, "%s\t%s\t%s\t%s\t%.17g\n", arm, day, z, ts, p)
                n += 1
            end
        end
    end
    @assert n > 0 "cell produced zero rows for $arm $day"
    mv(tmp, out; force=true)
    nper = length(res.market_prices[first(keys(res.market_prices))])
    println(">>> CELL arm=$arm day=$day status=$(res.status) zones=$(length(res.market_prices)) periods=$nper rows=$n")
    nper < 24 && println(">>> TRUNCATED arm=$arm day=$day periods=$nper")
end
main()
