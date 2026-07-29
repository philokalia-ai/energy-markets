# A/B screening harness for the bidirectional-ATC double-counting fix.
#
# Runs ONE market day of the 39-zone EU footprint in ONE arm and dumps the
# per-zone simulated prices, the settled day-ahead prices, and the cross-border
# flow totals to a JSON file. Arm selection is via EUPHEMIA_DISABLE_ATC_CANON
# in the process environment ("true" = pre-fix / main behaviour).
#
#   julia --project=. test/scripts/atc_canon_ab_day.jl <YYYY-MM-DD> <outfile.json>

using Euphemia
using Dates, JSON, Statistics

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

function settled_prices(day::Date)
    df = Euphemia.sql2df_with_retry(
        """
        SELECT map_code,
               to_char(date_time_utc AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MI') AS slot,
               price_currency_mwh
        FROM entsoe.energy_prices
        WHERE contract_type = 'Day-ahead'
          AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
          AND price_currency_mwh IS NOT NULL
        """, Any[day])
    out = Dict{String,Dict{String,Float64}}()
    for r in eachrow(df)
        z = get!(out, String(r.map_code), Dict{String,Float64}())
        z[String(r.slot)] = Float64(r.price_currency_mwh)
    end
    return out
end

day = Date(ARGS[1])
outfile = ARGS[2]
arm = lowercase(get(ENV, "EUPHEMIA_DISABLE_ATC_CANON", "")) == "true" ? "main" : "fixed"

t0 = time()
res = run_multi_zone_market_clearing(day;
    zones=FOOTPRINT, order_method=:merit_order, enrich_network=true,
    passes=2, save_to_db=false, optimizer="highs")
elapsed = time() - t0

act = settled_prices(day)

sim = Dict{String,Dict{String,Float64}}()
for (z, pd) in res.market_prices
    sim[z] = Dict{String,Float64}(string(k) => Float64(v) for (k, v) in pd)
end

# Total absolute cross-border flow over the day (MWh-equivalent at hourly slots)
function flow_totals(flows)
    total = 0.0
    by_border = Dict{String,Float64}()
    for (fid, pd) in flows
        s = sum(abs(v) for v in values(pd); init=0.0)
        total += s
        by_border[fid] = s
    end
    return total, by_border
end
flow_abs, flow_by_border = flow_totals(res.transmission_flows)

open(outfile, "w") do io
    JSON.print(io, Dict(
    "arm" => arm,
    "day" => string(day),
    "status" => string(res.status),
    "elapsed_s" => elapsed,
    "sim" => sim,
    "actual" => act,
    "flow_abs_total" => flow_abs,
    "flow_by_border" => flow_by_border,
    "flows" => Dict(String(k) => Dict(String(kk) => Float64(vv) for (kk, vv) in v)
                    for (k, v) in res.transmission_flows),
    "n_flow_ids" => length(res.transmission_flows),
    ))
end
println("WROTE $outfile  arm=$arm day=$day status=$(res.status) t=$(round(elapsed, digits=1))s")
