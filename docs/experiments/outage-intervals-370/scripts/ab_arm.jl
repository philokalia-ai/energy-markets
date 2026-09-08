# One A/B arm of the #370 paired measurement: 52 Wednesdays, 39-zone EU
# footprint, pipelined runner, Gurobi. Usage:
#   EUPHEMIA_DISABLE_OUTAGE_INTERVALS=1 CLEARING_MODE=ab370_legacy    julia --project=. ab_arm.jl
#                                       CLEARING_MODE=ab370_intervals julia --project=. ab_arm.jl
# Results land in simulations.energy_prices under the arm's clearing_mode
# (scenario-labelled; the record is untouched).
using Euphemia, Dates, Distributed
const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia"]
label = ENV["CLEARING_MODE"]
days = collect(Date(2025, 9, 3):Day(7):Date(2026, 8, 26))   # 52 Wednesdays
@assert length(days) == 52
println("ARM $label  intervals_enabled=", isempty(get(ENV, "EUPHEMIA_DISABLE_OUTAGE_INTERVALS", "")),
        "  days=", length(days), "  ", first(days), "..", last(days)); flush(stdout)
res = Euphemia.run_pipelined_backfill(days, FOOTPRINT;
    solver_workers=2, book_workers=6, in_flight=6, optimizer="gurobi",
    clearing_mode=label, save_to_db=true, resume=true)
println("ARM $label DONE  days/h=", res.days_per_hour); flush(stdout)
