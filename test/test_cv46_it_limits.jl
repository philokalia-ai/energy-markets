# cv46 P3b Italian internal floors (src/network/cv46_it_limits.jl). DB-free, < 1 s.
using Test
using Dates
using Euphemia
const NWI = Euphemia.Network

itrow(s, d, tp, c) = (source_zone=s, sink_zone=d, time_period=tp, capacity=c)

@testset "cv46 IT_LIMITS" begin
    @testset "switch" begin
        old = get(ENV, "EUPHEMIA_CV46_IT_LIMITS", nothing)
        try
            delete!(ENV, "EUPHEMIA_CV46_IT_LIMITS"); @test !NWI.cv46_it_on()
            ENV["EUPHEMIA_CV46_IT_LIMITS"] = "on"; @test NWI.cv46_it_on()
            ENV["EUPHEMIA_CV46_IT_LIMITS"] = "off"; @test !NWI.cv46_it_on()
        finally
            old === nothing ? delete!(ENV, "EUPHEMIA_CV46_IT_LIMITS") : (ENV["EUPHEMIA_CV46_IT_LIMITS"] = old)
        end
    end

    @testset "floors per border, direction and hour of day" begin
        hourly = Dict{Tuple{DateTime,String,String},Float64}()
        t0 = DateTime(2026, 10, 1)
        for d in 0:27, h in 0:23
            t = t0 + Day(d) + Hour(h)
            hourly[(t, "IT-CSOUTH", "IT-CNORTH")] = h == 10 ? 2000.0 + d : 500.0
            hourly[(t, "IT-CNORTH", "IT-CSOUTH")] = -100.0          # negative ⇒ 0
            hourly[(t, "IT-NORTH", "CH")] = 3000.0                  # not Italian-internal
            d < 10 && (hourly[(t, "IT-SOUTH", "IT-Calabria")] = 900.0)   # 10 samples < 14
        end
        fl = NWI.cv46_it_floors(hourly)
        @test fl[("IT-CSOUTH", "IT-CNORTH", 11)] ≈ NWI.cv46_quantile([2000.0 + d for d in 0:27], 0.95)
        @test fl[("IT-CSOUTH", "IT-CNORTH", 1)] == 500.0
        @test fl[("IT-CNORTH", "IT-CSOUTH", 5)] == 0.0
        @test !haskey(fl, ("IT-NORTH", "CH", 1))
        @test !haskey(fl, ("IT-SOUTH", "IT-Calabria", 1))
    end

    @testset "floor only raises, only Italian internal rows in the footprint" begin
        fp = Set(["IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "CH"])
        floors = Dict(("IT-CSOUTH", "IT-CNORTH", 11) => 2500.0, ("IT-CSOUTH", "IT-CNORTH", 12) => 1000.0,
                      ("IT-CNORTH", "IT-NORTH", 11) => 4000.0, ("IT-SOUTH", "IT-CSOUTH", 11) => 9000.0)
        rows = NamedTuple[itrow("IT-CSOUTH", "IT-CNORTH", 11, 800.0),    # dip ⇒ raised to 2500
                          itrow("IT-CSOUTH", "IT-CNORTH", 12, 3000.0),   # above floor ⇒ kept
                          itrow("IT-CNORTH", "IT-NORTH", 11, 3500.0),    # raised to 4000
                          itrow("IT-SOUTH", "IT-CSOUTH", 11, 100.0),     # IT-SOUTH not in fp ⇒ kept
                          itrow("CH", "IT-NORTH", 11, 10.0)]             # not internal ⇒ kept
        rows = [r for r in rows]
        s = NWI.cv46_floor_it_rows!(rows, floors, fp)
        @test [r.capacity for r in rows] == [2500.0, 3000.0, 4000.0, 100.0, 10.0]
        @test length(rows) == 5
        @test s == [(border=("IT-CNORTH", "IT-NORTH"), hours_raised=1, mw_added=500.0),
                    (border=("IT-CSOUTH", "IT-CNORTH"), hours_raised=1, mw_added=1700.0)]
        rows2 = [r for r in rows]
        @test isempty(NWI.cv46_floor_it_rows!(rows2, Dict{Tuple{String,String,Int},Float64}(), fp))
        @test rows2 == rows
    end
end
