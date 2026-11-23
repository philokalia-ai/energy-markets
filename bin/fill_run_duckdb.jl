# Fill step: Postgres -> run-local DuckDB (owner rule, 2026-11-23: DuckDB between Postgres and
# Julia; Julia never queries Postgres except here and in the results transfer).
#
#   julia --project=. bin/fill_run_duckdb.jl --profile daily-forecast|record|export --out DIR \
#         [--start YYYY-MM-DD --end YYYY-MM-DD] [--as-of YYYY-MM-DD] [--zones A,B,...] \
#         [--source duckdb:<path>]
# Env: ENERGY_CONN_STR; ZONES (default zone list, else the 39-zone footprint); INPUTS_BACK_DAYS
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
using Euphemia, Dates, JSON

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
    start = haskey(a, "start") ? Date(a["start"]) : nothing
    stop = haskey(a, "end") ? Date(a["end"]) : nothing
    src = get(a, "source", "postgres")
    source, source_path = src == "postgres" ? (:postgres, "") :
        startswith(src, "duckdb:") ? (:duckdb, src[8:end]) : error("--source postgres | duckdb:<path>")
    conn = source === :postgres ? get(ENV, "ENERGY_CONN_STR", "") : ""
    source === :postgres && isempty(conn) && error("ENERGY_CONN_STR is not set")

    ibd = parse(Int, get(ENV, "INPUTS_BACK_DAYS", "0"))
    p = Euphemia.fill_profile(profile; start=start, stop=stop, asof=asof, zones=zones, inputs_back_days=ibd)
    mkpath(out)
    for f in ("inputs.duckdb", "results.duckdb")
        ispath(joinpath(out, f)) && error("$(joinpath(out, f)) exists; a run directory is filled once")
    end
    tmp = joinpath(out, ".tmp-$(getpid())")
    mkpath(tmp)
    t0 = time()
    inputs = joinpath(tmp, "inputs.duckdb")
    results = joinpath(tmp, "results.duckdb")
    # per-unit feed bound: record = the gate rule; forecast/export = a week before the run day
    bound = profile === :record ? nothing : DateTime(asof) - Day(7)
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
        Euphemia.attach_postgres!(con, conn; alias="pg", read_only=true)
    else
        Euphemia.DBInterface.execute(con, "ATTACH '$(replace(source_path, "'" => "''"))' AS src (READ_ONLY)")
    end
    seeded = try
        Euphemia._FILL_SOURCE[] = source
        Euphemia.seed_run_results!(con, p.seeds)
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
    Euphemia.DBInterface.close!(wcon); Euphemia.DuckDB.close(wdb)
    info = Dict("profile" => string(profile), "days" => string.(p.days), "zones" => zones,
                "source" => string(source), "inputs_seconds" => round(t_inputs, digits=2),
                "results_seconds" => round(t_results, digits=2),
                "inputs_mib" => round(filesize(inputs) / 2^20, digits=1),
                "results_mib" => round(filesize(results) / 2^20, digits=1),
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
end

try
    main(ARGS)
catch e
    showerror(stderr, e, catch_backtrace())
    println(stderr)
    exit(1)
end
