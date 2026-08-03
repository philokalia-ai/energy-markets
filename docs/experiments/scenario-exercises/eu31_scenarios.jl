# The merged cv31 scenario set on the 39-zone EU footprint, paired against the
# STORED cv31 record (clearing_mode='multi_zone_eu', code_version=31 in
# data/results.duckdb) instead of a re-run baseline. Validity of that pairing is
# proven at startup: one record day is re-cleared with scenario=nothing and must
# be bit-identical to the stored rows (GUARD_OK), else the script aborts.
#
#   eu31_dc574          : GR data center +574 MW (load_modifier),
#                         2024-07-01..2026-06-30 (730 d)
#   eu31_ops_floor_paneu: pan-EU cold ironing, FLOOR profile, per-zone
#                         extra_orders (24 zones), 2024-07-01..2025-06-30
#                         (365 d — the AIS data window's overlap with the DC one)
#
#   julia --project=. docs/experiments/scenario-exercises/eu31_scenarios.jl
#
# Environment mirrors the cv31 record backfill: offline DuckDB extract
# read-only, results to data/results.duckdb, HiGHS (canonical), NO flow-mode
# pin (the cv25+ pipeline entries resolve the scoped :v3 ex-ante default).
# Resumable per (day, clearing_mode).

ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
const EXTRACT_PATH = get(ENV, "EUPHEMIA_DUCKDB_PATH",
    normpath(joinpath(@__DIR__, "..", "..", "..", "data", "extracts", "euphemia-live.duckdb")))
ENV["EUPHEMIA_DUCKDB_PATH"] = EXTRACT_PATH
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"
ENV["EUPHEMIA_DUCKDB_NPROCS_HINT"] = get(ENV, "EUPHEMIA_DUCKDB_NPROCS_HINT", "60")

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

# --- GUARD: the stored record is a valid baseline for today's main ----------
# Re-clear one full record day with scenario=nothing; every stored zone-hour
# must match bit-identically, else current code != record code and a fresh
# baseline run would be required.
let guard_day = Date(2025, 4, 15)
    println("GUARD start $guard_day (record day re-clear, no saves)")
    res = run_multi_zone_market_clearing(guard_day; zones=FOOTPRINT,
        order_method=:merit_order, enrich_network=true, passes=2,
        optimizer="highs", save_to_db=false)
    stored = Euphemia.sql2df("""
        SELECT bidding_zone, date_time_utc, price_eur_mwh
        FROM simulations.energy_prices
        WHERE clearing_mode = 'multi_zone_eu' AND code_version = 31
          AND date_time_utc >= \$1::date AND date_time_utc < \$1::date + 1""",
        [guard_day])
    nrow(stored) >= 900 || (println("GUARD_FAIL stored rows=$(nrow(stored))"); exit(1))
    maxd = 0.0; ncmp = 0; nmiss = 0; ndiff = 0
    for r in eachrow(stored)
        ts = Dates.format(r.date_time_utc, "yyyymmdd-HHMM")
        zp = get(res.market_prices, String(r.bidding_zone), nothing)
        p = zp === nothing ? nothing : get(zp, ts, nothing)
        p === nothing && (nmiss += 1; continue)
        d = abs(Float64(p) - Float64(r.price_eur_mwh))
        d > 0 && (ndiff += 1)
        maxd = max(maxd, d); ncmp += 1
    end
    println("GUARD compared=$ncmp missing=$nmiss differing=$ndiff maxdelta=$maxd")
    # Threshold 1e-9, not exact 0: the stored record was produced by the
    # 50-worker pipeline, whose concurrent book builds carry the documented
    # last-ULP SQL-aggregate reordering (≤ ~1e-12 €/MWh through a marginal
    # tranche's scarcity factor). A real code change shows up at ≥ 1e-2.
    (maxd <= 1e-9 && nmiss == 0 && ncmp >= 900) ||
        (println("GUARD_FAIL maxdelta=$maxd missing=$nmiss"); exit(1))
    println("GUARD_OK stored cv31 record pairs with scenario=nothing (ULP class only)")
end

# --- Scenario 1: GR data center +574 MW -------------------------------------
dc_scenario = Dict("GR" => ZoneScenario(load_modifier=(ts, l) -> l + 574.0))

# --- Scenario 2: pan-EU cold ironing, FLOOR profile -------------------------
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
println("OPS profile: $(length(OPS_BY_ZONE)) zones")

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

# --- the labeled runs (record baseline needs no run) ------------------------
RUNS = [
    ("eu31_dc574",           dc_scenario,     Date(2024, 7, 1), Date(2026, 6, 30)),
    ("eu31_ops_floor_paneu", pan_ops_scenario, Date(2024, 7, 1), Date(2025, 6, 30)),
]
for (label, scn, d0, d1) in RUNS
    days = d0:Day(1):d1
    println("\n" * "#"^70)
    println("# RUN $label  ($(first(days))..$(last(days)), $(length(days)) days)")
    println("#"^70)
    r = run_pipelined_backfill(collect(days), FOOTPRINT;
        solver_workers=50, book_workers=10, optimizer="highs",
        clearing_mode=label, save_to_db=true, save_prices_only=true,
        resume=true, scenario=scn)
    println("RUN_DONE label=$label processed=$(r.processed) saved=$(r.saved) " *
            "failed=$(r.failed) days_per_hour=$(round(r.days_per_hour, digits=1))")
end
println("SCN31_DONE")
