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

# Only `.type` and `.price` are read from an order, so a NamedTuple stands in.
_o(t, p) = (type=t, price=p)
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
    # PRESERVED DEFECTS — Phase 2 work. These tests assert TODAY's behaviour
    # so that fixing it is a deliberate test change, not a silent drift.
    # ---------------------------------------------------------------------

    @testset "DEFECT (phase 2): the sign-check fallback is period-WIDE" begin
        # C sits in its own isolated, perfectly consistent component, yet the
        # A–B violation discards C's reconstructed price too — the whole period
        # reverts to the solver's arbitrary bracket point.
        solver = Dict("A" => Dict("1" => 77.0), "B" => Dict("1" => 88.0),
                      "C" => Dict("1" => 999.0))
        r = _R(["A", "B", "C"], ["1"], [("A", "B")],
               _FK((("A", "B"), "1") => 100.0),
               Dict((("A", "B"), "1") => (100.0, 100.0)),
               Dict(("A", "1") => [1], ("B", "1") => [2], ("C", "1") => [3]),
               [_o(:supply, 90.0), _o(:supply, 10.0), _o(:supply, 55.0)],
               ["a", "b", "c"], Dict("a" => 0.5, "b" => 0.5, "c" => 0.5), _LIM, solver)
        @test r["C"]["1"] == 999.0          # SHOULD be 55.0 once scoped per component
    end

    @testset "DEFECT (phase 2): the marginal accumulator depends on order order" begin
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
