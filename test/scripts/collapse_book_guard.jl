# Offline integration check: default-off equality and RES-only MW preservation.
get(ENV, "EUPHEMIA_DUCKDB_READONLY", "") == "true" || error("Read-only source required")
using Euphemia, Dates, Test
const MOB = Euphemia.MeritOrderBook

function snapshot(flag)
    capture = Ref{Any}(nothing)
    MOB.BOOK_SINK[] = (zone, day, tagged, resolution, strategies) ->
        (capture[] = [(o.type, o.price, o.quantity, o.zone, o.date_time,
                       o.resolution_code, owner, strategy)
                      for ((o, owner), strategy) in zip(tagged, strategies)])
    result = withenv("EUPHEMIA_RES_OFFER_LADDER" => flag) do
        MOB.create_merit_order_book("GR", Date(2026, 11, 13);
            include_net_imports=false, target_resolution_minutes=60)
    end
    @test result.success
    return sort!(capture[]; by=string)
end

try
    unset, off, on = snapshot(nothing), snapshot("0"), snapshot("1")
    @test unset == off
    nonres(book) = filter(x -> x[7] != "RES", book)
    @test nonres(off) == nonres(on)
    res(book) = filter(x -> x[7] == "RES", book)
    @test sum(x[3] for x in res(off)) ≈ sum(x[3] for x in res(on))
    @test all(x -> x[2] == 0, res(on))
    @test !isempty(res(on))
    println("COLLAPSE_BOOK_GUARD_PASS default-off identical; non-RES orders identical; RES MW conserved")
finally
    MOB.BOOK_SINK[] = nothing
end
