#!/usr/bin/env julia
# SEE-delta measurement for bug 2 (legacy ATC aggregation): SEE single-zone
# (GR/BG/RO/RS/HU, forces SEE_PROFILE) + SEE 5-zone (enrich_network=false).
# Single-zone never touches the Network ATC build → expected bit-identical; the
# 5-zone legacy ATC build is where bug 2 lands. Run once per arm:
#   ARM=cv22  julia ...  (all fixes ON)   -> out_see_cv22.tsv
#   ARM=base EUPHEMIA_DISABLE_CV22=1 ...  -> out_see_base.tsv
# Scored against the extract's entsoe.energy_prices by score_see.py.
using Euphemia, Dates, Printf
const SEE5 = ["GR","BG","RO","RS","HU"]
const ARM = get(ENV, "ARM", "cv22")
const HERE = @__DIR__
days = [Date(strip(d)) for d in split(get(ENV, "DAYS",
    "2026-01-15,2026-03-03,2026-05-12,2026-06-20,2026-07-08"), ",")]
outf = joinpath(HERE, "out_see_$(ARM).tsv")
open(outf, "w") do io
    println(io, "mode\tday\tzone\ttimeslot\tprice")
    for day in days
        for z in SEE5
            p = try
                generate_energy_prices(z, day; order_method=:merit_order, save_to_db=false)
            catch e; @warn "1z fail" z day; continue; end
            for (ts, v) in p; @printf(io, "1z\t%s\t%s\t%s\t%.6f\n", day, z, ts, v); end
        end
        res = try
            run_multi_zone_market_clearing(day; zones=SEE5, order_method=:merit_order,
                enrich_network=false, save_to_db=false)
        catch e; @warn "5z fail" day; continue; end
        for z in sort(collect(keys(res.market_prices))), (ts, v) in sort(collect(res.market_prices[z]))
            @printf(io, "5z\t%s\t%s\t%s\t%.6f\n", day, z, ts, v)
        end
        println("done $ARM $day")
    end
end
println("WROTE $outf")
