ENV["EUPHEMIA_DATA_STORE"]="duckdb"; haskey(ENV, "EUPHEMIA_DUCKDB_PATH") || (ENV["EUPHEMIA_DUCKDB_PATH"] = "data/extracts/euphemia-live.duckdb")
using Euphemia, Dates, Statistics
M=Euphemia.MeritOrderBook
FOOT=["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT","LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH"]
day=Date(2023,1,10)
delete!(ENV,"EUPHEMIA_DISABLE_FRCAP")  # FIX ON
t0=time()
r=run_multi_zone_market_clearing(day; zones=FOOT, order_method=:merit_order, enrich_network=true, passes=2, optimizer="highs", save_to_db=false)
fr=[p for (_,p) in sort(collect(r.market_prices["FR"]))]
de=[p for (_,p) in r.market_prices["DE_LU"]]
capz=[z for z in FOOT if any(p>2900 for (_,p) in r.market_prices[z])]
println("RESULT_0110_FIXON: FR mean=$(round(mean(fr),digits=0)) max=$(round(maximum(fr),digits=0)) | DE_LU mean=$(round(mean(de),digits=0)) max=$(round(maximum(de),digits=0)) | cap_zones=$(length(capz)) $capz | $(round(time()-t0,digits=0))s")
println("FR hourly: ", [round(Int,p) for p in fr])
