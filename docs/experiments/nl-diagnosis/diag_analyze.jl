using CSV, DataFrames, Statistics, Dates, Printf
SP = ENV["SP"]
df = CSV.read(joinpath(SP,"nl_resid.csv"), DataFrame)
dropmissing!(df, [:model,:settled])
# EU DST: last Sun Mar 01:00 UTC .. last Sun Oct 01:00 UTC => +2 else +1
lastsun(y,m) = (d=Date(y,m,31); d - Day(mod(dayofweek(d),7)))
function euoff(u::DateTime)
  y=year(u); s=DateTime(lastsun(y,3),Time(1)); e=DateTime(lastsun(y,10),Time(1))
  (u>=s && u<e) ? 2 : 1
end
df.lhour = [hour(u + Hour(euoff(u))) for u in df.utc]
df.year = year.(df.utc)
mo = month.(df.utc)
df.season = map(m-> m in (12,1,2) ? "DJF" : m in (3,4,5) ? "MAM" : m in (6,7,8) ? "JJA" : "SON", mo)
df.resid = df.model .- df.settled

metrics(d) = (n=nrow(d), corr = nrow(d)>2 ? round(cor(d.model,d.settled),digits=3) : missing,
              mae=round(mean(abs.(d.resid)),digits=2), bias=round(mean(d.resid),digits=2),
              set=round(mean(d.settled),digits=1))

println("=== BY YEAR ===")
for y in sort(unique(df.year)); m=metrics(df[df.year.==y,:]); @printf("%d  n=%5d corr=%.3f MAE=%6.2f bias=%7.2f settled=%.1f\n",y,m.n,m.corr,m.mae,m.bias,m.set); end

println("\n=== BY SEASON (all years) ===")
for s in ["DJF","MAM","JJA","SON"]; m=metrics(df[df.season.==s,:]); @printf("%s  n=%5d corr=%.3f MAE=%6.2f bias=%7.2f settled=%.1f\n",s,m.n,m.corr,m.mae,m.bias,m.set); end

println("\n=== BY LOCAL HOUR (bias & MAE, all years) ===")
for h in 0:23; d=df[df.lhour.==h,:]; m=metrics(d); @printf("h%02d bias=%7.2f MAE=%6.2f settled=%.1f\n",h,m.bias,m.mae,m.set); end

println("\n=== SEASON x DAYPART bias (model-settled) ===")
daypart(h)= h in 0:5 ? "night" : h in 6:10 ? "morn" : h in 11:15 ? "midday" : h in 16:21 ? "evening" : "latenight"
df.dp = daypart.(df.lhour)
for s in ["DJF","MAM","JJA","SON"], dp in ["night","morn","midday","evening","latenight"]
  d=df[(df.season.==s).&(df.dp.==dp),:]; isempty(d)&&continue; m=metrics(d)
  @printf("%s %-9s bias=%7.2f MAE=%6.2f settled=%.1f\n",s,dp,m.bias,m.mae,m.set)
end
