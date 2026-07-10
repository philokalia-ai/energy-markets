#!/usr/bin/env julia
# EU-wide footprint CALIBRATION runner (issue #90, PR calibrate/eu-footprint).
#
# Same Europe-wide merit-order clearing as bin/eu_footprint_experiment.jl, but
# with the Phase-1 network fix (enrich_network=true: explicit-ATC union +
# aggregate→sub-zone remap + CH node) and the Phase-2/3 per-zone ZoneProfile
# calibration (apply_zone_profiles). Saves energy_prices under a DISTINCT
# clearing_mode so the frozen PR #91 baseline (clearing_mode='multi_zone_eu')
# is never overwritten.
#
# Env vars:
#   START_DATE, END_DATE   (YYYY-MM-DD; default 2026-04-01 .. 2026-04-05)
#   CLEARING_MODE          save key (default 'multi_zone_eu_cal')
#   APPLY_PROFILES         'true' (Phase 1+2+3) or 'false' (Phase-1-only ablation)
#   SAVE                   'true'/'false' (default true)
#   OPTIMIZER              'auto'/'gurobi'/'highs' (default auto)

using Euphemia, Dates, Statistics

# Full footprint = PR #91's 38 zones + Switzerland (now an endogenous node).
const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

start_date = Date(get(ENV, "START_DATE", "2026-04-01"))
end_date = Date(get(ENV, "END_DATE", "2026-04-05"))
save_to_db = lowercase(get(ENV, "SAVE", "true")) == "true"
optimizer = get(ENV, "OPTIMIZER", "auto")
apply_profiles = lowercase(get(ENV, "APPLY_PROFILES", "true")) == "true"
passes = parse(Int, get(ENV, "PASSES", "1"))
const CLEARING_MODE = get(ENV, "CLEARING_MODE", "multi_zone_eu_cal")

println("=" ^ 70)
println("EU CALIBRATION RUN  zones=$(length(FOOTPRINT))  period=$start_date..$end_date")
println("  clearing_mode=$CLEARING_MODE  apply_profiles=$apply_profiles  passes=$passes  save=$save_to_db")
println("  code_version=$(Euphemia.ENERGY_PRICES_CODE_VERSION)  optimizer=$optimizer")
println("=" ^ 70)
flush(stdout)

for day in start_date:Day(1):end_date
    println("\n" * "#" ^ 70 * "\n# DAY $day\n" * "#" ^ 70)
    flush(stdout)
    t0 = time()
    try
        # save_to_db=false: we save ONLY energy_prices ourselves below, under the
        # distinct CLEARING_MODE, mirroring eu_footprint_experiment.jl. This
        # avoids the built-in save path upserting transmission_flows /
        # optimization_runs on keys shared with the SEE baseline.
        result = Euphemia.run_multi_zone_market_clearing(day;
            zones=FOOTPRINT,
            order_method=:merit_order,
            optimizer=optimizer,
            silent=true,
            save_to_db=false,
            clearing_mode=CLEARING_MODE,
            enrich_network=true,
            apply_zone_profiles=apply_profiles,
            passes=passes)
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
        println(">>> DAY $day DONE  status=$(result.status)  " *
                "solve=$(round(result.solve_time, digits=1))s  " *
                "wall=$(round(elapsed, digits=1))s  nzones=$(length(result.market_prices))")
        for z in ("GR", "IT-SOUTH", "IT-NORTH", "DE_LU", "NO1", "CH")
            haskey(result.market_prices, z) || continue
            p = collect(values(result.market_prices[z]))
            println("      $z mean=$(round(mean(p), digits=1)) €/MWh")
        end
    catch e
        e isa InterruptException && rethrow()
        println("!!! DAY $day FAILED: $e")
    end
    flush(stdout)
end
println("\n✅ EU CALIBRATION RUN COMPLETE ($CLEARING_MODE)")
