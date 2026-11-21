# GFS-vintage capture covers every ML_RES_VARS variable (#431 R3 follow-up): the
# archive now carries cloud_cover + surface_pressure next to wind / GHI / temperature.
# Pure: the three fetchers are stubs. No network, no DB, no file written.
#   julia --project=. test/test_capture_gfs_vintages.jl

using Test, Dates

isdefined(@__MODULE__, :capture_delivery_day) ||
    include(joinpath(@__DIR__, "..", "bin", "capture_gfs_vintages.jl"))

@testset "GFS-vintage capture: ML RES variables (#431 R3 follow-up)" begin
    @test ml_extra_vars() == [(3, "cloud_cover"), (4, "surface_pressure")]
    archived = Set(["wind_speed_100m", "shortwave_radiation", "temperature_2m"])
    @test issubset(Set(ML_RES_VARS), union(archived, Set(v for (_, v) in ml_extra_vars())))

    cells = all_footprint_cells()
    rc = res_footprint_cells(cells)
    @test !isempty(rc) && length(rc) < length(cells) && issubset(Set(rc), Set(cells))
    # the ML geometry's cells are all RES cells, so the ML fetch over rc covers them
    geom = ml_geom()
    @test all(z -> issubset(Set((Float64(c[1]), Float64(c[2])) for c in geom[z]["cells"]), Set(rc)),
              ml_pilot_zones())

    day = Date(2026, 11, 16)
    t = DateTime(day)
    c1, c2, city = (48.0, 17.0), (49.0, 18.0), (50.0, 19.0)
    calls = Tuple{Symbol,Int,Int}[]
    fres(cs, ds; vintage_lag) = (push!(calls, (:res, vintage_lag, length(cs)));
                                 Dict(c => Dict(t => (5.0, 100.0)) for c in cs))
    fload(cs, ds; vintage_lag) = (push!(calls, (:load, vintage_lag, length(cs)));
                                  Dict(c => Dict(t => (12.0, 100.0)) for c in cs))
    fml(cs, ds; vintage_lag) = (push!(calls, (:ml, vintage_lag, length(cs)));
                                Dict(c => Dict(t => (5.0, 100.0, 40.0, 1013.0)) for c in cs))
    df = capture_delivery_day(day, [c1, c2, city]; ml_cells=[c1, c2], ml_vars=true,
                              fetch_res=fres, fetch_load=fload, fetch_ml=fml)
    @test sort(unique(df.variable)) ==
          ["cloud_cover", "shortwave_radiation", "surface_pressure", "temperature_2m", "wind_speed_100m"]
    @test nrow(df) == 7 * (3 * 3 + 2 * 2)                       # 7 leads; 3 vars × 3 cells + 2 ML vars × 2 cells
    @test count(==((:ml, 1, 2)), calls) == 1 && count(c -> c[1] == :ml, calls) == 7
    cc = df[(df.variable .== "cloud_cover") .& (df.lead_days .== 3), :]
    @test sort(collect(zip(cc.lat, cc.lon))) == [c1, c2] && all(==(40.0), cc.value)
    @test all(==(1013.0), df[df.variable .== "surface_pressure", :value])
    # wind/GHI are archived once (from the RES fetch), not again from the ML fetch
    @test nrow(df[df.variable .== "wind_speed_100m", :]) == 7 * 3
    # kill switch: the pre-2026-11-17 capture, no ML fetch at all
    empty!(calls)
    df0 = capture_delivery_day(day, [c1, c2, city]; ml_cells=[c1, c2], ml_vars=false,
                               fetch_res=fres, fetch_load=fload, fetch_ml=fml)
    @test !any(c -> c[1] == :ml, calls) && nrow(df0) == 7 * 3 * 3
    withenv("EUPHEMIA_VINTAGE_ML_VARS" => "0") do
        empty!(calls)
        capture_delivery_day(day, [c1]; ml_cells=[c1], fetch_res=fres, fetch_load=fload, fetch_ml=fml)
        @test !any(c -> c[1] == :ml, calls)
    end
end
