# highs-blocks M1 (research): per-period MPCC with the LP certificate / LP-derived
# MIP start vs the stock per-period solve, on a cached book (bin/hb_mono_dump.jl
# writes HB_OUT/book.jls). Same process, warm JIT; runs each arm HB_REPS times.
# env: HB_OUT=<dir with book.jls> HB_ARMS=base,cert HB_REPS=1
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
using Euphemia, Dates, JuMP, JSON, Serialization
const MPCC = Euphemia.MPCC
out = ENV["HB_OUT"]
ob, anchored = deserialize(joinpath(out, "book.jls"))
arms = split(get(ENV, "HB_ARMS", "base,cert"), ",")
reps = parse(Int, get(ENV, "HB_REPS", "1"))

function run_arm(arm)
    if arm == "cert"
        ENV["EUPHEMIA_MPCC_LP_CERT"] = "1"
    else
        delete!(ENV, "EUPHEMIA_MPCC_LP_CERT")
    end
    MPCC.LP_CERT_LOG[] = Any[]
    per = Dict{String,Any}()
    MPCC.RESEARCH_SOLVE_HOOK[] = function (stage, model, book)
        stage === :post || return nothing
        per[only(book.periods)] = Dict("status" => string(termination_status(model)),
            "obj" => has_values(model) ? objective_value(model) : NaN,
            "highs_secs" => solve_time(model))
        nothing
    end
    t = time()
    r = mz_solve_pass(ob; optimizer="highs", decompose_periods=true)
    wall = time() - t
    MPCC.RESEARCH_SOLVE_HOOK[] = nothing
    log = MPCC.LP_CERT_LOG[]; MPCC.LP_CERT_LOG[] = nothing
    return (r=r, wall=wall, per=per, log=log)
end

# no separate warm-up: run HB_REPS=2 and read rep 2 for timing (rep 1 includes JIT)
results = Dict{String,Any}()
for rep in 1:reps, a in arms
    res = run_arm(a)
    key = "$(a)#$(rep)"
    results[key] = res
    n_cert = count(d -> get(d, "outcome", "") == "certified", res.log)
    println("HB M1 $key: status=$(res.r.status) obj=$(res.r.objective_value) wall=$(round(res.wall, digits=1))s " *
            "certified=$n_cert/$(length(res.log))")
end

# compare prices / objectives against the first base run
base = results["base#1"]
summary = Dict{String,Any}()
for (k, res) in results
    k == "base#1" && continue
    maxdp = 0.0; ndiff = 0
    for z in keys(base.r.market_prices), t in keys(base.r.market_prices[z])
        d = abs(res.r.market_prices[z][t] - base.r.market_prices[z][t])
        maxdp = max(maxdp, d); d > 1e-6 && (ndiff += 1)
    end
    dobj = [abs(res.per[t]["obj"] - base.per[t]["obj"]) / max(1.0, abs(base.per[t]["obj"])) for t in keys(base.per)]
    summary[k] = Dict("wall" => res.wall, "obj" => res.r.objective_value,
        "max_abs_price_diff" => maxdp, "n_price_cells_diff" => ndiff,
        "max_rel_obj_diff_per_period" => maximum(dobj))
    println("HB M1 $k vs base#1: wall $(round(res.wall, digits=1)) vs $(round(base.wall, digits=1)) s; " *
            "price cells differing $ndiff (max |dp| $(round(maxdp, digits=4))); max rel obj diff/period $(maximum(dobj))")
end
open(joinpath(out, "m1_$(get(ENV, "HB_TAG", "run")).json"), "w") do io
    JSON.print(io, Dict("summary" => summary,
        "runs" => Dict(k => Dict("wall" => v.wall, "status" => string(v.r.status),
                                 "obj" => v.r.objective_value, "per" => v.per, "cert" => v.log)
                       for (k, v) in results)), 1)
end
