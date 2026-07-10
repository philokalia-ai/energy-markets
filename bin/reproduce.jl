# bin/reproduce.jl — one-command reproduction of the Euphemia competitive
# counterfactual against the published, self-contained DuckDB extract. Runs
# fully OFFLINE (no Postgres): it clears the market from the extract, saves the
# prices to a local results DuckDB, then scores them against the extract's own
# ENTSO-E day-ahead actuals with the resolution-aware methodology, and writes a
# markdown + CSV report under results/.
#
# Tiers:
#   --quick                  GR single-zone + 39-zone EU multi-zone, 2026-04-01..05
#   --range START END        multi-zone EU clear over [START,END]
#         [--zones A,B,...]   (restrict the footprint; default all 39)
#         [--single Z]        also single-zone-clear zone Z over the window
#   --full                   the 3.5-year GR single-zone backfill + monthly-sampled
#                            EU multi-zone weeks (~hours; the full 3.5y × 39 zones
#                            is ~24h — available but not the default)
#
# Common options:
#   --optimizer highs|gurobi   default highs (no license needed; Gurobi optional)
#   --order-method merit_order (default; the counterfactual path)
#
# Backend: uses the DuckDB extract auto-detected by the module, or set
#   EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_PATH=/path/to/extract.duckdb
# Results persist to data/results.duckdb (override EUPHEMIA_RESULTS_DB).

using Euphemia
using Dates
using Printf
using Statistics

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR",
    "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL",
    "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
    "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH",
]

include(joinpath(@__DIR__, "..", "test", "scripts", "eu_eval_metrics.jl"))

# --------------------------------------------------------------------------
# Backend resolution: make sure we are on a DuckDB extract if one is available,
# so the run is genuinely offline. Explicit env is respected by the module.
# --------------------------------------------------------------------------
function ensure_duckdb_backend()
    Euphemia.DATA_STORE[] == :duckdb && return true
    candidates = String[]
    p = get(ENV, "EUPHEMIA_DUCKDB_PATH", ""); !isempty(p) && push!(candidates, p)
    push!(candidates, "data/extracts/euphemia-public.duckdb")
    push!(candidates, "data/public/euphemia-public.duckdb")
    for c in candidates
        if isfile(c)
            Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=c)
            return true
        end
    end
    @warn "No DuckDB extract found — running on the current backend (Postgres). " *
          "For an offline reproduction, download the extract (see docs/reproducibility.md)."
    return false
end

# --------------------------------------------------------------------------
# Clearing helpers
# --------------------------------------------------------------------------
daterange(sd::Date, ed::Date) = sd:Day(1):ed

function clear_single_zone(zone::String, days; order_method::Symbol, optimizer::String)
    println("\n▶ Single-zone $zone: $(first(days)) .. $(last(days))  ($(length(days)) days)")
    ok = 0
    for d in days
        try
            generate_energy_prices(zone, d; order_method=order_method, optimizer=optimizer,
                                   save_to_db=true)
            ok += 1
        catch e
            @warn "single-zone clear failed" zone=zone day=d error=e
        end
        print("."); flush(stdout)
    end
    println("  [$ok/$(length(days)) days]")
end

function clear_multi_zone(zones::Vector{String}, days; order_method::Symbol, optimizer::String)
    println("\n▶ Multi-zone EU ($(length(zones)) zones): $(first(days)) .. $(last(days))  ($(length(days)) days)")
    ok = 0
    for d in days
        try
            run_multi_zone_market_clearing(d; zones=zones, order_method=order_method,
                optimizer=optimizer, enrich_network=true, passes=2,
                clearing_mode="multi_zone", save_to_db=true, silent=true)
            ok += 1
        catch e
            @warn "multi-zone clear failed" day=d error=e
        end
        print("."); flush(stdout)
    end
    println("  [$ok/$(length(days)) days]")
end

# Monthly-sampled representative weeks (one 7-day week per month) across a window.
function sampled_weeks(sd::Date, ed::Date)
    days = Date[]
    m = firstdayofmonth(sd)
    while m <= ed
        wk_start = max(m, sd)
        for k in 0:6
            d = wk_start + Day(k)
            d <= ed && push!(days, d)
        end
        m += Month(1)
    end
    return days
end

# --------------------------------------------------------------------------
# Metrics + reporting
# --------------------------------------------------------------------------
function score_and_report(sections, tier::String)
    mkpath("results")
    report = joinpath("results", "$(tier)_report.md")
    csv = joinpath("results", "$(tier)_metrics.csv")
    open(report, "w") do io
        println(io, "# Euphemia reproduction report — `$tier`")
        println(io)
        println(io, "- generated: ", now(UTC), " UTC")
        println(io, "- backend: ", Euphemia.DATA_STORE[] == :duckdb ?
                "DuckDB extract (offline)" : "PostgreSQL")
        println(io, "- code_version: ", Euphemia.ENERGY_PRICES_CODE_VERSION)
        println(io, "- methodology: resolution-aware actuals; bias = sim − actual (€/MWh)")
        println(io)
        open(csv, "w") do cio
            println(cio, "section,clearing_mode,zone,n,corr,mae,bias,sim_mean,act_mean")
            for (label, cm, sd, ed, zones) in sections
                rows = metrics(cm, Euphemia.ENERGY_PRICES_CODE_VERSION, sd, ed; zones=zones)
                println(io, "## $label")
                println(io)
                if isempty(rows)
                    println(io, "_no scored rows (no overlapping actuals)_\n")
                    continue
                end
                println(io, "| zone | n | corr | MAE | bias | sim μ | act μ |")
                println(io, "|------|---:|-----:|----:|-----:|------:|------:|")
                for r in sort(rows, by=x -> x.z)
                    @printf(io, "| %s | %d | %.3f | %.2f | %+.2f | %.2f | %.2f |\n",
                            r.z, r.n, r.corr, r.mae, r.bias, r.simμ, r.actμ)
                    @printf(cio, "%s,%s,%s,%d,%.4f,%.4f,%.4f,%.4f,%.4f\n",
                            label, cm, r.z, r.n, r.corr, r.mae, r.bias, r.simμ, r.actμ)
                end
                maes = [r.mae for r in rows]; corrs = [r.corr for r in rows if !isnan(r.corr)]
                biases = [r.bias for r in rows]
                @printf(io, "\n**Summary (%d zones): mean MAE %.2f, mean corr %.3f, mean bias %+.2f**\n\n",
                        length(rows), mean(maes), isempty(corrs) ? NaN : mean(corrs), mean(biases))
            end
        end
    end
    println("\n📄 Wrote $report and $csv")

    # For --quick, diff against the committed reference if present.
    if tier == "quick"
        ref = joinpath("results", "reference", "quick_metrics.csv")
        if isfile(ref)
            println("\n🔎 Diff vs committed reference ($ref):")
            compare_to_reference(csv, ref)
        else
            println("\n(no committed reference at $ref — this run can seed it)")
        end
    end
    return csv
end

# Compare per-(section,zone) MAE/bias/corr to a reference CSV; flag drift.
function compare_to_reference(csv::String, ref::String)
    parse_rows(path) = begin
        d = Dict{Tuple{String,String},NTuple{3,Float64}}()
        for (i, ln) in enumerate(eachline(path))
            i == 1 && continue
            f = split(ln, ",")
            length(f) >= 7 || continue
            d[(f[1], f[3])] = (parse(Float64, f[5]), parse(Float64, f[6]), parse(Float64, f[7]))
        end
        d
    end
    cur = parse_rows(csv); rf = parse_rows(ref)
    maxdrift = 0.0
    for (k, (corr, mae, bias)) in cur
        haskey(rf, k) || continue
        rc, rm, rb = rf[k]
        dmae = abs(mae - rm); dbias = abs(bias - rb)
        maxdrift = max(maxdrift, dmae, dbias)
        if dmae > 0.5 || dbias > 0.5
            @printf("  DRIFT %-24s MAE %.2f→%.2f  bias %+.2f→%+.2f\n", string(k), rm, mae, rb, bias)
        end
    end
    @printf("  max |Δ MAE|,|Δ bias| vs reference: %.4f €/MWh %s\n",
            maxdrift, maxdrift < 0.5 ? "✅ within tolerance" : "⚠️ review")
end

# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
function parse_args(argv)
    opts = Dict{String,Any}("tier" => nothing, "optimizer" => "highs",
        "order_method" => :merit_order, "zones" => FOOTPRINT, "single" => nothing,
        "start" => nothing, "stop" => nothing)
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--quick"; opts["tier"] = "quick"
        elseif a == "--full"; opts["tier"] = "full"
        elseif a == "--range"
            opts["tier"] = "range"
            opts["start"] = Date(argv[i+1]); opts["stop"] = Date(argv[i+2]); i += 2
        elseif a == "--zones"
            opts["zones"] = String[strip(z) for z in split(argv[i+1], ",") if !isempty(strip(z))]; i += 1
        elseif a == "--single"; opts["single"] = argv[i+1]; i += 1
        elseif a == "--optimizer"; opts["optimizer"] = argv[i+1]; i += 1
        elseif a == "--order-method"; opts["order_method"] = Symbol(argv[i+1]); i += 1
        else; @warn "ignoring unknown argument: $a"
        end
        i += 1
    end
    return opts
end

function main(argv)
    opts = parse_args(argv)
    tier = opts["tier"]
    tier === nothing && (println("usage: julia --project=. bin/reproduce.jl [--quick | --range S E [--zones ...] [--single Z] | --full] [--optimizer highs|gurobi]"); return 1)
    om = opts["order_method"]; opt = opts["optimizer"]

    offline = ensure_duckdb_backend()
    println("Backend: ", Euphemia.DATA_STORE[], offline ? "  (offline reproduction)" : "")

    t0 = time()
    sections = Any[]
    if tier == "quick"
        sd, ed = Date(2026, 4, 1), Date(2026, 4, 5)
        clear_single_zone("GR", daterange(sd, ed); order_method=om, optimizer=opt)
        clear_multi_zone(FOOTPRINT, daterange(sd, ed); order_method=om, optimizer=opt)
        push!(sections, ("GR single-zone $sd..$ed", "single_zone", sd, ed, ["GR"]))
        push!(sections, ("EU 39-zone multi-zone $sd..$ed", "multi_zone", sd, ed, FOOTPRINT))
    elseif tier == "range"
        sd, ed = opts["start"], opts["stop"]
        zs = opts["zones"]
        clear_multi_zone(zs, daterange(sd, ed); order_method=om, optimizer=opt)
        push!(sections, ("EU multi-zone $sd..$ed", "multi_zone", sd, ed, zs))
        if opts["single"] !== nothing
            z = opts["single"]
            clear_single_zone(z, daterange(sd, ed); order_method=om, optimizer=opt)
            push!(sections, ("$z single-zone $sd..$ed", "single_zone", sd, ed, [z]))
        end
    elseif tier == "full"
        sd, ed = Date(2023, 1, 1), Date(2026, 6, 30)
        println("\n⏳ --full: 3.5-year GR single-zone backfill + monthly-sampled EU weeks (hours).")
        clear_single_zone("GR", daterange(sd, ed); order_method=om, optimizer=opt)
        weeks = sampled_weeks(sd, ed)
        clear_multi_zone(FOOTPRINT, weeks; order_method=om, optimizer=opt)
        push!(sections, ("GR single-zone $sd..$ed", "single_zone", sd, ed, ["GR"]))
        push!(sections, ("EU 39-zone multi-zone (monthly-sampled weeks) $sd..$ed", "multi_zone", sd, ed, FOOTPRINT))
    end

    @printf("\nClearing done in %.0f s. Scoring...\n", time() - t0)
    score_and_report(sections, tier)
    @printf("Total %.0f s.\n", time() - t0)
    return 0
end

exit(main(ARGS))
