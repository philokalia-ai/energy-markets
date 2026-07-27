ENV["EUPHEMIA_DATA_STORE"]="duckdb"; ENV["EUPHEMIA_DUCKDB_PATH"]="data/extracts/frcap.duckdb"
using Euphemia, Dates
M=Euphemia.MeritOrderBook
FOOT=["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT","LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH"]
day=Date(2023,1,10)
FRP=M.ZONE_PROFILES["FR"]
fixed(p)=M.with_profile(p; nuclear_avail_share_lo=0.0, nuclear_avail_share_hi=0.0)
FRANCE=M.FRANCE_PROFILE
variants=[
  ("A_treat(avail+GB)", FRP),
  ("B_GBonly(fixed+GB)", fixed(FRP)),
  ("C_nuconly(avail,noGB)", FRANCE),
  ("D_base(fixed,noGB)", fixed(FRANCE)),
]
for (name,prof) in variants
  M.ZONE_PROFILES["FR"]=prof
  Euphemia.clear_generator_caches!(); M.clear_net_imports_cache!(); M.clear_boundary_cap_cache!()
  r=run_multi_zone_market_clearing(day; zones=FOOT, order_method=:merit_order, enrich_network=true, passes=2, optimizer="highs", save_to_db=false)
  frm=sum(p for (_,p) in r.market_prices["FR"])/24; frx=maximum(p for (_,p) in r.market_prices["FR"])
  dem=sum(p for (_,p) in r.market_prices["DE_LU"])/24; dex=maximum(p for (_,p) in r.market_prices["DE_LU"])
  ncap=count(z->any(p>2900 for (_,p) in r.market_prices[z]), FOOT)
  println("### $name : FR mean=$(round(frm,digits=0)) max=$(round(frx,digits=0)) | DE_LU mean=$(round(dem,digits=0)) max=$(round(dex,digits=0)) | cap_zones=$ncap")
  flush(stdout)
end
