# run_results.jl — the run-local results DuckDB for the forecast writers, and its transfer-op log
# (owner rule 2026-11-23: DuckDB between Postgres and Julia; Julia never writes Postgres except the one
# bulk transfer step). Included by ../dbutils.jl inside `module Euphemia`, after duckdb_store.jl.
#
# Under EUPHEMIA_DATA_STORE=duckdb a run reads its inputs from the filled run-local DuckDB and writes every
# `simulations.*` result into the writable results file (EUPHEMIA_RESULTS_DB, ATTACHed as `results_db`):
#   - energy_prices / optimization_runs / transmission_flows (duckdb_store.jl, unchanged);
#   - forecast_prices, forecast_prices_pre_reset, forecast_scores, input_corrections (this file).
# The fill seeds the last four with the slices the job reads back (no-clobber checks, scoring, cv32 deltas),
# so later steps of the same job read the state Postgres would have. Each writer applies its own slice
# semantics locally AND appends one row to `results_db.simulations.transfer_ops` (kind + slice keys/params as
# JSON; never row data). The rows it wrote carry that op's id in `transfer_op_id` (a local column, never sent).
# bin/transfer_run_results.jl replays the pending ops, in op_id order, against Postgres in ONE transaction,
# re-evaluating every guard there, then marks them done.

"Forecast-side result tables that live in the results DuckDB (reads and writes redirected to `results_db`)."
const RUN_RESULT_TABLES = ("forecast_prices", "forecast_prices_pre_reset", "forecast_scores", "input_corrections")

"""Columns the fill copies from Postgres into each run-result table (the Postgres column names; timestamptz
columns arrive as naive UTC `TIMESTAMP`, the extract convention). `transfer_op_id` is local only."""
const RUN_RESULT_COLUMNS = Dict(
    "forecast_prices" => ["id", "market_date", "date_time_utc", "bidding_zone", "price_eur_mwh",
        "prediction_made_utc", "lead_days", "clearing_mode", "code_version", "input_mode",
        "optimization_run_id", "created_at", "is_retro", "reset_tag", "retro_of_utc"],
    "forecast_prices_pre_reset" => ["backup_id", "market_date", "date_time_utc", "bidding_zone",
        "price_eur_mwh", "prediction_made_utc", "lead_days", "clearing_mode", "code_version", "input_mode",
        "is_retro", "reset_tag", "retro_of_utc", "superseded_at_utc"],
    "forecast_scores" => ["market_date", "bidding_zone", "lead_days", "code_version", "input_mode",
        "n_hours", "mae", "bias", "corr", "n_collapse_actual", "n_collapse_pred", "collapse_hits",
        "collapse_false_alarms", "collapse_hit_rate", "collapse_false_alarm_rate", "is_retro", "reset_tag",
        "scored_at", "n_q15", "mae_q15", "bias_q15", "corr_q15", "shape_floor_q15", "q15_forecast_res",
        "n_le0_q15_actual", "n_le0_q15_pred", "le0_q15_hits"],
    "input_corrections" => ["bidding_zone", "target", "date_time_utc", "corrected_mw", "model_tag"])

# DuckDB DDL. No UNIQUE/PRIMARY KEY on purpose: the writers delete-then-insert slices inside one DuckDB
# transaction, which DuckDB's eager constraint check rejects on re-inserted keys; uniqueness is the writers'
# job here (same keys as Postgres) and Postgres enforces its constraints at transfer.
const _RUN_RESULTS_DDL = [
    """CREATE TABLE IF NOT EXISTS results_db.simulations.forecast_prices (
        id BIGINT, market_date DATE NOT NULL, date_time_utc TIMESTAMP NOT NULL, bidding_zone VARCHAR NOT NULL,
        price_eur_mwh DOUBLE NOT NULL, prediction_made_utc TIMESTAMP NOT NULL, lead_days INTEGER NOT NULL,
        clearing_mode VARCHAR, code_version INTEGER NOT NULL, input_mode VARCHAR NOT NULL,
        optimization_run_id BIGINT, created_at TIMESTAMP, is_retro BOOLEAN NOT NULL, reset_tag VARCHAR,
        retro_of_utc TIMESTAMP, transfer_op_id BIGINT)""",
    """CREATE TABLE IF NOT EXISTS results_db.simulations.forecast_prices_pre_reset (
        backup_id BIGINT, market_date DATE NOT NULL, date_time_utc TIMESTAMP NOT NULL,
        bidding_zone VARCHAR NOT NULL, price_eur_mwh DOUBLE NOT NULL, prediction_made_utc TIMESTAMP NOT NULL,
        lead_days INTEGER NOT NULL, clearing_mode VARCHAR, code_version INTEGER NOT NULL,
        input_mode VARCHAR NOT NULL, is_retro BOOLEAN, reset_tag VARCHAR, retro_of_utc TIMESTAMP,
        superseded_at_utc TIMESTAMP, transfer_op_id BIGINT)""",
    """CREATE TABLE IF NOT EXISTS results_db.simulations.forecast_scores (
        market_date DATE NOT NULL, bidding_zone VARCHAR NOT NULL, lead_days INTEGER NOT NULL,
        code_version INTEGER NOT NULL, input_mode VARCHAR NOT NULL, n_hours INTEGER, mae DOUBLE, bias DOUBLE,
        corr DOUBLE, n_collapse_actual INTEGER, n_collapse_pred INTEGER, collapse_hits INTEGER,
        collapse_false_alarms INTEGER, collapse_hit_rate DOUBLE, collapse_false_alarm_rate DOUBLE,
        is_retro BOOLEAN NOT NULL, reset_tag VARCHAR, scored_at TIMESTAMP, n_q15 INTEGER, mae_q15 DOUBLE,
        bias_q15 DOUBLE, corr_q15 DOUBLE, shape_floor_q15 DOUBLE, q15_forecast_res VARCHAR,
        n_le0_q15_actual INTEGER, n_le0_q15_pred INTEGER, le0_q15_hits INTEGER, transfer_op_id BIGINT)""",
    """CREATE TABLE IF NOT EXISTS results_db.simulations.input_corrections (
        bidding_zone VARCHAR NOT NULL, target VARCHAR NOT NULL, date_time_utc TIMESTAMP NOT NULL,
        corrected_mw DOUBLE, model_tag VARCHAR, transfer_op_id BIGINT)""",
    "CREATE SEQUENCE IF NOT EXISTS results_db.simulations.transfer_ops_seq START 1",
    """CREATE TABLE IF NOT EXISTS results_db.simulations.transfer_ops (
        op_id BIGINT NOT NULL, kind VARCHAR NOT NULL, params VARCHAR NOT NULL,
        created_at TIMESTAMP NOT NULL, done_at TIMESTAMP, outcome VARCHAR)""",
]

"""
    ensure_run_results_tables!()

Create the forecast-side result tables and the transfer-op log in the writable results DuckDB
(`EUPHEMIA_RESULTS_DB`). Idempotent. Called by the writers, and by the fill before it seeds the read-back
slices (with `RUN_RESULT_COLUMNS`).
"""
function ensure_run_results_tables!()
    DATA_STORE[] === :duckdb || error("ensure_run_results_tables!: the results DuckDB needs EUPHEMIA_DATA_STORE=duckdb")
    _duckdb_assert_writable()
    for ddl in _RUN_RESULTS_DDL
        _results_exec(ddl)
    end
    return nothing
end

"`true` when result writes go to the run-local results DuckDB (and are replayed by the transfer step)."
results_to_duckdb() = DATA_STORE[] === :duckdb

"""
    log_transfer_op!(kind, params) -> op_id

Append one pending op to `results_db.simulations.transfer_ops`: its `kind` and the slice keys / parameters the
transfer needs (a `Dict` serialised as JSON; no row data). Returns the op id the writer stamps on its rows.
"""
function log_transfer_op!(kind::AbstractString, params::AbstractDict)
    ensure_run_results_tables!()
    id = Int64(_results_exec("SELECT nextval('results_db.simulations.transfer_ops_seq') AS id").id[1])
    _results_exec("INSERT INTO results_db.simulations.transfer_ops (op_id, kind, params, created_at) " *
                  "VALUES (\$1, \$2, \$3, now()::TIMESTAMP)", Any[id, String(kind), JSON.json(params)])
    return id
end

"Run `f()` inside one transaction on the results DuckDB (all of a writer's local statements, or none)."
function results_transaction(f)
    ensure_run_results_tables!()
    _results_exec("BEGIN TRANSACTION")
    try
        r = f()
        _results_exec("COMMIT")
        return r
    catch
        try _results_exec("ROLLBACK") catch end
        rethrow()
    end
end
