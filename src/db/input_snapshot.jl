# Opt-in retro input snapshot. State discovery and writers never install this scope.
using Base.ScopedValues: ScopedValue, with
using SHA, Serialization

mutable struct InputCacheEntry
    ready::Base.Event
    value::Union{Nothing,DataFrame}
    error::Any
    bytes::Int
end

mutable struct InputSnapshot
    query::Function
    cleanup::Function
    revision::String
    captured_at::String
    zones::Vector{String}
    cache::Dict{String,InputCacheEntry}
    order::Vector{String}
    lock::ReentrantLock
    max_bytes::Int
    bytes::Int
    hits::Int
    misses::Int
    query_seconds::Float64
    failure::Any
    closed::Bool
end

const CURRENT_INPUT_SNAPSHOT = ScopedValue{Union{Nothing,InputSnapshot}}(nothing)
const OPTIONAL_INPUT_READ = ScopedValue(false)
const INPUT_SNAPSHOT_LIFECYCLE_LOCK = ReentrantLock()

# Only UKA explicitly permits a missing table/schema and uses the model's existing
# EUA fallback. Network errors, malformed SQL and missing required inputs are fatal.
function optional_input_absent(e)
    e isa Union{LibPQ.Errors.UndefinedTable,LibPQ.Errors.InvalidSchemaName} && return true
    return e isa DuckDB.QueryException &&
        occursin("Catalog Error", sprint(showerror, e)) &&
        occursin("does not exist", sprint(showerror, e))
end

sql2df_optional_input(sql, args) = with(OPTIONAL_INPUT_READ => true) do
    sql2df(sql, args)
end

# Reader injection is also the offline proof boundary: a shared read-only extract
# is already immutable. Production only constructs this through open_pg_input_snapshot.
function InputSnapshot(query::Function, zones; revision::String, captured_at::String,
                       cleanup::Function=()->nothing, max_bytes::Int=512*1024^2)
    max_bytes > 0 || throw(ArgumentError("input cache byte limit must be positive"))
    return InputSnapshot(query, cleanup, revision, captured_at, sort(unique(String.(zones))),
        Dict{String,InputCacheEntry}(), String[], ReentrantLock(), max_bytes,
        0, 0, 0, 0.0, nothing, false)
end

function assert_input_snapshot_healthy(s::InputSnapshot)
    lock(s.lock) do
        s.closed && error("input snapshot is closed")
        s.failure === nothing || error("input snapshot failed; refusing forecast writes: $(s.failure)")
    end
end

function with_input_snapshot(f::Function, s::Union{Nothing,InputSnapshot})
    s === nothing && return f()
    assert_input_snapshot_healthy(s)
    result = with(f, CURRENT_INPUT_SNAPSHOT => s)
    # Legacy loaders sometimes catch SQL errors and substitute fallbacks. Such a
    # required-input failure must never permit a write from an incomplete snapshot.
    assert_input_snapshot_healthy(s)
    return result
end

function snapshot_sql2df(s::InputSnapshot, sql, args)
    assert_input_snapshot_healthy(s)
    io = IOBuffer()
    # Immutable serialized key includes types, full array contents and issuance.
    # No show()/repr() truncation and no mutable array keys.
    serialize(io, (String(sql), args, ctx_key(), OPTIONAL_INPUT_READ[]))
    key = bytes2hex(sha256(take!(io)))
    entry, owner = lock(s.lock) do
        if haskey(s.cache, key)
            s.hits += 1
            (s.cache[key], false)
        else
            s.misses += 1
            e = InputCacheEntry(Base.Event(), nothing, nothing, 0)
            s.cache[key] = e
            (e, true)
        end
    end
    if owner
        t = time()
        try
            value = s.query(sql, args)
            value isa DataFrame || error("input reader must return a DataFrame")
            size = Base.summarysize(value)
            lock(s.lock) do
                s.query_seconds += time() - t
                entry.value = value
                entry.bytes = size
                # Evict completed entries only. In-flight callers retain their
                # entry reference and cannot be stranded by eviction.
                while s.bytes + size > s.max_bytes && !isempty(s.order)
                    old = popfirst!(s.order)
                    prior = pop!(s.cache, old)
                    s.bytes -= prior.bytes
                end
                if size <= s.max_bytes
                    s.bytes += size
                    push!(s.order, key)
                else
                    delete!(s.cache, key) # oversized result is served, not retained
                end
            end
        catch e
            lock(s.lock) do
                entry.error = e
                if !(OPTIONAL_INPUT_READ[] && optional_input_absent(e))
                    s.failure = e
                end
                delete!(s.cache, key) # failed results consume no retained cache space
            end
        finally
            notify(entry.ready)
        end
    else
        wait(entry.ready)
    end
    entry.error === nothing || throw(entry.error)
    assert_input_snapshot_healthy(s)
    return deepcopy(entry.value) # callers may mutate rows/columns/nested values
end

# A dedicated read-only pool shares ONE exported MVCC view. It is independent of
# the ordinary PG pool used by resume checks and transactional forecast writes.
# Two source connections total, including the exporting connection; runtime-sized.
function open_pg_input_snapshot(zones; max_bytes::Int=512*1024^2,
                                connect::Function=newconnection)
    connections = LibPQ.Connection[]
    try
        first = connect()
        push!(connections, first)
        LibPQ.execute(first, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        meta = DataFrame(LibPQ.execute(first, """
            SELECT pg_export_snapshot() AS snapshot_id,
                   pg_current_snapshot()::text AS revision_cutoff,
                   (clock_timestamp() AT TIME ZONE 'UTC') AS captured_at_utc
            """))
        snapshot_id = String(meta.snapshot_id[1])
        occursin(r"^[A-Za-z0-9-]+$", snapshot_id) || error("invalid exported snapshot identifier")
        second = connect()
        push!(connections, second)
        LibPQ.execute(second, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        LibPQ.execute(second, "SET TRANSACTION SNAPSHOT '$snapshot_id'")
        for conn in connections
            LibPQ.execute(conn, "SET LOCAL statement_timeout = '10min'")
            LibPQ.execute(conn, "SET LOCAL idle_in_transaction_session_timeout = '15min'")
        end
        available = Channel{LibPQ.Connection}(length(connections))
        foreach(c -> put!(available, c), connections)
        query = function(sql, args)
            conn = take!(available)
            try
                # READ ONLY also rejects accidental mutating SQL. Errors poison
                # the chunk; never reconnect into a different revision snapshot.
                optional = OPTIONAL_INPUT_READ[]
                optional && LibPQ.execute(conn, "SAVEPOINT optional_input")
                result = try
                    # The tiny optional lookup uses execute so its SQLSTATE is
                    # available directly, rather than wrapped in TaskFailedException.
                    optional ? DataFrame(LibPQ.execute(conn, sql, args)) :
                               DataFrame(fetch(LibPQ.async_execute(conn, sql, args)))
                catch
                    if optional
                        # Recover the same frozen transaction after an optional
                        # missing relation. Failure to recover is itself fatal.
                        LibPQ.execute(conn, "ROLLBACK TO SAVEPOINT optional_input")
                        LibPQ.execute(conn, "RELEASE SAVEPOINT optional_input")
                    end
                    rethrow()
                end
                optional && LibPQ.execute(conn, "RELEASE SAVEPOINT optional_input")
                return result
            finally
                put!(available, conn)
            end
        end
        cleanup = function()
            for conn in connections
                try
                    LibPQ.execute(conn, "ROLLBACK")
                catch
                    # A lost connection cannot be repaired without changing the view.
                finally
                    close(conn)
                end
            end
        end
        return InputSnapshot(query, zones; revision="pg:$snapshot_id/$(meta.revision_cutoff[1])",
            captured_at=string(meta.captured_at_utc[1]), cleanup=cleanup, max_bytes=max_bytes)
    catch
        foreach(c -> try close(c) catch end, connections)
        rethrow()
    end
end

function close_input_snapshot!(s::InputSnapshot)
    already_closed = lock(s.lock) do
        old = s.closed
        s.closed = true
        old
    end
    already_closed && return nothing
    try
        s.cleanup()
    finally
        empty!(s.cache)
        empty!(s.order)
        s.bytes = 0
    end
end

# Source-derived legacy memos must not leak values across revision snapshots.
# Called only at the chunk boundary with no book tasks active. Configuration,
# thermometer overrides and solver state are deliberately retained.
function clear_input_memos!()
    for (mod, names) in (
        (@__MODULE__, (:TTF_PRICE_CACHE, :TTF_PRICE_CACHE_ASOF, :EUA_PRICE_CACHE,
            :EUA_PRICE_CACHE_ASOF, :UKA_PRICE_CACHE, :_OUTAGE_DAY_CACHE,
            :_GENERATOR_MEMO, :_FEED_ANCHOR_CACHE)),
        (MeritOrderBook, (:_TYPE_P95_DAY_CACHE, :_HYDRO_AVAIL_DAY_CACHE,
            :_INSTALLED_CAP_CACHE, :_RESERVOIR_DAY_CACHE, :_BOUNDARY_CAP_CACHE,
            :_BOUNDARY_FIRM_CACHE, :_NET_IMPORTS_DAY_CACHE, :_ANALOGUE_DAYS_CACHE,
            :_CV32_DELTA_CACHE, :_GRSQ_COMMIT_CACHE, :_PUMP_CAP_CACHE, :_STORAGE_BUDGET_CACHE)),
        (Network, (:_JAO_DAY_CACHE, :_JAO_CCR_PAIRS, :_JAO_NP_CACHE,
            :_TX_OUTAGE_DAY_CACHE, :_FBMC_CAP_DAY_CACHE, :_DA_EVER_CACHE,
            :_TRAILING_DA_DAY_CACHE)))
        for name in names
            empty!(getfield(mod, name))
        end
    end
    return nothing
end

# Scope only the lifecycle here. Input routing is installed explicitly around
# the clear, never around the caller's state discovery or forecast write.
function with_retro_input_chunk(f::Function, zones, first_day, last_day;
                               enabled::Bool=false, factory::Function=open_pg_input_snapshot)
    enabled || return f(nothing)
    lock(INPUT_SNAPSHOT_LIFECYCLE_LOCK) do
        clear_input_memos!()
        s = factory(zones)
        println("  📦 input snapshot chunk=$first_day..$last_day revision_cutoff=$(s.revision) captured_at_utc=$(s.captured_at) input_connections=2 cache_limit_bytes=$(s.max_bytes)")
        try
            return f(s)
        finally
            println("  📦 input cache hits=$(s.hits) misses=$(s.misses) source_query_seconds=$(round(s.query_seconds; digits=3)) retained_bytes=$(s.bytes)")
            try
                close_input_snapshot!(s)
            finally
                clear_input_memos!()
            end
        end
    end
end

# Batch the expensive unbounded last-positive-observation scan across all zones
# for each exact bound. MAX and the distinct unit→zone relation preserve the
# original per-zone query, including units registered in multiple zones.
function snapshot_feed_anchor(s::InputSnapshot, map_code::String, bound::Dates.DateTime)
    zones = map_code in s.zones ? s.zones : [map_code]
    df = snapshot_sql2df(s, """
        SELECT g.area_map_code, MAX(p.date_time_utc) AS last_obs
        FROM entsoe.actual_generation_output_per_generation_unit p
        JOIN (SELECT DISTINCT area_map_code, generation_unit_code
              FROM entsoe.production_and_generation_units
              WHERE area_map_code = ANY(\$1)) g
          ON p.generation_unit_code = g.generation_unit_code
        WHERE p.date_time_utc < \$2::timestamp
          AND p.actual_generation_output_mw > 0
        GROUP BY g.area_map_code
        """, Any[zones, bound])
    for row in eachrow(df)
        String(row.area_map_code) == map_code || continue
        return ismissing(row.last_obs) ? nothing : Dates.DateTime(row.last_obs)
    end
    return nothing
end
