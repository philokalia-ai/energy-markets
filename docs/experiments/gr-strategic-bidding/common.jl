# Shared harness for the GR strategic-bidding experiment.
#
# Hypothesis. On medium-correlation GR days the settled price sits ABOVE the
# competitive counterfactual (measured: +12 €/MWh median over the 60-day set).
# If that residual is *strategic bidding* by the big incumbent(s) — who can see
# the competitive price and know they are pivotal — then letting the model's big
# firms bid a market-power strategy should move the SIMULATED price UP toward the
# settled price, shrinking MAE / |residual| WITHOUT wrecking the shape (corr).
# A strategy "works" here iff, paired per day vs the same-day competitive
# baseline, it lowers mean |residual| and MAE against ACTUAL prices while holding
# correlation. If none does, the residual is not simple portfolio markup.
#
# Everything runs offline on the DuckDB extract (fast, no Postgres). Each of the
# 60 days is built ONCE (the expensive part — generators/outages/TTF are then
# memoized per day), after which every strategy re-clears that day cheaply, so a
# whole matrix of strategies × params is one warm pass.
#
# Third parties: each strategy lives in its own strat_*.jl and exposes ONE
# factory `name(; params...) -> (day::Date -> strategist_closure)`. Drop a new
# file next to these, add it to STRATEGY CONFIGS in run_all.jl, done.

const EM = abspath(joinpath(homedir(), "armada", "energy-markets"))
const EXTRACT = joinpath(EM, "data", "extracts", "euphemia-live.duckdb")
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
ENV["EUPHEMIA_DUCKDB_PATH"] = EXTRACT
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"

using Euphemia, Dates, JSON, Statistics, Printf, DataFrames

configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT, read_only=true,
    results_writable=false)

# --- big firms (the "players") ---------------------------------------------
# PPC (ΔΕΗ) alone is ~69% of the mapped GR registry (10.4 of 15.1 GW); adding
# the next private thermals approaches the ~80% ceiling. Override with
# EUPHEMIA_BIG_FIRMS="PPC,Mytilineos,Elpedison".
const BIG_FIRMS = Set(split(get(ENV, "EUPHEMIA_BIG_FIRMS", "PPC"), ","))

is_supply(o) = o.type == :supply
ts_of(o) = Dates.format(o.date_time, "yyyymmdd-HHMM")
is_big(firm_of::Dict, tag::String) = get(firm_of, tag, "") in BIG_FIRMS
bump(o, factor) = SimpleOrder(o.type, o.price * factor, o.quantity, o.zone,
    o.date_time, o.resolution_code)
setprice(o, p) = SimpleOrder(o.type, p, o.quantity, o.zone, o.date_time, o.resolution_code)
setqty(o, q) = SimpleOrder(o.type, o.price, q, o.zone, o.date_time, o.resolution_code)

# --- the 60 medium-correlation days ----------------------------------------
const DAYS = [Date(d) for d in JSON.parsefile(joinpath(@__DIR__, "days.json"))]

# --- settled actuals, hourly, keyed "yyyymmdd-HH00" ------------------------
# via Euphemia.sql2df (dispatches to the same read-only DuckDB extract).
function load_actuals()
    df = Euphemia.sql2df("""
        SELECT strftime(date_trunc('hour', date_time_utc), '%Y%m%d-%H00') AS ts,
               AVG(price_currency_mwh) AS p
        FROM entsoe.energy_prices
        WHERE map_code='GR' AND contract_type='Day-ahead'
        GROUP BY 1""")
    Dict{String,Float64}(String(r.ts) => Float64(r.p) for r in eachrow(df))
end
const ACTUALS = load_actuals()

# --- clear one GR day, optionally with a strategist ------------------------
function clear_day(day::Date; strategist=nothing)
    generate_energy_prices("GR", day; order_method=:merit_order,
        optimizer="highs", save_to_db=false, silent=true, strategist=strategist)
end

# --- competitive baseline per day (memoized; also the counterfactual the
#     players "see") ---------------------------------------------------------
const _BASELINE = Dict{Date,Dict{String,Float64}}()
function get_baseline(day::Date)
    get!(_BASELINE, day) do
        clear_day(day; strategist=nothing)
    end
end

# --- hourly evaluation of a sim price dict vs settled actuals ---------------
# returns (corr, mae, resid=mean(actual-sim), n)
# The sim is HOUR-AVERAGED first (review finding): post-2025-10 days clear at
# 15-min resolution while ACTUALS are hourly means; comparing 96 quarter-hours
# against 24 duplicated hourly values is an asymmetric metric. Averaging the sim
# onto the same hourly grid makes every day's pairing symmetric.
function eval_vs_actual(sim::Dict{String,Float64}, day::Date)
    hsum = Dict{String,Float64}(); hn = Dict{String,Int}()
    for (ts, sp) in sim
        hkey = ts[1:9] * ts[10:11] * "00"
        hsum[hkey] = get(hsum, hkey, 0.0) + sp
        hn[hkey] = get(hn, hkey, 0) + 1
    end
    a = Float64[]; s = Float64[]
    for (hkey, tot) in hsum
        ap = get(ACTUALS, hkey, nothing)
        ap === nothing && continue
        push!(a, ap); push!(s, tot / hn[hkey])
    end
    n = length(a)
    n < 12 && return (missing, missing, missing, n)
    c = (std(a) > 0 && std(s) > 0) ? cor(a, s) : missing
    (c, mean(abs.(a .- s)), mean(a .- s), n)
end

# --- run a matrix of strategies day-outer (warm caches) --------------------
# configs :: Vector{Pair{String, factory}}, factory(day)->strategist (or nothing)
# returns Dict{name => Vector of per-day (corr,mae,resid,n)}
function run_matrix(configs::Vector; days=DAYS, verbose=true)
    acc = Dict(name => NamedTuple[] for (name, _) in configs)
    for (i, day) in enumerate(days)
        get_baseline(day)                       # warm the per-day caches once
        for (name, factory) in configs
            strat = name == "baseline" ? nothing : factory(day)
            sim = try
                clear_day(day; strategist=strat)
            catch e
                verbose && @warn "clear failed" name day e
                continue
            end
            c, m, r, n = eval_vs_actual(sim, day)
            push!(acc[name], (day=day, corr=c, mae=m, resid=r, n=n))
        end
        verbose && @printf("  [%2d/%2d] %s done\n", i, length(days), day)
    end
    acc
end

# --- aggregate + rank -------------------------------------------------------
mean_skip(xs) = (v = collect(skipmissing(xs)); isempty(v) ? missing : mean(v))

function summarize(acc::Dict; base_name="baseline")
    base = acc[base_name]
    bmae = Dict(r.day => r.mae for r in base)
    bres = Dict(r.day => r.resid for r in base)
    rows = NamedTuple[]
    for (name, rs) in acc
        corr = mean_skip(r.corr for r in rs)
        mae = mean_skip(r.mae for r in rs)
        absres = mean_skip(abs(r.resid) for r in rs if r.resid !== missing)
        res = mean_skip(r.resid for r in rs)
        # paired improvement vs baseline (same days)
        dmae = mean_skip(bmae[r.day] - r.mae for r in rs
                         if haskey(bmae, r.day) && r.mae !== missing && bmae[r.day] !== missing)
        imp = count(r -> haskey(bmae, r.day) && r.mae !== missing &&
                    bmae[r.day] !== missing && r.mae < bmae[r.day] - 1e-6, rs)
        push!(rows, (name=name, corr=corr, mae=mae, absresid=absres, resid=res,
            mae_gain=dmae, days_better=imp, n=length(rs)))
    end
    sort(rows, by=r -> (r.mae_gain === missing ? -Inf : r.mae_gain), rev=true)
end

function print_table(rows)
    @printf("%-26s %6s %7s %8s %7s %8s %6s\n",
        "strategy", "corr", "MAE", "|resid|", "resid", "ΔMAE", "n↑")
    println("-"^78)
    for r in rows
        f(x) = x === missing ? "  -  " : @sprintf("%6.2f", x)
        @printf("%-26s %s %s %s %s %s %4d/%d\n", r.name,
            f(r.corr), f(r.mae), f(r.absresid), f(r.resid), f(r.mae_gain),
            r.days_better, r.n)
    end
end
