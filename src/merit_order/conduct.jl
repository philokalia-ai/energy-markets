# conduct.jl — pluggable market conduct: how the simulated market prices its flexible supply from cost.
#
# Chosen by passing a value — `ZoneScenario(conduct=…)` (per zone via the Dict form) → `create_merit_order_book(...;
# conduct=…)`, threaded through both passes and the pipelined backfill — never by an env flag. A conduct implements:
#   conduct_day_factors(c, d::DayCtx) -> Vector{Float64}   one factor per timeslot of the zone-day
#   offers!(out, c, u::UnitCtx)                              append (order, strategy label) for one unit-timeslot
# Conducts must be defined inside the package (this file): the pipeline's Distributed book workers deserialize the
# scenario value.
#   TranchesConduct()    the default: the declared conduct layer (TRANCHES ladder × scarcity/peak factor), unchanged
#   CompetitiveConduct() every flexible MW at 1.0 × SRMC, factor ≡ 1 — the issue #367 ablation arm (it replaced the
#                        deleted EUPHEMIA_CONDUCT_LAYER=off switch)
#   ShapeConduct(alpha)  the ladder with level-neutral reshaped day factors (strategy round 2, experiment 2)

"""Root of all bidding strategies (market conduct here; company strategies in the strategy research harness)."""
abstract type BiddingStrategy end

"""How the simulated market prices supply from cost (book builder plug-in)."""
abstract type MarketConduct <: BiddingStrategy end

"""
    DayCtx(zone, day, timeslots, margin, norm_demand, scarcity_threshold, scarcity_kappa, peak_kappa, peak_exponent,
           profile)

Per zone-day inputs of the conduct factor, built once by `create_merit_order_book` (timeslot order = `timeslots`):
`margin[t]` = (dispatchable capacity + import credit + backstop credit) / net demand, `norm_demand[t]` = net demand's
within-day position (0 trough … 1 peak). The four parameters are the RESOLVED values (keyword overrides of
`create_merit_order_book` win over the profile).
"""
struct DayCtx{P}
    zone::String
    day::Date
    timeslots::Vector{String}
    margin::Vector{Float64}
    norm_demand::Vector{Float64}
    scarcity_threshold::Float64
    scarcity_kappa::Float64
    peak_kappa::Float64
    peak_exponent::Float64
    profile::P
end

"""
    UnitCtx(gmc, flexible_capacity, factor, nuc_ceil, zone, date_time, resolution_minutes, tranche_grading)

One unit in one timeslot: its marginal cost `gmc` (€/MWh, anchor-lifted for nuclear where applicable), the flexible
capacity left after its must-run blocks (MW), the day factor of this timeslot, the nuclear ceiling (`Inf` unless set),
the order fields and the profile's `tranche_grading`.
"""
struct UnitCtx
    gmc::Float64
    flexible_capacity::Float64
    factor::Float64
    nuc_ceil::Float64
    zone::Symbol
    date_time::DateTime
    resolution_minutes::Int
    tranche_grading::Int
end

"""conduct_day_factors(c, d::DayCtx) -> Vector{Float64}: one multiplicative factor per timeslot of `d.timeslots`."""
function conduct_day_factors end

"""offers!(out, c, u::UnitCtx) -> out: append the unit-timeslot's (SimpleOrder, label) offers to `out`."""
function offers! end

"""offers(c, u::UnitCtx) -> Vector{Tuple{SimpleOrder,String}} (allocating convenience form of `offers!`)."""
offers(c::MarketConduct, u::UnitCtx) = offers!(Tuple{SimpleOrder,String}[], c, u)

# ── default: the declared conduct layer ───────────────────────────────────────────────────────────────────────────
"""
    TranchesConduct()

The default conduct (the code before the plug-in, moved verbatim; byte-identical):
- factor_t = 1 + scarcity_kappa·max(0, scarcity_threshold − margin_t)² + peak_kappa·norm_demand_t^peak_exponent
  (`ZoneProfile` scarcity_* / peak_kappa, `PEAK_EXPONENT`);
- per unit: `TRANCHES` (share, multiplier) of the flexible capacity, tranche 1 at gmc × multiplier, tranches 2+ at
  gmc × multiplier × factor_t, each capped at the nuclear ceiling; cv36 grading: K = `tranche_grading` sub-slices with
  multipliers walking linearly from the previous tranche's; labels `srmc_base` / `peak_tranche_i`.
"""
struct TranchesConduct <: MarketConduct end

function conduct_day_factors(::TranchesConduct, d::DayCtx)
    f = Vector{Float64}(undef, length(d.timeslots))
    for t in eachindex(d.timeslots)
        margin = d.margin[t]; norm_demand = d.norm_demand[t]
        f[t] = 1.0 + d.scarcity_kappa * max(0.0, d.scarcity_threshold - margin)^2 +
                     d.peak_kappa * norm_demand^d.peak_exponent
    end
    return f
end

function offers!(out, ::TranchesConduct, u::UnitCtx)
    tranches = TRANCHES
    gmc = u.gmc; scarcity = u.factor; nuc_ceil = u.nuc_ceil
    for (i, (share, mult)) in enumerate(tranches)
        qty = u.flexible_capacity * share
        qty < 0.1 && continue
        K = (i == 1 || u.tranche_grading <= 1) ? 1 : u.tranche_grading
        mult_lo = K == 1 ? mult : tranches[i-1][2]
        for j in 1:K
            m_j = K == 1 ? mult : mult_lo + (mult - mult_lo) * j / K
            price = min(gmc * m_j * (i == 1 ? 1.0 : scarcity), nuc_ceil)
            push!(out, (SimpleOrder(:supply, price, qty / K, u.zone, u.date_time, u.resolution_minutes),
                        i == 1 ? "srmc_base" : "peak_tranche_$i"))
        end
    end
    return out
end

# ── competitive: the #367 ablation arm ────────────────────────────────────────────────────────────────────────────
"""
    CompetitiveConduct()

Every flexible MW offered at 1.0 × gmc (capped at the nuclear ceiling), factor ≡ 1, label `srmc_base` — the issue #367
ablation arm, exactly what the deleted `EUPHEMIA_CONDUCT_LAYER=off` switch produced (one tranche (1.0, 1.0)). A
measurement arm, never a claim about the true competitive price.
"""
struct CompetitiveConduct <: MarketConduct end

conduct_day_factors(::CompetitiveConduct, d::DayCtx) = ones(Float64, length(d.timeslots))

function offers!(out, ::CompetitiveConduct, u::UnitCtx)
    qty = u.flexible_capacity * 1.0
    qty < 0.1 && return out
    push!(out, (SimpleOrder(:supply, min(u.gmc * 1.0 * 1.0, u.nuc_ceil), qty / 1, u.zone, u.date_time,
                            u.resolution_minutes), "srmc_base"))
    return out
end

# ── shape: level-neutral reshape of the day factors (strategy round 2, experiment 2) ──────────────────────────────
"""
Alpha of `ShapeConduct()` (strategy round 2, experiment 2; not the default): chosen on the 12 calibration days
(`strategy/days_cal.txt`, 2026-01-06 … 06-20) from {0, 0.25, 0.5, 0.75, 1} by physics-only MAE, 96-step clear,
main 5fa39e1 + this plug-in (strategy-st-impact 969eeb9, 2026-11-24): MAE 21.798 (alpha 1 = TranchesConduct),
21.762 (0.75), 21.679 (0.5), 21.543 (0.25), 21.486 (0) €/MWh. Held-out result and caveats: docs/code-version-ledger.md
(note under cv46).
"""
const SHAPE_CONDUCT_ALPHA = 0.0

"""
    ShapeConduct(alpha = SHAPE_CONDUCT_ALPHA)

Keeps `TranchesConduct`'s ladder and reshapes its day factors level-neutrally:

    f'_t = mean_d(f) + alpha · (f_t − mean_d(f)),   f = conduct_day_factors(TranchesConduct(), d)

The zone-day mean of the factor is conserved exactly (pre-clear; the clearing-price level is NOT held: flattening lowers
peaks more than it lifts troughs set by supply the factor does not touch). `alpha = 1` is `TranchesConduct`;
`alpha = 0` spreads the day's markup evenly over its timeslots; `alpha < 0` would invert the day's shape.
"""
struct ShapeConduct <: MarketConduct
    alpha::Float64
end
ShapeConduct() = ShapeConduct(SHAPE_CONDUCT_ALPHA)

function conduct_day_factors(c::ShapeConduct, d::DayCtx)
    f = conduct_day_factors(TranchesConduct(), d)
    isempty(f) && return f
    m = sum(f) / length(f)
    return [m + c.alpha * (x - m) for x in f]
end

offers!(out, ::ShapeConduct, u::UnitCtx) = offers!(out, TranchesConduct(), u)
