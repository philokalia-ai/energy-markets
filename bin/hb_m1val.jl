# highs-blocks M1 validation (research): one record day, both passes, every PAB
# round, through the same stage functions the pipelined record uses
# (mz_build_books → mz_solve_pass → mz_extract_anchor_inputs → mz_rebuild_anchored
# → mz_solve_pass), single process. The M1 flag comes from the environment
# (EUPHEMIA_MPCC_LP_CERT=shadow|1, EUPHEMIA_MPCC_LP_CERT_LOG=<dir>);
# EUPHEMIA_COMPLEX_ORDERS selects the config.
# env: HB_DAYS=2026-10-19[,..] HB_OUT=<dir>
ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "v2")
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"
using Euphemia, Dates, JSON
const MPCC = Euphemia.MPCC
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]
out = ENV["HB_OUT"]; mkpath(out)
cinfo() = (ci = MPCC.LAST_COMPLEX_INFO[]; ci === nothing ? nothing :
    Dict("status" => string(ci.status),
         "accepted" => hasproperty(ci, :blocks) ? sort(collect(keys(ci.blocks))) : String[],
         "forced" => hasproperty(ci, :forced) ? sort(collect(ci.forced)) : String[]))
println("HB M1VAL cert=$(get(ENV, "EUPHEMIA_MPCC_LP_CERT", "")) complex=$(get(ENV, "EUPHEMIA_COMPLEX_ORDERS", "<default>"))")
for day in Date.(split(ENV["HB_DAYS"], ","))
    gate(f) = Euphemia.with_context(f, Euphemia.gate_context(day))
    rec = Dict{String,Any}("day" => string(day), "cert" => get(ENV, "EUPHEMIA_MPCC_LP_CERT", ""),
                           "complex" => get(ENV, "EUPHEMIA_COMPLEX_ORDERS", ""))
    t0 = time()
    MPCC.LAST_COMPLEX_INFO[] = nothing
    ob1 = gate(() -> mz_build_books(FOOTPRINT, day; enrich_network=true, apply_zone_profiles=true))
    rec["book1_s"] = time() - t0
    t = time(); r1 = mz_solve_pass(ob1; optimizer="highs", decompose_periods=true)
    rec["pass1_s"] = time() - t; rec["pass1"] = Dict("status" => string(r1.status),
        "obj" => r1.objective_value, "message" => r1.message, "complex" => cinfo())
    ai = mz_extract_anchor_inputs(ob1, r1; apply_zone_profiles=true)
    final = r1
    if !isempty(ai.anchored)
        t = time()
        ob2 = gate(() -> mz_rebuild_anchored(FOOTPRINT, day, ai.refs, ai.cached;
                                             enrich_network=true, apply_zone_profiles=true))
        rec["book2_s"] = time() - t
        MPCC.LAST_COMPLEX_INFO[] = nothing
        t = time(); r2 = mz_solve_pass(ob2; optimizer="highs", decompose_periods=true)
        rec["pass2_s"] = time() - t; rec["pass2"] = Dict("status" => string(r2.status),
            "obj" => r2.objective_value, "message" => r2.message, "complex" => cinfo())
        (r2.status == :optimal || (r2.status == :time_limit && !isempty(r2.market_prices))) && (final = r2)
    end
    rec["day_s"] = time() - t0
    rec["final_prices"] = final.market_prices
    open(joinpath(out, "day-$(day).json"), "w") do io
        JSON.print(io, rec, 1)
    end
    println("HB M1VAL $day: pass1 $(rec["pass1"]["status"]) $(round(rec["pass1_s"], digits=1))s, " *
            "pass2 $(get(get(rec, "pass2", Dict()), "status", "-")) $(round(get(rec, "pass2_s", 0.0), digits=1))s, " *
            "day $(round(rec["day_s"], digits=1))s")
end
println("HB M1VAL done")
