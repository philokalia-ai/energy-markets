# block_order_mip.jl — true valley BLOCK-ORDER clearing for the GR single-zone
# book, as a per-day welfare-max MIP (Gurobi) + EUPHEMIA-style price formation.
#
# Loaded by block_order_pilot.jl ONLY when EUPHEMIA_ENABLE_GRSQ_BLOCKS is set
# (owner directive 2026-08: the block path is Gurobi-gated and opt-in; nothing
# block-related runs without the switch). Requires JuMP + Gurobi to be loaded
# by the includer.
#
# Model
# -----
# Hourly-order variables x_s, y_d ∈ [0,1] (divisible), one binary z_u per
# fill-or-kill valley block (unit u's committed MW in EVERY valley period of
# the day). Balance per period p:
#     Σ_s Q_s x_s + Σ_{u: p∈valley} q_u z_u == Σ_d Q_d y_d
# Objective: max Σ_d P_d Q_d w_p y_d − Σ_s P_s Q_s w_p x_s
#                − Σ_u P_blk q_u (Σ_{p∈span} w_p) z_u
# (w_p = period length in hours, so welfare is in €, not €·slots).
#
# Price formation (the subtle part, documented per the brief):
# 1. Solve the MIP (MIPGap 1e-9 — prices come from the true optimum).
# 2. Fix the binaries at the incumbent, relax to an LP, take the balance duals
#    as period prices (supply == demand form, max objective: the dual is the
#    marginal welfare of one extra demanded MW — the clearing price; the sign
#    convention is verified empirically against the engine's own base prices
#    in the pilot's sanity arm).
# 3. PAB check: every ACCEPTED block whose volume-weighted average clearing
#    price over its span is below its limit (avg < P_blk − tol) is
#    paradoxically accepted (loss-making). Force-reject it (z_u = 0 cut) and
#    re-solve the MIP from step 1. Iterate to a fixpoint. Paradoxically
#    REJECTED blocks are allowed, as in real EUPHEMIA, and are reported.

const PAB_TOL = 1e-6

"""One hourly (divisible) order in period `p` (index into the period vector)."""
struct HOrder
    p::Int
    price::Float64
    qty::Float64
end

"""
A fill-or-kill valley block: `unit`, MW `q` in every period of `span`
(indices into the period vector), limit price `limit` (€/MWh).
"""
struct VBlock
    unit::String
    q::Float64
    span::Vector{Int}
    limit::Float64
end

"""
    clear_with_blocks(supply, demand, blocks, wp; env)

Clear the day. `supply`/`demand` are `Vector{HOrder}`, `blocks` a
`Vector{VBlock}`, `wp[p]` the period length in hours. Returns a NamedTuple:
`prices[p]` (€/MWh duals, sign as returned by JuMP — the pilot verifies/fixes
the sign), `z` (unit → 0/1 final), `banned` (units force-rejected as PABs),
`iterations`, `prb` (paradoxically rejected units at final prices),
`mip_times`, `lp_times`, `mip_gap`.
"""
function clear_with_blocks(supply::Vector{HOrder}, demand::Vector{HOrder},
                           blocks::Vector{VBlock}, wp::Vector{Float64};
                           env=GRB_ENV)
    nP = length(wp)
    nB = length(blocks)
    banned = Set{String}()
    mip_times = Float64[]; lp_times = Float64[]
    prices = zeros(nP); zval = Dict{String,Float64}(); gap = 0.0
    iterations = 0
    while true
        iterations += 1
        # ── MIP ──────────────────────────────────────────────────────────
        t0 = time()
        m = Model(() -> Gurobi.Optimizer(env))
        set_silent(m)
        set_optimizer_attribute(m, "MIPGap", 1e-9)
        @variable(m, 0 <= x[i=1:length(supply)] <= 1)
        @variable(m, 0 <= y[j=1:length(demand)] <= 1)
        @variable(m, z[b=1:nB], Bin)
        for (b, blk) in enumerate(blocks)
            blk.unit in banned && @constraint(m, z[b] == 0)
        end
        # balance LHS/RHS built by explicit accumulation (robust to empty
        # per-period order sets; also faster than filtered macro sums)
        net = [AffExpr(0.0) for _ in 1:nP]      # supply + blocks − demand
        obj = AffExpr(0.0)
        for (i, s) in enumerate(supply)
            add_to_expression!(net[s.p], s.qty, x[i])
            add_to_expression!(obj, -s.price * s.qty * wp[s.p], x[i])
        end
        for (j, d) in enumerate(demand)
            add_to_expression!(net[d.p], -d.qty, y[j])
            add_to_expression!(obj, d.price * d.qty * wp[d.p], y[j])
        end
        for (b, blk) in enumerate(blocks)
            wsum = sum(wp[p] for p in blk.span)
            add_to_expression!(obj, -blk.limit * blk.q * wsum, z[b])
            for p in blk.span
                add_to_expression!(net[p], blk.q, z[b])
            end
        end
        bal = [@constraint(m, net[p] == 0) for p in 1:nP]
        @objective(m, Max, obj)
        optimize!(m)
        termination_status(m) == MOI.OPTIMAL ||
            error("block MIP not optimal: $(termination_status(m))")
        push!(mip_times, time() - t0)
        gap = nB > 0 ? relative_gap(m) : 0.0
        zsol = [round(value(z[b])) for b in 1:nB]
        # ── LP price formation: fix binaries, take balance duals ─────────
        t0 = time()
        for b in 1:nB
            unset_binary(z[b]); fix(z[b], zsol[b]; force=true)
        end
        optimize!(m)
        termination_status(m) == MOI.OPTIMAL ||
            error("pricing LP not optimal: $(termination_status(m))")
        push!(lp_times, time() - t0)
        # dual is marginal welfare per MW of balance slack; the objective is
        # weighted by wp (hours per period), so €/MWh price = dual / wp
        prices = [dual(bal[p]) / wp[p] for p in 1:nP]
        zval = Dict(blocks[b].unit => zsol[b] for b in 1:nB)
        # ── PAB check on accepted blocks ─────────────────────────────────
        # NOTE on sign: the PAB test needs prices in €/MWh with the market
        # sign. JuMP's dual sign for == in a Max problem is fixed per
        # convention; the pilot detects it once (sanity arm) and passes it in
        # via `dual_sign` on subsequent calls — see keyword below.
        pabs = String[]
        for (b, blk) in enumerate(blocks)
            zsol[b] > 0.5 || continue
            avgp = _avg_price(prices, wp, blk.span) * DUAL_SIGN[]
            avgp < blk.limit - PAB_TOL && push!(pabs, blk.unit)
        end
        if isempty(pabs)
            prb = String[]
            for (b, blk) in enumerate(blocks)
                zsol[b] < 0.5 || continue
                avgp = _avg_price(prices, wp, blk.span) * DUAL_SIGN[]
                avgp > blk.limit + PAB_TOL && push!(prb, blk.unit)
            end
            return (prices=prices, z=zval, banned=sort(collect(banned)),
                    iterations=iterations, prb=prb,
                    mip_times=mip_times, lp_times=lp_times, mip_gap=gap)
        end
        union!(banned, pabs)
    end
end

"Volume-weighted average price over a block span (equal MW every period)."
_avg_price(prices, wp, span) =
    sum(prices[p] * wp[p] for p in span) / sum(wp[p] for p in span)

# Dual sign convention (+1 or −1), detected once by the pilot's sanity arm
# against the engine's own base prices, then applied to the PAB test.
const DUAL_SIGN = Ref(1.0)

"""
    lp_only_prices(supply, demand, wp; env)

Sanity arm: clear the UNMODIFIED hourly book (no blocks, no removal) as a pure
LP and return the balance duals (raw JuMP sign). Used to validate the
reconstruction against the engine's own base prices and to set DUAL_SIGN.
"""
function lp_only_prices(supply::Vector{HOrder}, demand::Vector{HOrder},
                        wp::Vector{Float64}; env=GRB_ENV)
    r = clear_with_blocks(supply, demand, VBlock[], wp; env=env)
    return r.prices
end
