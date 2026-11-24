# conduct_shape.jl — experiment 2 (round 2): a level-neutral reshape of the conduct day factors.
# Standalone plug-in file (not included from src/Euphemia.jl). Load with
#     using Euphemia; include(joinpath(pkgdir(Euphemia), "src", "strategy", "conduct_shape.jl"))
# and pass it as a value: ZoneScenario(conduct=ShapeConduct(0.5)).
using Euphemia, Statistics
import Euphemia: conduct_day_factors, offers!

"""
    ShapeConduct(alpha)

Keeps `TranchesConduct`'s ladder (tranche shares, multipliers, grading, labels) and reshapes its day factors:

    f'_t = mean_d(f) + alpha · (f_t − mean_d(f)),   f = conduct_day_factors(TranchesConduct(), d)

- **Level-neutral, pre-clear:** the zone-day mean of the factor is conserved exactly (the plug-in cannot see the
  clearing price; what it holds fixed is the day's average markup multiplier on the upper tranches). `alpha = 1` is
  today's conduct; `alpha = 0` spreads the day's markup evenly over its timeslots; `0 < alpha < 1` flattens the
  scarcity/peak peaks and lifts the troughs by the same total.
- **Why:** round 1 (st-impact §6) found that replacing the peaked ladder by a flat markup cut the intraday *shape*
  error in every zone and region (pooled −2.4 €/MWh) while moving the *level* the wrong way; holding the level and
  changing only the shape is the next test.
- **Parameter:** one global `alpha`, chosen on the 12 calibration days by physics-only MAE from {0, 0.25, 0.5, 0.75}
  (1 = the baseline); nothing chosen on evaluation or replication days.
- With the conduct layer off (`EUPHEMIA_CONDUCT_LAYER=off`) every factor is 1 and the reshape is the identity.
"""
struct ShapeConduct <: MarketConduct
    alpha::Float64
end

function conduct_day_factors(c::ShapeConduct, d::DayCtx)
    f = conduct_day_factors(TranchesConduct(), d)
    isempty(f) && return f
    m = mean(f)
    return [m + c.alpha * (x - m) for x in f]
end

offers!(out, ::ShapeConduct, u::UnitCtx) = offers!(out, TranchesConduct(), u)
