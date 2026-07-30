# Tests for the generated calibration table (bin/export_zone_strategies.jl).
#
# The table's whole claim is that it cannot drift from the model. These tests are
# what makes that claim enforceable rather than aspirational:
#   - every profile field has a plain-language description, so adding a field to
#     the struct without explaining it fails here instead of shipping an
#     unexplained column on the public page;
#   - the "strategy outside the profile" notes name symbols that still exist, so a
#     mechanism that moves or disappears breaks the test instead of quietly
#     turning the honesty section into fiction;
#   - grouping is on the resolved profile, not on a stringified projection.

using Test, Dates
using Euphemia
const _MO = Euphemia.MeritOrderBook

@testset "Zone-strategy export" begin

    @testset "every profile field is described — no second copy to drift" begin
        # FIELD_DESCRIPTIONS lives beside the struct in zone_profiles.jl, and BOTH
        # the exporter and this test read that one object. An earlier version of
        # this test duplicated the list, which meant the two could drift apart
        # while the test still passed — the exact failure the generated table
        # exists to prevent, reintroduced in its own guard.
        @test Set(keys(_MO.FIELD_DESCRIPTIONS)) == Set(fieldnames(_MO.ZoneProfile))
        @test all(!isempty(v) for v in values(_MO.FIELD_DESCRIPTIONS))
        # and the exporter must not carry its own copy
        src = read(joinpath(dirname(@__DIR__), "bin", "export_zone_strategies.jl"), String)
        @test occursin("MO.FIELD_DESCRIPTIONS", src)
        @test !occursin("const FIELD_DESCRIPTIONS", src)
    end

    @testset "the honesty section names things that exist" begin
        # "Strategy outside the profile" claims completeness; these keep the named
        # mechanisms real.
        @test isdefined(_MO, :FLEET_TRUTH_OVERRIDE)
        @test _MO.FLEET_TRUTH_OVERRIDE[] === nothing   # unset in a clean process
        @test isdefined(_MO, :NORDIC_FLOW_ZONES)
        @test isdefined(_MO, :BoundaryBook)
        # the kill-switch names the export enumerates
        for b in (_MO.VIKING_GB_BOOK, _MO.UA_BOOK_DEFAULT)
            @test startswith(b.disable_env, "EUPHEMIA_DISABLE_")
        end
    end

    @testset "grouping is on the profile, not on a stringified projection" begin
        zones = ["GR", "BG", "RO", "RS", "HU", "FR", "DK1"]
        groups = Dict{_MO.ZoneProfile,Vector{String}}()
        for z in zones
            push!(get!(groups, _MO.get_zone_profile(z), String[]), z)
        end
        # GR/BG share the base profile; RO/HU share the import-backed one with the
        # UA book; RS has it without; FR and DK1 are each their own.
        @test haskey(groups, _MO.get_zone_profile("GR"))
        @test sort(groups[_MO.get_zone_profile("GR")]) == ["BG", "GR"]
        @test sort(groups[_MO.get_zone_profile("RO")]) == ["HU", "RO"]
        # FR's and DK1's boundary books are materially different calibrations and
        # must NOT collapse together — the bug a stringified key reintroduces.
        @test _MO.get_zone_profile("FR") != _MO.get_zone_profile("DK1")
        @test _MO.get_zone_profile("FR").boundary_book !=
              _MO.get_zone_profile("DK1").boundary_book
    end

    @testset "the export does not write into the published staging tree" begin
        # bin/web_data_push.sh syncs ALL of data/web/v1 to the public bucket, so a
        # file staged there publishes itself on the next unrelated data push.
        src = read(joinpath(dirname(@__DIR__), "bin", "export_zone_strategies.jl"), String)
        @test occursin("ZONE_STRATEGIES_OUT", src)
        @test !occursin("WEB_PARQUET_OUT", src)
        @test occursin("data\", \"calibration\"", src)
    end
end
