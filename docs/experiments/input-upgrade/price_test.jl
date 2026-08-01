# Price-level test: does injecting the NEW predicted inputs collapse GR July middays?
# Arms: reference (ENTSO-E inputs, no scenario) | baseline packs | new models.
# Replicates bin/daily_forecast.jl weather track: renewable->0 + RES as price-taker
# supply + load override, applied to the 4 pilot zones (neighbours keep reference).
using Euphemia, Dates, JSON, Statistics, Printf

const SP="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
const PILOTS=["GR","ES","DE_LU","SE2","NL"]
const DAYS=[Date(2026,7,24),Date(2026,7,25),Date(2026,7,26),Date(2026,7,27)]

# inputs[arm][zone]["yyyymmdd-HHMM"] = [load, solar, wind]
loadj(f)=JSON.parsefile(f)
INP=Dict("new"=>loadj("$SP/inputs_new.json"), "base"=>loadj("$SP/inputs_base.json"))

function scenario_for(arm::String)
    data=INP[arm]
    sc=Dict{String,Euphemia.ZoneScenario}()
    for z in PILOTS
        zd=get(data,z,Dict{String,Any}())
        zero_res=(ts,mw)->0.0
        extra=ctx->begin
            os=Euphemia.SimpleOrder[]
            for ts in ctx.timeslots
                v=get(zd,ts,nothing); v===nothing && continue
                mw=Float64(v[2])+Float64(v[3])   # solar+wind
                mw>0.0 || continue
                dt=DateTime(ts,dateformat"yyyymmdd-HHMM")
                push!(os,Euphemia.SimpleOrder(:supply,1.0,mw,Symbol(ctx.zone),dt,ctx.resolution_minutes))
            end
            os
        end
        lmod=(ts,mw)->begin
            v=get(zd,ts,nothing)
            (v===nothing || v[1]===nothing) ? mw : Float64(v[1])
        end
        sc[z]=Euphemia.ZoneScenario(load_modifier=lmod,renewable_modifier=zero_res,extra_orders=extra)
    end
    return sc
end

function midday_mean(result, zone)
    haskey(result.market_prices,zone) || return NaN
    hp=Dict{DateTime,Vector{Float64}}()
    for (k,v) in result.market_prices[zone]
        dt=DateTime(k,dateformat"yyyymmdd-HHMM"); h=trunc(dt,Hour)
        push!(get!(hp,h,Float64[]),v)
    end
    vals=Float64[]
    for (h,vs) in hp
        (9<=Dates.hour(h)<=15) && push!(vals,mean(vs))
    end
    isempty(vals) ? NaN : mean(vals)
end

function clear(day; scenario=nothing)
    r=Euphemia.run_multi_zone_market_clearing(day; order_method=:merit_order,
        optimizer="highs", silent=true, save_to_db=false, enrich_network=true,
        passes=2, scenario=scenario)
    return r
end

# all hourly prices for a zone: Dict "yyyymmdd-HHMM" => price (mean of sub-hourly)
function hourly_all(result, zone)
    haskey(result.market_prices,zone) || return Dict{String,Float64}()
    acc=Dict{DateTime,Vector{Float64}}()
    for (k,v) in result.market_prices[zone]
        dt=DateTime(k,dateformat"yyyymmdd-HHMM"); push!(get!(acc,trunc(dt,Hour),Float64[]),v)
    end
    Dict(Dates.format(h,"yyyymmdd-HHMM")=>mean(vs) for (h,vs) in acc)
end

println("day        zone   ref    base    new")
results=[]; hourly_rec=[]
for day in DAYS
    rref=clear(day)
    rbase=clear(day; scenario=scenario_for("base"))
    rnew=clear(day; scenario=scenario_for("new"))
    for z in PILOTS
        a=midday_mean(rref,z); b=midday_mean(rbase,z); c=midday_mean(rnew,z)
        @printf("%s %-5s %6.1f %6.1f %6.1f\n", day, z, a, b, c)
        push!(results,(day=string(day),zone=z,ref=a,base=b,new=c))
        push!(hourly_rec,(day=string(day),zone=z,
            ref=hourly_all(rref,z),base=hourly_all(rbase,z),new=hourly_all(rnew,z)))
    end
    flush(stdout)
end
open("$SP/price_test_results.json","w") do io; JSON.print(io,results); end
open("$SP/price_hourly.json","w") do io; JSON.print(io,hourly_rec); end
println("PRICE_TEST_DONE")
