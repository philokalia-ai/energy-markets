# cv45 knobs (src/cv45_knobs.jl): master switch, per-knob override, value rules.
# DB-free, < 1 s.
using Test
using Euphemia
const MOB = Euphemia.MeritOrderBook

function withenv_cv45(f, pairs...)
    keys_ = ["EUPHEMIA_CV45", Euphemia.CV45_KNOBS..., "EUPHEMIA_COMPLEX_ORDERS"]
    saved = Dict(k => get(ENV, k, nothing) for k in keys_)
    try
        foreach(k -> delete!(ENV, k), keys_)
        for (k, v) in pairs; ENV[k] = v; end
        f()
    finally
        for (k, v) in saved
            v === nothing ? delete!(ENV, k) : (ENV[k] = v)
        end
    end
end

@testset "cv45 knobs" begin
    withenv_cv45() do      # unset ⇒ the adopted set only
        @test all(Euphemia.cv45_on, Euphemia.CV45_SHIPPED)
        @test MOB.complex_order_kinds() == Set(["ps"])
    end
    withenv_cv45("EUPHEMIA_CV45" => "off") do      # master off ⇒ cv44
        @test !any(Euphemia.cv45_on, Euphemia.CV45_KNOBS)
        @test MOB.complex_order_kinds() == Set(["ps"])
    end
    withenv_cv45("EUPHEMIA_CV45" => "off", "EUPHEMIA_CV45_GAS_HHV" => "on") do   # single-change arm
        @test Euphemia.cv45_on("EUPHEMIA_CV45_GAS_HHV")
        @test !Euphemia.cv45_on("EUPHEMIA_CV45_AVAIL")
    end
    # v46: the deferred knobs are gone — a stale env var is ignored, not an error
    withenv_cv45() do
        ENV["EUPHEMIA_CV45_RESERVOIR"] = "on"
        try
            @test MOB.complex_order_kinds() == Set(["ps"])
        finally
            delete!(ENV, "EUPHEMIA_CV45_RESERVOIR")
        end
    end
    withenv_cv45("EUPHEMIA_CV45_AVAIL" => "off") do   # adopted set minus one
        @test !Euphemia.cv45_on("EUPHEMIA_CV45_AVAIL")
        @test Euphemia.cv45_on("EUPHEMIA_CV45_GAS_HHV")
    end
    withenv_cv45("EUPHEMIA_CV45" => "off", "EUPHEMIA_CV45_AVAIL" => "on") do
        @test !Euphemia.cv45_on("EUPHEMIA_CV45_AVAIL_INMERIT")
    end
    for efficiency in (Euphemia.GAS_PLANT_EFFICIENCY, MOB.GB_CCGT_EFFICIENCY)
        @test Euphemia._gas_fuel_cost(35.0, efficiency, false) === 35.0 / efficiency
        @test Euphemia._gas_fuel_cost(35.0, efficiency, true) == 35.0 / (efficiency * 0.90)
    end
    withenv_cv45("EUPHEMIA_COMPLEX_ORDERS" => "off") do   # complex-orders kill switch still wins
        @test isempty(MOB.complex_order_kinds())
    end
    withenv_cv45("EUPHEMIA_CV45_AVAIL" => "maybe") do
        @test_throws ErrorException Euphemia.cv45_on("EUPHEMIA_CV45_AVAIL")
    end
    @test length(Euphemia.CV45_KNOBS) == 4 && Set(Euphemia.CV45_KNOBS) == Set(Euphemia.CV45_SHIPPED)
    # Values come from declared constants, not new free parameters
    @test MOB.TRANCHES[end][2] == 1.6
    @test MOB.BACKSTOP_PRICE_MULT == 1.8
    @test Euphemia.GAS_NCV_PER_GCV == 0.90
end
