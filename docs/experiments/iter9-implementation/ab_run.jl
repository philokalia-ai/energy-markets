# iter9 A/B driver — clears a footprint over the A/B windows WITHOUT writing
# to Postgres (save_to_db=false; hourly prices land in a TSV, resumable per
# day). Postgres is used read-only for inputs.
#
# Env:
#   ZONESET   "43" (default) | "39"
#   DAYS      comma list of YYYY-MM-DD and/or start..end ranges
#             (default: the three iter9 A/B windows)
#   OPTIMIZER "gurobi" (default) | "highs" | "auto"
#   OUT       output TSV (default ab_<ZONESET>.tsv next to this script)
#   EUPHEMIA_ITER9_HRHU=endogenous   selects the HR–HU control arm (library env)
using Euphemia, Dates, Printf

const FP39 = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]
const FP43 = sort(vcat(FP39, ["AL", "HR", "ME", "MK"]))

zoneset = get(ENV, "ZONESET", "43")
zones = zoneset == "39" ? FP39 : FP43
optimizer = get(ENV, "OPTIMIZER", "gurobi")

function parse_days(spec::AbstractString)
    days = Date[]
    for tok in split(spec, ",")
        tok = strip(tok); isempty(tok) && continue
        if occursin("..", tok)
            a, b = split(tok, "..")
            append!(days, collect(Date(strip(a)):Day(1):Date(strip(b))))
        else
            push!(days, Date(tok))
        end
    end
    return sort(unique(days))
end

const DEFAULT_DAYS = "2026-04-01..2026-04-05,2026-07-06..2026-07-21,2026-03-01..2026-03-08"
days = parse_days(get(ENV, "DAYS", DEFAULT_DAYS))
out = get(ENV, "OUT", joinpath(@__DIR__, "ab_$(zoneset)" *
        (get(ENV, "EUPHEMIA_ITER9_HRHU", "") == "endogenous" ? "_hrhu" : "") * ".tsv"))

# Resume: skip days already present in OUT.
done_days = Set{Date}()
if isfile(out)
    for line in eachline(out)
        startswith(line, "zone\t") && continue
        parts = split(line, '\t')
        length(parts) >= 2 && push!(done_days, Date(parts[2][1:8], dateformat"yyyymmdd"))
    end
else
    open(out, "w") do io
        println(io, "zone\ttimeslot\tprice")
    end
end

println("iter9 A/B: zoneset=$zoneset ($(length(zones)) zones) days=$(length(days)) " *
        "(done: $(length(done_days))) optimizer=$optimizer out=$out " *
        "hrhu=$(get(ENV, "EUPHEMIA_ITER9_HRHU", "dropped"))")

for d in days
    d in done_days && (println("SKIP $d (already in $out)"); continue)
    t0 = time()
    r = try
        run_multi_zone_market_clearing(d; zones=zones, order_method=:merit_order,
            optimizer=optimizer, enrich_network=true, passes=2, save_to_db=false)
    catch e
        e isa InterruptException && rethrow()
        @error "DAY FAILED $d" exception=(e, catch_backtrace())
        continue
    end
    open(out, "a") do io
        for (z, prices) in r.market_prices, (ts, p) in prices
            @printf(io, "%s\t%s\t%.10g\n", z, ts, p)
        end
    end
    nz = length(r.market_prices)
    println("DONE $d zones=$nz solve=$(round(r.solve_time, digits=1))s total=$(round(time()-t0, digits=1))s")
end
println("A/B run complete: $out")
