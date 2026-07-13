#!/usr/bin/env julia
# scenario_delta.jl — run queries/load_weighted_price_delta.sql offline.
#
# Compares two scenario runs stored in the results DB (load-weighted average
# price of each, the delta in EUR/MWh, and the window + annualized extra cost),
# weighted by the model's own demand series (the day-ahead load forecast in the
# source extract). See the header of queries/load_weighted_price_delta.sql.
#
# Usage:
#   julia --project=. bin/scenario_delta.jl <baseline_label> <scenario_label> \
#       <zone> <start_date> <end_date_exclusive> [extract.duckdb] [results.duckdb]
#
#   julia --project=. bin/scenario_delta.jl gr_scn_base gr_scn_dc574 GR 2025-07-01 2026-07-01
#   julia --project=. bin/scenario_delta.jl gr_scn_base gr_scn_ops   GR 2024-07-01 2025-07-01
#
# Defaults: extract = $EUPHEMIA_DUCKDB_PATH or data/extracts/euphemia-live.duckdb,
#           results = $EUPHEMIA_RESULTS_DB  or data/results.duckdb.
# Both files are opened READ_ONLY; safe to run while a backfill is writing.

using DuckDB, DataFrames
const DBInterface = DuckDB.DBInterface

function main(args)
    length(args) >= 5 || begin
        println("usage: scenario_delta.jl <baseline_label> <scenario_label> <zone> " *
                "<start_date> <end_date_exclusive> [extract.duckdb] [results.duckdb]")
        exit(1)
    end
    base_label, scn_label, zone, d_from, d_to = args[1:5]
    root = normpath(joinpath(@__DIR__, ".."))
    extract = length(args) >= 6 ? args[6] :
              get(ENV, "EUPHEMIA_DUCKDB_PATH", joinpath(root, "data", "extracts", "euphemia-live.duckdb"))
    results = length(args) >= 7 ? args[7] :
              get(ENV, "EUPHEMIA_RESULTS_DB", joinpath(root, "data", "results.duckdb"))
    isfile(extract) || error("extract not found: $extract")
    isfile(results) || error("results DB not found: $results")

    sql = read(joinpath(root, "queries", "load_weighted_price_delta.sql"), String)

    con = DBInterface.connect(DuckDB.DB, ":memory:")
    DBInterface.execute(con, "ATTACH '$(extract)' AS src (READ_ONLY)")
    DBInterface.execute(con, "ATTACH '$(results)' AS results_db (READ_ONLY)")

    df = DataFrame(DBInterface.execute(con, sql,
        Any[zone, base_label, scn_label, d_from, d_to]))
    println("\nΔ = $scn_label − $base_label, zone $zone, window [$d_from, $d_to)")
    println("weights: hourly avg of entsoe.day_ahead_total_load_forecast (baseline load)\n")
    show(df; allrows=true, allcols=true, show_row_number=false, eltypes=false)
    println()
    DBInterface.close!(con)
    return df
end

main(ARGS)
