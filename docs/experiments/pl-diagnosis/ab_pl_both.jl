#!/usr/bin/env julia
# PL A/B, BOTH arms in one process (one precompile; arm B reuses warm
# generator/net-import caches). base = cv24 main; spread = PL gets
# unit_srmc_spread (heterogeneous hard-coal heat rates). Monolithic clear
# (decompose_periods=false) so market_prices carries the full 24h vector even on
# a time-limit incumbent — SAME mode both arms. Read-only extract enforced in
# THIS process before `using Euphemia`. Resumable per (arm,day). Retry a crashed
# or degenerate (<20 periods) day once (HiGHS #182).
#
#   DAYS=... SPREAD=0.10 OUTDIR=docs/experiments/pl-diagnosis \
#     julia --project=. docs/experiments/pl-diagnosis/ab_pl_both.jl
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
ENV["EUPHEMIA_DUCKDB_PATH"] = "/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"          # shared read-only — never lock the extract
haskey(ENV, "EUPHEMIA_RESULTS_DB") || (ENV["EUPHEMIA_RESULTS_DB"] =
    "/home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a62ce346a9048029f/scratch_results_ab.duckdb")
using Euphemia, Dates, Printf
# belt-and-braces: force read-only even if load-time auto-config differed
Euphemia.configure_data_store!(backend=:duckdb,
    duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
const SPREAD = parse(Float64, get(ENV, "SPREAD", "0.10"))
const OUTDIR = get(ENV, "OUTDIR", @__DIR__)
const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]
days = [Date(strip(d)) for d in split(ENV["DAYS"], ",")]

# decomposed (fast canonical) first; monolithic fallback guarantees 24 periods
# on a degenerate day. `decomp` is recorded so the SAME mode is reused for the
# other arm on that day (kept in DAY_MODE).
const DAY_MODE = Dict{Date,Bool}()   # day => decompose flag actually used
function clear_day(day)
    modes = haskey(DAY_MODE, day) ? [DAY_MODE[day]] : [true, true, false]  # decomp,decomp,mono
    for (attempt, decomp) in enumerate(modes)
        t0 = time()
        res = try
            run_multi_zone_market_clearing(day; zones=FOOTPRINT, order_method=:merit_order,
                enrich_network=true, passes=2, optimizer="highs", save_to_db=false,
                decompose_periods=decomp)
        catch e
            @warn "clear failed" day attempt error=sprint(showerror,e); nothing
        end
        if res !== nothing && haskey(res.market_prices, "PL") &&
           length(res.market_prices["PL"]) >= 20
            @printf("    ok %s in %.0fs (decomp=%s, PL periods=%d)\n",
                day, time()-t0, decomp, length(res.market_prices["PL"]))
            DAY_MODE[day] = decomp
            return res
        end
        @warn "degenerate/failed — next mode" day attempt decomp npl=(res===nothing ? -1 : length(get(res.market_prices,"PL",Dict())))
    end
    return nothing
end

function write_day(outf, day, res)
    open(outf, "a") do io
        for z in sort(collect(keys(res.market_prices))), (ts,p) in sort(collect(res.market_prices[z]))
            @printf(io, "%s\t%s\t%s\t%.6f\n", day, z, ts, p)
        end
    end
end

done_set(outf) = begin
    s = Set{String}()
    if isfile(outf)
        for l in Iterators.drop(eachline(outf), 1); push!(s, first(split(l,'\t'))); end
    else
        open(outf,"w") do io; println(io, "day\tzone\ttimeslot\tprice"); end
    end
    s
end

const ORIG_PL   = Euphemia.ZONE_PROFILES["PL"]
const SPREAD_PL = Euphemia.with_profile(ORIG_PL; unit_srmc_spread=SPREAD)
const BASEF   = joinpath(OUTDIR, "out_base.tsv")
const SPREADF = joinpath(OUTDIR, "out_spread.tsv")

# INTERLEAVED: both arms per day, so paired deltas accumulate and an early stop
# still yields a valid winter+summer read. Same decompose mode per day (DAY_MODE).
for day in days
    baseD = done_set(BASEF); sprD = done_set(SPREADF)
    if !(string(day) in baseD)
        println("  >>> base $day");   Euphemia.ZONE_PROFILES["PL"] = ORIG_PL
        r = clear_day(day); r === nothing ? (@warn "PERMANENT FAIL base" day) : write_day(BASEF, day, r)
    else; println("  skip base $day"); end
    if !(string(day) in sprD)
        println("  >>> spread $day"); Euphemia.ZONE_PROFILES["PL"] = SPREAD_PL
        r = clear_day(day); r === nothing ? (@warn "PERMANENT FAIL spread" day) : write_day(SPREADF, day, r)
    else; println("  skip spread $day"); end
    Euphemia.ZONE_PROFILES["PL"] = ORIG_PL
    println("  === paired day $day complete ===")
end
println("AB_BOTH_COMPLETE")
