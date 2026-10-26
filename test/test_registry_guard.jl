# test_registry_guard.jl — an empty unit-registry read must not pass silently
# (#390 §2, the Sicily attribution).
#
# On 2026-02-24 the cv39 backfill's registry query returned zero units for nine
# of the 39 zones at once. IT-Sicily's book was then built from aggregate fleet
# completion — 3 blocks instead of 13 units, ~1,150 MW dispatchable instead of
# 3,352 — its scarcity margin fell to 0.47, the multiplier rose to 4.78, and the
# marginal offer became an oil peak tranche at €932/MWh against a settled €148.
# Nothing in the run said so. These tests pin the guard that now says so.
#
# DB-dependent (the guard's whole job is to ask the database a second question).

using Test, Dates
using Euphemia

@testset "a zone with a fleet cannot read as empty" begin
    # IT-Sicily has registry rows on and around 2026-02-24, so an empty read for
    # that zone-day is a FAILED read and must throw rather than fall through.
    @test_throws ErrorException Euphemia._assert_registry_really_empty(
        "IT-Sicily", Date(2026, 2, 24))
    # ... and the message has to say what happened, not just that something did
    err = try
        Euphemia._assert_registry_really_empty("IT-Sicily", Date(2026, 2, 24))
        ""
    catch e
        sprint(showerror, e)
    end
    @test occursin("failed read", err)
    @test occursin("IT-Sicily", err)
end

@testset "a zone with no registry coverage is let through" begin
    # A zone that genuinely has no units (or none in the fortnight) is not an
    # error — it is what aggregate fleet completion exists for.
    @test Euphemia._assert_registry_really_empty("ZZZ-not-a-zone", Date(2026, 2, 24)) === nothing
end

@testset "the guard can be opted out of" begin
    withenv("EUPHEMIA_ALLOW_EMPTY_REGISTRY" => "1") do
        @test Euphemia._assert_registry_really_empty("IT-Sicily", Date(2026, 2, 24)) === nothing
    end
end

@testset "the real read for the attribution day is not empty" begin
    # The day itself, on current data: 13-15 units, not 0. The spike is not
    # reproducible once the registry reads correctly.
    gens = Euphemia.get_generators("IT-Sicily", Date(2026, 2, 24))
    @test length(gens) >= 5
    @test sum(g.p_max for g in gens) > 2000.0
end
