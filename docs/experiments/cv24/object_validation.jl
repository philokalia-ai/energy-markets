#!/usr/bin/env julia
# cv24 object-level validation — re-run the GME book comparison's composition
# measure on OUR new Italian book. Builds the single-zone merit book (IT profile)
# for the three GME sample days (2023-01-17 / 04-19 / 07-19) at hours 04/12/19,
# for both arms (base = EUPHEMIA_DISABLE_CV24; cv24 = the must-run floor on), and
# reports the supply-curve composition by price band (≤0 / 0-150 / 150-300 / >300)
# + the offered-volume total per zone. The novel gate: does the ≤0 volume share
# move from 0% (v10 unimodal SRMC stack) TOWARD the real GME ~45% must-run floor?
#
#   EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_PATH=.../euphemia-live.duckdb \
#     julia --project=. docs/experiments/cv24/object_validation.jl
using Euphemia, Dates, Printf
const MO = Euphemia.MeritOrderBook

const IT_ZONES = ["IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH",
                  "IT-Calabria","IT-Sicily","IT-Sardinia"]
const DAYS = [Date(2023,1,17), Date(2023,4,19), Date(2023,7,19)]
const HOURS = [4,12,19]
# GME real ≤0 share (composition_by_zone.tsv, gme_le0) + our OLD (v10) vol ratio.
const GME_LE0 = Dict("IT-NORTH"=>0.36,"IT-CNORTH"=>0.64,"IT-CSOUTH"=>0.27,
    "IT-SOUTH"=>0.36,"IT-Calabria"=>0.34,"IT-Sicily"=>0.38,"IT-Sardinia"=>0.79)
const VOL_RATIO_OLD = Dict("IT-NORTH"=>1.23,"IT-CNORTH"=>1.37,"IT-CSOUTH"=>1.54,
    "IT-SOUTH"=>1.15,"IT-Calabria"=>1.22,"IT-Sicily"=>1.49,"IT-Sardinia"=>1.45)

# Composition of a supply staircase (drop the corrupt >25 GW unit block in BOTH
# arms so the base arm is not distorted by the 13M-MW registry row).
function bands(tagged)
    sup = [(o.price, o.quantity) for (o,tag) in tagged
           if o.type == :supply && o.quantity <= 25_000.0]
    tot = sum(q for (_,q) in sup; init=0.0)
    tot <= 0 && return (NaN,NaN,NaN,NaN,0.0)
    le0 = sum(q for (p,q) in sup if p <= 0; init=0.0)/tot
    mid = sum(q for (p,q) in sup if 0 < p <= 150; init=0.0)/tot
    hi  = sum(q for (p,q) in sup if 150 < p <= 300; init=0.0)/tot
    cap = sum(q for (p,q) in sup if p > 300; init=0.0)/tot
    (le0,mid,hi,cap,tot)
end

function run_arm(arm)
    if arm == "base"; ENV["EUPHEMIA_DISABLE_CV24"] = "1"
    else; delete!(ENV, "EUPHEMIA_DISABLE_CV24"); end
    Euphemia.clear_generator_caches!(); MO.clear_fleet_data_caches!()
    captured = Dict{Tuple{String,Date},Vector{Tuple{Euphemia.SimpleOrder,String}}}()
    MO.BOOK_SINK[] = (z,d,tagged,res) -> (captured[(z,d)] = copy(tagged))
    per = Dict{String,Vector{NTuple{5,Float64}}}(z=>[] for z in IT_ZONES)
    for d in DAYS, z in IT_ZONES
        empty!(captured)
        MO.create_merit_order_book(z, d; profile=MO.get_zone_profile(z))
        haskey(captured,(z,d)) || continue
        tagged = captured[(z,d)]
        for h in HOURS
            ht = filter(t -> Dates.hour(t[1].date_time)==h, tagged)
            isempty(ht) && continue
            push!(per[z], bands(ht))
        end
    end
    MO.BOOK_SINK[] = nothing
    per
end

meancol(v,i) = isempty(v) ? NaN : sum(x[i] for x in v)/length(v)

base = run_arm("base"); cv24 = run_arm("cv24")
println("\n==== cv24 object validation: supply composition (≤0/mid/hi/cap) + volume ====")
@printf("%-12s | base ≤0  cv24 ≤0  GME ≤0 | base_vol cv24_vol volΔ%% | old_ratio new_ratio\n", "zone")
tot_b_le0=Float64[]; tot_c_le0=Float64[]; ratios=Float64[]
for z in IT_ZONES
    b=base[z]; c=cv24[z]
    ble0=meancol(b,1); cle0=meancol(c,1)
    bvol=meancol(b,5); cvol=meancol(c,5)
    voldelta = 100*(cvol-bvol)/bvol
    new_ratio = VOL_RATIO_OLD[z] * cvol/bvol
    push!(tot_b_le0,ble0); push!(tot_c_le0,cle0); push!(ratios,new_ratio)
    @printf("%-12s | %6.2f  %6.2f  %6.2f | %8.0f %8.0f %+5.1f | %8.2f %8.2f\n",
        z, ble0, cle0, GME_LE0[z], bvol, cvol, voldelta, VOL_RATIO_OLD[z], new_ratio)
end
@printf("\nAGGREGATE ≤0 share: base %.2f  →  cv24 %.2f   (GME real ~0.45)\n",
    sum(tot_b_le0)/length(tot_b_le0), sum(tot_c_le0)/length(tot_c_le0))
@printf("AGGREGATE vol ratio (our/GME): old %.2f  →  new %.2f   (target ~1.0-1.1)\n",
    sum(values(VOL_RATIO_OLD))/7, sum(ratios)/length(ratios))
