# pricetaker.jl — included by formats.jl inside `module StrategyFormats`.
#
# evaluate(asset, orders, P, day; res) applies EUPHEMIA's acceptance rules to the company's orders at the given
# prices P (one zone, one value per period of `res` minutes; realised SDAC for the price-taker score):
#   simple order:  supply accepted iff P ≥ price, demand iff P ≤ price (at the money: accepted);
#   BLK:           accepted iff its surplus Σ s_j (P_t − p_j) q_j dt ≥ 0;
#   BLKM:          surplus is linear in the ratio ⇒ ratio 1 iff surplus ≥ 0 (a price-taker never sits at the MAR);
#   BLKX:          the group's member with the highest surplus, if ≥ 0 (welfare-best member);
#   BLKL:          tree rule: value(f) = S_f + Σ_children max(0, value(c)); a root is accepted iff value ≥ 0, then
#                  each child of an accepted block iff its value ≥ 0 (children may pay for a parent; a child is
#                  never accepted without its parent). This is the welfare optimum of the family at fixed prices
#                  and every accepted block's subtree is in the money.
# A price-taker cannot be paradoxically rejected; "rejected" = out of the money at its own bid price.
#
# Then the physical settlement: the sold schedule x_t is turned into a feasible dispatch by a fixed MINIMAL repair
# rule (not optimised on the prices), the deviation is re-traded at the DA price of the period (an intraday proxy)
# plus `pen` €/MWh, and true costs are charged (SRMC per MWh, start-up € per start, water value, ...).
# Hourly orders evaluated on quarter-hour prices (res_P = 15) are 60-min products: one volume for the 4 quarters,
# in the money on the hour's mean price, settled quarter by quarter (= at the mean).

"""Map each order to the price periods it covers (indices into P with period length `res`)."""
function _cover(o, day::Date, res::Int)
    off = Dates.value(Minute(o.date_time - DateTime(day)))
    i0 = off ÷ res + 1
    n = max(1, o.resolution_code ÷ res)
    return i0:(i0+n-1)
end

_side(o) = o.type == :supply ? 1.0 : -1.0

"""
    accept(orders, P, day; res) -> (ratio::Vector{Float64} per order, fam::Dict{family=>ratio}, S::Dict{family=>surplus})
"""
function accept(orders::AbstractVector{<:MarketOrder}, P::Vector{Float64}, day::Date; res::Int)
    n = length(orders); ratio = zeros(n)
    pe = [sum(P[_cover(o, day, res)]) / length(_cover(o, day, res)) for o in orders]
    S = Dict{String,Float64}(); members = Dict{String,Vector{Int}}()
    for (i, o) in enumerate(orders)
        if o isa SimpleOrder
            ratio[i] = (o.type == :supply ? pe[i] >= o.price : pe[i] <= o.price) ? 1.0 : 0.0
        elseif o isa LinkedHourlyOrder
            S[o.family] = get(S, o.family, 0.0) + _side(o) * (pe[i] - o.price) * o.quantity * o.resolution_code / 60
            push!(get!(members, o.family, Int[]), i)
        end
    end
    fam = Dict{String,Float64}(f => 0.0 for f in keys(S))
    groups = Dict{String,Vector{String}}(); kids = Dict{String,Vector{String}}(); byname = Dict{String,String}()
    for f in keys(S)
        pf = parse_family(f)
        pf.kind in (:BLKL,) && (byname[pf.zone * ":" * pf.name] = f)
    end
    for f in keys(S)
        pf = parse_family(f)
        if pf.kind in (:BLK, :BLKM)
            fam[f] = S[f] >= -1e-9 ? 1.0 : 0.0
        elseif pf.kind == :BLKX
            push!(get!(groups, pf.attrs["group"], String[]), f)
        elseif pf.kind == :BLKL
            par = get(pf.attrs, "parent", "")
            push!(get!(kids, isempty(par) ? "" : byname[pf.zone * ":" * par], String[]), f)
        else
            error("price-taker: family kind of $f not handled")
        end
    end
    for (_, fs) in groups
        b = argmax(f -> (S[f], f), fs)
        S[b] >= -1e-9 && (fam[b] = 1.0)
    end
    val = Dict{String,Float64}()
    value(f) = get!(val, f) do
        S[f] + sum((max(0.0, value(c)) for c in get(kids, f, String[])); init=0.0)
    end
    function take!(f)
        fam[f] = 1.0
        for c in get(kids, f, String[]); value(c) >= -1e-9 && take!(c); end
    end
    for r in get(kids, "", String[]); value(r) >= -1e-9 && take!(r); end
    for (f, ix) in members, i in ix; ratio[i] = fam[f]; end
    return ratio, fam, S
end

"""Net sold injection per price period (MW; supply +, demand −)."""
function sold(orders, ratio, T::Int, day::Date; res::Int)
    x = zeros(T)
    for (i, o) in enumerate(orders)
        ratio[i] == 0 && continue
        for t in _cover(o, day, res); x[t] += _side(o) * o.quantity * ratio[i]; end
    end
    return x
end

# ------------------------------------------------------------------------------------ physical settlement
"""Thermal minimal repair: on-periods = sold > 0 (output ≥ Pmin); gaps shorter than min_down are bridged at
Pmin; runs shorter than min_up are extended forward (backward at the day's end) at Pmin. One start per run
(the unit is off before the day starts)."""
function _thermal_phys(a::Thermal, x::Vector{Float64}, dt)
    T = length(x); on = x .> 1e-6; phys = copy(x)
    md = max(1, round(Int, a.min_down / dt)); mu = max(1, round(Int, a.min_up / dt))
    runs() = (r = UnitRange{Int}[]; t = 1; while t <= T
        if on[t]; s = t; while t <= T && on[t]; t += 1; end; push!(r, s:t-1) else t += 1 end
    end; r)
    R = runs()
    for k in 2:length(R)                         # bridge short gaps
        g = (last(R[k-1])+1):(first(R[k])-1)
        length(g) < md && (on[g] .= true)
    end
    for r in runs()                              # extend short runs
        need = mu - length(r); need <= 0 && continue
        e = last(r)
        while need > 0 && e < T; e += 1; on[e] = true; need -= 1; end
        s = first(r)
        while need > 0 && s > 1; s -= 1; on[s] = true; need -= 1; end
    end
    for t in 1:T
        phys[t] = on[t] ? clamp(x[t], a.pmin, a.pmax) : 0.0
    end
    return phys, length(runs())
end

"""Storage: deliver the sold schedule in time order as far as the state of charge allows (SoC 0 at the start);
energy left at the end is valued at `eod` €/MWh_stored."""
function _storage_phys(s::Storage, x::Vector{Float64}, dt)
    ec = sqrt(s.eta); ed = sqrt(s.eta); soc = 0.0; phys = zeros(length(x))
    for t in eachindex(x)
        if x[t] > 0
            d = min(x[t], s.p, soc * ed / dt); soc -= d * dt / ed; phys[t] = d
        elseif x[t] < 0
            c = min(-x[t], s.p, (s.e - soc) / (ec * dt)); soc += c * dt * ec; phys[t] = -c
        end
    end
    return phys, soc
end

"""
    evaluate(asset, orders, P, day; res, pen=0.0) -> NamedTuple

Price-taker result at prices `P` (the asset's zone). `profit` €/day (retailer: −procurement cost − value of lost
load); `rev` DA revenue; `dev_mwh` repaired (re-traded) MWh; `starts`; `fam` accepted families; `S` surpluses.
"""
function evaluate(a, orders::AbstractVector{<:MarketOrder}, P::Vector{Float64}, day::Date; res::Int, pen::Float64=0.0)
    ratio, fam, S = accept(orders, P, day; res=res)
    return settle(a, orders, ratio, P, day; res=res, pen=pen, fam=fam, S=S)
end

"""
    settle(asset, orders, ratio, P, day; res, pen=0.0) -> NamedTuple

Physical settlement of a GIVEN acceptance (`ratio` per order, e.g. from a re-clear) at prices `P`.
"""
function settle(a, orders::AbstractVector{<:MarketOrder}, ratio::AbstractVector{<:Real}, P::Vector{Float64}, day::Date;
                res::Int, pen::Float64=0.0, fam=Dict{String,Float64}(), S=Dict{String,Float64}())
    T = length(P); dt = res / 60
    x = sold(orders, ratio, T, day; res=res)
    rev = sum(P .* x) * dt
    extra = (starts=0, eod_mwh=0.0)
    if a isa Thermal
        phys, st = _thermal_phys(a, x, dt)
        cost = a.srmc * sum(phys) * dt + a.startup * st
        extra = (starts=st, eod_mwh=0.0)
    elseif a isa Storage
        phys, soc = _storage_phys(a, x, dt)
        eod = sum(P) / T * sqrt(a.eta)            # stored energy left: sold later at today's mean price
        cost = -soc * eod
        extra = (starts=0, eod_mwh=soc)
    elseif a isa Hydro
        phys = copy(x); left = a.e
        for t in sortperm(P; rev=true)            # budget: keep the best-priced sold periods, buy back the rest
            d = min(phys[t], max(left, 0.0) / dt); phys[t] = d; left -= d * dt
        end
        cost = a.wv * sum(phys) * dt
    elseif a isa PVBat
        pv = length(a.pv) == T ? a.pv : repeat(a.pv; inner=T ÷ length(a.pv))
        b, soc = _storage_phys(a.bat, x .- pv, dt)
        # charging beyond what is sold below PV is curtailed PV (free); discharge shortfalls are bought back
        phys = [x[t] - pv[t] < 0 ? x[t] : min(x[t], pv[t] + b[t]) for t in 1:T]
        cost = -soc * sum(P) / T * sqrt(a.bat.eta)
        extra = (starts=0, eod_mwh=soc)
    elseif a isa Flex
        L = length(a.load) == T ? a.load : repeat(a.load; inner=T ÷ length(a.load))
        firm = (1 - a.shift - a.curt) .* L
        curt_bought = zeros(T); shift_bought = zeros(T)
        for (i, o) in enumerate(orders)     # the curtailable tranche = the simple demand orders at WTP
            (ratio[i] > 0 && o isa SimpleOrder && o.type == :demand && o.price == a.wtp) || continue
            for t in _cover(o, day, res); curt_bought[t] += o.quantity * ratio[i]; end
        end
        bought = -x
        shift_bought = bought .- firm .- curt_bought
        Es = a.shift * sum(L) * dt
        short = Es - sum(shift_bought) * dt                      # >0: buy the rest on the nominal shape
        nom = a.shift .* L ./ sum(a.shift .* L)
        phys = copy(x)
        if short > 0
            phys .-= nom .* short ./ dt
        elseif short < 0                                          # over-bought: sold back on the bought periods
            phys .+= (shift_bought ./ sum(shift_bought)) .* (-short) ./ dt
        end
        lost = sum(a.curt .* L .- curt_bought) * dt               # curtailed MWh, valued at WTP
        cost = a.wtp * lost
    else
        error("evaluate: asset type $(typeof(a))")
    end
    dev = phys .- x
    idv = sum(P .* dev) * dt                       # re-traded at the DA price (intraday proxy)
    profit = rev + idv - pen * sum(abs.(dev)) * dt - cost
    return (profit=profit, rev=rev, cost=cost, dev_mwh=sum(abs.(dev)) * dt, sold_mwh=sum(abs.(x)) * dt,
            phys=phys, x=x, fam=fam, S=S, starts=extra.starts, eod_mwh=extra.eod_mwh)
end
