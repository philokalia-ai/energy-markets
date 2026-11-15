# PS mechanism probe for the cv44 scenario rerun (blocks-p3c): clear base and
# DC +574 MW GR on the given days (record path: 39 zones, enrich_network, passes=2,
# HiGHS, decomposed; cv44 PS master on) and dump the pass-2 PS master allocation
# per storage family and hour, plus the zone prices.
# usage: julia --project=. test/scripts/blocks/scn_ps_mechanism.jl OUTDIR DAY1 DAY2 ...
using Euphemia, Dates
const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH"]
outdir = ARGS[1]; isdir(outdir) || mkpath(outdir)
arms = [("base", nothing),
        ("dc574", Dict("GR" => ZoneScenario(load_modifier=(ts, l) -> l + 574.0)))]
for ds in ARGS[2:end], (arm, scn) in arms
    d = Date(ds)
    f = joinpath(outdir, "$(arm)_$(d).alloc.csv")
    isfile(f) && continue
    res = run_multi_zone_market_clearing(d; zones=FOOTPRINT, order_method=:merit_order,
        optimizer="highs", silent=true, save_to_db=false, clearing_mode="p3c_mech_$arm",
        enrich_network=true, passes=2, scenario=scn)
    info = Euphemia.MPCC.LAST_COMPLEX_INFO[]
    open(joinpath(outdir, "$(arm)_$(d).prices.csv"), "w") do io
        println(io, "zone,period,price")
        for (z, pd) in res.market_prices, (p, v) in pd
            println(io, "$z,$p,$v")
        end
    end
    open(f * ".tmp", "w") do io
        println(io, "family,date_time,offered_mw,alloc_mw,budget_mwh,used_mwh,status")
        if info !== nothing
            for (fam, dd) in sort(collect(info.families); by=first), (dt, q, a) in get(dd, "all", [])
                println(io, "$fam,$dt,$q,$a,$(dd["budget"]),$(dd["used"]),$(info.status)")
            end
        end
    end
    mv(f * ".tmp", f)
    Euphemia.MPCC.LAST_COMPLEX_INFO[] = nothing
    println("DONE $arm $d $(res.status)")
end
