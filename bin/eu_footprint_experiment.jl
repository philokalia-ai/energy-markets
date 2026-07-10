#!/usr/bin/env julia
# EU-wide footprint experiment runner.
#
# Runs multi-zone merit-order market clearing over a (near) Europe-wide
# footprint and saves prices under clearing_mode="multi_zone_eu" (code_version
# 10). Resumable per-day: days already present in the DB for that clearing_mode
# are skipped. Aggregate/sub-zone dedup: Italy via sub-zones (aggregate IT
# excluded), Denmark via DK1/DK2 (aggregate DK excluded), Germany via the DE_LU
# bidding zone (control-area DE_50HzT excluded).
#
# Env vars:
#   START_DATE, END_DATE  (YYYY-MM-DD)
#   FOOTPRINT             "full" (37 zones) or "core" (GR 2-ring fallback)
#   SAVE                  "true"/"false" (default true)
#   OPTIMIZER             "auto"/"gurobi"/"highs" (default auto)

using Euphemia, Dates

# --- Footprints -------------------------------------------------------------
# Full = task's 39 minus the two shadow aggregates DE_50HzT and DK.
const FULL_FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia",
]
# GR-centred 2-ring core (fallback if full is intractable). Makes GR's Italian
# and continental borders endogenous without the full European MILP.
const CORE_FOOTPRINT = String[
    "GR", "BG", "RO", "RS", "HU",
    "IT-SOUTH", "IT-CSOUTH", "IT-Calabria", "IT-Sicily", "IT-NORTH",
    "IT-CNORTH", "IT-Sardinia",
    "AT", "SI", "CZ", "SK", "PL", "DE_LU", "FR",
]

footprint_name = get(ENV, "FOOTPRINT", "full")
zones = footprint_name == "core" ? CORE_FOOTPRINT : FULL_FOOTPRINT
save_to_db = lowercase(get(ENV, "SAVE", "true")) == "true"
optimizer = get(ENV, "OPTIMIZER", "auto")
start_date = Date(get(ENV, "START_DATE", "2026-04-01"))
end_date = Date(get(ENV, "END_DATE", "2026-04-14"))

const CLEARING_MODE = "multi_zone_eu"

function already_done(day::Date)
    df = Euphemia.sql2df(
        """
        SELECT count(*) AS n FROM simulations.energy_prices
        WHERE clearing_mode = \$1 AND code_version = $(Euphemia.ENERGY_PRICES_CODE_VERSION)
          AND bidding_zone = 'GR'
          AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc <  ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
        """,
        [CLEARING_MODE, day])
    return df.n[1] >= 24
end

println("=" ^ 70)
println("EU FOOTPRINT EXPERIMENT  footprint=$footprint_name  zones=$(length(zones))")
println("  period=$start_date..$end_date  save=$save_to_db  optimizer=$optimizer")
println("  clearing_mode=$CLEARING_MODE  code_version=$(Euphemia.ENERGY_PRICES_CODE_VERSION)")
println("=" ^ 70)
flush(stdout)

for day in start_date:Day(1):end_date
    if save_to_db && already_done(day)
        println("\n⏭️  $day already saved for $CLEARING_MODE — skipping")
        flush(stdout)
        continue
    end
    println("\n" * "#" ^ 70)
    println("# DAY $day")
    println("#" ^ 70)
    flush(stdout)
    t0 = time()
    try
        # save_to_db=false: we save ONLY energy_prices ourselves below, under
        # clearing_mode="multi_zone_eu". This deliberately avoids the built-in
        # save path, which would also upsert simulations.transmission_flows and
        # optimization_runs on keys shared with the 5-zone SEE multi_zone
        # baseline (those tables have no clearing_mode discriminator), silently
        # corrupting the baseline. Only energy_prices is footprint-isolated.
        result = Euphemia.run_multi_zone_market_clearing(day;
            zones=zones,
            order_method=:merit_order,
            optimizer=optimizer,
            silent=true,
            save_to_db=false,
            clearing_mode=CLEARING_MODE)
        elapsed = time() - t0
        if save_to_db && (result.status == :optimal ||
                          (result.status == :time_limit && !isempty(result.market_prices)))
            nsaved = 0
            for zone in keys(result.market_prices)
                nsaved += Euphemia.save_energy_prices(result.market_prices[zone],
                    zone, day, :merit_order; clearing_mode=CLEARING_MODE)
            end
            println(">>> saved $nsaved price rows under $CLEARING_MODE")
        end
        println("\n>>> DAY $day DONE  status=$(result.status)  " *
                "solve=$(round(result.solve_time, digits=1))s  " *
                "wall=$(round(elapsed, digits=1))s  " *
                "nzones_priced=$(length(result.market_prices))")
        if haskey(result.market_prices, "GR")
            gp = collect(values(result.market_prices["GR"]))
            println(">>> GR mean=$(round(sum(gp)/length(gp), digits=2)) €/MWh")
        end
    catch e
        e isa InterruptException && rethrow()
        println("\n!!! DAY $day FAILED: $e")
    end
    flush(stdout)
end

println("\n✅ EXPERIMENT RUN COMPLETE")
