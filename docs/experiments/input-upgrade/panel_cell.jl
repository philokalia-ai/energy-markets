# Panel cell (Validation B of the ML-inputs wiring): clear the 39-zone EU
# footprint for ONE UTC day under the weather scenario (current main = #255 hook
# fix), overriding the 5 pilot zones' RES + load with either the committed packs
# ("old") or the pure-Julia ML models ("ml"). Neighbours keep reference ENTSO-E
# inputs, so the two arms isolate the pilots' input change. Writes the pilot-zone
# hourly cleared prices to <SP>/panel_<day>_<arm>.json.
#
# Fresh process per (day, arm); read-only extract; save_to_db=false.
#   EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true \
#   EUPHEMIA_DUCKDB_PATH=<extract> julia --project=. \
#     docs/experiments/input-upgrade/panel_cell.jl 2026-07-24 ml

const SP = "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
using Euphemia, Dates, JSON, Statistics
const REPO = dirname(dirname(dirname(@__DIR__)))
include(joinpath(REPO, "bin", "forecast_common.jl"))
include(joinpath(REPO, "bin", "weather_res.jl"))
include(joinpath(REPO, "bin", "weather_load.jl"))
include(joinpath(REPO, "bin", "ml_inputs.jl"))

day = Date(ARGS[1]); arm = ARGS[2]
arm in ("old", "ml") || error("arm must be old|ml")
PILOTS = ML_PILOT_ZONES
asof = Date(now(UTC))
lag = openmeteo_vintage_lag(day; asof=asof)
println("panel cell: day=$day arm=$arm vintage_lag=$lag")

# ── per-pilot RES + load predictions for the UTC day ──
res_pred = Dict{String,Dict{DateTime,Float64}}()
load_pred = Dict{String,Dict{DateTime,Float64}}()
hours = collect(DateTime(day):Hour(1):DateTime(day) + Hour(23))
if arm == "ml"
    r, l = build_ml_inputs(PILOTS, day, day, Set([day]); asof=asof)
    global res_pred = r; global load_pred = l
else
    respack = load_res_models(); loadpack = load_load_models()
    for z in PILOTS
        zm = respack["zones"][z]
        cells = [(Float64(c[1]), Float64(c[2])) for c in zm["cells"]]
        rw = fetch_weather(cells, [day]; vintage_lag=lag)
        res_pred[z] = predict_res(respack, z, hours, rw)
        lz = loadpack["zones"][z]
        cities = [(Float64(c[1]), Float64(c[2])) for c in lz["cities"]]
        lw = fetch_load_weather(cities, collect((day - Day(2)):Day(1):day); vintage_lag=lag)
        load_pred[z] = predict_load(loadpack, z, hours, lw)
    end
end

# ── scenario: override RES + load for the pilots (neighbours reference) ──
scenario = Dict{String,Euphemia.ZoneScenario}()
for z in PILOTS
    zr = get(res_pred, z, Dict{DateTime,Float64}())
    zl = get(load_pred, z, Dict{DateTime,Float64}())
    rmod = (ts, mw) -> get(zr, trunc(DateTime(ts, dateformat"yyyymmdd-HHMM"), Hour), mw)
    lmod = (ts, mw) -> get(zl, trunc(DateTime(ts, dateformat"yyyymmdd-HHMM"), Hour), mw)
    scenario[z] = Euphemia.ZoneScenario(load_modifier=lmod, renewable_modifier=rmod)
end

r = Euphemia.run_multi_zone_market_clearing(day; zones=FORECAST_FOOTPRINT,
    order_method=:merit_order, optimizer="highs", silent=true, save_to_db=false,
    enrich_network=true, passes=2, scenario=scenario)

out = Dict{String,Dict{String,Float64}}()
for z in PILOTS
    haskey(r.market_prices, z) || continue
    acc = Dict{DateTime,Vector{Float64}}()
    for (k, v) in r.market_prices[z]
        push!(get!(acc, trunc(DateTime(k, dateformat"yyyymmdd-HHMM"), Hour), Float64[]), v)
    end
    out[z] = Dict(Dates.format(h, "yyyymmdd-HHMM") => mean(vs) for (h, vs) in acc)
end
open(joinpath(SP, "panel_$(day)_$(arm).json"), "w") do io; JSON.print(io, out); end
println("PANEL_CELL_DONE $day $arm zones=$(join(keys(out), ","))")
