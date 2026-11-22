# highs-blocks Track 2, 3(a) (research only): the JOINT big-M monolith with block
# orders, seeded by the converged fix-and-reprice loop.
#   1. Build the record day with EUPHEMIA_COMPLEX_ORDERS=ps,blocks exactly as the
#      pipeline does (pass 1 with the PAB loop → anchors → pass-2 book), run the
#      pass-2 loop (timed), keep its final accepted/forced block sets.
#   2. Final-round resolved book (re-run of the master with the final forced set;
#      checked equal) → per-period MPCC solution with blocks as fixed injections.
#   3. Joint model = the 24-period MPCC of the resolved book's SimpleOrders
#      (storage members stay capped at the final master allocation — a stated
#      simplification), blocks NOT fixed: one binary z_f per BLK family, members
#      inject q_j·z_f into the nodal balance, cost q_j·b_j·z_f in the objective,
#      and the PAB row  Σ_j q_j·r_j/60·(P_{n,t_j} − b_j) ≥ −M_f·(1 − z_f),
#      M_f = Σ_j q_j·r_j/60·max(0, b_j − floor), at the price VARIABLES.
#   4. Seeds: joint_seed.sol (MIPLIB, every column: loop solution + z) and
#      joint_seed_int.sol (HiGHS partial format: integers only, so HiGHS
#      completes the continuous part — prices included — by LP).
# env: HB_DAY HB_OUT, extract env as in record_arm.jl.
ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "v2")
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"
ENV["EUPHEMIA_COMPLEX_ORDERS"] = get(ENV, "HB_COMPLEX", "ps,blocks")
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
meta = Dict{String,Any}("day" => string(day), "complex" => ENV["EUPHEMIA_COMPLEX_ORDERS"])
t0 = time()
bookfile = joinpath(out, "book_blocks.jls")
if isfile(bookfile)
    ob, meta["anchored"], meta["pass1_secs"] = deserialize(bookfile)
else
    ob1 = gate(() -> mz_build_books(FOOTPRINT, day; enrich_network=true, apply_zone_profiles=true))
    tp = time()
    r1 = mz_solve_pass(ob1; optimizer="highs", decompose_periods=true)
    meta["pass1_secs"] = time() - tp
    ai = mz_extract_anchor_inputs(ob1, r1; apply_zone_profiles=true)
    ob = isempty(ai.anchored) ? ob1 :
         gate(() -> mz_rebuild_anchored(FOOTPRINT, day, ai.refs, ai.cached;
                                        enrich_network=true, apply_zone_profiles=true))
    meta["anchored"] = ai.anchored
    serialize(bookfile, (ob, ai.anchored, meta["pass1_secs"]))
end
println("HB blocks book ready $(round(time() - t0, digits=1))s")

# pass-2 PAB loop (the comparator), timed
tl = time()
rloop = mz_solve_pass(ob; optimizer="highs", decompose_periods=true)
meta["pass2_loop_secs"] = time() - tl
info = MPCC.LAST_COMPLEX_INFO[]
@assert info.status == :optimal "loop did not end on an optimal master: $(info.status)"
forced = copy(info.forced)
accepted = Set(keys(info.blocks))
meta["loop"] = Dict("status" => string(rloop.status), "objective" => rloop.objective_value,
    "n_forced" => length(forced), "n_accepted" => length(accepted), "n_blocks" => info.n_blocks,
    "message" => rloop.message)
println("HB loop: $(rloop.status) obj=$(rloop.objective_value) accepted=$(length(accepted))/$(info.n_blocks) forced=$(length(forced)) in $(round(meta["pass2_loop_secs"], digits=1))s")

# final-round resolved book (deterministic master re-run)
resolved = MPCC.resolve_complex_orders(ob; preferred_solver="highs", verbose=false, forced_reject=forced)
@assert Set(keys(MPCC.LAST_COMPLEX_INFO[].blocks)) == accepted "master re-run gave a different accepted set"

sanitize(s) = replace(s, r"[\"() ]" => "")
simple = filter(o -> o isa MPCC.SimpleOrder, resolved.orders)
glist = Dict(t => Int[] for t in resolved.periods)
for (g, o) in enumerate(simple)
    t = MPCC.extract_time_period(o.date_time, resolved.periods)
    haskey(glist, t) && push!(glist[t], g)
end

# seed: per-period MPCC of the final-round book
sol = Dict{String,Float64}()
MPCC.RESEARCH_SOLVE_HOOK[] = function (stage, model, book)
    stage === :post || return nothing
    t = only(book.periods)
    has_values(model) || return nothing
    for v in all_variables(model)
        n = sanitize(name(v))
        m = match(r"\[order_(\d+)_", n)
        if m !== nothing
            n = replace(n, r"\[order_\d+_" => "[order_$(glist[t][parse(Int, m.captures[1])])_"; count=1)
        end
        sol[n] = value(v)
    end
    nothing
end
rseed = MPCC.solve_mpcc_market_clearing(resolved; preferred_solver="highs", decompose_periods=true, verbose=false)
MPCC.RESEARCH_SOLVE_HOOK[] = nothing
meta["seed_mpcc"] = Dict("status" => string(rseed.status), "objective" => rseed.objective_value)

# joint model
blk = [o for o in ob.orders if o isa MPCC.LinkedHourlyOrder && MPCC.is_block_family(o.family)]
fams = sort(unique(o.family for o in blk))
floor_ = ob.price_limits[1]
joint_stats = Dict{String,Any}()
zname(f) = "blk_z[" * sanitize(f) * "]"
blk_cost = Dict(f => 0.0 for f in fams)
for o in blk
    blk_cost[o.family] += o.quantity * o.price
end
MPCC.RESEARCH_SOLVE_HOOK[] = function (stage, model, book)
    stage === :pre || return nothing
    for v in all_variables(model)
        set_name(v, sanitize(name(v)))
    end
    z = Dict(f => @variable(model, binary = true, base_name = zname(f)) for f in fams)
    bal = model[:nodal_power_balance]; P = model[:market_price]
    coef = Dict{Tuple{String,String,String},Float64}()
    pab = Dict(f => AffExpr(0.0) for f in fams); M = Dict(f => 0.0 for f in fams)
    for o in blk
        n = string(o.zone); t = MPCC.extract_time_period(o.date_time, book.periods)
        k = (o.family, n, t); coef[k] = get(coef, k, 0.0) - o.quantity
        w = o.quantity * o.resolution_code / 60.0
        add_to_expression!(pab[o.family], w, P[n, t])
        add_to_constant!(pab[o.family], -w * o.price)
        M[o.family] += w * max(0.0, o.price - floor_)
    end
    for ((f, n, t), c) in coef
        set_normalized_coefficient(bal[n, t], z[f], c)
    end
    obj = objective_function(model)
    for f in fams
        add_to_expression!(obj, -blk_cost[f], z[f])
    end
    set_objective_function(model, obj)
    npab = 0
    for f in fams
        M[f] > 0 || continue
        @constraint(model, pab[f] + M[f] * (1 - z[f]) >= 0, base_name = "pab[" * sanitize(f) * "]")
        npab += 1
    end
    joint_stats["num_variables"] = num_variables(model)
    joint_stats["num_binaries"] = count(is_binary, all_variables(model))
    joint_stats["n_block_binaries"] = length(fams); joint_stats["n_pab_rows"] = npab
    joint_stats["M_max"] = maximum(values(M))
    write_to_file(model, joinpath(out, "joint.mps"))
    return :skip
end
jbook = MPCC.MPCCOrderBook(simple, resolved.nodes, resolved.periods, resolved.price_limits,
                           resolved.network_topology, ob.fixed_injections)
rj = MPCC.solve_mpcc_market_clearing(jbook; preferred_solver="highs", decompose_periods=false, verbose=false)
MPCC.RESEARCH_SOLVE_HOOK[] = nothing
@assert rj.message == "research hook: solve skipped"
meta["joint"] = joint_stats
println("HB joint MPS written: $joint_stats")

seed_obj = rseed.objective_value - sum(blk_cost[f] for f in accepted; init=0.0)
meta["seed_objective_welfare"] = seed_obj
for f in fams
    sol[zname(f)] = f in accepted ? 1.0 : 0.0
end
open(joinpath(out, "joint_seed.sol"), "w") do io
    println(io, "=obj= ", repr(-seed_obj))
    for k in sort(collect(keys(sol)))
        println(io, k, " ", repr(sol[k]))
    end
end
ints = sort([k for k in keys(sol) if occursin("_aux[", k) || startswith(k, "blk_z[")])
open(joinpath(out, "joint_seed_int.sol"), "w") do io
    println(io, "Model status\nOptimal\n\n# Primal solution values\nFeasible\nObjective 0")
    println(io, "# Columns -$(length(ints)) partial")
    for k in ints
        println(io, k, " ", repr(round(sol[k])))
    end
end
meta["blocks"] = Dict("families" => fams, "accepted" => sort(collect(accepted)), "forced" => sort(collect(forced)))
meta["loop_prices"] = rloop.market_prices
open(joinpath(out, "joint_meta.json"), "w") do io
    JSON.print(io, meta, 1)
end
println("HB done $(round(time() - t0, digits=1))s")
