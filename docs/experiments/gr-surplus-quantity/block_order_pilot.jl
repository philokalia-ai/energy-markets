# block_order_pilot.jl — GRSQ lever-2 structural alternative: TRUE valley
# block orders in the GR single-zone book, cleared as a per-day MIP (Gurobi),
# measured against the shipped hourly-projection lever (EUPHEMIA_ENABLE_GRSQ_T2).
# Prereg: docs/experiments/gr-surplus-quantity/prereg-2026-08.md ("block-order
# equivalence" amendment — this is the recorded structural alternative).
# Results: docs/experiments/gr-surplus-quantity/block-order-pilot-2026-08.md.
#
# Arms per day (offline extract, fresh in-process book builds):
#   a. settled     — entsoe.energy_prices (GR, Day-ahead), hourly mean
#   b. base        — engine :merit_order clear, all GRSQ switches off
#   c. projection  — engine clear with EUPHEMIA_ENABLE_GRSQ_T2=1 (lever 2)
#   d. block-MIP   — this script's fill-or-kill valley blocks (opt-in, below)
#
# OPT-IN (owner directive 2026-08): arm d — and everything block-related,
# including loading JuMP/Gurobi — runs ONLY when EUPHEMIA_ENABLE_GRSQ_BLOCKS
# is set. Unset ⇒ the script runs arms a–c only. If the block path ever lands
# in src it ships default-OFF behind the same switch and requires
# optimizer="gurobi"; the canonical HiGHS record path is never touched.
#
# Usage:
#   EUPHEMIA_ENABLE_GRSQ_BLOCKS=1 julia --project=. \
#       docs/experiments/gr-surplus-quantity/block_order_pilot.jl
#   Optional: PILOT_OUT=<dir> (CSV outputs; default: a temp dir),
#             PILOT_DAYS=2026-02-23,2026-02-24 (default: the 5 anatomy days).

ENV["EUPHEMIA_DATA_STORE"] = "duckdb"
get!(ENV, "EUPHEMIA_DUCKDB_PATH",
     "/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb")
ENV["EUPHEMIA_DUCKDB_READONLY"] = "true"
delete!(ENV, "EUPHEMIA_ENABLE_GRSQ_T2")   # arms b/d build with the lever OFF

using Euphemia, Dates, DataFrames, Statistics, CSV, Printf

const BLOCKS_ON = !isempty(get(ENV, "EUPHEMIA_ENABLE_GRSQ_BLOCKS", ""))
if BLOCKS_ON
    @eval using JuMP, Gurobi
    @eval const GRB_ENV = Gurobi.Env()      # ONE env, reused for every solve
    include(joinpath(@__DIR__, "block_order_mip.jl"))
else
    println("EUPHEMIA_ENABLE_GRSQ_BLOCKS unset — block-MIP arm disabled; " *
            "running settled/base/projection arms only.")
end

const ZONE = "GR"
const DAYS = [Date(strip(s)) for s in split(get(ENV, "PILOT_DAYS",
    "2026-02-23,2026-02-24,2026-03-29,2026-04-29,2026-05-05"), ",")]
const OUT = get(ENV, "PILOT_OUT", mktempdir(; prefix="grsq_blocks_"))
const FLOOR = Euphemia.MeritOrderBook.DEEP_SURPLUS_FLOOR_EUR   # −20 €/MWh
const SEED = 42
mkpath(OUT)

# ── data helpers ──────────────────────────────────────────────────────────

"Settled Day-ahead prices from the extract, hour-of-day → mean €/MWh."
function settled_hourly(zone, day)
    df = Euphemia.sql2df_with_retry("""
        SELECT to_char(date_time_utc AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MI') AS slot,
               price_currency_mwh
        FROM entsoe.energy_prices
        WHERE map_code = \$1 AND contract_type = 'Day-ahead'
          AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
          AND price_currency_mwh IS NOT NULL
        ORDER BY 1""", Any[zone, day])
    byh = Dict{Int,Vector{Float64}}()
    for r in eachrow(df)
        push!(get!(byh, parse(Int, r.slot[10:11]), Float64[]), r.price_currency_mwh)
    end
    return Dict(h => mean(v) for (h, v) in byh)
end

"Engine clear with strategist-hook capture. Returns (hourly, per-slot, ctx)."
function engine_arm(zone, day)
    captured = Ref{Any}(nothing)
    strat = ctx -> (captured[] = ctx; ctx.tagged_orders)   # identity pass-through
    sim = generate_energy_prices(zone, day; order_method=:merit_order,
                                 save_to_db=false, random_seed=SEED,
                                 strategist=strat)
    byh = Dict{Int,Vector{Float64}}()
    for (ts, p) in sim
        push!(get!(byh, parse(Int, ts[10:11]), Float64[]), p)
    end
    return Dict(h => mean(v) for (h, v) in byh), sim, captured[]
end

"""
Valley-hour gate, replicated EXACTLY from book_build.jl grsq2_share/grsq2_valley
(hours 04–13 UTC with day-ahead solar share of forecast load ≥ 0.25), using the
same renewables records and the captured post-build load_by_time.
"""
function valley_hours(zone, day, load_by_time)
    ren = Euphemia.get_generation_forecast_for_wind_and_solar(zone, day)
    sol = Dict{Int,Vector{Float64}}(); ld = Dict{Int,Vector{Float64}}()
    for r in ren
        r.production_type == "Solar" || continue
        length(r.date_time) >= 11 || continue
        push!(get!(sol, parse(Int, r.date_time[10:11]), Float64[]),
              r.aggregated_generation_forecast)
    end
    for (ts, v) in load_by_time
        length(ts) >= 11 || continue
        push!(get!(ld, parse(Int, ts[10:11]), Float64[]), v)
    end
    hrs = Int[]
    for (h, vs) in sol
        lv = haskey(ld, h) ? sum(ld[h]) / length(ld[h]) : 0.0
        share = lv > 0 ? (sum(vs) / length(vs)) / lv : 0.0
        4 <= h <= 13 && share >= 0.25 && push!(hrs, h)
    end
    return sort(hrs)
end

# ── main loop ─────────────────────────────────────────────────────────────

price_rows = NamedTuple[]     # per (day, hour): the four arms
diag_rows = NamedTuple[]      # per day: blocks, iterations, times, sanity
block_rows = NamedTuple[]     # per (day, unit): block fate

for day in DAYS
    println("\n════ $day ════")
    settled = settled_hourly(ZONE, day)
    if isempty(settled)
        println("  no settled prices — skipping"); continue
    end

    # arm b: base book + capture (switches off)
    delete!(ENV, "EUPHEMIA_ENABLE_GRSQ_T2")
    base_h, base_raw, ctx = engine_arm(ZONE, day)
    ctx === nothing && (println("  no capture — skipping"); continue)

    # arm c: projection lever (env read per book build; same process is fine)
    ENV["EUPHEMIA_ENABLE_GRSQ_T2"] = "1"
    lever_h, _, _ = engine_arm(ZONE, day)
    delete!(ENV, "EUPHEMIA_ENABLE_GRSQ_T2")

    gens = Euphemia.get_generators(ZONE, day)
    commits = Euphemia.MeritOrderBook._valley_continuation_commits(ZONE, day, gens)
    vhrs = valley_hours(ZONE, day, ctx.load_by_time)
    println("  valley hours (04–13 UTC, solar share ≥ 0.25): $vhrs")
    println("  overnight runners: $(length(commits)) " *
            "($(round(sum(values(commits)); digits=0)) MW committed)")

    block_h = Dict{Int,Float64}()
    diag = (; day, n_units=length(commits), commit_mw=sum(values(commits); init=0.0),
            n_valley_hours=length(vhrs), n_blocks=0, n_accepted=0, n_banned=0,
            n_prb=0, pab_iterations=0, mip_s=NaN, lp_s=NaN, total_s=NaN,
            sanity_max_dp=NaN, sanity_n_off=0, maxd_bp_valley=NaN, maxd_bp_all=NaN)
    if BLOCKS_ON && !isempty(vhrs) && !isempty(commits)
        tagged = ctx.tagged_orders
        # periods (the book's native resolution — hourly or 15-min)
        periods = sort(unique(o.date_time for (o, _) in tagged))
        pidx = Dict(dt => i for (i, dt) in enumerate(periods))
        wp = zeros(length(periods))
        for (o, _) in tagged
            wp[pidx[o.date_time]] = parse(Int, string(o.resolution_code)) / 60.0
        end
        vper = [i for (i, dt) in enumerate(periods) if Dates.hour(dt) in vhrs]

        # mutable per-order remaining quantities (for the valley removal)
        qty = [o.quantity for (o, _) in tagged]

        # build one block per overnight runner: remove its cheapest committed
        # MW from every valley period; the block carries that MW fill-or-kill
        blocks = VBlock[]
        for (code, want0) in sort(collect(commits))
            # available MW of this unit per valley period
            byper = Dict{Int,Vector{Int}}()
            for (k, (o, tag)) in enumerate(tagged)
                (o.type == :supply && tag == code) || continue
                p = pidx[o.date_time]
                p in vper && push!(get!(byper, p, Int[]), k)
            end
            avail = [sum(qty[k] for k in get(byper, p, Int[]); init=0.0) for p in vper]
            q_u = min(want0, isempty(avail) ? 0.0 : minimum(avail))
            if q_u <= 1e-6
                push!(block_rows, (; day, unit=code, q_mw=0.0, fate="no_orders_in_valley"))
                continue
            end
            for p in vper                      # remove q_u cheapest MW at p
                idxs = sort(byper[p]; by=k -> tagged[k][1].price)
                want = q_u
                for k in idxs
                    want <= 1e-9 && break
                    take = min(want, qty[k]); qty[k] -= take; want -= take
                end
            end
            push!(blocks, VBlock(code, q_u, vper, FLOOR))
        end

        # hourly-order lists from the (post-removal) book
        supply = HOrder[]; demand = HOrder[]
        for (k, (o, _)) in enumerate(tagged)
            qty[k] <= 1e-9 && continue
            p = pidx[o.date_time]
            o.type == :supply ? push!(supply, HOrder(p, o.price, qty[k])) :
                                push!(demand, HOrder(p, o.price, qty[k]))
        end

        # sanity arm: pure LP on the UNMODIFIED book vs engine base prices
        sup0 = HOrder[]; dem0 = HOrder[]
        for (o, _) in tagged
            p = pidx[o.date_time]
            o.type == :supply ? push!(sup0, HOrder(p, o.price, o.quantity)) :
                                push!(dem0, HOrder(p, o.price, o.quantity))
        end
        lp0 = lp_only_prices(sup0, dem0, wp)
        # dual-sign auto-detection against the engine's own prices; the sign
        # feeds the PAB test inside clear_with_blocks via DUAL_SIGN.
        # Per-SLOT comparison (an hourly mean would inflate the diff wherever
        # the price moves within the hour on the 15-min book).
        eng = [get(base_raw, Dates.format(dt, "yyyymmdd-HHMM"), NaN) for dt in periods]
        ok = .!isnan.(eng)
        sgn = sum(abs.(lp0[ok] .- eng[ok])) <= sum(abs.(-lp0[ok] .- eng[ok])) ? 1.0 : -1.0
        DUAL_SIGN[] = sgn
        sanity = maximum(abs.(sgn .* lp0[ok] .- eng[ok]))
        n_off = count(abs.(sgn .* lp0[ok] .- eng[ok]) .> 0.01)
        @printf("  sanity (no-block LP vs engine base): max |Δ| = %.4f €/MWh (%d/%d periods > 0.01, dual sign %+d)\n",
                sanity, n_off, count(ok), Int(sgn))

        t0 = time()
        r = clear_with_blocks(supply, demand, blocks, wp)
        ttot = time() - t0
        bprices = sgn .* r.prices
        byh = Dict{Int,Vector{Float64}}()
        for (i, dt) in enumerate(periods)
            push!(get!(byh, Dates.hour(dt), Float64[]), bprices[i])
        end
        block_h = Dict(h => mean(v) for (h, v) in byh)

        for blk in blocks
            wsum = sum(wp[p] for p in blk.span)
            avgp = sum(bprices[p] * wp[p] for p in blk.span) / wsum
            fate = blk.unit in r.banned ? "PAB_forced_reject" :
                   r.z[blk.unit] > 0.5 ? "accepted" :
                   blk.unit in r.prb ? "paradoxically_rejected" : "rejected"
            push!(block_rows, (; day, unit=blk.unit, q_mw=round(blk.q; digits=1),
                               fate, avg_price=round(avgp; digits=2)))
        end
        n_acc = count(v -> v > 0.5, values(r.z))
        println("  blocks: $(length(blocks)) built, $n_acc accepted, " *
                "$(length(r.banned)) PAB-banned, $(length(r.prb)) paradoxically rejected; " *
                "$(r.iterations) PAB iteration(s)")
        @printf("  solve: MIP %s s, LP %s s, total %.2f s, final gap %.1e\n",
                join(round.(r.mip_times; digits=2), "+"),
                join(round.(r.lp_times; digits=2), "+"), ttot, r.mip_gap)
        # the pilot's key question: does endogenous acceptance diverge from
        # the hourly projection?
        dv = maximum(abs(get(block_h, h, NaN) - get(lever_h, h, NaN)) for h in vhrs)
        dall = maximum(abs(get(block_h, h, NaN) - get(lever_h, h, NaN))
                       for h in keys(block_h))
        @printf("  block vs projection: max |Δ| valley %.2f, all-hours %.2f €/MWh\n",
                dv, dall)
        diag = (; diag..., n_blocks=length(blocks), n_accepted=n_acc,
                n_banned=length(r.banned), n_prb=length(r.prb),
                pab_iterations=r.iterations, mip_s=sum(r.mip_times),
                lp_s=sum(r.lp_times), total_s=ttot, sanity_max_dp=sanity,
                sanity_n_off=n_off, maxd_bp_valley=dv, maxd_bp_all=dall)
    end
    push!(diag_rows, diag)

    for h in sort(collect(keys(base_h)))
        push!(price_rows, (; day, hour=h, valley=(h in vhrs),
              settled=get(settled, h, NaN), base=get(base_h, h, NaN),
              projection=get(lever_h, h, NaN),
              block_mip=get(block_h, h, NaN)))
    end
    flush(stdout)
end

pdf = DataFrame(price_rows)
CSV.write(joinpath(OUT, "block_pilot_prices.csv"), pdf)
CSV.write(joinpath(OUT, "block_pilot_blocks.csv"), DataFrame(block_rows))
CSV.write(joinpath(OUT, "block_pilot_diag.csv"), DataFrame(diag_rows))
println("\nOutputs in $OUT")

# compact valley-hour table
println("\nValley-hour comparison (€/MWh):")
println("day         hr  settled    base    proj   block")
for r in eachrow(pdf[pdf.valley .== true, :])
    @printf("%s  %02d  %7.2f %7.2f %7.2f %7.2f\n",
            r.day, r.hour, r.settled, r.base, r.projection, r.block_mip)
end

# valley MAE per day/arm
println("\nValley-hour MAE vs settled (€/MWh):")
for day in unique(pdf.day)
    s = pdf[(pdf.day .== day) .& pdf.valley .& .!isnan.(pdf.settled), :]
    isempty(s) && continue
    @printf("%s  base %6.2f  proj %6.2f  block %6.2f  (n=%d)\n", day,
            mean(abs.(s.base .- s.settled)), mean(abs.(s.projection .- s.settled)),
            all(isnan.(s.block_mip)) ? NaN : mean(abs.(s.block_mip .- s.settled)),
            nrow(s))
end
println("PILOT_DONE")
