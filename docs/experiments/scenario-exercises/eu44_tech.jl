# cv44 "bring your own power" BY TECHNOLOGY: the GR data center (+574 MW flat)
# plus a new GR plant of a given technology, sized by ANNUAL ENERGY e relative
# to the DC's consumption (574 MW × 8760 h = 5.03 TWh/yr). Paired with the cv44
# base and DC arms of eu44_scenarios.jl (same code + extract ⇒ deterministic
# clear, so base/dc574 are reused, not re-cleared; `eu44_base` here is only
# for a one-day match check).
#
#   eu44t_pv_e100/_e200     GR utility PV: hourly MW = e·574·cf_norm(h), offered
#                           at −0.01 €/MWh (merchant: curtails at negative prices)
#   eu44t_wind_e100/_e200   the same with GR's wind profile
#   eu44t_pvwind_e100       pv_e100 + wind_e100 (optional mix, e = 200 % total)
#   eu44t_firm_e100         flat zero-carbon baseload: 574 MW offered every hour
#                           (= 638 MW × 0.9 availability) at 10 €/MWh
#   eu44t_pv_e100_batt4h    pv_e100 + a 574 MW / 2,296 MWh battery: DISCHARGE is
#                           an energy-limited complex-order family (LinkedHourly
#                           Order "XBATT:GR", 574 MW every hour at 1 €/MWh, daily
#                           budget 2,296 MWh) allocated by the cv44 master like
#                           PS; CHARGING is fixed GR load, 2,296/0.88 = 2,609 MWh
#                           per day at ≤ 574 MW in the day's highest-PV hours
#                           (two-step: the master has no pumping/charging side)
#   eu44t_hydro_res         new GR reservoir: family "XHYD:GR", 574 MW at 1 €/MWh,
#                           daily budget 0.30·574·24 = 4,133 MWh (natural inflow,
#                           no pumping)
#   eu44t_dc_flex10         no plant: the DC load is 0 in the hours listed in
#                           TECH_FLEX_HOURS (the top ~10 % GR price hours of the
#                           paired eu44_dc574 arm, see build_flex_hours.py)
#
# Profiles: TECH_PROFILES CSV (ts = UTC 'yyyymmdd-HH', pv_norm, wind_norm,
# charge_mw), built by build_tech_profiles.py: CF = GR actual / trailing-365-day
# max of actual, normalised by its 2024-07..2026-06 mean so e is exact in
# expectation. Requires the extra_orders → LinkedHourlyOrder pass-through in
# src/merit_order/book_build.jl (a no-op for SimpleOrder-only hooks).
#
# Env: SCN_ARMS, SCN_STEP (default 16), SCN_DAYS, SCN_SOLVERS/SCN_BOOKS/
# SCN_INFLIGHT, SCN_OPTIMIZER, TECH_PROFILES, TECH_FLEX_HOURS,
# EUPHEMIA_DUCKDB_PATH / EUPHEMIA_RESULTS_DB (extract read-only). Resumable.

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

const STEP = parse(Int, get(ENV, "SCN_STEP", "16"))
const SAMPLE = isempty(get(ENV, "SCN_DAYS", "")) ?
    collect(Date(2024, 7, 1):Day(STEP):Date(2026, 6, 30)) :
    Date.(strip.(split(ENV["SCN_DAYS"], ",")))

const DC_MW = 574.0
const PROF = let df = CSV.read(ENV["TECH_PROFILES"], DataFrame; types=Dict(:ts => String))
    (pv=Dict(String(r.ts) => Float64(r.pv_norm) for r in eachrow(df)),
     wind=Dict(String(r.ts) => Float64(r.wind_norm) for r in eachrow(df)),
     charge=Dict(String(r.ts) => Float64(r.charge_mw) for r in eachrow(df)))
end
const FLEX = let p = get(ENV, "TECH_FLEX_HOURS", "")
    isempty(p) ? Set{String}() : Set(String.(CSV.read(p, DataFrame; types=Dict(:ts => String)).ts))
end
missing_days = [d for d in SAMPLE if !haskey(PROF.pv, Dates.format(DateTime(d) + Hour(10), "yyyymmdd-HH"))]
isempty(missing_days) || error("TECH_PROFILES lacks days $(missing_days)")

# Hooks are closures serialized to the book workers: capture everything as
# locals, reference only Euphemia (loaded on the workers), never Main globals.
"RES-like supply following a normalised profile: e·574·norm(h) MW at `bid`."
make_profile_orders(parts::Vector{Tuple{Dict{String,Float64},Float64}}, bid::Float64) =
    let parts = parts, bid = bid
        ctx -> begin
            orders = Euphemia.SimpleOrder[]
            ctx.zone == "GR" || return orders
            for ts in ctx.timeslots
                mw = sum(e * 574.0 * get(prof, ts[1:11], 0.0) for (prof, e) in parts)
                mw > 0.1 && push!(orders, Euphemia.SimpleOrder(:supply, bid, mw, Symbol(ctx.zone),
                    DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes))
            end
            orders
        end
    end

"Flat supply: `mw` every slot at `bid`."
make_flat_orders(mw::Float64, bid::Float64) = let mw = mw, bid = bid
    ctx -> begin
        orders = Euphemia.SimpleOrder[]
        ctx.zone == "GR" || return orders
        for ts in ctx.timeslots
            push!(orders, Euphemia.SimpleOrder(:supply, bid, mw, Symbol(ctx.zone),
                DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes))
        end
        orders
    end
end

"Energy-limited family (complex-order master): `mw` every slot at `bid`, daily budget `e_day` MWh."
make_family_orders(fam::String, mw::Float64, bid::Float64, e_day::Float64) =
    let fam = fam, mw = mw, bid = bid, e_day = e_day
        ctx -> begin
            orders = Euphemia.MarketOrder[]
            ctx.zone == "GR" || return orders
            # budget scaled to the book's slot coverage (as _split_storage_families)
            e = e_day * min(1.0, length(ctx.timeslots) * ctx.resolution_minutes / (24 * 60))
            for ts in ctx.timeslots
                push!(orders, Euphemia.LinkedHourlyOrder(:supply, bid, mw, Symbol(ctx.zone),
                    DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes, fam, e))
            end
            orders
        end
    end

combine(fs...) = let fs = fs
    ctx -> begin
        out = Euphemia.MarketOrder[]
        for f in fs
            append!(out, f(ctx))
        end
        out
    end
end

const PV, WIND, CHARGE = PROF.pv, PROF.wind, PROF.charge
dc_load = (ts, l) -> l + 574.0
gr(extra; load=dc_load) = Dict("GR" => ZoneScenario(load_modifier=load, extra_orders=extra))

batt_load = let ch = CHARGE
    (ts, l) -> l + 574.0 + get(ch, ts[1:11], 0.0)
end
flex_load = let fx = FLEX
    (ts, l) -> l + (ts[1:11] in fx ? 0.0 : 574.0)
end

ALL_RUNS = [
    ("eu44_base",            nothing),
    ("eu44t_pv_e100",        gr(make_profile_orders([(PV, 1.0)], -0.01))),
    ("eu44t_wind_e100",      gr(make_profile_orders([(WIND, 1.0)], -0.01))),
    ("eu44t_firm_e100",      gr(make_flat_orders(574.0, 10.0))),
    ("eu44t_pv_e100_batt4h", gr(combine(make_profile_orders([(PV, 1.0)], -0.01),
                                        make_family_orders("XBATT:GR", 574.0, 1.0, 2296.0)); load=batt_load)),
    ("eu44t_hydro_res",      gr(make_family_orders("XHYD:GR", 574.0, 1.0, 0.30 * 574.0 * 24))),
    ("eu44t_pv_e200",        gr(make_profile_orders([(PV, 2.0)], -0.01))),
    ("eu44t_wind_e200",      gr(make_profile_orders([(WIND, 2.0)], -0.01))),
    ("eu44t_pvwind_e100",    gr(make_profile_orders([(PV, 1.0), (WIND, 1.0)], -0.01))),
    ("eu44t_dc_flex10",      Dict("GR" => ZoneScenario(load_modifier=flex_load))),
]
want = strip.(split(get(ENV, "SCN_ARMS", join(first.(ALL_RUNS)[2:end], ",")), ","))
RUNS = [r for r in ALL_RUNS if r[1] in want]
"eu44t_dc_flex10" in first.(RUNS) && isempty(FLEX) && error("dc_flex10 needs TECH_FLEX_HOURS")
println("cv$CV tech harness: $(length(SAMPLE)) days (step $STEP); arms: $(join(first.(RUNS), ", "))")

for (label, scn) in RUNS
    println("\n" * "#"^70)
    println("# RUN $label  ($(first(SAMPLE))..$(last(SAMPLE)), $(length(SAMPLE)) days)")
    println("#"^70)
    t0 = time()
    ns = parse(Int, get(ENV, "SCN_SOLVERS", "14"))
    r = run_pipelined_backfill(SAMPLE, FOOTPRINT;
        solver_workers=ns, book_workers=parse(Int, get(ENV, "SCN_BOOKS", "3")),
        in_flight=parse(Int, get(ENV, "SCN_INFLIGHT", string(ns + 4))),
        optimizer=get(ENV, "SCN_OPTIMIZER", "highs"),
        clearing_mode=label, save_to_db=true, save_prices_only=true,
        resume=true, scenario=scn)
    println("RUN_DONE label=$label processed=$(r.processed) saved=$(r.saved) " *
            "failed=$(r.failed) days_per_hour=$(round(r.days_per_hour, digits=1)) " *
            "wall_s=$(round(Int, time() - t0))")
end
println("TECH44_DONE")
