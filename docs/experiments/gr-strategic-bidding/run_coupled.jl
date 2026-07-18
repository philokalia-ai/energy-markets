# Robustness test: does the GR top-slice finding survive IMPORT RESPONSE?
#
# The main experiment (run_all.jl) clears GR SINGLE-ZONE — imports fixed at
# historical values, so a PPC markup raises the GR price with nothing pushing
# back. This re-runs the winning strategy on the FULL 39-zone coupled footprint
# (enrich_network, two-pass), where neighbours can import into GR against the
# markup. If the improvement shrinks, part of the single-zone gain was the
# no-import-relief artifact; if it holds, the finding is real under coupling.
#
#   julia --project=. docs/experiments/gr-strategic-bidding/run_coupled.jl
#
# Two labeled runs on the same 60 days, saved to data/results.duckdb:
#   gr_strat_eu_base      : no scenario (cv17 coupled baseline)
#   gr_strat_eu_topslice  : GR ZoneScenario(strategist = top-slice 25%)
# Evaluate GR vs settled with eval_coupled.py.

ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "v2")
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
const EXTRACT = abspath(joinpath(homedir(), "armada/energy-markets/data/extracts/euphemia-live.duckdb"))
ENV["EUPHEMIA_DUCKDB_PATH"] = EXTRACT
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"

using Euphemia, Dates, JSON
configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT, read_only=true,
    results_writable=true)

const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]

const DAYS = [Date(d) for d in JSON.parsefile(joinpath(@__DIR__, "days.json"))]

# self-contained top-slice strategist (25% on PPC flexible tranches) — no
# external helpers so it serializes cleanly to pipeline workers.
const GR_BIG = Set(["PPC"])
function gr_topslice(ctx)
    markup = 0.25; slice_from = 1.10
    key(o) = Dates.format(o.date_time, "yyyymmdd-HHMM")
    minp = Dict{Tuple{String,String},Float64}()
    for (o, tag) in ctx.tagged_orders
        (o.type == :supply && get(ctx.firm_of, tag, "") in GR_BIG) || continue
        k = (tag, key(o)); minp[k] = min(get(minp, k, Inf), o.price)
    end
    out = Tuple{SimpleOrder,String}[]
    for (o, tag) in ctx.tagged_orders
        if o.type == :supply && get(ctx.firm_of, tag, "") in GR_BIG
            base = get(minp, (tag, key(o)), o.price)
            push!(out, (o.price > slice_from * base ?
                SimpleOrder(o.type, o.price * (1 + markup), o.quantity, o.zone,
                    o.date_time, o.resolution_code) : o, tag))
        else
            push!(out, (o, tag))
        end
    end
    out
end

const RUNS = [
    ("gr_strat_eu_base",     nothing),
    ("gr_strat_eu_topslice", Dict("GR" => ZoneScenario(strategist=gr_topslice))),
]

for (label, scn) in RUNS
    println("\n", "#"^66, "\n# RUN $label  ($(length(DAYS)) days)\n", "#"^66)
    r = run_pipelined_backfill(DAYS, FOOTPRINT;
        solver_workers=2, optimizer="gurobi",
        clearing_mode=label, save_to_db=true, save_prices_only=true,
        resume=true, scenario=scn)
    println("[$label] processed=$(r.processed) saved=$(r.saved) failed=$(r.failed)")
end
println("COUPLED ROBUSTNESS RUNS DONE")
