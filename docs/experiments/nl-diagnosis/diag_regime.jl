using DuckDB, DataFrames, CSV, Statistics, Dates, Printf
SP=ENV["SP"]
df = CSV.read(joinpath(SP,"nl_resid.csv"), DataFrame)
dropmissing!(df,[:model,:settled])
lastsun(y,m)=(d=Date(y,m,31); d-Day(mod(dayofweek(d),7)))
euoff(u)=(y=year(u); (u>=DateTime(lastsun(y,3),Time(1)) && u<DateTime(lastsun(y,10),Time(1))) ? 2 : 1)
df.lhour=[hour(u+Hour(euoff(u))) for u in df.utc]
df.resid=df.model.-df.settled
df.nettot = coalesce.(df.imp_GB,0).+coalesce.(df.imp_NO2,0).+coalesce.(df.imp_DK1,0).+coalesce.(df.imp_BE,0).+coalesce.(df.imp_DE_LU,0)

# 1. Evening focus: residual vs GB import regime
eve = df[(df.lhour.>=17).&(df.lhour.<=21),:]
println("=== EVENING (h17-21) n=",nrow(eve)," bias=",round(mean(eve.resid),digits=2)," MAE=",round(mean(abs.(eve.resid)),digits=2))
println("corr(resid, imp_GB)=",round(cor(eve.resid, coalesce.(eve.imp_GB,0.0)),digits=3),
        "  corr(resid, nettot)=",round(cor(eve.resid, eve.nettot),digits=3))
# bin evening by GB import
eve.gbbin = map(x-> x < -400 ? "NL->GB exp" : x>400 ? "GB->NL imp" : "neutral", coalesce.(eve.imp_GB,0.0))
for b in ["NL->GB exp","neutral","GB->NL imp"]; d=eve[eve.gbbin.==b,:]; isempty(d)&&continue
  @printf("  GBregime %-11s n=%5d bias=%7.2f MAE=%6.2f settled=%.1f meanImpGB=%.0f\n",b,nrow(d),mean(d.resid),mean(abs.(d.resid)),mean(d.settled),mean(coalesce.(d.imp_GB,0.0))); end
# bin evening by total net import (importing vs exporting overall)
eve.ntbin = map(x-> x<0 ? "NL exporting" : x>2000 ? "NL big-import" : "NL mod-import", eve.nettot)
for b in ["NL exporting","NL mod-import","NL big-import"]; d=eve[eve.ntbin.==b,:]; isempty(d)&&continue
  @printf("  NET %-13s n=%5d bias=%7.2f MAE=%6.2f settled=%.1f meanNet=%.0f\n",b,nrow(d),mean(d.resid),mean(abs.(d.resid)),mean(d.settled),mean(d.nettot)); end

# 2. Is evening under-pricing systemic? Compare NL vs DE_LU vs BE evening bias
dbh=DuckDB.DB(ENV["EX"];readonly=true); con=DBInterface.connect(dbh); q(s)=DataFrame(DBInterface.execute(con,s))
mcsv=joinpath(SP,"cv23_model.csv")
DBInterface.execute(con,"CREATE TEMP TABLE model AS SELECT bidding_zone zn,(CAST(h AS TIMESTAMPTZ) AT TIME ZONE 'UTC') utc,price_eur_mwh model FROM read_csv_auto('$mcsv',header=true)")
println("\n=== EVENING bias by zone (h18-20 local ~ h16-18 UTC summer/h17-19 winter; use UTC hour 17-19) ===")
for z in ["NL","DE_LU","BE","DK1","NO2"]
  d=q("""SELECT m.model, s.p settled FROM model m JOIN
     (SELECT date_trunc('hour',date_time_utc) utc, avg(price_currency_mwh) p FROM entsoe.energy_prices
      WHERE map_code='$z' AND contract_type='Day-ahead' AND currency='EUR' GROUP BY 1) s ON m.utc=s.utc
     WHERE m.zn='$z' AND extract(hour from m.utc) IN (17,18,19)""")
  isempty(d)&&continue
  @printf("  %-6s n=%5d corr=%.3f MAE=%6.2f bias=%7.2f settled=%.1f\n",z,nrow(d),cor(d.model,d.settled),mean(abs.(d.model.-d.settled)),mean(d.model.-d.settled),mean(d.settled)); end

# 3. midday negative/low price incidence (settled) vs model floor
mid=df[(df.lhour.>=11).&(df.lhour.<=15),:]
@printf("\n=== MIDDAY (h11-15) settled<0: %d/%d (%.1f%%)  model<0: %d  settled<20: %d model<20: %d\n",
  sum(mid.settled.<0),nrow(mid),100*mean(mid.settled.<0),sum(mid.model.<0),sum(mid.settled.<20),sum(mid.model.<20))
@printf("   midday bias=%.2f  when settled<20: model mean=%.1f settled mean=%.1f\n",mean(mid.resid),mean(mid.model[mid.settled.<20]),mean(mid.settled[mid.settled.<20]))
