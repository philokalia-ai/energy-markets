# EU-coupled scenario exercises: the GR counterfactuals cleared on the FULL
# 39-zone EU footprint (order_method=:merit_order, enrich_network=true,
# passes=2), via the pipelined backfill with the scenario passthrough.
#
#   julia --project=. docs/experiments/scenario-exercises/eu_scenarios.jl
#
# Three labeled runs (all resumable per (day, clearing_mode); rerun to continue):
#   eu_scn_base      : no scenario,                    2024-07-01..2026-06-30
#   eu_scn_dc574     : GR load_modifier +574 MW,       2024-07-01..2026-06-30
#   eu_scn_ops_floor : GR extra_orders, FLOOR OPS MW,  2024-07-01..2025-06-30
#
# The dc574 window covers both exercise windows (2025-07..2026-06 and the
# OPS-comparable 2024-07..2025-06), so one run serves both comparisons.
#
# FLOW MODE: pinned to the cv16+ EU-footprint product default (:v2 fully
# ex-ante flows) EXPLICITLY, because the pipeline's book workers call
# mz_build_books directly and would otherwise fall back to the process-wide
# :d0. Explicit env is forwarded to the workers by run_pipelined_backfill.
#
# GUROBI: solver_workers=2 (WLS session cap). Results are saved by the single
# coordinator writer to data/results.duckdb (energy_prices only, under each
# label; optimization_runs/transmission_flows untouched — save_prices_only).

ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "v2")
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
const EXTRACT_PATH = get(ENV, "EUPHEMIA_DUCKDB_PATH",
    normpath(joinpath(@__DIR__, "..", "..", "..", "data", "extracts", "euphemia-live.duckdb")))
ENV["EUPHEMIA_DUCKDB_PATH"] = EXTRACT_PATH
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"

using Euphemia, Dates, CSV, DataFrames

configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT_PATH,
    read_only=true, results_writable=true)

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

# --- scenario 1: +574 MW always-on data center in GR -----------------------
const DC_MW = 574.0
dc_scenario = Dict("GR" => ZoneScenario(load_modifier=(ts, l) -> l + DC_MW))

# --- scenario 2: cold ironing, FLOOR profile (confirmed >5000 GT only) ------
const OPS_FLOOR_MW = let
    df = CSV.read(joinpath(@__DIR__, "ops_hourly_gr_floor_2024H2_2025H1.csv"), DataFrame)
    d = Dict{String,Float64}()
    for r in eachrow(df)
        dt = DateTime(string(r.datetime_utc)[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
        d[Dates.format(dt, "yyyymmdd-HH")] = Float64(r.ops_mw)
    end
    d
end

ops_orders = ctx -> begin
    orders = SimpleOrder[]
    for ts in ctx.timeslots
        mw = get(OPS_FLOOR_MW, ts[1:11], 0.0)
        mw > 0 && push!(orders, SimpleOrder(:demand, 3000.0, mw, Symbol(ctx.zone),
            DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes))
    end
    orders
end
ops_scenario = Dict("GR" => ZoneScenario(extra_orders=ops_orders))

# --- the three labeled runs -------------------------------------------------
RUNS = [
    ("eu_scn_base",      Date(2024, 7, 1):Day(1):Date(2026, 6, 30), nothing),
    ("eu_scn_dc574",     Date(2024, 7, 1):Day(1):Date(2026, 6, 30), dc_scenario),
    ("eu_scn_ops_floor", Date(2024, 7, 1):Day(1):Date(2025, 6, 30), ops_scenario),
]

for (label, days, scn) in RUNS
    println("\n" * "#"^70)
    println("# RUN $label  ($(first(days))..$(last(days)), $(length(days)) days)")
    println("#"^70)
    r = run_pipelined_backfill(collect(days), FOOTPRINT;
        solver_workers=2, optimizer="gurobi",
        clearing_mode=label, save_to_db=true, save_prices_only=true,
        resume=true, scenario=scn)
    println("[$label] processed=$(r.processed) saved=$(r.saved) " *
            "failed=$(r.failed) days/h=$(round(r.days_per_hour, digits=1))")
end
println("ALL EU RUNS DONE")
