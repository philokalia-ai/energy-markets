# Pan-European cold ironing (OPS), FLOOR scenario, on the full 39-zone EU
# footprint — cv17 model. Two labeled runs over the AIS data window
# (2023-07-01..2025-06-30, 730 days):
#
#   eu17_base           : no scenario (fresh cv17 baseline for this window)
#   eu17_ops_floor_paneu: per-zone extra_orders from the pan-EU OPS profile
#                         (ops_hourly_eu_floor_2023H2_2025H1.csv — 24 zones,
#                          ~2,494 GWh/yr; registry-confirmed >5000 GT only)
#
#   julia --project=. docs/experiments/scenario-exercises/eu_pan_ops.jl
#   SMOKE=true julia --project=. ...   # one 2023-07 day, no saves, prints deltas
#
# Both runs are resumable per (day, clearing_mode); rerun to continue.
# Same environment discipline as eu_scenarios.jl: flow mode pinned :v2
# (forwarded to pipeline workers), offline DuckDB extract read-only, results
# to data/results.duckdb, Gurobi capped at 2 solver workers (WLS sessions).
#
# Zone mapping / exclusions are documented in the profile builder
# (scratchpad build_eu_ops_profiles.py, summarized in README.md): out of
# footprint IE/HR/MT/CY; non-coupled island systems excluded (Canaries,
# Ceuta/Melilla, Madeira/Azores, Corsica, Mayotte).

ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "v2")
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
const EXTRACT_PATH = get(ENV, "EUPHEMIA_DUCKDB_PATH",
    normpath(joinpath(@__DIR__, "..", "..", "..", "data", "extracts", "euphemia-live.duckdb")))
ENV["EUPHEMIA_DUCKDB_PATH"] = EXTRACT_PATH
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"

using Euphemia, Dates, CSV, DataFrames

configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT_PATH,
    read_only=true, results_writable=true)

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

# --- per-zone hourly OPS MW: zone => ("yyyymmdd-HH" => MW) ------------------
const OPS_BY_ZONE = let
    csv_path = joinpath(@__DIR__, "ops_hourly_eu_floor_2023H2_2025H1.csv")
    df = CSV.read(isfile(csv_path) ? csv_path : csv_path * ".gz", DataFrame)
    d = Dict{String,Dict{String,Float64}}()
    for r in eachrow(df)
        dt = DateTime(string(r.datetime_utc)[1:19], dateformat"yyyy-mm-dd HH:MM:SS")
        get!(d, String(r.zone), Dict{String,Float64}())[Dates.format(dt, "yyyymmdd-HH")] =
            Float64(r.mw)
    end
    d
end
@assert all(z -> z in FOOTPRINT, keys(OPS_BY_ZONE)) "profile zone outside footprint"
println("OPS profile: $(length(OPS_BY_ZONE)) zones, " *
    "$(round(sum(sum(values(m)) for m in values(OPS_BY_ZONE))/1000/2, digits=0)) GWh/yr")

# one extra_orders closure per zone (workers have Euphemia + Dates loaded;
# closures capture only plain Dicts)
make_ops_orders(mw_by_hour::Dict{String,Float64}) = ctx -> begin
    orders = SimpleOrder[]
    for ts in ctx.timeslots
        mw = get(mw_by_hour, ts[1:11], 0.0)
        mw > 0 && push!(orders, SimpleOrder(:demand, 3000.0, mw, Symbol(ctx.zone),
            DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes))
    end
    orders
end
pan_ops_scenario = Dict(z => ZoneScenario(extra_orders=make_ops_orders(m))
                        for (z, m) in OPS_BY_ZONE)

# --- smoke mode: one early-window day, no saves, print deltas ---------------
if get(ENV, "SMOKE", "false") == "true"
    day = Date(2023, 7, 5)
    println("SMOKE: $day baseline vs pan-OPS (no saves)")
    base = run_multi_zone_market_clearing(day; zones=FOOTPRINT,
        order_method=:merit_order, enrich_network=true, passes=2,
        optimizer="gurobi", save_to_db=false)
    scn = run_multi_zone_market_clearing(day; zones=FOOTPRINT,
        order_method=:merit_order, enrich_network=true, passes=2,
        optimizer="gurobi", save_to_db=false, scenario=pan_ops_scenario)
    for z in ["GR", "ES", "IT-CSOUTH", "IT-Sardinia", "FR", "DE_LU", "FI", "RO"]
        b = get(base.market_prices, z, nothing); s = get(scn.market_prices, z, nothing)
        (b === nothing || s === nothing) && (println("  $z: MISSING"); continue)
        mb = sum(values(b)) / length(b); ms = sum(values(s)) / length(s)
        println("  $z: base $(round(mb, digits=2)) -> ops $(round(ms, digits=2))  " *
                "Δ=$(round(ms - mb, digits=3)) €/MWh")
    end
    exit(0)
end

# --- the two labeled runs ----------------------------------------------------
RUNS = [
    ("eu17_base",            nothing),
    ("eu17_ops_floor_paneu", pan_ops_scenario),
]
for (label, scn) in RUNS
    days = Date(2023, 7, 1):Day(1):Date(2025, 6, 30)
    println("\n" * "#"^70)
    println("# RUN $label  ($(first(days))..$(last(days)), $(length(days)) days)")
    println("#"^70)
    r = run_pipelined_backfill(collect(days), FOOTPRINT;
        solver_workers=2, optimizer="gurobi",
        clearing_mode=label, save_to_db=true, save_prices_only=true,
        resume=true, scenario=scn)
    println("[$label] processed=$(r.processed) saved=$(r.saved) " *
            "failed=$(r.failed) days/h=$(round(r.days_per_hour, digits=1))")
end
println("ALL PAN-EU OPS RUNS DONE")
