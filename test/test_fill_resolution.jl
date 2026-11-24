# #477 review finding 1: daily-forecast eligibility fills on the zone's own series
# resolution (src/merit_order/book_build.jl _merge_load_fill! / _merge_res_fill!).
# DB-free: synthetic TSO rows + hourly fills → _demand_series at 15 and 60 min.
using Test
using Euphemia
const MOB = Euphemia.MeritOrderBook

slot(h, m) = "20261113-" * lpad(h, 2, '0') * lpad(m, 2, '0')

@testset "fill rows on the series resolution (#477 finding 1)" begin
    # native-15-min zone, TSO published hours 00-11 only (48 quarters); the hook
    # fills every hour (hourly values), as the weather track does
    tso_load(h, m) = 5000.0 + 10h + m             # distinct per quarter
    fill_load(h) = 7000.0 + 100h
    loads = [Load(slot(h, m), "PT15M", "HU", tso_load(h, m)) for h in 0:11 for m in (0, 15, 30, 45)]
    added = MOB._merge_load_fill!(loads, Dict(slot(h, 0) => fill_load(h) for h in 0:23), "HU")
    @test added == 48                             # 12 hours × 4 quarters, TSO quarters untouched
    @test all(l.resolution_code == "PT15M" for l in loads)

    wind(h, m) = 300.0 + h + m / 100
    res = [RenewablesGenerationForecast(slot(h, m), "PT15M", "HU", "Wind Onshore", wind(h, m))
           for h in 0:11 for m in (0, 15, 30, 45)]
    issued = Dict{Int,Vector{Float64}}()
    rfill = [(slot(h, 0), 50.0 + h, "Solar") for h in 0:23]
    append!(rfill, [(slot(h, 0), 400.0 + h, "WeatherFill") for h in 0:23])
    radded = MOB._merge_res_fill!(res, rfill, "HU", issued)
    @test radded == 2 * 48                        # two typed rows per filled quarter
    @test sort(collect(keys(issued))) == collect(0:23) && all(length(issued[h]) == 1 for h in 0:23)

    # 15-min clear: all 96 slots, quarters replicated, no zero RES
    ts, lb, rb, rmin = MOB._demand_series(loads, res, 15, nothing, nothing)
    @test rmin == 15
    @test length(ts) == 96 && length(lb) == 96 && length(rb) == 96
    @test lb[slot(5, 30)] == tso_load(5, 30)      # TSO quarter kept
    @test all(lb[slot(17, m)] == fill_load(17) for m in (0, 15, 30, 45))   # fill replicated
    @test rb[slot(5, 45)] == wind(5, 45)
    @test all(rb[slot(17, m)] == (50.0 + 17) + (400.0 + 17) for m in (0, 15, 30, 45))
    @test all(>(0), values(rb))

    # 60-min clear on the same inputs: hourly means, fills exact
    ts6, lb6, rb6, rmin6 = MOB._demand_series(loads, res, 60, nothing, nothing)
    @test rmin6 == 60 && length(ts6) == 24
    @test lb6[slot(5, 0)] ≈ sum(tso_load(5, m) for m in (0, 15, 30, 45)) / 4
    @test lb6[slot(17, 0)] == fill_load(17)
    @test rb6[slot(17, 0)] == 484.0

    # a partly published hour: only its missing quarters are filled
    part = [Load(slot(h, m), "PT15M", "HU", 1.0) for h in 0:22 for m in (0, 15, 30, 45)]
    push!(part, Load(slot(23, 0), "PT15M", "HU", 2.0), Load(slot(23, 15), "PT15M", "HU", 2.0))
    @test MOB._merge_load_fill!(part, Dict(slot(h, 0) => 9.0 for h in 0:23), "HU") == 2
    v = Dict(l.timeslot => l.value for l in part)
    @test v[slot(23, 0)] == 2.0 && v[slot(23, 15)] == 2.0 && v[slot(23, 30)] == 9.0 && v[slot(23, 45)] == 9.0

    # native-hourly zone: fill stays hourly on the TSO code; the grid replicates it
    hl = [Load(slot(h, 0), "PT60M", "GR", 6000.0 + h) for h in 0:11]
    @test MOB._merge_load_fill!(hl, Dict(slot(h, 0) => 8000.0 + h for h in 0:23), "GR") == 12
    @test all(l.resolution_code == "PT60M" for l in hl)
    hr = RenewablesGenerationForecast[]           # no TSO RES at all ⇒ hourly fill rows
    @test MOB._merge_res_fill!(hr, [(slot(h, 0), 100.0) for h in 0:23], "GR", Dict{Int,Vector{Float64}}()) == 24
    @test all(r.resolution_code == "PT60M" && r.production_type == "WeatherFill" for r in hr)
    ts, lb, rb, _ = MOB._demand_series(hl, hr, 15, nothing, nothing)
    @test length(lb) == 96 && lb[slot(20, 45)] == 8020.0 && rb[slot(20, 45)] == 100.0
    ts, lb, rb, _ = MOB._demand_series(hl, hr, 60, nothing, nothing)
    @test length(lb) == 24 && lb[slot(3, 0)] == 6003.0 && lb[slot(20, 0)] == 8020.0

    # no TSO load at all (lead ≥ 2): hourly fill rows, unchanged behaviour
    el = Load[]
    @test MOB._merge_load_fill!(el, Dict(slot(h, 0) => 1.0 for h in 0:23), "GR") == 24
    @test all(l.resolution_code == "PT60M" for l in el)
end
