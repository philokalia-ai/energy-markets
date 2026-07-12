# Prototype: does buildup/builddown (ramp coupling) move the competitive price
# shape closer to reality than the per-period clear? Single-zone GR, one day.
# Pure marginal-cost economic dispatch (perfect-competition benchmark), solved
# WITH and WITHOUT inter-temporal ramp constraints; price = dual of the hourly
# energy balance. Ramp constraints are LINEAR, so the dispatch stays an LP with
# well-defined duals (no non-convex-pricing issue yet — that arrives with
# commitment binaries). HiGHS is fine here (LP).
using Euphemia, Dates, JuMP, HiGHS, DataFrames, Statistics, Printf

const ZONE = "GR"
const DAY = Date(2026, 4, 3)

gens = Euphemia.get_generators_with_inferred_params(ZONE, DAY)
gens = [g for g in gens if g.p_max > 0]
println("dispatchable generators: ", length(gens))

# --- net demand per hour (load − wind/solar forecast), hourly mean ---
q(sql) = Euphemia.sql2df(sql, String[])
ld = q("""SELECT EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int h, AVG(total_load_mw) mw
          FROM entsoe.day_ahead_total_load_forecast
          WHERE area_map_code='$ZONE' AND (date_time_utc AT TIME ZONE 'UTC')::date='$DAY'
            AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY') GROUP BY 1""")
rn = q("""SELECT h, AVG(tot) mw FROM (
            SELECT date_time_utc, EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int h,
                   SUM(COALESCE(day_ahead_generation_forecast_mw,0)) tot
            FROM entsoe.generation_forecasts_for_wind_and_solar
            WHERE area_map_code='$ZONE' AND (date_time_utc AT TIME ZONE 'UTC')::date='$DAY'
              AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
            GROUP BY date_time_utc, h) s GROUP BY h""")
loadh = Dict(Int(r.h) => r.mw for r in eachrow(ld))
resh  = Dict(Int(r.h) => r.mw for r in eachrow(rn))
T = sort(collect(keys(loadh)))
net = [max(0.0, loadh[h] - get(resh, h, 0.0)) for h in T]
@printf("hours=%d  net demand range [%.0f, %.0f] MW\n", length(T), minimum(net), maximum(net))

# --- actual GR day-ahead price per hour ---
ap = q("""WITH d AS (SELECT DISTINCT ON (date_time_utc) date_time_utc, price_currency_mwh p
            FROM entsoe.energy_prices WHERE map_code='$ZONE' AND contract_type='Day-ahead'
              AND area_type_code LIKE 'BZN%' AND (date_time_utc AT TIME ZONE 'UTC')::date='$DAY'
            ORDER BY date_time_utc, (CASE WHEN sequence ~ '^\\s*\\d+\\s*\$' THEN trim(sequence)::int ELSE NULL END) DESC NULLS LAST)
          SELECT EXTRACT(HOUR FROM date_time_utc AT TIME ZONE 'UTC')::int h, AVG(p) p FROM d GROUP BY 1""")
actual = Dict(Int(r.h) => r.p for r in eachrow(ap))

# --- economic dispatch, price = balance dual ---
function dispatch(; ramp::Bool)
    m = Model(HiGHS.Optimizer); set_silent(m)
    N, H = length(gens), length(T)
    @variable(m, 0 <= p[1:N, 1:H])
    @variable(m, 0 <= short[1:H])            # load shedding, VOLL-priced
    for i in 1:N, t in 1:H
        set_upper_bound(p[i, t], gens[i].p_max)
    end
    @constraint(m, bal[t=1:H], sum(p[i, t] for i in 1:N) + short[t] == net[t])
    if ramp
        for i in 1:N
            ru = something(gens[i].ramp_up, 0.3) * gens[i].p_max    # MW/hour
            rd = something(gens[i].ramp_down, 0.3) * gens[i].p_max
            for t in 2:H
                @constraint(m, p[i, t] - p[i, t-1] <=  ru)
                @constraint(m, p[i, t] - p[i, t-1] >= -rd)
            end
        end
    end
    @objective(m, Min, sum(gens[i].marginal_cost * p[i, t] for i in 1:N, t in 1:H)
                       + 3000.0 * sum(short))          # VOLL
    optimize!(m)
    return Dict(T[t] => dual(bal[t]) for t in 1:H)
end

pr_ramp = dispatch(ramp=true)
pr_flat = dispatch(ramp=false)

# --- compare shapes to actual ---
hs = [h for h in T if haskey(actual, h)]
va = [actual[h] for h in hs]
vr = [pr_ramp[h] for h in hs]
vf = [pr_flat[h] for h in hs]
cor2(x, y) = (std(x) == 0 || std(y) == 0) ? NaN : cor(x, y)
mae(x, y) = mean(abs.(x .- y))
println("\nhour  actual  ED_flat  ED_ramp")
for (i, h) in enumerate(hs)
    @printf("  %2d   %6.1f  %6.1f  %6.1f\n", h, va[i], vf[i], vr[i])
end
@printf("\nED_flat (per-period): corr=%.3f  MAE=%.1f\n", cor2(vf, va), mae(vf, va))
@printf("ED_ramp (buildup/builddown): corr=%.3f  MAE=%.1f\n", cor2(vr, va), mae(vr, va))
