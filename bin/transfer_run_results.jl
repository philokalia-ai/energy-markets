#!/usr/bin/env julia
# transfer_run_results.jl — the ONE Julia → Postgres write step of a fill → run → transfer job (owner rule
# 2026-11-23: "DuckDB between Postgres and Julia, always"). It replays the pending ops of a run-local results
# DuckDB (src/db/run_results.jl) against Postgres through DuckDB's postgres extension (attach_postgres!,
# read_only=false): one Postgres transaction for the whole job, rows moved engine-to-engine (never row by row
# through Julia), then the ops are marked done in the results DuckDB.
#
# Ops (written by the DuckDB-backend writers; params = slice keys/flags only, rows live in results_db):
#   forecast_slice    bin/daily_forecast.jl write_forecast!: live per-zone clear + insert, or the retro plan
#                     (insert / alongside / supersede-with-backup / refuse) RE-DECIDED here on Postgres; an op
#                     whose plan changed since the run aborts the whole transfer (nothing is clobbered).
#                     Live slices re-check the realized-day guard against Postgres.
#   input_corrections bin/emit_input_corrections.jl: INSERT … ON CONFLICT DO NOTHING (Postgres' own key).
#   score_upsert      bin/score_forecasts.jl upsert_score!: INSERT … ON CONFLICT DO UPDATE of the hourly columns.
#   score_q15         bin/score_forecasts.jl update_q15!: UPDATE of the q15 columns (added first if missing,
#                     catalog first, under a 5 s lock_timeout, as ensure_q15_columns does).
# Postgres reads here (plan counts, the realized horizon, the q15 catalog check) are the transfer step's own;
# nothing else in Julia reads Postgres.
#
# Idempotent: every op is a slice replace / upsert / insert-ignore, so a re-run after a failure (before or after
# the commit, the marks are written after it) converges to the same Postgres state; a superseded live vintage is
# backed up once (on a replay the slice holds no live rows any more).
#
# usage: julia --project=. bin/transfer_run_results.jl [--results-db PATH] [--dry-run]
# env:   ENERGY_CONN_STR (libpq key=value or postgresql:// URI; never printed),
#        EUPHEMIA_RESULTS_DB (default data/results.duckdb), EUPHEMIA_DUCKDB_EXT_DIR (see pg_attach.jl)
using Euphemia, DuckDB, DataFrames, Dates, JSON, Printf
include(joinpath(@__DIR__, "forecast_common.jl"))   # retro_write_plan, assert_unrealized, assert_hours_unrealized

const STAGE_PREFIX = "_p96_transfer_stage"

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
x(con, sql, args=Any[]) = (isempty(args) ? DBInterface.execute(con, sql) :
                           DBInterface.execute(DBInterface.prepare(con, sql), args); nothing)
sqlstr(s) = "'" * replace(String(s), "'" => "''") * "'"
"Run raw SQL inside Postgres, in the attached connection's current transaction."
pg_exec(con, sql) = x(con, "CALL postgres_execute('pg', $(sqlstr(sql)))")
"Run a read-only query inside Postgres (aggregates stay in Postgres)."
pg_query(con, sql) = q(con, "SELECT * FROM postgres_query('pg', $(sqlstr(sql)))")

const FP_COLS = "market_date, date_time_utc, bidding_zone, price_eur_mwh, prediction_made_utc, lead_days, " *
                "clearing_mode, code_version, input_mode, is_retro, reset_tag, retro_of_utc"
# naive-UTC TIMESTAMP (results DuckDB) → timestamptz (Postgres), session TimeZone = UTC
const FP_SELECT = "market_date, CAST(date_time_utc AS TIMESTAMPTZ), bidding_zone, price_eur_mwh, " *
                  "CAST(prediction_made_utc AS TIMESTAMPTZ), lead_days, clearing_mode, code_version, input_mode, " *
                  "is_retro, reset_tag, CAST(retro_of_utc AS TIMESTAMPTZ)"

"Postgres realized horizon (MAX UTC date of entsoe.actual_total_load), read once per transfer."
const _HORIZON = Ref{Union{Nothing,Date}}(nothing)
function pg_latest_actual_date(con)
    _HORIZON[] === nothing || return _HORIZON[]
    df = pg_query(con, "SELECT MAX((date_time_utc AT TIME ZONE 'UTC')::date) AS d FROM entsoe.actual_total_load")
    (isempty(df) || ismissing(df.d[1])) && error("entsoe.actual_total_load is empty in Postgres")
    return (_HORIZON[] = Date(df.d[1]))
end

function transfer_forecast_slice!(con, op_id, p)
    md = Date(p["market_date"]); lead = Int(p["lead_days"]); mode = String(p["input_mode"])
    is_retro = Bool(p["is_retro"]); alongside = Bool(p["alongside"]); supersede = Bool(p["supersede"])
    cv = Int(p["code_version"]); tag = p["reset_tag"]; zones = String.(p["zones"])
    slice = "market_date = \$1 AND lead_days = \$2 AND input_mode = \$3"
    key = Any[md, lead, mode]
    rows_sql = "SELECT $FP_SELECT FROM r.simulations.forecast_prices WHERE transfer_op_id = $op_id"
    n_rows = Int(q(con, "SELECT COUNT(*) AS n FROM r.simulations.forecast_prices WHERE transfer_op_id = \$1",
                   Any[op_id]).n[1])
    if !is_retro   # LIVE: the realized-data guards, re-checked against Postgres at transfer time
        assert_unrealized(md, pg_latest_actual_date(con))
        hrs = q(con, "SELECT date_time_utc AS h FROM r.simulations.forecast_prices WHERE transfer_op_id = \$1",
                Any[op_id]).h
        assert_hours_unrealized(DateTime.(hrs), DateTime(p["prediction_made_utc"]))
    end
    cnt(where, args=Any[]) = Int(q(con, "SELECT COUNT(*) AS n FROM pg.simulations.forecast_prices " *
                                        "WHERE $slice AND $where", vcat(key, args)).n[1])
    n_live = is_retro ? cnt("is_retro = false") : 0
    n_live_same_cv = alongside ? cnt("code_version = \$4 AND is_retro = false", Any[cv]) : 0
    plan = retro_write_plan(is_retro=is_retro, supersede=supersede, has_live=(n_live > 0),
                            alongside=alongside, has_live_same_cv=(n_live_same_cv > 0))
    string(plan) == p["plan"] || error("op $op_id ($md lead=$lead mode=$mode): the run decided " *
        "$(p["plan"]) but Postgres now gives $plan (live rows: $n_live) — refusing the whole transfer")
    if plan == :alongside
        x(con, "DELETE FROM pg.simulations.forecast_prices WHERE $slice AND is_retro = true AND reset_tag = \$4 " *
               "AND code_version = \$5", vcat(key, Any[tag, cv]))
    elseif plan == :supersede
        ins = q(con, "INSERT INTO pg.simulations.forecast_prices_pre_reset ($FP_COLS) " *
                     "SELECT $FP_COLS FROM pg.simulations.forecast_prices WHERE $slice AND is_retro = false", key)
        n_backed = Int(ins[1, 1])   # DuckDB returns the inserted row count
        n_backed == n_live || error("op $op_id: supersede backup mismatch (backed up $n_backed, $n_live live rows)")
        x(con, "DELETE FROM pg.simulations.forecast_prices WHERE $slice", key)
    elseif is_retro
        x(con, "DELETE FROM pg.simulations.forecast_prices WHERE $slice AND is_retro = true", key)
    else
        x(con, "DELETE FROM pg.simulations.forecast_prices WHERE $slice AND is_retro = false " *
               "AND bidding_zone IN (SELECT unnest(\$4))", vcat(key, Any[zones]))
    end
    x(con, "INSERT INTO pg.simulations.forecast_prices ($FP_COLS) $rows_sql")
    return "$(plan) $(n_rows) row(s)" * (plan == :supersede ? ", $n_live live row(s) backed up" : "")
end

"Stage `select_sql` as a real Postgres table (same transaction), run `apply_sql` inside Postgres, drop the stage."
function via_stage!(con, op_id, select_sql, apply_sql)
    st = "simulations.$(STAGE_PREFIX)_$(op_id)"
    x(con, "CREATE TABLE pg.$st AS $select_sql")
    pg_exec(con, replace(apply_sql, "{stage}" => st))
    pg_exec(con, "DROP TABLE $st")
    return nothing
end

function transfer_input_corrections!(con, op_id, p)
    n = Int(q(con, "SELECT COUNT(*) AS n FROM r.simulations.input_corrections WHERE transfer_op_id = \$1",
              Any[op_id]).n[1])
    n == 0 && return "0 row(s)"
    cols = "bidding_zone, target, date_time_utc, corrected_mw, model_tag"
    via_stage!(con, op_id,
        "SELECT bidding_zone, target, CAST(date_time_utc AS TIMESTAMPTZ) AS date_time_utc, corrected_mw, model_tag " *
        "FROM r.simulations.input_corrections WHERE transfer_op_id = $op_id",
        "INSERT INTO simulations.input_corrections ($cols) SELECT $cols FROM {stage} ON CONFLICT DO NOTHING")
    return "$n row(s) offered (ON CONFLICT DO NOTHING)"
end

"Register the op's score keys as a DuckDB view `k` (market_date, bidding_zone, lead_days, code_version, input_mode, is_retro)."
function score_keys!(con, p)
    ks = p["keys"]
    df = DataFrame(market_date=Date.([k["market_date"] for k in ks]), bidding_zone=String[k["bidding_zone"] for k in ks],
                   lead_days=Int[k["lead_days"] for k in ks], code_version=Int[k["code_version"] for k in ks],
                   input_mode=String[k["input_mode"] for k in ks], is_retro=Bool[k["is_retro"] for k in ks])
    try DuckDB.unregister_data_frame(con, "k") catch end
    DuckDB.register_data_frame(con, df, "k")
    return nrow(df)
end
const SCORE_JOIN = "JOIN k USING (market_date, bidding_zone, lead_days, code_version, input_mode, is_retro)"
const SCORE_PK = "market_date, bidding_zone, lead_days, code_version, input_mode, is_retro"
const SCORE_HOURLY = ["n_hours", "mae", "bias", "corr", "n_collapse_actual", "n_collapse_pred", "collapse_hits",
                      "collapse_false_alarms", "collapse_hit_rate", "collapse_false_alarm_rate"]
const SCORE_Q15 = [("n_q15", "INT"), ("mae_q15", "DOUBLE PRECISION"), ("bias_q15", "DOUBLE PRECISION"),
                   ("corr_q15", "DOUBLE PRECISION"), ("shape_floor_q15", "DOUBLE PRECISION"),
                   ("q15_forecast_res", "TEXT"), ("n_le0_q15_actual", "INT"), ("n_le0_q15_pred", "INT"),
                   ("le0_q15_hits", "INT")]

function transfer_score_upsert!(con, op_id, p)
    n = score_keys!(con, p)
    cols = join(SCORE_HOURLY, ", ")
    via_stage!(con, op_id,
        "SELECT $SCORE_PK, $cols, reset_tag FROM r.simulations.forecast_scores $SCORE_JOIN",
        "INSERT INTO simulations.forecast_scores ($SCORE_PK, $cols, reset_tag, scored_at) " *
        "SELECT $SCORE_PK, $cols, reset_tag, now() FROM {stage} " *
        "ON CONFLICT ($SCORE_PK) DO UPDATE SET " *
        join(("$c = EXCLUDED.$c" for c in SCORE_HOURLY), ", ") *
        ", is_retro = EXCLUDED.is_retro, reset_tag = EXCLUDED.reset_tag, scored_at = now()")
    return "$n key(s) upserted"
end

function transfer_score_q15!(con, op_id, p)
    have = Set(String.(pg_query(con, "SELECT column_name FROM information_schema.columns WHERE " *
        "table_schema = 'simulations' AND table_name = 'forecast_scores'").column_name))
    missing_cols = [(c, ty) for (c, ty) in SCORE_Q15 if !(c in have)]
    if !isempty(missing_cols)   # as ensure_q15_columns: catalog first, a short lock wait, inside this transaction
        pg_exec(con, "SET LOCAL lock_timeout = '5s'")
        pg_exec(con, "ALTER TABLE simulations.forecast_scores " *
                     join(("ADD COLUMN IF NOT EXISTS $c $ty" for (c, ty) in missing_cols), ", "))
    end
    n = score_keys!(con, p)
    cols = first.(SCORE_Q15)
    via_stage!(con, op_id,
        "SELECT $SCORE_PK, $(join(cols, ", ")) FROM r.simulations.forecast_scores $SCORE_JOIN",
        "UPDATE simulations.forecast_scores t SET " * join(("$c = s.$c" for c in cols), ", ") *
        " FROM {stage} s WHERE " * join(("t.$c = s.$c" for c in split(SCORE_PK, ", ")), " AND "))
    return "$n key(s) q15-updated" * (isempty(missing_cols) ? "" : " (added $(length(missing_cols)) column(s))")
end

const HANDLERS = Dict("forecast_slice" => transfer_forecast_slice!, "input_corrections" => transfer_input_corrections!,
                      "score_upsert" => transfer_score_upsert!, "score_q15" => transfer_score_q15!)

function main()
    o = parse_cli(ARGS)
    path = o["results_db"]
    isfile(path) || error("results DuckDB not found: $path")
    conn = strip(get(ENV, "ENERGY_CONN_STR", ""))
    isempty(conn) && !o["dry_run"] && error("ENERGY_CONN_STR is not set (the transfer's Postgres target)")
    con = DBInterface.connect(DuckDB.DB, ":memory:")
    try x(con, "SET TimeZone = 'UTC'") catch end   # needs ICU; without it DuckDB already treats TIMESTAMP as UTC
    x(con, "ATTACH $(sqlstr(path)) AS r (READ_WRITE)")
    has_ops = !isempty(q(con, "SELECT 1 FROM information_schema.tables WHERE table_catalog = 'r' " *
                              "AND table_schema = 'simulations' AND table_name = 'transfer_ops'"))
    ops = has_ops ? q(con, "SELECT op_id, kind, params FROM r.simulations.transfer_ops WHERE done_at IS NULL " *
                           "ORDER BY op_id") : DataFrame(op_id=Int[], kind=String[], params=String[])
    println("transfer_run_results: $(nrow(ops)) pending op(s) in $path" * (o["dry_run"] ? " (dry run)" : ""))
    for r in eachrow(ops)
        haskey(HANDLERS, r.kind) || error("op $(r.op_id): unknown kind $(r.kind)")
    end
    (isempty(ops) || o["dry_run"]) && (foreach(r -> println("  op $(r.op_id) $(r.kind) $(r.params)"), eachrow(ops)); return)
    Euphemia.attach_postgres!(con, conn; read_only=false)
    t0 = time()
    outcomes = Dict{Int,String}()
    x(con, "BEGIN TRANSACTION")
    try
        for r in eachrow(ops)
            outcomes[r.op_id] = HANDLERS[r.kind](con, r.op_id, JSON.parse(r.params))
            @printf("  op %d %-17s %s\n", r.op_id, r.kind, outcomes[r.op_id])
        end
        x(con, "COMMIT")
    catch
        try x(con, "ROLLBACK") catch end
        println("transfer FAILED — Postgres unchanged (one transaction); the ops stay pending")
        rethrow()
    end
    # Marks after the commit (a separate transaction: DuckDB writes one attached database per transaction).
    # A crash between the two leaves the ops pending; replaying them is idempotent (see the header).
    for (id, out) in outcomes
        x(con, "UPDATE r.simulations.transfer_ops SET done_at = now()::TIMESTAMP, outcome = \$1 WHERE op_id = \$2",
          Any[out, id])
    end
    @printf("transfer_run_results: %d op(s) committed to Postgres in %.1f s\n", length(outcomes), time() - t0)
end

main()
