#!/usr/bin/env julia
# Score the cv23 A/B (ab_cv23.jl outputs) against REALIZED day-ahead prices read
# from the offline extract (entsoe.energy_prices, hourly AVG) — no Postgres.
# Per zone × window: MAE, bias, corr, evening (17-20 UTC) bias/MAE, for base and
# cv23, plus the deltas. Prints the gate-zone table and the footprint means.
#
#   EUPHEMIA_DUCKDB_PATH=.../x.duckdb julia --project=. \
#     docs/experiments/cv23/score_cv23.jl base.tsv cv23.tsv windows.json
using DuckDB, Printf, DataFrames, CSV, Statistics, Dates, JSON
basef, cv23f, winf = ARGS[1], ARGS[2], ARGS[3]
windows = Dict(k => Set(String.(v)) for (k,v) in JSON.parsefile(winf))
con = DBInterface.connect(DuckDB.DB(ENV["EUPHEMIA_DUCKDB_PATH"]; readonly=true))

function loadarm(path)
    df = CSV.read(path, DataFrame)
    df.ts = DateTime.(string.(df.timeslot), dateformat"yyyymmdd-HHMM")
    df.h = floor.(df.ts, Hour(1))
    combine(groupby(df, [:day,:zone,:h]), :price=>mean=>:price)
end
b = loadarm(basef); c = loadarm(cv23f)
rename!(b,:price=>:base); rename!(c,:price=>:cv23)
sim = outerjoin(b, c, on=[:day,:zone,:h])

# realized from extract
real = DataFrame(DBInterface.execute(con, """
  SELECT map_code AS zone, date_trunc('hour', date_time_utc) AS h, AVG(price_currency_mwh) AS act
  FROM entsoe.energy_prices WHERE contract_type='Day-ahead' GROUP BY 1,2"""))
real.h = DateTime.(real.h)
m = innerjoin(sim, real, on=[:zone,:h])
m.day = string.(m.day)
m.hour = Dates.hour.(m.h)
m.eve = (m.hour .>= 17) .& (m.hour .<= 20)

mae(x)=isempty(x) ? NaN : mean(abs.(x))
bias(x)=isempty(x) ? NaN : mean(x)
corr(a,b)=(length(a)<3||std(a)==0||std(b)==0) ? NaN : cor(a,b)

function score(g, arm)
    r = g[.!ismissing.(g[!,arm]),:]
    isempty(r) && return (NaN,NaN,NaN,NaN,NaN)
    res = Float64.(r[!,arm]) .- r.act
    ev = res[r.eve]
    (mae(res), bias(res), corr(Float64.(r[!,arm]), r.act), mae(ev), bias(ev))
end

GATE = ["FR","BE","NL","NO2","DK1"]
for (wname, wdays) in sort(collect(windows); by=first)  # by key: Set values are not comparable
    w = m[in.(m.day, Ref(wdays)),:]
    isempty(w) && continue
    println("\n===== WINDOW $wname ($(length(unique(w.day))) days) =====")
    @printf("%-6s | %-28s | %-28s | %s\n","zone","base MAE/bias/corr eveB/eveMAE","cv23 MAE/bias/corr eveB/eveMAE","Δ")
    for z in GATE
        g = w[w.zone.==z,:]
        isempty(g) && continue
        bm,bb,bc,bem,beb = score(g,:base)
        cm,cb,cc,cem,ceb = score(g,:cv23)
        @printf("%-6s | %6.1f %+6.1f %5.2f %+6.1f %5.1f | %6.1f %+6.1f %5.2f %+6.1f %5.1f | dMAE=%+5.1f dCorr=%+.2f dEveB=%+5.1f\n",
            z, bm,bb,bc,beb,bem, cm,cb,cc,ceb,cem, cm-bm, cc-bc, ceb-beb)
    end
    # footprint means (over all zones present)
    zb=Float64[]; zc=Float64[]; zbe=Float64[]; zce=Float64[]
    zbc=Float64[]; zcc=Float64[]
    for z in unique(w.zone)
        g=w[w.zone.==z,:]
        bm,_,bc,_,beb=score(g,:base); cm,_,cc,_,ceb=score(g,:cv23)
        isnan(bm)||isnan(cm) || (push!(zb,bm);push!(zc,cm))
        isnan(beb)||isnan(ceb) || (push!(zbe,beb);push!(zce,ceb))
        isnan(bc)||isnan(cc) || (push!(zbc,bc);push!(zcc,cc))
    end
    @printf("FOOTPRINT mean MAE %.2f -> %.2f | mean corr %.3f -> %.3f | mean eveBias %+.1f -> %+.1f | (%d/%d zones MAE better)\n",
        mean(zb),mean(zc),mean(zbc),mean(zcc),mean(zbe),mean(zce), count(zc.<zb),length(zb))
end
