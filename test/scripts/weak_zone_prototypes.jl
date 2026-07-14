# Weak-zone diagnosis prototypes (docs/experiments/weak-zone-diagnosis).
#
# Re-clears a stratified 28-day benchmark (16 phantom-spike days + 12 normal
# days) on the full 39-zone EU footprint under prototype variants, WITHOUT
# touching production code: all changes are runtime overrides (method
# redefinition + ZONE_PROFILES mutation + the built-in scenario hooks).
#
#   VARIANT=v0  julia --project=. test/scripts/weak_zone_prototypes.jl
#     v0: no overrides — replication check against stored eu_scn_base rows
#     v1: extended flow-based border drops (AT–CZ, AT–DE_LU, AT–SI)
#         + SI on the Slovakia treatment (continental temperament + :hydro
#           anchor so the dropped-border imports price at the coupled ref)
#     v2: v1 + ex-ante elastic import backstop (see below) for the weak zones
#     v3: backstop only (no drops) — isolates the two mechanisms
#     v4: v1 + backstop with the wider 56-calendar-day capability window
#         (physical import capability is weekday-agnostic; the 8-same-weekday
#         max misses tail days whose flows exceed any recent same-weekday draw)
#
# Import backstop (v2/v3): for each weak zone, one extra supply block per
# hour, tagged EXTRA via the ZoneScenario extra_orders hook:
#   qty(h)   = max(0, max_{k=1..8} netimport(day-7k, h) − median_{k}(...)(h))
#              — the import headroom the zone has DEMONSTRATED on recent
#                same-weekday days beyond the climatology injection the
#                model already carries (both strictly ex-ante: D-7..D-56).
#   price(h) = 1.8 × gas SRMC — above every domestic tranche multiplier
#              (max 1.60), so it never displaces domestic supply or normal
#              imports; it only stops the book from jumping from ~1.6×gas
#              to the 3000 cap when physically-demonstrated import capability
#              exceeds the scheduled injection.
#
# Results: one CSV per variant under docs/experiments/weak-zone-diagnosis/data/
# (zone, ts, price). Guard zones GR/DE_LU/ES/PT receive NO scenario hooks; the
# v1 drops touch only AT/SI borders.

ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "v2")
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
const REPO = normpath(joinpath(@__DIR__, "..", ".."))
const EXTRACT_PATH = get(ENV, "EUPHEMIA_DUCKDB_PATH",
    joinpath(REPO, "data", "extracts", "euphemia-live.duckdb"))
ENV["EUPHEMIA_DUCKDB_PATH"] = EXTRACT_PATH
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"
# Never write into the shared results DB from a prototype run
ENV["EUPHEMIA_RESULTS_DB"] = get(ENV, "EUPHEMIA_RESULTS_DB",
    joinpath(tempdir(), "weak_zone_proto_results.duckdb"))
haskey(ENV, "GRB_LICENSE_FILE") ||
    (ENV["GRB_LICENSE_FILE"] = joinpath(homedir(), "gurobi.lic"))

using Euphemia, Dates

configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT_PATH,
    read_only=true, results_writable=true)

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

# Stratified benchmark: 16 phantom-spike days (each weak zone represented,
# incl. the shared SEE cold-snap cluster and the RO June-2026 run) + 12
# spike-free days spread over seasons and weekday/weekend.
const SPIKE_DAYS = Date[
    Date(2024, 8, 22),   # SI (summer cluster)
    Date(2024, 10, 14),  # BE
    Date(2024, 12, 11),  # DK2
    Date(2025, 1, 1),    # CH (holiday ATC gap)
    Date(2025, 1, 14),   # RO, BE, RS
    Date(2025, 2, 11),   # IT-CNORTH
    Date(2025, 4, 8),    # DK1
    Date(2025, 7, 3),    # SI
    Date(2025, 8, 27),   # DK1, DK2
    Date(2025, 10, 5),   # AT, RS, SI
    Date(2025, 11, 18),  # AT
    Date(2025, 12, 1),   # AT
    Date(2026, 1, 13),   # SI, RO, HU, RS (SEE cold snap)
    Date(2026, 1, 28),   # BE
    Date(2026, 2, 18),   # DK1, DK2, SE3
    Date(2026, 6, 20),   # RO (June 2026 run)
]
const NORMAL_DAYS = Date[
    Date(2024, 7, 10), Date(2024, 9, 14), Date(2024, 10, 22), Date(2024, 11, 24),
    Date(2025, 2, 25), Date(2025, 3, 26), Date(2025, 5, 14), Date(2025, 6, 21),
    Date(2025, 9, 16), Date(2025, 12, 14), Date(2026, 3, 10), Date(2026, 5, 20),
]
const BENCH_DAYS = vcat(SPIKE_DAYS, NORMAL_DAYS)

const VARIANT = lowercase(get(ENV, "VARIANT", "v1"))
const DAYS = haskey(ENV, "DAYS") ?
    [Date(strip(s)) for s in split(ENV["DAYS"], ",")] : BENCH_DAYS
const OUTDIR = get(ENV, "OUTDIR",
    joinpath(REPO, "docs", "experiments", "weak-zone-diagnosis", "evidence"))
mkpath(OUTDIR)

# ---------------------------------------------------------------------------
# v1: extended flow-based border drops + SI anchor (runtime overrides only)
# ---------------------------------------------------------------------------
function apply_v1_overrides!()
    # Chronic Core-FBMC residual ATC (measured, see README):
    #   CZ→AT  offered ATC p10 = 0, avg ~300 MW vs ~1.6 GW physical on spike hrs
    #   DE_LU→AT          p10 = 0, avg ~250 MW vs ~2.0 GW physical
    #   AT→SI             p10 = 0, avg ~150 MW vs ~1.3 GW physical
    base = Euphemia.flow_based_drop_borders(FOOTPRINT)
    extra = [("AT", "CZ"), ("AT", "DE_LU"), ("AT", "SI")]
    merged = unique(vcat(base, extra))
    @eval Euphemia function flow_based_drop_borders(
        footprint::AbstractVector{<:AbstractString})
        return $(merged)
    end
    # SI gets the Slovakia treatment: continental scarcity temperament +
    # :hydro opportunity anchor so the dropped AT-border imports price at the
    # coupled Core reference instead of the €1 price-taker block.
    Euphemia.MeritOrderBook.ZONE_PROFILES["SI"] =
        Euphemia.MeritOrderBook.ZoneProfile(
            scarcity_threshold = 1.25,
            scarcity_kappa = 1.5,
            peak_kappa = 0.6,
            opportunity_anchor = :hydro,
        )
    println("v1 overrides applied: drops += $(extra); SI → SK-style anchored profile")
end

# ---------------------------------------------------------------------------
# v2/v3: ex-ante elastic import backstop via the scenario extra_orders hook
# ---------------------------------------------------------------------------
const BACKSTOP_ZONES = ["AT", "BE", "CH", "DK1", "DK2", "SE3", "IT-CNORTH",
                        "SI", "RO", "HU", "RS"]

# Net import of `zone` at `hour` from a (h,cp,dir)=>flow border map
_net_at(bh, hour) = sum((dir * v for ((h, _, dir), v) in bh if h == hour); init=0.0)

const BACKSTOP_LAGS = Ref{Vector{Int}}([7k for k in 1:8])  # v4 sets 1:56

const _BACKSTOP_CACHE = Dict{Tuple{String,Date},Dict{Int,Float64}}()
function backstop_by_hour(zone::String, day::Date)
    get!(_BACKSTOP_CACHE, (zone, day)) do
        # capability window: all lags strictly before the D-1 auction
        lagged = [Euphemia.MeritOrderBook._zone_border_hourly(zone, day; lag=l)
                  for l in BACKSTOP_LAGS[]]
        clim = Euphemia.MeritOrderBook._zone_border_hourly_clim(zone, day)
        out = Dict{Int,Float64}()
        for h in 0:23
            mx = maximum((_net_at(bh, h) for bh in lagged); init=-Inf)
            cl = _net_at(clim, h)
            out[h] = isfinite(mx) ? max(0.0, mx - cl) : 0.0
        end
        out
    end
end

function backstop_orders(ctx)
    qty = backstop_by_hour(ctx.zone, ctx.day)
    price = 1.8 * Euphemia.get_marginal_cost(ctx.day, "Fossil Gas", ctx.zone)
    orders = SimpleOrder[]
    for ts in ctx.timeslots
        h = parse(Int, ts[10:11])
        q = get(qty, h, 0.0)
        q > 1.0 && push!(orders, SimpleOrder(:supply, price, q, Symbol(ctx.zone),
            DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes))
    end
    return orders
end

backstop_scenario() = Dict{String,ZoneScenario}(
    z => ZoneScenario(extra_orders=backstop_orders) for z in BACKSTOP_ZONES)

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
scenario = nothing
if VARIANT == "v1"
    apply_v1_overrides!()
elseif VARIANT == "v2"
    apply_v1_overrides!()
    scenario = backstop_scenario()
elseif VARIANT == "v3"
    scenario = backstop_scenario()
elseif VARIANT == "v4"
    apply_v1_overrides!()
    BACKSTOP_LAGS[] = collect(1:56)
    scenario = backstop_scenario()
elseif VARIANT != "v0"
    error("unknown VARIANT=$(VARIANT)")
end

outfile = joinpath(OUTDIR, "prices_$(VARIANT).csv")
done = Set{String}()
if isfile(outfile)   # resumable: skip days already in the CSV
    for line in Iterators.drop(eachline(outfile), 1)
        push!(done, split(line, ",")[2][1:8])
    end
else
    open(outfile, "w") do io
        println(io, "zone,ts,price")
    end
end

for day in DAYS
    key = Dates.format(day, "yyyymmdd")
    key in done && (println("skip $day (already done)"); continue)
    println("\n===== $VARIANT $day =====")
    t0 = time()
    result = run_multi_zone_market_clearing(day;
        zones=FOOTPRINT, order_method=:merit_order, optimizer="gurobi",
        enrich_network=true, passes=2, save_to_db=false,
        scenario=scenario)
    if result === nothing || isempty(result.market_prices)
        @warn "no prices for $day"
        continue
    end
    open(outfile, "a") do io
        for (zone, prices) in result.market_prices
            for (ts, p) in prices
                println(io, "$zone,$ts,$p")
            end
        end
    end
    println("day $day done in $(round(time() - t0, digits=1)) s")
end
println("\nAll requested days done → $outfile")
