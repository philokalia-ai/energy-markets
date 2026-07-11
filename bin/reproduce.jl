# bin/reproduce.jl — one-command reproduction of the Euphemia competitive
# counterfactual against the published, self-contained DuckDB extract. Runs
# fully OFFLINE (no Postgres): it clears the market from the extract, saves the
# prices to a local results DuckDB, then scores them against the extract's own
# ENTSO-E day-ahead actuals with the resolution-aware methodology, and writes a
# markdown + CSV report under results/.
#
# Tiers:
#   --quick                  GR single-zone + 39-zone EU multi-zone, 2026-04-01..05
#   --range START END        multi-zone EU clear over [START,END]
#         [--zones A,B,...]   (restrict the footprint; default all 39)
#         [--single Z]        also single-zone-clear zone Z over the window
#   --full                   the 3.5-year GR single-zone backfill + monthly-sampled
#                            EU multi-zone weeks (~hours; the full 3.5y × 39 zones
#                            is ~24h — available but not the default)
#
# Common options:
#   --optimizer highs|gurobi   default highs (no license needed; Gurobi optional)
#   --order-method merit_order (default; the counterfactual path)
#   --workers N|auto           parallelize across DAYS with N worker processes
#                              (default 0 = sequential; auto = CPU_THREADS ÷ 2,
#                              capped at the number of days). Workers share the
#                              extract via DuckDB's read-only multi-process mode
#                              and clear with save_to_db=false; the COORDINATOR
#                              persists the returned prices, so the single-writer
#                              results DB is only ever touched by one process.
#   --pipeline                 run the multi-zone EU jobs through the
#                              producer/consumer pipeline: book-builder workers
#                              build the 39-zone two-pass books ahead in memory
#                              while a small pool of solver workers stays
#                              saturated with Gurobi (it "never sits"). Resumable
#                              per day. Single-zone jobs still run sequentially.
#         [--book-workers M]   book-builder processes (default min(10, CPU÷8))
#         [--solver-workers S] concurrent Gurobi solver processes (default 2 =
#                              WLS session cap; use 1 to share the license with
#                              another running backfill)
#
# Backend: uses the DuckDB extract auto-detected by the module, or set
#   EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_PATH=/path/to/extract.duckdb
# Results persist to data/results.duckdb (override EUPHEMIA_RESULTS_DB).

using Euphemia
using Dates
using Printf
using Statistics
using Distributed

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

include(joinpath(@__DIR__, "..", "test", "scripts", "eu_eval_metrics.jl"))

# --------------------------------------------------------------------------
# Backend resolution: make sure we are on a DuckDB extract if one is available,
# so the run is genuinely offline. Explicit env is respected by the module.
# --------------------------------------------------------------------------
function ensure_duckdb_backend()
    Euphemia.DATA_STORE[] == :duckdb && return true
    candidates = String[]
    p = get(ENV, "EUPHEMIA_DUCKDB_PATH", ""); !isempty(p) && push!(candidates, p)
    push!(candidates, "data/extracts/euphemia-public.duckdb")
    push!(candidates, "data/public/euphemia-public.duckdb")
    for c in candidates
        if isfile(c)
            Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=c)
            return true
        end
    end
    @warn "No DuckDB extract found — running on the current backend (Postgres). " *
          "For an offline reproduction, download the extract (see docs/reproducibility.md)."
    return false
end

# --------------------------------------------------------------------------
# Clearing helpers (sequential + day-parallel)
# --------------------------------------------------------------------------
daterange(sd::Date, ed::Date) = sd:Day(1):ed

function clear_single_zone(zone::String, days; order_method::Symbol, optimizer::String)
    println("\n▶ Single-zone $zone: $(first(days)) .. $(last(days))  ($(length(days)) days)")
    ok = 0
    for d in days
        try
            generate_energy_prices(zone, d; order_method=order_method, optimizer=optimizer,
                                   save_to_db=true)
            ok += 1
        catch e
            @warn "single-zone clear failed" zone=zone day=d error=e
        end
        print("."); flush(stdout)
    end
    println("  [$ok/$(length(days)) days]")
end

function clear_multi_zone(zones::Vector{String}, days; order_method::Symbol, optimizer::String)
    println("\n▶ Multi-zone EU ($(length(zones)) zones): $(first(days)) .. $(last(days))  ($(length(days)) days)")
    ok = 0
    for d in days
        try
            res = run_multi_zone_market_clearing(d; zones=zones, order_method=order_method,
                optimizer=optimizer, enrich_network=true, passes=2,
                clearing_mode="multi_zone", save_to_db=true, silent=true,
                mpcc_time_limit=mpcc_budget(optimizer),
                mpcc_heuristic_effort=optimizer == "highs" ? 0.3 : nothing)
            # A day only counts if it produced prices (TIME_LIMIT with no
            # incumbent throws nothing but yields an empty result).
            usable = res.status == :optimal ||
                     (res.status == :time_limit && !isempty(res.market_prices))
            usable ? (ok += 1) : @warn "multi-zone clear produced no prices" day=d status=res.status
        catch e
            @warn "multi-zone clear failed" day=d error=e
        end
        print("."); flush(stdout)
    end
    println("  [$ok/$(length(days)) days]")
end

# MPCC time budget per solver: Gurobi closes the 39-zone MIP in ~10-60 s, so the
# library default (900 s) is ample. HiGHS needs far longer to find its first
# incumbent on the 39-zone complementarity MIP.
mpcc_budget(optimizer::String) = optimizer == "highs" ? 3600.0 : 900.0

# --------------------------------------------------------------------------
# Day-parallel clearing. DuckDB is single-writer but supports any number of
# read-only PROCESSES on one file. The coordinator drops its extract handle to
# read-only, spawns workers that open the extract read-only
# (EUPHEMIA_DUCKDB_READONLY=true), pmap-clears the days with save_to_db=false,
# tears the pool down, reopens read-write, and only THEN persists the returned
# prices — the results DB is only ever touched by this one process.
# --------------------------------------------------------------------------
function with_worker_pool(f, nworkers::Int)
    nworkers <= 0 && return f()
    Euphemia.DATA_STORE[] == :duckdb ||
        error("--workers requires the DuckDB extract backend")
    extract = abspath(Euphemia.DUCKDB_PATH[])
    Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract, read_only=true)
    ws = addprocs(nworkers;
        exeflags="--project=$(dirname(Base.active_project()))",
        env=["EUPHEMIA_DATA_STORE" => "duckdb",
             "EUPHEMIA_DUCKDB_PATH" => extract,
             "EUPHEMIA_DUCKDB_READONLY" => "true",
             "ENERGY_CONN_STR" => ""])
    try
        @everywhere ws @eval using Euphemia
        return f()
    finally
        rmprocs(ws)
        # Back to read-write so the coordinator can persist results and score.
        Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract, read_only=false)
    end
end

# pmap over days: single-zone clears, results returned (NOT saved — workers and
# the coordinator are read-only while the pool is up).
function parallel_clear_single(zone::String, days; order_method::Symbol, optimizer::String)
    println("\n▶ Single-zone $zone (parallel): $(first(days)) .. $(last(days))  ($(length(days)) days)")
    return pmap(collect(days)) do d
        try
            (day=d, prices=generate_energy_prices(zone, d; order_method=order_method,
                optimizer=optimizer, save_to_db=false), err=nothing)
        catch e
            (day=d, prices=nothing, err=sprint(showerror, e))
        end
    end
end

# pmap over days: multi-zone clears, results returned.
function parallel_clear_multi(zones::Vector{String}, days; order_method::Symbol, optimizer::String)
    println("\n▶ Multi-zone EU ($(length(zones)) zones, parallel): $(first(days)) .. $(last(days))  ($(length(days)) days)")
    # Capture plain VALUES (not Main functions) — pmap closures must not
    # reference coordinator-only bindings.
    tl = mpcc_budget(optimizer)
    he = optimizer == "highs" ? 0.3 : nothing
    return pmap(collect(days)) do d
        try
            res = run_multi_zone_market_clearing(d; zones=zones, order_method=order_method,
                optimizer=optimizer, enrich_network=true, passes=2,
                clearing_mode="multi_zone", save_to_db=false, silent=true,
                mpcc_time_limit=tl,
                mpcc_heuristic_effort=he)
            usable = res.status == :optimal ||
                     (res.status == :time_limit && !isempty(res.market_prices))
            usable ||
                return (day=d, market_prices=nothing, flows=nothing, status=res.status,
                        objective=nothing, solve_time=nothing, solver=nothing,
                        err="no prices (status=$(res.status))")
            (day=d, market_prices=res.market_prices, flows=res.transmission_flows,
             status=res.status, objective=res.objective_value, solve_time=res.solve_time,
             solver=res.solver_name, err=nothing)
        catch e
            (day=d, market_prices=nothing, flows=nothing, status=nothing,
             objective=nothing, solve_time=nothing, solver=nothing, err=sprint(showerror, e))
        end
    end
end

# Persist parallel single-zone results (coordinator, read-write, after teardown).
function persist_single(zone::String, results; order_method::Symbol, optimizer::String)
    ok = 0
    for r in results
        if r.err !== nothing || r.prices === nothing
            @warn "single-zone clear failed" zone=zone day=r.day error=r.err
            continue
        end
        run_id = save_optimization_run(zone, r.day, order_method, :mpcc, optimizer, :optimal;
            num_price_periods=length(r.prices))
        save_energy_prices(r.prices, zone, r.day, order_method;
            clearing_mode="single_zone", optimization_run_id=run_id)
        ok += 1
    end
    println("  single-zone $zone: [$ok/$(length(results)) days saved]")
end

# Persist parallel multi-zone results (mirrors run_multi_zone's own save block).
function persist_multi(results; order_method::Symbol, optimizer::String)
    ok = 0
    for r in results
        if r.err !== nothing || r.market_prices === nothing
            @warn "multi-zone clear failed" day=r.day error=r.err
            continue
        end
        run_id = save_optimization_run("MULTI_ZONE", r.day, order_method,
            :mpcc_multi_zone, something(r.solver, optimizer), something(r.status, :optimal);
            objective_value=r.objective, solve_time_seconds=r.solve_time)
        for (zone, prices) in r.market_prices
            save_energy_prices(prices, zone, r.day, order_method;
                clearing_mode="multi_zone", optimization_run_id=run_id)
        end
        r.flows !== nothing && !isempty(r.flows) && save_transmission_flows(r.flows, r.day)
        ok += 1
    end
    println("  multi-zone: [$ok/$(length(results)) days saved]")
end

# Monthly-sampled representative weeks (one 7-day week per month) across a window.
function sampled_weeks(sd::Date, ed::Date)
    days = Date[]
    m = firstdayofmonth(sd)
    while m <= ed
        wk_start = max(m, sd)
        for k in 0:6
            d = wk_start + Day(k)
            d <= ed && push!(days, d)
        end
        m += Month(1)
    end
    return days
end

# --------------------------------------------------------------------------
# Metrics + reporting
# --------------------------------------------------------------------------
function score_and_report(sections, tier::String)
    mkpath("results")
    report = joinpath("results", "$(tier)_report.md")
    csv = joinpath("results", "$(tier)_metrics.csv")
    open(report, "w") do io
        println(io, "# Euphemia reproduction report — `$tier`")
        println(io)
        println(io, "- generated: ", now(UTC), " UTC")
        println(io, "- backend: ", Euphemia.DATA_STORE[] == :duckdb ?
                "DuckDB extract (offline)" : "PostgreSQL")
        println(io, "- code_version: ", Euphemia.ENERGY_PRICES_CODE_VERSION)
        println(io, "- methodology: resolution-aware actuals; bias = sim − actual (€/MWh)")
        println(io)
        open(csv, "w") do cio
            println(cio, "section,clearing_mode,zone,n,corr,mae,bias,sim_mean,act_mean")
            for (label, cm, sd, ed, zones) in sections
                rows = metrics(cm, Euphemia.ENERGY_PRICES_CODE_VERSION, sd, ed; zones=zones)
                println(io, "## $label")
                println(io)
                if isempty(rows)
                    println(io, "_no scored rows (no overlapping actuals)_\n")
                    continue
                end
                println(io, "| zone | n | corr | MAE | bias | sim μ | act μ |")
                println(io, "|------|---:|-----:|----:|-----:|------:|------:|")
                for r in sort(rows, by=x -> x.z)
                    @printf(io, "| %s | %d | %.3f | %.2f | %+.2f | %.2f | %.2f |\n",
                            r.z, r.n, r.corr, r.mae, r.bias, r.simμ, r.actμ)
                    @printf(cio, "%s,%s,%s,%d,%.4f,%.4f,%.4f,%.4f,%.4f\n",
                            label, cm, r.z, r.n, r.corr, r.mae, r.bias, r.simμ, r.actμ)
                end
                maes = [r.mae for r in rows]; corrs = [r.corr for r in rows if !isnan(r.corr)]
                biases = [r.bias for r in rows]
                @printf(io, "\n**Summary (%d zones): mean MAE %.2f, mean corr %.3f, mean bias %+.2f**\n\n",
                        length(rows), mean(maes), isempty(corrs) ? NaN : mean(corrs), mean(biases))
            end
        end
    end
    println("\n📄 Wrote $report and $csv")

    # For --quick, diff against the committed reference if present.
    if tier == "quick"
        ref = joinpath("results", "reference", "quick_metrics.csv")
        if isfile(ref)
            println("\n🔎 Diff vs committed reference ($ref):")
            compare_to_reference(csv, ref)
        else
            println("\n(no committed reference at $ref — this run can seed it)")
        end
    end
    return csv
end

# Compare per-(section,zone) MAE/bias/corr to a reference CSV; flag drift.
function compare_to_reference(csv::String, ref::String)
    parse_rows(path) = begin
        d = Dict{Tuple{String,String},NTuple{3,Float64}}()
        for (i, ln) in enumerate(eachline(path))
            i == 1 && continue
            f = split(ln, ",")
            length(f) >= 7 || continue
            d[(f[1], f[3])] = (parse(Float64, f[5]), parse(Float64, f[6]), parse(Float64, f[7]))
        end
        d
    end
    cur = parse_rows(csv); rf = parse_rows(ref)
    maxdrift = 0.0
    for (k, (corr, mae, bias)) in cur
        haskey(rf, k) || continue
        rc, rm, rb = rf[k]
        dmae = abs(mae - rm); dbias = abs(bias - rb)
        maxdrift = max(maxdrift, dmae, dbias)
        if dmae > 0.5 || dbias > 0.5
            @printf("  DRIFT %-24s MAE %.2f→%.2f  bias %+.2f→%+.2f\n", string(k), rm, mae, rb, bias)
        end
    end
    @printf("  max |Δ MAE|,|Δ bias| vs reference: %.4f €/MWh %s\n",
            maxdrift, maxdrift < 0.5 ? "✅ within tolerance" : "⚠️ review")
end

# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
function parse_args(argv)
    # Default optimizer "auto": Gurobi when installed, else HiGHS. Single-zone
    # clears run fine on HiGHS; the 39-zone coupled MIP currently needs Gurobi
    # to find an incumbent (HiGHS: none within 1 h — see docs/reproducibility.md).
    opts = Dict{String,Any}("tier" => nothing, "optimizer" => "auto",
        "order_method" => :merit_order, "zones" => FOOTPRINT, "single" => nothing,
        "start" => nothing, "stop" => nothing, "workers" => "0",
        "pipeline" => false, "book_workers" => "0", "solver_workers" => "2")
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--quick"; opts["tier"] = "quick"
        elseif a == "--full"; opts["tier"] = "full"
        elseif a == "--range"
            opts["tier"] = "range"
            opts["start"] = Date(argv[i+1]); opts["stop"] = Date(argv[i+2]); i += 2
        elseif a == "--zones"
            opts["zones"] = String[strip(z) for z in split(argv[i+1], ",") if !isempty(strip(z))]; i += 1
        elseif a == "--single"; opts["single"] = argv[i+1]; i += 1
        elseif a == "--optimizer"; opts["optimizer"] = argv[i+1]; i += 1
        elseif a == "--order-method"; opts["order_method"] = Symbol(argv[i+1]); i += 1
        elseif a == "--workers"; opts["workers"] = argv[i+1]; i += 1
        elseif a == "--pipeline"; opts["pipeline"] = true
        elseif a == "--book-workers"; opts["book_workers"] = argv[i+1]; i += 1
        elseif a == "--solver-workers"; opts["solver_workers"] = argv[i+1]; i += 1
        else; @warn "ignoring unknown argument: $a"
        end
        i += 1
    end
    return opts
end

# Resolve --workers N|auto against the number of days to clear.
function resolve_workers(spec::AbstractString, ndays::Int)
    w = lowercase(strip(spec)) == "auto" ? Sys.CPU_THREADS ÷ 2 : parse(Int, spec)
    return max(0, min(w, ndays))
end

function main(argv)
    opts = parse_args(argv)
    tier = opts["tier"]
    tier === nothing && (println("usage: julia --project=. bin/reproduce.jl [--quick | --range S E [--zones ...] [--single Z] | --full] [--optimizer highs|gurobi] [--workers N|auto] [--pipeline [--book-workers M] [--solver-workers S]]"); return 1)
    om = opts["order_method"]
    # Resolve "auto" to the concrete solver now, so the per-solver MPCC budget
    # and the report metadata are exact.
    opt = lowercase(Euphemia.select_solver(opts["optimizer"])[2])
    println("Optimizer: ", opt)

    offline = ensure_duckdb_backend()
    println("Backend: ", Euphemia.DATA_STORE[], offline ? "  (offline reproduction)" : "")

    # Each tier defines: single-zone jobs (zone, days) and multi-zone jobs (zones, days).
    single_jobs = Tuple{String,Any}[]
    multi_jobs = Tuple{Vector{String},Any}[]
    sections = Any[]
    local ndays
    if tier == "quick"
        sd, ed = Date(2026, 4, 1), Date(2026, 4, 5)
        days = daterange(sd, ed); ndays = length(days)
        push!(single_jobs, ("GR", days))
        push!(multi_jobs, (FOOTPRINT, days))
        push!(sections, ("GR single-zone $sd..$ed", "single_zone", sd, ed, ["GR"]))
        push!(sections, ("EU 39-zone multi-zone $sd..$ed", "multi_zone", sd, ed, FOOTPRINT))
    elseif tier == "range"
        sd, ed = opts["start"], opts["stop"]
        zs = opts["zones"]
        days = daterange(sd, ed); ndays = length(days)
        push!(multi_jobs, (zs, days))
        push!(sections, ("EU multi-zone $sd..$ed", "multi_zone", sd, ed, zs))
        if opts["single"] !== nothing
            push!(single_jobs, (opts["single"], days))
            push!(sections, ("$(opts["single"]) single-zone $sd..$ed", "single_zone", sd, ed, [opts["single"]]))
        end
    elseif tier == "full"
        sd, ed = Date(2023, 1, 1), Date(2026, 6, 30)
        println("\n⏳ --full: 3.5-year GR single-zone backfill + monthly-sampled EU weeks.")
        days = daterange(sd, ed); ndays = length(days)
        push!(single_jobs, ("GR", days))
        push!(multi_jobs, (FOOTPRINT, sampled_weeks(sd, ed)))
        push!(sections, ("GR single-zone $sd..$ed", "single_zone", sd, ed, ["GR"]))
        push!(sections, ("EU 39-zone multi-zone (monthly-sampled weeks) $sd..$ed", "multi_zone", sd, ed, FOOTPRINT))
    end

    t0 = time()
    # --pipeline: run the multi-zone EU jobs through the producer/consumer
    # pipeline (book workers build ahead while a small pool of solver workers
    # stays saturated with Gurobi). Single-zone jobs (no two-pass structure) run
    # on the ordinary sequential path. Days already saved are skipped (resume).
    if opts["pipeline"]
        for (zone, days) in single_jobs
            clear_single_zone(zone, days; order_method=om, optimizer=opt)
        end
        bw = parse(Int, opts["book_workers"])
        bw <= 0 && (bw = min(10, max(1, Sys.CPU_THREADS ÷ 8)))
        sw = parse(Int, opts["solver_workers"])
        he = opt == "highs" ? 0.3 : nothing
        for (zones, days) in multi_jobs
            run_pipelined_backfill(collect(days), zones;
                solver_workers=sw, book_workers=bw,
                optimizer=opt, clearing_mode="multi_zone", save_to_db=true,
                resume=true, mpcc_time_limit=mpcc_budget(opt),
                mpcc_heuristic_effort=he)
        end
        @printf("\nClearing done in %.0f s. Scoring...\n", time() - t0)
        score_and_report(sections, tier)
        @printf("Total %.0f s.\n", time() - t0)
        return 0
    end
    nw = resolve_workers(opts["workers"], ndays)
    if nw > 0
        println("Parallel mode: $nw workers (day-level, DuckDB read-only sharing)")
        # Clear everything read-only in the pool, persist afterwards read-write.
        sz_results = Any[]; mz_results = Any[]
        with_worker_pool(nw) do
            for (zone, days) in single_jobs
                push!(sz_results, (zone, parallel_clear_single(zone, days; order_method=om, optimizer=opt)))
            end
            for (zones, days) in multi_jobs
                push!(mz_results, parallel_clear_multi(zones, days; order_method=om, optimizer=opt))
            end
        end
        for (zone, results) in sz_results
            persist_single(zone, results; order_method=om, optimizer=opt)
        end
        for results in mz_results
            persist_multi(results; order_method=om, optimizer=opt)
        end
    else
        for (zone, days) in single_jobs
            clear_single_zone(zone, days; order_method=om, optimizer=opt)
        end
        for (zones, days) in multi_jobs
            clear_multi_zone(zones, days; order_method=om, optimizer=opt)
        end
    end

    @printf("\nClearing done in %.0f s. Scoring...\n", time() - t0)
    score_and_report(sections, tier)
    @printf("Total %.0f s.\n", time() - t0)
    return 0
end

exit(main(ARGS))
