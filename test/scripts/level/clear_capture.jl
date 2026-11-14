# Clear UTC days on the 39-zone EU footprint (record path, identical to
# test/scripts/blocks/clear_days.jl: enrich_network, passes=2, HiGHS) and dump
# hourly prices + flows + the FINAL (pass-2-wins) tagged order book of every
# zone, with the unit fuel type, for marginal-block attribution.
# usage: julia +1.12 --project=. test/scripts/level/clear_capture.jl OUTDIR DAY1 DAY2 ...
using Euphemia, Dates, Printf
const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH"]
outdir = ARGS[1]; isdir(outdir) || mkpath(outdir)
const CAP = Dict{String,Any}()
const MOB = Euphemia.MeritOrderBook
capture = get(ENV, "LEVEL_CAPTURE", "1") == "1"
if capture
    MOB.BOOK_SINK[] = function (zone, day, tagged, res, strat)
        CAP[zone] = (copy(tagged), copy(strat))   # later call (pass 2) wins
    end
end
for ds in ARGS[2:end]
    d = Date(ds)
    f = joinpath(outdir, "$(d).csv")
    isfile(f) && (println("skip $d"); continue)
    empty!(CAP)
    t0 = time()
    res = run_multi_zone_market_clearing(d; zones=FOOTPRINT, order_method=:merit_order,
        optimizer="highs", silent=true, save_to_db=false, clearing_mode="multi_zone",
        enrich_network=true, passes=2)
    el = time() - t0
    ok = res.status == :optimal || (res.status == :time_limit && !isempty(res.market_prices))
    open(joinpath(outdir, "timing.tsv"), "a") do io
        println(io, "$d\t$(res.status)\t$(round(res.solve_time, digits=1))\t$(round(el, digits=1))\t$(res.message)")
    end
    ok || (println("FAILED $d $(res.status)"); continue)
    open(joinpath(outdir, "$(d).flows.csv"), "w") do io
        println(io, "line,period,flow")
        for (l, pd) in res.transmission_flows, (p, v) in pd
            println(io, "$l,$p,$v")
        end
    end
    if capture
        open(joinpath(outdir, "$(d).book.csv"), "w") do io
            println(io, "zone,ts,side,price,mw,owner,strategy,fuel")
            for (z, (tagged, strat)) in CAP
                fuel = Dict{String,String}()
                try
                    for g in Euphemia.get_generators(z, d)
                        fuel[g.code] = String(g.fuel_type)
                    end
                catch
                end
                for (i, (o, own)) in enumerate(tagged)
                    println(io, "$z,$(Dates.format(o.date_time, "yyyy-mm-ddTHH:MM")),$(o.type),$(o.price),$(o.quantity),\"$own\",$(strat[i]),\"$(get(fuel, own, ""))\"")
                end
            end
        end
    end
    open(f * ".tmp", "w") do io
        println(io, "zone,period,price")
        for (z, pd) in res.market_prices, (p, v) in pd
            println(io, "$z,$p,$v")
        end
    end
    mv(f * ".tmp", f)
    println("DONE $d in $(round(el, digits=1))s")
end
