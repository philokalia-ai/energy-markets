#!/usr/bin/env julia
# measure_duckdb_path.jl — timing (and a price cross-check) of the current Postgres read path vs the fill → DuckDB
# path, for .github/workflows/measure-duckdb-path.yml (perf-96; owner rule 2026-11-23). READ-ONLY: it clears with
# save_to_db=false and never writes Postgres or the results DuckDB.
#
#   clear:   julia --project=. bin/measure_duckdb_path.jl clear --days 2026-11-18,2026-11-19 --label pg --out DIR
#                [--entry forecast|record]   forecast (default) = the daily forecast's call (run_multi_zone_market_clearing,
#                passes=2): the timing production runs every day; record = the pipelined record's stage functions
#                (bit-identical to the record, so also comparable with it). Both backends must use the same entry.
#            The backend is whatever the environment selects: ENERGY_CONN_STR + EUPHEMIA_DATA_STORE=postgres for the
#            current path; EUPHEMIA_DATA_STORE=duckdb + EUPHEMIA_DUCKDB_PATH=<filled inputs> for the DuckDB path.
#            Each day: the chosen entry's clear (gate context, two passes), with per-day wall time. Writes DIR/prices_<label>.csv and
#            DIR/times_<label>.csv.
#   compare: julia --project=. bin/measure_duckdb_path.jl compare DIR/prices_pg.csv DIR/prices_duckdb.csv --out DIR
#            Cell-by-cell comparison; every differing cell listed with its |Δ| and class (bit-identical / ≤2e-12
#            tie class / beyond), plus DIR/summary.md (also appended to $GITHUB_STEP_SUMMARY when set).
const _T_PROCESS0 = time()   # process wall: measured here (the runner image has no /usr/bin/time)
using Dates, Printf
# Euphemia (and its data-store init) only for `clear`: `compare` is a pure CSV comparison and needs no store.
const _CMD = isempty(ARGS) ? "" : ARGS[1]
_CMD == "clear" && @eval using Euphemia
"Peak resident memory of this process (kB), from the kernel."
peak_rss_kb() = try parse(Int, match(r"VmHWM:\s*(\d+)", read("/proc/self/status", String))[1]) catch; -1 end

const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]
const TIE = 2e-12

function opt(args, k, default=nothing)
    i = findfirst(==(k), args)
    i === nothing ? default : args[i+1]
end

usable(r) = r.status == :optimal || (r.status == :time_limit && !isempty(r.market_prices))

"""The record's clear of one day: the stage functions PipelinedBackfill's workers call (as_of=:gate), in one
process — mz_build_books → mz_solve_pass → mz_extract_anchor_inputs → mz_rebuild_anchored → mz_solve_pass, pass 2
accepted when usable (else pass 1). Bit-identical to the pipelined record (perf-96 profile driver vs arm A)."""
function record_clear(d::Date)
    gate(f) = Euphemia.with_context(f, Euphemia.gate_context(d))
    kw = (optimizer="highs", silent=true, mpcc_time_limit=900.0, mpcc_mip_gap=1e-6, mpcc_heuristic_effort=nothing,
          decompose_periods=true)
    ob1 = gate(() -> mz_build_books(FOOTPRINT, d; enrich_network=true, apply_zone_profiles=true, scenario=nothing))
    r1 = mz_solve_pass(ob1; kw...)
    usable(r1) || return r1
    ai = mz_extract_anchor_inputs(ob1, r1; apply_zone_profiles=true)
    isempty(ai.anchored) && return r1
    ob2 = gate(() -> mz_rebuild_anchored(FOOTPRINT, d, ai.refs, ai.cached; enrich_network=true,
                                         apply_zone_profiles=true, scenario=nothing))
    r2 = mz_solve_pass(ob2; kw...)
    return usable(r2) ? r2 : r1
end

"""The daily forecast's clear of one UTC day (bin/daily_forecast.jl clear_utc_day!: run_multi_zone_market_clearing,
passes=2, enrich_network), here under the day's gate context and without the weather-track scenario."""
forecast_clear(d::Date) = Euphemia.with_context(Euphemia.gate_context(d)) do
    run_multi_zone_market_clearing(d; zones=FOOTPRINT, order_method=:merit_order, optimizer="highs",
        silent=true, save_to_db=false, enrich_network=true, passes=2)
end

function clear(args)
    days = Date.(split(opt(args, "--days"), ","))
    label = opt(args, "--label"); out = opt(args, "--out"); mkpath(out)
    entry = opt(args, "--entry", "forecast")
    entry in ("forecast", "record") || error("--entry must be forecast or record")
    clear1 = entry == "forecast" ? forecast_clear : record_clear
    println("measure clear: backend=$(Euphemia.DATA_STORE[]) entry=$entry label=$label days=$(join(days, ","))")
    open(joinpath(out, "prices_$label.csv"), "w") do pio
        open(joinpath(out, "times_$label.csv"), "w") do tio
            println(pio, "day,zone,period,price"); println(tio, "day,wall_s,status")
            for d in days
                stop = get(ENV, "STOP_FILE", "")
                if !isempty(stop) && isfile(stop)   # the workflow watchdog saw a forecast/publish job start
                    println("STOP: $(strip(read(stop, String))) — measurement stopped before $d"); exit(3)
                end
                t0 = time()
                r = clear1(d)
                wall = time() - t0
                prices = r === nothing ? Dict() : r.market_prices
                for z in sort(collect(keys(prices))), (p, v) in sort(collect(prices[z]))
                    println(pio, d, ",", z, ",", p, ",", repr(v))
                end
                status = r === nothing ? "failed" : string(r.status)
                println(tio, d, ",", round(wall, digits=2), ",", status); flush(tio); flush(pio)
                @printf("  %s  %7.1f s  %s  %d zones\n", d, wall, status, length(prices))
            end
        end
    end
    open(joinpath(out, "process_$label.csv"), "w") do io
        println(io, "label,process_wall_s,peak_rss_kb")
        println(io, label, ",", round(time() - _T_PROCESS0, digits=2), ",", peak_rss_kb())
    end
end

function readp(f)
    d = Dict{Tuple{String,String,String},Float64}()
    for (i, l) in enumerate(eachline(f))
        i == 1 && continue
        a = split(l, ","); d[(a[1], a[2], a[3])] = parse(Float64, a[4])
    end
    return d
end

function compare(args)
    fa, fb = args[2], args[3]; out = opt(args, "--out", dirname(fa))
    a, b = readp(fa), readp(fb)
    keys_all = sort(collect(union(keys(a), keys(b))))
    same = 0; tie = 0; beyond = 0; missing_ = 0
    open(joinpath(out, "diff_cells.csv"), "w") do io
        println(io, "day,zone,period,a,b,abs_diff,class")
        for k in keys_all
            if !haskey(a, k) || !haskey(b, k)
                missing_ += 1; println(io, join(k, ","), ",", get(a, k, ""), ",", get(b, k, ""), ",,missing"); continue
            end
            va, vb = a[k], b[k]
            if reinterpret(UInt64, va) == reinterpret(UInt64, vb)
                same += 1
            else
                dlt = abs(va - vb); cls = dlt <= TIE ? "tie" : "beyond"
                cls == "tie" ? (tie += 1) : (beyond += 1)
                println(io, join(k, ","), ",", repr(va), ",", repr(vb), ",", repr(dlt), ",", cls)
            end
        end
    end
    ta = joinpath(dirname(fa), replace(basename(fa), "prices_" => "times_"))
    tb = joinpath(dirname(fb), replace(basename(fb), "prices_" => "times_"))
    wall(f) = isfile(f) ? sum(parse(Float64, split(l, ",")[2]) for (i, l) in enumerate(eachline(f)) if i > 1) : NaN
    pa = joinpath(dirname(fa), replace(basename(fa), "prices_" => "process_"))
    pb = joinpath(dirname(fb), replace(basename(fb), "prices_" => "process_"))
    proc(f) = isfile(f) ? split(collect(eachline(f))[2], ",") : ["-", "-", "-"]
    s = """
    ### DuckDB path measurement
    | | $(basename(fa)) | $(basename(fb)) |
    |---|---|---|
    | cells | $(length(a)) | $(length(b)) |
    | Σ day wall (s) | $(round(wall(ta), digits=1)) | $(round(wall(tb), digits=1)) |
    | process wall (s) | $(proc(pa)[2]) | $(proc(pb)[2]) |
    | peak RSS (kB) | $(proc(pa)[3]) | $(proc(pb)[3]) |

    Cells: bit-identical $same, tie class (≤$TIE) $tie, beyond $beyond, missing on one side $missing_
    (every differing cell is in diff_cells.csv).
    """
    write(joinpath(out, "summary.md"), s)
    haskey(ENV, "GITHUB_STEP_SUMMARY") && open(io -> write(io, s), ENV["GITHUB_STEP_SUMMARY"], "a")
    print(s)
    return beyond == 0 && missing_ == 0
end

if _CMD == "clear"
    clear(ARGS)
elseif _CMD == "compare"
    compare(ARGS) || (println("cells beyond the tie class or missing — see diff_cells.csv"); exit(1))
else
    error("usage: measure_duckdb_path.jl clear --days D1,D2 --label L --out DIR | compare A.csv B.csv [--out DIR]")
end
