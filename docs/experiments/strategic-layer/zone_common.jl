# Phase B shared harness — the GR strategic-bidding protocol, zone-parameterized.
#
# Differences from the GR original (docs/experiments/gr-strategic-bidding/):
#  * ZONE comes from ENV["SL_ZONE"]; day sets from days_<ZONE>.json /
#    heldout_<ZONE>.json in this directory (built by select_days.py from the
#    cv17 coupled baseline `eu17_base`).
#  * Clearing uses run_multi_zone_market_clearing(zones=[ZONE],
#    enrich_network=true, apply_zone_profiles=true, passes=2) so the zone gets
#    its OWN calibrated ZoneProfile (the single-zone legacy path forces
#    SEE_PROFILE — wrong for DE_LU/FR). All borders are non-endogenous ex-ante
#    injections; the paired design cancels level miscalibration.
#  * firm_of comes from the committed wave-1 CSVs
#    (docs/experiments/firm-maps/unit_firms_<ZONE>.csv) merged over ctx.firm_of
#    — the offline extract does not yet carry the wave-1 rows.
#
# Eval, summarize, additive null: identical discipline to the GR experiment
# (hour-averaged pairing, paired ΔMAE, post-hoc additive level-shift null).

const EM = abspath(joinpath(homedir(), "armada", "energy-markets"))
const EXTRACT = joinpath(EM, "data", "extracts", "euphemia-live.duckdb")
ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "v2")
ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
ENV["EUPHEMIA_DUCKDB_PATH"] = EXTRACT
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"

using Euphemia, Dates, JSON, Statistics, Printf, DataFrames, CSV

configure_data_store!(backend=:duckdb, duckdb_path=EXTRACT, read_only=true,
    results_writable=false)

const ZONE = get(ENV, "SL_ZONE", "DE_LU")

# --- firm map: committed wave-1 CSV (fallback: whatever the extract has) -----
const FIRM_OF = let
    path = joinpath(EM, "docs", "experiments", "firm-maps", "unit_firms_$(ZONE).csv")
    d = Dict{String,String}()
    if isfile(path)
        for r in CSV.File(path)
            d[String(r.unit_code)] = String(r.firm)
        end
    end
    d
end
@info "firm map for $ZONE: $(length(FIRM_OF)) units (wave-1 CSV)"

merged_firm_of(ctx) = isempty(FIRM_OF) ? ctx.firm_of : merge(ctx.firm_of, FIRM_OF)

is_supply(o) = o.type == :supply
ts_of(o) = Dates.format(o.date_time, "yyyymmdd-HHMM")
bump(o, f) = SimpleOrder(o.type, o.price * f, o.quantity, o.zone, o.date_time, o.resolution_code)

# --- day sets ----------------------------------------------------------------
load_days(name) = [Date(d) for d in JSON.parsefile(joinpath(@__DIR__, "$(name)_$(ZONE).json"))]
const DAYS = isfile(joinpath(@__DIR__, "days_$(ZONE).json")) ? load_days("days") : Date[]
const HELDOUT = isfile(joinpath(@__DIR__, "heldout_$(ZONE).json")) ? load_days("heldout") : Date[]

# --- settled actuals ---------------------------------------------------------
function load_actuals()
    df = Euphemia.sql2df("""
        SELECT strftime(date_trunc('hour', date_time_utc), '%Y%m%d-%H00') AS ts,
               AVG(price_currency_mwh) AS p
        FROM entsoe.energy_prices
        WHERE map_code='$(ZONE)' AND contract_type='Day-ahead'
        GROUP BY 1""")
    Dict{String,Float64}(String(r.ts) => Float64(r.p) for r in eachrow(df))
end
const ACTUALS = load_actuals()

# --- clear one day with the zone's own profile ------------------------------
# The enriched network build requires ≥1 in-footprint border, so the footprint
# is the target zone plus ONE partner with a kept (non-flow-based-dropped)
# border; every other border is an ex-ante injection. Only the target zone is
# evaluated; the strategist applies only to the target zone.
# Partners must share a border with offered (implicit) ATC — the Core-FBMC
# borders have none, so DE_LU pairs with DK1 (NTC DC link), FR with ES.
const PARTNER = Dict("DE_LU" => "DK1", "FR" => "ES", "ES" => "FR", "HU" => "RS",
                     "IT-CSOUTH" => "IT-SOUTH", "IT-NORTH" => "IT-CNORTH")
function clear_day(day::Date; strategist=nothing)
    scn = strategist === nothing ? nothing :
          Dict(ZONE => ZoneScenario(strategist=strategist))
    zones = [ZONE, get(PARTNER, ZONE, "NL")]
    r = run_multi_zone_market_clearing(day; zones=zones,
        order_method=:merit_order, enrich_network=true, apply_zone_profiles=true,
        passes=2, optimizer="highs", save_to_db=false, scenario=scn)
    get(r.market_prices, ZONE, Dict{String,Float64}())
end

const _BASELINE = Dict{Date,Dict{String,Float64}}()
get_baseline(day::Date) = get!(_BASELINE, day) do
    clear_day(day)
end

# --- evaluation (hour-averaged pairing, identical to the GR corrected eval) --
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

function run_matrix(configs::Vector; days=DAYS, verbose=true)
    acc = Dict(name => NamedTuple[] for (name, _) in configs)
    for (i, day) in enumerate(days)
        try
            get_baseline(day)
        catch e
            verbose && @warn "baseline failed, skipping day" day e
            continue
        end
        for (name, factory) in configs
            strat = name == "baseline" ? nothing : factory(day)
            sim = name == "baseline" ? _BASELINE[day] : try
                clear_day(day; strategist=strat)
            catch e
                verbose && @warn "clear failed" name day e
                continue
            end
            c, m, r, n = eval_vs_actual(sim, day)
            push!(acc[name], (day=day, corr=c, mae=m, resid=r, n=n))
        end
        verbose && @printf("  [%2d/%2d] %s done\n", i, length(days), day)
        flush(stdout)
    end
    acc
end

mean_skip(xs) = (v = collect(skipmissing(xs)); isempty(v) ? missing : mean(v))

function summarize(acc::Dict; base_name="baseline")
    base = acc[base_name]
    bmae = Dict(r.day => r.mae for r in base)
    rows = NamedTuple[]
    for (name, rs) in acc
        corr = mean_skip(r.corr for r in rs)
        mae = mean_skip(r.mae for r in rs)
        absres = mean_skip(abs(r.resid) for r in rs if r.resid !== missing)
        res = mean_skip(r.resid for r in rs)
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

# --- additive level-shift null ----------------------------------------------
function additive_null(days)
    pairs = Dict{Date,Tuple{Vector{Float64},Vector{Float64}}}()
    for day in days
        haskey(_BASELINE, day) || continue
        sim = _BASELINE[day]
        hsum = Dict{String,Float64}(); hn = Dict{String,Int}()
        for (ts, sp) in sim
            hk = ts[1:9] * ts[10:11] * "00"
            hsum[hk] = get(hsum, hk, 0.0) + sp; hn[hk] = get(hn, hk, 0) + 1
        end
        a = Float64[]; s = Float64[]
        for (hk, tot) in hsum
            ap = get(ACTUALS, hk, nothing); ap === nothing && continue
            push!(a, ap); push!(s, tot / hn[hk])
        end
        length(a) >= 12 && (pairs[day] = (a, s))
    end
    isempty(pairs) && return nothing
    best = (Inf, 0.0)
    for c in -15.0:0.25:25.0
        m = mean(mean(abs.(a .- (s .+ c))) for (a, s) in values(pairs))
        m < best[1] && (best = (m, c))
    end
    mae, cshift = best
    resid = mean(mean(a .- (s .+ cshift)) for (a, s) in values(pairs))
    (mae=mae, shift=cshift, resid=resid, n=length(pairs))
end

# --- the winning GR mechanism, per-firm --------------------------------------
# near-uniform markup on committed units' dispatchable range (min-price anchor)
function firm_nearuniform(firms::Set{String}; markup::Float64=0.25, slice_from::Float64=1.10)
    (_day::Date) -> (ctx -> begin
        fo = merged_firm_of(ctx)
        minp = Dict{Tuple{String,String},Float64}()
        for (o, tag) in ctx.tagged_orders
            (is_supply(o) && get(fo, tag, "") in firms) || continue
            k = (tag, ts_of(o)); minp[k] = min(get(minp, k, Inf), o.price)
        end
        out = Tuple{SimpleOrder,String}[]
        for (o, tag) in ctx.tagged_orders
            if is_supply(o) && get(fo, tag, "") in firms
                base = get(minp, (tag, ts_of(o)), o.price)
                push!(out, (o.price > slice_from * base ? bump(o, 1 + markup) : o, tag))
            else
                push!(out, (o, tag))
            end
        end
        out
    end)
end

dump_tsv(path, rows) = open(path, "w") do io
    println(io, "strategy\tcorr\tmae\tabsresid\tresid\tmae_gain\tdays_better\tn")
    for r in rows
        g(x) = x === missing ? "" : @sprintf("%.4f", x)
        println(io, join([r.name, g(r.corr), g(r.mae), g(r.absresid), g(r.resid),
            g(r.mae_gain), string(r.days_better), string(r.n)], "\t"))
    end
end
