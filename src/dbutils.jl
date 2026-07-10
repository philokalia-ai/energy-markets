using LibPQ
using ConcurrentUtilities: ConcurrentUtilities, Pools
using Dates
using DuckDB   # also brings DBInterface into scope

# ============================================================================
# Data store configuration (Postgres | DuckDB)
# ============================================================================
#
# The library normally reads from the live Postgres `energy` database. For
# offline / portable work it can instead read from a self-contained DuckDB
# extract (see `bin/build_duckdb_extract.jl`) that mirrors the same
# `schema.table` names, with every timestamp stored as naive UTC. The DuckDB
# backend is READ-ONLY in v1: every write path (`save_*`, `ensure_*`, UC
# caching) warns once and no-ops.
#
# Select the backend either programmatically with `configure_data_store!` or
# via the environment at module init:
#   EUPHEMIA_DATA_STORE=duckdb  EUPHEMIA_DUCKDB_PATH=/path/to/extract.duckdb
# When DuckDB is selected via ENV the eager LibPQ pool is skipped entirely so
# the library works with no Postgres available at all.

const DATA_STORE = Ref{Symbol}(:postgres)
const DUCKDB_PATH = Ref{String}("")
# Open the extract with DuckDB's READ_ONLY access mode. DuckDB is single-writer,
# but any number of PROCESSES may share one file when every one of them opens it
# read-only — this is what enables day-level parallel reproduction
# (bin/reproduce.jl --workers): each worker opens the extract read-only, clears
# with save_to_db=false, and the coordinator persists the returned prices.
# Selected via configure_data_store!(read_only=true) or EUPHEMIA_DUCKDB_READONLY.
const DUCKDB_READ_ONLY = Ref{Bool}(false)

# Default location the auto-detector looks for the published public extract when
# no backend is chosen explicitly. Overridable via EUPHEMIA_DUCKDB_PATH.
const DEFAULT_PUBLIC_EXTRACT = "data/extracts/euphemia-public.duckdb"
const _DUCKDB_DB = Ref{Any}(nothing)
const _DUCKDB_CONN = Ref{Any}(nothing)
const _DUCKDB_LOCK = ReentrantLock()
const _DUCKDB_READONLY_WARNED = Ref{Bool}(false)

# Lazily open (and reuse) a single DuckDB connection, guarded by a lock.
function _duckdb_connection()
    lock(_DUCKDB_LOCK) do
        if _DUCKDB_CONN[] === nothing
            path = DUCKDB_PATH[]
            isfile(path) || error("DuckDB extract file not found: $path")
            db = DuckDB.DB(path; readonly=DUCKDB_READ_ONLY[])
            _DUCKDB_DB[] = db
            _DUCKDB_CONN[] = DBInterface.connect(db)
        end
        return _DUCKDB_CONN[]
    end
end

"""
    configure_data_store!(; backend::Symbol=:postgres, duckdb_path=nothing)

Select the data backend used by all `sql2df` queries.

- `backend=:postgres` (default): use the live Postgres connection pool.
- `backend=:duckdb`: read from a self-contained DuckDB extract at
  `duckdb_path` (the file must already exist). One DuckDB connection is
  opened lazily and reused for the process. The DuckDB backend is read-only:
  write paths warn once and no-op.

Returns the active `DATA_STORE[]` symbol.
"""
function configure_data_store!(; backend::Symbol=:postgres,
                               duckdb_path::Union{Nothing,String}=nothing,
                               read_only::Bool=false)
    backend in (:postgres, :duckdb) ||
        error("Invalid backend: $backend (must be :postgres or :duckdb)")

    if backend == :duckdb
        duckdb_path === nothing && error("duckdb_path is required for the :duckdb backend")
        isfile(duckdb_path) || error("DuckDB extract file not found: $duckdb_path")
        lock(_DUCKDB_LOCK) do
            # Drop a stale connection if the path OR access mode changed
            if _DUCKDB_CONN[] !== nothing &&
               (DUCKDB_PATH[] != duckdb_path || DUCKDB_READ_ONLY[] != read_only)
                try
                    DBInterface.close!(_DUCKDB_CONN[])
                catch
                end
                try
                    _DUCKDB_DB[] !== nothing && close(_DUCKDB_DB[])
                catch
                end
                _DUCKDB_CONN[] = nothing
                _DUCKDB_DB[] = nothing
                _RESULTS_ATTACHED[] = false
            end
            DUCKDB_PATH[] = duckdb_path
            DUCKDB_READ_ONLY[] = read_only
        end
        DATA_STORE[] = :duckdb
        _DUCKDB_READONLY_WARNED[] = false
        _duckdb_connection()  # open eagerly to validate the file
        @info "Data store: DuckDB$(read_only ? " (read-only shared)" : "") — $duckdb_path"
    else
        DATA_STORE[] = :postgres
        @info "Data store: PostgreSQL"
    end
    return DATA_STORE[]
end

"""
    _resolve_data_store(; data_store, duckdb_path, energy_conn_str, exists) -> Tuple

Pure decision logic for which backend `__init__` should select. Kept separate
from `__init__` so it can be unit-tested without opening any connection.

- `data_store`   = value of ENV["EUPHEMIA_DATA_STORE"] (may be "").
- `duckdb_path`  = value of ENV["EUPHEMIA_DUCKDB_PATH"] (may be "").
- `energy_conn_str` = value of ENV["ENERGY_CONN_STR"] (may be "").
- `exists(path)` = predicate telling whether a file exists (injected for tests;
  defaults to `isfile`).

Returns `(:duckdb, path)`, `(:postgres, "")`, or throws with actionable text.
Rules: an explicit `EUPHEMIA_DATA_STORE` always wins. When unset, auto-select
DuckDB if the default (or overridden) extract file exists, else Postgres if
ENERGY_CONN_STR is set, else error.
"""
function _resolve_data_store(; data_store::AbstractString,
                            duckdb_path::AbstractString,
                            energy_conn_str::AbstractString,
                            exists=isfile)
    store = lowercase(strip(data_store))
    default_path = isempty(duckdb_path) ? DEFAULT_PUBLIC_EXTRACT : duckdb_path
    if store == "duckdb"
        return (:duckdb, default_path)
    elseif store == "postgres"
        return (:postgres, "")
    elseif isempty(store)
        if exists(default_path)
            return (:duckdb, default_path)
        elseif !isempty(strip(energy_conn_str))
            return (:postgres, "")
        else
            error("No data store available. Either:\n" *
                  "  • download the public extract to $DEFAULT_PUBLIC_EXTRACT " *
                  "(or set EUPHEMIA_DUCKDB_PATH to its location), or\n" *
                  "  • set EUPHEMIA_DATA_STORE=duckdb with EUPHEMIA_DUCKDB_PATH=/path/to/extract.duckdb, or\n" *
                  "  • set ENERGY_CONN_STR for the live Postgres backend.\n" *
                  "See docs/reproducibility.md.")
        end
    else
        error("Invalid EUPHEMIA_DATA_STORE=$(data_store) (expected \"duckdb\" or \"postgres\").")
    end
end

# Our SQL is authored for Postgres; adapt the handful of dialect differences
# for DuckDB. The extract stores every timestamp as naive UTC, which is what
# makes stripping ` AT TIME ZONE 'UTC'` safe.
function _duckdb_rewrite(sql::AbstractString)
    s = String(sql)
    s = replace(s, " AT TIME ZONE 'UTC'" => "")
    # `col = ANY($n)`  -> `col IN (SELECT unnest($n))`
    s = replace(s, r"=\s*ANY\((\$\d+)\)" => s"IN (SELECT unnest(\1))")
    # `col <> ALL($n)` -> `col NOT IN (SELECT unnest($n))`
    s = replace(s, r"<>\s*ALL\((\$\d+)\)" => s"NOT IN (SELECT unnest(\1))")
    # to_char(x, 'YYYYMMDD-HH24MI') -> strftime(x, '%Y%m%d-%H%M') (same arg order)
    s = replace(s, "'YYYYMMDD-HH24MI'" => "'%Y%m%d-%H%M'")
    s = replace(s, "to_char(" => "strftime(")
    # get_generators' day-outage arrays use Postgres multi-arg table unnest,
    # which DuckDB does not support. DuckDB unnests multiple lists in one SELECT
    # in lockstep, so rewrite the FROM fragment to that form. Must run before the
    # single-unnest rule below (this pattern also contains `::text[]`).
    s = replace(s,
        r"unnest\((\$\d+)::text\[\],\s*(\$\d+)::float8\[\]\)\s*AS t\(asset_code, available_capacity_mw\)" =>
        s"(SELECT unnest(\1) AS asset_code, unnest(\2) AS available_capacity_mw) AS t")
    # Single-array unnest with a Postgres array cast -> bare unnest (the param is
    # already bound as a DuckDB list). e.g. stale_outage_override's $5::text[].
    s = replace(s, r"unnest\((\$\d+)::text\[\]\)" => s"unnest(\1)")
    # The three writable simulation-result tables do NOT live in the read-only
    # extract (its `simulations` schema carries only generator_inferred_parameters
    # and unit_firms). They live in a SEPARATE writable file ATTACHed as
    # `results_db` (see _ensure_results_attached). Redirect reads/writes of them to
    # that catalog so `save_*` persists offline and eval scripts read it back. The
    # extract's own simulations.* tables are left untouched.
    for t in ("energy_prices", "optimization_runs", "transmission_flows")
        s = replace(s, "simulations.$t" => "results_db.simulations.$t")
    end
    return s
end

function _duckdb_sql2df(sql, args)
    rewritten = _duckdb_rewrite(sql)
    con = _duckdb_connection()
    occursin("results_db.", rewritten) && _ensure_results_attached(con)
    lock(_DUCKDB_LOCK) do
        stmt = DBInterface.prepare(con, rewritten)
        try
            res = isempty(args) ? DBInterface.execute(stmt) :
                  DBInterface.execute(stmt, collect(args))
            return DataFrame(res)
        finally
            DBInterface.close!(stmt)
        end
    end
end

# Guard for write paths under the read-only DuckDB backend: warns once and
# tells the caller to no-op. Returns `true` when running on DuckDB.
#
# NOTE: this is now used ONLY for write paths with no offline equivalent — UC
# caching (`ensure_uc_results_tables`) and `ensure_indexes`. The three
# market-result writers (energy_prices / optimization_runs / transmission_flows)
# instead persist to a separate writable results database so the full pipeline
# (incl. save_to_db) and the eval scripts run end-to-end offline; see below.
function _duckdb_readonly_guard(fname::AbstractString)
    DATA_STORE[] == :duckdb || return false
    if !_DUCKDB_READONLY_WARNED[]
        @warn "DuckDB data store is read-only for source data (entsoe/yfinance) — skipping this write" first_call=fname
        _DUCKDB_READONLY_WARNED[] = true
    end
    return true
end

# ============================================================================
# Writable local results under the DuckDB backend
# ============================================================================
#
# The published extract stays READ-ONLY: source data (entsoe.*, yfinance.*) can
# never be written. Market RESULTS, however, must persist so the full pipeline
# (save_to_db=true) and the eval scripts run fully offline. They are routed to a
# SEPARATE local DuckDB file (default data/results.duckdb, override with env
# EUPHEMIA_RESULTS_DB) ATTACHed to the extract connection as `results_db`. The
# `_duckdb_rewrite` redirect above makes reads of `simulations.energy_prices`
# etc. resolve there transparently.
# NOTE: read from ENV in __init__ (not here) — top-level values are baked in at
# PRECOMPILE time, so an ENV read here would ignore the runtime environment.
const RESULTS_DB_PATH = Ref{String}("data/results.duckdb")
const _RESULTS_ATTACHED = Ref{Bool}(false)

# ATTACH the results DB (created on first attach) and create the result tables
# IF NOT EXISTS. Idempotent; guarded by the DuckDB lock. `con` must be the
# extract connection returned by _duckdb_connection().
# Fail loudly when a result write is attempted in read-only shared mode.
function _duckdb_assert_writable()
    DUCKDB_READ_ONLY[] && error(
        "The DuckDB data store is open in read-only shared mode " *
        "(EUPHEMIA_DUCKDB_READONLY / configure_data_store!(read_only=true)); " *
        "results cannot be written from this process. Parallel workers must run " *
        "with save_to_db=false — the coordinator persists the returned prices.")
    return nothing
end

function _ensure_results_attached(con)
    lock(_DUCKDB_LOCK) do
        _RESULTS_ATTACHED[] && return
        DUCKDB_READ_ONLY[] && _duckdb_assert_writable()
        path = RESULTS_DB_PATH[]
        dir = dirname(path)
        !isempty(dir) && !isdir(dir) && mkpath(dir)
        DBInterface.execute(con, "ATTACH IF NOT EXISTS '$(path)' AS results_db")
        DBInterface.execute(con, "CREATE SCHEMA IF NOT EXISTS results_db.simulations")
        DBInterface.execute(con, """
            CREATE TABLE IF NOT EXISTS results_db.simulations.energy_prices (
                date_time_utc TIMESTAMP, resolution_code VARCHAR, bidding_zone VARCHAR,
                contract_type VARCHAR, price_eur_mwh DOUBLE, currency VARCHAR,
                order_method VARCHAR, clearing_mode VARCHAR, optimization_run_id BIGINT,
                code_version INTEGER, update_time_utc TIMESTAMP)""")
        DBInterface.execute(con,
            "CREATE SEQUENCE IF NOT EXISTS results_db.simulations.optimization_runs_id_seq START 1")
        DBInterface.execute(con, """
            CREATE TABLE IF NOT EXISTS results_db.simulations.optimization_runs (
                id BIGINT, bidding_zone VARCHAR, optimization_date DATE, order_method VARCHAR,
                model_type VARCHAR, optimizer VARCHAR, status VARCHAR, objective_value DOUBLE,
                solve_time_seconds DOUBLE, num_orders INTEGER, num_price_periods INTEGER,
                error_message VARCHAR, code_version INTEGER, created_at TIMESTAMP,
                is_iterative BOOLEAN, total_time_seconds DOUBLE, iterations INTEGER,
                converged BOOLEAN, final_price_change DOUBLE, final_flow_change_pct DOUBLE)""")
        DBInterface.execute(con, """
            CREATE TABLE IF NOT EXISTS results_db.simulations.transmission_flows (
                date_time_utc TIMESTAMP, source_zone VARCHAR, sink_zone VARCHAR,
                flow_mw DOUBLE, code_version INTEGER, update_time_utc TIMESTAMP)""")
        _RESULTS_ATTACHED[] = true
    end
    return nothing
end

# Run a statement against the extract connection (results_db attached). Returns a
# DataFrame (empty for non-SELECT). No dialect rewrite — callers write DuckDB SQL.
function _results_exec(sql::AbstractString, params=[])
    con = _duckdb_connection()
    _ensure_results_attached(con)
    lock(_DUCKDB_LOCK) do
        stmt = DBInterface.prepare(con, sql)
        try
            res = isempty(params) ? DBInterface.execute(stmt) :
                  DBInterface.execute(stmt, collect(params))
            return DataFrame(res)
        finally
            DBInterface.close!(stmt)
        end
    end
end

# Bulk-insert a DataFrame into results_db.simulations.<table> (columns must match
# the table definition order). Registers the frame and INSERT ... SELECT — fast.
function _results_insert_df(df::DataFrame, table::AbstractString)
    isempty(df) && return 0
    con = _duckdb_connection()
    _ensure_results_attached(con)
    lock(_DUCKDB_LOCK) do
        view = "_results_stage"
        DuckDB.register_data_frame(con, df, view)
        try
            DBInterface.execute(con,
                "INSERT INTO results_db.simulations.$table SELECT * FROM $view")
        finally
            DuckDB.unregister_data_frame(con, view)
        end
    end
    return nrow(df)
end

# --- DuckDB implementations of the three market-result writers ---

function _duckdb_save_energy_prices(prices::Dict{String,Float64}, bidding_zone::String,
                                    day::Date, order_method::Symbol; clearing_mode::String,
                                    optimization_run_id::Union{Integer,Nothing})
    isempty(prices) && (@warn "No prices to save for $bidding_zone on $day"; return 0)
    num_periods = length(prices)
    resolution_code = num_periods == 96 ? "15M" : num_periods == 48 ? "30M" :
                      num_periods == 24 ? "1H" : "1H"
    order_method_str = string(order_method)
    opt_run_id = optimization_run_id === nothing ? missing : Int64(optimization_run_id)
    update_time = now(UTC)

    dts = DateTime[]; res = String[]; bz = String[]; ct = String[]; px = Float64[]
    cur = String[]; om = String[]; cm = String[]; ori = Union{Int64,Missing}[]
    cv = Int[]; ut = DateTime[]
    for (timeslot, price) in prices
        local dt
        try
            dt = DateTime(timeslot, dateformat"yyyymmdd-HHMM")
        catch e
            @error "Failed to parse timeslot '$timeslot': $e"; continue
        end
        push!(dts, dt); push!(res, resolution_code); push!(bz, bidding_zone)
        push!(ct, "Day-Ahead"); push!(px, price); push!(cur, "EUR")
        push!(om, order_method_str); push!(cm, clearing_mode); push!(ori, opt_run_id)
        push!(cv, ENERGY_PRICES_CODE_VERSION); push!(ut, update_time)
    end
    isempty(dts) && (@error "No valid records to insert"; return 0)

    # Replace any existing rows for this (zone, day, method, mode, version).
    _results_exec("""
        DELETE FROM results_db.simulations.energy_prices
        WHERE bidding_zone = \$1 AND CAST(date_time_utc AS DATE) = \$2
          AND order_method = \$3 AND clearing_mode = \$4 AND code_version = \$5
        """, Any[bidding_zone, day, order_method_str, clearing_mode, ENERGY_PRICES_CODE_VERSION])

    df = DataFrame(date_time_utc=dts, resolution_code=res, bidding_zone=bz,
                   contract_type=ct, price_eur_mwh=px, currency=cur,
                   order_method=om, clearing_mode=cm, optimization_run_id=ori,
                   code_version=cv, update_time_utc=ut)
    n = _results_insert_df(df, "energy_prices")
    @info "Saved $n energy price records to results_db for $bidding_zone on $day (order_method: $order_method, clearing_mode: $clearing_mode)"
    return n
end

function _duckdb_save_optimization_run(bidding_zone::String, date::Date, order_method::Symbol,
        model_type::Symbol, optimizer::String, status::Symbol; objective_value, solve_time_seconds,
        num_orders, num_price_periods, error_message, code_version::Int, is_iterative::Bool,
        total_time_seconds, iterations, converged, final_price_change, final_flow_change_pct)
    _duckdb_assert_writable()  # fail loudly (not silently) in read-only shared mode
    try
        # Upsert-by-replace: same config re-run replaces its row.
        _results_exec("""
            DELETE FROM results_db.simulations.optimization_runs
            WHERE bidding_zone = \$1 AND optimization_date = \$2 AND order_method = \$3
              AND model_type = \$4 AND code_version = \$5 AND optimizer = \$6
            """, Any[bidding_zone, date, string(order_method), string(model_type), code_version, optimizer])
        run_id = Int64(_results_exec("SELECT nextval('results_db.simulations.optimization_runs_id_seq') AS id").id[1])
        m(x) = x === nothing ? missing : x
        df = DataFrame(id=Int64[run_id], bidding_zone=[bidding_zone], optimization_date=[date],
            order_method=[string(order_method)], model_type=[string(model_type)], optimizer=[optimizer],
            status=[string(status)], objective_value=Union{Float64,Missing}[m(objective_value)],
            solve_time_seconds=Union{Float64,Missing}[m(solve_time_seconds)],
            num_orders=Union{Int,Missing}[m(num_orders)], num_price_periods=Union{Int,Missing}[m(num_price_periods)],
            error_message=Union{String,Missing}[m(error_message)], code_version=[code_version],
            created_at=[now(UTC)], is_iterative=[is_iterative],
            total_time_seconds=Union{Float64,Missing}[m(total_time_seconds)],
            iterations=Union{Int,Missing}[m(iterations)], converged=Union{Bool,Missing}[m(converged)],
            final_price_change=Union{Float64,Missing}[m(final_price_change)],
            final_flow_change_pct=Union{Float64,Missing}[m(final_flow_change_pct)])
        _results_insert_df(df, "optimization_runs")
        @info "Saved optimization run to results_db: $bidding_zone on $date ($status) id=$run_id"
        return run_id
    catch e
        @error "Failed to save optimization run to results_db for $bidding_zone on $date: $e"
        return nothing
    end
end

function _duckdb_save_transmission_flows(flows::Dict{String,Dict{String,Float64}}, date::Date;
                                         code_version::Int)
    isempty(flows) && (@warn "No transmission flows to save"; return 0)
    update_time = now(UTC)
    dts = DateTime[]; src = String[]; snk = String[]; fmw = Float64[]; cv = Int[]; ut = DateTime[]
    for (flow_id, period_flows) in flows
        parts = split(flow_id, "_to_")
        length(parts) != 2 && (@warn "Invalid flow_id format: $flow_id"; continue)
        for (period, flow_mw) in period_flows
            local dt
            if length(period) >= 13 && contains(period, "-")
                dt = DateTime(period, dateformat"yyyymmdd-HHMM")
            else
                dt = DateTime(date) + Hour(parse(Int, period) - 1)
            end
            push!(dts, dt); push!(src, String(parts[1])); push!(snk, String(parts[2]))
            push!(fmw, flow_mw); push!(cv, code_version); push!(ut, update_time)
        end
    end
    isempty(dts) && return 0
    _results_exec("""
        DELETE FROM results_db.simulations.transmission_flows
        WHERE CAST(date_time_utc AS DATE) = \$1 AND code_version = \$2
        """, Any[date, code_version])
    df = DataFrame(date_time_utc=dts, source_zone=src, sink_zone=snk,
                   flow_mw=fmw, code_version=cv, update_time_utc=ut)
    n = _results_insert_df(df, "transmission_flows")
    @info "Saved $n transmission flow records to results_db"
    return n
end

# Version of the pricing/cost model that produced stored energy_prices rows.
# Bump when the model changes incompatibly (e.g. v2 -> v3: stylized
# 2.2x-markup marginal costs replaced by SRMC/TTF-based costs, July 2026;
# v3 -> v7: multi-zone artifact fixes — tight MIP gap, component-wise price
# reconstruction, border-aware net-import exclusion, July 2026; 4-6 were
# already taken by legacy uc_based experiment rows; v7 -> v8: daily EUA
# carbon prices from yfinance.eua_co2 instead of yearly averages, July 2026;
# v8 -> v9: multi-zone nodal-balance flow signs fixed — flows were
# physically mirrored, capping every border by the opposite direction's
# ATC, July 2026; v9 -> v10: crisis-year honesty — fleet-truthing derate
# of baseload types to trailing p95 (phantom 2022 lignite) and absolute
# instead of proportional must-run below-cost discount, July 2026) so new
# results are never mixed with — or skipped because of — old rows. Each
# version is one selectable "Run" in the Metabase counterfactual
# dashboard.
const ENERGY_PRICES_CODE_VERSION = 14

const poolsize = 5
cnxpool = Pools.Pool{LibPQ.Connection}(poolsize)

function cnxisok(cnx::LibPQ.Connection)
    return LibPQ.status(cnx) == LibPQ.libpq_c.CONNECTION_OK
end

function newconnection()
    conn_str = get(ENV, "ENERGY_CONN_STR", "")

    # Add PostgreSQL connection parameters to improve connection reliability
    # These parameters work with both URL and key=value connection string formats
    if !contains(conn_str, "connect_timeout")
        # Detect connection string format and append parameters appropriately
        if contains(conn_str, "postgresql://") || contains(conn_str, "postgres://")
            # URL format: add query parameters
            separator = contains(conn_str, "?") ? "&" : "?"
            conn_str = conn_str * separator * "connect_timeout=30&keepalives_idle=300&keepalives_interval=30&keepalives_count=3"
        else
            # Key=value format: add space-separated parameters
            conn_str = conn_str * " connect_timeout=30 keepalives_idle=300 keepalives_interval=30 keepalives_count=3"
        end
    end

    cnx = LibPQ.Connection(conn_str)
    !isdefined(LibPQ, :setnonblocking) && return cnx
    LibPQ.setnonblocking(cnx) && return cnx
    error("Could not set connection to nonblocking")
end

function preinit_pool(poolsize=poolsize)
    cnxs = [Base.acquire(newconnection, cnxpool; isvalid=cnxisok) for i in 1:poolsize]
    # They all need to exist at the same time;
    map(cnxs) do connection
        Base.release(cnxpool, connection)
    end
    @info "preinit $poolsize done"
end

function withdb(f)
    connection = Base.acquire(newconnection, cnxpool; isvalid=cnxisok)
    result = f(connection)

    !cnxisok(connection) && LibPQ.reset!(connection)
    Base.release(cnxpool, connection)

    return result
end

function sql2df(sql, args=[])
    if DATA_STORE[] == :duckdb
        return _duckdb_sql2df(sql, args)
    end
    return withdb() do cnx
        result = LibPQ.async_execute(cnx, sql, args)
        return DataFrame(fetch(result))
    end
end

"""
    sql2df_with_retry(sql, args=[]; max_retries=3, retry_delay=2.0)

Execute SQL query with automatic retry on connection failures.
"""
function sql2df_with_retry(sql, args=[]; max_retries=3, retry_delay=2.0)
    last_error = nothing

    for attempt in 1:max_retries
        try
            return sql2df(sql, args)
        catch e
            last_error = e

            # Check if it's a connection-related error
            if isa(e, LibPQ.Errors.JLConnectionError) ||
               (isa(e, Exception) && occursin("connection", string(e)))

                if attempt < max_retries
                    @warn "Database connection failed (attempt $attempt/$max_retries): $e"
                    @info "Retrying in $retry_delay seconds..."
                    sleep(retry_delay)

                    # Try to reset the connection pool
                    try
                        preinit_pool(poolsize)
                    catch pool_error
                        @warn "Failed to reinitialize connection pool: $pool_error"
                    end

                    continue
                else
                    @error "Database connection failed after $max_retries attempts: $e"
                end
            else
                # Non-connection error, don't retry
                break
            end
        end
    end

    # If we get here, all retries failed
    throw(last_error)
end

"""
    ensure_energy_prices_table()

Creates the simulations schema and energy_prices table if they don't exist.
Assumes connection is already to the 'energy' database.
"""
function ensure_energy_prices_table()
    _duckdb_readonly_guard("ensure_energy_prices_table") && return nothing
    withdb() do cnx
        # Create schema if not exists (energy is the database, simulations is the schema)
        LibPQ.execute(cnx, "CREATE SCHEMA IF NOT EXISTS simulations")

        # Create table if not exists
        create_table_sql = """
        CREATE TABLE IF NOT EXISTS simulations.energy_prices (
            id SERIAL PRIMARY KEY,
            date_time_utc TIMESTAMP NOT NULL,
            resolution_code VARCHAR(10) NOT NULL,
            bidding_zone VARCHAR(20) NOT NULL,
            contract_type VARCHAR(50) NOT NULL,
            price_eur_mwh NUMERIC(10,2) NOT NULL,
            currency VARCHAR(3) NOT NULL,
            order_method VARCHAR(20) NOT NULL,
            clearing_mode VARCHAR(20) NOT NULL DEFAULT 'single_zone',
            optimization_run_id INTEGER,
            code_version INTEGER NOT NULL,
            update_time_utc TIMESTAMP NOT NULL,
            UNIQUE(date_time_utc, bidding_zone, contract_type, order_method, clearing_mode, code_version)
        )
        """

        LibPQ.execute(cnx, create_table_sql)

        # Add clearing_mode column if it doesn't exist (for existing tables)
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'simulations'
                    AND table_name = 'energy_prices'
                    AND column_name = 'clearing_mode'
                ) THEN
                    ALTER TABLE simulations.energy_prices
                    ADD COLUMN clearing_mode VARCHAR(20) NOT NULL DEFAULT 'single_zone';
                END IF;
            END \$\$;
        """)

        # Add optimization_run_id column if it doesn't exist (for existing tables)
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'simulations'
                    AND table_name = 'energy_prices'
                    AND column_name = 'optimization_run_id'
                ) THEN
                    ALTER TABLE simulations.energy_prices
                    ADD COLUMN optimization_run_id INTEGER;
                END IF;
            END \$\$;
        """)

        # Migrate unique constraint to include clearing_mode (for databases created before clearing_mode was added)
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                -- Check if the old constraint (without clearing_mode) exists
                IF EXISTS (
                    SELECT 1 FROM pg_indexes
                    WHERE schemaname = 'simulations'
                    AND tablename = 'energy_prices'
                    AND indexdef LIKE '%date_time_utc, bidding_zone, contract_type, order_method, code_version)%'
                    AND indexdef NOT LIKE '%clearing_mode%'
                ) THEN
                    -- Drop the old constraint
                    ALTER TABLE simulations.energy_prices
                    DROP CONSTRAINT energy_prices_date_time_utc_bidding_zone_contract_type_orde_key;
                    -- Add the new constraint with clearing_mode
                    ALTER TABLE simulations.energy_prices
                    ADD CONSTRAINT energy_prices_unique_record
                    UNIQUE (date_time_utc, bidding_zone, contract_type, order_method, clearing_mode, code_version);
                END IF;
            END \$\$;
        """)

        # Create useful indexes
        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_energy_prices_datetime_zone 
ON simulations.energy_prices (date_time_utc, bidding_zone)
"""
        )

        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_energy_prices_zone_contract
ON simulations.energy_prices (bidding_zone, contract_type, date_time_utc)
"""
        )

        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_energy_prices_clearing_mode
ON simulations.energy_prices (clearing_mode, date_time_utc)
"""
        )

        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_energy_prices_optimization_run_id
ON simulations.energy_prices (optimization_run_id)
"""
        )

        # Create optimization runs table for tracking all optimization attempts
        create_optimization_runs_sql = """
        CREATE TABLE IF NOT EXISTS simulations.optimization_runs (
            id SERIAL PRIMARY KEY,
            bidding_zone VARCHAR(20) NOT NULL,
            optimization_date DATE NOT NULL,
            order_method VARCHAR(20) NOT NULL,
            model_type VARCHAR(20) NOT NULL,
            optimizer VARCHAR(20) NOT NULL,
            status VARCHAR(20) NOT NULL,
            objective_value NUMERIC(15,2),
            solve_time_seconds NUMERIC(10,3),
            num_orders INTEGER,
            num_price_periods INTEGER,
            error_message TEXT,
            code_version INTEGER NOT NULL,
            created_at TIMESTAMP NOT NULL,
            -- Iterative optimization metadata (added for UC-MPCC iterative runs)
            is_iterative BOOLEAN DEFAULT FALSE,
            total_time_seconds NUMERIC(12,3),
            iterations INTEGER,
            converged BOOLEAN,
            final_price_change NUMERIC(10,3),
            final_flow_change_pct NUMERIC(10,3),
            UNIQUE(bidding_zone, optimization_date, order_method, model_type, code_version, optimizer)
        )
        """

        LibPQ.execute(cnx, create_optimization_runs_sql)

        # Add iterative columns to existing tables (migration for existing installations)
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                -- Add is_iterative column if it doesn't exist
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'is_iterative') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN is_iterative BOOLEAN DEFAULT FALSE;
                END IF;
                -- Add total_time_seconds column if it doesn't exist
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'total_time_seconds') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN total_time_seconds NUMERIC(12,3);
                END IF;
                -- Add iterations column if it doesn't exist
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'iterations') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN iterations INTEGER;
                END IF;
                -- Add converged column if it doesn't exist
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'converged') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN converged BOOLEAN;
                END IF;
                -- Add final_price_change column if it doesn't exist
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'final_price_change') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN final_price_change NUMERIC(10,3);
                END IF;
                -- Add final_flow_change_pct column if it doesn't exist
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'optimization_runs'
                               AND column_name = 'final_flow_change_pct') THEN
                    ALTER TABLE simulations.optimization_runs ADD COLUMN final_flow_change_pct NUMERIC(10,3);
                END IF;
            END \$\$;
        """)

        # Create useful indexes for optimization runs
        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_optimization_runs_zone_date 
ON simulations.optimization_runs (bidding_zone, optimization_date)
"""
        )

        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_optimization_runs_status
ON simulations.optimization_runs (status, optimization_date)
"""
        )

        # Add foreign key constraint if it doesn't exist
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.table_constraints
                    WHERE constraint_schema = 'simulations'
                    AND table_name = 'energy_prices'
                    AND constraint_name = 'fk_energy_prices_optimization_run'
                ) THEN
                    ALTER TABLE simulations.energy_prices
                    ADD CONSTRAINT fk_energy_prices_optimization_run
                    FOREIGN KEY (optimization_run_id)
                    REFERENCES simulations.optimization_runs(id)
                    ON DELETE SET NULL;
                END IF;
            END \$\$;
        """)
    end

    @info "Energy prices and optimization runs tables schema verified/created"
end

"""
    save_energy_prices(prices::Dict{String,Float64}, bidding_zone::String, day::Date, order_method::Symbol;
                       clearing_mode::String="single_zone", optimization_run_id::Union{Integer,Nothing}=nothing,
                       batch_size::Int=100, create_schema::Bool=true)

Save energy prices to the database in the simulations.energy_prices table.
Creates the schema and table if they don't exist (when create_schema=true).
Assumes connection is already to the 'energy' database.

# Arguments
- `prices`: Dictionary with timeslot keys ("YYYYMMDD-HHMM") and price values in EUR/MWh
- `bidding_zone`: Bidding zone code (e.g., "GR", "AL")
- `day`: Date of the prices
- `order_method`: Method used (:uc_based or :alternative)
- `clearing_mode`: Market clearing mode ("single_zone" or "multi_zone", default: "single_zone")
- `optimization_run_id`: Foreign key to simulations.optimization_runs (default: nothing)
- `batch_size`: Number of records to insert per batch (default: 100)
- `create_schema`: Whether to create schema/table if missing (default: true)

# Table Schema
- `date_time_utc`: Timestamp in UTC
- `resolution_code`: Temporal resolution (15M, 30M, 1H)
- `bidding_zone`: Bidding zone code
- `contract_type`: Always "Day-Ahead" for now
- `price_eur_mwh`: Energy price in EUR/MWh
- `currency`: Always "EUR" for now
- `update_time_utc`: Timestamp when record was inserted
- `order_method`: Method used to generate prices
- `clearing_mode`: Market clearing mode (single_zone or multi_zone)
- `optimization_run_id`: Foreign key to the optimization run that generated these prices
- `code_version`: Version code (current: 3 — bumped when the cost/pricing model changes incompatibly)
"""
function save_energy_prices(prices::Dict{String,Float64}, bidding_zone::String, day::Date, order_method::Symbol;
                            clearing_mode::String="single_zone", optimization_run_id::Union{Integer,Nothing}=nothing,
                            batch_size::Int=100, create_schema::Bool=true)
    if DATA_STORE[] == :duckdb
        return _duckdb_save_energy_prices(prices, bidding_zone, day, order_method;
            clearing_mode=clearing_mode, optimization_run_id=optimization_run_id)
    end
    if isempty(prices)
        @warn "No prices to save for $bidding_zone on $day"
        return 0
    end

    # Create schema and table if requested
    if create_schema
        ensure_energy_prices_table()
    end

    # Detect resolution from number of periods
    num_periods = length(prices)
    resolution_code = if num_periods == 96
        "15M"
    elseif num_periods == 48
        "30M"
    elseif num_periods == 24
        "1H"
    else
        @warn "Unexpected number of periods: $num_periods, defaulting to 1H"
        "1H"
    end

    # Prepare data for batch insertion
    # Tuple: (date_time_utc, resolution_code, bidding_zone, contract_type, price_eur_mwh, currency, order_method, clearing_mode, optimization_run_id, code_version, update_time_utc)
    records = Vector{Tuple{DateTime,String,String,String,Float64,String,String,String,Union{Int,Missing},Int,DateTime}}()
    sizehint!(records, length(prices))  # Pre-allocate for efficiency
    update_time = now(UTC)
    order_method_str = string(order_method)  # Convert once
    opt_run_id = optimization_run_id === nothing ? missing : optimization_run_id

    for (timeslot, price) in prices
        # Parse timeslot "YYYYMMDD-HHMM" to DateTime using DateFormat for efficiency
        try
            # More efficient: use DateFormat instead of manual parsing
            date_time_utc = DateTime(timeslot, dateformat"yyyymmdd-HHMM")

            push!(records, (
                date_time_utc,
                resolution_code,
                bidding_zone,
                "Day-Ahead",
                price,
                "EUR",
                order_method_str,
                clearing_mode,
                opt_run_id,
                ENERGY_PRICES_CODE_VERSION,
                update_time
            ))
        catch e
            @error "Failed to parse timeslot '$timeslot': $e"
            continue
        end
    end

    if isempty(records)
        @error "No valid records to insert"
        return 0
    end

    # Delete existing records for this bidding_zone/date/order_method/clearing_mode/code_version before inserting
    # This ensures we replace incomplete data from previous failed runs
    try
        withdb() do cnx
            delete_sql = """
            DELETE FROM simulations.energy_prices
            WHERE bidding_zone = \$1
              AND DATE(date_time_utc) = \$2
              AND order_method = \$3
              AND clearing_mode = \$4
              AND code_version = \$5
            """
            LibPQ.execute(cnx, delete_sql, [bidding_zone, day, order_method_str, clearing_mode, ENERGY_PRICES_CODE_VERSION])
            @info "Deleted existing price records for $bidding_zone on $day (order_method: $order_method, clearing_mode: $clearing_mode) if any existed"
        end
    catch delete_error
        @error "Failed to delete existing records: $delete_error"
        rethrow(delete_error)
    end

    # Insert in batches
    total_inserted = 0

    sql = """
    INSERT INTO simulations.energy_prices
    (date_time_utc, resolution_code, bidding_zone, contract_type, price_eur_mwh, currency, order_method, clearing_mode, optimization_run_id, code_version, update_time_utc)
    VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11)
    """

    for batch_start in 1:batch_size:length(records)
        batch_end = min(batch_start + batch_size - 1, length(records))
        batch = records[batch_start:batch_end]

        try
            withdb() do cnx
                # Use transaction for batch
                LibPQ.execute(cnx, "BEGIN")

                try
                    for record in batch
                        LibPQ.execute(cnx, sql, collect(record))
                    end
                    LibPQ.execute(cnx, "COMMIT")
                    total_inserted += length(batch)
                    @info "Inserted batch $(div(batch_start-1, batch_size)+1): $(length(batch)) records"
                catch batch_error
                    LibPQ.execute(cnx, "ROLLBACK")
                    @error "Batch insertion failed: $batch_error"
                    rethrow(batch_error)
                end
            end
        catch e
            @error "Database error in batch $(div(batch_start-1, batch_size)+1): $e"
            # Continue with next batch or rethrow based on requirements
            rethrow(e)
        end
    end

    @info "Successfully saved $total_inserted energy price records for $bidding_zone on $day (order_method: $order_method, clearing_mode: $clearing_mode)"
    return total_inserted
end

"""
    save_optimization_run(bidding_zone::String, date::Date, order_method::Symbol, model_type::Symbol,
                          optimizer::String, status::Symbol; kwargs...) -> Union{Int, Nothing}

Save optimization run metadata to track all optimization attempts (successful and failed).

# Arguments
- `bidding_zone`: Bidding zone code (e.g., "GR", "AL", or "MULTI_ZONE" for multi-zone runs)
- `date`: Date of the optimization
- `order_method`: Method used (:uc_based or :alternative)
- `model_type`: Model used (:mpcc, :mpcc_multi_zone, :mpcc_iterative, etc.)
- `optimizer`: Solver used ("highs", "gurobi", "cplex")
- `status`: Optimization status (:optimal, :infeasible, :time_limit, etc.)
- `objective_value`: Final objective value (nothing for failed runs)
- `solve_time_seconds`: Solution time in seconds (for iterative runs, this is the final MPCC solve time)
- `num_orders`: Number of orders in the order book
- `num_price_periods`: Number of price periods generated (nothing for failed runs)
- `error_message`: Error details for failed runs (nothing for successful runs)
- `code_version`: Version code (default: 4)
- `create_schema`: Whether to create schema/table if missing (default: true)

## Iterative optimization metadata (for UC-MPCC iterative runs)
- `is_iterative`: Whether this was an iterative optimization run (default: false)
- `total_time_seconds`: Total time for all iterations including UC solves (nothing for non-iterative)
- `iterations`: Number of iterations performed (nothing for non-iterative)
- `converged`: Whether the iterative algorithm converged (nothing for non-iterative)
- `final_price_change`: Final max price change in €/MWh at convergence/termination
- `final_flow_change_pct`: Final flow change percentage at convergence/termination

# Returns
- `Int`: The ID of the inserted optimization run record, or `nothing` if insertion failed
"""
function save_optimization_run(bidding_zone::String, date::Date, order_method::Symbol, model_type::Symbol,
    optimizer::String, status::Symbol;
    objective_value=nothing,
    solve_time_seconds=nothing,
    num_orders=nothing,
    num_price_periods=nothing,
    error_message=nothing,
    code_version::Int=4,
    create_schema::Bool=true,
    # Iterative optimization metadata
    is_iterative::Bool=false,
    total_time_seconds=nothing,
    iterations=nothing,
    converged=nothing,
    final_price_change=nothing,
    final_flow_change_pct=nothing)

    if DATA_STORE[] == :duckdb
        return _duckdb_save_optimization_run(bidding_zone, date, order_method, model_type,
            optimizer, status; objective_value=objective_value, solve_time_seconds=solve_time_seconds,
            num_orders=num_orders, num_price_periods=num_price_periods, error_message=error_message,
            code_version=code_version, is_iterative=is_iterative, total_time_seconds=total_time_seconds,
            iterations=iterations, converged=converged, final_price_change=final_price_change,
            final_flow_change_pct=final_flow_change_pct)
    end

    # Create schema and table if requested
    if create_schema
        ensure_energy_prices_table()  # This now creates both tables
    end

    try
        run_id = withdb() do cnx
            # Upsert: re-running the same configuration (e.g. a backfill after
            # a model fix) replaces the run record instead of raising a
            # UniqueViolation. The thrown violation used to abort the whole
            # save mid-transaction and could poison the pooled connection.
            sql = """
            INSERT INTO simulations.optimization_runs
            (bidding_zone, optimization_date, order_method, model_type, optimizer, status,
             objective_value, solve_time_seconds, num_orders, num_price_periods, error_message,
             code_version, created_at,
             is_iterative, total_time_seconds, iterations, converged, final_price_change, final_flow_change_pct)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, \$13,
                    \$14, \$15, \$16, \$17, \$18, \$19)
            ON CONFLICT (bidding_zone, optimization_date, order_method, model_type, code_version, optimizer)
            DO UPDATE SET
                status = EXCLUDED.status,
                objective_value = EXCLUDED.objective_value,
                solve_time_seconds = EXCLUDED.solve_time_seconds,
                num_orders = EXCLUDED.num_orders,
                num_price_periods = EXCLUDED.num_price_periods,
                error_message = EXCLUDED.error_message,
                created_at = EXCLUDED.created_at,
                is_iterative = EXCLUDED.is_iterative,
                total_time_seconds = EXCLUDED.total_time_seconds,
                iterations = EXCLUDED.iterations,
                converged = EXCLUDED.converged,
                final_price_change = EXCLUDED.final_price_change,
                final_flow_change_pct = EXCLUDED.final_flow_change_pct
            RETURNING id
            """

            result = LibPQ.execute(cnx, sql, [
                bidding_zone,
                date,
                string(order_method),
                string(model_type),
                optimizer,
                string(status),
                objective_value === nothing ? missing : objective_value,
                solve_time_seconds === nothing ? missing : solve_time_seconds,
                num_orders === nothing ? missing : num_orders,
                num_price_periods === nothing ? missing : num_price_periods,
                error_message === nothing ? missing : error_message,
                code_version,
                now(UTC),
                is_iterative,
                total_time_seconds === nothing ? missing : total_time_seconds,
                iterations === nothing ? missing : iterations,
                converged === nothing ? missing : converged,
                final_price_change === nothing ? missing : final_price_change,
                final_flow_change_pct === nothing ? missing : final_flow_change_pct
            ])

            # Get the returned ID
            df = DataFrame(result)
            return df.id[1]
        end

        @info "Saved optimization run: $bidding_zone on $date ($status) with id=$run_id"
        return run_id

    catch e
        @error "Failed to save optimization run for $bidding_zone on $date: $e"
        return nothing
    end
end

"""
    ensure_transmission_flows_table()

Creates the simulations.transmission_flows table if it doesn't exist.
Used to store cross-border transmission flow results from multi-zone market clearing.
"""
function ensure_transmission_flows_table()
    _duckdb_readonly_guard("ensure_transmission_flows_table") && return nothing
    withdb() do cnx
        create_table_sql = """
        CREATE TABLE IF NOT EXISTS simulations.transmission_flows (
            id SERIAL PRIMARY KEY,
            date_time_utc TIMESTAMP NOT NULL,
            source_zone VARCHAR(20) NOT NULL,
            sink_zone VARCHAR(20) NOT NULL,
            flow_mw NUMERIC(10,2) NOT NULL,
            code_version INTEGER NOT NULL,
            update_time_utc TIMESTAMP NOT NULL,
            UNIQUE(date_time_utc, source_zone, sink_zone, code_version)
        )
        """

        LibPQ.execute(cnx, create_table_sql)

        # Create useful indexes
        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_transmission_flows_datetime
ON simulations.transmission_flows (date_time_utc)
"""
        )

        LibPQ.execute(
            cnx,
            """
CREATE INDEX IF NOT EXISTS idx_transmission_flows_zones
ON simulations.transmission_flows (source_zone, sink_zone, date_time_utc)
"""
        )
    end

    @info "Transmission flows table schema verified/created"
end

"""
    save_transmission_flows(flows::Dict{String,Dict{String,Float64}}, date::Date;
                           code_version::Int=4, create_schema::Bool=true)

Save transmission flow results to the database in the simulations.transmission_flows table.

# Arguments
- `flows`: Dictionary with flow_id keys ("SOURCE_to_SINK") and inner Dict of period → MW values
- `date`: Date of the optimization
- `code_version`: Version code (default: 4)
- `create_schema`: Whether to create table if missing (default: true)

# Returns
- Number of records inserted
"""
function save_transmission_flows(flows::Dict{String,Dict{String,Float64}}, date::Date;
                                 code_version::Int=4, create_schema::Bool=true)
    if DATA_STORE[] == :duckdb
        return _duckdb_save_transmission_flows(flows, date; code_version=code_version)
    end
    if isempty(flows)
        @warn "No transmission flows to save"
        return 0
    end

    # Create table if requested
    if create_schema
        ensure_transmission_flows_table()
    end

    update_time = now(UTC)
    total_inserted = 0

    sql = """
    INSERT INTO simulations.transmission_flows
    (date_time_utc, source_zone, sink_zone, flow_mw, code_version, update_time_utc)
    VALUES (\$1, \$2, \$3, \$4, \$5, \$6)
    ON CONFLICT (date_time_utc, source_zone, sink_zone, code_version)
    DO UPDATE SET flow_mw = EXCLUDED.flow_mw, update_time_utc = EXCLUDED.update_time_utc
    """

    try
        withdb() do cnx
            LibPQ.execute(cnx, "BEGIN")

            try
                for (flow_id, period_flows) in flows
                    # Parse flow_id: "SOURCE_to_SINK"
                    parts = split(flow_id, "_to_")
                    if length(parts) != 2
                        @warn "Invalid flow_id format: $flow_id (expected SOURCE_to_SINK)"
                        continue
                    end
                    source_zone = parts[1]
                    sink_zone = parts[2]

                    for (period, flow_mw) in period_flows
                        # Parse period: "YYYYMMDD-HHMM" or hourly "1"-"24"
                        if length(period) >= 13 && contains(period, "-")
                            # Parse timeslot format "YYYYMMDD-HHMM"
                            date_time_utc = DateTime(period, dateformat"yyyymmdd-HHMM")
                        else
                            # Parse hourly format "1"-"24"
                            hour = parse(Int, period) - 1  # Convert 1-24 to 0-23
                            date_time_utc = DateTime(date) + Hour(hour)
                        end

                        LibPQ.execute(cnx, sql, [
                            date_time_utc,
                            source_zone,
                            sink_zone,
                            flow_mw,
                            code_version,
                            update_time
                        ])
                        total_inserted += 1
                    end
                end

                LibPQ.execute(cnx, "COMMIT")
                @info "Successfully saved $total_inserted transmission flow records"

            catch batch_error
                LibPQ.execute(cnx, "ROLLBACK")
                @error "Transmission flow insertion failed: $batch_error"
                rethrow(batch_error)
            end
        end
    catch e
        @error "Database error saving transmission flows: $e"
        rethrow(e)
    end

    return total_inserted
end

"""
    ensure_uc_results_tables()

Creates the simulations.uc_results, simulations.uc_generation, and simulations.uc_net_demand tables
if they don't exist. Used to cache Unit Commitment optimization results.
"""
function ensure_uc_results_tables()
    _duckdb_readonly_guard("ensure_uc_results_tables") && return nothing
    withdb() do cnx
        # Create schema if not exists
        LibPQ.execute(cnx, "CREATE SCHEMA IF NOT EXISTS simulations")

        # Create uc_results summary table
        create_uc_results_sql = """
        CREATE TABLE IF NOT EXISTS simulations.uc_results (
            id SERIAL PRIMARY KEY,
            bidding_zone VARCHAR(20) NOT NULL,
            market_date DATE NOT NULL,
            status VARCHAR(30) NOT NULL,
            solver VARCHAR(20) NOT NULL,
            resolution_minutes INTEGER NOT NULL,
            num_generators INTEGER NOT NULL,
            num_periods INTEGER NOT NULL,
            total_cost NUMERIC(15,2),
            production_cost NUMERIC(15,2),
            startup_cost NUMERIC(15,2),
            noload_cost NUMERIC(15,2),
            hot_startups INTEGER DEFAULT 0,
            warm_startups INTEGER DEFAULT 0,
            cold_startups INTEGER DEFAULT 0,
            mip_gap NUMERIC(6,4) DEFAULT 0.01,
            time_limit_seconds NUMERIC(10,2) DEFAULT 600.0,
            code_version INTEGER NOT NULL DEFAULT 4,
            created_at TIMESTAMP NOT NULL DEFAULT NOW(),
            UNIQUE(bidding_zone, market_date, code_version)
        )
        """
        LibPQ.execute(cnx, create_uc_results_sql)

        # Create uc_generation detail table
        create_uc_generation_sql = """
        CREATE TABLE IF NOT EXISTS simulations.uc_generation (
            id SERIAL PRIMARY KEY,
            uc_result_id INTEGER NOT NULL REFERENCES simulations.uc_results(id) ON DELETE CASCADE,
            generator_code VARCHAR(50) NOT NULL,
            generator_idx INTEGER NOT NULL,
            period_idx INTEGER NOT NULL,
            time_slot_utc TIMESTAMP NOT NULL,
            generation_mw NUMERIC(10,2) NOT NULL,
            commitment INTEGER NOT NULL,
            startup INTEGER NOT NULL,
            UNIQUE(uc_result_id, generator_code, period_idx)
        )
        """
        LibPQ.execute(cnx, create_uc_generation_sql)

        # Create uc_net_demand table
        create_uc_net_demand_sql = """
        CREATE TABLE IF NOT EXISTS simulations.uc_net_demand (
            id SERIAL PRIMARY KEY,
            uc_result_id INTEGER NOT NULL REFERENCES simulations.uc_results(id) ON DELETE CASCADE,
            period_idx INTEGER NOT NULL,
            time_slot_utc TIMESTAMP NOT NULL,
            net_demand_mw NUMERIC(10,2) NOT NULL,
            renewable_generation_mw NUMERIC(10,2),
            UNIQUE(uc_result_id, period_idx)
        )
        """
        LibPQ.execute(cnx, create_uc_net_demand_sql)

        # Create indexes for efficient queries
        LibPQ.execute(cnx, """
            CREATE INDEX IF NOT EXISTS idx_uc_results_zone_date
            ON simulations.uc_results (bidding_zone, market_date)
        """)

        LibPQ.execute(cnx, """
            CREATE INDEX IF NOT EXISTS idx_uc_results_status
            ON simulations.uc_results (status)
        """)

        LibPQ.execute(cnx, """
            CREATE INDEX IF NOT EXISTS idx_uc_generation_result_id
            ON simulations.uc_generation (uc_result_id)
        """)

        LibPQ.execute(cnx, """
            CREATE INDEX IF NOT EXISTS idx_uc_generation_generator
            ON simulations.uc_generation (generator_code)
        """)

        LibPQ.execute(cnx, """
            CREATE INDEX IF NOT EXISTS idx_uc_net_demand_result_id
            ON simulations.uc_net_demand (uc_result_id)
        """)

        # Add curtailment and excess columns (schema migration for existing tables)
        # Using DO block to conditionally add columns if they don't exist
        LibPQ.execute(cnx, """
            DO \$\$
            BEGIN
                -- Add curtailment columns to uc_results summary table
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_results'
                               AND column_name = 'total_curtailment_mwh') THEN
                    ALTER TABLE simulations.uc_results ADD COLUMN total_curtailment_mwh NUMERIC(12,2) DEFAULT 0;
                END IF;

                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_results'
                               AND column_name = 'curtailment_cost') THEN
                    ALTER TABLE simulations.uc_results ADD COLUMN curtailment_cost NUMERIC(12,2) DEFAULT 0;
                END IF;

                -- Add excess generation columns to uc_results summary table
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_results'
                               AND column_name = 'total_excess_mwh') THEN
                    ALTER TABLE simulations.uc_results ADD COLUMN total_excess_mwh NUMERIC(12,2) DEFAULT 0;
                END IF;

                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_results'
                               AND column_name = 'excess_cost') THEN
                    ALTER TABLE simulations.uc_results ADD COLUMN excess_cost NUMERIC(15,2) DEFAULT 0;
                END IF;

                -- Add curtailment column to uc_net_demand table
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_net_demand'
                               AND column_name = 'curtailment_mw') THEN
                    ALTER TABLE simulations.uc_net_demand ADD COLUMN curtailment_mw NUMERIC(10,2) DEFAULT 0;
                END IF;

                -- Add excess column to uc_net_demand table
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_net_demand'
                               AND column_name = 'excess_mw') THEN
                    ALTER TABLE simulations.uc_net_demand ADD COLUMN excess_mw NUMERIC(10,2) DEFAULT 0;
                END IF;

                -- Add shortage (load shedding) columns to uc_results summary table
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_results'
                               AND column_name = 'total_shortage_mwh') THEN
                    ALTER TABLE simulations.uc_results ADD COLUMN total_shortage_mwh NUMERIC(12,2) DEFAULT 0;
                END IF;

                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_results'
                               AND column_name = 'shortage_cost') THEN
                    ALTER TABLE simulations.uc_results ADD COLUMN shortage_cost NUMERIC(15,2) DEFAULT 0;
                END IF;

                -- Add shortage column to uc_net_demand table
                IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                               WHERE table_schema = 'simulations'
                               AND table_name = 'uc_net_demand'
                               AND column_name = 'shortage_mw') THEN
                    ALTER TABLE simulations.uc_net_demand ADD COLUMN shortage_mw NUMERIC(10,2) DEFAULT 0;
                END IF;
            END \$\$;
        """)
    end

    @info "UC results tables schema verified/created"
end

"""
    ensure_indexes()

Create indexes on ENTSOE tables to speed up common queries.
This function is idempotent (safe to run multiple times).

Indexes are created with CONCURRENTLY to avoid locking tables during creation.
First run may take 30-60 minutes for large tables. Subsequent runs are instant.

# Example
```julia
using Euphemia
Euphemia.ensure_indexes()  # Run once after DB setup, or when queries are slow
```
"""
function ensure_indexes()
    _duckdb_readonly_guard("ensure_indexes") && return nothing
    @info "Ensuring indexes on ENTSOE tables..."

    withdb() do cnx
        # Index for parameter inference and initial conditions queries
        # Table: 54 GB, 260M rows - queries by generator_code + date range
        @info "Creating index on actual_generation_output_per_generation_unit (this may take 30-60 min first time)..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_actual_gen_unit_date
            ON entsoe.actual_generation_output_per_generation_unit
            (generation_unit_code, date_time_utc);
        """)

        # Index for outage/unavailability filtering in get_generators()
        # Table: 4.4 GB, 9.5M rows - queries by asset_code + date range
        @info "Creating index on unavailability_of_production_and_generation_units..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_unavail_asset_date
            ON entsoe.unavailability_of_production_and_generation_units
            (asset_code, start_outage_utc);
        """)

        # Indexes for get_generators()'s per-zone unit lookup. The table has NO
        # indexes, so both the main query's `area_map_code = $1` filter and the
        # recent-generation CTE's unit-code subquery seq-scanned it (~280 ms each,
        # 2-3x per zone). area_map_code drives the zone filter; generation_unit_code
        # serves the DISTINCT-ON dedup / code lookups.
        @info "Creating indexes on production_and_generation_units..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_prod_gen_units_area
            ON entsoe.production_and_generation_units (area_map_code);
        """)
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_prod_gen_units_gen_code
            ON entsoe.production_and_generation_units (generation_unit_code);
        """)

        # Index for hydro availability / per-type generation queries
        # Table: 23 GB - queries by zone + production_type + date range
        @info "Creating index on aggregated_generation_per_type..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_agg_gen_type_zone_date
            ON entsoe.aggregated_generation_per_type
            (area_map_code, production_type, date_time_utc);
        """)

        # Index for actual DAM price lookups (eval harness, Metabase
        # sim-vs-actual dashboard). Table: ~6.5M rows, ETL-populated
        @info "Creating index on energy_prices (actuals)..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_entsoe_energy_prices_zone_contract_time
            ON entsoe.energy_prices
            (map_code, contract_type, date_time_utc);
        """)

        # Indexes for the merit-order book creation queries — these four
        # tables are ETL-populated with no indexes, so every zone-day book
        # build seq-scanned ~29 GB (loads, RES forecast, net imports, ATC)
        @info "Creating index on day_ahead_total_load_forecast..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_load_fcst_zone_time
            ON entsoe.day_ahead_total_load_forecast (area_map_code, date_time_utc);
        """)
        @info "Creating index on generation_forecasts_for_wind_and_solar..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_res_fcst_zone_time
            ON entsoe.generation_forecasts_for_wind_and_solar (area_map_code, date_time_utc);
        """)
        @info "Creating indexes on physical_flows..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_physical_flows_in_time
            ON entsoe.physical_flows (in_area_map_code, date_time_utc);
        """)
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_physical_flows_out_time
            ON entsoe.physical_flows (out_area_map_code, date_time_utc);
        """)
        @info "Creating index on offered_transfer_capacities_implicit..."
        LibPQ.execute(cnx, """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_atc_borders_time
            ON entsoe.offered_transfer_capacities_implicit (out_map_code, in_map_code, date_time_utc);
        """)

        # Add more indexes here as needed:
        # - generation_forecasts_for_wind_and_solar (zone, date)
        # - day_ahead_total_load_forecast (zone, date)
        # - offered_transfer_capacities_implicit (zone pairs, date)
    end

    @info "Indexes ensured successfully"
end
