using Dates
ENV["EUPHEMIA_DATA_STORE"]="duckdb"
ENV["EUPHEMIA_DUCKDB_PATH"]="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"]="true"
using Euphemia
const MO = Euphemia.MeritOrderBook
day = Date(2025,7,8)
println("IT-NORTH must_run_floor = ", MO.ZONE_PROFILES["IT-NORTH"].must_run_floor)
println("IT-NORTH must_run_floor_price = ", MO.ZONE_PROFILES["IT-NORTH"].must_run_floor_price)
dmin = MO.get_all_hours_min_p5("IT-NORTH", day)
println("get_all_hours_min_p5 IT-NORTH thermal keys: ",
        [(k, round(v)) for (k,v) in dmin if occursin("Fossil", k) || occursin("Gas", k)])
gens = Euphemia.get_generators("IT-NORTH", day)
gas = [g for g in gens if g.fuel_type == Symbol("Fossil Gas")]
println("n gas gens = ", length(gas), "  sum p_max = ", round(sum(g.p_max for g in gas; init=0.0)),
        "  sum p_min = ", round(sum(g.p_min for g in gas; init=0.0)))
println("fuel_type symbols present: ", unique([string(g.fuel_type) for g in gens]))
