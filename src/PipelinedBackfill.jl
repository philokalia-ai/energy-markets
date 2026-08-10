# PipelinedBackfill.jl — producer/consumer pipeline for the 39-zone EU
# multi-zone backfill.
#
# Motivation (the user's goal, verbatim): "build the books in parallel, in
# memory, and then chunk them to Gurobi so it never sits." The two-pass
# merit-order clear per day is: build pass-1 books (CPU + DB heavy, ~seconds
# per 39-zone day) → pass-1 MPCC solve (the scarce Gurobi resource) → extract
# opportunity-anchor refs → rebuild only the ~12 anchored zones' books →
# pass-2 solve → save. Running that sequentially leaves Gurobi idle during
# every book build. This pipeline decouples the stages onto separate
# Distributed workers connected by bounded RemoteChannels, so the solver
# workers stay saturated while book workers build the next days ahead.
#
# Topology (per market day, with the pass-2 feedback edge):
#
#   feeder ──bookwork(:pass1)──▶ BOOK WORKERS ──solvework(:pass1)──▶ SOLVER
#     ▲                                                                │
#     │ token                       (anchored?)  ◀── extract anchors ──┤
#     │                                  │ yes                         │ no
#   WRITER ◀────── results ◀────┐        ▼                             │
#  (coordinator, single writer) │   bookwork(:pass2)                   │
#     │                         │        │                             │
#     └──── save + release ─────┘   BOOK WORKERS ──solvework(:pass2)──▶ SOLVER ─▶ results
#
# Correctness: every model/book step reuses the EXACT functions the sequential
# `run_multi_zone_market_clearing(...; passes=2)` path uses (`mz_build_books`,
# `mz_solve_pass`, `mz_extract_anchor_inputs`, `mz_rebuild_anchored`). Only the
# orchestration is new, so a pipelined day is byte-identical to the sequential
# one (acceptance-tested in test/scripts/pipeline_identity.jl).
#
# Concurrency safety:
#  - Exactly `solver_workers` solver PROCESSES exist (default 2 = Gurobi WLS
#    concurrent-session cap); each solves one problem at a time, so at most
#    `solver_workers` Gurobi solves run at once. Each solver process creates ONE
#    persistent Gurobi env on first solve (SOLVER_ENV_CACHE) and reuses it.
#  - A counting-token semaphore caps days-in-flight at `in_flight`; every
#    internal channel has capacity `in_flight`, so no internal `put!` can ever
#    block — this breaks the pass-2 feedback cycle's deadlock potential. Only
#    the feeder blocks (intended backpressure), bounding RAM.
#  - Single writer (the coordinator) owns all DB writes.

using Distributed

# --- message tags --------------------------------------------------------
# bookwork items:  (:pass1, day, t_feed)
#                  (:pass2, day, refs, cached, r1, book_secs, waitq, solve1_secs, t_solve1_done)
#                  (:stop,)
# solvework items: (:pass1, day, ob1, book_secs, t_build_done)
#                  (:pass2, day, ob2, r1, book_secs, waitq, solve1_secs, rebuild_secs, t_rebuild_done)
#                  (:stop,)
# results items:   NamedTuple (see _result_ok / _result_failed)

_result_ok(day, final, ob, book_secs, waitq, solve1_secs, rebuild_secs, solve2_secs) =
    (day=day, ok=true, final=final, ob=ob, status=final.status,
     book_secs=book_secs, waitq_secs=waitq, solve1_secs=solve1_secs,
     rebuild_secs=rebuild_secs, solve2_secs=solve2_secs, err=nothing)

_result_failed(day; status=:error, book_secs=0.0, waitq_secs=0.0,
               solve1_secs=0.0, rebuild_secs=0.0, solve2_secs=0.0, err=nothing) =
    (day=day, ok=false, final=nothing, ob=nothing, status=status,
     book_secs=book_secs, waitq_secs=waitq_secs, solve1_secs=solve1_secs,
     rebuild_secs=rebuild_secs, solve2_secs=solve2_secs, err=err)

_usable(r) = r.status == :optimal ||
             (r.status == :time_limit && !isempty(r.market_prices))

# ---------------------------------------------------------------------------
# Order-book capture (opt-in via run_pipelined_backfill(books_dir=...))
# ---------------------------------------------------------------------------
# The BOOK_SINK Ref fires inside create_merit_order_book, which in the pipeline
# runs on the BOOK WORKERS (mz_build_books / mz_rebuild_anchored), not the
# coordinator. So capture is worker-side: each book worker installs a sink that
# accumulates the FULL tagged book per (zone,day), and after each pass job it
# flushes that day's captured zones to a PASS-TAGGED staging parquet in
# `<books_dir>/.staging/`. The coordinator merges pass-1 ∪ pass-2 (pass-2 WINS
# per zone — same overwrite-per-(zone,day) semantics as bin/daily_forecast.jl's
# sink, where pass-2 only re-fires for the anchored zones and the rest persist
# from pass 1) into `<books_dir>/<day>.parquet` at save time.
#
# Concurrency: within a worker the threaded 39-zone build fires the sink from
# multiple threads, guarded by a per-worker lock. ACROSS workers a day's pass-1
# and pass-2 books may be built by DIFFERENT processes, so each writes its own
# pass-tagged staging file and the single coordinator merges — no cross-process
# file races. Ordering is safe by construction: a worker flushes its staging
# file SYNCHRONOUSLY before forwarding the job to the solver, so the file is on
# disk before any result for that day can reach the coordinator's writer.
#
# When `books_dir` is nothing the sink is never installed and this whole path is
# inert — the pipeline is byte-identical to the pre-books code (identity guard).

_pipeline_book_staging(dir::AbstractString, day::Date, pass::Int) =
    joinpath(dir, ".staging", "$(day)_pass$(pass).parquet")

# Write a parquet (zstd) atomically: COPY to `path.tmp` then rename.
function _write_books_parquet(df::DataFrame, path::AbstractString)
    tmp = path * ".tmp"
    dbh = DuckDB.DB()
    con = DBInterface.connect(dbh)
    try
        DuckDB.register_data_frame(con, df, "_books_stage")
        DBInterface.execute(con,
            "COPY (SELECT * FROM _books_stage ORDER BY zone, ts, side, price) " *
            "TO '$(tmp)' (FORMAT parquet, COMPRESSION zstd)")
    finally
        DBInterface.close!(con)
        close(dbh)
    end
    mv(tmp, path; force=true)
    return path
end

# Flush (and clear) the captured books for `day` to its pass-tagged staging
# parquet. Columns mirror bin/daily_forecast.jl's flush_books! so downstream
# tooling reads one schema. Returns the row count written.
function _flush_pipeline_books(books::Dict{Tuple{String,Date},Vector{Tuple{SimpleOrder,String,String}}},
                               books_lock::ReentrantLock, dir::AbstractString,
                               day::Date, pass::Int)
    rows = NamedTuple[]
    lock(books_lock) do
        for k in collect(keys(books))
            (zone, d) = k
            d == day || continue
            for (o, tag, strat) in books[k]
                push!(rows, (market_date=day, zone=zone, ts=o.date_time,
                             side=String(o.type), price=o.price, mw=o.quantity,
                             owner=tag, strategy=strat,
                             code_version=ENERGY_PRICES_CODE_VERSION))
            end
            delete!(books, k)
        end
    end
    staging = _pipeline_book_staging(dir, day, pass)
    mkpath(dirname(staging))
    isempty(rows) && return 0
    _write_books_parquet(DataFrame(rows), staging)
    return length(rows)
end

# Coordinator-side merge: combine `day`'s pass-1 and pass-2 staging parquets into
# `<dir>/<day>.parquet` with pass-2 winning per zone, then delete the staging
# files. Returns the output path, or `nothing` if no pass-1 file was captured.
function _merge_pipeline_day_books(dir::AbstractString, day::Date)
    p1 = _pipeline_book_staging(dir, day, 1)
    p2 = _pipeline_book_staging(dir, day, 2)
    isfile(p1) || return nothing
    out = joinpath(dir, "$(day).parquet")
    tmp = out * ".tmp"
    dbh = DuckDB.DB()
    con = DBInterface.connect(dbh)
    try
        sql = if isfile(p2)
            # pass-2 wins: keep pass-1 rows only for zones NOT rebuilt in pass 2.
            """
            COPY (
              SELECT * FROM read_parquet('$(p1)')
              WHERE zone NOT IN (SELECT DISTINCT zone FROM read_parquet('$(p2)'))
              UNION ALL
              SELECT * FROM read_parquet('$(p2)')
              ORDER BY zone, ts, side, price
            ) TO '$(tmp)' (FORMAT parquet, COMPRESSION zstd)
            """
        else
            "COPY (SELECT * FROM read_parquet('$(p1)') ORDER BY zone, ts, side, price) " *
            "TO '$(tmp)' (FORMAT parquet, COMPRESSION zstd)"
        end
        DBInterface.execute(con, sql)
    finally
        DBInterface.close!(con)
        close(dbh)
    end
    mv(tmp, out; force=true)
    rm(p1; force=true)
    isfile(p2) && rm(p2; force=true)
    return out
end

# Remove any staging parquets for a day whose result was NOT usable, so failed
# days leave no orphaned staging files behind.
function _cleanup_pipeline_staging(dir::AbstractString, day::Date)
    for pass in (1, 2)
        p = _pipeline_book_staging(dir, day, pass)
        isfile(p) && rm(p; force=true)
    end
    return nothing
end

"""
    pipeline_book_worker(bookwork, solvework, results, zones, cfg) -> Int

Book-building worker loop. Blocks on the `bookwork` channel and, per job:
- `:pass1` → builds the full 39-zone pass-1 order book (`mz_build_books`) and
  forwards it to `solvework`;
- `:pass2` → rebuilds ONLY the anchored zones, reusing the cached pass-1 orders
  for every other zone (`mz_rebuild_anchored`), and forwards to `solvework`.
Exits on a `:stop` sentinel. Returns the number of book jobs handled.
Any build error is turned into a failed `results` item so the day still
completes (its token is released) instead of stalling the pipeline.
"""
function pipeline_book_worker(bookwork::RemoteChannel, solvework::RemoteChannel,
                              results::RemoteChannel, zones::Vector{String}, cfg,
                              progress::Union{Nothing,RemoteChannel}=nothing)
    handled = 0
    # Opt-in book capture (cfg.books_dir set). Install a process-local sink that
    # accumulates the tagged book per (zone,day); the threaded build fires it
    # from several threads, so guard the dict with a lock. Flushed + cleared per
    # pass job below. Inert (never installed) when books_dir is nothing.
    books_dir = hasproperty(cfg, :books_dir) ? cfg.books_dir : nothing
    # Each captured order is (SimpleOrder, owner_tag, strategy_label) — the
    # strategy is the parallel 5th sink arg zipped in here (additive `strategy`
    # parquet column; see _flush_pipeline_books).
    books = books_dir === nothing ? nothing :
        Dict{Tuple{String,Date},Vector{Tuple{SimpleOrder,String,String}}}()
    books_lock = ReentrantLock()
    if books !== nothing
        MeritOrderBook.BOOK_SINK[] = function (zone, day, tagged, res, strat)
            lock(books_lock) do
                books[(zone, day)] = [(tagged[i][1], tagged[i][2], String(strat[i]))
                                      for i in eachindex(tagged)]
            end
        end
    end
    while true
        job = take!(bookwork)
        job[1] === :stop && break
        handled += 1
        # Report the day this worker is now processing so the coordinator can
        # resubmit it if this process dies (#182 crash resilience).
        progress === nothing || put!(progress, (myid(), :start, job[2]))
        if job[1] === :pass1
            (_, day, _t_feed) = job
            try
                t0 = time()
                ob1 = mz_build_books(zones, day;
                    enrich_network=cfg.enrich_network,
                    apply_zone_profiles=cfg.apply_zone_profiles,
                    scenario=cfg.scenario)
                book_secs = time() - t0
                # Flush pass-1 books BEFORE forwarding, so the staging file is on
                # disk before any result for this day can reach the coordinator.
                books === nothing ||
                    _flush_pipeline_books(books, books_lock, books_dir, day, 1)
                put!(solvework, (:pass1, day, ob1, book_secs, time()))
            catch e
                e isa InterruptException && rethrow()
                put!(results, _result_failed(day; status=:error,
                    err="pass-1 book build: " * sprint(showerror, e)))
            end
        else # :pass2
            (_, day, refs, cached, r1, book_secs, waitq, solve1_secs, _t) = job
            try
                t0 = time()
                ob2 = mz_rebuild_anchored(zones, day, refs, cached;
                    enrich_network=cfg.enrich_network,
                    apply_zone_profiles=cfg.apply_zone_profiles,
                    scenario=cfg.scenario)
                rebuild_secs = time() - t0
                # Flush pass-2 books (only the anchored zones re-fired the sink)
                # before forwarding — same ordering guarantee as pass 1.
                books === nothing ||
                    _flush_pipeline_books(books, books_lock, books_dir, day, 2)
                put!(solvework, (:pass2, day, ob2, r1, book_secs, waitq,
                                 solve1_secs, rebuild_secs, time()))
            catch e
                e isa InterruptException && rethrow()
                put!(results, _result_failed(day; status=:error,
                    book_secs=book_secs, waitq_secs=waitq, solve1_secs=solve1_secs,
                    err="pass-2 rebuild: " * sprint(showerror, e)))
            end
        end
        progress === nothing || put!(progress, (myid(), :idle, job[2]))
    end
    return handled
end

"""
    pipeline_solver_worker(solvework, bookwork, results, cfg) -> (busy, n)

MPCC solver worker loop. Blocks on `solvework` and, per job:
- `:pass1` → solves pass 1, extracts anchor inputs; if no zone is anchored the
  day is done (→ `results`); otherwise pushes a `:pass2` rebuild job back onto
  `bookwork` (the feedback edge);
- `:pass2` → solves pass 2 and completes the day (accept pass-2 result, else
  fall back to the pass-1 result — same rule as the sequential path).
Exits on a `:stop` sentinel. Returns `(cumulative_solve_wall_seconds,
n_solves)` for the utilization summary. Each solver process reuses one
persistent Gurobi env (SOLVER_ENV_CACHE) across all solves.
"""
function pipeline_solver_worker(solvework::RemoteChannel, bookwork::RemoteChannel,
                                results::RemoteChannel, cfg,
                                progress::Union{Nothing,RemoteChannel}=nothing)
    busy = 0.0
    n = 0
    while true
        job = take!(solvework)
        job[1] === :stop && break
        # Report the day being solved for crash-resubmit (#182).
        progress === nothing || put!(progress, (myid(), :start, job[2]))
        if job[1] === :pass1
            (_, day, ob1, book_secs, t_build_done) = job
            waitq = time() - t_build_done
            try
                tw = time()
                r1 = mz_solve_pass(ob1; optimizer=cfg.optimizer, silent=cfg.silent,
                    mpcc_time_limit=cfg.mpcc_time_limit, mpcc_mip_gap=cfg.mpcc_mip_gap,
                    mpcc_heuristic_effort=cfg.mpcc_heuristic_effort,
                    decompose_periods=cfg.decompose_periods)
                solve1_secs = time() - tw
                busy += solve1_secs; n += 1
                if !_usable(r1)
                    put!(results, _result_failed(day; status=r1.status,
                        book_secs=book_secs, waitq_secs=waitq, solve1_secs=solve1_secs,
                        err="pass-1 solve produced no prices"))
                    progress === nothing || put!(progress, (myid(), :idle, day))
                    continue
                end
                ai = mz_extract_anchor_inputs(ob1, r1;
                    apply_zone_profiles=cfg.apply_zone_profiles)
                if isempty(ai.anchored)
                    # No anchored zone (e.g. SEE footprint) → pass 1 is final.
                    put!(results, _result_ok(day, r1, ob1, book_secs, waitq,
                        solve1_secs, 0.0, 0.0))
                else
                    put!(bookwork, (:pass2, day, ai.refs, ai.cached, r1,
                        book_secs, waitq, solve1_secs, time()))
                end
            catch e
                e isa InterruptException && rethrow()
                put!(results, _result_failed(day; status=:error,
                    book_secs=book_secs, waitq_secs=waitq,
                    err="pass-1 solve: " * sprint(showerror, e)))
            end
        else # :pass2
            (_, day, ob2, r1, book_secs, waitq, solve1_secs, rebuild_secs, _t) = job
            try
                tw = time()
                r2 = mz_solve_pass(ob2; optimizer=cfg.optimizer, silent=cfg.silent,
                    mpcc_time_limit=cfg.mpcc_time_limit, mpcc_mip_gap=cfg.mpcc_mip_gap,
                    mpcc_heuristic_effort=cfg.mpcc_heuristic_effort,
                    decompose_periods=cfg.decompose_periods)
                solve2_secs = time() - tw
                busy += solve2_secs; n += 1
                # Accept pass 2 if usable, else fall back to pass 1 (as sequential).
                final = _usable(r2) ? r2 : r1
                put!(results, _result_ok(day, final, ob2, book_secs, waitq,
                    solve1_secs, rebuild_secs, solve2_secs))
            catch e
                e isa InterruptException && rethrow()
                # Pass-2 solve blew up — fall back to the pass-1 incumbent, as
                # the sequential path does. It warns there (multi_zone_run.jl);
                # here the exception was swallowed entirely, so a 1,300-day
                # record gave no way to tell which days are silently pass-1
                # only. Same result, now visible.
                @warn "pass-2 solve failed for $day — falling back to the pass-1 clear" error = sprint(showerror, e)
                put!(results, _result_ok(day, r1, ob2, book_secs, waitq,
                    solve1_secs, rebuild_secs, 0.0))
            end
        end
        progress === nothing || put!(progress, (myid(), :idle, job[2]))
    end
    return (busy, n)
end

"""
    pipeline_day_saved(day, clearing_mode, cv) -> Bool

Resume check: has this (day, clearing_mode, code_version) already been saved to
`simulations.energy_prices`? Mirrors the eval-metrics date filter (works on both
Postgres and the DuckDB results DB).
"""
function pipeline_day_saved(day::Date, clearing_mode::String, cv::Int)
    try
        df = sql2df("""
            SELECT COUNT(*) AS n
            FROM simulations.energy_prices
            WHERE clearing_mode = \$1 AND code_version = \$2
              AND date_time_utc >= (\$3::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc <  (\$4::date::timestamp AT TIME ZONE 'UTC')
        """, [clearing_mode, cv, day, day + Day(1)])
        return !isempty(df) && Int(df[1, :n]) > 0
    catch e
        @warn "resume check failed for $day — treating as not-saved" error=e
        return false
    end
end

"""
    run_pipelined_backfill(days, zones; kwargs...) -> NamedTuple

Pipelined two-pass multi-zone (merit-order) backfill over `days`.

Spawns `solver_workers` solver processes and `book_workers` book-building
processes, wires them with bounded RemoteChannels, feeds days through the
pass-1 → solve → anchor → pass-2 → solve pipeline, and saves each completed day
from a single writer on the coordinator. Produces byte-identical prices to the
sequential `run_multi_zone_market_clearing(day; passes=2, ...)` path.

# Key arguments
- `days`            : iterable of `Date`
- `zones`           : footprint (default 39-zone EU)
- `solver_workers`  : number of concurrent solver processes (default 2; MUST NOT
  exceed the Gurobi WLS concurrent-session cap — set 1 to coordinate with
  another running backfill)
- `book_workers`    : book-builder processes (default `min(10, CPU÷8)`)
- `in_flight`       : max days in flight / channel capacity (default 8)
- `optimizer`       : "gurobi" (default) / "highs" / "auto"
- `clearing_mode`   : energy_prices save key (default "multi_zone_eu")
- `save_to_db`      : persist results (default true)
- `resume`          : skip already-saved days (default true)
- `collect_prices`  : also return each day's market_prices in-memory (default
  false; the identity test uses true)
- `books_dir`       : if set, capture each backfilled day's FULL tagged order
  book to `<books_dir>/<market_date>.parquet` (pass-2 wins per zone).
  Observational — prices are byte-identical to `books_dir=nothing`.
- `duckdb_readonly_env` : pass the DuckDB read-only env to workers (auto-detected
  from the coordinator backend)

Returns `(processed, saved, failed, wall_seconds, days_per_hour,
solver_utilization, per_solver, day_prices)`.
"""
function run_pipelined_backfill(days, zones::Vector{String}=String[];
        solver_workers::Int=2,
        book_workers::Int=min(10, max(1, Sys.CPU_THREADS ÷ 8)),
        in_flight::Int=8,
        optimizer::String="gurobi",
        order_method::Symbol=:merit_order,
        enrich_network::Bool=true,
        apply_zone_profiles::Bool=true,
        clearing_mode::String="multi_zone_eu",
        silent::Bool=true,
        save_to_db::Bool=true,
        save_prices_only::Bool=false,
        resume::Bool=true,
        collect_prices::Bool=false,
        mpcc_time_limit::Float64=900.0,
        mpcc_mip_gap::Float64=1e-6,
        mpcc_heuristic_effort::Union{Float64,Nothing}=nothing,
        # Minimum distinct price periods a day must produce to be SAVED.
        #
        # The coupled clear intersects every zone's periods
        # (`common_periods = reduce(intersect, …)` in multi_zone_books.jl), so a
        # SINGLE zone with a short book truncates the whole 39-zone day. That
        # trim is deliberate on the forecast path (it drops the unpublished
        # next-CET-day tail) but on a historical backfill it silently produces
        # one-hour days: the day still carries all 39 zones, still prints DONE,
        # and resume then skips it forever. Measured on the cv24 record —
        # 65 of 1,304 days (5.0%) hold fewer than 24 UTC hours, 12 of them a
        # single hour, losing 30,810 zone-hours (2.52% of the record).
        #
        # A UTC day always has 24 hours (no DST ambiguity), so the honest bar
        # for an hourly clear is 24. Set 0 to restore the old save-anything
        # behaviour. This gate never changes a price — only whether a
        # truncated day is recorded as complete.
        min_price_periods::Int=24,
        # Same cv20 policy as run_multi_zone_market_clearing: `nothing` resolves
        # to decomposed on the enriched (EU-footprint) path — the canonical,
        # solver-invariant mode — and monolithic otherwise. Explicit wins.
        decompose_periods::Union{Nothing,Bool}=nothing,
        # Scenario passthrough (docs/scenario-api.md): a single ZoneScenario
        # applied to every zone, or Dict{String,ZoneScenario} for per-zone
        # targeting. Threaded into BOTH book stages (mz_build_books /
        # mz_rebuild_anchored), so the counterfactual applies on both passes —
        # identical semantics to run_multi_zone_market_clearing(...; scenario=).
        # nothing (default) is byte-identical to the pre-scenario pipeline.
        # NOTE: hooks are closures serialized to the book workers — define them
        # at top level of the driver script (Main) with plain captured data.
        scenario::Union{Nothing,ZoneScenario,Dict{String,ZoneScenario}}=nothing,
        # Opt-in order-book capture. When set, each book worker writes every
        # zone-day's FULL tagged book (per-unit ladders + RES/IMPORT/DEMAND/
        # BACKSTOP tags, the pre-merge strategist view) and the coordinator
        # merges pass-1 ∪ pass-2 (pass-2 wins per zone) into
        # `<books_dir>/<market_date>.parquet` (zstd; columns market_date/zone/ts/
        # side/price/mw/owner/strategy/code_version). Observational: prices are
        # bit-identical to books_dir=nothing. Captured for every USABLE day,
        # independent of save_to_db.
        books_dir::Union{Nothing,String}=nothing,
        ram_log_every::Int=10)

    order_method == :merit_order ||
        error("run_pipelined_backfill supports order_method=:merit_order only")
    solver_workers >= 1 && book_workers >= 1 ||
        error("need >=1 solver_workers and >=1 book_workers (got $solver_workers/$book_workers)")
    isempty(zones) && error("run_pipelined_backfill: `zones` must be non-empty")
    days = collect(Date, days)
    cv = ENERGY_PRICES_CODE_VERSION

    # Resume: drop already-saved days up front, so the total to process is known.
    # Under the DuckDB backend the resume probe READS simulations.* which lives
    # in the separate results_db — opt into results_writable BEFORE the probe,
    # or it errors ("results cannot be written from this process") and resume
    # silently treats every day as not-saved (full recompute on any restart;
    # observed on the cv25 record run, 2026-07-30). Same configuration the
    # coordinator sets again later with the worker extract path — idempotent.
    if resume && save_to_db && DATA_STORE[] == :duckdb
        configure_data_store!(backend=:duckdb, duckdb_path=abspath(DUCKDB_PATH[]),
                              read_only=true, results_writable=true)
    end
    todo = if resume && save_to_db
        # ONE grouped probe for the whole range (was one COUNT round-trip per
        # candidate day — a 365-day resume paid 365 serial queries before any
        # work started).
        #
        # A day counts as saved only when EVERY requested zone is present. The
        # old verdict was "any row for that day", which made a SHORT day
        # permanent: a zone whose book build failed is dropped from the clear
        # (multi_zone_books.jl rebuilds its neighbours and proceeds), the day
        # is written with 38 of 39 zones and printed DONE, and resume then
        # skipped it forever. Zone-count completeness costs nothing extra —
        # it is the same grouped scan with one more aggregate.
        saved_days = try
            df = sql2df("""
                SELECT (date_time_utc AT TIME ZONE 'UTC')::date AS d,
                       COUNT(DISTINCT bidding_zone) AS nz,
                       COUNT(DISTINCT date_time_utc) AS nh
                FROM simulations.energy_prices
                WHERE clearing_mode = \$1 AND code_version = \$2
                  AND date_time_utc >= (\$3::date::timestamp AT TIME ZONE 'UTC')
                  AND date_time_utc <  (\$4::date::timestamp AT TIME ZONE 'UTC')
                GROUP BY 1
                """, [clearing_mode, cv, minimum(days), maximum(days) + Day(1)])
            # BOTH dimensions. Zone count alone is not completeness: the cv24
            # record holds 65 days that carry all 39 zones and fewer than 24
            # hours (12 of them a single hour) because one zone's short book
            # collapsed the coupled period intersection. Those days passed a
            # zone-only check and were skipped forever.
            complete = Set(Date(r.d) for r in eachrow(df)
                           if Int(r.nz) >= length(zones) && Int(r.nh) >= min_price_periods)
            for r in eachrow(df)
                nz, nh = Int(r.nz), Int(r.nh)
                (nz >= length(zones) && nh >= min_price_periods) && continue
                @warn "resume: $(Date(r.d)) is SHORT ($nz/$(length(zones)) zones, " *
                      "$nh/$min_price_periods hours) — re-processing"
            end
            complete
        catch e
            @warn "resume range check failed — treating all days as not-saved" error = e
            Set{Date}()
        end
        keep = Date[]
        for d in days
            d in saved_days ?
                println("⏩ skip $d (already saved under $clearing_mode cv$cv)") :
                push!(keep, d)
        end
        keep
    else
        days
    end
    N = length(todo)
    if N == 0
        println("Nothing to do — all $(length(days)) day(s) already saved.")
        return (processed=0, saved=0, failed=0, wall_seconds=0.0,
                days_per_hour=0.0, solver_utilization=Float64[], per_solver=[],
                day_prices=Dict{Date,Dict{String,Dict{String,Float64}}}())
    end

    run_zone_label = clearing_mode == "multi_zone" ? "MULTI_ZONE" :
                     "MULTI_ZONE_" * uppercase(replace(clearing_mode, "multi_zone_" => ""))

    println("=" ^ 70)
    println("🔀 PIPELINED BACKFILL  days=$N/$(length(days))  zones=$(length(zones))")
    println("   solver_workers=$solver_workers  book_workers=$book_workers  in_flight=$in_flight")
    println("   optimizer=$optimizer  clearing_mode=$clearing_mode  cv=$cv  save=$save_to_db")
    println("=" ^ 70); flush(stdout)

    # --- spin up the worker pool -------------------------------------------
    extract_env = String[]
    if DATA_STORE[] == :duckdb
        extract = abspath(DUCKDB_PATH[])
        extract_env = ["EUPHEMIA_DATA_STORE" => "duckdb",
                       "EUPHEMIA_DUCKDB_PATH" => extract,
                       "EUPHEMIA_DUCKDB_READONLY" => "true",
                       "ENERGY_CONN_STR" => ""]
        # The book workers call mz_build_books directly (no run_multi_zone_
        # market_clearing wrapper), so the EU-footprint scoped :v2 default does
        # NOT apply there — the workers use the process-wide FLOW_ASOF_MODE.
        # Forward an explicitly-set coordinator mode so worker books match what
        # the coordinator (and the sequential path under the same env) builds.
        haskey(ENV, "EUPHEMIA_FLOW_ASOF_MODE") &&
            push!(extract_env, "EUPHEMIA_FLOW_ASOF_MODE" => ENV["EUPHEMIA_FLOW_ASOF_MODE"])
        # Same reasoning for the cv26 ATC Day-ahead-preference kill-switch:
        # local addprocs children inherit ENV, but SSH workers would not.
        haskey(ENV, "EUPHEMIA_DISABLE_ATC_DAPREF") &&
            push!(extract_env, "EUPHEMIA_DISABLE_ATC_DAPREF" => ENV["EUPHEMIA_DISABLE_ATC_DAPREF"])
        # cv31 solar-regime floor is default-ON: forward its kill-switch and any
        # explicit EUPHEMIA_SOLAR_REGIME* A/B overrides so worker books match the
        # coordinator (SSH workers do not inherit ENV; the book workers call
        # mz_build_books directly).
        haskey(ENV, "EUPHEMIA_DISABLE_CV31") &&
            push!(extract_env, "EUPHEMIA_DISABLE_CV31" => ENV["EUPHEMIA_DISABLE_CV31"])
        for k in ("EUPHEMIA_SOLAR_REGIME", "EUPHEMIA_SOLAR_REGIME_THETA",
                  "EUPHEMIA_SOLAR_REGIME_BLOCKS", "EUPHEMIA_SOLAR_REGIME_ZONES")
            haskey(ENV, k) && push!(extract_env, k => ENV[k])
        end
        # TR/MK boundary book (docs/experiments/tr-boundary/): the opt-in and
        # its kill-switch travel to the book workers for the same reason.
        for k in ("EUPHEMIA_ENABLE_TRMK", "EUPHEMIA_DISABLE_TRMK")
            haskey(ENV, k) && push!(extract_env, k => ENV[k])
        end
        # GR surplus-quantity lever 2 (opt-in, docs/experiments/
        # gr-surplus-quantity/): same worker-forwarding contract.
        for k in ("EUPHEMIA_ENABLE_GRSQ_T2", "EUPHEMIA_GRSQ_ZONES")
            haskey(ENV, k) && push!(extract_env, k => ENV[k])
        end
        # cv34 continental package switches (T1 zonal θ rides the existing
        # EUPHEMIA_SOLAR_REGIME* wildcarded block below if present; these are
        # the package-specific ones).
        for k in ("EUPHEMIA_CV34_PUMP_ZONES", "EUPHEMIA_CV34_PUMP_ETA",
                  "EUPHEMIA_CV34_T4_ZONES", "EUPHEMIA_SOLAR_REGIME_THETA2",
                  "EUPHEMIA_SOLAR_REGIME_FLOOR2", "EUPHEMIA_SOLAR_REGIME_THETA_FR")
            haskey(ENV, k) && push!(extract_env, k => ENV[k])
        end
        # Workers share the source extract read-only; the coordinator keeps the
        # source read-only too (so it can coexist with them) but opts into result
        # writes, which land in the SEPARATE writable results_db file.
        configure_data_store!(backend=:duckdb, duckdb_path=extract,
                              read_only=true, results_writable=true)
    end

    nprocs_add = solver_workers + book_workers
    proj = dirname(Base.active_project())
    ws = isempty(extract_env) ?
        addprocs(nprocs_add; exeflags="--project=$proj") :
        addprocs(nprocs_add; exeflags="--project=$proj", env=extract_env)
    solver_pids = ws[1:solver_workers]
    book_pids = ws[solver_workers+1:end]

    resolved_decompose = decompose_periods !== nothing ? decompose_periods :
        enrich_network
    books_dir_abs = books_dir === nothing ? nothing : abspath(books_dir)
    if books_dir_abs !== nothing
        mkpath(joinpath(books_dir_abs, ".staging"))
        println("📚 book capture ON → $books_dir_abs (one parquet per market day)")
    end
    cfg = (optimizer=optimizer, silent=silent, enrich_network=enrich_network,
           apply_zone_profiles=apply_zone_profiles, mpcc_time_limit=mpcc_time_limit,
           mpcc_mip_gap=mpcc_mip_gap, mpcc_heuristic_effort=mpcc_heuristic_effort,
           scenario=scenario, decompose_periods=resolved_decompose,
           books_dir=books_dir_abs)

    day_prices = Dict{Date,Dict{String,Dict{String,Float64}}}()
    saved = 0; failed = 0
    wall0 = 0.0
    solver_futs = []
    try
        # Load Dates alongside Euphemia: scenario hooks are closures serialized
        # from the coordinator's Main, and the documented examples reference
        # `DateTime` / `dateformat` as Main bindings — without `using Dates` on
        # the workers those references throw UndefVarError inside the per-zone
        # book build, which is caught and silently DROPS the zone from the book
        # (observed: an extra_orders hook using DateTime removed GR from all
        # 365 days of a footprint run). Base values (numbers, Dicts) captured
        # by hooks serialize fine; other package bindings do not — keep hooks
        # to Euphemia exports, Dates, and plain data.
        @everywhere ws @eval using Euphemia, Dates

        # Bounded channels. Capacity = in_flight; combined with the token
        # semaphore (≤ in_flight days live) no internal put! ever blocks.
        cap = in_flight
        bookwork = RemoteChannel(() -> Channel{Any}(cap))
        solvework = RemoteChannel(() -> Channel{Any}(cap))
        results = RemoteChannel(() -> Channel{Any}(cap))
        # `progress` is sized so workers never block reporting (start/idle per
        # job); the coordinator drains it continuously.
        progress = RemoteChannel(() -> Channel{Any}(4 * (solver_workers + book_workers) + 8))

        book_futs = [@spawnat p pipeline_book_worker(bookwork, solvework, results, zones, cfg, progress)
                     for p in book_pids]
        solver_futs = [@spawnat p pipeline_solver_worker(solvework, bookwork, results, cfg, progress)
                       for p in solver_pids]
        # All futures ever spawned (originals + crash replacements), for the
        # drain / utilization-stat collection.
        all_book_futs = copy(book_futs)
        all_solver_futs = copy(solver_futs)

        # --- #182 crash resilience -----------------------------------------
        # A HiGHS SIGSEGV (~3-4% of decomposed day-solves) kills a worker
        # PROCESS, which a try/catch in the same process cannot catch — the retry
        # must live at the coordinator (the layer that survives). Each worker
        # reports (pid, :start/:idle, day) on `progress`; the coordinator tracks
        # each worker's current day and, on a worker's death, resubmits its
        # orphaned day (retry-once) and spawns a same-kind replacement (so the
        # solver-process count == WLS session cap is preserved). Days are deduped
        # at the writer, so a resubmit racing a late genuine result is harmless.
        worker_day = Dict{Int,Union{Nothing,Date}}()
        seen = Set{Date}()          # days that produced a (first) result
        retried = Set{Date}()       # days resubmitted once after a crash
        # Live worker count per kind. When it reaches zero nothing can ever
        # produce the outstanding days, which is a terminal state the writer
        # cannot observe on its own (it blocks on `take!`).
        live_workers = Dict{Symbol,Int}(:solver => solver_workers, :book => book_workers)
        draining = Ref(false)
        progress_reader = @async begin
            while true
                msg = take!(progress)
                msg === :stop && break
                pid, ev, day = msg
                worker_day[pid] = ev === :start ? day : nothing
            end
        end
        function monitor_worker(fut, pid, kind::Symbol)
            @async begin
                try; fetch(fut); catch; end     # resolves when the process exits
                draining[] && return
                live_workers[kind] -= 1
                d = get(worker_day, pid, nothing)
                if d !== nothing && !(d in seen) && !(d in retried)
                    push!(retried, d)
                    @warn "pipeline $kind worker $pid died on $d — resubmitting (retry once)"
                    @async put!(bookwork, (:pass1, d, time()))
                elseif d !== nothing && !(d in seen)
                    # Retry already spent and STILL no result: the day is
                    # terminally lost. It must be reported as a failure, not
                    # left owing — the writer loops `while length(seen) < N`,
                    # so an unaccounted day parks it on `take!(results)` with
                    # every worker idle and the feeder drained: a silent hang
                    # that loses the rest of the run (segfaults are
                    # input-dependent, so a day that crashed once tends to
                    # crash again). Emitting the failure also returns the
                    # day's in-flight token.
                    @error "pipeline $kind worker $pid died on $d after its retry — " *
                           "day reported FAILED (rerun it with resume=true)"
                    @async put!(results, _result_failed(d; status=:error,
                        err="worker died twice (retry exhausted)"))
                elseif d !== nothing
                    @warn "pipeline $kind worker $pid died on $d — already resulted"
                else
                    @warn "pipeline $kind worker $pid died idle"
                end
                # Same-kind replacement so the pool (and WLS session count) is
                # restored; keep watching it too.
                try
                    newp = (isempty(extract_env) ?
                        addprocs(1; exeflags="--project=$proj") :
                        addprocs(1; exeflags="--project=$proj", env=extract_env))[1]
                    @everywhere [newp] @eval using Euphemia, Dates
                    push!(ws, newp)
                    nf = kind === :solver ?
                        (@spawnat newp pipeline_solver_worker(solvework, bookwork, results, cfg, progress)) :
                        (@spawnat newp pipeline_book_worker(bookwork, solvework, results, zones, cfg, progress))
                    kind === :solver ? push!(all_solver_futs, nf) : push!(all_book_futs, nf)
                    live_workers[kind] += 1      # replacement is up
                    monitor_worker(nf, newp, kind)
                catch e
                    # Same terminal-state reasoning as above: with no worker of
                    # this kind left, nothing can ever produce the outstanding
                    # days, so the writer would park forever. Report them.
                    @error "failed to spawn replacement $kind worker" error=e
                    if live_workers[kind] <= 0
                        @error "no $kind workers left — failing the $(N - length(seen)) " *
                               "outstanding day(s) so the run terminates honestly"
                        for d2 in todo
                            (d2 in seen) && continue
                            @async put!(results, _result_failed(d2; status=:error,
                                err="no $kind worker left to process the day"))
                        end
                    end
                end
            end
        end
        for (f, p) in zip(solver_futs, solver_pids); monitor_worker(f, p, :solver); end
        for (f, p) in zip(book_futs, book_pids); monitor_worker(f, p, :book); end

        # Token semaphore: at most `in_flight` days between feed and save.
        tokens = Channel{Nothing}(in_flight)
        for _ in 1:in_flight; put!(tokens, nothing); end

        wall0 = time()
        feeder = @async begin
            for d in todo
                take!(tokens)                 # backpressure
                put!(bookwork, (:pass1, d, time()))
            end
        end

        # Writer (single, on coordinator). Loops until every UNIQUE day has a
        # result (not a fixed N take!s) — a crash-resubmitted day produces a
        # second result for a day already `seen`, which is ignored here (and
        # never releases a second token, since the resubmit consumed none). This
        # is what lets the coordinator survive a worker death without deadlock.
        i = 0
        while length(seen) < N
            r = take!(results)
            if r.day in seen
                continue                      # duplicate from a crash-resubmit
            end
            push!(seen, r.day)
            i += 1
            put!(tokens, nothing)             # release for the next day
            total = r.book_secs + r.waitq_secs + r.solve1_secs + r.rebuild_secs + r.solve2_secs
            # Truncation gate (see min_price_periods). Checked here, at the
            # writer, so it applies to whatever the clear actually produced
            # rather than to what the book intended.
            n_periods = r.ok && r.final !== nothing && !isempty(r.final.market_prices) ?
                maximum(length(pd) for pd in values(r.final.market_prices)) : 0
            if r.ok && _usable(r.final) && n_periods < min_price_periods
                @error "DAY $(r.day) TRUNCATED — only $n_periods price period(s), " *
                       "need $min_price_periods. One zone's short book collapses the " *
                       "coupled intersection for every zone. NOT saved (rerun the day " *
                       "once its inputs are complete; min_price_periods=0 disables this)."
                failed += 1
                # Same housekeeping as the FAIL branch: a day that is not
                # recorded must not leave its staged books behind either.
                cfg.books_dir === nothing || _cleanup_pipeline_staging(cfg.books_dir, r.day)
                println("DAY $(r.day) TRUNCATED status=$(r.status) periods=$n_periods [$i/$N]")
                flush(stdout)
                continue
            end
            if r.ok && _usable(r.final)
                if collect_prices
                    day_prices[r.day] = deepcopy(r.final.market_prices)
                end
                # Merge this day's captured books (pass-2 wins per zone) into one
                # per-day parquet. Observational — a failure here never fails the
                # day. Independent of save_to_db so books are captured even for
                # dry runs.
                if cfg.books_dir !== nothing
                    try
                        _merge_pipeline_day_books(cfg.books_dir, r.day)
                    catch e
                        @warn "book merge failed for $(r.day) (prices unaffected)" error=e
                    end
                end
                write_ok = true
                if save_to_db
                    try
                        # save_prices_only mirrors the calibration runner: persist
                        # energy_prices only, under the given clearing_mode, WITHOUT
                        # touching the shared optimization_runs / transmission_flows
                        # keys. Otherwise the full save path (as sequential).
                        run_id = save_prices_only ? nothing :
                            save_optimization_run(run_zone_label, r.day, order_method,
                                :mpcc_multi_zone, r.final.solver_name, r.final.status;
                                objective_value=r.final.objective_value,
                                solve_time_seconds=r.final.solve_time,
                                num_orders=length(r.ob.orders),
                                num_price_periods=length(r.ob.periods))
                        # Iterate the PRICES, not the pass-2 book's node list:
                        # `r.final` can be the pass-1 result (pass-2 fallback)
                        # while `r.ob` is the pass-2 book, so a zone that
                        # cleared in pass 1 but dropped out of the pass-2
                        # rebuild had its prices silently discarded here.
                        for zone in sort(collect(keys(r.final.market_prices)))
                            save_energy_prices(r.final.market_prices[zone], zone, r.day,
                                order_method; clearing_mode=clearing_mode,
                                optimization_run_id=run_id)
                        end
                        !save_prices_only && !isempty(r.final.transmission_flows) &&
                            save_transmission_flows(r.final.transmission_flows, r.day)
                    catch e
                        write_ok = false
                        @error "save failed for $(r.day)" error=e
                    end
                end
                _r1(x) = round(x, digits=1)
                if write_ok
                    saved += 1
                    println("DAY $(r.day) DONE status=$(r.status) book=$(_r1(r.book_secs))s " *
                        "waitq=$(_r1(r.waitq_secs))s solve1=$(_r1(r.solve1_secs))s " *
                        "rebuild=$(_r1(r.rebuild_secs))s solve2=$(_r1(r.solve2_secs))s " *
                        "total=$(_r1(total))s [$i/$N]")
                else
                    # Solved fine but persistence failed — NOT a success. Count it
                    # as failed and say so, so the run summary can never claim
                    # saved=N while nothing reached the database.
                    failed += 1
                    println("DAY $(r.day) SAVE-FAILED status=$(r.status) " *
                        "(solved but not persisted) [$i/$N]")
                end
            else
                failed += 1
                # Drop any staging books left by a partial (unusable) day.
                cfg.books_dir === nothing || _cleanup_pipeline_staging(cfg.books_dir, r.day)
                println("DAY $(r.day) FAIL   status=$(r.status) err=$(something(r.err, "")) [$i/$N]")
            end
            if i % ram_log_every == 0
                free_gb = round(Sys.free_memory() / 2^30, digits=1)
                dph_so_far = round(i / max(time() - wall0, 1e-9) * 3600, digits=1)
                println("   … $i/$N done, $free_gb GB free, $dph_so_far days/h so far")
                flush(stdout)
            end
            flush(stdout)
        end

        wait(feeder)
        # Drain. `draining` stops the crash supervisor from resubmitting/replacing
        # on the clean shutdown exits below. The alive worker count is invariant
        # under the supervisor (each death is matched by one replacement), so the
        # original per-kind sentinel counts still match the live workers; dead
        # workers' futures already resolved, so the tolerant fetch never blocks.
        draining[] = true
        for _ in 1:book_workers; put!(bookwork, (:stop,)); end
        for _ in 1:solver_workers; put!(solvework, (:stop,)); end
        for f in all_book_futs; try; fetch(f); catch; end; end
        solver_futs = [(try; fetch(f); catch; (0.0, 0); end) for f in all_solver_futs]
        put!(progress, :stop)
    finally
        rmprocs(ws)
        DATA_STORE[] == :duckdb &&
            configure_data_store!(backend=:duckdb, duckdb_path=abspath(DUCKDB_PATH[]), read_only=false)
    end

    wall = time() - wall0
    per_solver = solver_futs   # Vector of (busy, n)
    utils = [wall > 0 ? b / wall : 0.0 for (b, _n) in per_solver]
    dph = N / max(wall, 1e-9) * 3600

    println("=" ^ 70)
    println("✅ PIPELINE DONE  processed=$N saved=$saved failed=$failed  " *
            "wall=$(round(wall, digits=0))s ($(round(wall/3600, digits=2)) h)")
    println("   throughput = $(round(dph, digits=1)) days/hour")
    for (k, ((b, n), u)) in enumerate(zip(per_solver, utils))
        println("   solver $k: $n solves, busy $(round(b, digits=0))s, " *
                "utilization $(round(100u, digits=1))%")
    end
    println("=" ^ 70); flush(stdout)

    return (processed=N, saved=saved, failed=failed, wall_seconds=wall,
            days_per_hour=dph, solver_utilization=utils, per_solver=per_solver,
            day_prices=day_prices)
end
