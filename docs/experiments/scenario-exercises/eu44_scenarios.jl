# cv44 scenario harness (copy of eu43_scenarios.jl; labels eu44_*) — GR data center, "bring your own power" (BYOP) and
# pan-EU cold ironing on a DETERMINISTIC STRATIFIED SAMPLE of days, paired
# against a fresh baseline cleared by the same code (there is no stored cv43
# record locally).
#
#   eu44_base            : scenario=nothing
#   eu44_dc574           : GR +574 MW flat load                 (= BYOP s = 0 %)
#   eu44_byop_s{25,50,75,100}: DC +574 MW AND a new GR CCGT offering
#                          s × 574 MW every hour at its own SRMC
#                          (η = BYOP_ETA, default 0.59; nameplate =
#                          s × 574 / BYOP_AVAIL — only the offered MW enters
#                          the clear; SRMC from the SAME ex-ante TTF/EUA closes
#                          the fleet uses: get_ttf_price / eua_price(day))
#   eu44_ops_floor_paneu : pan-EU cold-ironing FLOOR profile (24 zones),
#                          first sample year only (the AIS window)
#   eu44_byop_s150/_s200 : s > 100 % bracket arms, run only when named in
#                          SCN_ARMS (the Nov 2026 run used SCN_STEP=8 for them)
#
# Day sample: every SCN_STEP-th day (default 4) from 2024-07-01 to 2026-06-30
# (183 days); cold ironing uses the sample days ≤ 2025-06-30 (92 days, a subset
# of the same days, so it reuses the baseline).
#
# Env (all optional):
#   SCN_ARMS        comma list of arm labels to run (default: all, in order)
#   SCN_STEP        sample stride in days (default 4)
#   SCN_DAYS        explicit comma list of ISO days (overrides the sample; dry runs)
#   SCN_SOLVERS     solver workers (default 50)   SCN_BOOKS  book workers (default 10)
#   SCN_INFLIGHT    days in flight (default solvers + 8). Keep it >= solvers: the
#                   pipeline default of 8 caps concurrency at 8 days.
#   SCN_OPTIMIZER   highs (default) | gurobi
#   BYOP_ETA        0.59      BYOP_AVAIL  0.90
#   EUPHEMIA_DUCKDB_PATH / EUPHEMIA_RESULTS_DB as usual (extract read-only).
#
# Resumable per (day, clearing_mode). Run from the repo root (cv44+, Julia 1.13):
#   julia --project=. docs/experiments/scenario-exercises/eu44_scenarios.jl
# Results DB: EUPHEMIA_RESULTS_DB (one DB per process when arms run in parallel;
# analysis merges them into one snapshot). Worker RSS grows to ~5-6 GB over a
# run: size SCN_SOLVERS + SCN_BOOKS to the free memory.

ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
const EXTRACT_PATH = ENV["EUPHEMIA_DUCKDB_PATH"]
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"
ENV["EUPHEMIA_DUCKDB_NPROCS_HINT"] = get(ENV, "EUPHEMIA_DUCKDB_NPROCS_HINT", "64")

using Euphemia, Dates, CSV, DataFrames

configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT_PATH,
    read_only=true, results_writable=true)

const CV = Euphemia.ENERGY_PRICES_CODE_VERSION
CV == 44 || @warn "harness expects cv44 code, running cv$CV"

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

const STEP = parse(Int, get(ENV, "SCN_STEP", "4"))
const SAMPLE = isempty(get(ENV, "SCN_DAYS", "")) ?
    collect(Date(2024, 7, 1):Day(STEP):Date(2026, 6, 30)) :
    Date.(strip.(split(ENV["SCN_DAYS"], ",")))
const OPS_DAYS = filter(d -> d <= Date(2025, 6, 30), SAMPLE)

# --- DC + BYOP ----------------------------------------------------------------
const DC_MW = 574.0
const BYOP_ETA = parse(Float64, get(ENV, "BYOP_ETA", "0.59"))
const BYOP_AVAIL = parse(Float64, get(ENV, "BYOP_AVAIL", "0.90"))
# SRMC = TTF/η + 0.202/η·EUA + 2: the fleet's gas formula (src/generators/
# fuel_costs.jl) with a new H-class CCGT efficiency instead of the 0.55 average.
# Hooks are closures serialized to the pipeline's book workers: they must not
# reference Main globals or Main-defined named functions (the workers do not
# have them), so every constant is captured as a local and the SRMC is
# computed inline from Euphemia's own ex-ante closes.
make_byop_orders(share::Float64, eta::Float64, mw_dc::Float64) = let share = share, eta = eta, mw_dc = mw_dc
    ctx -> begin
        orders = SimpleOrder[]
        ctx.zone == "GR" || return orders
        ttf = Euphemia.get_ttf_price(ctx.day)   # last close strictly before D (fleet rule)
        ttf === nothing && return orders         # no fuel price ⇒ plant not offered
        c = ttf / eta + 0.202 / eta * Euphemia.eua_price(ctx.day) + 2.0   # fleet's EF/VOM, own η
        mw = share * mw_dc                       # offered = nameplate × availability
        for ts in ctx.timeslots
            push!(orders, SimpleOrder(:supply, c, mw, Symbol(ctx.zone),
                DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes))
        end
        orders
    end
end

dc_scenario = Dict("GR" => ZoneScenario(load_modifier=(ts, l) -> l + 574.0))
byop_scenario(share) = Dict("GR" => ZoneScenario(load_modifier=(ts, l) -> l + 574.0,
                                                 extra_orders=make_byop_orders(share, BYOP_ETA, DC_MW)))

# --- cold ironing (unchanged from eu37_scenarios.jl) ---------------------------
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

# --- runs ------------------------------------------------------------------------
ALL_RUNS = [
    ("eu44_base",            nothing,             SAMPLE),
    ("eu44_dc574",           dc_scenario,         SAMPLE),
    ("eu44_byop_s50",        byop_scenario(0.50), SAMPLE),
    ("eu44_byop_s100",       byop_scenario(1.00), SAMPLE),
    ("eu44_byop_s25",        byop_scenario(0.25), SAMPLE),
    ("eu44_byop_s75",        byop_scenario(0.75), SAMPLE),
    # s > 100 %: the merchant plant sized above the DC load (s* bracket; run
    # only when named in SCN_ARMS)
    ("eu44_byop_s150",       byop_scenario(1.50), SAMPLE),
    ("eu44_byop_s200",       byop_scenario(2.00), SAMPLE),
    ("eu44_ops_floor_paneu", pan_ops_scenario,    OPS_DAYS),
]
want = strip.(split(get(ENV, "SCN_ARMS", join(filter(a -> !(a in ("eu44_byop_s150", "eu44_byop_s200")), first.(ALL_RUNS)), ",")), ","))
RUNS = [r for r in ALL_RUNS if r[1] in want]
println("cv$CV harness: $(length(SAMPLE)) sample days (step $STEP), ops $(length(OPS_DAYS)); " *
        "arms: $(join(first.(RUNS), ", ")); BYOP η=$BYOP_ETA avail=$BYOP_AVAIL")

for (label, scn, days) in RUNS
    isempty(days) && continue
    println("\n" * "#"^70)
    println("# RUN $label  ($(first(days))..$(last(days)), $(length(days)) days)")
    println("#"^70)
    t0 = time()
    r = run_pipelined_backfill(days, FOOTPRINT;
        solver_workers=parse(Int, get(ENV, "SCN_SOLVERS", "50")),
        book_workers=parse(Int, get(ENV, "SCN_BOOKS", "10")),
        # days in flight: the pipeline default (8) caps concurrency at 8 days
        # whatever the solver count — keep it >= solver workers.
        in_flight=parse(Int, get(ENV, "SCN_INFLIGHT", string(parse(Int, get(ENV, "SCN_SOLVERS", "50")) + 8))),
        optimizer=get(ENV, "SCN_OPTIMIZER", "highs"),
        clearing_mode=label, save_to_db=true, save_prices_only=true,
        resume=true, scenario=scn)
    println("RUN_DONE label=$label processed=$(r.processed) saved=$(r.saved) " *
            "failed=$(r.failed) days_per_hour=$(round(r.days_per_hour, digits=1)) " *
            "wall_s=$(round(Int, time() - t0))")
end
println("SCN44_DONE")
