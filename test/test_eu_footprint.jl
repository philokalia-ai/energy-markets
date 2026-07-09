# Tests for the EU-wide footprint aggregate/sub-zone dedup helper.
#
# The critical invariant: for the 5-zone SEE footprint (and any footprint
# without split-country sub-zones) the helper returns NOTHING, so the
# multi-zone merit order-book build is byte-identical to the pre-change path.

using Test
using Euphemia

@testset "shadowed_aggregate_codes" begin
    sac = Euphemia.shadowed_aggregate_codes

    @testset "5-zone SEE footprint is untouched (byte-identical guarantee)" begin
        @test sac(["GR", "BG", "RO", "RS", "HU"]) == String[]
    end

    @testset "single zone / empty" begin
        @test sac(["GR"]) == String[]
        @test sac(String[]) == String[]
    end

    @testset "Italy sub-zones present -> exclude aggregate IT" begin
        @test "IT" in sac(["GR", "IT-SOUTH"])
        @test "IT" in sac(["IT-NORTH", "IT-CNORTH", "IT-SOUTH"])
        # aggregate IT is never itself a footprint node here, so it is returned
        @test sac(["GR", "IT-SOUTH"]) == ["IT"]
    end

    @testset "Denmark sub-zones present -> exclude aggregate DK" begin
        @test "DK" in sac(["DE_LU", "DK1", "DK2"])
        @test "DK" in sac(["DK2"])
    end

    @testset "German bidding zone present -> exclude TSO control-area aliases" begin
        s = sac(["DE_LU", "FR"])
        for c in ("DE_50HzT", "DE_Amprion", "DE_TenneT_GER", "DE_TransnetBW")
            @test c in s
        end
        # DE_LU itself (a real node) must never be shadowed
        @test !("DE_LU" in s)
    end

    @testset "never shadow a code that is itself a footprint node" begin
        # contrived: if the aggregate IT were somehow also a node, do not exclude it
        @test !("IT" in sac(["IT", "IT-SOUTH"]))
    end

    @testset "full EU footprint" begin
        footprint = ["AT", "BE", "BG", "CZ", "DE_LU", "DK1", "DK2", "EE", "ES",
            "FI", "FR", "GR", "HU", "LT", "LV", "NL", "NO1", "NO2", "NO3", "NO4",
            "NO5", "PL", "PT", "RO", "RS", "SE1", "SE2", "SE3", "SE4", "SI", "SK",
            "IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
            "IT-Sicily", "IT-Sardinia"]
        s = sac(footprint)
        @test "IT" in s
        @test "DK" in s
        @test "DE_50HzT" in s
        # none of the returned shadows may be actual footprint nodes
        @test isempty(intersect(s, footprint))
    end
end
