# duckdb_store.jl — DuckDB data-store backend: lazy lock-guarded connection, SQL dialect rewrite, prepared-statement cache, read-only guard, and the results.duckdb (ATTACHed) market-result writers.
# Included by ../dbutils.jl inside `module Euphemia` (definition order preserved).

const DATA_STORE = Ref{Symbol}(:postgres)
const DUCKDB_PATH = Ref{String}("")
# Open the extract with DuckDB's READ_ONLY access mode. DuckDB is single-writer,
# but any number of PROCESSES may share one file when every one of them opens it
# read-only — this is what enables day-level parallel reproduction
# (bin/reproduce.jl --workers): each worker opens the extract read-only, clears
# with save_to_db=false, and the coordinator persists the returned prices.
# Selected via configure_data_store!(read_only=true) or EUPHEMIA_DUCKDB_READONLY.
const DUCKDB_READ_ONLY = Ref{Bool}(false)

# When the source extract is opened read-only (DUCKDB_READ_ONLY) the pipelined
# backfill coordinator STILL needs to persist market results — they go to the
# SEPARATE writable `results_db` file, never to the source. This flag opts that
# coordinator into result writes while keeping the source read-only: the
# `results_db` ATTACH is issued READ_WRITE and `_duckdb_assert_writable()` permits
# the write. Parallel worker processes leave it false, so their accidental writes
# still fail loudly (they must run save_to_db=false). Set via
# configure_data_store!(read_only=true, results_writable=true).
const DUCKDB_RESULTS_WRITABLE = Ref{Bool}(false)

# Default location the auto-detector looks for the published public extract when
# no backend is chosen explicitly. Overridable via EUPHEMIA_DUCKDB_PATH.
const DEFAULT_PUBLIC_EXTRACT = "data/extracts/euphemia-public.duckdb"
const _DUCKDB_DB = Ref{Any}(nothing)
const _DUCKDB_CONN = Ref{Any}(nothing)
const _DUCKDB_LOCK = ReentrantLock()
const _DUCKDB_READONLY_WARNED = Ref{Bool}(false)
# Per-connection prepared-statement cache, keyed by the (already dialect-
# rewritten) SQL string. DuckDB re-parses/re-plans on every DBInterface.prepare,
# and a 39-zone day book issues ~300 small queries drawn from a tiny fixed set
# of SQL shapes, so caching the compiled statements removes that repeated
# planning. Cleared whenever the connection is dropped/reopened (the statements
# belong to the old connection). Guarded by _DUCKDB_LOCK.
const _DUCKDB_STMT_CACHE = Dict{String,Any}()

# Drop the cached connection, db handle and prepared statements. Caller must
# hold _DUCKDB_LOCK.
function _duckdb_drop_connection!()
    empty!(_DUCKDB_STMT_CACHE)
    if _DUCKDB_CONN[] !== nothing
        try
            DBInterface.close!(_DUCKDB_CONN[])
        catch
        end
    end
    if _DUCKDB_DB[] !== nothing
        try
            close(_DUCKDB_DB[])
        catch
        end
    end
    _DUCKDB_CONN[] = nothing
    _DUCKDB_DB[] = nothing
    _FILL_GUARD[] = nothing
    _RESULTS_ATTACHED[] = false
    _READBACK_SEEDS[] = nothing
    return nothing
end

# Apply per-connection engine settings sized for the current process, so that N
# parallel reproduce/backfill worker processes do not each grab all cores and
# most of RAM (which oversubscribes the machine N-fold — thread thrashing and
# OOM under `--workers`). The concurrency hint is the number of processes that
# will run DuckDB queries at once; wired from reproduce.jl's --workers (env
# EUPHEMIA_DUCKDB_NPROCS_HINT) and defaulting to 1 (a lone process may use the
# whole box). All three are env-overridable. Every SET is best-effort so an
# unsupported option never breaks opening the extract.
function _duckdb_apply_settings!(con, path::AbstractString)
    hp = tryparse(Int, get(ENV, "EUPHEMIA_DUCKDB_NPROCS_HINT", "1"))
    nprocs_hint = max(1, hp === nothing ? 1 : hp)
    # threads
    threads_env = get(ENV, "EUPHEMIA_DUCKDB_THREADS", "")
    threads = isempty(threads_env) ? max(1, Sys.CPU_THREADS ÷ nprocs_hint) :
              max(1, something(tryparse(Int, threads_env), 1))
    try
        DBInterface.execute(con, "SET threads = $threads")
    catch e
        @debug "DuckDB SET threads failed" exception=e
    end
    # memory_limit: total physical RAM × 0.6 ÷ nprocs_hint (GB), env-overridable.
    mem_env = get(ENV, "EUPHEMIA_DUCKDB_MEMORY", "")
    if !isempty(mem_env)
        try
            DBInterface.execute(con, "SET memory_limit = '$mem_env'")
        catch e
            @debug "DuckDB SET memory_limit failed" exception=e
        end
    else
        gb = max(1.0, (Sys.total_memory() / 1e9) * 0.6 / nprocs_hint)
        try
            DBInterface.execute(con, "SET memory_limit = '$(round(gb, digits=1))GB'")
        catch e
            @debug "DuckDB SET memory_limit failed" exception=e
        end
    end
    # temp_directory: DuckDB's spill workspace. Keep it under the repo data dir
    # (next to the extract, on /home), NEVER /tmp or / — the user's disk-space
    # rule. Env-overridable.
    tmp = get(ENV, "EUPHEMIA_DUCKDB_TEMP", "")
    if isempty(tmp)
        base = dirname(abspath(path))
        tmp = joinpath(isempty(base) ? "." : base, ".duckdb_query_tmp")
    end
    try
        !isdir(tmp) && mkpath(tmp)
        DBInterface.execute(con, "SET temp_directory = '$tmp'")
    catch e
        @debug "DuckDB SET temp_directory failed" exception=e
    end
    return nothing
end

# Lazily open (and reuse) a single DuckDB connection, guarded by a lock.
function _duckdb_connection()
    lock(_DUCKDB_LOCK) do
        if _DUCKDB_CONN[] === nothing
            path = DUCKDB_PATH[]
            isfile(path) || error("DuckDB extract file not found: $path")
            db = DuckDB.DB(path; readonly=DUCKDB_READ_ONLY[])
            con = DBInterface.connect(db)
            _duckdb_apply_settings!(con, path)
            _DUCKDB_DB[] = db
            _DUCKDB_CONN[] = con
            _FILL_GUARD[] = _load_fill_guard(con)   # strict mode for run-local fills
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
                               read_only::Bool=false,
                               results_writable::Bool=false)
    backend in (:postgres, :duckdb) ||
        error("Invalid backend: $backend (must be :postgres or :duckdb)")

    if backend == :duckdb
        duckdb_path === nothing && error("duckdb_path is required for the :duckdb backend")
        isfile(duckdb_path) || error("DuckDB extract file not found: $duckdb_path")
        lock(_DUCKDB_LOCK) do
            # Drop a stale connection if the path OR access mode changed
            if _DUCKDB_CONN[] !== nothing &&
               (DUCKDB_PATH[] != duckdb_path || DUCKDB_READ_ONLY[] != read_only)
                _duckdb_drop_connection!()
            elseif _DUCKDB_CONN[] !== nothing && _RESULTS_ATTACHED[] &&
                   DUCKDB_RESULTS_WRITABLE[] != results_writable
                # The results file's access mode follows results_writable: a
                # surviving READ_WRITE attachment would keep the writer lock
                # after the flag is restored to false (and a READ_ONLY one
                # would refuse writes after it is set). Detach; the next access
                # re-attaches lazily in the right mode.
                try
                    DBInterface.execute(_DUCKDB_CONN[], "DETACH results_db")
                catch e
                    @debug "DETACH results_db failed — reopening the connection" exception = e
                    _duckdb_drop_connection!()
                end
                _RESULTS_ATTACHED[] = false
                _READBACK_SEEDS[] = nothing
            end
            DUCKDB_PATH[] = duckdb_path
            DUCKDB_READ_ONLY[] = read_only
            DUCKDB_RESULTS_WRITABLE[] = results_writable
        end
        DATA_STORE[] = :duckdb
        _DUCKDB_READONLY_WARNED[] = false
        _duckdb_connection()  # open eagerly to validate the file
        mode = read_only ? (results_writable ? " (read-only source, writable results)" :
                            " (read-only shared)") : ""
        @info "Data store: DuckDB$(mode) — $duckdb_path"
    else
        DATA_STORE[] = :postgres
        DUCKDB_RESULTS_WRITABLE[] = false
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
    # The forecast-side results (run_results.jl) live there too: the fill seeds the slices a job reads back
    # and the writers apply their slices locally, so reads see the state Postgres would have. Whole-word
    # match (forecast_prices must not catch forecast_prices_pre_reset), never twice.
    # input_corrections is an INPUT on an extract (the cv32 corrections it carries) and a
    # read-back table only in a run-local fill (the fill seeds it into results_db, the job
    # appends): redirect it only when the inputs DB is a fill, or extract runs (reproduce,
    # research, the identity rigs) lose the corrections and IT-Sardinia/Sicily prices move.
    # The forecast tables are read-backs too: redirected only for a fill (an extract has none;
    # it reads them exactly as main does). A write statement keeps the full redirect in both
    # modes, so a plain-named write can only ever land in results_db (the transfer source);
    # the DuckDB writers name results_db.simulations.* explicitly anyway.
    is_write = occursin(r"^\s*(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|MERGE|COPY|TRUNCATE)\b"i, s)
    if _FILL_GUARD[] === nothing && !is_write
        return s
    end
    tabs = (is_write || RESULTS_READBACK[] === :results) ?
        "forecast_prices_pre_reset|forecast_prices|forecast_scores|input_corrections" :
        "forecast_prices_pre_reset|forecast_prices|forecast_scores"
    s = replace(s, Regex("(?<![\\w.])simulations\\.($tabs)\\b") => s"results_db.simulations.\1")
    return s
end

# ---------------------------------------------------------------------------
# Strict read guard for run-local fills (owner rule: a read that the fill did not
# cover must fail loudly, never come back empty and never fall back to Postgres).
# A DuckDB that carries `_fill.windows` (written by fill_run_duckdb) is strict:
#   (1) every schema.table a query reads must be in the manifest;
#   (2) every Date/DateTime parameter and every TIMESTAMP '...' literal must lie in
#       a filled [lo, hi) window of each windowed table the query reads.
# SQL-internal offsets (`$1::date - 366`) are covered by the manifest's declared
# lookbacks; the identity runs prove that coverage. results_db.* is not guarded.
# ---------------------------------------------------------------------------
const _FILL_GUARD = Ref{Any}(nothing)

"A read under a run-local fill that the fill does not cover (fail loudly; never fall back)."
struct FillGuardError <: Exception
    msg::String
end
Base.showerror(io::IO, e::FillGuardError) = print(io, "FillGuardError: ", e.msg)
"Inside a `catch`: let a FillGuardError through every soft fallback."
_rethrow_fill_guard(e) = e isa FillGuardError ? throw(e) : nothing
"True when the open inputs DB is a run-local fill (carries _fill.windows)."
_in_fill() = _FILL_GUARD[] !== nothing

# Where read-back tables come from under a fill, decided explicitly per process role
# (EUPHEMIA_RESULTS_READBACK, read in __init__): :results for single-process jobs and the
# pipeline coordinator (they attach results_db and must see their own writes: the daily
# forecast emits cv32 corrections, then clears); :inputs for the pipelined book workers, which
# cannot attach the results DB the coordinator holds read-write and read the fill-time copy in
# inputs.duckdb (record/backfill runs emit no corrections, so it equals the seed).
const RESULTS_READBACK = Ref{Symbol}(:results)

function _results_readback_role(v::AbstractString)
    v = lowercase(strip(v))
    v in ("", "results") && return :results
    v == "inputs" && return :inputs
    error("EUPHEMIA_RESULTS_READBACK=$(v): expected results | inputs")
end

# Read-back tables a fill seeds into the results DB, with the windows seeded (results_db._fill.seeds,
# written by seed_run_results!). Under a fill a read of one of them must find its seed: a results DB
# filled without it (or a pre-marker fill) raises instead of reading an empty table.
const _READBACK_TABLES = ("forecast_prices", "forecast_scores", "input_corrections")
const _READBACK_WINDOWED = ("input_corrections",)   # its readers' parameters are delivery times
const _READBACK_SEEDS = Ref{Any}(nothing)

function _load_readback_seeds(con)
    has = !isempty(collect(DBInterface.execute(con,
        "SELECT 1 FROM duckdb_tables() WHERE database_name = 'results_db' AND schema_name = '_fill' AND table_name = 'seeds'")))
    seeds = Dict{String,Vector{Tuple{Dates.DateTime,Dates.DateTime}}}()
    has || return seeds
    for r in DBInterface.execute(con, "SELECT table_name, lo, hi FROM results_db._fill.seeds")
        push!(get!(seeds, String(r.table_name), Tuple{Dates.DateTime,Dates.DateTime}[]),
              (Dates.DateTime(r.lo), Dates.DateTime(r.hi)))
    end
    return seeds
end

"""
    mark_results_seeded!(tables; lo=1900-01-01, hi=2999-12-31)

Record read-back seeds in the attached results DB, as `seed_run_results!` does (tests and tools
that build a results DB by hand under `mark_run_local_fill!`)."""
function mark_results_seeded!(tables; lo=Dates.Date(1900, 1, 1), hi=Dates.Date(2999, 12, 31))
    _results_exec("CREATE SCHEMA IF NOT EXISTS results_db._fill")
    _results_exec("CREATE TABLE IF NOT EXISTS results_db._fill.seeds (table_name VARCHAR, lo DATE, hi DATE, n_rows BIGINT)")
    for t in tables
        _results_exec("INSERT INTO results_db._fill.seeds VALUES (\$1, \$2, \$3, 0)", Any[String(t), lo, hi])
    end
    lock(() -> (_READBACK_SEEDS[] = nothing), _DUCKDB_LOCK)
    return nothing
end

function _readback_check(con, sql::AbstractString, args)
    tabs = unique(m.captures[1] for m in eachmatch(r"results_db\.simulations\.([a-z_]+)\b", sql))
    tabs = [t for t in tabs if t in _READBACK_TABLES]
    isempty(tabs) && return nothing
    seeds = lock(_DUCKDB_LOCK) do
        _READBACK_SEEDS[] === nothing && (_READBACK_SEEDS[] = _load_readback_seeds(con))
        _READBACK_SEEDS[]
    end
    stamps = Dates.DateTime[]
    for a in (args === nothing ? () : args)
        a isa Dates.Date && push!(stamps, Dates.DateTime(a))
        a isa Dates.DateTime && push!(stamps, a)
    end
    for t in tabs
        haskey(seeds, t) || throw(FillGuardError("fill guard: read-back of simulations.$t, but the results DB " *
            "holds no seed of it (fill ran with --seed-results false, or before seed markers): re-run the fill"))
        t in _READBACK_WINDOWED || continue
        wins = seeds[t]
        for ts in stamps
            any(w -> w[1] <= ts < w[2] || w[1] == ts == w[2], wins) ||
                throw(FillGuardError("fill guard: read-back of simulations.$t at $ts is outside the seeded " *
                                     "windows $(wins) (extend the seed in fill_profile)"))
        end
    end
    return nothing
end
const _GUARDED_SCHEMAS = ("entsoe", "jao", "yfinance", "epias", "simulations", "weather")

function _load_fill_guard(con)
    has = collect(DBInterface.execute(con,
        "SELECT count(*) AS n FROM information_schema.tables WHERE table_schema = '_fill' AND table_name = 'windows'"))[1].n
    has == 0 && return nothing
    g = Dict{String,Vector{Tuple{Dates.DateTime,Dates.DateTime}}}()
    for r in DBInterface.execute(con, "SELECT schema_name, table_name, lo, hi FROM _fill.windows")
        push!(get!(g, string(r.schema_name, ".", r.table_name), Tuple{Dates.DateTime,Dates.DateTime}[]),
              (Dates.DateTime(r.lo), Dates.DateTime(r.hi)))
    end
    return g
end

const _FULL_LO = Dates.DateTime(1900, 1, 1)

"""
    mark_run_local_fill!(path; windows=[(schema, table, lo::Date, hi::Date), ...])

Mark an existing DuckDB file as a run-local fill: write `_fill.windows` (the table
fill_run_duckdb writes), which arms the strict read guard and the read-back redirect when
the file is opened as the data store. For tests and tools that build small inputs files by
hand; `lo = Date(1900,1,1)` marks a table as filled whole.
"""
function mark_run_local_fill!(path::AbstractString; windows)
    db = DuckDB.DB(String(path))
    con = DBInterface.connect(db)
    try
        DBInterface.execute(con, "CREATE SCHEMA IF NOT EXISTS _fill")
        DBInterface.execute(con, "CREATE TABLE IF NOT EXISTS _fill.windows (schema_name VARCHAR, table_name VARCHAR, kind VARCHAR, lo DATE, hi DATE, n_rows BIGINT, seconds DOUBLE)")
        for (sch, tbl, lo, hi) in windows
            DBInterface.execute(con, "INSERT INTO _fill.windows VALUES (?, ?, 'window', ?, ?, 0, 0.0)",
                                [String(sch), String(tbl), Dates.Date(lo), Dates.Date(hi)])
        end
    finally
        DBInterface.close!(con)
        DuckDB.close(db)
    end
    return String(path)
end

function _fill_guard_check(g, sql::AbstractString, args)
    tables = String[]
    for m in eachmatch(r"(?<![\w.])(results_db\.)?([A-Za-z_]+)\.([A-Za-z_][A-Za-z0-9_]*)\b", sql)
        m.captures[1] === nothing || continue          # results_db.* is the writable results file
        sch = lowercase(m.captures[2])
        sch in _GUARDED_SCHEMAS || continue
        push!(tables, string(sch, ".", m.captures[3]))
    end
    for t in unique(tables)
        haskey(g, t) || throw(FillGuardError("fill guard: $t is not in this run's fill manifest " *
                              "(add it to FILL_SPECS; never read Postgres directly)"))
    end
    stamps = Dates.DateTime[]
    for a in (args === nothing ? () : args)
        a isa Dates.Date && push!(stamps, Dates.DateTime(a))
        a isa Dates.DateTime && push!(stamps, a)
    end
    for m in eachmatch(r"TIMESTAMP\s+'(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2}:\d{2}))?'", sql)
        push!(stamps, Dates.DateTime(m.captures[1] * "T" * something(m.captures[2], "00:00:00")))
    end
    isempty(stamps) && return nothing
    for t in unique(tables)
        wins = g[t]
        any(w -> w[1] == _FULL_LO, wins) && continue
        for ts in stamps
            any(w -> w[1] <= ts <= w[2], wins) ||
                throw(FillGuardError("fill guard: $t read at $ts is outside the filled windows $(wins) " *
                      "(extend the manifest lookback; never read Postgres directly)"))
        end
    end
    return nothing
end

function _duckdb_sql2df(sql, args)
    # Dialect rewrite is pure CPU — do it outside the lock. The result is a
    # stable function of the input SQL, so it is also the prepared-statement
    # cache key.
    con = _duckdb_connection()      # first: opening it loads the fill guard the rewrite consults
    rewritten = _duckdb_rewrite(sql)
    g = _FILL_GUARD[]
    g === nothing || _fill_guard_check(g, rewritten, args)
    if occursin("results_db.", rewritten)
        _ensure_results_attached(con)
        g === nothing || _readback_check(con, rewritten, args)
    end
    # Lock scope narrowed to prepare-once + execute + materialize. The compiled
    # statement is cached per connection, so repeat calls skip parse/plan.
    lock(_DUCKDB_LOCK) do
        stmt = get!(_DUCKDB_STMT_CACHE, rewritten) do
            DBInterface.prepare(con, rewritten)
        end
        res = isempty(args) ? DBInterface.execute(stmt) :
              DBInterface.execute(stmt, collect(args))
        return DataFrame(res)
    end
end

# Guard for write paths under the read-only DuckDB backend: warns once and
# tells the caller to no-op. Returns `true` when running on DuckDB.
#
# NOTE: this is now used ONLY for write paths with no offline equivalent — UC
# caching (removed in cv25) and `ensure_indexes`. The three
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
    (DUCKDB_READ_ONLY[] && !DUCKDB_RESULTS_WRITABLE[]) && error(
        "The DuckDB data store is open in read-only shared mode " *
        "(EUPHEMIA_DUCKDB_READONLY / configure_data_store!(read_only=true)); " *
        "results cannot be written from this process. Parallel workers must run " *
        "with save_to_db=false — the coordinator persists the returned prices. " *
        "(The coordinator opts in via configure_data_store!(read_only=true, " *
        "results_writable=true).)")
    return nothing
end

# Under a run-local fill a failed results attach is a FillGuardError (never a soft fallback): a
# process that cannot open the results DB (DuckDB's file lock: another process holds it
# read-write) must be started with EUPHEMIA_RESULTS_READBACK=inputs.
function _attach_results(con, path, mode)
    try
        DBInterface.execute(con, "ATTACH IF NOT EXISTS '$(path)' AS results_db ($mode)")
    catch e
        _in_fill() || rethrow()
        throw(FillGuardError("fill guard: cannot attach the results DB $(path) ($mode): " *
            sprint(showerror, e) * " — a process that cannot open it (pipelined book workers) must run " *
            "with EUPHEMIA_RESULTS_READBACK=inputs"))
    end
end

function _ensure_results_attached(con)
    lock(_DUCKDB_LOCK) do
        _RESULTS_ATTACHED[] && return
        path = RESULTS_DB_PATH[]
        if DUCKDB_READ_ONLY[] && !DUCKDB_RESULTS_WRITABLE[]
            # A read-only shared process (parallel worker, eval script) may
            # still READ results — e.g. the pipeline's already-saved check.
            # Before 2026-08-25 this asserted writability on every read too, so
            # such a process threw, `pipeline_day_saved` swallowed the error as
            # "not saved" and re-cleared already-saved days. Attach read-only;
            # the writers still assert via _duckdb_assert_writable().
            isfile(path) || (_in_fill() ? throw(FillGuardError("fill guard: results DuckDB $(path) does not exist " *
                                  "(this process is read-only and cannot create it)")) :
                             error("results DuckDB $(path) does not exist and this " *
                                   "process is read-only (cannot create it)"))
            _attach_results(con, path, "READ_ONLY")
            _RESULTS_ATTACHED[] = true
            return
        end
        dir = dirname(path)
        !isempty(dir) && !isdir(dir) && mkpath(dir)
        # A read-only source connection defaults its ATTACH to read-only too, so
        # the separate results file must be attached with an explicit READ_WRITE
        # override (DuckDB honours per-attachment access mode). Harmless when the
        # source is already read-write.
        _attach_results(con, path, "READ_WRITE")
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
                flow_mw DOUBLE, clearing_mode VARCHAR DEFAULT 'multi_zone',
                code_version INTEGER, update_time_utc TIMESTAMP)""")
        # Migration for results files created before flows carried a run label
        # (bug sweep 2026-08-24). Legacy rows are labelled 'multi_zone'.
        DBInterface.execute(con, """
            ALTER TABLE results_db.simulations.transmission_flows
            ADD COLUMN IF NOT EXISTS clearing_mode VARCHAR DEFAULT 'multi_zone'""")
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

# Bulk-insert a DataFrame into results_db.simulations.<table>. Registers the
# frame and INSERT BY NAME — column-order-proof: a results DB whose table
# predates a migration (e.g. transmission_flows grew clearing_mode at the END)
# has a different physical column order than a freshly created one, and the
# positional `SELECT *` used to land strings on INT columns (2026-08-26).
function _results_insert_df(df::DataFrame, table::AbstractString)
    isempty(df) && return 0
    con = _duckdb_connection()
    _ensure_results_attached(con)
    lock(_DUCKDB_LOCK) do
        view = "_results_stage"
        # register_data_frame creates a temp VIEW in the session's DEFAULT
        # catalog. When the source extract is attached read-only that catalog
        # can't take a CREATE, so switch the default to the writable results_db
        # for the registration + insert, then restore it (source reads such as
        # entsoe.* resolve against the original catalog's search path).
        prev_db = DataFrame(DBInterface.execute(con, "SELECT current_database() AS d")).d[1]
        DBInterface.execute(con, "USE results_db")
        DuckDB.register_data_frame(con, df, view)
        try
            DBInterface.execute(con,
                "INSERT INTO results_db.simulations.$table BY NAME SELECT * FROM $view")
        finally
            DuckDB.unregister_data_frame(con, view)
            DBInterface.execute(con, "USE \"$(prev_db)\"")
        end
    end
    return nrow(df)
end

"""
    results_write_transaction(f)

Run a block of result writes (`save_energy_prices` / `save_optimization_run` /
`save_transmission_flows`) inside a single DuckDB transaction on the
results-attached connection, so a whole persist segment commits ONCE instead of
autocommitting — and checkpointing — every per-day DELETE/INSERT. For a `--full`
run (tens of thousands of tiny round-trips on the single-writer results DB) this
collapses the post-clearing persist overhead to one commit. The per-day DELETE
+ INSERT (idempotent replace) logic is unchanged, so re-running a tier is still
resumable. No-op on the Postgres backend (its writers batch their own way).
"""
function results_write_transaction(f)
    DATA_STORE[] == :duckdb || return f()
    con = _duckdb_connection()
    _ensure_results_attached(con)
    lock(_DUCKDB_LOCK) do
        DBInterface.execute(con, "BEGIN TRANSACTION")
    end
    committed = false
    try
        r = f()
        lock(_DUCKDB_LOCK) do
            DBInterface.execute(con, "COMMIT")
        end
        committed = true
        return r
    finally
        if !committed
            lock(_DUCKDB_LOCK) do
                try
                    DBInterface.execute(con, "ROLLBACK")
                catch
                end
            end
        end
    end
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
                                         code_version::Int, clearing_mode::String="multi_zone")
    isempty(flows) && (@warn "No transmission flows to save"; return 0)
    update_time = now(UTC)
    dts = DateTime[]; src = String[]; snk = String[]; fmw = Float64[]; cv = Int[]; ut = DateTime[]
    cm = String[]
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
            push!(cm, clearing_mode)
        end
    end
    isempty(dts) && return 0
    # Replace only THIS run label's rows for the day (the old delete keyed on
    # (day, code_version) alone, so a 5-zone run wiped the 39-zone flows).
    _results_exec("""
        DELETE FROM results_db.simulations.transmission_flows
        WHERE CAST(date_time_utc AS DATE) = \$1 AND code_version = \$2
          AND clearing_mode = \$3
        """, Any[date, code_version, clearing_mode])
    df = DataFrame(date_time_utc=dts, source_zone=src, sink_zone=snk,
                   flow_mw=fmw, clearing_mode=cm, code_version=cv, update_time_utc=ut)
    n = _results_insert_df(df, "transmission_flows")
    @info "Saved $n transmission flow records to results_db"
    return n
end
