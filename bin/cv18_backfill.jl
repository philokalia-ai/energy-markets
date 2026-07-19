#!/usr/bin/env julia
# cv18 production backfill: full-year 39-zone multi_zone_eu record to POSTGRES.
#
#   START_DATE=2025-07-01 END_DATE=2026-06-30 julia --project=. bin/cv18_backfill.jl
#
# Uses the pipelined backfill (2 Gurobi solver workers = WLS session budget,
# book workers ahead of the solvers), resume=true so a restart skips saved
# days, and saves ONLY energy_prices under clearing_mode='multi_zone_eu' at
# ENERGY_PRICES_CODE_VERSION (mirrors the cv16 record produced via
# bin/eu_calibration_run.jl PIPELINE=true).
haskey(ENV, "GRB_LICENSE_FILE") ||
    (ENV["GRB_LICENSE_FILE"] = joinpath(homedir(), "gurobi.lic"))

using Euphemia, Dates

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

start_date = Date(get(ENV, "START_DATE", "2025-07-01"))
end_date = Date(get(ENV, "END_DATE", "2026-06-30"))
solver_workers = parse(Int, get(ENV, "SOLVER_WORKERS", "2"))
book_workers = parse(Int, get(ENV, "BOOK_WORKERS", "0"))
bw = book_workers <= 0 ? min(10, max(1, Sys.CPU_THREADS ÷ 8)) : book_workers
clearing_mode = get(ENV, "CLEARING_MODE", "multi_zone_eu")

println("cv18 BACKFILL $start_date..$end_date  cv=$(Euphemia.ENERGY_PRICES_CODE_VERSION)  " *
        "clearing_mode=$clearing_mode  solver_workers=$solver_workers  book_workers=$bw")
flush(stdout)

result = Euphemia.run_pipelined_backfill(
    collect(start_date:Day(1):end_date), FOOTPRINT;
    solver_workers=solver_workers, book_workers=bw,
    optimizer="gurobi", clearing_mode=clearing_mode,
    enrich_network=true, apply_zone_profiles=true,
    save_to_db=true, save_prices_only=true, resume=true)

println("\nBACKFILL COMPLETE: processed=$(result.processed) saved=$(result.saved) " *
        "failed=$(result.failed) days/hour=$(round(result.days_per_hour, digits=1)) " *
        "solver_util=$(result.solver_utilization)")
