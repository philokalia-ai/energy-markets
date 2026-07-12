# v17 block-commitment CANARY.
#
# For a representative set of zones spanning the zone classes, clears 3 days
# (winter / shoulder / summer) SINGLE-ZONE both :merit_order and
# :block_commitment on IDENTICAL fundamentals, scores each against actual
# day-ahead prices (resolution-aware: dedup latest sequence, hourly mean), and
# prints a per-zone table of merit vs block corr + MAE (3-day average) plus the
# "improves" decision (block lowers MAE by >=1 EUR/MWh AND does not drop corr).
#
#   julia --project=. test/scripts/v17_block_canary.jl

using Euphemia, Dates, Statistics, Printf, DataFrames

const ZONES = ["GR","BG","RS","RO", "DE_LU","PL","CZ","NL", "FR",
               "ES","PT", "IT-NORTH", "FI","NO2", "AT","SK"]
const DAYS = [Date(2026,1,14), Date(2026,4,15), Date(2026,6,15)]

# FAIR merit clear: same zone profile as the block clear (identical fundamentals).
# The single-zone `generate_energy_prices(:merit_order)` path always uses
# SEE_PROFILE, so for continental zones it would clear a DIFFERENT (p95) fleet
# than the block clear's installed fleet — an unfair comparison. Here BOTH
# methods clear on `get_zone_profile(z)`, so only the mechanism differs.
function merit_clear(z::String, d::Date)
    prof = Euphemia.get_zone_profile(z)
    r = Euphemia.create_merit_order_book(z, d; profile=prof)
    r.success || error("merit book failed: $(r.message)")
    mr = Euphemia.solve_mpcc_market_clearing(r.order_book; preferred_solver="auto", silent=true)
    haskey(mr.market_prices, z) || error("no merit prices for $z")
    return mr.market_prices[z]
end

# hourly actual day-ahead prices for one zone/day (resolution-aware)
function actual_hourly(zone::String, day::Date)
    df = Euphemia.sql2df("""
        WITH dedup AS (
          SELECT DISTINCT ON (date_time_utc) date_time_utc, price_currency_mwh p
          FROM entsoe.energy_prices
          WHERE map_code = \$1 AND contract_type = 'Day-ahead' AND area_type_code LIKE 'BZN%'
            AND price_currency_mwh IS NOT NULL
            AND (date_time_utc AT TIME ZONE 'UTC')::date = \$2
          ORDER BY date_time_utc,
                   (CASE WHEN sequence ~ '^\\s*\\d+\\s*\$' THEN trim(sequence)::int ELSE NULL END) DESC NULLS LAST,
                   update_time_utc DESC
        )
        SELECT EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int h, AVG(p) p
        FROM dedup GROUP BY 1
    """, Any[zone, day])
    Dict(Int(r.h) => Float64(r.p) for r in eachrow(df))
end

# collapse a timeslot=>price dict to hour=>mean
function sim_hourly(p::Dict{String,Float64})
    acc = Dict{Int,Tuple{Float64,Int}}()
    for (ts, v) in p
        h = parse(Int, ts[10:11])
        s, n = get(acc, h, (0.0, 0))
        acc[h] = (s + v, n + 1)
    end
    Dict(h => s / n for (h, (s, n)) in acc)
end

score(sim, act) = begin
    hs = sort([h for h in keys(sim) if haskey(act, h)])
    sv = [sim[h] for h in hs]; av = [act[h] for h in hs]
    c = (length(sv) >= 3 && std(sv) > 0 && std(av) > 0) ? cor(sv, av) : NaN
    m = isempty(sv) ? NaN : mean(abs.(sv .- av))
    (corr=c, mae=m, n=length(sv))
end

results = Dict{String,Any}()
for z in ZONES
    mc, mm, bc, bm, st = Float64[], Float64[], Float64[], Float64[], Float64[]
    for d in DAYS
        act = actual_hourly(z, d)
        isempty(act) && (println("!! no actuals $z $d"); continue)
        local mp, bp, tsolve
        try
            mp = merit_clear(z, d)
        catch e; println("!! merit fail $z $d: $e"); continue; end
        try
            t0 = time()
            bp = generate_energy_prices(z, d; order_method=:block_commitment, save_to_db=false)
            tsolve = time() - t0
        catch e; println("!! block fail $z $d: $e"); continue; end
        (isempty(mp) || isempty(bp)) && (println("!! empty prices $z $d"); continue)
        sm = score(sim_hourly(mp), act); sb = score(sim_hourly(bp), act)
        push!(mc, sm.corr); push!(mm, sm.mae); push!(bc, sb.corr); push!(bm, sb.mae); push!(st, tsolve)
        @printf("  %-9s %s  merit c=%.3f MAE=%5.1f | block c=%.3f MAE=%5.1f (%.0fs)\n",
                z, d, sm.corr, sm.mae, sb.corr, sb.mae, tsolve)
    end
    isempty(mm) && continue
    results[z] = (mcorr=mean(mc), mmae=mean(mm), bcorr=mean(bc), bmae=mean(bm),
                  dmae=mean(mm)-mean(bm), dcorr=mean(bc)-mean(mc), tsolve=mean(st), ndays=length(mm))
end

println("\n" * "="^92)
println("v17 BLOCK-COMMITMENT CANARY — per-zone 3-day average (merit vs block)")
println("="^92)
@printf("%-10s %6s %7s | %6s %7s | %7s %7s  %-8s %5s\n",
        "zone","m_corr","m_MAE","b_corr","b_MAE","dMAE","dcorr","improves","solve")
improved = String[]
for z in ZONES
    haskey(results, z) || continue
    r = results[z]
    imp = (r.dmae >= 1.0 && r.dcorr >= 0.0)
    imp && push!(improved, z)
    @printf("%-10s %6.3f %7.1f | %6.3f %7.1f | %+7.1f %+7.3f  %-8s %4.0fs\n",
            z, r.mcorr, r.mmae, r.bcorr, r.bmae, r.dmae, r.dcorr, imp ? "YES" : "no", r.tsolve)
end
println("="^92)
println("IMPROVE (block MAE -≥1 AND corr not dropped): ", isempty(improved) ? "(none)" : join(improved, ", "))
if !isempty(results)
    @printf("AGG merit meanMAE=%.1f meanCorr=%.2f | block meanMAE=%.1f meanCorr=%.2f\n",
            mean(r.mmae for r in values(results)), mean(r.mcorr for r in values(results)),
            mean(r.bmae for r in values(results)), mean(r.bcorr for r in values(results)))
end
