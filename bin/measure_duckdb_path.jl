#!/usr/bin/env julia
# measure_duckdb_path.jl — timing (and a price cross-check) of the current Postgres read path vs the fill → DuckDB
# path, for .github/workflows/measure-duckdb-path.yml (perf-96; owner rule 2026-11-23). READ-ONLY: it clears with
# save_to_db=false and never writes Postgres or the results DuckDB.
#
#   clear:   julia --project=. bin/measure_duckdb_path.jl clear --days 2026-11-18,2026-11-19 --label pg --out DIR
#            The backend is whatever the environment selects: ENERGY_CONN_STR + EUPHEMIA_DATA_STORE=postgres for the
#            current path; EUPHEMIA_DATA_STORE=duckdb + EUPHEMIA_DUCKDB_PATH=<filled inputs> for the DuckDB path.
#            Each day: run_multi_zone_market_clearing(passes=2, enrich_network=true, save_to_db=false) under the
#            gate context (as the record does), with per-day wall time. Writes DIR/prices_<label>.csv and
#            DIR/times_<label>.csv.
#   compare: julia --project=. bin/measure_duckdb_path.jl compare DIR/prices_pg.csv DIR/prices_duckdb.csv --out DIR
#            Cell-by-cell comparison; every differing cell listed with its |Δ| and class (bit-identical / ≤2e-12
#            tie class / beyond), plus DIR/summary.md (also appended to $GITHUB_STEP_SUMMARY when set).
using Euphemia, Dates, Printf

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

function clear(args)
    days = Date.(split(opt(args, "--days"), ","))
    label = opt(args, "--label"); out = opt(args, "--out"); mkpath(out)
    println("measure clear: backend=$(Euphemia.DATA_STORE[]) label=$label days=$(join(days, ","))")
    open(joinpath(out, "prices_$label.csv"), "w") do pio
        open(joinpath(out, "times_$label.csv"), "w") do tio
            println(pio, "day,zone,period,price"); println(tio, "day,wall_s,status")
            for d in days
                t0 = time()
                r = Euphemia.with_context(Euphemia.gate_context(d)) do
                    run_multi_zone_market_clearing(d; zones=FOOTPRINT, order_method=:merit_order, optimizer="highs",
                        silent=true, save_to_db=false, enrich_network=true, passes=2)
                end
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
    s = """
    ### DuckDB path measurement
    | | $(basename(fa)) | $(basename(fb)) |
    |---|---|---|
    | cells | $(length(a)) | $(length(b)) |
    | Σ day wall (s) | $(round(wall(ta), digits=1)) | $(round(wall(tb), digits=1)) |

    Cells: bit-identical $same, tie class (≤$TIE) $tie, beyond $beyond, missing on one side $missing_
    (every differing cell is in diff_cells.csv).
    """
    write(joinpath(out, "summary.md"), s)
    haskey(ENV, "GITHUB_STEP_SUMMARY") && open(io -> write(io, s), ENV["GITHUB_STEP_SUMMARY"], "a")
    print(s)
    return beyond == 0 && missing_ == 0
end

if !isempty(ARGS) && ARGS[1] == "clear"
    clear(ARGS)
elseif !isempty(ARGS) && ARGS[1] == "compare"
    compare(ARGS) || (println("cells beyond the tie class or missing — see diff_cells.csv"); exit(1))
else
    error("usage: measure_duckdb_path.jl clear --days D1,D2 --label L --out DIR | compare A.csv B.csv [--out DIR]")
end
