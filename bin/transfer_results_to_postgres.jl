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
#
# How (owner rule, CLAUDE.md: Julia never queries Postgres except the fill and this bulk transfer, and
# never reads Postgres rows back to decide): DuckDB's postgres extension (attach_postgres!) is the only
# path to Postgres; no LibPQ connection is opened. Per day window: the window's runs, prices and flows
# and the source's checksums are staged engine-to-engine into Postgres tables, then ONE PL/pgSQL block
# (one transaction) upserts the runs (RETURNING id → run-id map), replaces the price and flow slices with
# the remapped ids, and verifies per-year counts + zone-month price checksums against the staged source
# ones — a mismatch RAISEs and nothing is written. NUMERIC columns are cast from the source double's
# shortest text (as the COPY of Julia's string(x) did), so stored values are the same.
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
#   # fill → run → transfer jobs (perf-96, owner rule 2026-11-23): the run-local results DuckDB also holds
#   # the energy_prices rows the fill seeded for the skip-existing check; move ONLY the days this run wrote
#   # (rows with update_time_utc >= the given UTC instant), one day window at a time, so a skipped day's
#   # Postgres rows are never deleted or rewritten
#   julia --project=. bin/transfer_results_to_postgres.jl --clearing-mode multi_zone \
#       --start 2026-11-22 --end 2026-11-22 --written-since 2026-11-23T03:00:00
#
#   # verify only (no slice writes): per-year row counts + per zone-month price checksums on both sides,
#   # compared inside Postgres
#   julia --project=. bin/transfer_results_to_postgres.jl --verify
#
# ENV
#   ENERGY_CONN_STR  live Postgres connection string (from .env; never printed)
#   RESULTS_DUCKDB   source results DuckDB (default data/results.duckdb, or the
#                    --results-db flag)

using DuckDB
# Load Euphemia (ENERGY_PRICES_CODE_VERSION, .env, attach_postgres!) on an empty boot DuckDB, so its __init__
# opens no LibPQ pool even with ENERGY_CONN_STR set (the extension is this script's only path to Postgres).
const _BOOT = let d = mktempdir(); f = joinpath(d, "boot.duckdb"); close(DuckDB.DB(f)); f end
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"; ENV["EUPHEMIA_DUCKDB_PATH"] = _BOOT; ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"
using Euphemia            # loads .env (ENERGY_CONN_STR)
using DataFrames, Dates, Printf

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
        "written_since" => nothing,
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
        elseif a == "--written-since"; o["written_since"] = DateTime(argv[i+1]); i += 1
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
    db = DuckDB.DB(":memory:")
    con = DBInterface.connect(db)
    try DBInterface.execute(con, "SET TimeZone = 'UTC'") catch end
    DBInterface.execute(con, "ATTACH '$(replace(path, "'" => "''"))' AS r (READ_ONLY)")
    DBInterface.execute(con, "USE r")      # the source queries below read r's simulations.* unqualified
    return con, db
end

sqlstr(s) = "'" * replace(String(s), "'" => "''") * "'"
pg_exec(con, sql) = DBInterface.execute(con, "CALL postgres_execute('pg', $(sqlstr(sql)))")
ts_lit(d::Date) = "TIMESTAMP " * sqlstr(Dates.format(d, "yyyy-mm-dd") * " 00:00:00")
"Postgres-side slice predicate (half-open [start, end+1) on date_time_utc)."
pg_slice(o) = "clearing_mode = $(sqlstr(o["clearing_mode"])) AND code_version = $(o["code_version"]) AND " *
              "date_time_utc >= $(ts_lit(o["start"])) AND date_time_utc < $(ts_lit(o["end"] + Day(1)))"

# Half-open [start, end+1) day predicate, plus params. Both bounds are always
# set by the time this is called (see `bound_window!`): an unbounded window
# used to expand the Postgres DELETE to the ENTIRE (clearing_mode, code_version)
# slice while restoring only what the source DuckDB held — and the verify step
# compared the two sides AFTER the wipe, so it passed (bug sweep 2026-08-24).
function day_window_clause(col::AbstractString, start, stop, p0::Int)
    (start === nothing || stop === nothing) &&
        error("day_window_clause: unbounded window — call bound_window! first")
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

"""
Fill a missing --start/--end from the SOURCE slice's own extent, so the Postgres
delete can never reach beyond the days the source actually carries.
"""
function bound_window!(con, o)
    (o["start"] !== nothing && o["end"] !== nothing) && return o
    ext = DataFrame(DBInterface.execute(con, """
        SELECT MIN(CAST(date_time_utc AS DATE)) AS d0, MAX(CAST(date_time_utc AS DATE)) AS d1
        FROM simulations.energy_prices
        WHERE clearing_mode = \$1 AND code_version = \$2
        """, Any[o["clearing_mode"], o["code_version"]]))
    (isempty(ext) || ismissing(ext.d0[1])) &&
        error("source slice (clearing_mode=$(o["clearing_mode"]), cv=$(o["code_version"])) is empty — nothing to transfer")
    o["start"] === nothing && (o["start"] = Date(ext.d0[1]))
    o["end"]   === nothing && (o["end"]   = Date(ext.d1[1]))
    @info "transfer window bounded to the source slice: $(o["start"]) .. $(o["end"])"
    return o
end

function read_flows(con, o)
    win, wp = day_window_clause("date_time_utc", o["start"], o["end"], 3)
    sql = """
        SELECT date_time_utc, source_zone, sink_zone, flow_mw,
               COALESCE(clearing_mode, 'multi_zone') AS clearing_mode, code_version,
               update_time_utc
        FROM simulations.transmission_flows
        WHERE code_version = \$1 AND COALESCE(clearing_mode, 'multi_zone') = \$2 AND $win
        ORDER BY source_zone, sink_zone, date_time_utc
    """
    return DataFrame(DBInterface.execute(con, sql, Any[o["code_version"], o["clearing_mode"], wp...]))
end

const RUN_COLS = ["bidding_zone", "optimization_date", "order_method", "model_type", "optimizer", "status",
    "objective_value", "solve_time_seconds", "num_orders", "num_price_periods", "error_message", "code_version",
    "created_at", "is_iterative", "total_time_seconds", "iterations", "converged", "final_price_change",
    "final_flow_change_pct"]
const RUN_NUMERIC = Set(["objective_value", "solve_time_seconds", "total_time_seconds", "final_price_change",
                         "final_flow_change_pct"])
"Source column → staged expression: NUMERIC targets travel as the double's shortest text."
stagecol(c) = c in RUN_NUMERIC ? "CAST($c AS VARCHAR) AS $c" : c
pgcol(c, alias) = c in RUN_NUMERIC ? "$alias.$c::numeric" : "$alias.$c"

"""Stage the source's per-year counts and zone-month checksums (computed in DuckDB, as before)."""
function stage_checks!(con, o, st)
    win, wp = day_window_clause("date_time_utc", o["start"], o["end"], 3)
    DBInterface.execute(con, """
        CREATE TABLE pg.$(st)_chk AS
        SELECT bidding_zone AS z, strftime(date_time_utc, '%Y-%m') AS ym,
               ROUND(SUM(ROUND(price_eur_mwh, 2)), 2) AS s, COUNT(*) AS n
        FROM simulations.energy_prices
        WHERE clearing_mode = \$1 AND code_version = \$2 AND $win
        GROUP BY 1, 2""", Any[o["clearing_mode"], o["code_version"], wp...])
    DBInterface.execute(con, """
        CREATE TABLE pg.$(st)_years AS
        SELECT CAST(EXTRACT(YEAR FROM date_time_utc) AS INTEGER) AS y, COUNT(*) AS n
        FROM simulations.energy_prices
        WHERE clearing_mode = \$1 AND code_version = \$2 AND $win
        GROUP BY 1""", Any[o["clearing_mode"], o["code_version"], wp...])
end

"""The server-side verification (inside the caller's PL/pgSQL block): RAISE unless Postgres' slice has the same
per-year counts and zone-month checksums (±0.01, row-rounded sums) as the staged source."""
plpgsql_verify(o, st) = """
  SELECT COUNT(*) INTO ndiff FROM (
    SELECT y FROM (SELECT EXTRACT(YEAR FROM date_time_utc)::int AS y, COUNT(*) AS n FROM simulations.energy_prices
                   WHERE $(pg_slice(o)) GROUP BY 1) p
    FULL JOIN $(st)_years c USING (y) WHERE p.n IS DISTINCT FROM c.n) d;
  IF ndiff > 0 THEN RAISE EXCEPTION 'verification FAILED: % year(s) with different energy_prices row counts', ndiff; END IF;
  SELECT COUNT(*), string_agg(z || ' ' || ym, ', ') INTO ndiff, diffs FROM (
    SELECT z, ym FROM (SELECT bidding_zone AS z, to_char(date_time_utc, 'YYYY-MM') AS ym,
                              ROUND(SUM(ROUND(price_eur_mwh, 2)), 2)::float8 AS s, COUNT(*) AS n
                       FROM simulations.energy_prices WHERE $(pg_slice(o)) GROUP BY 1, 2) p
    FULL JOIN $(st)_chk c USING (z, ym)
    WHERE p.n IS DISTINCT FROM c.n OR p.s IS NULL OR c.s IS NULL OR abs(p.s - c.s) > 0.01 LIMIT 20) d;
  IF ndiff > 0 THEN RAISE EXCEPTION 'verification FAILED: zone-month checksums differ: %', diffs; END IF;
"""

"""Transfer one window inside Postgres (one transaction): runs upsert → run-id map, price and flow slice
delete-then-insert with remapped ids, server-side verification. Returns the staged row counts."""
function transfer_window_pg!(con, o, prices::DataFrame, run_ids)
    st = "simulations._p96r_" * Dates.format(now(UTC), "yyyymmddHHMMSS") * "_" * string(getpid())
    win, wp = day_window_clause("date_time_utc", o["start"], o["end"], 3)
    stages = ["$(st)_runs", "$(st)_prices", "$(st)_flows", "$(st)_chk", "$(st)_years"]
    try
        DBInterface.execute(con, "CREATE TABLE pg.$(st)_runs AS SELECT id AS local_id, " *
            join(stagecol.(RUN_COLS), ", ") * " FROM simulations.optimization_runs WHERE id IN (SELECT unnest(\$1))",
            Any[collect(Int64, run_ids)])
        DBInterface.execute(con, """
            CREATE TABLE pg.$(st)_prices AS
            SELECT date_time_utc, resolution_code, bidding_zone, contract_type, CAST(price_eur_mwh AS VARCHAR) AS price_t,
                   currency, order_method, clearing_mode, optimization_run_id AS local_run_id, code_version, update_time_utc
            FROM simulations.energy_prices WHERE clearing_mode = \$1 AND code_version = \$2 AND $win""",
            Any[o["clearing_mode"], o["code_version"], wp...])
        nflows = 0
        if o["flows"]
            DBInterface.execute(con, """
                CREATE TABLE pg.$(st)_flows AS
                SELECT date_time_utc, source_zone, sink_zone, CAST(flow_mw AS VARCHAR) AS flow_t,
                       COALESCE(clearing_mode, 'multi_zone') AS clearing_mode, code_version, update_time_utc
                FROM simulations.transmission_flows
                WHERE code_version = \$1 AND COALESCE(clearing_mode, 'multi_zone') = \$2 AND $win""",
                Any[o["code_version"], o["clearing_mode"], wp...])
            nflows = Int(DataFrame(DBInterface.execute(con, "SELECT COUNT(*) AS n FROM pg.$(st)_flows")).n[1])
        end
        stage_checks!(con, o, st)
        cols = join(RUN_COLS, ", ")
        upd = join(("$c = EXCLUDED.$c" for c in ("status", "objective_value", "solve_time_seconds", "num_orders",
            "num_price_periods", "error_message", "created_at", "is_iterative", "total_time_seconds", "iterations",
            "converged", "final_price_change", "final_flow_change_pct")), ", ")
        flows_sql = !o["flows"] ? "" : """
          DELETE FROM simulations.transmission_flows WHERE $(pg_slice(o));
          INSERT INTO simulations.transmission_flows
            (date_time_utc, source_zone, sink_zone, flow_mw, clearing_mode, code_version, update_time_utc)
            SELECT date_time_utc, source_zone, sink_zone, flow_t::numeric, clearing_mode, code_version, update_time_utc
            FROM $(st)_flows;"""
        pg_exec(con, """
DO \$p96rec\$
DECLARE r record; new_id int; ndiff bigint; diffs text;
BEGIN
  IF to_regclass('simulations.energy_prices') IS NULL OR to_regclass('simulations.optimization_runs') IS NULL
     $(o["flows"] ? "OR to_regclass('simulations.transmission_flows') IS NULL" : "") THEN
    RAISE EXCEPTION 'destination simulations tables are missing (create them with the repo DDL first)';
  END IF;
  CREATE TEMP TABLE _p96_idmap (local_id bigint PRIMARY KEY, pg_id int) ON COMMIT DROP;
  FOR r IN SELECT * FROM $(st)_runs LOOP
    INSERT INTO simulations.optimization_runs ($cols)
      VALUES ($(join((pgcol(c, "r") for c in RUN_COLS), ", ")))
      ON CONFLICT (bidding_zone, optimization_date, order_method, model_type, code_version, optimizer)
      DO UPDATE SET $upd
      RETURNING id INTO new_id;
    INSERT INTO _p96_idmap VALUES (r.local_id, new_id);
  END LOOP;
  DELETE FROM simulations.energy_prices WHERE $(pg_slice(o));
  INSERT INTO simulations.energy_prices
    (date_time_utc, resolution_code, bidding_zone, contract_type, price_eur_mwh, currency, order_method,
     clearing_mode, optimization_run_id, code_version, update_time_utc)
    SELECT p.date_time_utc, p.resolution_code, p.bidding_zone, p.contract_type, p.price_t::numeric, p.currency,
           p.order_method, p.clearing_mode, m.pg_id, p.code_version, p.update_time_utc
    FROM $(st)_prices p LEFT JOIN _p96_idmap m ON m.local_id = p.local_run_id;
$flows_sql
$(plpgsql_verify(o, st))
END
\$p96rec\$;""")
        return (runs=length(run_ids), prices=nrow(prices), flows=nflows)
    finally
        for t in stages
            try pg_exec(con, "DROP TABLE IF EXISTS $t") catch e; @warn "could not drop $t" exception = e end
        end
    end
end

"Verify only: stage the source checks and compare inside Postgres (no slice is written)."
function run_verify(con, o)
    st = "simulations._p96v_" * Dates.format(now(UTC), "yyyymmddHHMMSS") * "_" * string(getpid())
    try
        stage_checks!(con, o, st)
        pg_exec(con, "DO \$p96v\$ DECLARE ndiff bigint; diffs text; BEGIN $(plpgsql_verify(o, st)) END \$p96v\$;")
        println("  ✅ per-year counts and all zone-month checksums match (verified inside Postgres)")
        return true
    catch e
        println("  ⚠️ ", sprint(showerror, e))
        return false
    finally
        for t in ("$(st)_chk", "$(st)_years")
            try pg_exec(con, "DROP TABLE IF EXISTS $t") catch end
        end
    end
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
    Euphemia.attach_postgres!(con, ENV["ENERGY_CONN_STR"]; read_only=false)
    try
        if o["verify"]
            bound_window!(con, o)
            ok = run_verify(con, o)
            exit(ok ? 0 : 1)
        end

        if o["written_since"] !== nothing
            days = written_days(con, o)
            println("--written-since $(o["written_since"]): $(length(days)) day(s) written by this run: " *
                    join(days, ", "))
            isempty(days) && (println("nothing to transfer — no rows written since then"); return)
            for d in days
                od = copy(o); od["start"] = d; od["end"] = d
                transfer_window!(con, od)
            end
            return
        end
        transfer_window!(con, o)
    finally
        DBInterface.close!(con); DuckDB.close(db)
    end
end

"Distinct UTC days of the slice with rows written at or after o[\"written_since\"] (within --start/--end if given)."
function written_days(con, o)
    extra, ep = (o["start"] === nothing || o["end"] === nothing) ? ("", Any[]) :
        (" AND " * first(day_window_clause("date_time_utc", o["start"], o["end"], 4)),
         last(day_window_clause("date_time_utc", o["start"], o["end"], 4)))
    df = DataFrame(DBInterface.execute(con, """
        SELECT DISTINCT CAST(date_time_utc AS DATE) AS d FROM simulations.energy_prices
        WHERE clearing_mode = \$1 AND code_version = \$2 AND update_time_utc >= \$3$extra
        ORDER BY 1""", Any[o["clearing_mode"], o["code_version"], o["written_since"], ep...]))
    return Date.(df.d)
end

"""Refuse (before any Postgres mutation) when a referenced optimization run lies outside the slice: another
code version, or an optimization_date outside start..end. Local check on the results DuckDB's rows."""
function check_runs_in_slice(runs::DataFrame, o)
    isempty(runs) && return nothing
    cv = o["code_version"]; d0 = o["start"]; d1 = o["end"]
    bad = [r.id for r in eachrow(runs) if r.code_version != cv ||
           !(d0 <= Date(r.optimization_date) <= d1)]
    isempty(bad) || error("transfer refused: $(length(bad)) referenced optimization_runs " *
        "fall outside the slice (code_version=$cv, $d0..$d1), e.g. ids $(first(bad, 5)). " *
        "Nothing was written.")
    println("referenced optimization_runs all inside the slice (cv$cv, $d0..$d1)")
    return nothing
end

"Transfer one (clearing_mode, code_version, day window) slice inside Postgres: runs, prices, flows, verify."
function transfer_window!(con, o)
    bound_window!(con, o)   # never an unbounded Postgres delete
    t0 = time()
    prices = read_prices(con, o)
    println("read $(nrow(prices)) price rows from results DuckDB ($(o["start"]) .. $(o["end"]))")
    isempty(prices) && (println("nothing to transfer — empty slice"); return)
    run_ids = unique(Int64[Int64(x) for x in skipmissing(prices.optimization_run_id)])
    runs = read_runs(con, run_ids)
    println("referenced optimization_runs: $(nrow(runs))")
    check_runs_in_slice(runs, o)   # before ANY destination mutation
    n = transfer_window_pg!(con, o, prices, run_ids)
    println("upserted $(n.runs) optimization_runs, replaced $(n.prices) energy_prices + $(n.flows) transmission_flows " *
            "rows in one Postgres transaction; verification passed inside it (per-year counts, zone-month " *
            "checksums) — $(round(time() - t0, digits=1))s")
    println("DONE")
end

main()
