# cv25 validation: byte-identity (non-IT unchanged) + IT floor fires + ≤€0 volume.
using Dates
ENV["EUPHEMIA_DATA_STORE"]="duckdb"
ENV["EUPHEMIA_DUCKDB_PATH"]="/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"]="true"
using Euphemia
const MO = Euphemia.MeritOrderBook
day = Date(2025,7,8)

function book(zone, d)
    prof = get(MO.ZONE_PROFILES, zone, MO.SEE_PROFILE)
    res = MO.create_merit_order_book(zone, d; profile=prof)
    res.success || return (nothing, NaN, NaN, NaN)
    os = sort([(o.type, round(o.price,digits=4), round(o.quantity,digits=4), o.date_time) for o in res.order_book.orders])
    tot=0.0; le0=0.0
    for o in res.order_book.orders
        o.type==:supply || continue
        tot+=o.quantity; o.price<=0.0 && (le0+=o.quantity)
    end
    return (hash(os), le0, tot, tot>0 ? le0/tot : 0.0)
end

for zone in ["GR","IT-NORTH","IT-CSOUTH","CH","FR"]
    delete!(ENV,"EUPHEMIA_DISABLE_CV25"); MO.clear_fleet_data_caches!()
    on = book(zone, day)
    ENV["EUPHEMIA_DISABLE_CV25"]="1"; MO.clear_fleet_data_caches!()
    off = book(zone, day)
    delete!(ENV,"EUPHEMIA_DISABLE_CV25")
    identical = on[1]==off[1]
    println("$zone: on≡off=$(identical) | ON ≤0 share $(round(on[4],digits=3)) ($(round(on[2])) MW) | OFF ≤0 $(round(off[2])) MW | tot $(round(on[3]))")
end
