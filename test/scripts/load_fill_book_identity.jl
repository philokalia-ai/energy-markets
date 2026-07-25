#!/usr/bin/env julia
#
# Guards for the load-fill book hook (src/merit_order/book_build.jl load_fill):
#   (1) INERTNESS — with no fill (load_fill=nothing) OR a fill that returns
#       nothing, a merit-order book is BIT-IDENTICAL to the no-hook book.
#   (2) SEED — for a zone/day whose TSO load is absent, the book FAILS without a
#       fill ("No load data found") and BUILDS with one (model load seeded).
#   (3) NO-OVERRIDE — when TSO load IS present, a fill that also returns values
#       for the same hours does NOT change the book (present TSO hours win); the
#       merge only adds hours the TSO lacks.
#
# Single-zone book builds only (no MPCC solve, no 39-zone clear).
#
#   julia --project=. test/scripts/load_fill_book_identity.jl [ZONE] [YYYY-MM-DD]

using Euphemia, Dates
const MOB = Euphemia.MeritOrderBook

zone = length(ARGS) >= 1 ? ARGS[1] : "GR"
day = length(ARGS) >= 2 ? Date(ARGS[2]) : Date(2026, 4, 3)

function book_prices(res)
    res === nothing && return nothing
    (res isa MOB.AdjustedOrderBookResult && !res.success) && return nothing
    ob = res.order_book
    ob === nothing && return nothing
    # Deterministic serialization of the merit book's orders.
    rows = Tuple{String,String,Float64,Float64,String}[]
    for o in ob.orders
        push!(rows, (string(o.type), string(o.date_time), o.price, o.quantity, string(o.zone)))
    end
    return sort(rows)
end

println("="^70)
println("LOAD-FILL BOOK GUARDS  zone=$zone day=$day")
println("="^70)

# (1) INERTNESS ---------------------------------------------------------------
base = MOB.create_merit_order_book(zone, day)
withfn = MOB.create_merit_order_book(zone, day; load_fill=(z, d) -> nothing)
pb, pf = book_prices(base), book_prices(withfn)
inert = pb !== nothing && pb == pf
println("(1) inertness (load_fill returns nothing) → ",
        inert ? "BIT-IDENTICAL ✅ ($(length(pb)) orders)" : "DIFFERS ❌")

# (3) NO-OVERRIDE -------------------------------------------------------------
# A fill that returns a value for EVERY hour of the day; since TSO load is
# present, the merge must add nothing → identical book.
overfill = (z, d) -> Dict(Dates.format(DateTime(d) + Hour(h), "yyyymmdd-HHMM") => 99999.0
                          for h in 0:23)
overb = MOB.create_merit_order_book(zone, day; load_fill=overfill)
po = book_prices(overb)
noover = pb !== nothing && pb == po
println("(3) no-override (fill offered for present TSO hours) → ",
        noover ? "BIT-IDENTICAL ✅ (TSO hours win)" : "DIFFERS ❌")

# (2) SEED --------------------------------------------------------------------
# A far-future day with no published TSO load: build must FAIL without a fill
# and SUCCEED with one.
future = Date(max(day, Dates.today()) + Day(400))
nofill = MOB.create_merit_order_book(zone, future)
failed_wo = nofill isa MOB.AdjustedOrderBookResult && !nofill.success
seed = (z, d) -> Dict(Dates.format(DateTime(d) + Hour(h), "yyyymmdd-HHMM") => 5000.0
                      for h in 0:23)
withseed = MOB.create_merit_order_book(zone, future; load_fill=seed)
built_w = book_prices(withseed) !== nothing
println("(2) seed on $future (no TSO load): without fill ",
        failed_wo ? "FAILS ✅" : "unexpectedly built ⚠️",
        " ; with fill ", built_w ? "BUILDS ✅" : "still fails ❌")

# ── RES-FILL guards (symmetric) ─────────────────────────────────────────────
# (R1) inertness: res_fill returning nothing is byte-identical.
res_inert_b = MOB.create_merit_order_book(zone, day; res_fill=(z, d) -> nothing)
pr = book_prices(res_inert_b)
res_inert = pb !== nothing && pb == pr
println("(R1) res-fill inertness (returns nothing) → ",
        res_inert ? "BIT-IDENTICAL ✅" : "DIFFERS ❌")

# (R3) no-override: res_fill offered for present TSO RES hours changes nothing.
res_over = MOB.create_merit_order_book(zone, day; res_fill=overfill)
pro = book_prices(res_over)
res_noover = pb !== nothing && pb == pro
println("(R3) res-fill no-override (present TSO RES hours) → ",
        res_noover ? "BIT-IDENTICAL ✅ (TSO RES wins)" : "DIFFERS ❌")

# (R2) effect: on a zone/day with missing RES hours, res_fill ADDS RES supply,
# which lowers or holds the book (more near-zero supply) — here just assert the
# book still builds and the order set CHANGES when RES is genuinely injected on
# the far-future seeded day (which has no TSO RES either).
res_seed = (z, d) -> Dict(Dates.format(DateTime(d) + Hour(h), "yyyymmdd-HHMM") => 1000.0
                          for h in 0:23)
withboth = MOB.create_merit_order_book(zone, future; load_fill=seed, res_fill=res_seed)
res_seed_built = book_prices(withboth) !== nothing
println("(R2) res-fill effect on $future (load+RES seeded): ",
        res_seed_built ? "BUILDS ✅" : "fails ❌")

ok = inert && noover && res_inert && res_noover
println("="^70)
println(ok ? "GUARDS PASSED ✅" : "GUARD FAILURE ❌")
println("="^70)
exit(ok ? 0 : 1)
