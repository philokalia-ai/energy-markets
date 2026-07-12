# GR mini-UC with fix-and-reprice. Tests whether ENDOGENOUS COMMITMENT
# (units paying startup to avoid cycling, staying on at min-load through the
# midday trough) reproduces the price shape better than a per-period clear.
#
#   1. MILP: min production + startup + no-load, s.t. balance, min/max output
#      gated by commitment u∈{0,1}, ramp, startup logic, min-uptime.
#   2. Fix u = u*, re-solve the LP → price[t] = dual of the balance (a unit on
#      min-load can now be marginal — the fix-and-reprice non-convex price).
#
# Hydro/storage priced at water value (≈gas) so midday isn't an artefact of
# hydro's ~zero variable cost; this isolates the commitment effect. Gurobi (MILP).
using Euphemia, Dates, JuMP, Gurobi, DataFrames, Statistics, Printf

const ZONE = "DE_LU"; const DAY = Date(2025, 12, 15); const VOLL = 3000.0
const FLEX = Set(String.(["Hydro Water Reservoir", "Hydro Run-of-river and pondage",
    "Hydro Pumped Storage", "Energy storage", "Other"]))

gens = [g for g in Euphemia.get_generators_with_inferred_params(ZONE, DAY) if g.p_max > 0]
gas_srmc = Euphemia.get_marginal_cost(DAY, "Fossil Gas", ZONE)
mc = [String(g.fuel_type) in FLEX ? 0.85 * gas_srmc : g.marginal_cost for g in gens]  # water-value hydro
N = length(gens)
println("generators=$N  gas SRMC=$(round(gas_srmc,digits=1))  €/MWh")

q(sql) = Euphemia.sql2df(sql, String[])
ld = q("""SELECT EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int h, AVG(total_load_mw) mw
          FROM entsoe.day_ahead_total_load_forecast WHERE area_map_code='$ZONE'
            AND (date_time_utc AT TIME ZONE 'UTC')::date='$DAY'
            AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY') GROUP BY 1""")
rn = q("""SELECT h, AVG(tot) mw FROM (SELECT date_time_utc, EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int h,
            SUM(COALESCE(day_ahead_generation_forecast_mw,0)) tot FROM entsoe.generation_forecasts_for_wind_and_solar
            WHERE area_map_code='$ZONE' AND (date_time_utc AT TIME ZONE 'UTC')::date='$DAY'
              AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY') GROUP BY date_time_utc,h) s GROUP BY h""")
loadh = Dict(Int(r.h)=>r.mw for r in eachrow(ld)); resh = Dict(Int(r.h)=>r.mw for r in eachrow(rn))
T = sort(collect(keys(loadh))); H = length(T)
net = [max(0.0, loadh[h] - get(resh, h, 0.0)) for h in T]
ap = q("""WITH d AS (SELECT DISTINCT ON (date_time_utc) date_time_utc, price_currency_mwh p FROM entsoe.energy_prices
            WHERE map_code='$ZONE' AND contract_type='Day-ahead' AND area_type_code LIKE 'BZN%'
              AND (date_time_utc AT TIME ZONE 'UTC')::date='$DAY'
            ORDER BY date_time_utc,(CASE WHEN sequence ~ '^\\s*\\d+\\s*\$' THEN trim(sequence)::int ELSE NULL END) DESC NULLS LAST)
          SELECT EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int h, AVG(p) p FROM d GROUP BY 1""")
actual = Dict(Int(r.h)=>r.p for r in eachrow(ap))

# per-generator UC params
pmax = [g.p_max for g in gens]; pmin = [g.p_min for g in gens]
ru = [something(g.ramp_up, 0.3)*g.p_max for g in gens]; rd = [something(g.ramp_down, 0.3)*g.p_max for g in gens]
isflex = [String(g.fuel_type) in FLEX for g in gens]
minup = [isflex[i] ? 1 : Int(something(gens[i].min_uptime, 4)) for i in 1:N]
sumult = [String(g.fuel_type) in Set(["Fossil Hard coal","Fossil Brown coal/Lignite"]) ? 2.0 : 1.0 for g in gens]
SU = [sumult[i]*mc[i]*pmax[i] for i in 1:N]       # startup cost (€)
NL = [0.05*mc[i]*pmin[i] for i in 1:N]            # no-load cost (€/h)

# ---- 1) commitment MILP ----
env = Gurobi.Env(); m = Model(() -> Gurobi.Optimizer(env)); set_silent(m)
set_optimizer_attribute(m, "MIPGap", 0.01); set_optimizer_attribute(m, "TimeLimit", 300.0)
@variable(m, p[1:N,1:H] >= 0); @variable(m, u[1:N,1:H], Bin); @variable(m, v[1:N,1:H] >= 0)
@variable(m, short[1:H] >= 0); @variable(m, spill[1:H] >= 0)
@constraint(m, bal[t=1:H], sum(p[i,t] for i in 1:N) + short[t] - spill[t] == net[t])
@constraint(m, [i=1:N,t=1:H], p[i,t] <= pmax[i]*u[i,t])
@constraint(m, [i=1:N,t=1:H], p[i,t] >= pmin[i]*u[i,t])
@constraint(m, [i=1:N,t=2:H], p[i,t]-p[i,t-1] <= ru[i] + pmax[i]*v[i,t])      # ramp (relaxed at startup)
@constraint(m, [i=1:N,t=2:H], p[i,t-1]-p[i,t] <= rd[i] + pmax[i]*u[i,t-1]*0 + pmax[i]*(1-u[i,t])) # relaxed at shutdown
@constraint(m, [i=1:N,t=2:H], v[i,t] >= u[i,t]-u[i,t-1])
for i in 1:N, t in 1:H  # min uptime
    minup[i] <= 1 && continue
    @constraint(m, sum(u[i,τ] for τ in t:min(H,t+minup[i]-1)) >= minup[i]*v[i,t])
end
@objective(m, Min, sum(mc[i]*p[i,t] for i in 1:N,t in 1:H) + sum(SU[i]*v[i,t] for i in 1:N,t in 1:H)
                  + sum(NL[i]*u[i,t] for i in 1:N,t in 1:H) + VOLL*sum(short) + VOLL*sum(spill))
_tmilp = @elapsed optimize!(m); @printf("MILP solve: %.1fs\n", _tmilp)
ustar = round.(value.(u))

# ---- 2) fix-and-reprice LP ----
function reprice(ufix; commitment::Bool)
    lp = Model(() -> Gurobi.Optimizer(env)); set_silent(lp)
    @variable(lp, p[1:N,1:H] >= 0); @variable(lp, short[1:H] >= 0); @variable(lp, spill[1:H] >= 0)
    @constraint(lp, bal[t=1:H], sum(p[i,t] for i in 1:N) + short[t] - spill[t] == net[t])
    @constraint(lp, [i=1:N,t=1:H], p[i,t] <= pmax[i]*ufix[i,t])
    if commitment
        @constraint(lp, [i=1:N,t=1:H], p[i,t] >= pmin[i]*ufix[i,t])           # min-load when on
        @constraint(lp, [i=1:N,t=2:H], p[i,t]-p[i,t-1] <= ru[i] + pmax[i]*(ufix[i,t]-ufix[i,t-1] > 0.5 ? 1 : 0))
    end
    @objective(lp, Min, sum(mc[i]*p[i,t] for i in 1:N,t in 1:H) + VOLL*sum(short) + VOLL*sum(spill))
    optimize!(lp)
    return [dual(bal[t]) for t in 1:H]
end
price_uc = reprice(ustar; commitment=true)
# clean per-period baseline: every unit free to dispatch 0..p_max each hour,
# NO p_min forcing, NO inter-temporal coupling — the classic marginal clear.
price_flat = reprice(ones(N,H); commitment=false)

hs=[h for h in T if haskey(actual,h)]; va=[actual[h] for h in hs]
idx=Dict(T[t]=>t for t in 1:H); vuc=[price_uc[idx[h]] for h in hs]; vfl=[price_flat[idx[h]] for h in hs]
c2(x,y)=(std(x)==0||std(y)==0) ? NaN : cor(x,y); mae(x,y)=mean(abs.(x.-y))
println("\nhour  actual  flat_LP  mini_UC   committed_units")
for (i,h) in enumerate(hs)
    nc = Int(round(sum(ustar[:,idx[h]])))
    @printf("  %2d   %6.1f  %6.1f  %6.1f     %d/%d\n", h, va[i], vfl[i], vuc[i], nc, N)
end
@printf("\nflat LP (per-period, same costs): corr=%.3f  MAE=%.1f\n", c2(vfl,va), mae(vfl,va))
@printf("mini-UC (commitment+reprice):     corr=%.3f  MAE=%.1f\n", c2(vuc,va), mae(vuc,va))

# --- isolate commitment from the capacity-shortage artefact ---
keep = [i for i in 1:length(hs) if abs(vuc[i]) < 1000 && abs(vfl[i]) < 1000]
va2, vuc2, vfl2 = va[keep], vuc[keep], vfl[keep]
@printf("\n(excluding %d VOLL/shortage hours — fleet undercount, not the mechanism)\n", length(hs)-length(keep))
@printf("flat LP (per-period):          corr=%.3f  MAE=%.1f\n", c2(vfl2,va2), mae(vfl2,va2))
@printf("mini-UC (commitment+reprice):  corr=%.3f  MAE=%.1f\n", c2(vuc2,va2), mae(vuc2,va2))
