# IT-NORTH A/B harness — full 39-zone coupled clear, HiGHS, offline extract.
# Arms: base (cv23) vs treatment. Treatment selected by ENV["ARM"].
#   ARM=base       -> cv23 IT-NORTH profile (no import backstop)
#   ARM=backstop   -> IT-NORTH gets import_backstop=true (mirrors IT-CNORTH)
# Writes per (zone,day,hour_utc,price) to OUT csv, one arm per run.
# Loops per day, retries a failed day once (HiGHS ~3-4% segfault, #182).
using Dates, Printf
ENV["EUPHEMIA_DATA_STORE"]="duckdb"
ENV["EUPHEMIA_DUCKDB_PATH"]="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"]="true"
ENV["EUPHEMIA_DUCKDB_NPROCS_HINT"]="6"
using Euphemia
const MO = Euphemia.MeritOrderBook

const FOOTPRINT = String["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT","LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH"]
const REPORT = String["IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH","FR","AT","SI"]

arm = length(ARGS) >= 1 ? ARGS[1] : get(ENV, "ARM", "base")
out = length(ARGS) >= 2 ? ARGS[2] : get(ENV, "OUT", "/tmp/ab_$(arm).csv")

# Windows: a high-solar summer window (where the degradation lives) + a winter window.
summer = Date(2025,7,7):Day(1):Date(2025,7,14)   # 8 d
winter = Date(2025,1,13):Day(1):Date(2025,1,20)  # 8 d
days = vcat(collect(summer), collect(winter))

if arm == "backstop"
    MO.ZONE_PROFILES["IT-NORTH"] = MO.with_profile(MO.ITALY_PROFILE; import_backstop=true)
    @info "TREATMENT: IT-NORTH import_backstop=true"
else
    @info "BASE: cv23 IT-NORTH profile"
end

open(out, "w") do io
    println(io, "arm,zone,day,hour_utc,price")
    for d in days
        ok = false
        for attempt in 1:2
            try
                r = run_multi_zone_market_clearing(d; zones=FOOTPRINT, order_method=:merit_order,
                        enrich_network=true, passes=2, save_to_db=false, optimizer="highs")
                for z in REPORT
                    haskey(r.market_prices, z) || continue
                    pd = r.market_prices[z]   # Dict{String,Float64} keyed by "yyyymmdd-HHMM" (CET-naive? -> parse below)
                    for (ts, p) in pd
                        println(io, "$arm,$z,$d,$ts,$p")
                    end
                end
                flush(io)
                @info "day done" day=d attempt=attempt
                ok = true
                break
            catch e
                @warn "day failed" day=d attempt=attempt err=sprint(showerror, e)
            end
        end
        ok || @error "day permanently failed" day=d
    end
end
@info "arm complete" arm=arm out=out
