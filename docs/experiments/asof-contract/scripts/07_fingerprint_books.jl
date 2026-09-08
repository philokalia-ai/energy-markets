using Euphemia, Dates
fp(r) = begin
    r.success || return (:FAILED, r.message)
    v = Float64[]
    for o in r.order_book.orders; push!(v, o.price, o.quantity); end
    (length(v), round(sum(v); digits=3), hash(round.(v; digits=9)))
end
for d in (Date(2026, 8, 20), Date(2025, 8, 20)), z in ("DE_LU", "GR", "NO4")
    println("IDENT ", d, " ", z, " ", fp(Euphemia.create_merit_order_book(z, d)))
end
tc = Euphemia.Network.tx_outage_caps(Date(2026, 8, 20))
println("IDENT txcaps 2026-08-20 ", length(tc), " ", round(sum(values(tc)); digits=3))
