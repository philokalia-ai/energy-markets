# cv46 physics switches (src/cv46_physics.jl): unset = off, value rules. DB-free, < 1 s.
using Test
using Euphemia

@testset "cv46 physics switches" begin
    saved = Dict(k => get(ENV, k, nothing) for k in Euphemia.CV46_PHYSICS_SWITCHES)
    try
        foreach(k -> delete!(ENV, k), Euphemia.CV46_PHYSICS_SWITCHES)
        @test !any(Euphemia.cv46_on, Euphemia.CV46_PHYSICS_SWITCHES)
        ENV["EUPHEMIA_CV46_NORDIC_WV"] = "on"
        @test Euphemia.cv46_on("EUPHEMIA_CV46_NORDIC_WV")
        @test !Euphemia.cv46_on("EUPHEMIA_CV46_SEE_LIMIT")
        ENV["EUPHEMIA_CV46_NORDIC_WV"] = "OFF"
        @test !Euphemia.cv46_on("EUPHEMIA_CV46_NORDIC_WV")
        ENV["EUPHEMIA_CV46_NORDIC_WV"] = "1"
        @test_throws ErrorException Euphemia.cv46_on("EUPHEMIA_CV46_NORDIC_WV")
        @test_throws ErrorException Euphemia.cv46_on("EUPHEMIA_CV46_NOPE")
    finally
        for (k, v) in saved
            v === nothing ? delete!(ENV, k) : (ENV[k] = v)
        end
    end
end
