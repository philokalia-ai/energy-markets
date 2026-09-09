# One A/B arm of the #366 paired measurement (spill gate): 52 Wednesdays, 39-zone EU
# footprint, pipelined runner, Gurobi. Usage:
#   CLEARING_MODE=ab366_base    julia --project=. ab_arm.jl
#                                       EUPHEMIA_SPILL_GATE=0.95 CLEARING_MODE=ab366_spill julia --project=. ab_arm.jl
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
days = collect(Date(2024, 9, 4):Day(14):Date(2026, 8, 19))   # 52 even-ISO-week Wednesdays, 2 years (seasonal regimes)
@assert length(days) == 52
println("ARM $label  spill_gate=", get(ENV, "EUPHEMIA_SPILL_GATE", "off"),
        "  days=", length(days), "  ", first(days), "..", last(days)); flush(stdout)
res = Euphemia.run_pipelined_backfill(days, FOOTPRINT;
    solver_workers=2, book_workers=6, in_flight=6, optimizer="gurobi",
    clearing_mode=label, save_to_db=true, resume=true)
println("ARM $label DONE  days/h=", res.days_per_hour); flush(stdout)
