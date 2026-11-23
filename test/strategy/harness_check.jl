# Harness self-checks on one cached baseline day (st-orch). env DAY. Run in the same env as baseline.sh.
using Euphemia, Dates
configure_data_store!(backend=:duckdb, duckdb_path=ENV["EUPHEMIA_DUCKDB_PATH"], read_only=true)
include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
day = Date(ENV["DAY"]); b = load_baseline(day)
maxdiff(a, c) = maximum(abs(a[z][p] - c[z][p]) for z in keys(a) for p in keys(a[z]) if haskey(c, z) && haskey(c[z], p))
# 1. empty re-clear == baseline
t = time(); r0 = reclear(b, MarketOrder[]); println("CHECK1 empty reclear: status=$(r0.status) max|Δp|=$(maxdiff(b.prices, r0.prices)) solve=$(round(time()-t; digits=1))s")
# 2. carve 400 MW of GR supply around 120 €/MWh, add the same 400 MW back as one company order per period at 120
z = "GR"; per = b.book.periods
ts(p) = DateTime(day) + Hour(StrategyHarness.period_hour(p))
co = MarketOrder[SimpleOrder(:supply, 120.0, 400.0, Symbol(z), ts(p), 60) for p in per]
r2 = reclear(b, co; carve=[Carve(z, 400.0, 60.0, 180.0; ref=120.0)])
dd = sort([(abs(r2.prices[zz][p] - b.prices[zz][p]), zz, p, b.prices[zz][p], r2.prices[zz][p]) for zz in keys(b.prices) for p in keys(b.prices[zz]) if haskey(r2.prices, zz)]; rev=true)[1:8]
println("CHECK2 top diffs: ", dd)
println("CHECK2 carve+truthful: max|Δp| all=$(maxdiff(b.prices, r2.prices)) GR=$(maximum(abs(b.prices[z][p]-r2.prices[z][p]) for p in per)) shortfall=$(sum(values(r2.carve_shortfall); init=0.0)) accepted_MWh=$(sum(r2.accepted)) ambiguous=$(count(r2.ambiguous))")
# 3. residual demand GR + slope
t = time(); rd = residual_demand(b, z; q_grid=[-500.0, -100.0, 0.0, 100.0, 500.0], cache=false)
sl = rd_slope(rd); println("CHECK3 residual_demand GR 5 pts in $(round(time()-t; digits=1))s; slope €/MWh per 100MW by hour: ",
    join([string(round(100 * sl[p]; digits=2)) for p in sort(collect(keys(sl)); by=StrategyHarness.period_hour)], " "))
# 4. withholding: company 400 MW priced at 3000 instead of 120 (after carve) -> GR price up
co4 = MarketOrder[SimpleOrder(:supply, 3000.0, 400.0, Symbol(z), ts(p), 60) for p in per]
r4 = reclear(b, co4; carve=[Carve(z, 400.0, 60.0, 180.0; ref=120.0)])
println("CHECK4 withhold 400MW GR: mean Δp GR=$(round(sum(r4.prices[z][p]-b.prices[z][p] for p in per)/length(per); digits=2)) accepted_MWh=$(sum(r4.accepted))")
# 5. realised
re = load_realised(day); println("CHECK5 realised keys match book periods: $(all(p -> haskey(re["GR"], p), per)) zones=$(length(re)) GR mean=$(round(sum(values(re["GR"]))/length(re["GR"]); digits=2)) forecast GR mean=$(round(sum(values(b.prices["GR"]))/24; digits=2))")
# 6. a company BLK block accepted in GR (cheap 100 MW 24h block at 1 €/MWh) -> blocks_accepted, accepted MW = 100/period
fam = "BLK:hc6:GR"
co6 = MarketOrder[Euphemia.MarketOrders.LinkedHourlyOrder(:supply, 1.0, 100.0, :GR, ts(p), 60, fam, 2400.0) for p in per]
r6 = reclear(b, co6)
println("CHECK6 BLK accepted=$(fam in r6.blocks_accepted) MWh=$(sum(r6.accepted)) (expect true, 2400)")
