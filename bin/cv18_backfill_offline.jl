#!/usr/bin/env julia
# cv18 full-year record, computed OFFLINE on the DuckDB extract (~230 days/h vs
# ~57 reading live Postgres — measured on this host) and saved to
# data/results.duckdb under clearing_mode='multi_zone_eu' at cv18;
# bin/cv18_transfer.py then moves the rows to Postgres in one shot.
# Extract↔Postgres parity is documented at ≤2e-12 €/MWh (test/scripts/
# eu_duckdb_parity.jl), so the record is equivalent to a live-Postgres compute.
#
#   START_DATE=2025-07-01 END_DATE=2026-06-30 julia --project=. bin/cv18_backfill_offline.jl
haskey(ENV, "GRB_LICENSE_FILE") ||
    (ENV["GRB_LICENSE_FILE"] = joinpath(homedir(), "gurobi.lic"))
ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "v2")
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
const EXTRACT = get(ENV, "EUPHEMIA_DUCKDB_PATH",
    normpath(joinpath(@__DIR__, "..", "data", "extracts", "euphemia-live.duckdb")))
ENV["EUPHEMIA_DUCKDB_PATH"] = EXTRACT
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"

using Euphemia, Dates
configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT, read_only=true,
    results_writable=true)

const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]

d0 = Date(get(ENV, "START_DATE", "2025-07-01"))
d1 = Date(get(ENV, "END_DATE", "2026-06-30"))
days = collect(d0:Day(1):d1)
println("cv18 OFFLINE BACKFILL $d0..$d1  cv=$(Euphemia.ENERGY_PRICES_CODE_VERSION)  " *
        "clearing_mode=multi_zone_eu -> results.duckdb")
r = run_pipelined_backfill(days, FOOTPRINT;
    solver_workers=2, optimizer="gurobi",
    clearing_mode="multi_zone_eu", save_to_db=true, save_prices_only=true,
    resume=true)
println("processed=$(r.processed) saved=$(r.saved) failed=$(r.failed) days/h=$(round(r.days_per_hour, digits=1))")
