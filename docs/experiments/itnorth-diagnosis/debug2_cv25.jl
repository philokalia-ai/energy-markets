using Dates
ENV["EUPHEMIA_DATA_STORE"]="duckdb"
ENV["EUPHEMIA_DUCKDB_PATH"]="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"]="true"
using Euphemia
const MO = Euphemia.MeritOrderBook
day = Date(2025,7,8)
# Inspect the pre-merge tagged book via BOOK_SINK
MO.BOOK_SINK[] = function(zone, d, tagged, resmin)
    le0=0.0; tot=0.0; owners_le0=Set{String}()
    for (o,tag) in tagged
        o.type==:supply || continue
        tot+=o.quantity
        if o.price<=0.0
            le0+=o.quantity; push!(owners_le0, tag)
        end
    end
    println(">>> $zone pre-merge supply: ≤0 = $(round(le0)) MW / total $(round(tot)) MW ; ≤0 owners=$(length(owners_le0))")
end
for z in ["IT-NORTH"]
    delete!(ENV,"EUPHEMIA_DISABLE_CV25"); MO.clear_fleet_data_caches!()
    println("--- $z cv25 ON ---"); MO.create_merit_order_book(z, day)
    ENV["EUPHEMIA_DISABLE_CV25"]="1"; MO.clear_fleet_data_caches!()
    println("--- $z cv25 OFF ---"); MO.create_merit_order_book(z, day)
    delete!(ENV,"EUPHEMIA_DISABLE_CV25")
end
MO.BOOK_SINK[] = nothing
