# LP certificate (src/mpcc/lp_certificate.jl): the MPCC is solved by two LPs when the welfare-LP
# dispatch admits consistent prices, and by the MIP (started from that pattern) when it does not.
# DB-free; the expected values were produced by the MIP-first clear at 8372669 (cv45) on the same
# fixtures, so "same prices" here means "same as before the certificate existed".
using Test, Dates
using Euphemia
using Euphemia: MPCC

const _LC_DT = DateTime(2026, 1, 1, 0)
const _LC_SLOT = "20260101-0000"
# Cheap A (50 MW @ 10, demand 20 @ cap), expensive B (50 MW @ 100, demand 40 @ cap).
_lc_book(tc) = MPCCOrderBook(MarketOrder[
        SimpleOrder(:supply, 10.0, 50.0, :A, _LC_DT, 60),
        SimpleOrder(:demand, 3000.0, 20.0, :A, _LC_DT, 60),
        SimpleOrder(:supply, 100.0, 50.0, :B, _LC_DT, 60),
        SimpleOrder(:demand, 3000.0, 40.0, :B, _LC_DT, 60)],
    ["A", "B"], [_LC_SLOT], (-500.0, 3000.0), tc)

function _lc_solve(tc)
    c0 = MPCC.LP_CERT_COUNTS[]
    r = solve_mpcc_market_clearing(_lc_book(tc); preferred_solver="highs", verbose=false)
    c1 = MPCC.LP_CERT_COUNTS[]
    return r, c1.certified - c0.certified, c1.fallback - c0.fallback
end

@testset "LP certificate" begin
    @testset "congested border: certified, no MIP" begin
        tc = TransferCapacity(["A", "B"], ["1"],
            Dict(("A", "B", "1") => 10.0), Dict(("A", "B", "1") => 10.0))
        r, ncert, nfall = _lc_solve(tc)
        @test (ncert, nfall) == (1, 0)
        @test r.status == :optimal
        @test r.objective_value == 176700.0                 # MIP-first: 176700.0
        @test r.market_prices["A"][_LC_SLOT] == 10.0        # MIP-first: 10.0
        @test r.market_prices["B"][_LC_SLOT] == 100.0       # MIP-first: 100.0
        @test isapprox(r.transmission_flows["A_to_B"][_LC_SLOT], 10.0; atol=1e-9)
    end

    @testset "net-position limit: pattern infeasible, MIP fallback, same prices" begin
        # The JAO hub limit caps A's exports at 10 MW while the ATC (100 MW) is not binding.
        # The welfare LP prices A at 10 and B at 100 across an interior link, which the MPCC
        # coupling row (equal prices on an uncongested link; NP rows are unpriced) forbids,
        # so the certificate must fail and the MIP must clear it.
        tc = TransferCapacity(["A", "B"], ["1"],
            Dict(("A", "B", "1") => 100.0), Dict(("A", "B", "1") => 100.0),
            Dict(("CORE", "A", "1") => (-10.0, 10.0)), Dict("CORE" => Set([("A", "B")])))
        r, ncert, nfall = _lc_solve(tc)
        @test (ncert, nfall) == (0, 1)
        @test r.status == :optimal
        @test r.objective_value == -23500.0                 # MIP-first: -23500.0
        @test r.market_prices["A"][_LC_SLOT] == 100.0       # MIP-first: 100.0
        @test r.market_prices["B"][_LC_SLOT] == 100.0       # MIP-first: 100.0
        @test isapprox(r.transmission_flows["A_to_B"][_LC_SLOT], 10.0; atol=1e-9)
    end

    @testset "decomposed day: one certificate per period" begin
        dts = [_LC_DT, _LC_DT + Hour(1)]
        slots = ["20260101-0000", "20260101-0100"]
        orders = MarketOrder[]
        for dt in dts
            push!(orders, SimpleOrder(:supply, 10.0, 50.0, :A, dt, 60),
                SimpleOrder(:demand, 3000.0, 20.0, :A, dt, 60),
                SimpleOrder(:supply, 100.0, 50.0, :B, dt, 60),
                SimpleOrder(:demand, 3000.0, 40.0, :B, dt, 60))
        end
        tc = TransferCapacity(["A", "B"], ["1", "2"],
            Dict(("A", "B", "1") => 10.0, ("A", "B", "2") => 10.0),
            Dict(("A", "B", "1") => 10.0, ("A", "B", "2") => 10.0))
        c0 = MPCC.LP_CERT_COUNTS[]
        r = solve_mpcc_market_clearing(MPCCOrderBook(orders, ["A", "B"], slots, (-500.0, 3000.0), tc);
            preferred_solver="highs", decompose_periods=true, verbose=false)
        c1 = MPCC.LP_CERT_COUNTS[]
        @test (c1.certified - c0.certified, c1.fallback - c0.fallback) == (2, 0)
        @test r.status == :optimal
        @test all(r.market_prices["A"][s] == 10.0 && r.market_prices["B"][s] == 100.0 for s in slots)
    end
end
