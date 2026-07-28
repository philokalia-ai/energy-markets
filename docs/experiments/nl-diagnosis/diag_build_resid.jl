using DuckDB, DataFrames, CSV, Statistics
SP = ENV["SP"]
dbh = DuckDB.DB(ENV["EX"]; readonly=true)
con = DBInterface.connect(dbh)
q(s) = DataFrame(DBInterface.execute(con, s))
ex(s) = DBInterface.execute(con, s)

# Load model CSV (all zones), cast h -> UTC naive timestamp
modelcsv = joinpath(SP, "cv23_model.csv")
ex("""CREATE TEMP TABLE model AS
  SELECT bidding_zone AS zone,
         (CAST(h AS TIMESTAMPTZ) AT TIME ZONE 'UTC') AS utc,
         price_eur_mwh AS model
  FROM read_csv_auto('$modelcsv', header=true)""")

# settled NL hourly (aggregate PT15M->hourly by mean)
ex("""CREATE TEMP TABLE settled AS
  SELECT date_trunc('hour', date_time_utc) AS utc, avg(price_currency_mwh) AS settled
  FROM entsoe.energy_prices
  WHERE map_code='NL' AND contract_type='Day-ahead' AND currency='EUR'
  GROUP BY 1""")

# NL net import per border, hourly mean MW. import_from_X = flow(X->NL) - flow(NL->X)
function border(code)
  ex("""CREATE TEMP TABLE imp_$code AS
    WITH inflow AS (SELECT date_trunc('hour',date_time_utc) utc, avg(flow_mw) f
                    FROM entsoe.physical_flows WHERE out_area_map_code='$code' AND in_area_map_code='NL' GROUP BY 1),
         outflow AS (SELECT date_trunc('hour',date_time_utc) utc, avg(flow_mw) f
                    FROM entsoe.physical_flows WHERE out_area_map_code='NL' AND in_area_map_code='$code' GROUP BY 1)
    SELECT coalesce(inflow.utc,outflow.utc) utc,
           coalesce(inflow.f,0)-coalesce(outflow.f,0) AS imp_$code
    FROM inflow FULL OUTER JOIN outflow ON inflow.utc=outflow.utc""")
end
for c in ["GB","NO2","DK1","BE","DE_LU"]; border(c); end

df = q("""
  SELECT m.utc, m.model, s.settled,
         ig.imp_GB, ino.imp_NO2, idk.imp_DK1, ibe.imp_BE, ide.imp_DE_LU
  FROM model m
  JOIN settled s ON m.utc=s.utc
  LEFT JOIN imp_GB ig ON m.utc=ig.utc
  LEFT JOIN imp_NO2 ino ON m.utc=ino.utc
  LEFT JOIN imp_DK1 idk ON m.utc=idk.utc
  LEFT JOIN imp_BE ibe ON m.utc=ibe.utc
  LEFT JOIN imp_DE_LU ide ON m.utc=ide.utc
  WHERE m.zone='NL'
  ORDER BY m.utc""")
CSV.write(joinpath(SP,"nl_resid.csv"), df)
println("rows=", nrow(df), "  utc range ", minimum(df.utc), " .. ", maximum(df.utc))
c = cor(df.model, df.settled)
println("overall corr=", round(c,digits=4), "  MAE=", round(mean(abs.(df.model .- df.settled)),digits=3),
        "  bias(model-settled)=", round(mean(df.model .- df.settled),digits=3))
