#!/usr/bin/env julia
# capture_book_features.jl DAY OUTCSV — build every zone's merit-order book for
# DAY (live Postgres) and emit hourly ex-ante features (D, RES/IMPORT/BACKSTOP
# MW, total supply) via the strategist hook. Sub-hourly slots are AVERAGED into
# hours (PT15M books would otherwise inflate the MW scale 4x). Used by
# bin/emit_model_lines.sh to grow the model-line feature cache one day per run.
using Euphemia, Dates
MO = Euphemia.MeritOrderBook
day = Date(ARGS[1]); out = ARGS[2]
ZONES = ["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT","LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH"]
open(out, "w") do io
    println(io, "zone,k,D,res_mw,imp_mw,bst_mw,stot")
    for z in ZONES
        agg = Dict{String,Dict{Symbol,Float64}}()
        slot = Dict{DateTime,Dict{Symbol,Float64}}()
        cap = ctx -> begin
            for (o, owner) in ctx.tagged_orders
                a = get!(slot, o.date_time, Dict(:D=>0.0,:res=>0.0,:imp=>0.0,:bst=>0.0,:stot=>0.0))
                if o.type == :demand
                    a[:D] += o.quantity
                else
                    a[:stot] += o.quantity
                    owner == "RES" && (a[:res] += o.quantity)
                    owner == "IMPORT" && (a[:imp] += o.quantity)
                    owner == "BACKSTOP" && (a[:bst] += o.quantity)
                end
            end
            cnt = Dict{String,Int}()
            for (ts, a) in slot
                k = Dates.format(ts, "yyyy-mm-ddTHH")
                h = get!(agg, k, Dict(:D=>0.0,:res=>0.0,:imp=>0.0,:bst=>0.0,:stot=>0.0))
                for f in (:D,:res,:imp,:bst,:stot); h[f] += a[f]; end
                cnt[k] = get(cnt, k, 0) + 1
            end
            for (k, h) in agg, f in (:D,:res,:imp,:bst,:stot)
                h[f] /= max(cnt[k], 1)
            end
            ctx.tagged_orders
        end
        r = try
            MO.create_merit_order_book(z, day; profile=MO.get_zone_profile(z), strategist=cap)
        catch e
            println("FAIL $z: ", sprint(showerror, e)); continue
        end
        (r.success && !isempty(agg)) || (println("FAIL $z: $(r.message)"); continue)
        for (k, a) in sort(collect(agg); by=first)
            println(io, "$z,$k,$(a[:D]),$(a[:res]),$(a[:imp]),$(a[:bst]),$(a[:stot])")
        end
        println("OK $z"); flush(stdout)
    end
end
println("FEATURES DONE $day")
