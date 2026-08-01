#!/usr/bin/env julia
# transfer_results_to_postgres.jl — copy market results from the local
# offline results DuckDB (data/results.duckdb; the writable file the pipelined
# backfill persists to under the DuckDB extract backend) into the LIVE Postgres
# `simulations.*` tables.
#
# This is step 2 of the cv23 backfill flow (native DuckDB backfill → TRANSFER →
# extract rebuild → books retention; see docs/backfill-architecture.md). The
# backfill runs offline against the read-only extract and writes energy_prices /
# optimization_runs / transmission_flows into `data/results.duckdb`; this script
# lifts a (clearing_mode, code_version) slice of those into Postgres, preserving
# the optimization_runs linkage (run rows are upserted first, then each price
# row's optimization_run_id is remapped to the new Postgres id).
#
# It is idempotent + resumable at the scope level: the destination slice is
# delete-then-insert (same semantics as the normal save path), so a re-run
# replaces the slice wholesale — an interrupted transfer is fixed by re-running.
# Bulk inserts use Postgres COPY (streamed) so a full ~1.2M-row year transfers in
# minutes.
#
# USAGE
#   # transfer the default slice (multi_zone_eu / current cv) from data/results.duckdb
#   julia --project=. bin/transfer_results_to_postgres.jl
#
#   # explicit slice + source + date window
#   RESULTS_DUCKDB=data/results.duckdb \
#     julia --project=. bin/transfer_results_to_postgres.jl \
#       --clearing-mode multi_zone_eu --code-version 23 \
#       --start 2023-01-01 --end 2026-07-24
#
#   # verify only (no writes): per-year row counts + per zone-month price
#   # checksums on both sides
#   julia --project=. bin/transfer_results_to_postgres.jl --verify
#
# ENV
#   ENERGY_CONN_STR  live Postgres connection string (from .env; never printed)
#   RESULTS_DUCKDB   source results DuckDB (default data/results.duckdb, or the
#                    --results-db flag)

using Euphemia            # loads .env (ENERGY_CONN_STR) and the Postgres writers
using DuckDB, DataFrames, LibPQ, Dates, Printf

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
function parse_cli(argv)
    o = Dict{String,Any}(
        "clearing_mode" => "multi_zone_eu",
        "code_version"  => Euphemia.ENERGY_PRICES_CODE_VERSION,
        "results_db"    => get(ENV, "RESULTS_DUCKDB", "data/results.duckdb"),
        "start"         => nothing,
        "end"           => nothing,
        "verify"        => false,
        "flows"         => true,
    )
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--clearing-mode";  o["clearing_mode"] = argv[i+1]; i += 1
        elseif a == "--code-version"; o["code_version"] = parse(Int, argv[i+1]); i += 1
        elseif a == "--results-db";  o["results_db"]  = argv[i+1]; i += 1
        elseif a == "--start";       o["start"] = Date(argv[i+1]); i += 1
        elseif a == "--end";         o["end"]   = Date(argv[i+1]); i += 1
        elseif a == "--verify";      o["verify"] = true
        elseif a == "--no-flows";    o["flows"] = false
        elseif a in ("-h", "--help")
            println("See header of $(basename(@__FILE__)) for usage."); exit(0)
        else
            error("unknown arg: $a")
        end
        i += 1
    end
    return o
end

# ---------------------------------------------------------------------------
# DuckDB source read
# ---------------------------------------------------------------------------
function open_results_duckdb(path::AbstractString)
    isfile(path) || error("results DuckDB not found: $path")
    db = DuckDB.DB(path; readonly=true)
    return DBInterface.connect(db), db
end

# Half-open [start, end+1) day predicate (or "TRUE" when unbounded), plus params.
function day_window_clause(col::AbstractString, start, stop, p0::Int)
    start === nothing && stop === nothing && return ("TRUE", Any[])
    parts = String[]; params = Any[]; n = p0
    if start !== nothing
        push!(parts, "$col >= \$$(n)"); push!(params, start); n += 1
    end
    if stop !== nothing
        push!(parts, "$col < \$$(n)"); push!(params, stop + Day(1)); n += 1
    end
    return (join(parts, " AND "), params)
end

function read_prices(con, o)
    win, wp = day_window_clause("date_time_utc", o["start"], o["end"], 3)
    sql = """
        SELECT date_time_utc, resolution_code, bidding_zone, contract_type,
               price_eur_mwh, currency, order_method, clearing_mode,
               optimization_run_id, code_version, update_time_utc
        FROM simulations.energy_prices
        WHERE clearing_mode = \$1 AND code_version = \$2 AND $win
        ORDER BY bidding_zone, date_time_utc
    """
    return DataFrame(DBInterface.execute(con,
        sql, Any[o["clearing_mode"], o["code_version"], wp...]))
end

function read_runs(con, run_ids::Vector{<:Integer})
    isempty(run_ids) && return DataFrame()
    # DuckDB list-membership: bind the ids as a list parameter.
    sql = """
        SELECT id, bidding_zone, optimization_date, order_method, model_type,
               optimizer, status, objective_value, solve_time_seconds, num_orders,
               num_price_periods, error_message, code_version, created_at,
               is_iterative, total_time_seconds, iterations, converged,
               final_price_change, final_flow_change_pct
        FROM simulations.optimization_runs
        WHERE id IN (SELECT unnest(\$1))
    """
    return DataFrame(DBInterface.execute(con, sql, Any[collect(Int64, run_ids)]))
end

function read_flows(con, o)
    win, wp = day_window_clause("date_time_utc", o["start"], o["end"], 2)
    sql = """
        SELECT date_time_utc, source_zone, sink_zone, flow_mw, code_version,
               update_time_utc
        FROM simulations.transmission_flows
        WHERE code_version = \$1 AND $win
        ORDER BY source_zone, sink_zone, date_time_utc
    """
    return DataFrame(DBInterface.execute(con, sql, Any[o["code_version"], wp...]))
end

# ---------------------------------------------------------------------------
# CSV helpers for Postgres COPY
# ---------------------------------------------------------------------------
_csv(x::Missing) = ""
_csv(::Nothing)  = ""
_csv(x::DateTime) = Dates.format(x, "yyyy-mm-dd HH:MM:SS")
_csv(x::Date)     = Dates.format(x, "yyyy-mm-dd")
_csv(x::Bool)     = x ? "t" : "f"
_csv(x::Real)     = string(x)
function _csv(x::AbstractString)
    s = String(x)
    (occursin(',', s) || occursin('"', s) || occursin('\n', s)) &&
        return "\"" * replace(s, "\"" => "\"\"") * "\""
    return s
end
_csvline(vals) = join(_csv.(vals), ",") * "\n"

# ---------------------------------------------------------------------------
# Postgres upserts
# ---------------------------------------------------------------------------
"""Upsert optimization_runs one row at a time, returning duckdb_id → pg_id."""
function transfer_runs!(pg, runs::DataFrame)
    idmap = Dict{Int64,Int}()
    isempty(runs) && return idmap
    sql = """
        INSERT INTO simulations.optimization_runs
        (bidding_zone, optimization_date, order_method, model_type, optimizer, status,
         objective_value, solve_time_seconds, num_orders, num_price_periods, error_message,
         code_version, created_at,
         is_iterative, total_time_seconds, iterations, converged, final_price_change, final_flow_change_pct)
        VALUES (\$1,\$2,\$3,\$4,\$5,\$6,\$7,\$8,\$9,\$10,\$11,\$12,\$13,\$14,\$15,\$16,\$17,\$18,\$19)
        ON CONFLICT (bidding_zone, optimization_date, order_method, model_type, code_version, optimizer)
        DO UPDATE SET status = EXCLUDED.status, objective_value = EXCLUDED.objective_value,
            solve_time_seconds = EXCLUDED.solve_time_seconds, num_orders = EXCLUDED.num_orders,
            num_price_periods = EXCLUDED.num_price_periods, error_message = EXCLUDED.error_message,
            created_at = EXCLUDED.created_at, is_iterative = EXCLUDED.is_iterative,
            total_time_seconds = EXCLUDED.total_time_seconds, iterations = EXCLUDED.iterations,
            converged = EXCLUDED.converged, final_price_change = EXCLUDED.final_price_change,
            final_flow_change_pct = EXCLUDED.final_flow_change_pct
        RETURNING id
    """
    m(x) = (x === missing || x === nothing) ? missing : x
    LibPQ.execute(pg, "BEGIN")
    try
        for row in eachrow(runs)
            res = LibPQ.execute(pg, sql, [
                row.bidding_zone, row.optimization_date, row.order_method, row.model_type,
                row.optimizer, row.status, m(row.objective_value), m(row.solve_time_seconds),
                m(row.num_orders), m(row.num_price_periods), m(row.error_message),
                row.code_version, m(row.created_at), m(row.is_iterative),
                m(row.total_time_seconds), m(row.iterations), m(row.converged),
                m(row.final_price_change), m(row.final_flow_change_pct)])
            idmap[Int64(row.id)] = DataFrame(res).id[1]
        end
        LibPQ.execute(pg, "COMMIT")
    catch e
        LibPQ.execute(pg, "ROLLBACK"); rethrow(e)
    end
    return idmap
end

"""Delete-then-COPY the price slice into Postgres (with remapped run ids)."""
function transfer_prices!(pg, prices::DataFrame, idmap::Dict{Int64,Int}, o)
    win, wp = day_window_clause("date_time_utc", o["start"], o["end"], 3)
    LibPQ.execute(pg, "BEGIN")
    try
        LibPQ.execute(pg, """
            DELETE FROM simulations.energy_prices
            WHERE clearing_mode = \$1 AND code_version = \$2 AND $win
            """, Any[o["clearing_mode"], o["code_version"], wp...])

        remap(x) = (x === missing || x === nothing) ? missing : get(idmap, Int64(x), missing)
        lines = (_csvline((
            row.date_time_utc, row.resolution_code, row.bidding_zone, row.contract_type,
            row.price_eur_mwh, row.currency, row.order_method, row.clearing_mode,
            remap(row.optimization_run_id), row.code_version, row.update_time_utc))
            for row in eachrow(prices))
        copy = LibPQ.CopyIn("""
            COPY simulations.energy_prices
            (date_time_utc, resolution_code, bidding_zone, contract_type, price_eur_mwh,
             currency, order_method, clearing_mode, optimization_run_id, code_version, update_time_utc)
            FROM STDIN (FORMAT csv, NULL '')
            """, lines)
        LibPQ.execute(pg, copy)
        LibPQ.execute(pg, "COMMIT")
    catch e
        LibPQ.execute(pg, "ROLLBACK"); rethrow(e)
    end
    return nrow(prices)
end

"""
Delete-then-COPY the transmission-flow slice into Postgres.

CAUTION — this delete is WIDER than the price delete. `simulations.energy_prices`
is scoped by `clearing_mode`, but `simulations.transmission_flows` has no such
column, so the delete can only key on `(code_version, window)`. Transferring the
`multi_zone_eu` slice therefore also removes any flow rows in that window at the
same code_version that came from a DIFFERENT clearing mode (single-zone, the SEE
5-zone run, iterative) and were written straight to live Postgres. The asymmetry
is easy to miss because the price side IS mode-scoped.
"""
function transfer_flows!(pg, flows::DataFrame, o)
    isempty(flows) && return 0
    @warn "transmission_flows delete is NOT clearing-mode scoped (the table has no " *
          "such column): every flow row at code_version $(o["code_version"]) in this " *
          "window is replaced, including rows from other clearing modes"
    win, wp = day_window_clause("date_time_utc", o["start"], o["end"], 2)
    LibPQ.execute(pg, "BEGIN")
    try
        LibPQ.execute(pg, """
            DELETE FROM simulations.transmission_flows
            WHERE code_version = \$1 AND $win
            """, Any[o["code_version"], wp...])
        lines = (_csvline((row.date_time_utc, row.source_zone, row.sink_zone,
                           row.flow_mw, row.code_version, row.update_time_utc))
                 for row in eachrow(flows))
        copy = LibPQ.CopyIn("""
            COPY simulations.transmission_flows
            (date_time_utc, source_zone, sink_zone, flow_mw, code_version, update_time_utc)
            FROM STDIN (FORMAT csv, NULL '')
            """, lines)
        LibPQ.execute(pg, copy)
        LibPQ.execute(pg, "COMMIT")
    catch e
        LibPQ.execute(pg, "ROLLBACK"); rethrow(e)
    end
    return nrow(flows)
end

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
function per_year_counts_duckdb(con, o)
    win, wp = day_window_clause("date_time_utc", o["start"], o["end"], 3)
    DataFrame(DBInterface.execute(con, """
        SELECT EXTRACT(YEAR FROM date_time_utc) AS y, COUNT(*) AS n
        FROM simulations.energy_prices
        WHERE clearing_mode = \$1 AND code_version = \$2 AND $win
        GROUP BY 1 ORDER BY 1
        """, Any[o["clearing_mode"], o["code_version"], wp...]))
end

function per_year_counts_pg(pg, o)
    win, wp = day_window_clause("date_time_utc", o["start"], o["end"], 3)
    DataFrame(LibPQ.execute(pg, """
        SELECT EXTRACT(YEAR FROM date_time_utc)::int AS y, COUNT(*) AS n
        FROM simulations.energy_prices
        WHERE clearing_mode = \$1 AND code_version = \$2 AND $win
        GROUP BY 1 ORDER BY 1
        """, Any[o["clearing_mode"], o["code_version"], wp...]))
end

# Per zone-month price-sum checksums (rounded) — a strong content fingerprint.
# The Postgres column is NUMERIC(10,2), so every stored price is quantized to
# 2 decimals; the DuckDB side keeps full float64. Rounding PER ROW before the
# SUM makes the two fingerprints like-for-like — summing full-precision values
# and rounding once at the end flags spurious cent-level DIFFs whenever a
# month's sub-cent residues fail to cancel (seen on the cv31 transfer:
# 3/1677 Baltic zone-months, max per-row effect 0.005 €/MWh, all rows present).
function checksums_duckdb(con, o)
    win, wp = day_window_clause("date_time_utc", o["start"], o["end"], 3)
    DataFrame(DBInterface.execute(con, """
        SELECT bidding_zone AS z, strftime(date_time_utc, '%Y-%m') AS ym,
               ROUND(SUM(ROUND(price_eur_mwh, 2)), 2) AS s, COUNT(*) AS n
        FROM simulations.energy_prices
        WHERE clearing_mode = \$1 AND code_version = \$2 AND $win
        GROUP BY 1, 2 ORDER BY 1, 2
        """, Any[o["clearing_mode"], o["code_version"], wp...]))
end

function checksums_pg(pg, o)
    win, wp = day_window_clause("date_time_utc", o["start"], o["end"], 3)
    DataFrame(LibPQ.execute(pg, """
        SELECT bidding_zone AS z, to_char(date_time_utc, 'YYYY-MM') AS ym,
               ROUND(SUM(ROUND(price_eur_mwh, 2)), 2)::float8 AS s, COUNT(*) AS n
        FROM simulations.energy_prices
        WHERE clearing_mode = \$1 AND code_version = \$2 AND $win
        GROUP BY 1, 2 ORDER BY 1, 2
        """, Any[o["clearing_mode"], o["code_version"], wp...]))
end

function run_verify(con, pg, o)
    println("── per-year energy_prices row counts ──")
    dcy = per_year_counts_duckdb(con, o); pgy = per_year_counts_pg(pg, o)
    dd = Dict(Int(r.y) => Int(r.n) for r in eachrow(dcy))
    pd = Dict(Int(r.y) => Int(r.n) for r in eachrow(pgy))
    @printf("  %-6s %14s %14s %8s\n", "year", "duckdb", "postgres", "match")
    for y in sort(collect(union(keys(dd), keys(pd))))
        d = get(dd, y, 0); p = get(pd, y, 0)
        @printf("  %-6d %14d %14d %8s\n", y, d, p, d == p ? "ok" : "DIFF")
    end
    println("── zone-month price checksums (SUM price rounded) ──")
    dcs = checksums_duckdb(con, o); pcs = checksums_pg(pg, o)
    dk = Dict((String(r.z), String(r.ym)) => (round(Float64(r.s), digits=2), Int(r.n)) for r in eachrow(dcs))
    pk = Dict((String(r.z), String(r.ym)) => (round(Float64(r.s), digits=2), Int(r.n)) for r in eachrow(pcs))
    keys_all = sort(collect(union(keys(dk), keys(pk))))
    ndiff = 0
    for k in keys_all
        dv = get(dk, k, (NaN, 0)); pv = get(pk, k, (NaN, 0))
        if !(isapprox(dv[1], pv[1]; atol=0.01) && dv[2] == pv[2])
            ndiff += 1
            ndiff <= 20 && @printf("  DIFF %-12s %s  duckdb=(%.2f,%d) pg=(%.2f,%d)\n",
                k[1], k[2], dv[1], dv[2], pv[1], pv[2])
        end
    end
    println(ndiff == 0 ?
        "  ✅ all $(length(keys_all)) zone-month checksums match" :
        "  ⚠️ $ndiff / $(length(keys_all)) zone-month checksums differ")
    return ndiff == 0
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function main()
    o = parse_cli(ARGS)
    haskey(ENV, "ENERGY_CONN_STR") && !isempty(ENV["ENERGY_CONN_STR"]) ||
        error("ENERGY_CONN_STR is not set (needed for the live Postgres target)")

    println("=" ^ 70)
    println("TRANSFER results DuckDB → Postgres")
    println("  source        : $(o["results_db"])")
    println("  clearing_mode : $(o["clearing_mode"])   code_version : $(o["code_version"])")
    println("  date window   : $(something(o["start"], "min")) .. $(something(o["end"], "max"))")
    println("  mode          : $(o["verify"] ? "VERIFY (no writes)" : "TRANSFER")")
    println("=" ^ 70)

    con, db = open_results_duckdb(o["results_db"])
    pg = Euphemia.newconnection()
    try
        if o["verify"]
            ok = run_verify(con, pg, o)
            exit(ok ? 0 : 1)
        end

        # Make sure destination tables exist.
        Euphemia.ensure_energy_prices_table()
        o["flows"] && Euphemia.ensure_transmission_flows_table()

        t0 = time()
        prices = read_prices(con, o)
        println("read $(nrow(prices)) price rows from results DuckDB ($(round(time()-t0, digits=1))s)")
        isempty(prices) && (println("nothing to transfer — empty slice"); return)

        run_ids = Int64[Int64(x) for x in skipmissing(prices.optimization_run_id)]
        runs = read_runs(con, unique(run_ids))
        println("referenced optimization_runs: $(nrow(runs))")

        idmap = transfer_runs!(pg, runs)
        println("upserted $(length(idmap)) optimization_runs into Postgres")

        t1 = time()
        n = transfer_prices!(pg, prices, idmap, o)
        @printf("COPY'd %d energy_prices rows in %.1fs (%.0f rows/s)\n",
                n, time()-t1, n / max(time()-t1, 1e-9))

        if o["flows"]
            flows = read_flows(con, o)
            if !isempty(flows)
                nf = transfer_flows!(pg, flows, o)
                println("COPY'd $nf transmission_flows rows")
            else
                println("no transmission_flows in slice")
            end
        end

        println("── post-transfer verification ──")
        # The verdict must reach the exit code. It was discarded here, so a
        # transfer whose zone-month checksums DISAGREED still printed DONE and
        # exited 0 — the one check that can catch a bad transfer could not fail
        # the run (only --verify-only mode propagated it).
        ok = run_verify(con, pg, o)
        @printf("DONE in %.1fs\n", time() - t0)
        if ok === false
            println("❌ post-transfer verification FAILED — the Postgres slice does " *
                    "not match the source. Investigate before publishing.")
            exit(1)
        end
    finally
        LibPQ.close(pg)
        DBInterface.close!(con); DuckDB.close(db)
    end
end

main()
