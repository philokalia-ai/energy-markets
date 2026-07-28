# cv25 A/B, PER-DAY INTERLEAVED (base then treat for the SAME day) so every
# completed day is a scoreable pair. base = cv24 (EUPHEMIA_DISABLE_CV25=1);
# treat = cv25. 39-zone coupled, HiGHS, offline extract read-only. Retry once.
# ARGS: <window: summer|winter> <outdir>
using Dates, Printf
ENV["EUPHEMIA_DATA_STORE"]="duckdb"
ENV["EUPHEMIA_DUCKDB_PATH"]="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"]="true"
ENV["EUPHEMIA_DUCKDB_NPROCS_HINT"]="8"
using Euphemia
const FOOTPRINT = String["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT","LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH"]
const REPORT = String["IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH","FR","AT","SI"]
which = length(ARGS)>=1 ? ARGS[1] : "summer"
OUTDIR = length(ARGS)>=2 ? ARGS[2] : "/tmp"
days = which=="winter" ? collect(Date(2025,1,13):Day(1):Date(2025,1,18)) :
                          collect(Date(2025,7,7):Day(1):Date(2025,7,12))   # 6 days

function solve_day(io, arm, d)
    arm == "base" ? (ENV["EUPHEMIA_DISABLE_CV25"]="1") : delete!(ENV,"EUPHEMIA_DISABLE_CV25")
    for attempt in 1:2
        try
            r = run_multi_zone_market_clearing(d; zones=FOOTPRINT, order_method=:merit_order,
                    enrich_network=true, passes=2, save_to_db=false, optimizer="highs")
            for z in REPORT
                haskey(r.market_prices,z) || continue
                for (ts,p) in r.market_prices[z]; println(io, "$arm,$z,$d,$ts,$p"); end
            end
            flush(io); @info "day done" arm=arm day=d; return true
        catch e
            @warn "day failed" arm=arm day=d attempt=attempt err=sprint(showerror,e)
        end
    end
    @error "day permanently failed" arm=arm day=d; return false
end

out = joinpath(OUTDIR, "cv25_$(which).csv")
open(out, "w") do io
    println(io, "arm,zone,day,hour_utc,price")
    for d in days
        solve_day(io, "base", d)
        solve_day(io, "treat", d)
    end
end
@info "ALL DONE" out=out
