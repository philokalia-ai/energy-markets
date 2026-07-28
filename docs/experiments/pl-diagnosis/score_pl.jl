#!/usr/bin/env julia
# Score the PL A/B (ab_pl_spread.jl outputs) vs REALIZED day-ahead prices from
# the offline extract (entsoe.energy_prices, hourly AVG). Per zone × window:
# MAE, bias, corr, evening (16-19 UTC) bias/MAE, base vs spread + deltas.
# PL = primary; DE_LU/CZ/SK/LT/SE4 = coupled-neighbour guard; FR/GR = controls.
#
#   EUPHEMIA_DUCKDB_PATH=.../x.duckdb julia --project=. \
#     docs/experiments/pl-diagnosis/score_pl.jl base.tsv spread.tsv windows.json
using DuckDB, Printf, DataFrames, CSV, Statistics, Dates, JSON
basef, sprf, winf = ARGS[1], ARGS[2], ARGS[3]
windows = Dict(k => Set(String.(v)) for (k,v) in JSON.parsefile(winf))
con = DBInterface.connect(DuckDB.DB(ENV["EUPHEMIA_DUCKDB_PATH"]; readonly=true))
function loadarm(path)
    df = CSV.read(path, DataFrame)
    df.ts = DateTime.(string.(df.timeslot), dateformat"yyyymmdd-HHMM")
    df.h = floor.(df.ts, Hour(1))
    combine(groupby(df, [:day,:zone,:h]), :price=>mean=>:price)
end
b = loadarm(basef); c = loadarm(sprf)
rename!(b,:price=>:base); rename!(c,:price=>:spread)
sim = outerjoin(b, c, on=[:day,:zone,:h])
real = DataFrame(DBInterface.execute(con, """
  SELECT map_code AS zone, date_trunc('hour', date_time_utc) AS h, AVG(price_currency_mwh) AS act
  FROM entsoe.energy_prices WHERE contract_type='Day-ahead' AND currency='EUR' GROUP BY 1,2"""))
real.h = DateTime.(real.h)
m = innerjoin(sim, real, on=[:zone,:h])
m.day = string.(m.day); m.hour = Dates.hour.(m.h)
m.eve = (m.hour .>= 16) .& (m.hour .<= 19)
mae(x)=isempty(x) ? NaN : mean(abs.(x)); bias(x)=isempty(x) ? NaN : mean(x)
corr(a,b)=(length(a)<3||std(a)==0||std(b)==0) ? NaN : cor(a,b)
function score(g, arm)
    r = g[.!ismissing.(g[!,arm]),:]; isempty(r) && return (NaN,NaN,NaN,NaN,NaN)
    res = Float64.(r[!,arm]) .- r.act; ev = res[r.eve]
    (mae(res), bias(res), corr(Float64.(r[!,arm]), r.act), mae(ev), bias(ev))
end
PRIMARY=["PL"]; GUARD=["DE_LU","CZ","SK","LT","SE4","NO4","SE3"]; CTRL=["FR","GR","ES","IT-NORTH"]
for (wname, wdays) in sort(collect(windows); by=first)
    w = m[in.(m.day, Ref(wdays)),:]; isempty(w) && continue
    println("\n===== WINDOW $wname ($(length(unique(w.day))) days) =====")
    @printf("%-7s | %-30s | %-30s | %s\n","zone","base MAE bias corr eveB eveMAE","spread MAE bias corr eveB eveMAE","delta")
    for (grp,label) in [(PRIMARY,"PRIMARY"),(GUARD,"GUARD"),(CTRL,"CTRL")]
        println("-- $label --")
        for z in grp
            g = w[w.zone.==z,:]; isempty(g) && continue
            bm,bb,bc,bem,beb = score(g,:base); cm,cb,cc,cem,ceb = score(g,:spread)
            @printf("%-7s | %6.1f %+6.1f %5.2f %+6.1f %6.1f | %6.1f %+6.1f %5.2f %+6.1f %6.1f | dMAE=%+5.1f dCorr=%+.3f dEveB=%+5.1f\n",
                z, bm,bb,bc,beb,bem, cm,cb,cc,ceb,cem, cm-bm, cc-bc, ceb-beb)
        end
    end
    zb=Float64[]; zc=Float64[]; zbc=Float64[]; zcc=Float64[]
    for z in unique(w.zone)
        g=w[w.zone.==z,:]; bm,_,bc,_,_=score(g,:base); cm,_,cc,_,_=score(g,:spread)
        isnan(bm)||isnan(cm)||(push!(zb,bm);push!(zc,cm))
        isnan(bc)||isnan(cc)||(push!(zbc,bc);push!(zcc,cc))
    end
    @printf("FOOTPRINT mean MAE %.2f -> %.2f | mean corr %.3f -> %.3f | (%d/%d zones MAE better)\n",
        mean(zb),mean(zc),mean(zbc),mean(zcc), count(zc.<zb),length(zb))
    # cv18 Nordic cap-day guard: count phantom-scarcity (>=500) and hard-cap (>=2999) hours per zone
    println("-- CAP-DAY GUARD (hours >=500 / >=2999): base -> spread --")
    NORDIC=["NO1","NO2","NO3","NO4","NO5","SE1","SE2","SE3","SE4","FI","DK1","DK2","PL","DE_LU"]
    for z in NORDIC
        g = w[w.zone.==z,:]; isempty(g) && continue
        rb = g[.!ismissing.(g.base),:]; rc = g[.!ismissing.(g.spread),:]
        b500=count(>=(500.0), Float64.(rb.base)); c500=count(>=(500.0), Float64.(rc.spread))
        bcap=count(>=(2999.0), Float64.(rb.base)); ccap=count(>=(2999.0), Float64.(rc.spread))
        flag = (c500-b500) > 2 ? "  <== CAP-RISE (cv18 mode)" : ""
        @printf("%-7s | >=500: %3d -> %3d   >=2999: %3d -> %3d%s\n", z, b500,c500,bcap,ccap,flag)
    end
end
