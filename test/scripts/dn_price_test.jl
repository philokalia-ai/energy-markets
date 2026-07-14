# D-n price test (GR, single-zone :merit_order, offline DuckDB extract).
#
# For ~30 sample days across the OOS test year, clears GR at leads n=1..7 with
# ONLY lead-n-legal inputs:
#   load  — our ridge load model driven by the honest lead-n GFS temperature
#           vintage (gr_load_pred.csv from test/scripts/dn_load_model.jl)
#   RES   — the production weather-RES pack (bin/res_models_v1.json) driven by
#           honest lead-n GFS vintages of v100/GHI at the GR cells
#           (prev_res_cells.csv from test/scripts/dn_load_fetch.py)
#   fuel  — TTF/EUA close of the last trading day ≤ T−n (cache-seeded)
#   flows — EUPHEMIA_FLOW_ASOF_MODE=clim (8-week same-weekday median, inputs
#           D-7..D-56; note: at lead 7 the D-7 draw is the freeze day itself —
#           its flows are ~complete at the evening freeze, stated in README)
#
# Benchmarks per day:
#   ref_d1      — the production-style D-1 reference clear (ENTSO-E D-1 load +
#                 ENTSO-E RES forecast, same clim flows, TTF ≤ T−1)
#   persist_p7  — actual DA price at T−7, same hour (price persistence; legal
#                 at every lead 1..7 since T−7's auction clears on T−8)
#
# Run:
#   julia --project=. test/scripts/dn_price_test.jl
# Env: DN_OUT (scratch dir), DN_LEADS (default "1,2,3,4,5,6,7"), DN_STEP (12)

ENV["EUPHEMIA_FLOW_ASOF_MODE"] = get(ENV, "EUPHEMIA_FLOW_ASOF_MODE", "clim")

using Euphemia, CSV, DataFrames, Dates, Statistics, Printf

# read-only so a concurrently-open extract (another session's process) is fine
Euphemia.configure_data_store!(backend=:duckdb, read_only=true,
    duckdb_path=get(ENV, "EUPHEMIA_DUCKDB_PATH",
        joinpath(@__DIR__, "..", "..", "data", "extracts", "euphemia-live.duckdb")))

include(joinpath(@__DIR__, "..", "..", "bin", "weather_res.jl"))  # pure helpers (guarded main)

const SP = get(ENV, "DN_OUT",
    "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/dn")
const LEADS = [parse(Int, s) for s in split(get(ENV, "DN_LEADS", "1,2,3,4,5,6,7"), ",")]
const STEP = parse(Int, get(ENV, "DN_STEP", "12"))
const T0, T1 = Date(2025, 7, 8), Date(2026, 6, 30)

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
"lead → (hour → load MW) from the load-model script."
function load_predictions()
    df = CSV.read(joinpath(SP, "gr_load_pred.csv"), DataFrame)
    out = Dict{Int,Dict{DateTime,Float64}}()
    for r in eachrow(df)
        h = r.h isa DateTime ? r.h : DateTime(String(r.h))
        push!(get!(out, Int(r.lead), Dict{DateTime,Float64}()), h => Float64(r.load_mw))
    end
    return out
end

"lead → (hour → (wind MW, solar MW)) via the production RES pack on lead-n vintages."
function res_predictions()
    pack = load_res_models()
    zm = pack["zones"]["GR"]
    ncells = length(zm["cells"])
    wind_model, solar_model = get(zm, "wind", nothing), get(zm, "solar", nothing)
    df = CSV.read(joinpath(SP, "prev_res_cells.csv"), DataFrame)
    # (lead, hour) → per-cell v100 / ghi
    v = Dict{Tuple{Int,DateTime},Vector{Union{Missing,Float64}}}()
    g = Dict{Tuple{Int,DateTime},Vector{Union{Missing,Float64}}}()
    for r in eachrow(df)
        h = r.h isa DateTime ? r.h : DateTime(String(r.h))
        ci = Int(r.cell_idx) + 1
        for n in LEADS
            wv = r[Symbol("wind_speed_100m_previous_day$n")]
            gv = r[Symbol("shortwave_radiation_previous_day$n")]
            vv = get!(v, (n, h), Vector{Union{Missing,Float64}}(missing, ncells))
            gg = get!(g, (n, h), Vector{Union{Missing,Float64}}(missing, ncells))
            wv !== missing && (vv[ci] = Float64(wv))
            gv !== missing && (gg[ci] = Float64(gv))
        end
    end
    out = Dict{Int,Dict{DateTime,Tuple{Float64,Float64}}}()
    for ((n, h), vv) in v
        gg = g[(n, h)]
        (any(ismissing, vv) || any(ismissing, gg)) && continue
        w = wind_model === nothing ? 0.0 : predict_wind_hour(wind_model, Float64.(vv))
        s = solar_model === nothing ? 0.0 : predict_solar_hour(solar_model, mean(Float64.(gg)), h)
        push!(get!(out, n, Dict{DateTime,Tuple{Float64,Float64}}()), h => (w, s))
    end
    return out
end

"hour → actual (wind, solar) MW from the psql per-type extract (gr_actual_res.csv)."
function actual_res()
    df = CSV.read(joinpath(SP, "gr_actual_res.csv"), DataFrame)
    wind = Dict{DateTime,Float64}()
    solar = Dict{DateTime,Float64}()
    for r in eachrow(df)
        h = r.h isa DateTime ? r.h : DateTime(String(r.h))
        if String(r.pt) == "Solar"
            solar[h] = Float64(r.mw)
        else
            wind[h] = get(wind, h, 0.0) + Float64(r.mw)   # Onshore + Offshore
        end
    end
    return wind, solar
end

"""
Lead-legal recency calibration of the RES level. The ERA5-trained pack under a
GFS-vintage feed has a systematic level bias (measured ≈ −20 % wind+solar on
the sample days). For day T at lead n, wind and solar are scaled separately by
k = Σactual/Σpredicted over the trailing `window` days ending T−n−1, computed
on the SAME lead-n vintage series — per-type actual generation publishes
near-real-time, so every input predates the freeze. Clamped to [0.5, 2].
"""
function res_calibration(rpn::Dict{DateTime,Tuple{Float64,Float64}},
                         wind_act::Dict{DateTime,Float64},
                         solar_act::Dict{DateTime,Float64},
                         day::Date, lead::Int; window::Int=42)
    t1 = DateTime(day - Day(lead + 1)) + Hour(23)
    t0 = DateTime(day - Day(lead + window))
    pw = ps = aw = as = 0.0
    nh = 0
    for (h, (w, s)) in rpn
        (t0 <= h <= t1 && haskey(wind_act, h) && haskey(solar_act, h)) || continue
        pw += w; ps += s; aw += wind_act[h]; as += solar_act[h]; nh += 1
    end
    nh < 200 && return (1.0, 1.0)
    kw = pw > 0 ? clamp(aw / pw, 0.5, 2.0) : 1.0
    ks = ps > 0 ? clamp(as / ps, 0.5, 2.0) : 1.0
    return (kw, ks)
end

"trading-day closes: Date → close (from the extract's yfinance tables)."
function closes(table::String)
    df = Euphemia.sql2df("SELECT date, close FROM $table ORDER BY date")
    return [(Date(r.date), Float64(r.close)) for r in eachrow(df) if !ismissing(r.close)]
end
"last close at or before `d` within 10 days, else nothing."
function close_asof(cl, d::Date)
    best = nothing
    for (cd, c) in cl
        cd > d && break
        cd >= d - Day(10) && (best = c)
    end
    return best
end

function actual_prices(day::Date)
    df = Euphemia.sql2df("""
        WITH d AS (SELECT DISTINCT ON (date_time_utc) date_time_utc, price_currency_mwh p
          FROM entsoe.energy_prices
          WHERE map_code='GR' AND contract_type='Day-ahead' AND area_type_code LIKE 'BZN%'
            AND date_time_utc >= \$1::date AND date_time_utc < \$1::date + 1
          ORDER BY date_time_utc, TRY_CAST(trim(sequence) AS INT) DESC NULLS LAST)
        SELECT date_trunc('hour', date_time_utc) hh, AVG(p) p
        FROM d GROUP BY 1 ORDER BY 1""", [string(day)])
    return Dict(Dates.format(DateTime(r.hh), "yyyymmdd-HHMM") => Float64(r.p)
                for r in eachrow(df))
end

hourkey(ts::String) = ts[1:9] * ts[10:11] * "00"
hourly(prices) = begin
    acc = Dict{String,Vector{Float64}}()
    for (ts, p) in prices
        push!(get!(acc, hourkey(ts), Float64[]), p)
    end
    Dict(k => mean(v) for (k, v) in acc)
end
c2(x, y) = (std(x) == 0 || std(y) == 0) ? NaN : cor(x, y)

"Seed the TTF/EUA caches with the value legal at freeze date T−n."
function seed_fuel!(day::Date, lead::Int, ttf, eua)
    Euphemia.clear_generator_caches!()
    empty!(Euphemia.TTF_PRICE_CACHE)
    empty!(Euphemia.EUA_PRICE_CACHE)
    Euphemia.TTF_PRICE_CACHE[day] = close_asof(ttf, day - Day(lead))
    Euphemia.EUA_PRICE_CACHE[day] = close_asof(eua, day - Day(lead))
end

const CALIBRATE = lowercase(get(ENV, "DN_CALIBRATE", "true")) == "true"
# Diagnostic: substitute ONLY the load (keep ENTSO-E RES) — isolates the load
# model's price cost. Only meaningful at lead 1 (ENTSO-E RES needs D-1).
const LOAD_ONLY = lowercase(get(ENV, "DN_LOAD_ONLY", "false")) == "true"
# Variant: RES from PERSISTENCE of actual per-type generation (same hour of the
# freshest fully-realized day P = T−n−1) instead of the weather pack — fully
# lead-legal and pack-free. Load still from our model at lead n.
const RES_PERS = lowercase(get(ENV, "DN_RES_PERS", "false")) == "true"
# Benchmark: FORECAST persistence — the product's current leads-2..7 fill
# (bin/horizon_forecast.jl): the lead-1 model clear of P = T−7, hours
# relabeled +7 d. Emulated here as the single-zone ref clear of T−7.
const FC_PERSIST = lowercase(get(ENV, "DN_FC_PERSIST", "false")) == "true"

function main()
    println("D-n PRICE TEST — GR single-zone :merit_order, flows=:$(ENV["EUPHEMIA_FLOW_ASOF_MODE"]), " *
            "res_calibration=$CALIBRATE")
    lp = load_predictions()
    rp = res_predictions()
    wind_act, solar_act = actual_res()
    ttf, eua = closes("yfinance.ttf_f"), closes("yfinance.eua_co2")
    days = collect(T0:Day(STEP):T1)
    println("$(length(days)) candidate days, leads $(LEADS)")

    rows = DataFrame(day=Date[], config=String[], n=Int[], corr=Float64[],
                     mae=Float64[], bias=Float64[])
    pooled = Dict{String,Tuple{Vector{Float64},Vector{Float64}}}()  # config → (pred, act)
    getpool(c) = get!(pooled, c, (Float64[], Float64[]))

    for day in days
        act = actual_prices(day)
        length(act) >= 20 || (println("$day: only $(length(act)) actual hours — skipped"); continue)
        ks = sort(collect(keys(act)))
        a = [act[k] for k in ks]

        score!(cfg, ph) = begin
            kk = [k for k in ks if haskey(ph, k)]
            length(kk) == length(ks) || return false
            p = [ph[k] for k in kk]
            push!(rows, (day, cfg, length(kk), c2(p, a), mean(abs.(p .- a)), mean(p .- a)))
            append!(getpool(cfg)[1], p); append!(getpool(cfg)[2], a)
            true
        end

        # reference D-1 clear (ENTSO-E load + RES, fuel legal at lead 1)
        seed_fuel!(day, 1, ttf, eua)
        ref = try
            hourly(generate_energy_prices("GR", day; order_method=:merit_order, save_to_db=false))
        catch e
            println("$day ref_d1 FAILED: $e"); nothing
        end
        ref !== nothing && score!("ref_d1", ref)

        # forecast persistence: the lead-1 clear of T−7 relabeled +7 d (the
        # product's current leads-2..7 fill, single-zone emulation)
        if FC_PERSIST
            P = day - Day(7)
            seed_fuel!(P, 1, ttf, eua)
            fp = try
                hourly(generate_energy_prices("GR", P; order_method=:merit_order, save_to_db=false))
            catch e
                println("$day fc_persist ($P) FAILED: $e"); nothing
            end
            if fp !== nothing
                shifted = Dict(Dates.format(DateTime(k, dateformat"yyyymmdd-HHMM") + Day(7),
                                            "yyyymmdd-HHMM") => v for (k, v) in fp)
                score!("fc_persist", shifted)
            end
        end

        for n in LEADS
            lpn, rpn = get(lp, n, nothing), get(rp, n, nothing)
            (lpn === nothing || rpn === nothing) && continue
            hours = [DateTime(day) + Hour(h) for h in 0:23]
            all(h -> haskey(lpn, h) && haskey(rpn, h), hours) ||
                (println("$day lead $n: incomplete load/RES vintages — skipped"); continue)
            loadmod = (ts, mw) -> lpn[trunc(DateTime(ts, dateformat"yyyymmdd-HHMM"), Hour)]
            resmod = nothing
            cfg = "model_lead$n"
            if LOAD_ONLY
                cfg = "loadonly_lead$n"
            elseif RES_PERS
                cfg = "respers_lead$n"
                P = day - Day(n + 1)   # freshest fully-realized day at the freeze
                shift = Day(n + 1)
                all(h -> haskey(wind_act, h - shift) && haskey(solar_act, h - shift), hours) ||
                    (println("$day lead $n: incomplete actual RES at $P — skipped"); continue)
                resmod = (ts, mw) -> begin
                    hp = trunc(DateTime(ts, dateformat"yyyymmdd-HHMM"), Hour) - shift
                    wind_act[hp] + solar_act[hp]
                end
            else
                kcal_w, kcal_s = CALIBRATE ?
                    res_calibration(rpn, wind_act, solar_act, day, n) : (1.0, 1.0)
                resmod = (ts, mw) -> begin
                    w, s = rpn[trunc(DateTime(ts, dateformat"yyyymmdd-HHMM"), Hour)]
                    kcal_w * w + kcal_s * s
                end
            end
            seed_fuel!(day, n, ttf, eua)
            sim = try
                hourly(generate_energy_prices("GR", day; order_method=:merit_order,
                    save_to_db=false, load_modifier=loadmod,
                    renewable_modifier=resmod))
            catch e
                println("$day lead $n FAILED: $e"); continue
            end
            score!(cfg, sim)
        end
        println("$day done")
    end

    # price persistence T−7 (hour-aligned relabel; legal at every lead ≤ 7)
    for day in days
        act = actual_prices(day)
        length(act) >= 20 || continue
        prev = actual_prices(day - Day(7))
        ph = Dict{String,Float64}()
        for (k, v) in prev
            ph[Dates.format(DateTime(k, dateformat"yyyymmdd-HHMM") + Day(7), "yyyymmdd-HHMM")] = v
        end
        ks = sort(collect(keys(act)))
        kk = [k for k in ks if haskey(ph, k)]
        length(kk) == length(ks) || continue
        p = [ph[k] for k in kk]; a = [act[k] for k in kk]
        push!(rows, (day, "persist_p7", length(kk), c2(p, a), mean(abs.(p .- a)), mean(p .- a)))
        pl = getpool("persist_p7"); append!(pl[1], p); append!(pl[2], a)
    end

    CSV.write(joinpath(SP, FC_PERSIST ? "price_metrics_fcpersist.csv" :
                           LOAD_ONLY ? "price_metrics_loadonly.csv" :
                           RES_PERS ? "price_metrics_respers.csv" :
                           CALIBRATE ? "price_metrics_cal.csv" : "price_metrics.csv"), rows)
    println("\n=== POOLED (hours) ===")
    for cfg in sort(collect(keys(pooled)))
        p, a = pooled[cfg]
        @printf("%-14s n=%5d  corr=%.3f  MAE=%6.2f  bias=%+6.2f\n",
                cfg, length(a), c2(p, a), mean(abs.(p .- a)), mean(p .- a))
    end
    println("\n=== MEAN OF DAILY METRICS ===")
    for cfg in sort(unique(rows.config))
        sub = rows[rows.config .== cfg, :]
        good = sub[.!isnan.(sub.corr), :]
        @printf("%-14s days=%2d  corr=%.3f  MAE=%6.2f  |  days with corr>persist: %d\n",
                cfg, nrow(sub), mean(good.corr), mean(sub.mae),
                count(d -> begin
                    pc = rows[(rows.day .== d) .& (rows.config .== "persist_p7"), :corr]
                    mc = rows[(rows.day .== d) .& (rows.config .== cfg), :corr]
                    !isempty(pc) && !isempty(mc) && !isnan(mc[1]) && mc[1] > pc[1]
                end, unique(sub.day)))
    end
end

main()
