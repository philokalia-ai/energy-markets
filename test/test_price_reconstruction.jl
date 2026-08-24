# Unit tests for the competitive price reconstruction.
#
# This is the arithmetic that decides every published price. Until cv25 phase 1
# it could only execute behind a live MIP solve; now it is a pure function and
# these tests run DB-free and solver-free in well under a second.
#
# They pin the CURRENT semantics — including three defects that are deliberately
# preserved here and scheduled for Phase 2, each marked below. Locking them down
# before Phase 2 touches them is the point: a fix has to change a test on
# purpose, not by accident.

using Test
using Euphemia: MPCC

# The function returns (prices, fallback_periods) since the cv25 observability
# change; _R unwraps to prices, _Rfull keeps the tuple for the fallback tests.
const _Rfull = MPCC._reconstruct_component_prices
_R(args...) = _Rfull(args...).prices

# Only `.type`, `.price` and `.quantity` are read from an order, so a NamedTuple
# stands in (quantity defaults to a "large" 100 MW block).
_o(t, p; q=100.0) = (type=t, price=p, quantity=q)
const _FK = Dict{Tuple{Tuple{String,String},String},Float64}
const _LIM = (-500.0, 4000.0)
_solver(zones, periods, v) = Dict(z => Dict(p => v for p in periods) for z in zones)

@testset "Competitive price reconstruction" begin

    @testset "a marginal order pins the price to its bid" begin
        r = _R(["GR"], ["1"], Tuple{String,String}[], _FK(), Dict(),
               Dict(("GR", "1") => [1, 2]),
               [_o(:supply, 50.0), _o(:supply, 80.0)], ["a", "b"],
               Dict("a" => 1.0, "b" => 0.5), _LIM, _solver(["GR"], ["1"], 999.0))
        @test r["GR"]["1"] == 80.0          # the partially-accepted order, not the solver's 999
    end

    @testset "an orderless component is pinned to the floor, deterministically" begin
        r = _R(["GR"], ["1"], Tuple{String,String}[], _FK(), Dict(), Dict(),
               [], String[], Dict{String,Float64}(), _LIM, _solver(["GR"], ["1"], 999.0))
        @test r["GR"]["1"] == _LIM[1]
    end

    @testset "a zero-capacity link decouples and is exempt from the sign check" begin
        # flow pinned at 0 = both limits at once: the link cannot carry rent in
        # either direction, so the zones price independently and no sign check applies.
        r = _R(["A", "B"], ["1"], [("A", "B")],
               _FK((("A", "B"), "1") => 0.0),
               Dict((("A", "B"), "1") => (0.0, 0.0)),
               Dict(("A", "1") => [1], ("B", "1") => [2]),
               [_o(:supply, 20.0), _o(:supply, 90.0)], ["a", "b"],
               Dict("a" => 0.5, "b" => 0.5), _LIM,
               Dict("A" => Dict("1" => 7.0), "B" => Dict("1" => 8.0)))
        @test r["A"]["1"] == 20.0
        @test r["B"]["1"] == 90.0           # separated prices are legitimate here
    end

    @testset "a rent-sign violation makes the period keep the solver's prices" begin
        # A (source) marginal at 90, B (sink) at 10, flow at the forward cap:
        # the sink's price may not fall below the source's, so the reconstruction
        # is rejected and the solver's coupling-consistent values stand.
        solver = Dict("A" => Dict("1" => 77.0), "B" => Dict("1" => 88.0))
        r = _R(["A", "B"], ["1"], [("A", "B")],
               _FK((("A", "B"), "1") => 100.0),
               Dict((("A", "B"), "1") => (100.0, 100.0)),
               Dict(("A", "1") => [1], ("B", "1") => [2]),
               [_o(:supply, 90.0), _o(:supply, 10.0)], ["a", "b"],
               Dict("a" => 0.5, "b" => 0.5), _LIM, solver)
        @test r["A"]["1"] == 77.0
        @test r["B"]["1"] == 88.0
        # and the caller's dict is not mutated on the way
        @test solver["A"]["1"] == 77.0 && solver["B"]["1"] == 88.0
        # cv25 observability: the fallback is now countable
        full = _Rfull(["A", "B"], ["1"], [("A", "B")],
               _FK((("A", "B"), "1") => 100.0),
               Dict((("A", "B"), "1") => (100.0, 100.0)),
               Dict(("A", "1") => [1], ("B", "1") => [2]),
               [_o(:supply, 90.0), _o(:supply, 10.0)], ["a", "b"],
               Dict("a" => 0.5, "b" => 0.5), _LIM, solver)
        @test full.fallback_periods == ["1"]
    end

    # ---------------------------------------------------------------------
    # Fixed 2026-08-24 (bug sweep): the fallback is scoped per component and
    # unpinned components are propagated along binding links first.
    # ---------------------------------------------------------------------

    @testset "the sign-check fallback is scoped to the violating components" begin
        # C sits in its own isolated, perfectly consistent component; the A–B
        # violation (both pinned by marginal orders) no longer discards it.
        solver = Dict("A" => Dict("1" => 77.0), "B" => Dict("1" => 88.0),
                      "C" => Dict("1" => 999.0))
        full = _Rfull(["A", "B", "C"], ["1"], [("A", "B")],
               _FK((("A", "B"), "1") => 100.0),
               Dict((("A", "B"), "1") => (100.0, 100.0)),
               Dict(("A", "1") => [1], ("B", "1") => [2], ("C", "1") => [3]),
               [_o(:supply, 90.0), _o(:supply, 10.0), _o(:supply, 55.0)],
               ["a", "b", "c"], Dict("a" => 0.5, "b" => 0.5, "c" => 0.5), _LIM, solver)
        @test full.prices["C"]["1"] == 55.0
        @test full.prices["A"]["1"] == 77.0 && full.prices["B"]["1"] == 88.0
        @test full.fallback_periods == ["1"]
        @test full.fallback_cells == 2
    end

    @testset "an unpinned sink is raised into its bracket along a binding link" begin
        # A: accepted supply at 100, rejected at 105 -> bracket [100,105], no
        # marginal. B: accepted 50, rejected 120 -> [50,120]. Flow A->B at cap:
        # p_B >= p_A. The old code took lo for both (100 / 50), failed the sign
        # check and published the solver's values; the answer is B = 100.
        solver = Dict("A" => Dict("1" => 103.0), "B" => Dict("1" => 104.0))
        full = _Rfull(["A", "B"], ["1"], [("A", "B")],
               _FK((("A", "B"), "1") => 50.0),
               Dict((("A", "B"), "1") => (50.0, 50.0)),
               Dict(("A", "1") => [1, 2], ("B", "1") => [3, 4]),
               [_o(:supply, 100.0), _o(:supply, 105.0), _o(:supply, 50.0), _o(:supply, 120.0)],
               ["a1", "a2", "b1", "b2"],
               Dict("a1" => 1.0, "a2" => 0.0, "b1" => 1.0, "b2" => 0.0), _LIM, solver)
        @test full.prices["A"]["1"] == 100.0
        @test full.prices["B"]["1"] == 100.0
        @test isempty(full.fallback_periods)
    end

    @testset "acceptance is classified in MW, not as a fraction of the order" begin
        # 60 GW price-taker demand at the cap, 3 MW short: a = 1 - 5e-5 used to
        # read as "fully accepted" (relative 1e-4) and the hour was priced at the
        # top accepted supply (50) instead of the model's scarcity price (3000).
        r = _R(["A"], ["1"], Tuple{String,String}[], _FK(), Dict(),
               Dict(("A", "1") => [1, 2]),
               [_o(:supply, 50.0; q=59_997.0), _o(:demand, 3000.0; q=60_000.0)], ["s", "d"],
               Dict("s" => 1.0, "d" => 59_997.0 / 60_000.0), _LIM, _solver(["A"], ["1"], 0.0))
        @test r["A"]["1"] == 3000.0
        # ...while sub-noise residue on a small order still reads as accepted
        r2 = _R(["A"], ["1"], Tuple{String,String}[], _FK(), Dict(),
               Dict(("A", "1") => [1, 2]),
               [_o(:supply, 50.0; q=100.0), _o(:supply, 80.0; q=100.0)], ["s", "t"],
               Dict("s" => 1 - 1e-6, "t" => 0.0), _LIM, _solver(["A"], ["1"], 0.0))
        @test r2["A"]["1"] == 50.0
    end

    @testset "a zero-size order cannot constrain the price" begin
        # A 0 MW supply "accepted" at 150 used to raise lo above the true
        # marginal (60) and the clamp then hid the inverted bracket.
        full = _Rfull(["A"], ["1"], Tuple{String,String}[], _FK(), Dict(),
               Dict(("A", "1") => [1, 2, 3]),
               [_o(:supply, 60.0), _o(:supply, 80.0), _o(:supply, 150.0; q=0.0)], ["a", "b", "z"],
               Dict("a" => 0.5, "b" => 0.0, "z" => 1.0), _LIM, _solver(["A"], ["1"], 0.0))
        @test full.prices["A"]["1"] == 60.0
        @test full.inconsistent_brackets == 0
    end

    @testset "an inverted bracket is counted, not hidden" begin
        full = _Rfull(["A"], ["1"], Tuple{String,String}[], _FK(), Dict(),
               Dict(("A", "1") => [1, 2]),
               [_o(:supply, 150.0), _o(:supply, 80.0)], ["a", "b"],
               Dict("a" => 1.0, "b" => 0.0), _LIM, _solver(["A"], ["1"], 0.0))
        @test full.inconsistent_brackets == 1
    end

    @testset "DEFECT (unreachable in an optimal clear): marginal accumulator depends on order order" begin
        # One component with a marginal SUPPLY at 60 and a marginal DEMAND at 40.
        # The accumulator is seeded by whichever is enumerated first and then
        # applies that side's max/min, so the published price is decided by book
        # assembly order rather than economics.
        mk(idx) = _R(["A"], ["1"], Tuple{String,String}[], _FK(), Dict(),
                     Dict(("A", "1") => idx),
                     [_o(:supply, 60.0), _o(:demand, 40.0)], ["s", "d"],
                     Dict("s" => 0.5, "d" => 0.5), _LIM, _solver(["A"], ["1"], 0.0))
        supply_first = mk([1, 2])["A"]["1"]
        demand_first = mk([2, 1])["A"]["1"]
        @test supply_first != demand_first
        @test Set([supply_first, demand_first]) == Set([60.0, 40.0])
    end
end
