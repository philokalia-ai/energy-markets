# Run in a fresh process with a read-only extract and an isolated results path:
#   julia --project=. test/scripts/benchmark_runtime_upgrade.jl OUTPUT.json decomposed DATE...
# Modes: decomposed (canonical two-pass EU clear), monolithic (same books, no decomposition).
# This instruments the library in THIS PROCESS ONLY. No production file or input is modified.
const OPS_PROCESS_START = time_ns()
using Dates, JSON, HiGHS, SHA
const OPS_LOAD_SECONDS = @elapsed using Euphemia
using JuMP

const OPS_BOOK_TIMES = Float64[]
const OPS_SOLVES = Dict{String,Any}[]
const OPS_BOOK_FINGERPRINTS = Dict{String,Any}[]
const OPS_ZONES = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK", "IT-NORTH",
    "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria", "IT-Sicily", "IT-Sardinia", "CH",
]

function resident_mib()
    # Linux /proc reports current RSS; Sys.maxrss is cumulative across days.
    return open("/proc/self/status") do io
        for line in eachline(io)
            startswith(line, "VmRSS:") && return parse(Int, split(line)[2]) / 1024
        end
        return 0.0
    end
end

json_safe(x::AbstractFloat) = isfinite(x) ? x : string(x)
json_safe(x::AbstractDict) = Dict(k => json_safe(v) for (k, v) in x)
json_safe(x::AbstractVector) = json_safe.(x)
json_safe(x) = x

function fingerprint_book(book)
    order_rows = [join((String(o.zone), string(o.date_time), string(o.type),
                       bitstring(o.price), bitstring(o.quantity), string(o.resolution_code)), "|")
                  for o in book.orders]
    capacity_rows = String[]
    for (label, capacities) in (("forward", book.network_topology.capacity_forward),
                                ("backward", book.network_topology.capacity_backward))
        append!(capacity_rows, [join((label, a, b, t, bitstring(mw)), "|")
                                for ((a, b, t), mw) in capacities])
    end
    digest(rows) = bytes2hex(sha256(join(rows, "\n")))
    result = Dict{String,Any}("orders" => length(order_rows),
        "order_sequence_sha256" => digest(order_rows),
        "order_multiset_sha256" => digest(sort(order_rows)),
        "capacity_sha256" => digest(sort(capacity_rows)),
        "nodes" => book.nodes, "periods" => book.periods)
    if haskey(ENV, "OPS_BOOK_DUMP_PREFIX")
        prefix = ENV["OPS_BOOK_DUMP_PREFIX"] * "-" * first(book.periods) *
                 "-pass" * string(length(OPS_BOOK_FINGERPRINTS) + 1)
        write(prefix * "-orders.txt", join(order_rows, "\n"))
        write(prefix * "-capacities.txt", join(sort(capacity_rows), "\n"))
    end
    push!(OPS_BOOK_FINGERPRINTS, result)
end

function instrument_books(source, assignment)
    first_pos = findfirst(assignment, source)
    first_pos === nothing && error("Book timing insertion no longer matches: $assignment")
    last_pos = findnext("scenario=scenario)", source, last(first_pos))
    last_pos === nothing && error("Book call terminator no longer matches")
    call = source[first(first_pos):last(last_pos)]
    # begin preserves assignments in the surrounding function's local scope.
    replacement = "_ops_book_timed = @timed begin\n" * call *
        "\nend\npush!(Main.OPS_BOOK_TIMES, _ops_book_timed.time)\nMain.fingerprint_book(_ops_book_timed.value)"
    return replace(source, call => replacement; count=1)
end

function instrument!()
    root = dirname(pathof(Euphemia))
    run_file = joinpath(root, "clearing", "multi_zone_run.jl")
    source = read(run_file, String)
    source = instrument_books(source, "order_book = _create_multi_zone_order_book_merit(")
    source = instrument_books(source, "order_book2 = mz_rebuild_anchored(")
    Base.include_string(Euphemia, source, run_file)

    solver_file = joinpath(root, "mpcc", "solver.jl")
    source = read(solver_file, String)
    needle = "        solve_time = time() - start_time\n\n        # Extract results"
    occursin(needle, source) || error("Solver timing insertion no longer matches")
    addition = """
        solve_time = time() - start_time
        push!(Main.OPS_SOLVES, Dict{String,Any}(
            "periods" => copy(order_book.periods),
            "status" => string(termination_status(model)),
            "has_values" => has_values(model),
            "library_solve_seconds" => solve_time,
            "native_solve_seconds" => try JuMP.solve_time(model) catch; nothing end,
            "relative_gap" => try JuMP.relative_gap(model) catch; nothing end,
            "objective_bound" => try JuMP.objective_bound(model) catch; nothing end,
            "objective_value" => try JuMP.objective_value(model) catch; nothing end,
            "links" => length(zone_pairs),
        ))
        if length(order_book.periods) > 1
            # A hard monolithic timeout must not erase the first solver report.
            println("OPS_NATIVE ", Main.JSON.json(Main.json_safe(merge(
                last(Main.OPS_SOLVES), Dict("book_seconds" => copy(Main.OPS_BOOK_TIMES))))))
            flush(stdout)
        end

        # Extract results"""
    source = replace(source, needle => addition; count=1)
    Base.include_string(Euphemia.MPCC, source, solver_file)
end

function main()
    length(ARGS) >= 3 || error("usage: OUTPUT.json decomposed|monolithic DATE...")
    output, mode = ARGS[1:2]
    mode in ("decomposed", "monolithic") || error("Unknown mode $mode")
    Euphemia.DATA_STORE[] == :duckdb || error("A read-only DuckDB extract is required")
    Euphemia.DUCKDB_READ_ONLY[] || error("Set EUPHEMIA_DUCKDB_READONLY=true")
    instrument!()
    mkpath(dirname(abspath(output)))
    metadata = Dict{String,Any}(
        "julia" => string(VERSION), "highs_jl" => string(pkgversion(HiGHS)),
        "highs" => unsafe_string(HiGHS.Highs_version()), "jump" => string(pkgversion(JuMP)),
        "architecture" => string(Sys.ARCH), "julia_threads" => Threads.nthreads(),
        "load_euphemia_seconds" => OPS_LOAD_SECONDS,
        "startup_to_ready_seconds" => (time_ns() - OPS_PROCESS_START) / 1e9,
        "mode" => mode, "input_vintage" => "legacy record path, no ForecastContext; not certified ex-ante; scoped v3 flows",
        "solver_settings" => Dict("time_limit_seconds" => mode == "decomposed" ? 900.0 : 360.0,
            "mip_gap" => 1e-6, "heuristic_effort" => nothing,
            "decompose_periods" => mode == "decomposed",
            "source" => "bin/daily_forecast.jl clear_utc_day! inherits multi_zone_run.jl defaults"),
        "clearing_mode" => "multi_zone_eu", "code_version" => Euphemia.ENERGY_PRICES_CODE_VERSION,
        "source_revision" => get(ENV, "OPS_SOURCE_REVISION", "f2ca0db (pre-analyst-fix)"),
        "days" => Any[],
    )
    for (i, date_string) in enumerate(ARGS[3:end])
        empty!(OPS_BOOK_TIMES)
        empty!(OPS_SOLVES)
        empty!(OPS_BOOK_FINGERPRINTS)
        day = Dict{String,Any}("date" => date_string, "first_clear_in_process" => i == 1)
        started = time_ns()
        sampling = Threads.Atomic{Bool}(true)
        peak_rss = Ref(resident_mib())
        sampler = Threads.@spawn while sampling[]
            peak_rss[] = max(peak_rss[], resident_mib())
            sleep(0.2)
        end
        println("OPS_DAY_START ", date_string, " mode=", mode); flush(stdout)
        try
            # invokelatest ensures calls use the instrumented methods, including on Julia 1.14.
            # The production clear_utc_day! leaves all solver keywords at the
            # library defaults: 900 s/period, gap 1e-6, no heuristic override,
            # and canonical EU decomposition. Monolithic is a separate bounded
            # experiment, deliberately overriding only mode and time ceiling.
            options = mode == "monolithic" ?
                (mpcc_time_limit=360.0, decompose_periods=false) : NamedTuple()
            result = Base.invokelatest(Euphemia.run_multi_zone_market_clearing, Date(date_string);
                zones=OPS_ZONES, order_method=:merit_order, optimizer="highs",
                enrich_network=true, passes=2, clearing_mode="multi_zone_eu",
                save_to_db=false, silent=mode == "decomposed", options...)
            day["status"] = string(result.status)
            day["message"] = result.message
            day["returned_solve_seconds"] = result.solve_time
            day["returned_total_seconds"] = result.total_time
            day["prices"] = result.market_prices
            day["cells"] = sum(length, values(result.market_prices); init=0)
        catch err
            err isa InterruptException && rethrow()
            day["error"] = sprint(showerror, err, catch_backtrace())
            day["status"] = "exception"
        finally
            sampling[] = false
            wait(sampler)
        end
        day["wall_seconds"] = (time_ns() - started) / 1e9
        day["book_seconds"] = copy(OPS_BOOK_TIMES)
        day["book_fingerprints"] = copy(OPS_BOOK_FINGERPRINTS)
        day["solver_calls"] = copy(OPS_SOLVES)
        day["peak_rss_sampled_mib"] = peak_rss[]
        day["process_peak_rss_mib"] = Sys.maxrss() / 1024^2
        push!(metadata["days"], day)
        # Persist after each day so a later native crash cannot erase previous days.
        temporary = output * ".tmp"
        open(temporary, "w") do io
            JSON.print(io, json_safe(metadata), 2)
        end
        mv(temporary, output; force=true)
        println("OPS_DAY_DONE ", date_string, " status=", day["status"], " wall=", day["wall_seconds"])
        flush(stdout)
    end
end
main()
