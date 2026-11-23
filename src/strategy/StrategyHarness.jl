# StrategyHarness.jl — the shared harness of the strategy research (branch `strategy`; st-orch).
#
# Standalone: NOT included from src/Euphemia.jl, so the production forecast path is untouched.
# Load with
#     using Euphemia
#     include(joinpath(pkgdir(Euphemia), "src", "strategy", "StrategyHarness.jl")); using .StrategyHarness
#
# What it does (design: ~/armada/em-team/strategy/DESIGN.md §1):
#   build_baseline(day)            the final (pass-2) 39-zone book of day D + our forecast prices, built exactly as the
#                                  record pipeline builds it (as_of=:gate, 2 passes, HiGHS, per-period decomposition)
#   load_baseline(day)             cached BaselineDay (book, prices, realised SDAC for scoring only)
#   reclear(base, company; carve)  re-clear the book with the company's orders added (and a carve-out of equivalent
#                                  baseline supply removed); prices for all zones, the company's accepted volumes and
#                                  accepted blocks
#   residual_demand(base, zone)    the zone's price per period when the company sells q MW price-taking (q<0 buys)
#   pricetaker_accept / pnl        acceptance + profit at given prices (realised = the price-taker score)
#
# Short-run assumptions (state them in every report): the other players' orders are the baseline book; the pass-2
# opportunity anchors (FR nuclear, Nordic/alpine hydro) keep their baseline references when the company moves prices.
module StrategyHarness

using Euphemia, Dates, Serialization, Printf
using Euphemia.MPCC: MPCCOrderBook, MPCCResult
using Euphemia.MarketOrders: MarketOrder, SimpleOrder, LinkedHourlyOrder

export FOOTPRINT, STUDY_ZONES, BaselineDay, build_baseline, load_baseline, baseline_path,
       Carve, ReclearResult, reclear, apply_carve, residual_demand, rd_slope,
       period_hour, period_of, pricetaker_accept, pnl, load_realised, company_book

const FOOTPRINT = String[
    "AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES", "FI", "FR", "GR", "HU", "LT",
    "LV", "NL", "NO1", "NO2", "NO3", "NO4", "NO5", "PL", "PT", "RO", "RS", "SE1", "SE2", "SE3",
    "SE4", "SI", "SK", "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
    "IT-Sicily", "IT-Sardinia", "CH"]          # = cv46 record_day.jl
const STUDY_ZONES = ["GR", "IT-SOUTH", "DE_LU", "FR", "NO2", "ES"]   # strategy/days.md
const ROOT = joinpath(homedir(), "armada", "em-team", "strategy")
const CACHE = Ref(joinpath(ROOT, "runs", "baseline"))
const RD_CACHE = Ref(joinpath(ROOT, "runs", "rd"))   # workers: set StrategyHarness.RD_CACHE[] to runs/<you>/rd
const REALISED_CSV = Ref(joinpath(ROOT, "data", "sdac", "realised_hourly.csv"))

struct BaselineDay
    day::Date
    book::MPCCOrderBook                        # final book (pass 2 if accepted, else pass 1)
    prices::Dict{String,Dict{String,Float64}}  # our forecast: zone => period => €/MWh
    pass::Int
    meta::Dict{String,Any}                     # commit, env, timings, statuses
end

baseline_path(day::Date) = joinpath(CACHE[], "$(day).jls")

# periods: the multi-zone book uses timeslot ids "yyyymmdd-HHMM" (UTC start) at 24 and 96 steps; "1".."24" elsewhere.
period_hour(p::AbstractString) = occursin('-', p) ? parse(Int, p[10:11]) : parse(Int, p) - 1
period_of(book::MPCCOrderBook, dt::DateTime) = Euphemia.MPCC.extract_time_period(dt, book.periods)

_usable(r) = r.status == :optimal || (r.status == :time_limit && !isempty(r.market_prices))

"""
    build_baseline(day; save=true) -> BaselineDay

The record pipeline's day (src/PipelinedBackfill.jl pass1/pass2 jobs), run sequentially in this process. Uses the
process env for every knob (the runner sets the cv46 record env: EUPHEMIA_FLOW_ASOF_MODE=v2, DuckDB read-only).
"""
function build_baseline(day::Date; save::Bool=true, optimizer::String="highs", tagged::Bool=save)
    t0 = time()
    # Tagged-book capture (read-only sink, as the pipeline's books_dir): zone => [(order, owner_tag, strategy)];
    # pass 2 re-fires only the anchored zones and overwrites them, so the dict ends as the FINAL book's tags.
    tags = Dict{String,Vector{Tuple{SimpleOrder,String,String}}}()
    tl = ReentrantLock()
    sink_prev = Euphemia.MeritOrderBook.BOOK_SINK[]
    tagged && (Euphemia.MeritOrderBook.BOOK_SINK[] = function (zone, d, tg, res, strat)
        lock(tl) do
            tags[String(zone)] = [(tg[i][1], tg[i][2], String(strat[i])) for i in eachindex(tg)]
        end
    end)
    try
    ctx() = Euphemia.gate_context(day)
    ob1 = Euphemia.with_context(ctx()) do
        mz_build_books(FOOTPRINT, day; enrich_network=true, apply_zone_profiles=true)
    end
    tb1 = time() - t0
    r1 = mz_solve_pass(ob1; optimizer=optimizer, silent=true, decompose_periods=true)
    _usable(r1) || error("baseline $day: pass-1 solve unusable ($(r1.status))")
    ai = mz_extract_anchor_inputs(ob1, r1; apply_zone_profiles=true)
    book, res, pass = ob1, r1, 1
    tb2 = 0.0
    if !isempty(ai.anchored)
        t2 = time()
        ob2 = Euphemia.with_context(ctx()) do
            mz_rebuild_anchored(FOOTPRINT, day, ai.refs, ai.cached; transfer_capacity=ai.network,
                enrich_network=true, apply_zone_profiles=true)
        end
        tb2 = time() - t2
        r2 = mz_solve_pass(ob2; optimizer=optimizer, silent=true, decompose_periods=true)
        # the pipeline keeps ob2 even when it falls back to r1; we keep the pair that produced the prices
        if _usable(r2)
            book, res, pass = ob2, r2, 2
        else
            @warn "baseline $day: pass 2 unusable ($(r2.status)) — keeping pass 1"
        end
    end
    commit = try
        readchomp(`git -C $(pkgdir(Euphemia)) rev-parse --short HEAD`)
    catch
        "unknown"
    end
    meta = Dict{String,Any}("commit" => commit, "built_utc" => string(now(UTC)), "wall_s" => time() - t0,
        "book1_s" => tb1, "book2_s" => tb2, "anchored" => ai.anchored, "status" => string(res.status),
        "env" => sort([k => v for (k, v) in ENV if startswith(k, "EUPHEMIA_")]),
        "n_orders" => length(book.orders))
    b = BaselineDay(day, book, res.market_prices, pass, meta)
    if save && tagged
        mkpath(CACHE[])
        tp = joinpath(CACHE[], "$(day).tagged.csv.gz")
        open(pipeline(`gzip -c`; stdout=tp * ".tmp"), "w") do io
            println(io, "zone,date_time_utc,resolution,type,price,quantity,owner_tag,strategy")
            for z in sort(collect(keys(tags))), (o, tag, st) in tags[z]
                @printf(io, "%s,%s,%d,%s,%.6f,%.6f,%s,%s\n", z, o.date_time, o.resolution_code, o.type, o.price,
                    o.quantity, replace(tag, ',' => ';'), replace(st, ',' => ';'))
            end
        end
        mv(tp * ".tmp", tp; force=true)
    end
    if save
        mkpath(CACHE[])
        tmp = baseline_path(day) * ".tmp"
        serialize(tmp, b)
        mv(tmp, baseline_path(day); force=true)
        open(joinpath(CACHE[], "$(day).prices.csv"), "w") do io
            println(io, "zone,period,hour_utc,price")
            for z in sort(collect(keys(b.prices))), (p, v) in sort(collect(b.prices[z]); by=x -> period_hour(x[1]))
                @printf(io, "%s,%s,%d,%.6f\n", z, p, period_hour(p), v)
            end
        end
    end
    return b
    finally
        tagged && (Euphemia.MeritOrderBook.BOOK_SINK[] = sink_prev)
    end
end

"""load_baseline(day) -> BaselineDay (from the shared cache; never rebuilds)."""
function load_baseline(day::Date)
    p = baseline_path(day)
    isfile(p) || error("no baseline for $day at $p (st-orch builds them; see strategy/STATUS.md)")
    return deserialize(p)
end

"""
    load_realised(day) -> zone => period => €/MWh  (SDAC; SCORING ONLY — never an input to a strategy for `day`)
Keyed like the book's periods: timeslot ids "yyyymmdd-HHMM" of the UTC hour (the 24-step book uses these), or
"1".."24" with `hourly_ids=true`.
"""
function load_realised(day::Date; path::AbstractString=REALISED_CSV[], hourly_ids::Bool=false)
    out = Dict{String,Dict{String,Float64}}()
    pre = string(day)
    for (i, l) in enumerate(eachline(path))
        i == 1 && continue
        z, t, p = split(l, ',')
        startswith(t, pre) || continue
        h = parse(Int, t[12:13])
        key = hourly_ids ? string(h + 1) : Dates.format(DateTime(day) + Hour(h), dateformat"yyyymmdd-HHMM")
        get!(out, String(z), Dict{String,Float64}())[key] = parse(Float64, p)
    end
    return out
end

# ───────────────────────────── carve-out ─────────────────────────────
"""
    Carve(zone, mw, price_lo, price_hi; ref=(lo+hi)/2)

NB the book merges supply orders at round(price, 2) (book_build.jl:2253): express the band on rounded prices
and check `r.carve_shortfall` is empty (st-impact, 21:15Z).
Remove `mw` (a number, or period => MW) of baseline SUPPLY SimpleOrders in `zone` priced in [price_lo, price_hi],
closest to `ref` first. Models the company's asset replacing equivalent capacity already in the forecast.
"""
struct Carve
    zone::String
    mw::Union{Float64,Dict{String,Float64}}
    price_lo::Float64
    price_hi::Float64
    ref::Float64
end
Carve(zone, mw, lo, hi; ref=(lo + hi) / 2) = Carve(String(zone), mw isa Number ? Float64(mw) : mw, lo, hi, ref)

_carve_mw(c::Carve, p::String) = c.mw isa Float64 ? c.mw : get(c.mw, p, 0.0)

"""apply_carve(book, carves) -> (orders::Vector{MarketOrder}, shortfall::Dict{(zone,period)=>MW})"""
function apply_carve(book::MPCCOrderBook, carves::Vector{Carve})
    orders = copy(book.orders)
    short = Dict{Tuple{String,String},Float64}()
    isempty(carves) && return orders, short
    for c in carves
        # candidate indices per period
        cand = Dict{String,Vector{Int}}()
        for (i, o) in enumerate(orders)
            o isa SimpleOrder || continue
            (o.type == :supply && string(o.zone) == c.zone && c.price_lo <= o.price <= c.price_hi) || continue
            p = period_of(book, o.date_time)
            push!(get!(cand, p, Int[]), i)
        end
        for p in book.periods
            need = _carve_mw(c, p)
            need <= 0 && continue
            idx = sort(get(cand, p, Int[]); by=i -> (abs(orders[i].price - c.ref), orders[i].price, i))
            for i in idx
                need <= 1e-9 && break
                o = orders[i]
                take = min(o.quantity, need)
                need -= take
                orders[i] = SimpleOrder(o.type, o.price, o.quantity - take, o.zone, o.date_time, o.resolution_code)
            end
            need > 1e-6 && (short[(c.zone, p)] = need)
        end
    end
    filter!(o -> !(o isa SimpleOrder) || o.quantity > 1e-9, orders)
    return orders, short
end

# ───────────────────────────── re-clear ─────────────────────────────
struct ReclearResult
    status::Symbol
    prices::Dict{String,Dict{String,Float64}}
    accepted::Vector{Float64}           # MW per company order (index = position in `company`; LinkedHourly: per member)
    ambiguous::Vector{Bool}             # tie at the order's price that the acceptance keys could not resolve uniquely
    blocks_accepted::Set{String}        # company block families accepted (BLK/BLKM/BLKL/BLKX); ratio in complex_info
    carve_shortfall::Dict{Tuple{String,String},Float64}
    flows::Dict{String,Dict{String,Float64}}
    solve_s::Float64
    complex_info::Any
end

"""company_book(base, company; carve, extra_injections) -> MPCCOrderBook (baseline − carve + company orders last)"""
function company_book(base::BaselineDay, company::AbstractVector{<:MarketOrder};
    carve::Vector{Carve}=Carve[], extra_injections::Dict{Tuple{String,String},Float64}=Dict{Tuple{String,String},Float64}())
    b = base.book
    orders, short = apply_carve(b, carve)
    append!(orders, company)
    inj = copy(b.fixed_injections)
    for (k, v) in extra_injections
        inj[k] = get(inj, k, 0.0) + v
    end
    return MPCCOrderBook(orders, b.nodes, b.periods, b.price_limits, b.network_topology, inj), short
end

_is_block(f::AbstractString) = startswith(f, "BLK:") || startswith(f, "BLKM:") || startswith(f, "BLKL:") ||
                               startswith(f, "BLKX:")

const _KEY_RE = r"^(.+)::order_\d+_z(.+)_h(\d+)_q(-?\d+)_p(-?\d+)$"

"""
    reclear(base, company; carve=Carve[], extra_injections=Dict(), optimizer="highs") -> ReclearResult

`extra_injections`: AVOID with storage families in the book (latent main bug, see residual_demand) — use price-taking orders.
Company orders may be `SimpleOrder`s and `LinkedHourlyOrder` families (`BLK:<name>:<zone>` blocks, storage budget
families). Accepted MW of a SimpleOrder: in the money → full, out → 0, at a tie → the solver's acceptance for the key
(zone, hour, round(q), round(p)) in that period, if unique; else pro-rata flagged `ambiguous`.
"""
function reclear(base::BaselineDay, company::AbstractVector{<:MarketOrder};
    carve::Vector{Carve}=Carve[], extra_injections::Dict{Tuple{String,String},Float64}=Dict{Tuple{String,String},Float64}(),
    optimizer::String="highs", tol::Float64=1e-4)
    # The master's `BLK:` path treats every member as supply (src/mpcc/complex_orders.jl; main builds supply-only
    # blocks). A company block with demand legs must be a signed `BLKL:<zone>:<name>` root (st-blocks, 144c2a3).
    for o in company
        o isa LinkedHourlyOrder && startswith(o.family, "BLK:") && o.type != :supply &&
            throw(ArgumentError("company BLK: family $(o.family) has a $(o.type) member; use BLKL:<zone>:<name> (signed)"))
    end
    book, short = company_book(base, company; carve=carve, extra_injections=extra_injections)
    Euphemia.MPCC.LAST_COMPLEX_INFO[] = nothing
    t0 = time()
    r = mz_solve_pass(book; optimizer=optimizer, silent=true, decompose_periods=true)
    el = time() - t0
    info = Euphemia.MPCC.LAST_COMPLEX_INFO[]
    # accepted blocks: info.blocks is a Dict family => (zone, price, [ratio,] slices); company BLK:/BLKM:/BLKL:/BLKX:
    blk = Set{String}()
    ratio = Dict{String,Float64}()
    if info !== nothing && hasproperty(info, :blocks)
        cf = Set(o.family for o in company if o isa LinkedHourlyOrder)
        for (f, b) in info.blocks
            fs = string(f)
            fs in cf || continue
            push!(blk, fs)
            ratio[fs] = hasproperty(b, :ratio) ? b.ratio : 1.0
        end
    end
    # solver acceptance index: (period, zone, hour, q, p) => [acceptance...]
    acc_idx = Dict{NTuple{5,String},Vector{Float64}}()
    for (k, a) in r.stepwise_acceptance
        m = match(_KEY_RE, k)
        m === nothing && continue
        push!(get!(acc_idx, (m[1], m[2], m[3], m[4], m[5]), Float64[]), a)
    end
    n = length(company)
    acc = zeros(n); amb = falses(n)
    fam_alloc = Dict{Tuple{String,DateTime},Float64}()
    if info !== nothing && hasproperty(info, :families)
        for (f, d) in info.families, (dt, q, a) in d["all"]
            fam_alloc[(f, dt)] = a
        end
    end
    for (i, o) in enumerate(company)
        o isa SimpleOrder || o isa LinkedHourlyOrder || continue
        p = period_of(book, o.date_time)
        P = get(get(r.market_prices, string(o.zone), Dict{String,Float64}()), p, NaN)
        isnan(P) && (acc[i] = NaN; continue)
        q = o.quantity
        if o isa LinkedHourlyOrder
            if _is_block(o.family)    # BLK: all-or-nothing; BLKM/BLKL/BLKX (st-blocks): ratio from the master
                acc[i] = o.family in blk ? q * ratio[o.family] : 0.0
                continue
            end
            q = get(fam_alloc, (o.family, o.date_time), q)   # storage: capped at the master allocation
        end
        inmoney = o.type == :supply ? P - o.price : o.price - P
        if inmoney > tol
            acc[i] = q
        elseif inmoney < -tol
            acc[i] = 0.0
        else
            key = (p, string(o.zone), string(Dates.hour(o.date_time)), string(round(Int, q)), string(round(Int, o.price)))
            v = get(acc_idx, key, Float64[])
            if length(v) == 1
                acc[i] = q * clamp(v[1], 0.0, 1.0)
            else
                acc[i] = isempty(v) ? 0.5q : q * clamp(sum(v) / length(v), 0.0, 1.0)
                amb[i] = true
            end
        end
    end
    return ReclearResult(r.status, r.market_prices, acc, amb, blk, short, r.transmission_flows, el, info)
end

# ───────────────────────────── residual demand ─────────────────────────────
"""
    residual_demand(base, zone; q_grid, carve=Carve[], cache=true) -> Dict(period => Vector{(q, price)})

The zone's clearing price per period when the company sells `q` MW price-taking (a fixed injection, all periods at
once; q < 0 = the company buys). One full re-clear per q. The baseline (q = 0, no carve) is the cached forecast.
"""
const DEFAULT_QGRID = [-2000.0, -1000.0, -500.0, -250.0, -100.0, 0.0, 100.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0]
function residual_demand(base::BaselineDay, zone::String; q_grid::Vector{Float64}=DEFAULT_QGRID,
    carve::Vector{Carve}=Carve[], cache::Bool=true, optimizer::String="highs")
    cp = joinpath(RD_CACHE[], "$(base.day)_$(zone)_$(hash((q_grid, [(c.zone, c.mw, c.price_lo, c.price_hi, c.ref) for c in carve]))).jls")
    cache && isfile(cp) && return deserialize(cp)
    out = Dict{String,Vector{Tuple{Float64,Float64}}}(p => Tuple{Float64,Float64}[] for p in base.book.periods)
    for q in sort(q_grid)
        if q == 0.0 && isempty(carve)
            pr = base.prices
        else
            # price-taking orders at the book's price limits (NOT fixed_injections: on main, a book with fixed
            # injections + storage families makes the complex-order master fail on an unimported
            # `add_to_constant!` and release the storage caps — latent on main, which never has both)
            lo, hi = base.book.price_limits
            day0 = DateTime(base.day)
            co = MarketOrder[q > 0 ? SimpleOrder(:supply, lo, q, Symbol(zone), _period_dt(base, p), _res(base)) :
                                     SimpleOrder(:demand, hi, -q, Symbol(zone), _period_dt(base, p), _res(base))
                             for p in base.book.periods]
            pr = reclear(base, co; carve=carve, optimizer=optimizer).prices
        end
        for p in base.book.periods
            v = get(get(pr, zone, Dict{String,Float64}()), p, NaN)
            push!(out[p], (q, v))
        end
    end
    if cache
        mkpath(dirname(cp))
        serialize(cp * ".tmp", out); mv(cp * ".tmp", cp; force=true)
    end
    return out
end

_res(base::BaselineDay) = length(base.book.periods) == 24 ? 60 : 15
_period_dt(base::BaselineDay, p::AbstractString) = occursin('-', p) ? DateTime(p, dateformat"yyyymmdd-HHMM") :
    DateTime(base.day) + Hour(parse(Int, p) - 1)

"""rd_slope(rd; dq=100) -> period => €/MWh per MW at q=0 (centred difference on the grid points nearest ±dq)."""
function rd_slope(rd::Dict{String,Vector{Tuple{Float64,Float64}}}; dq::Float64=100.0)
    out = Dict{String,Float64}()
    for (p, v) in rd
        qs = first.(v)
        lo = v[argmin(abs.(qs .+ dq))]; hi = v[argmin(abs.(qs .- dq))]
        out[p] = (hi[2] - lo[2]) / (hi[1] - lo[1])
    end
    return out
end

# ───────────────────────────── price-taker acceptance + P&L ─────────────────────────────
"""
    pricetaker_accept(company, prices, periods_of) -> Vector{Float64} MW

Acceptance of each company order AT GIVEN PRICES, price-taking (no effect on prices): simple orders in the money
(ties accepted); `BLK:` families accepted iff their day surplus Σ(P−b)·q·res/60 ≥ 0 (EUPHEMIA: no paradoxically
accepted block; a price-taker cannot be paradoxically rejected). Storage budget families: not handled here (they
need the asset's own dispatch optimisation — the workers' evaluators).
`periods_of(o)` maps an order to its period key in `prices`.
"""
function pricetaker_accept(company::AbstractVector{<:MarketOrder}, prices::Dict{String,Dict{String,Float64}}, periods_of::Function)
    acc = zeros(length(company))
    P(o) = get(get(prices, string(o.zone), Dict{String,Float64}()), periods_of(o), NaN)
    fam_surplus = Dict{String,Float64}()
    for o in company
        o isa LinkedHourlyOrder && startswith(o.family, "BLK:") || continue
        s = (o.type == :supply ? P(o) - o.price : o.price - P(o)) * o.quantity * o.resolution_code / 60
        fam_surplus[o.family] = get(fam_surplus, o.family, 0.0) + s
    end
    for (i, o) in enumerate(company)
        if o isa LinkedHourlyOrder && startswith(o.family, "BLK:")
            acc[i] = fam_surplus[o.family] >= 0 ? o.quantity : 0.0
        elseif o isa SimpleOrder
            x = P(o)
            acc[i] = isnan(x) ? NaN : ((o.type == :supply ? x >= o.price : x <= o.price) ? o.quantity : 0.0)
        else
            acc[i] = NaN
        end
    end
    return acc
end

"""
    pnl(company, accepted_mw, prices, mc, periods_of; fixed=0.0) -> €

Σ sign·(P − mc_i)·MW_i·res/60 over company orders (supply sign +1: revenue − cost; demand: value − price with
mc_i = the buyer's value), minus `fixed` (start-up € etc., computed by the caller from the accepted schedule).
"""
function pnl(company::AbstractVector{<:MarketOrder}, accepted::AbstractVector{<:Real},
    prices::Dict{String,Dict{String,Float64}}, mc::AbstractVector{<:Real}, periods_of::Function; fixed::Real=0.0)
    s = 0.0
    for (i, o) in enumerate(company)
        a = accepted[i]
        (isnan(a) || a == 0) && continue
        x = get(get(prices, string(o.zone), Dict{String,Float64}()), periods_of(o), NaN)
        h = o.resolution_code / 60
        s += (o.type == :supply ? (x - mc[i]) : (mc[i] - x)) * a * h
    end
    return s - fixed
end

end # module
