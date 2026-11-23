#!/usr/bin/env julia
# transfer_run_results.jl — the bulk transfer of a fill → run → transfer job (owner rule, CLAUDE.md: "Julia never
# queries Postgres, except the one step that fills DuckDB … Results: Julia writes to DuckDB, and a bulk transfer
# moves them to Postgres"). It replays the pending ops of a run-local results DuckDB (src/db/run_results.jl):
#
#   1. STAGE: each op's rows are copied engine-to-engine (DuckDB postgres extension, attach_postgres!) into one
#      Postgres staging table per op (simulations._p96t_<run>_<op>); rows never pass through Julia.
#   2. APPLY: ONE PL/pgSQL block, executed inside Postgres as a single transaction, applies every op in op_id
#      order. All decisions are server-side SQL — Julia reads no Postgres row back:
#        forecast_slice    the realized-day guard (market_date > MAX actual_total_load date) and the hour guard
#                          (every staged hour > prediction_made_utc) for live slices; the retro plan re-decided
#                          from the live rows of the slice at that moment (retro_write_plan's rules: insert /
#                          alongside / supersede / refuse), RAISE if it differs from the plan the run applied;
#                          then the live per-zone DELETE, the retro DELETE, or the supersede backup
#                          (INSERT INTO forecast_prices_pre_reset SELECT …, ROW_COUNT must equal the live count)
#                          + slice DELETE; then INSERT … SELECT from the stage.
#        input_corrections INSERT … SELECT … ON CONFLICT DO NOTHING (Postgres' own key, as the emitter did).
#        score_upsert      INSERT … ON CONFLICT (pk) DO UPDATE of the hourly columns (as upsert_score! did), with
#                          scored_at = the scorer's scoring-time stamp (a rescore campaign's key file matches it).
#        score_q15         the q15 columns added first if missing (catalog check + ALTER under a 5 s lock
#                          timeout, as ensure_q15_columns did), then UPDATE … FROM the stage.
#        score_restore     forecast_scores_snapshot.jl restore: snapshot values + scored_at back, only where the
#                          row's scored_at is still the campaign's (UPDATE … FROM the stage … AND scored_at = …).
#      Any RAISE aborts the whole block: Postgres is unchanged.
#   3. The staging tables are dropped (always), then the ops are marked done in the results DuckDB.
#
# Exactly once: the block records every op it applies in simulations.transfer_log (run_uuid of the results
# DuckDB, op_id) inside the same Postgres transaction, and skips an op already recorded there. A failed transfer
# records nothing (re-run applies everything); a transfer that committed but lost its local done marks is a
# no-op when re-run (no duplicate supersede backup, no plan re-decided on an already-changed slice).
#
# usage: julia --project=. bin/transfer_run_results.jl [--results-db PATH] [--dry-run]
# env:   ENERGY_CONN_STR (libpq key=value or postgresql:// URI; never printed),
#        EUPHEMIA_RESULTS_DB (default data/results.duckdb), EUPHEMIA_DUCKDB_EXT_DIR (see pg_attach.jl)
using DuckDB, DataFrames, Dates, JSON, Printf
# Not `using Euphemia`: its __init__ resolves a data store, and with ENERGY_CONN_STR set it would open a LibPQ
# connection pool to Postgres. The transfer needs only the extension helper (attach_postgres!), loaded standalone.
module TransferPG
using DuckDB
include(joinpath(@__DIR__, "..", "src", "db", "pg_attach.jl"))
end

function parse_cli(argv)
    o = Dict{String,Any}("results_db" => get(ENV, "EUPHEMIA_RESULTS_DB", "data/results.duckdb"), "dry_run" => false)
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--results-db"; o["results_db"] = argv[i+1]; i += 1
        elseif a == "--dry-run"; o["dry_run"] = true
        else error("unknown arg: $a") end
        i += 1
    end
    return o
end

q(con, sql, args=Any[]) = DataFrame(isempty(args) ? DBInterface.execute(con, sql) :
                                    DBInterface.execute(DBInterface.prepare(con, sql), args))
x(con, sql) = (DBInterface.execute(con, sql); nothing)
sqlstr(s) = "'" * replace(String(s), "'" => "''") * "'"
"Run SQL inside Postgres (DuckDB postgres extension) — the transfer's only way to act on Postgres."
pg_exec(con, sql) = x(con, "CALL postgres_execute('pg', $(sqlstr(sql)))")

# SQL literals for the generated PL/pgSQL (op params are dates, ints, short strings, flags)
lit(v::Nothing) = "NULL"
lit(v::Bool) = v ? "true" : "false"
lit(v::Integer) = string(v)
lit(v::AbstractString) = sqlstr(v)
lit(v::Date) = "DATE " * sqlstr(Dates.format(v, "yyyy-mm-dd"))
lit(v::DateTime) = "TIMESTAMPTZ " * sqlstr(Dates.format(v, "yyyy-mm-dd HH:MM:SS.sss") * "+00")
lit_text_array(v) = isempty(v) ? "ARRAY[]::text[]" : "ARRAY[" * join(lit.(String.(v)), ", ") * "]::text[]"
ident_ok(s) = occursin(r"^[a-z0-9_]+$", s) || error("bad identifier $(repr(s))")

const FP_COLS = "market_date, date_time_utc, bidding_zone, price_eur_mwh, prediction_made_utc, lead_days, " *
                "clearing_mode, code_version, input_mode, is_retro, reset_tag, retro_of_utc"
# naive-UTC TIMESTAMP (results DuckDB) → timestamptz (Postgres); DuckDB's TimeZone is UTC
const FP_STAGE_SELECT = "market_date, CAST(date_time_utc AS TIMESTAMPTZ) AS date_time_utc, bidding_zone, " *
    "price_eur_mwh, CAST(prediction_made_utc AS TIMESTAMPTZ) AS prediction_made_utc, lead_days, clearing_mode, " *
    "code_version, input_mode, is_retro, reset_tag, CAST(retro_of_utc AS TIMESTAMPTZ) AS retro_of_utc"
const SCORE_PK = ["market_date", "bidding_zone", "lead_days", "code_version", "input_mode", "is_retro"]
const SCORE_HOURLY = ["n_hours", "mae", "bias", "corr", "n_collapse_actual", "n_collapse_pred", "collapse_hits",
                      "collapse_false_alarms", "collapse_hit_rate", "collapse_false_alarm_rate"]
const SCORE_Q15 = [("n_q15", "INT"), ("mae_q15", "DOUBLE PRECISION"), ("bias_q15", "DOUBLE PRECISION"),
                   ("corr_q15", "DOUBLE PRECISION"), ("shape_floor_q15", "DOUBLE PRECISION"),
                   ("q15_forecast_res", "TEXT"), ("n_le0_q15_actual", "INT"), ("n_le0_q15_pred", "INT"),
                   ("le0_q15_hits", "INT")]

# ---------------------------------------------------------------------------------------------------------------
# 1. staging (DuckDB → Postgres, engine to engine)
# ---------------------------------------------------------------------------------------------------------------
"Register an op's score keys as the DuckDB view `k`."
function score_keys!(con, p)
    ks = p["keys"]
    df = DataFrame(market_date=Date.([k["market_date"] for k in ks]), bidding_zone=String[k["bidding_zone"] for k in ks],
                   lead_days=Int[k["lead_days"] for k in ks], code_version=Int[k["code_version"] for k in ks],
                   input_mode=String[k["input_mode"] for k in ks], is_retro=Bool[k["is_retro"] for k in ks])
    try DuckDB.unregister_data_frame(con, "k") catch end
    DuckDB.register_data_frame(con, df, "k")
    return nrow(df)
end

"The SELECT (over the results DuckDB `r`) whose rows an op ships, and its local row count."
function stage_select(con, kind, op_id, p)
    if kind == "forecast_slice"
        sel = "SELECT $FP_STAGE_SELECT FROM r.simulations.transfer_forecast_rows WHERE transfer_op_id = $op_id"
    elseif kind == "input_corrections"
        sel = "SELECT bidding_zone, target, CAST(date_time_utc AS TIMESTAMPTZ) AS date_time_utc, corrected_mw, " *
              "model_tag FROM r.simulations.input_corrections WHERE transfer_op_id = $op_id"
    elseif kind == "score_upsert"
        score_keys!(con, p)
        sel = "SELECT $(join(SCORE_PK, ", ")), $(join(SCORE_HOURLY, ", ")), reset_tag, " *
              "CAST(scored_at AS TIMESTAMPTZ) AS scored_at FROM r.simulations.forecast_scores " *
              "JOIN k USING ($(join(SCORE_PK, ", ")))"
    elseif kind == "score_restore"
        sel = "SELECT $(join(SCORE_PK, ", ")), $(join(SCORE_HOURLY, ", ")), reset_tag, snapshot_scored_at, " *
              "campaign_scored_at FROM r.simulations.transfer_score_restore WHERE transfer_op_id = $op_id"
    elseif kind == "score_q15"
        score_keys!(con, p)
        sel = "SELECT $(join(SCORE_PK, ", ")), $(join(first.(SCORE_Q15), ", ")) FROM r.simulations.forecast_scores " *
              "JOIN k USING ($(join(SCORE_PK, ", ")))"
    else
        error("op $op_id: unknown kind $kind")
    end
    n = Int(q(con, "SELECT COUNT(*) AS n FROM ($sel)").n[1])
    return sel, n
end

# ---------------------------------------------------------------------------------------------------------------
# 2. the server-side PL/pgSQL for each op (runs inside Postgres; no row comes back to Julia)
# ---------------------------------------------------------------------------------------------------------------
function plpgsql_forecast_slice(op_id, p, st)
    md = Date(p["market_date"]); lead = Int(p["lead_days"]); mode = String(p["input_mode"])
    is_retro = Bool(p["is_retro"]); alongside = Bool(p["alongside"]); supersede = Bool(p["supersede"])
    cv = Int(p["code_version"]); tag = p["reset_tag"]; zones = String.(p["zones"]); plan = String(p["plan"])
    slice = "market_date = $(lit(md)) AND lead_days = $(lit(lead)) AND input_mode = $(lit(mode))"
    who = "op $op_id ($md lead=$lead mode=$mode)"
    b = IOBuffer()
    println(b, "  -- $who: forecast_slice, run plan $plan")
    if !is_retro   # LIVE: realized-day and hour guards, against Postgres now
        println(b, """
          IF horizon IS NULL THEN RAISE EXCEPTION 'entsoe.actual_total_load is empty: no realized horizon'; END IF;
          IF $(lit(md)) <= horizon THEN
            RAISE EXCEPTION '$who: REFUSING, the market day has realized (latest actual_total_load date %)', horizon;
          END IF;
          IF EXISTS (SELECT 1 FROM $st WHERE date_time_utc <= $(lit(DateTime(p["prediction_made_utc"])))) THEN
            RAISE EXCEPTION '$who: REFUSING, a row is at or before prediction_made_utc';
          END IF;""")
    end
    # retro_write_plan, server-side (bin/forecast_common.jl): the plan Postgres gives now must be the run's
    println(b, "  SELECT COUNT(*) INTO n_live FROM simulations.forecast_prices WHERE $slice AND is_retro = false;")
    alongside && println(b, "  SELECT COUNT(*) INTO n_live_same_cv FROM simulations.forecast_prices WHERE $slice " *
                            "AND code_version = $(lit(cv)) AND is_retro = false;")
    pg_plan = alongside ? "CASE WHEN n_live_same_cv > 0 THEN 'refuse_same_cv' ELSE 'alongside' END" :
              !is_retro ? "'insert'" :
              "CASE WHEN n_live = 0 THEN 'insert' ELSE $(supersede ? "'supersede'" : "'refuse'") END"
    println(b, """
      plan := $pg_plan;
      IF plan <> $(lit(plan)) THEN
        RAISE EXCEPTION '$who: the run applied plan $plan but Postgres now gives % (live rows: %) — refusing the transfer', plan, n_live;
      END IF;""")
    if plan == "alongside"
        println(b, "  DELETE FROM simulations.forecast_prices WHERE $slice AND is_retro = true " *
                   "AND reset_tag = $(lit(tag)) AND code_version = $(lit(cv));")
    elseif plan == "supersede"
        println(b, """
          INSERT INTO simulations.forecast_prices_pre_reset ($FP_COLS)
            SELECT $FP_COLS FROM simulations.forecast_prices WHERE $slice AND is_retro = false;
          GET DIAGNOSTICS n_backed = ROW_COUNT;
          IF n_backed <> n_live THEN
            RAISE EXCEPTION '$who: supersede backup mismatch (backed up %, % live rows)', n_backed, n_live;
          END IF;
          DELETE FROM simulations.forecast_prices WHERE $slice;""")
    elseif is_retro
        println(b, "  DELETE FROM simulations.forecast_prices WHERE $slice AND is_retro = true;")
    else
        println(b, "  DELETE FROM simulations.forecast_prices WHERE $slice AND is_retro = false " *
                   "AND bidding_zone = ANY($(lit_text_array(zones)));")
    end
    println(b, "  INSERT INTO simulations.forecast_prices ($FP_COLS) SELECT $FP_COLS FROM $st;")
    return String(take!(b))
end

plpgsql_input_corrections(op_id, p, st) =
    "  -- op $op_id: input_corrections (ON CONFLICT DO NOTHING, as the emitter)\n" *
    "  INSERT INTO simulations.input_corrections (bidding_zone, target, date_time_utc, corrected_mw, model_tag)\n" *
    "    SELECT bidding_zone, target, date_time_utc, corrected_mw, model_tag FROM $st ON CONFLICT DO NOTHING;\n"

function plpgsql_score_upsert(op_id, p, st)
    pk = join(SCORE_PK, ", "); hc = join(SCORE_HOURLY, ", ")
    # scored_at = the stamp the scorer set at scoring time (so a rescore campaign's key file matches Postgres)
    return "  -- op $op_id: score_upsert (as upsert_score!; scored_at = the scoring-time stamp)\n" *
           "  INSERT INTO simulations.forecast_scores ($pk, $hc, reset_tag, scored_at)\n" *
           "    SELECT $pk, $hc, reset_tag, scored_at FROM $st\n" *
           "    ON CONFLICT ($pk) DO UPDATE SET " * join(("$c = EXCLUDED.$c" for c in SCORE_HOURLY), ", ") *
           ", is_retro = EXCLUDED.is_retro, reset_tag = EXCLUDED.reset_tag, scored_at = EXCLUDED.scored_at;\n"
end

"score_restore (as forecast_scores_snapshot.jl restore): snapshot values + scored_at back, only on rows whose
scored_at is still the campaign's."
function plpgsql_score_restore(op_id, p, st)
    return "  -- op $op_id: score_restore (only where scored_at is still the campaign's)\n" *
           "  UPDATE simulations.forecast_scores t SET " *
           join(("$c = s.$c" for c in vcat(SCORE_HOURLY, ["reset_tag"])), ", ") *
           ", scored_at = s.snapshot_scored_at::timestamptz FROM $st s WHERE " *
           join(("t.$c = s.$c" for c in SCORE_PK), " AND ") * " AND t.scored_at = s.campaign_scored_at::timestamptz;\n"
end

function plpgsql_score_q15(op_id, p, st)
    b = IOBuffer()
    println(b, "  -- op $op_id: score_q15 (columns as ensure_q15_columns, then as update_q15!)")
    println(b, "  PERFORM set_config('lock_timeout', '5s', true);")
    for (c, ty) in SCORE_Q15
        println(b, "  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'simulations' " *
                   "AND table_name = 'forecast_scores' AND column_name = '$c') THEN " *
                   "EXECUTE 'ALTER TABLE simulations.forecast_scores ADD COLUMN IF NOT EXISTS $c $ty'; END IF;")
    end
    println(b, "  PERFORM set_config('lock_timeout', '0', true);")
    println(b, "  UPDATE simulations.forecast_scores t SET " * join(("$c = s.$c" for c in first.(SCORE_Q15)), ", ") *
               " FROM $st s WHERE " * join(("t.$c = s.$c" for c in SCORE_PK), " AND ") * ";")
    return String(take!(b))
end

const PLPGSQL = Dict("forecast_slice" => plpgsql_forecast_slice, "input_corrections" => plpgsql_input_corrections,
                     "score_upsert" => plpgsql_score_upsert, "score_q15" => plpgsql_score_q15,
                     "score_restore" => plpgsql_score_restore)

"The single server-side transfer block (one Postgres transaction)."
function transfer_block(ops, stages, run_uuid)
    needs_horizon = any(r -> r.kind == "forecast_slice" && !Bool(JSON.parse(r.params)["is_retro"]), eachrow(ops))
    b = IOBuffer()
    println(b, "DO \$p96transfer\$")
    println(b, "DECLARE horizon date; n_live bigint := 0; n_live_same_cv bigint := 0; n_backed bigint; plan text;")
    println(b, "BEGIN")
    println(b, "  CREATE TABLE IF NOT EXISTS simulations.transfer_log (run_uuid text NOT NULL, op_id bigint NOT NULL, " *
               "kind text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (run_uuid, op_id));")
    needs_horizon && println(b, "  SELECT MAX((date_time_utc AT TIME ZONE 'UTC')::date) INTO horizon FROM entsoe.actual_total_load;")
    for r in eachrow(ops)
        println(b, "  IF EXISTS (SELECT 1 FROM simulations.transfer_log WHERE run_uuid = $(lit(run_uuid)) AND op_id = $(r.op_id)) THEN")
        println(b, "    RAISE NOTICE 'op $(r.op_id) already applied (transfer_log) — skipped';")
        println(b, "  ELSE")
        print(b, PLPGSQL[r.kind](r.op_id, JSON.parse(r.params), stages[r.op_id]))
        println(b, "  INSERT INTO simulations.transfer_log (run_uuid, op_id, kind) VALUES ($(lit(run_uuid)), $(r.op_id), $(lit(r.kind)));")
        println(b, "  END IF;")
    end
    println(b, "END")
    println(b, "\$p96transfer\$;")
    return String(take!(b))
end

# ---------------------------------------------------------------------------------------------------------------
function main()
    o = parse_cli(ARGS)
    path = o["results_db"]
    isfile(path) || error("results DuckDB not found: $path")
    con = DBInterface.connect(DuckDB.DB, ":memory:")
    try x(con, "SET TimeZone = 'UTC'") catch end   # needs ICU; without it DuckDB already treats TIMESTAMP as UTC
    x(con, "ATTACH $(sqlstr(path)) AS r (READ_WRITE)")
    has_ops = !isempty(q(con, "SELECT 1 FROM information_schema.tables WHERE table_catalog = 'r' " *
                              "AND table_schema = 'simulations' AND table_name = 'transfer_ops'"))
    ops = has_ops ? q(con, "SELECT op_id, kind, params FROM r.simulations.transfer_ops WHERE done_at IS NULL " *
                           "ORDER BY op_id") : DataFrame(op_id=Int[], kind=String[], params=String[])
    println("transfer_run_results: $(nrow(ops)) pending op(s) in $path" * (o["dry_run"] ? " (dry run)" : ""))
    for r in eachrow(ops)
        haskey(PLPGSQL, r.kind) || error("op $(r.op_id): unknown kind $(r.kind)")
    end
    isempty(ops) && return
    meta = q(con, "SELECT run_uuid FROM r.simulations.transfer_meta")
    nrow(meta) == 1 || error("results DuckDB has $(nrow(meta)) run_uuid row(s) in transfer_meta (expected 1)")
    run_uuid = String(meta.run_uuid[1]); occursin(r"^[0-9a-f]{32}$", run_uuid) || error("bad run_uuid")
    run = "_p96t_" * Dates.format(now(UTC), "yyyymmddHHMMSS") * "_" * string(getpid())
    ident_ok(run)
    stages = Dict(r.op_id => "simulations.$(run)_$(r.op_id)" for r in eachrow(ops))
    if o["dry_run"]   # print the server-side block with the stage names it would use; touch nothing
        for r in eachrow(ops)
            _, n = stage_select(con, r.kind, r.op_id, JSON.parse(r.params))
            println("  op $(r.op_id) $(r.kind): $n row(s) to stage  $(r.params)")
        end
        println(transfer_block(ops, stages, run_uuid))
        return
    end
    conn = strip(get(ENV, "ENERGY_CONN_STR", ""))
    isempty(conn) && error("ENERGY_CONN_STR is not set (the transfer's Postgres target)")
    TransferPG.attach_postgres!(con, conn; read_only=false)
    t0 = time()
    nrows = Dict{Int,Int}()
    try
        for r in eachrow(ops)   # 1. stage (engine to engine; committed, uniquely named, dropped below)
            sel, n = stage_select(con, r.kind, r.op_id, JSON.parse(r.params))
            x(con, "CREATE TABLE pg.$(stages[r.op_id]) AS $sel")
            nrows[r.op_id] = n
        end
        t1 = time()
        pg_exec(con, transfer_block(ops, stages, run_uuid))   # 2. apply: one server-side transaction
        @printf("  staged %d row(s) in %.1f s; applied %d op(s) in one Postgres transaction in %.1f s\n",
                sum(values(nrows)), t1 - t0, nrow(ops), time() - t1)
    catch
        println("transfer FAILED — Postgres unchanged (the apply block is one transaction); the ops stay pending")
        rethrow()
    finally   # 3. drop the stages whatever happened
        for st in values(stages)
            try pg_exec(con, "DROP TABLE IF EXISTS $st") catch e; @warn "could not drop $st" exception = e end
        end
    end
    for r in eachrow(ops)   # marks after the commit; replaying is idempotent (header)
        out = "$(nrows[r.op_id]) row(s); plan " * get(JSON.parse(r.params), "plan", "-")
        DBInterface.execute(DBInterface.prepare(con,
            "UPDATE r.simulations.transfer_ops SET done_at = now()::TIMESTAMP, outcome = \$1 WHERE op_id = \$2"),
            Any[out, r.op_id])
        @printf("  op %d %-17s %s\n", r.op_id, r.kind, out)
    end
    @printf("transfer_run_results: %d op(s) committed to Postgres in %.1f s\n", nrow(ops), time() - t0)
end

main()
