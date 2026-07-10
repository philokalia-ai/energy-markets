#!/usr/bin/env julia
# Diagnostic: how much of GR's supply is met by ENDOGENOUS cross-border imports
# in the EU footprint, vs the OBSERVED-net-import baseline (SEE / single-zone).
using Euphemia, Dates, Statistics

day = Date(get(ENV, "DAY", "2026-04-08"))
zones = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2",
    "SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH",
    "IT-Calabria","IT-Sicily","IT-Sardinia"]

res = Euphemia.run_multi_zone_market_clearing(day; zones=zones,
    order_method=:merit_order, optimizer="auto", silent=true, save_to_db=false,
    clearing_mode="multi_zone_eu")

# Net endogenous import into GR per hour = sum over flows of (into GR) - (out of GR)
gr_endo = Dict{Int,Float64}()
for (fid, per) in res.transmission_flows
    parts = split(fid, "_to_")
    length(parts) == 2 || continue
    src, dst = parts
    (src == "GR" || dst == "GR") || continue
    for (p, mw) in per
        h = length(p) >= 13 ? Dates.hour(DateTime(p, dateformat"yyyymmdd-HHMM")) : parse(Int, p) - 1
        gr_endo[h] = get(gr_endo, h, 0.0) + (dst == "GR" ? mw : -mw)
    end
end

# Observed net imports baseline (what SEE/single-zone would inject over the same
# borders that are now endogenous — i.e. GR's ATC-linked in-footprint borders).
obs_all = Euphemia.MeritOrderBook.get_net_imports("GR", day)  # all BZN borders
mean_endo = isempty(gr_endo) ? 0.0 : mean(values(gr_endo))
mean_obs  = isempty(obs_all) ? 0.0 : mean(values(obs_all))

# GR load for the day (approx, from the merit path's demand) — use realised load
ld = Euphemia.sql2df("""
    SELECT avg(v) FROM (
      SELECT date_time_utc, sum(total_load_mw) v FROM entsoe.day_ahead_total_load_forecast
      WHERE area_map_code='GR' AND area_type_code LIKE 'BZN%'
        AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
        AND date_time_utc <  ((\$1::date+1)::timestamp AT TIME ZONE 'UTC')
      GROUP BY date_time_utc) t
    """, [day])
gr_load = (isempty(ld) || ismissing(ld[1,1])) ? NaN : Float64(ld[1,1])

println("\n================ GR IMPORT DIAGNOSTIC  $day ================")
println("GR mean ENDOGENOUS net import (EU footprint): $(round(mean_endo, digits=1)) MW")
println("GR mean OBSERVED  net import (physical_flows): $(round(mean_obs, digits=1)) MW")
println("GR mean load (day-ahead forecast):            $(round(gr_load, digits=1)) MW")
if isfinite(gr_load) && gr_load > 0
    println("Endogenous imports as % of GR load: $(round(100*mean_endo/gr_load, digits=1))%")
    println("Observed  imports as % of GR load: $(round(100*mean_obs/gr_load, digits=1))%")
end
println("GR mean price (EU): $(round(mean(values(res.market_prices["GR"])), digits=1)) €/MWh")
println("IT-SOUTH mean price (EU): $(round(mean(values(res.market_prices["IT-SOUTH"])), digits=1)) €/MWh")
