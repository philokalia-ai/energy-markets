# highs-blocks Track 2 (research only): build one record day's final (pass-2)
# multi-zone book exactly as the pipelined record does (as_of=:gate, enriched,
# zone profiles), then
#   1. write the MONOLITHIC 24-period MPCC (decompose_periods=false) as MPS,
#      without solving it;
#   2. solve the canonical per-period decomposition and write its solution
#      mapped onto the monolithic variable names (MIPLIB .sol, readable by
#      `highs --read_solution_file`).
# env: HB_DAY=2026-10-19 HB_OUT=<dir>, extract env as in record_arm.jl.
ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "v2")
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"
using Euphemia, Dates, JuMP, JSON, Serialization
const MPCC = Euphemia.MPCC
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]
day = Date(ENV["HB_DAY"]); out = ENV["HB_OUT"]; mkpath(out)
gate(f) = Euphemia.with_context(f, Euphemia.gate_context(day))
t0 = time()
bookfile = joinpath(out, "book.jls")
if isfile(bookfile)
    ob, anchored = deserialize(bookfile)
    ai = (anchored = anchored,)
else
ob1 = gate(() -> mz_build_books(FOOTPRINT, day; enrich_network=true, apply_zone_profiles=true))
r1 = mz_solve_pass(ob1; optimizer="highs", decompose_periods=true)
ai = mz_extract_anchor_inputs(ob1, r1; apply_zone_profiles=true)
ob = isempty(ai.anchored) ? ob1 :
     gate(() -> mz_rebuild_anchored(FOOTPRINT, day, ai.refs, ai.cached;
                                    enrich_network=true, apply_zone_profiles=true))
serialize(bookfile, (ob, ai.anchored))
end
println("HB books ready in $(round(time() - t0, digits=1))s; anchored=$(ai.anchored)")

sanitize(s) = replace(s, r"[\"() ]" => "")
sanitize_all!(model) = for v in all_variables(model)
    set_name(v, sanitize(name(v)))
end

# Global (monolithic) order index per period, in book order: the decomposition
# driver buckets `filter(SimpleOrder, orders)` in that same order, so the i-th
# order of period t's sub-book is glist[t][i].
# NOTE: under the default `ps` complex orders the MPCC sees the master-RESOLVED
# book (storage members appended as capped SimpleOrders), so the index must be
# built from the book the hook receives, not from `ob`.
simple = MPCC.SimpleOrder[]
glist = Dict{String,Vector{Int}}()
function index_book!(book)
    empty!(simple); append!(simple, filter(o -> o isa MPCC.SimpleOrder, book.orders))
    empty!(glist); for t in book.periods; glist[t] = Int[]; end
    for (g, o) in enumerate(simple)
        t = MPCC.extract_time_period(o.date_time, book.periods)
        haskey(glist, t) && push!(glist[t], g)
    end
end

# 1. monolithic MPS (no solve)
mono_stats = Dict{String,Any}()
MPCC.RESEARCH_SOLVE_HOOK[] = function (stage, model, book)
    stage === :pre || return nothing
    index_book!(book)
    sanitize_all!(model)
    mono_stats["num_variables"] = num_variables(model)
    mono_stats["num_binaries"] = count(is_binary, all_variables(model))
    mono_stats["num_constraints"] = num_constraints(model; count_variable_in_set_constraints=false)
    tw = time()
    get(ENV, "HB_SKIP_MONO", "") == "" && write_to_file(model, joinpath(out, "mono.mps"))
    mono_stats["write_secs"] = time() - tw
    return :skip
end
rm_ = MPCC.solve_mpcc_market_clearing(ob; preferred_solver="highs", decompose_periods=false, verbose=false)
@assert rm_.message == "research hook: solve skipped"
println("HB mono MPS written: $mono_stats")

# 2. decomposed solve, solution mapped onto monolithic names
sol = Dict{String,Float64}()
per_period = Dict{String,Any}()
MPCC.RESEARCH_SOLVE_HOOK[] = function (stage, model, book)
    t = only(book.periods)
    if stage === :pre
        if get(ENV, "HB_PERIOD_MPS", "") != ""
            sanitize_all!(model)
            mkpath(joinpath(out, "periods"))
            write_to_file(model, joinpath(out, "periods", "p$(t[10:13]).mps"))
        end
        return nothing
    end
    per_period[t] = Dict("status" => string(termination_status(model)),
        "objective" => has_values(model) ? objective_value(model) : NaN,
        "solve_time" => solve_time(model),
        "nodes" => try MOI.get(model, MOI.NodeCount()) catch; -1 end)
    has_values(model) || return nothing
    for v in all_variables(model)
        n = sanitize(name(v))
        m = match(r"\[order_(\d+)_", n)
        if m !== nothing
            g = glist[t][parse(Int, m.captures[1])]
            n = replace(n, r"\[order_\d+_" => "[order_$(g)_"; count=1)
        end
        sol[n] = value(v)
    end
    return nothing
end
td = time()
rd = mz_solve_pass(ob; optimizer="highs", decompose_periods=true)
MPCC.RESEARCH_SOLVE_HOOK[] = nothing
dec_secs = time() - td
println("HB decomposed: status=$(rd.status) obj=$(rd.objective_value) in $(round(dec_secs, digits=1))s; $(length(sol)) values")
open(joinpath(out, "decomposed.sol"), "w") do io
    println(io, "=obj= ", repr(rd.objective_value))
    for k in sort(collect(keys(sol)))
        println(io, k, " ", repr(sol[k]))
    end
end
open(joinpath(out, "mono_meta.json"), "w") do io
    JSON.print(io, Dict("day" => string(day), "anchored" => ai.anchored,
        "n_orders" => length(simple), "periods" => ob.periods, "nodes" => ob.nodes,
        "price_limits" => ob.price_limits, "mono" => mono_stats,
        "decomposed" => Dict("status" => string(rd.status), "objective" => rd.objective_value,
                             "wall_secs" => dec_secs, "per_period" => per_period),
        "prices" => rd.market_prices), 1)
end
println("HB done in $(round(time() - t0, digits=1))s")
