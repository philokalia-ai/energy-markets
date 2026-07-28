# Score the A/B: per-zone corr/MAE both arms vs settled (overall + evening).
# ab csv cols: day,arm,zone,ts,price  (ts = "yyyymmdd-HHMM" UTC)
# settled_neighbors.csv cols: zone,utc,settled  (utc = naive UTC DateTime)
# Usage: NL_OUT=<ab_csv> SP=<scratch> WINDOW=<label> julia --project=. score_ab.jl
using CSV, DataFrames, Statistics, Dates, Printf
SP=ENV["SP"]
ab=CSV.read(ENV["NL_OUT"], DataFrame)
set=CSV.read(joinpath(SP,"settled_neighbors.csv"), DataFrame)
sd=Dict((string(r.zone),DateTime(r.utc)) => Float64(r.settled) for r in eachrow(set))
ab.dt=[DateTime(String(t), dateformat"yyyymmdd-HHMM") for t in ab.ts]
ab.hh=hour.(ab.dt)
ab.mset=[get(sd,(String(r.zone),r.dt),missing) for r in eachrow(ab)]
dropmissing!(ab,:mset)
sc(d)= nrow(d)<3 ? (nrow(d),NaN,NaN,NaN) :
       (nrow(d),round(cor(d.price,d.mset),digits=3),round(mean(abs.(d.price.-d.mset)),digits=2),round(mean(d.price.-d.mset),digits=2))
println("=== WINDOW=",get(ENV,"WINDOW","?"),"  ndays=",length(unique(ab.day))," ===")
for z in ["NL","BE","DE_LU","DK1","NO2","FR"]
  a=ab[(ab.zone.==z).&(ab.arm.=="A_off"),:]; b=ab[(ab.zone.==z).&(ab.arm.=="B_on"),:]
  (nrow(a)==0||nrow(b)==0) && continue
  na,ca,ma,ba=sc(a); nb,cb,mb,bb=sc(b)
  ae=a[(a.hh.>=17).&(a.hh.<=19),:]; be=b[(b.hh.>=17).&(b.hh.<=19),:]
  _,cae,mae,bae=sc(ae); _,cbe,mbe,bbe=sc(be)
  @printf("%-7s A corr=%.3f MAE=%6.2f bias=%7.2f | B corr=%.3f MAE=%6.2f bias=%7.2f || EVE MAE %5.1f->%5.1f corr %.3f->%.3f bias %6.1f->%6.1f\n",
    z,ca,ma,ba,cb,mb,bb,mae,mbe,cae,cbe,bae,bbe)
end
