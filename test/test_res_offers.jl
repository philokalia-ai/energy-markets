using Test
include(joinpath(@__DIR__, "..", "src", "merit_order", "res_offers.jl"))

@testset "Ex-ante RES offer ladder" begin
    @test res_offer_tranches(100, RESOfferPolicy()) == [(0.0, 100.0, "res_zero_cost")]
    ladder = res_offer_tranches(100, RESOfferPolicy(; supported_share=0.3, support_eur_mwh=25))
    @test ladder == [(-25.0, 30.0, "res_supported"), (0.0, 70.0, "res_zero_cost")]
    @test sum(x[2] for x in ladder) == 100
    @test res_offer_tranches(0, RESOfferPolicy()) == []
    @test res_offer_tranches(100, RESOfferPolicy(; supported_share=1))[1][2] == 100
    for s in (-0.1, 1.1, NaN, Inf)
        @test_throws ArgumentError RESOfferPolicy(; supported_share=s)
    end
    @test_throws ArgumentError RESOfferPolicy(; support_eur_mwh=-1)
    @test_throws ArgumentError RESOfferPolicy(; support_eur_mwh=501)
    @test_throws ArgumentError res_offer_tranches(-1, RESOfferPolicy())
    withenv("EUPHEMIA_RES_OFFER_LADDER" => nothing) do
        @test !res_offer_ladder_enabled()
    end
    withenv("EUPHEMIA_RES_OFFER_LADDER" => "1",
            "EUPHEMIA_RES_SUPPORTED_SHARE_IT_SOUTH" => "0.2") do
        @test res_offer_ladder_enabled()
        @test res_offer_policy("IT-SOUTH").supported_share == 0.2
        @test res_offer_policy("GR").supported_share == 0
    end
end
