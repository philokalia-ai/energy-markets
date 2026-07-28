# Combined IT-NORTH A/B — both arms in ONE process (compile paid once).
# Reduced window (2 summer + 2 winter days) — a directional coupled read on the
# saturated shared machine; underpowered vs the pre-registered 8+8, reported honestly.
# base = cv23 IT-NORTH profile; treat = IT-NORTH import_backstop=true.
using Dates, Printf
ENV["EUPHEMIA_DATA_STORE"]="duckdb"
ENV["EUPHEMIA_DUCKDB_PATH"]="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"]="true"
ENV["EUPHEMIA_DUCKDB_NPROCS_HINT"]="6"
using Euphemia
const MO = Euphemia.MeritOrderBook
const FOOTPRINT = String["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT","LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH"]
const REPORT = String["IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH","FR","AT","SI"]
const OUTDIR = length(ARGS)>=1 ? ARGS[1] : "/tmp"

days = [Date(2025,7,7), Date(2025,7,8), Date(2025,1,14), Date(2025,1,15)]
const ITALY_BASE = MO.ZONE_PROFILES["IT-NORTH"]

function run_arm(arm::String)
    if arm == "treat"
        MO.ZONE_PROFILES["IT-NORTH"] = MO.with_profile(MO.ITALY_PROFILE; import_backstop=true)
    else
        MO.ZONE_PROFILES["IT-NORTH"] = ITALY_BASE
    end
    out = joinpath(OUTDIR, "ab_$(arm).csv")
    open(out, "w") do io
        println(io, "arm,zone,day,hour_utc,price")
        for d in days
            ok=false
            for attempt in 1:2
                try
                    t0=time()
                    r = run_multi_zone_market_clearing(d; zones=FOOTPRINT, order_method=:merit_order,
                            enrich_network=true, passes=2, save_to_db=false, optimizer="highs")
                    for z in REPORT
                        haskey(r.market_prices,z) || continue
                        for (ts,p) in r.market_prices[z]
                            println(io, "$arm,$z,$d,$ts,$p")
                        end
                    end
                    flush(io)
                    @info "day done" arm=arm day=d secs=round(time()-t0,digits=0)
                    ok=true; break
                catch e
                    @warn "day failed" arm=arm day=d attempt=attempt err=sprint(showerror,e)
                end
            end
            ok || @error "day permanently failed" arm=arm day=d
        end
    end
    @info "arm complete" arm=arm out=out
end

run_arm("base")
run_arm("treat")
@info "ALL DONE"
