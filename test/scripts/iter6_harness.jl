#!/usr/bin/env julia
# iteration-6 calibration harness — runs the full 39-zone EU merit-order clear on
# the FROZEN 36-day stratified sample (test/scripts/iter6_sample_days.json),
# OFFLINE against the DuckDB extract, scores each zone against resolution-aware
# day-ahead actuals (bias = sim − actual), and writes a per-zone CSV.
#
# In-memory only: workers clear with save_to_db=false and return market_prices;
# the coordinator concatenates (sim, act) pairs across all sample days per zone.
# Timeslot keys "YYYYMMDD-HHMM" are naive UTC (see save_energy_prices) — joined
# directly to the naive-UTC hourly actuals, identical to eu_eval_metrics.
#
# Env:
#   LABEL      output tag  -> results dir <RESULTS>/<LABEL>.csv         (required)
#   RESULTS    output dir  (default: scratchpad/iter6_results)
#   WORKERS    Gurobi worker processes (default 2; keep <=2 while backfill runs)
#   SUBSAMPLE  "hard" | "weekday" | "weekend" | comma-list of YYYY-MM-DD
#              (default: all 36). Use a subsample for fast directional checks.
#   ZONES      comma list to restrict scoring output (clear is always full 39z)
#   BASELINE   path to a baseline CSV to diff against (optional)
#   EUPHEMIA_DATA_STORE=duckdb, EUPHEMIA_DUCKDB_PATH=... must be set.

using Euphemia, Dates, Statistics, Printf, DataFrames, Distributed

const REPO = get(ENV, "REPO", abspath(joinpath(@__DIR__, "..", "..")))
include(joinpath(REPO, "test", "scripts", "eu_eval_metrics.jl"))

const FOOTPRINT = String["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR",
  "GR","HU","LT","LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS",
  "SE1","SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH",
  "IT-Calabria","IT-Sicily","IT-Sardinia","CH"]

function load_sample()
    txt = read(joinpath(REPO, "test", "scripts", "iter6_sample_days.json"), String)
    rows = NamedTuple[]
    for m in eachmatch(r"\"date\":\s*\"(\d{4}-\d{2}-\d{2})\",\s*\"kind\":\s*\"(\w+)\"", txt)
        push!(rows, (date=Date(m.captures[1]), kind=m.captures[2]))
    end
    ss = get(ENV, "SUBSAMPLE", "")
    isempty(ss) && return [r.date for r in rows]
    if ss in ("hard","weekday","weekend")
        return [r.date for r in rows if r.kind == ss]
    end
    return [Date(strip(x)) for x in split(ss, ",") if !isempty(strip(x))]
end

# ---- parallel clear (read-only duckdb workers), returns Dict(day => market_prices)
function clear_days(days::Vector{Date}, nworkers::Int)
    extract = abspath(Euphemia.DUCKDB_PATH[])
    tl = 900.0
    do_day(d) = begin
        try
            res = run_multi_zone_market_clearing(d; zones=FOOTPRINT, order_method=:merit_order,
                optimizer="gurobi", enrich_network=true, passes=2, clearing_mode="multi_zone",
                save_to_db=false, silent=true, mpcc_time_limit=tl)
            usable = res.status == :optimal || (res.status == :time_limit && !isempty(res.market_prices))
            usable ? (day=d, mp=res.market_prices, status=res.status, err=nothing) :
                     (day=d, mp=nothing, status=res.status, err="no prices")
        catch e
            (day=d, mp=nothing, status=nothing, err=sprint(showerror, e))
        end
    end
    if nworkers <= 1
        return [do_day(d) for d in days]
    end
    Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract, read_only=true)
    ws = addprocs(nworkers; exeflags="--project=$(dirname(Base.active_project()))",
        env=["EUPHEMIA_DATA_STORE"=>"duckdb","EUPHEMIA_DUCKDB_PATH"=>extract,
             "EUPHEMIA_DUCKDB_READONLY"=>"true","ENERGY_CONN_STR"=>""])
    try
        @everywhere ws @eval using Euphemia
        fp = FOOTPRINT   # capture as a local so pmap serializes it by value
        return pmap(days) do d
            try
                res = run_multi_zone_market_clearing(d; zones=fp, order_method=:merit_order,
                    optimizer="gurobi", enrich_network=true, passes=2, clearing_mode="multi_zone",
                    save_to_db=false, silent=true, mpcc_time_limit=900.0)
                usable = res.status == :optimal || (res.status == :time_limit && !isempty(res.market_prices))
                usable ? (day=d, mp=res.market_prices, status=res.status, err=nothing) :
                         (day=d, mp=nothing, status=res.status, err="no prices")
            catch e
                (day=d, mp=nothing, status=nothing, err=sprint(showerror, e))
            end
        end
    finally
        rmprocs(ws)
        Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract, read_only=false)
    end
end

function score(results, days::Vector{Date}, zones)
    sd, ed = minimum(days), maximum(days)
    act = resolution_aware_actuals(sd, ed)
    actmap = Dict{Tuple{String,DateTime},Float64}()
    for r in eachrow(act); actmap[(String(r.z), DateTime(r.t))] = Float64(r.act); end
    fmt = dateformat"yyyymmdd-HHMM"
    # per-zone accumulate (sim, act)
    sv = Dict{String,Vector{Float64}}(); av = Dict{String,Vector{Float64}}()
    nfail = 0
    for r in results
        if r.mp === nothing; nfail += 1; @warn "day failed" day=r.day err=r.err; continue; end
        for (z, pd) in r.mp
            zones !== nothing && !(z in zones) && continue
            for (ts, p) in pd
                dt = DateTime(ts, fmt)
                k = (z, dt); haskey(actmap, k) || continue
                push!(get!(sv, z, Float64[]), Float64(p))
                push!(get!(av, z, Float64[]), actmap[k])
            end
        end
    end
    out = NamedTuple[]
    for z in sort(collect(keys(sv)))
        s = sv[z]; a = av[z]; length(s) < 3 && continue
        c = (std(s) > 0 && std(a) > 0) ? cor(s, a) : NaN
        push!(out, (z=z, n=length(s), corr=c, mae=mean(abs.(s .- a)),
                    bias=mean(s .- a), simμ=mean(s), actμ=mean(a)))
    end
    return out, nfail
end

function main()
    label = get(ENV, "LABEL", "run")
    resdir = get(ENV, "RESULTS", "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/iter6_results")
    mkpath(resdir)
    nworkers = parse(Int, get(ENV, "WORKERS", "2"))
    zones = haskey(ENV, "ZONES") ? Set(String[strip(z) for z in split(ENV["ZONES"], ",")]) : nothing
    days = load_sample()
    println("ITER6 harness  label=$label  days=$(length(days))  workers=$nworkers  cv=$(Euphemia.ENERGY_PRICES_CODE_VERSION)")
    println("  span=$(minimum(days))..$(maximum(days))")
    t0 = time()
    results = clear_days(days, nworkers)
    rows, nfail = score(results, days, zones)
    dt = time() - t0
    @printf("cleared %d days (%d failed) in %.0fs (%.0fs/day wall)\n",
            length(days), nfail, dt, dt/max(1,length(days)))

    # write CSV
    csv = joinpath(resdir, "$label.csv")
    open(csv, "w") do io
        println(io, "zone,n,corr,mae,bias,sim_mean,act_mean")
        for r in rows
            @printf(io, "%s,%d,%.4f,%.4f,%.4f,%.4f,%.4f\n", r.z, r.n, r.corr, r.mae, r.bias, r.simμ, r.actμ)
        end
    end

    # baseline diff
    base = get(ENV, "BASELINE", "")
    basemap = Dict{String,NamedTuple}()
    if !isempty(base) && isfile(base)
        for (i, ln) in enumerate(eachline(base)); i==1 && continue
            f = split(ln, ","); length(f) >= 5 || continue
            basemap[f[1]] = (corr=parse(Float64,f[3]), mae=parse(Float64,f[4]), bias=parse(Float64,f[5]))
        end
    end
    # table
    if isempty(basemap)
        @printf("%-12s %5s %6s %7s %8s %7s %7s\n","zone","n","corr","MAE","bias","simμ","actμ")
        for r in rows
            @printf("%-12s %5d %6.2f %7.1f %+8.1f %7.1f %7.1f\n", r.z, r.n, r.corr, r.mae, r.bias, r.simμ, r.actμ)
        end
    else
        @printf("%-12s %6s %7s %8s   %6s %7s %8s\n","zone","corr","MAE","bias","Δcorr","ΔMAE","Δbias")
        for r in rows
            b = get(basemap, r.z, nothing)
            if b === nothing
                @printf("%-12s %6.2f %7.1f %+8.1f   %6s %7s %8s\n", r.z, r.corr, r.mae, r.bias,"new","-","-")
            else
                @printf("%-12s %6.2f %7.1f %+8.1f   %+6.2f %+7.1f %+8.1f\n", r.z, r.corr, r.mae, r.bias,
                        r.corr-b.corr, r.mae-b.mae, r.bias-b.bias)
            end
        end
    end
    if !isempty(rows)
        cvals = [r.corr for r in rows if !isnan(r.corr)]
        @printf("AGG zones=%d meanMAE=%.1f meanBias=%+.1f medMAE=%.1f meanCorr=%.2f\n",
                length(rows), mean(r.mae for r in rows), mean(r.bias for r in rows),
                median(r.mae for r in rows), mean(cvals))
        if !isempty(basemap)
            common = [r for r in rows if haskey(basemap, r.z)]
            bc = mean(basemap[r.z].corr for r in common); bm = mean(basemap[r.z].mae for r in common)
            @printf("    vs BASE: meanCorr %.2f->%.2f  meanMAE %.1f->%.1f\n",
                    bc, mean(r.corr for r in common), bm, mean(r.mae for r in common))
        end
    end
    println("wrote $csv")
end

main()
