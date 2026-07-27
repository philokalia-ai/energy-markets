ENV["EUPHEMIA_DATA_STORE"]="duckdb"; ENV["EUPHEMIA_DUCKDB_PATH"]="data/extracts/frcap.duckdb"
using Euphemia, Dates, Statistics, DuckDB, DataFrames
M=Euphemia.MeritOrderBook
con=DBInterface.connect(DuckDB.DB(ENV["EUPHEMIA_DUCKDB_PATH"]; readonly=true))
realFR(day)=let df=DataFrame(DBInterface.execute(con,"SELECT AVG(price_currency_mwh) p FROM entsoe.energy_prices WHERE contract_type='Day-ahead' AND map_code='FR' AND DATE(date_time_utc)='$day' AND EXTRACT(HOUR FROM date_time_utc) BETWEEN 17 AND 20")); (isempty(df)||ismissing(df.p[1])) ? NaN : Float64(df.p[1]); end
# On each clean 2023 day: gas SRMC, backstop price (1.8xgas), realistic ref (use realized evening),
# ceiling (1.3xref). Does the fix bite? (bite if backstopPrice < realizedEve or ceiling < realizedEve)
for day in [Date(2023,6,13),Date(2023,7,11),Date(2023,7,25),Date(2023,8,8),Date(2023,3,14),Date(2023,4,18),Date(2023,1,10)]
  gas=M.get_marginal_cost(day,"Fossil Gas","FR"); bsp=1.8*gas
  reve=realFR(day); ceil13=1.3*reve
  bite = (bsp < reve) || (ceil13 < reve)
  println("$day: gas=$(round(gas,digits=0)) backstopP=$(round(bsp,digits=0)) realizedEveFR=$(round(reve,digits=0)) ceiling(1.3xrealized)=$(round(ceil13,digits=0)) -> fix_bites_below_realized=$bite")
end
