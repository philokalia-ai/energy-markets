# Fill step: Postgres -> run-local DuckDB (owner rule, 2026-11-23: DuckDB between Postgres and
# Julia; Julia never queries Postgres except here and in the results transfer).
#
#   julia --project=. bin/fill_run_duckdb.jl --profile daily-forecast|record|export|retro|rescore --out DIR \
#         [--start YYYY-MM-DD|auto --end YYYY-MM-DD | --days D1,D2,...] [--as-of YYYY-MM-DD] [--zones A,B,...] \
#         [--source duckdb:<path>] [--seed-results false] [--seed-skip T1,T2]
# Env: ENERGY_CONN_STR; RESULTS_SOURCE_CONN_STR (optional: seeds from another database); ZONES (default zone list, else the 39-zone footprint); INPUTS_BACK_DAYS
# (export profile: export_prediction_inputs.jl's look-back on the RES/load/generation tables).
#
# Needs ENERGY_CONN_STR (unless --source duckdb:<path>, the offline proof mode that reads the
# same rows from a DuckDB extract). Produces, atomically (built under DIR/.tmp-<pid>, renamed
# only on success):
#   DIR/inputs.duckdb   read-only inputs (carries _fill.windows => the strict read guard)
#   DIR/results.duckdb  results-side slices seeded for read-back (writable by the job)
#   DIR/fill.json       per-table rows and seconds
# Exits non-zero on any failure. Jobs then run with EUPHEMIA_DATA_STORE=duckdb,
# EUPHEMIA_DUCKDB_PATH=DIR/inputs.duckdb, EUPHEMIA_DUCKDB_READONLY=true,
# EUPHEMIA_RESULTS_DB=DIR/results.duckdb and no ENERGY_CONN_STR.
# Pin Euphemia to the DuckDB backend BEFORE loading it: with ENERGY_CONN_STR set and no
# store chosen, module init would select Postgres and open the LibPQ pool, a stray
# Julia -> Postgres path beside the scanner. Init needs an existing DuckDB file, and the run's
# inputs file does not exist yet, so an empty boot file in the run's temp dir stands in.
const _T_PROCESS0 = time()   # process wall (no /usr/bin/time on the runner image): measured here
using DuckDB, Dates, JSON
function _boot_store!(argv)
    i = findfirst(==("--out"), argv)
    (i === nothing || i == length(argv)) && error("--out DIR is required")
    tmp = joinpath(argv[i + 1], ".tmp-$(getpid())")
    mkpath(tmp)
    boot = joinpath(tmp, "boot.duckdb")
    DuckDB.close(DuckDB.DB(boot))
    ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
    ENV["EUPHEMIA_DUCKDB_PATH"] = boot
    ENV["EUPHEMIA_DUCKDB_READONLY"] = "false"
    return tmp
end
const BOOT_TMP = try
    _boot_store!(ARGS)
catch e
    showerror(stderr, e); println(stderr); exit(1)
end
using Euphemia

const FOOTPRINT = String["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3","SE4","SI","SK",
    "IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH"]

function parse_args(argv)
    a = Dict{String,String}()
    i = 1
    while i <= length(argv)
        k = argv[i]
        startswith(k, "--") && i < length(argv) || error("bad argument $(k) (flags take a value)")
        a[k[3:end]] = argv[i + 1]
        i += 2
    end
    return a
end

function main(argv)
    a = parse_args(argv)
    profile = Symbol(replace(get(a, "profile", ""), "-" => "_"))
    out = get(a, "out", "")
    isempty(out) && error("--out DIR is required")
    zones = haskey(a, "zones") ? String.(split(a["zones"], ",")) :
            (!isempty(strip(get(ENV, "ZONES", ""))) ? String.(strip.(split(ENV["ZONES"], ","))) : FOOTPRINT)
    asof = haskey(a, "as-of") ? Date(a["as-of"]) : Date(Dates.now(Dates.UTC))
    start_auto = get(a, "start", "") == "auto"
    start = (haskey(a, "start") && !start_auto) ? Date(a["start"]) : nothing
    stop = haskey(a, "end") ? Date(a["end"]) : nothing
    src = get(a, "source", "postgres")
    source, source_path = src == "postgres" ? (:postgres, "") :
        startswith(src, "duckdb:") ? (:duckdb, src[8:end]) : error("--source postgres | duckdb:<path>")
    conn = source === :postgres ? get(ENV, "ENERGY_CONN_STR", "") : ""
    source === :postgres && isempty(conn) && error("ENERGY_CONN_STR is not set")

    if start_auto
        profile === :rescore || error("--start auto is only for --profile rescore")
        start = Euphemia.resolve_rescore_start(; zones=zones, conn_str=conn, source=source, source_path=source_path)
        println("FILL rescore --start auto resolved to $start (first forecast_prices market_date for the zones)")
    end
    ibd = Euphemia.env_int("INPUTS_BACK_DAYS", 0)   # empty (schedule / blank dispatch input) = unset
    dl = haskey(a, "days") ? Date.(split(a["days"], ",")) : nothing
    # daily-forecast / export: the readers' data-dependent windows, resolved from where the forecast
    # tables live (the seed source: RESULTS_SOURCE_CONN_STR on a test bed, else ENERGY_CONN_STR)
    needs = nothing
    if profile in (:daily_forecast, :export)
        sc = source === :postgres ? (isempty(get(ENV, "RESULTS_SOURCE_CONN_STR", "")) ? conn : ENV["RESULTS_SOURCE_CONN_STR"]) : ""
        needs = Euphemia.resolve_forecast_needs(; conn_str=sc, source=source, source_path=source_path)
        println("FILL $profile needs: map window from $(something(needs.map_start, "none")), " *
                "forecast history from $(something(needs.history_start, "none"))")
    end
    p = Euphemia.fill_profile(profile; start=start, stop=stop, asof=asof, zones=zones, inputs_back_days=ibd,
                              days_list=dl, needs=needs)
    mkpath(out)
    for f in ("inputs.duckdb", "results.duckdb")
        ispath(joinpath(out, f)) && error("$(joinpath(out, f)) exists; a run directory is filled once")
    end
    tmp = BOOT_TMP
    t0 = time()
    inputs = joinpath(tmp, "inputs.duckdb")
    results = joinpath(tmp, "results.duckdb")
    # per-unit feed bound: record = the gate rule; forecast/export = a week before the run day
    bound = profile in (:record, :retro, :rescore) ? nothing : DateTime(asof) - Day(7)
    Euphemia.fill_run_duckdb(inputs; days=p.days, zones=zones, conn_str=conn, specs=p.specs,
                             feed_bound_min=bound, source=source, source_path=source_path)
    t_inputs = time() - t0

    # results-side read-back slices into results.duckdb (through the backend's results attach)
    t1 = time()
    Euphemia.RESULTS_DB_PATH[] = results
    Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=inputs, read_only=true, results_writable=true)
    con = Euphemia._duckdb_connection()
    Euphemia._ensure_results_attached(con)
    isdefined(Euphemia, :ensure_run_results_tables!) && Euphemia.ensure_run_results_tables!()
    if source === :postgres
        # RESULTS_SOURCE_CONN_STR: the results-side seeds come from another database (test beds
        # that keep the forecast tables apart from the inputs); production leaves it unset.
        seed_conn = get(ENV, "RESULTS_SOURCE_CONN_STR", "")
        Euphemia.attach_postgres!(con, isempty(seed_conn) ? conn : seed_conn; alias="pg", read_only=true)
    else
        Euphemia.DBInterface.execute(con, "ATTACH '$(replace(source_path, "'" => "''"))' AS src (READ_ONLY)")
    end
    # --seed-results false: an empty results.duckdb (rigs that must not resume-skip on rows the
    # source already holds for these days; production keeps the seeds)
    # A read-back of an unseeded table raises under the fill (results_db._fill.seeds), so a rig that only
    # needs to recompute existing days skips just those seeds: --seed-skip energy_prices
    seeds = lowercase(get(a, "seed-results", "true")) == "false" ? NamedTuple[] : p.seeds
    skip = haskey(a, "seed-skip") ? Set(String.(split(a["seed-skip"], ","))) : Set{String}()
    seeds = [sd for sd in seeds if !(sd.table in skip)]
    seeded = try
        Euphemia._FILL_SOURCE[] = source
        Euphemia.seed_run_results!(con, seeds)
    finally
        Euphemia._FILL_SOURCE[] = :postgres
        source === :postgres ? Euphemia.detach_postgres!(con) : Euphemia.DBInterface.execute(con, "DETACH src")
        Euphemia._duckdb_drop_connection!()
    end
    t_results = time() - t1

    wdb = Euphemia.DuckDB.DB(inputs; readonly=true)
    wcon = Euphemia.DBInterface.connect(wdb)
    windows = [Dict("table" => string(r.schema_name, ".", r.table_name), "kind" => r.kind,
                    "lo" => string(r.lo), "hi" => string(r.hi), "rows" => r.n_rows, "seconds" => r.seconds)
               for r in Euphemia.DBInterface.execute(wcon, "SELECT * FROM _fill.windows ORDER BY schema_name, table_name, lo")]
    run_row = collect(Euphemia.DBInterface.execute(wcon, "SELECT source_timezone, scanner_timezone FROM _fill.run"))[1]
    source_tz = String(run_row.source_timezone); scanner_tz = String(run_row.scanner_timezone)
    absent = [w["table"] for w in windows if w["kind"] == "absent"]
    Euphemia.DBInterface.close!(wcon); Euphemia.DuckDB.close(wdb)
    # Peak resident memory of this process (kB) from the kernel: the runner image has no /usr/bin/time.
    vmhwm = try parse(Int, match(r"VmHWM:\s*(\d+)", read("/proc/self/status", String))[1]) catch; -1 end
    info = Dict("profile" => string(profile), "start" => start === nothing ? nothing : string(start),
                "end" => stop === nothing ? nothing : string(stop), "days" => string.(p.days), "zones" => zones,
                "process_wall_s" => round(time() - _T_PROCESS0, digits=2), "peak_rss_kb" => vmhwm,
                "source" => string(source), "inputs_seconds" => round(t_inputs, digits=2),
                "results_seconds" => round(t_results, digits=2),
                "inputs_mib" => round(filesize(inputs) / 2^20, digits=1),
                "results_mib" => round(filesize(results) / 2^20, digits=1),
                # pg_timezone: current_setting('TimeZone') of the Postgres session through postgres_query
                # (pinned to UTC; attach_postgres! refuses anything else); scanner_timezone: the fill's
                # DuckDB connection
                "source_timezone" => source_tz, "pg_timezone" => source_tz, "scanner_timezone" => scanner_tz,
                "map_start" => needs === nothing || needs.map_start === nothing ? nothing : string(needs.map_start),
                "history_start" => needs === nothing || needs.history_start === nothing ? nothing : string(needs.history_start),
                "absent_in_source" => absent,
                "windows" => windows,
                "seeds" => [Dict("table" => s.table, "rows" => s.rows, "seconds" => round(s.seconds, digits=2)) for s in seeded])
    open(joinpath(tmp, "fill.json"), "w") do io
        JSON.print(io, info, 1)
    end
    for f in ("inputs.duckdb", "results.duckdb", "fill.json")
        mv(joinpath(tmp, f), joinpath(out, f))
    end
    rm(tmp; recursive=true, force=true)
    println("FILL $(profile) done: inputs $(info["inputs_mib"]) MiB in $(info["inputs_seconds"]) s, " *
            "results $(info["results_mib"]) MiB in $(info["results_seconds"]) s -> $out")
    println("FILL process: wall $(info["process_wall_s"]) s, peak RSS $(info["peak_rss_kb"]) kB")
end

try
    main(ARGS)
catch e
    showerror(stderr, e, catch_backtrace())
    println(stderr)
    exit(1)
end
