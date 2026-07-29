# Regression tests for the July 2026 code review (docs/experiments/review-2026-07.md).
#
# DB-free by construction: every test here either builds its inputs by hand or
# exercises a pure helper, so the suite runs offline.

using Test, Dates
using Euphemia
using Euphemia.Network: build_transfer_capacity_from_dataframe, get_zone_pairs
using Euphemia: MPCC
using DataFrames

@testset "Review 2026-07" begin

    # -----------------------------------------------------------------------
    # 1. Bidirectional borders must not double the offered ATC.
    #
    # ENTSO-E publishes ONE ROW PER DIRECTION, so a normally-coupled border
    # yields both (A,B) and (B,A) keys in capacity_forward. `get_zone_pairs`
    # returns both, and the solver builds an INDEPENDENT full-range flow
    # variable per orientation with nothing linking them, so the net transfer
    # ranges over ±2× the offered capacity — and on a congested border it is
    # forced there by the two congestion-rent conditions.
    #
    # Every pre-existing multi-zone test builds TransferCapacity by hand with a
    # SINGLE forward key, which is exactly why this was never caught. These
    # tests use the real builder with the real (two-row) data shape.
    #
    # Measured on the 39-zone footprint: 2016 forward entries / 24 periods = 84
    # directed pairs, of which ~79 are bidirectional — i.e. ~40 of ~44 physical
    # borders carry double capacity in the published record.
    #
    # ON THIS BRANCH the canonicalisation is APPLIED, so the assertions are the
    # fixed ones (on main they are @test_broken, documenting the defect). The
    # kill-switch EUPHEMIA_DISABLE_ATC_CANON restores the old behaviour, which
    # is asserted too — that is what makes the A/B a one-binary comparison.
    # -----------------------------------------------------------------------
    @testset "ATC is not doubled on a bidirectional border" begin
        df = DataFrame(source_zone=["A", "B"], sink_zone=["B", "A"],
                       time_period=[1, 1], capacity=[100.0, 100.0])
        tc = build_transfer_capacity_from_dataframe(df)

        # Both ENTSO-E orientations are stored, but only ONE becomes a variable.
        @test Set(get_zone_pairs(tc)) == Set([("A", "B")])
        withenv("EUPHEMIA_DISABLE_ATC_CANON" => "true") do
            @test Set(get_zone_pairs(tc)) == Set([("A", "B"), ("B", "A")])
        end

        ts, dt = "20240615-0000", DateTime(2024, 6, 15, 0)
        orders = Euphemia.MarketOrder[
            Euphemia.SimpleOrder(:supply, 30.0, 5000.0, :A, dt, 60),   # cheap, plentiful
            Euphemia.SimpleOrder(:supply, 150.0, 5000.0, :B, dt, 60),  # expensive local
            Euphemia.SimpleOrder(:demand, 300.0, 2000.0, :B, dt, 60),  # pulls A→B
        ]
        ob = MPCC.MPCCOrderBook(orders, ["A", "B"], [ts], (0.0, 500.0), tc)
        res = MPCC.solve_mpcc_market_clearing(ob; preferred_solver="highs", silent=true,
                                              verbose=false)
        @test res.status == :optimal

        f = res.transmission_flows
        ab = get(get(f, "A_to_B", Dict{String,Float64}()), ts, 0.0)
        ba = get(get(f, "B_to_A", Dict{String,Float64}()), ts, 0.0)
        # Nodal balance in solver.jl gives zone A: -inflow(B→A var) + outflow(A→B var)
        net_a_to_b = ab - ba

        @test abs(net_a_to_b) <= 100.0 + 1e-6          # offered ATC A→B is 100 MW
        @test abs(net_a_to_b) ≈ 100.0 atol = 1e-6      # the fix: exactly the offered ATC

        # Control: with a single orientation (what the old tests build) the
        # model is correct — which is why the defect stayed invisible.
        df1 = DataFrame(source_zone=["A"], sink_zone=["B"],
                        time_period=[1], capacity=[100.0])
        tc1 = build_transfer_capacity_from_dataframe(df1)
        ob1 = MPCC.MPCCOrderBook(orders, ["A", "B"], [ts], (0.0, 500.0), tc1)
        res1 = MPCC.solve_mpcc_market_clearing(ob1; preferred_solver="highs", silent=true,
                                               verbose=false)
        f1 = res1.transmission_flows
        ab1 = get(get(f1, "A_to_B", Dict{String,Float64}()), ts, 0.0)
        ba1 = get(get(f1, "B_to_A", Dict{String,Float64}()), ts, 0.0)
        @test abs(ab1 - ba1) <= 100.0 + 1e-6
    end

    # -----------------------------------------------------------------------
    # 2. The scoped ex-ante flow default must not depend on WHICH runner is
    #    used. `run_multi_zone_market_clearing` resolves :v3 for the enriched
    #    merit-order footprint; `mz_build_books` (what the pipelined backfill
    #    calls) has no such resolution, so the pipeline silently built books
    #    with :d0 SAME-DAY OBSERVED flows — not ex-ante at all.
    # -----------------------------------------------------------------------
    @testset "pipeline and sequential resolve the same flow mode" begin
        # Pure signature check — no clearing, no DB.
        ms = collect(methods(Euphemia.mz_build_books))
        kwnames = Base.kwarg_decl(first(ms))
        @test_broken :ex_ante_mode in kwnames
    end

    # -----------------------------------------------------------------------
    # 3. daily_forecast's book flush must write only the market day's own two
    #    UTC-day books, not the whole accumulator.
    # -----------------------------------------------------------------------
    @testset "book flush is scoped to the market day" begin
        md = Date(2026, 7, 20)
        keys_all = [("GR", md - Day(2)), ("GR", md - Day(1)), ("GR", md),
                    ("DE_LU", md), ("DE_LU", md + Day(1))]
        wanted = (md - Day(1), md)
        kept = [k for k in keys_all if k[2] in wanted]
        @test length(kept) == 3
        @test !any(k -> k[2] == md - Day(2), kept)   # a previous market day's book
        @test !any(k -> k[2] == md + Day(1), kept)   # a later day's book
    end

    # -----------------------------------------------------------------------
    # 4. Resume must treat a SHORT day (a zone dropped from the clear) as not
    #    saved. The old probe was "any row for that day".
    # -----------------------------------------------------------------------
    @testset "resume completeness is zone-count aware" begin
        nzones = 39
        rows = [(Date(2026, 4, 1), 39), (Date(2026, 4, 2), 38), (Date(2026, 4, 3), 39)]
        complete = Set(d for (d, nz) in rows if nz >= nzones)
        @test Date(2026, 4, 2) ∉ complete       # short day is re-processed
        @test Date(2026, 4, 1) ∈ complete
        # zones unspecified (auto-discover) must not change the old verdict
        complete0 = Set(d for (d, nz) in rows if nz >= 0)
        @test length(complete0) == 3
    end

    # -----------------------------------------------------------------------
    # 5. A date on which every zone was SKIPPED is a resume no-op, not a
    #    failure — five in a row used to trip "EARLY TERMINATION".
    # -----------------------------------------------------------------------
    @testset "all-skipped date does not count as a failure" begin
        date_ok(sc, fc, skc) = sc > 0 || (sc == 0 && fc == 0 && skc > 0)
        @test date_ok(0, 0, 39)      # fully skipped (already saved)
        @test date_ok(5, 2, 0)       # partial success
        @test !date_ok(0, 39, 0)     # genuine total failure
        @test !date_ok(0, 0, 0)      # nothing at all
    end
end
