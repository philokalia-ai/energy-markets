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
                              results::RemoteChannel, zones::Vector{String}, cfg)
    handled = 0
    while true
        job = take!(bookwork)
        job[1] === :stop && break
        handled += 1
        if job[1] === :pass1
            (_, day, _t_feed) = job
            try
                t0 = time()
                ob1 = mz_build_books(zones, day;
                    enrich_network=cfg.enrich_network,
                    apply_zone_profiles=cfg.apply_zone_profiles,
                    scenario=cfg.scenario)
                book_secs = time() - t0
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
                put!(solvework, (:pass2, day, ob2, r1, book_secs, waitq,
                                 solve1_secs, rebuild_secs, time()))
            catch e
                e isa InterruptException && rethrow()
                put!(results, _result_failed(day; status=:error,
                    book_secs=book_secs, waitq_secs=waitq, solve1_secs=solve1_secs,
                    err="pass-2 rebuild: " * sprint(showerror, e)))
            end
        end
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
                                results::RemoteChannel, cfg)
    busy = 0.0
    n = 0
    while true
        job = take!(solvework)
        job[1] === :stop && break
        if job[1] === :pass1
            (_, day, ob1, book_secs, t_build_done) = job
            waitq = time() - t_build_done
            try
                tw = time()
                r1 = mz_solve_pass(ob1; optimizer=cfg.optimizer, silent=cfg.silent,
                    mpcc_time_limit=cfg.mpcc_time_limit, mpcc_mip_gap=cfg.mpcc_mip_gap,
                    mpcc_heuristic_effort=cfg.mpcc_heuristic_effort)
                solve1_secs = time() - tw
                busy += solve1_secs; n += 1
                if !_usable(r1)
                    put!(results, _result_failed(day; status=r1.status,
                        book_secs=book_secs, waitq_secs=waitq, solve1_secs=solve1_secs,
                        err="pass-1 solve produced no prices"))
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
                    mpcc_heuristic_effort=cfg.mpcc_heuristic_effort)
                solve2_secs = time() - tw
                busy += solve2_secs; n += 1
                # Accept pass 2 if usable, else fall back to pass 1 (as sequential).
                final = _usable(r2) ? r2 : r1
                put!(results, _result_ok(day, final, ob2, book_secs, waitq,
                    solve1_secs, rebuild_secs, solve2_secs))
            catch e
                e isa InterruptException && rethrow()
                # Pass-2 solve blew up — fall back to the pass-1 incumbent.
                put!(results, _result_ok(day, r1, ob2, book_secs, waitq,
                    solve1_secs, rebuild_secs, 0.0))
            end
        end
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
        # Scenario passthrough (docs/scenario-api.md): a single ZoneScenario
        # applied to every zone, or Dict{String,ZoneScenario} for per-zone
        # targeting. Threaded into BOTH book stages (mz_build_books /
        # mz_rebuild_anchored), so the counterfactual applies on both passes —
        # identical semantics to run_multi_zone_market_clearing(...; scenario=).
        # nothing (default) is byte-identical to the pre-scenario pipeline.
        # NOTE: hooks are closures serialized to the book workers — define them
        # at top level of the driver script (Main) with plain captured data.
        scenario::Union{Nothing,ZoneScenario,Dict{String,ZoneScenario}}=nothing,
        ram_log_every::Int=10)

    order_method == :merit_order ||
        error("run_pipelined_backfill supports order_method=:merit_order only")
    solver_workers >= 1 && book_workers >= 1 ||
        error("need >=1 solver_workers and >=1 book_workers (got $solver_workers/$book_workers)")
    isempty(zones) && error("run_pipelined_backfill: `zones` must be non-empty")
    days = collect(Date, days)
    cv = ENERGY_PRICES_CODE_VERSION

    # Resume: drop already-saved days up front, so the total to process is known.
    todo = if resume && save_to_db
        keep = Date[]
        for d in days
            pipeline_day_saved(d, clearing_mode, cv) ?
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

    cfg = (optimizer=optimizer, silent=silent, enrich_network=enrich_network,
           apply_zone_profiles=apply_zone_profiles, mpcc_time_limit=mpcc_time_limit,
           mpcc_mip_gap=mpcc_mip_gap, mpcc_heuristic_effort=mpcc_heuristic_effort,
           scenario=scenario)

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

        book_futs = [@spawnat p pipeline_book_worker(bookwork, solvework, results, zones, cfg)
                     for p in book_pids]
        solver_futs = [@spawnat p pipeline_solver_worker(solvework, bookwork, results, cfg)
                       for p in solver_pids]

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

        # Writer (single, on coordinator).
        for i in 1:N
            r = take!(results)
            put!(tokens, nothing)             # release for the next day
            total = r.book_secs + r.waitq_secs + r.solve1_secs + r.rebuild_secs + r.solve2_secs
            if r.ok && _usable(r.final)
                if collect_prices
                    day_prices[r.day] = deepcopy(r.final.market_prices)
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
                        for zone in r.ob.nodes
                            haskey(r.final.market_prices, zone) &&
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
        # Drain: all days are through, so no real jobs remain. Send sentinels.
        for _ in book_pids; put!(bookwork, (:stop,)); end
        for _ in solver_pids; put!(solvework, (:stop,)); end
        foreach(fetch, book_futs)
        solver_futs = [fetch(f) for f in solver_futs]
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
