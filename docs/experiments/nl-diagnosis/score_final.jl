# Comprehensive A/B scorer for the wider NL confirm.
# Prints: NL per-day (winter days individually), and per-season per-zone aggregates.
# Usage: NL_OUT=<ab2.csv> SP=<scratch> julia --project=. score_final.jl
using CSV, DataFrames, Statistics, Dates, Printf
SP=ENV["SP"]
ab=CSV.read(ENV["NL_OUT"], DataFrame)
set=CSV.read(joinpath(SP,"settled_neighbors.csv"), DataFrame)
sd=Dict((string(r.zone),DateTime(r.utc)) => Float64(r.settled) for r in eachrow(set))
ab.dt=[DateTime(String(t), dateformat"yyyymmdd-HHMM") for t in ab.ts]
ab.hh=hour.(ab.dt)
ab.mset=[get(sd,(String(r.zone),r.dt),missing) for r in eachrow(ab)]
dropmissing!(ab,:mset)
# Drop degenerate days (source-data gap ⇒ <24h NL coverage in either arm; e.g.
# 2025-12-15 returned 1 slot). Excluded blind to their A/B score.
nlcount(d,arm)=sum((ab.zone.=="NL").&(ab.arm.==arm).&(string.(ab.day).==d))
baddays=Set(d for d in string.(unique(ab.day)) if nlcount(d,"A_off")<24 || nlcount(d,"B_on")<24)
isempty(baddays)||println("EXCLUDED degenerate days (<24h): ",join(sort(collect(baddays)),","))
ab=ab[.!in.(string.(ab.day),Ref(baddays)),:]
WINTER=["2025-11-01","2025-11-15","2025-12-01","2025-12-15","2026-01-01","2026-01-15","2026-02-01","2026-02-15"]
SUMMER=["2025-05-01","2025-05-15","2025-06-01","2025-06-15","2025-07-01","2025-07-15","2025-08-01","2025-08-15"]
sc(d)= nrow(d)<3 ? (nrow(d),NaN,NaN,NaN) :
       (nrow(d),round(cor(d.price,d.mset),digits=3),round(mean(abs.(d.price.-d.mset)),digits=2),round(mean(d.price.-d.mset),digits=2))
function line(tag,z,a,b)
  na,ca,ma,ba=sc(a); nb,cb,mb,bb=sc(b)
  ae=a[(a.hh.>=17).&(a.hh.<=19),:]; be=b[(b.hh.>=17).&(b.hh.<=19),:]
  _,_,mae,_=sc(ae); _,_,mbe,_=sc(be)
  ep = (isnan(mae)||mae==0) ? NaN : round(100*(mbe-mae)/mae,digits=1)
  @printf("%-22s %-6s A c=%.3f MAE=%6.2f | B c=%.3f MAE=%6.2f | dC=%+.3f dMAE%%=%+.1f eveMAE %5.1f->%5.1f(%+.1f%%)\n",
    tag,z,ca,ma,cb,mb,cb-ca,100*(mb-ma)/ma,mae,mbe,ep)
end
avail=Set(string.(unique(ab.day)))
println("### NL PER-DAY — WINTER ###")
for dd in WINTER; dd in avail || continue
  a=ab[(ab.zone.=="NL").&(ab.arm.=="A_off").&(string.(ab.day).==dd),:]
  b=ab[(ab.zone.=="NL").&(ab.arm.=="B_on").&(string.(ab.day).==dd),:]
  (nrow(a)>0&&nrow(b)>0)&&line(dd,"NL",a,b)
end
println("\n### NL PER-DAY — SUMMER ###")
for dd in SUMMER; dd in avail || continue
  a=ab[(ab.zone.=="NL").&(ab.arm.=="A_off").&(string.(ab.day).==dd),:]
  b=ab[(ab.zone.=="NL").&(ab.arm.=="B_on").&(string.(ab.day).==dd),:]
  (nrow(a)>0&&nrow(b)>0)&&line(dd,"NL",a,b)
end
# PAIRED days only: a day counts iff BOTH arms completed it (balanced A vs B).
paired(days)= [d for d in days if d in avail &&
  any((ab.arm.=="A_off").&(string.(ab.day).==d)) && any((ab.arm.=="B_on").&(string.(ab.day).==d))]
for (nm,days0) in (("WINTER",WINTER),("SUMMER",SUMMER))
  days=paired(days0); ds=Set(days)
  println("\n### $nm AGGREGATE (paired days=",length(days),": ",join(days,","),") ###")
  for z in ["NL","BE","DE_LU","DK1","NO2","FR"]
    a=ab[(ab.zone.==z).&(ab.arm.=="A_off").&(in.(string.(ab.day),Ref(ds))),:]
    b=ab[(ab.zone.==z).&(ab.arm.=="B_on").&(in.(string.(ab.day),Ref(ds))),:]
    (nrow(a)>0&&nrow(b)>0)&&line(nm,z,a,b)
  end
end
