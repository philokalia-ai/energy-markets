# Clear UTC days on the 39-zone EU footprint (record path: enrich_network,
# passes=2, HiGHS, decomposed) and dump hourly prices to CSV.
# usage: julia +1.12 --project=. test/scripts/blocks/clear_days.jl LABEL DAY1 DAY2 ...
using Euphemia, Dates, Printf
const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH"]
include(joinpath(@__DIR__, "contexts.jl"))   # pregate_0630
label = ARGS[1]
outdir = joinpath(get(() -> error("Set BLOCKS_RESULTS_DIR to the required local file or directory"), ENV, "BLOCKS_RESULTS_DIR"), label)
mkdir!(p) = isdir(p) || mkpath(p); mkdir!(outdir)
for ds in ARGS[2:end]
    d = Date(ds)
    f = joinpath(outdir, "$(d).csv")
    isfile(f) && (println("skip $d"); continue)
    t0 = time()
    clear() = run_multi_zone_market_clearing(d; zones=FOOTPRINT, order_method=:merit_order,
        optimizer="highs", silent=true, save_to_db=false, clearing_mode="multi_zone",
        enrich_network=true, passes=2,
        # CLEAR_RES=15: quarter-hourly clear (96 periods, replicate-not-divide; docs/15min-clearing.md)
        clear_resolution_minutes=parse(Int, get(ENV, "CLEAR_RES", "60")),
        # rerun budget for time-limited days: CLEAR_TIME_LIMIT=3600 (bin/reproduce.jl's HiGHS budget)
        mpcc_time_limit=parse(Float64, get(ENV, "CLEAR_TIME_LIMIT", "900")))
    # CLEAR_CONTEXT=0630: the lead-1 06:30 UTC D-1 issuance context (pre-gate product)
    res = get(ENV, "CLEAR_CONTEXT", "") == "0630" ?
        Euphemia.with_context(clear, pregate_0630(d)) : clear()
    el = time() - t0
    ok = res.status == :optimal || (res.status == :time_limit && !isempty(res.market_prices))
    open(joinpath(outdir, "timing.tsv"), "a") do io
        println(io, "$d\t$(res.status)\t$(round(res.solve_time, digits=1))\t$(round(el, digits=1))\t$(res.message)")
    end
    ok || (println("FAILED $d $(res.status)"); continue)
    open(f * ".tmp", "w") do io
        println(io, "zone,period,price")
        for (z, pd) in res.market_prices, (p, v) in pd
            println(io, "$z,$p,$v")
        end
    end
    mv(f * ".tmp", f)
    info = Euphemia.MPCC.LAST_COMPLEX_INFO[]
    if info !== nothing
        open(joinpath(outdir, "$(d).complex.csv"), "w") do io
            println(io, "family,date_time,offered_mw,alloc_mw,budget_mwh,used_mwh,status,master_s")
            if info.status == :optimal
                for (fam, dd) in sort(collect(info.families); by=first), (dt, q, a) in dd["capped"]
                    println(io, "$fam,$dt,$q,$a,$(dd["budget"]),$(dd["used"]),optimal,$(info.solve_time)")
                end
            else
                println(io, ",,,,,,$(info.status),")
            end
        end
        if info.status == :optimal
            open(joinpath(outdir, "$(d).alloc.csv"), "w") do io
                println(io, "family,date_time,offered_mw,alloc_mw")
                for (fam, dd) in sort(collect(info.families); by=first), (dt, q, a) in get(dd, "all", [])
                    println(io, "$fam,$dt,$q,$a")
                end
            end
        end
        Euphemia.MPCC.LAST_COMPLEX_INFO[] = nothing
    end
    println("DONE $d in $(round(el, digits=1))s")
end
