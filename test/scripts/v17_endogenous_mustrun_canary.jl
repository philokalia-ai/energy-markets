# v17 ENDOGENOUS MUST-RUN canary — the one-variable isolation experiment.
#
# Same harness, zones, days, and decision rule as v17_block_canary.jl, but the
# comparison is now the clean isolation the block canary could not give:
#
#   static     — :merit_order with the day-level must-run heuristic (today)
#   endogenous — the IDENTICAL merit book where ONLY the per-hour committed set
#                that gates the must-run split comes from the commitment MILP
#                (BlockCommitment._commitment_milp on the same fundamentals,
#                anchored to real initial conditions).
#
# Everything else — tranche ladder, scarcity factor, water values, demand, RES,
# imports, the must-run PRICE split itself — is byte-identical between arms.
#
# Per zone-day it also records the committed-set overlap (mean hourly Jaccard
# vs the static set) and the MILP solve time, and flags fallbacks to :static.
#
#   julia --project=. test/scripts/v17_endogenous_mustrun_canary.jl
#
# Decision rule (unchanged): a zone improves iff endogenous lowers 3-day-mean
# MAE by >= 1 EUR/MWh AND does not drop correlation.

using Euphemia, Dates, Statistics, Printf, DataFrames

const ZONES = ["GR","BG","RS","RO", "DE_LU","PL","CZ","NL", "FR",
               "ES","PT", "IT-NORTH", "FI","NO2", "AT","SK"]
const DAYS = [Date(2026,1,14), Date(2026,4,15), Date(2026,6,15)]

# FAIR clear: both arms use the zone's own profile and the same book builder;
# only must_run_mode differs.
function merit_clear(z::String, d::Date; must_run_mode::Symbol=:static)
    prof = Euphemia.get_zone_profile(z)
    r = Euphemia.create_merit_order_book(z, d; profile=prof, must_run_mode=must_run_mode)
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
overlap_rows = NamedTuple[]
for z in ZONES
    sc, sm, ec, em, milpt, jacc = Float64[], Float64[], Float64[], Float64[], Float64[], Float64[]
    for d in DAYS
        act = actual_hourly(z, d)
        isempty(act) && (println("!! no actuals $z $d"); continue)
        local sp, ep
        try
            sp = merit_clear(z, d; must_run_mode=:static)
        catch e; println("!! static fail $z $d: $e"); continue; end
        try
            ep = merit_clear(z, d; must_run_mode=:endogenous)
        catch e; println("!! endo fail $z $d: $e"); continue; end
        st = Euphemia.MeritOrderBook.LAST_ENDOGENOUS_STATS[]
        if st === nothing
            println("!! endo FELL BACK to :static for $z $d — excluding day from comparison")
            continue
        end
        (isempty(sp) || isempty(ep)) && (println("!! empty prices $z $d"); continue)
        ss = score(sim_hourly(sp), act); se = score(sim_hourly(ep), act)
        push!(sc, ss.corr); push!(sm, ss.mae); push!(ec, se.corr); push!(em, se.mae)
        push!(milpt, st.milp_seconds); push!(jacc, st.overlap_jaccard)
        push!(overlap_rows, (zone=z, day=d, jaccard=st.overlap_jaccard,
              endo_size=st.mean_endo_size, static_size=st.static_size,
              milp_s=st.milp_seconds, status=string(st.status)))
        @printf("  %-9s %s  static c=%.3f MAE=%6.1f | endo c=%.3f MAE=%6.1f  (jac=%.2f, milp %.0fs)\n",
                z, d, ss.corr, ss.mae, se.corr, se.mae, st.overlap_jaccard, st.milp_seconds)
    end
    isempty(sm) && continue
    results[z] = (scorr=mean(sc), smae=mean(sm), ecorr=mean(ec), emae=mean(em),
                  dmae=mean(sm)-mean(em), dcorr=mean(ec)-mean(sc),
                  milp=mean(milpt), jac=mean(jacc), ndays=length(sm))
end

println("\n" * "="^100)
println("v17 ENDOGENOUS MUST-RUN CANARY — per-zone 3-day average (static vs endogenous committed set)")
println("="^100)
@printf("%-10s %6s %7s | %6s %7s | %7s %7s  %-8s %5s %5s\n",
        "zone","s_corr","s_MAE","e_corr","e_MAE","dMAE","dcorr","improves","jac","milp")
improved = String[]
for z in ZONES
    haskey(results, z) || continue
    r = results[z]
    imp = (r.dmae >= 1.0 && r.dcorr >= 0.0)
    imp && push!(improved, z)
    @printf("%-10s %6.3f %7.1f | %6.3f %7.1f | %+7.1f %+7.3f  %-8s %5.2f %4.0fs\n",
            z, r.scorr, r.smae, r.ecorr, r.emae, r.dmae, r.dcorr, imp ? "YES" : "no", r.jac, r.milp)
end
println("="^100)
println("IMPROVE (endo MAE -≥1 AND corr not dropped): ", isempty(improved) ? "(none)" : join(improved, ", "))
if !isempty(results)
    @printf("AGG static meanMAE=%.1f meanCorr=%.2f | endo meanMAE=%.1f meanCorr=%.2f\n",
            mean(r.smae for r in values(results)), mean(r.scorr for r in values(results)),
            mean(r.emae for r in values(results)), mean(r.ecorr for r in values(results)))
end

println("\nCOMMITTED-SET OVERLAP (per zone-day):")
@printf("%-10s %-12s %8s %10s %11s %7s  %s\n", "zone","day","jaccard","endo_size","static_size","milp_s","status")
for r in overlap_rows
    @printf("%-10s %-12s %8.2f %10.1f %11d %7.0f  %s\n",
            r.zone, r.day, r.jaccard, r.endo_size, r.static_size, r.milp_s, r.status)
end
