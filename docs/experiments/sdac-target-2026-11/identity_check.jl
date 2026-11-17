# Flag-off identity + Julia/Python agreement for the DA target policy (#431 PR C).
#
# For sample market days, writes the hourly actuals the scorer/exporters read
# (window market_date-1 .. market_date, as in bin/score_forecasts.jl) to OUTDIR:
#   actuals_default.csv  — `da_target_actuals` with EUPHEMIA_DA_TARGET unset
#                          (on a checkout without it, i.e. main: `resolution_aware_actuals`)
#   actuals_sdac.csv     — `da_target_actuals` with EUPHEMIA_DA_TARGET=sdac (branch only)
#   actuals_highest_seq.csv — with EUPHEMIA_DA_TARGET=highest_seq (the kill switch; since
#                          #431 C2 the unset default is sdac)
# Run it on main and on the branch against the same read-only extract and compare the
# default files byte for byte (`cmp`); compare_python.py checks the sdac file against
# bin/da_target.py.
#
# usage: EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_PATH=<extract> EUPHEMIA_DUCKDB_READONLY=true \
#        julia --project=. docs/experiments/sdac-target-2026-11/identity_check.jl OUTDIR
using Euphemia, Dates, DataFrames, Printf
include(joinpath(@__DIR__, "..", "..", "..", "test", "scripts", "eu_eval_metrics.jl"))

const DAYS = Date.(["2024-07-15", "2025-03-30", "2025-10-01", "2025-10-26", "2026-03-29",
                    "2026-09-20", "2026-10-25", "2026-11-13", "2026-11-14", "2026-11-15"])
out = ARGS[1]; mkpath(out)

function dump(path, f)
    open(path, "w") do io
        println(io, "market_date,z,t,act")
        for d in DAYS
            a = sort(f(d - Day(1), d), [:z, :t])
            for r in eachrow(a)
                @printf(io, "%s,%s,%s,%.10f\n", d, r.z, DateTime(r.t), Float64(r.act))
            end
        end
    end
end

has_policy = isdefined(@__MODULE__, :da_target_actuals)
withenv("EUPHEMIA_DA_TARGET" => nothing) do
    dump(joinpath(out, "actuals_default.csv"),
         has_policy ? da_target_actuals : resolution_aware_actuals)
end
if has_policy
    withenv("EUPHEMIA_DA_TARGET" => "sdac") do
        dump(joinpath(out, "actuals_sdac.csv"), da_target_actuals)
    end
    # the kill switch (#431 C2): must equal main's pre-flip default byte for byte
    withenv("EUPHEMIA_DA_TARGET" => "highest_seq") do
        dump(joinpath(out, "actuals_highest_seq.csv"), da_target_actuals)
    end
end
println("IDENTITY_CHECK_DONE has_policy=$has_policy days=$(length(DAYS)) -> $out")
