# Sequential re-run of ONLY the coupled top-slice label (gr_strat_eu_base is
# already saved by run_coupled.jl). Sequential run_multi_zone_market_clearing
# commits each day in its own transaction, avoiding the pipeline's end-of-segment
# teardown hang. Resumable: already-saved (day, label) pairs are skipped.
#
#   julia --project=. docs/experiments/gr-strategic-bidding/run_coupled_topslice_seq.jl

ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "v2")
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
const EXTRACT = abspath(joinpath(homedir(), "armada/energy-markets/data/extracts/euphemia-live.duckdb"))
ENV["EUPHEMIA_DUCKDB_PATH"] = EXTRACT
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"

using Euphemia, Dates, JSON, DataFrames
configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT, read_only=true,
    results_writable=true)

const FOOTPRINT = String[
    "AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU","LT",
    "LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS","SE1","SE2","SE3",
    "SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH","IT-SOUTH","IT-Calabria",
    "IT-Sicily","IT-Sardinia","CH"]
const DAYS = [Date(d) for d in JSON.parsefile(joinpath(@__DIR__, "days.json"))]
const LABEL = "gr_strat_eu_topslice"

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
const SCN = Dict("GR" => ZoneScenario(strategist=gr_topslice))

# which days already saved for this label?
saved = Set{Date}()
try
    df = Euphemia.sql2df("""
        SELECT DISTINCT CAST(date_time_utc AS DATE) d
        FROM simulations.energy_prices WHERE clearing_mode='$LABEL'""")
    saved = Set(Date.(df.d))
catch; end

todo = [d for d in DAYS if !(d in saved)]
println("$LABEL: $(length(saved)) already saved, $(length(todo)) to run")
for (i, day) in enumerate(todo)
    print("[$i/$(length(todo))] $day ... ")
    r = run_multi_zone_market_clearing(day; zones=FOOTPRINT,
        order_method=:merit_order, enrich_network=true, passes=2,
        optimizer="gurobi", save_to_db=true, clearing_mode=LABEL, scenario=SCN)
    gr = get(r.market_prices, "GR", Dict())
    println("GR $(length(gr)) hrs, mean €$(isempty(gr) ? "-" : round(sum(values(gr))/length(gr),digits=1))")
end
println("DONE $LABEL")
