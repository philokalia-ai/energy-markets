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

# A hand-built single-zone MPCC (same rows as solve_mpcc_market_clearing) for the branches the
# market fixtures cannot reach. With all binaries fixed the price side and the primal side of the
# MPCC separate, so "fixed model OPTIMAL but below the welfare-LP bound" needs a row that couples a
# binary to primal variables: `extra=true` adds a_s2 ≥ 0.4 − 0.4·aux2_s2, which the welfare LP drops
# (it contains a binary). Orders: s1 50 MW @ 10, s2 50 MW @ 20 (supply), d 60 MW @ 3000 (demand).
function _lc_handbuilt(; extra::Bool=true)
    opt, _ = Euphemia.select_solver("highs")
    m = Model(opt); set_silent(m)
    ids = ["s1", "s2", "d"]
    q = Dict("s1" => 50.0, "s2" => 50.0, "d" => 60.0)
    b = Dict("s1" => 10.0, "s2" => 20.0, "d" => 3000.0)
    sup = Dict("s1" => true, "s2" => true, "d" => false)
    lo, hi = -500.0, 3000.0
    @variable(m, 0 <= stepwise_acceptance[ids] <= 1)
    @variable(m, stepwise_dual[ids] >= 0)
    @variable(m, market_price[["Z"]])
    @variable(m, stepwise_acceptance_complementarity_aux[ids], Bin)
    @variable(m, stepwise_dual_complementarity_aux[ids], Bin)
    @variable(m, load_shed >= 0)
    a, d, P = stepwise_acceptance, stepwise_dual, market_price["Z"]
    x1, x2 = stepwise_acceptance_complementarity_aux, stepwise_dual_complementarity_aux
    for o in ids
        qs = sup[o] ? -q[o] : q[o]
        rhs = @expression(m, d[o] + qs * P - qs * b[o])
        m1 = sup[o] ? q[o] * max(0.0, b[o] - lo) : q[o] * max(0.0, hi - b[o])
        ms = sup[o] ? q[o] * max(0.0, hi - b[o]) : q[o] * max(0.0, b[o] - lo)
        @constraint(m, rhs >= 0)
        @constraint(m, a[o] <= x1[o])
        @constraint(m, rhs <= (1 - x1[o]) * m1)
        @constraint(m, d[o] <= x2[o] * ms)
        @constraint(m, 1 - a[o] <= 1 - x2[o])
    end
    @constraint(m, lo <= P <= hi)
    @constraint(m, sum((sup[o] ? -q[o] : q[o]) * a[o] for o in ids) + load_shed == 0)
    extra && @constraint(m, a["s2"] + 0.4 * x2["s2"] >= 0.4)
    @objective(m, Max, sum((sup[o] ? -q[o] : q[o]) * b[o] * a[o] for o in ids) - 10000.0 * load_shed)
    return m, opt
end
_lc_fixed_binaries(m) = count(is_fixed, (v for nm in (:stepwise_acceptance_complementarity_aux,
                                                     :stepwise_dual_complementarity_aux) for v in m[nm]))

@testset "LP certificate: fallback branches (hand-built MPCC)" begin
    @testset "without the coupling row it certifies" begin
        m, opt = _lc_handbuilt(; extra=false)
        @test MPCC._lp_certify!(m, opt) == true
        @test objective_value(m) ≈ 179300.0                 # 3000·60 − 10·50 − 20·10
        @test value(m[:market_price]["Z"]) ≈ 20.0           # s2 partial pins the price
    end

    @testset "fixed model OPTIMAL but below the bound: falls back with the full-values start" begin
        m, opt = _lc_handbuilt()
        @test MPCC._lp_certify!(m, opt) == false            # welfare LP 179300, fixed pattern 79100
        @test _lc_fixed_binaries(m) == 0                    # pattern unfixed for the MIP
        @test start_value(m[:stepwise_acceptance]["s2"]) ≈ 0.4   # start = the fixed solve's values
        @test start_value(m[:load_shed]) ≈ 10.0
        optimize!(m)                                        # the fallback MIP, as solver.jl runs it
        @test termination_status(m) == MOI.OPTIMAL
        @test objective_value(m) ≈ 79100.0                  # 180000 − 500 − 400 − 10000·10
        @test value(m[:market_price]["Z"]) ≈ 20.0
    end

    @testset "an exception inside the certificate unfixes the pattern and lets the MIP run" begin
        m, _ = _lc_handbuilt()
        bad = () -> error("optimizer refused")              # e.g. a solver licence limit
        @test (@test_logs (:warn, r"LP certificate raised") match_mode=:any MPCC._lp_certify_guarded!(m, bad)) == false
        @test _lc_fixed_binaries(m) == 0
        for v in m[:stepwise_dual_complementarity_aux]      # a pattern left behind by a late throw
            fix(v, 1.0; force=true)
        end
        MPCC._unfix_pattern!(m)
        @test _lc_fixed_binaries(m) == 0
        optimize!(m)
        @test termination_status(m) == MOI.OPTIMAL
        @test objective_value(m) ≈ 79100.0
    end
end
