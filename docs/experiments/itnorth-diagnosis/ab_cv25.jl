# cv25 must-run-floor A/B on the full 39-zone coupled footprint (HiGHS, offline
# extract, read-only). base = cv24 (EUPHEMIA_DISABLE_CV25=1); treat = cv25 (floor on).
# Summer-inner-loop-FIRST: runs the summer window (both arms) before winter, so the
# summer gate can be scored before spending the winter budget. Per-day CSV, retry once.
# ARGS: <window: summer|winter|both> <outdir>
using Dates, Printf
ENV["EUPHEMIA_DATA_STORE"]="duckdb"
ENV["EUPHEMIA_DUCKDB_PATH"]="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"]="true"
ENV["EUPHEMIA_DUCKDB_NPROCS_HINT"]="8"
using Euphemia
const FOOTPRINT = String["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT","LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH"]
const REPORT = String["IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH","FR","AT","SI"]
which = length(ARGS)>=1 ? ARGS[1] : "both"
OUTDIR = length(ARGS)>=2 ? ARGS[2] : "/tmp"

summer = collect(Date(2025,7,7):Day(1):Date(2025,7,14))   # 8 d high-solar
winter = collect(Date(2025,1,13):Day(1):Date(2025,1,20))   # 8 d

function run_arm(io, arm, days)
    if arm == "base"
        ENV["EUPHEMIA_DISABLE_CV25"]="1"
    else
        delete!(ENV,"EUPHEMIA_DISABLE_CV25")
    end
    for d in days
        ok=false
        for attempt in 1:2
            try
                r = run_multi_zone_market_clearing(d; zones=FOOTPRINT, order_method=:merit_order,
                        enrich_network=true, passes=2, save_to_db=false, optimizer="highs")
                for z in REPORT
                    haskey(r.market_prices,z) || continue
                    for (ts,p) in r.market_prices[z]
                        println(io, "$arm,$z,$d,$ts,$p")
                    end
                end
                flush(io); @info "day done" arm=arm day=d; ok=true; break
            catch e
                @warn "day failed" arm=arm day=d attempt=attempt err=sprint(showerror,e)
            end
        end
        ok || @error "day permanently failed" arm=arm day=d
    end
end

function run_window(name, days)
    out = joinpath(OUTDIR, "cv25_$(name).csv")
    open(out, "w") do io
        println(io, "arm,zone,day,hour_utc,price")
        run_arm(io, "base", days)   # cv24 baseline
        run_arm(io, "treat", days)  # cv25 floor
    end
    @info "window complete" name=name out=out
end

which in ("summer","both") && run_window("summer", summer)
which in ("winter","both") && run_window("winter", winter)
@info "ALL DONE"
