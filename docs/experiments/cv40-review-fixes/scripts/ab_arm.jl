# One A/B arm of the #cv40 paired measurement (review 2026-09-13 implementation defects)
# footprint, pipelined runner, Gurobi. Usage:
#   EUPHEMIA_DISABLE_OUTAGE_INTERVALS=1 CLEARING_MODE=ab40_base    julia --project=. ab_arm.jl
#                                       CLEARING_MODE=ab40_fixes julia --project=. ab_arm.jl
# Results land in simulations.energy_prices under the arm's clearing_mode
# (scenario-labelled; the record is untouched).
using Euphemia, Dates, Distributed
const FOOTPRINT = String[   # the canonical 39-zone record footprint (bin/reproduce.jl) — CH included
    "AT", "BE", "BG", "CH", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia"]
@assert length(FOOTPRINT) == 39 && "CH" in FOOTPRINT
label = ENV["CLEARING_MODE"]
days = collect(Date(2025, 9, 3):Day(7):Date(2026, 8, 26))   # 52 Wednesdays
@assert length(days) == 52
println("ARM $label  de_hub=", isempty(get(ENV, "EUPHEMIA_DISABLE_CV40_DEHUB", "")),
        "  days=", length(days), "  ", first(days), "..", last(days)); flush(stdout)
res = Euphemia.run_pipelined_backfill(days, FOOTPRINT;
    solver_workers=2, book_workers=6, in_flight=6, optimizer="gurobi",
    clearing_mode=label, save_to_db=true, resume=true)
println("ARM $label DONE  days/h=", res.days_per_hour); flush(stdout)
