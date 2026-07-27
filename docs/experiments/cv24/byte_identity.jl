#!/usr/bin/env julia
# cv24 byte-identity guard. Builds the FULL tagged order book for a set of zones
# both with the cv24 mechanism ACTIVE and with the EUPHEMIA_DISABLE_CV24 kill-
# switch set (which reverts every cv24 delta — must-run floor + registry sanity
# bound — to cv23 main by construction). Reports, per zone, whether the two books
# are bit-identical. Expectation: every NON-Italian zone (GR single-zone / SEE
# 5-zone / continental EU) is bit-identical (the mechanism does not leak), and the
# Italian zones differ (the mechanism fires). Since cv24-disabled == cv23-main by
# construction (all deltas gated), non-IT identity here == byte-identity vs main.
#
#   EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true \
#     EUPHEMIA_DUCKDB_PATH=.../euphemia-live.duckdb \
#     julia --project=. docs/experiments/cv24/byte_identity.jl
using Euphemia, Dates, Printf
const MO = Euphemia.MeritOrderBook
const DAY = Date(2023,7,19)
const ZONES = ["GR","BG","RO","RS","HU",          # SEE (single-zone / 5-zone product)
               "DE_LU","FR","NO2","CH","ES",       # non-IT EU
               "IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-Sardinia"]  # IT (must differ)

function bookkey(z)
    Euphemia.clear_generator_caches!(); MO.clear_fleet_data_caches!()
    cap = Ref{Any}(nothing)
    MO.BOOK_SINK[] = (zz,dd,tagged,res) -> (cap[] = copy(tagged))
    MO.create_merit_order_book(z, DAY; profile=MO.get_zone_profile(z))
    MO.BOOK_SINK[] = nothing
    cap[] === nothing && return UInt(0)
    rows = sort([(string(o.type), round(o.price,digits=6), round(o.quantity,digits=6),
                  string(o.date_time), tag) for (o,tag) in cap[]])
    hash(rows)
end

println("cv24 byte-identity guard on $DAY")
@printf("%-14s | %-10s | %-10s | %s\n","zone","cv24 hash","base hash","identical?")
nfail = 0
for z in ZONES
    delete!(ENV,"EUPHEMIA_DISABLE_CV24"); h_on = bookkey(z)
    ENV["EUPHEMIA_DISABLE_CV24"]="1";    h_off = bookkey(z)
    delete!(ENV,"EUPHEMIA_DISABLE_CV24")
    is_it = startswith(z,"IT")
    same = h_on == h_off
    ok = is_it ? !same : same     # non-IT must match; IT must differ
    ok || (global nfail += 1)
    @printf("%-14s | %10x | %10x | %-5s %s\n", z, h_on%0x100000000, h_off%0x100000000,
        same, ok ? "OK" : "*** GATE FAIL ***")
end
println(nfail==0 ? "\nGUARD PASS: non-IT bit-identical, IT changed." :
                   "\nGUARD FAIL: $nfail zone(s) violated expectation.")
