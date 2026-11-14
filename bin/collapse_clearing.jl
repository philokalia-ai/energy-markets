#!/usr/bin/env julia
# Eight-day, one-candidate coupled ablation; no source/results DB writes.
# Every result is explicitly a latest-revision ENTSO-E input proxy.
# Set this before module initialization. Fail closed on a typo or absent flag.
get(ENV, "EUPHEMIA_DUCKDB_READONLY", "") == "true" ||
    error("Set EUPHEMIA_DUCKDB_READONLY=true before loading Euphemia")
using Euphemia, Dates, JSON, CSV, DataFrames
Euphemia.DUCKDB_READ_ONLY[] || error("Source extract must be read-only")
include(joinpath(@__DIR__, "forecast_common.jl"))

outdir = get(ENV, "COLLAPSE_OUTPUT", "results/collapse-2026-11")
mkpath(outdir)
days = Date.(split(get(ENV, "COLLAPSE_DAYS",
    "2026-09-20,2026-10-19,2026-11-04,2026-11-13,2026-09-16,2026-09-27,2026-10-06,2026-11-02"), ","))
arms = split(get(ENV, "COLLAPSE_ARMS", "baseline,res_zero"), ",")
for day in days, arm in arms
    path = joinpath(outdir, "$(day)-$(arm).csv")
    isfile(path) && continue
    arm in ("baseline", "res_zero") || error("Unknown arm $arm")
    t0 = time()
    try
        result = withenv("EUPHEMIA_RES_OFFER_LADDER" => (arm == "res_zero" ? "1" : "0")) do
            Euphemia.with_context(Euphemia.issuance_context(day, 1; issue_time=Time(10))) do
                Euphemia.run_multi_zone_market_clearing(day;
                    zones=FORECAST_FOOTPRINT, optimizer="highs", save_to_db=false,
                    silent=true, enrich_network=true, apply_zone_profiles=true,
                    passes=2, mpcc_time_limit=120.0, decompose_periods=true,
                    clearing_mode="collapse_202611_$(arm)_latest_proxy")
            end
        end
        rows = NamedTuple[]
        for (zone, prices) in result.market_prices, (t, price) in prices
            push!(rows, (; zone, t=string(t), price=price, arm,
                         input_variant="gate_1000_latest_proxy", code_version=42))
        end
        CSV.write(path, DataFrame(rows))
        open(joinpath(outdir, "$(day)-$(arm)-status.json"), "w") do io
            JSON.print(io, Dict("day" => string(day), "arm" => arm,
                "status" => string(result.status), "wall_seconds" => time()-t0,
                "solve_seconds" => result.solve_time, "n" => length(rows),
                "asof_audit" => Euphemia.asof_audit()))
        end
        println("COLLAPSE_RESULT day=$day arm=$arm status=$(result.status) n=$(length(rows)) wall=$(time()-t0)")
    catch e
        e isa InterruptException && rethrow()
        open(joinpath(outdir, "$(day)-$(arm)-error.txt"), "w") do io
            showerror(io, e, catch_backtrace())
        end
        println("COLLAPSE_FAILED day=$day arm=$arm error=$e")
    end
    Euphemia.reset_asof_audit!()
    flush(stdout)
end
