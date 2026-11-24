# conduct.jl — pluggable market conduct (round 2; strategy/DESIGN-pluggable.md).
#
# How the simulated market prices its flexible supply from cost is a value passed in (`ZoneScenario(conduct=…)`
# → `create_merit_order_book(...; conduct=…)`), never an env flag. Two methods per conduct:
#   conduct_day_factors(c, d::DayCtx) -> Vector{Float64}   one factor per timeslot of the zone-day
#   offers!(out, c, u::UnitCtx)                              append (order, strategy label) for one unit-timeslot
# `TranchesConduct()` is the default and is today's code moved verbatim (same expressions, same float operation order,
# same labels, same EUPHEMIA_CONDUCT_LAYER=off behaviour). `CompetitiveConduct()` prices every flexible MW at 1.0 × SRMC
# with factor ≡ 1 (the plug-in equivalent of EUPHEMIA_CONDUCT_LAYER=off).
# Company strategies (research, src/strategy/) subtype `CompanyStrategy <: BiddingStrategy` in the strategy harness.

"""Root of all bidding strategies (market conduct and company strategies)."""
abstract type BiddingStrategy end

"""How the simulated market prices supply from cost (book builder plug-in)."""
abstract type MarketConduct <: BiddingStrategy end

"""
    DayCtx(zone, day, timeslots, margin, norm_demand, scarcity_threshold, scarcity_kappa, peak_kappa, peak_exponent,
           layer_on, profile)

Per zone-day inputs of the conduct factor, built once by `create_merit_order_book` (timeslot order = `timeslots`):
`margin[t]` = (dispatchable capacity + import credit + backstop credit) / net demand, `norm_demand[t]` = net demand's
within-day position (0 trough … 1 peak). The four parameters are the RESOLVED values (keyword overrides of
`create_merit_order_book` win over the profile). `layer_on` = `_conduct_layer_on()` read once per book.
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
    layer_on::Bool
    profile::P
end

"""
    UnitCtx(gmc, flexible_capacity, factor, nuc_ceil, zone, date_time, resolution_minutes, tranche_grading, layer_on)

One unit in one timeslot: its marginal cost `gmc` (€/MWh, anchor-lifted for nuclear where applicable), the flexible
capacity left after its must-run blocks (MW), the day factor of this timeslot, the nuclear ceiling (`Inf` unless set),
the order fields, the profile's `tranche_grading`, and `layer_on`.
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
    layer_on::Bool
end

"""conduct_day_factors(c, d::DayCtx) -> Vector{Float64}: one multiplicative factor per timeslot of `d.timeslots`."""
function conduct_day_factors end

"""offers!(out, c, u::UnitCtx) -> out: append the unit-timeslot's (SimpleOrder, label) offers to `out`."""
function offers! end

"""offers(c, u::UnitCtx) -> Vector{Tuple{SimpleOrder,String}} (allocating convenience form of `offers!`)."""
offers(c::MarketConduct, u::UnitCtx) = offers!(Tuple{SimpleOrder,String}[], c, u)

# ── default: today's TRANCHES ladder with the scarcity / peak factor ─────────────────────────────────────────────
"""
    TranchesConduct()

The default conduct (= the code before the plug-in, moved verbatim):
- factor_t = 1 + scarcity_kappa·max(0, scarcity_threshold − margin_t)² + peak_kappa·norm_demand_t^peak_exponent
  (1 when the conduct layer is off) — `ZoneProfile` scarcity_* / peak_kappa, `PEAK_EXPONENT`;
- per unit: `TRANCHES` (share, multiplier) of the flexible capacity, tranche 1 at gmc × multiplier, tranches 2+ at
  gmc × multiplier × factor_t, each capped at the nuclear ceiling; cv36 grading: K = `tranche_grading` sub-slices with
  multipliers walking linearly from the previous tranche's; labels `srmc_base` / `peak_tranche_i`;
  conduct layer off ⇒ one tranche (1.0, 1.0).
"""
struct TranchesConduct <: MarketConduct end

function conduct_day_factors(::TranchesConduct, d::DayCtx)
    f = Vector{Float64}(undef, length(d.timeslots))
    for t in eachindex(d.timeslots)
        margin = d.margin[t]; norm_demand = d.norm_demand[t]
        f[t] = d.layer_on ?
               1.0 + d.scarcity_kappa * max(0.0, d.scarcity_threshold - margin)^2 +
                     d.peak_kappa * norm_demand^d.peak_exponent :
               1.0
    end
    return f
end

function offers!(out, ::TranchesConduct, u::UnitCtx)
    tranches = u.layer_on ? TRANCHES : [(1.0, 1.0)]
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

# ── competitive: every flexible MW at its marginal cost ──────────────────────────────────────────────────────────
"""
    CompetitiveConduct()

Every flexible MW offered at 1.0 × gmc (capped at the nuclear ceiling), factor ≡ 1: the plug-in equivalent of
`EUPHEMIA_CONDUCT_LAYER=off` (one tranche (1.0, 1.0), label `srmc_base`).
"""
struct CompetitiveConduct <: MarketConduct end

conduct_day_factors(::CompetitiveConduct, d::DayCtx) = ones(Float64, length(d.timeslots))

function offers!(out, ::CompetitiveConduct, u::UnitCtx)
    qty = u.flexible_capacity
    qty < 0.1 && return out
    push!(out, (SimpleOrder(:supply, min(u.gmc * 1.0 * 1.0, u.nuc_ceil), qty, u.zone, u.date_time,
                            u.resolution_minutes), "srmc_base"))
    return out
end
