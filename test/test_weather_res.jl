# Tests for the weather-based RES prediction helpers (bin/weather_res.jl):
# power-curve / sun-elevation / feature-vector construction against
# hand-computed examples, multi-model ensemble averaging, and open-meteo
# response parsing (object and array shapes) on literal JSON — no network,
# no DB.

using Test, Dates, Statistics

include(joinpath(@__DIR__, "..", "bin", "weather_res.jl"))

@testset "Weather RES" begin

    @testset "pcurve (turbine power curve, km/h input)" begin
        # x = v/3.6 m/s; cut-in 3, rated 12, cut-out 25; cubic ramp between.
        @test pcurve(0.0) == 0.0
        @test pcurve(10.79) == 0.0            # x < 3 m/s
        @test pcurve(10.8) == 0.0             # x = 3 exactly → ((3-3)/9)^3 = 0
        @test pcurve(27.0) ≈ 0.125            # x = 7.5 → (4.5/9)^3 = 0.5^3
        @test pcurve(43.2) == 1.0             # x = 12 → rated
        @test pcurve(89.9) == 1.0             # just below cut-out
        @test pcurve(90.0) == 0.0             # x = 25 → cut-out
        @test pcurve(200.0) == 0.0
        # midpoint hand check: v = 21.6 km/h → x = 6 → (3/9)^3 = 1/27
        @test pcurve(21.6) ≈ 1 / 27
    end

    @testset "sinel (sun elevation proxy)" begin
        # Equinox noon at lon 0, lat 40°N (hand-computed):
        # doy = 79, dec = 0.409·sin(2π·363/365) ≈ −0.014078, H = 0
        # se = sind(40)·sin(dec) + cosd(40)·cos(dec) ≈ 0.75692
        @test isapprox(sinel(DateTime(2026, 3, 20, 12), 40.0, 0.0), 0.75692; atol=2e-4)
        # Midnight in Greece mid-summer: below horizon → clamped to 0
        @test sinel(DateTime(2026, 6, 21, 0), 38.0, 23.7) == 0.0
        # Summer-solstice "local noon" is higher than winter's at the same site
        @test sinel(DateTime(2026, 6, 21, 10), 38.0, 23.7) >
              sinel(DateTime(2026, 12, 21, 10), 38.0, 23.7)
        @test 0.0 <= sinel(DateTime(2026, 1, 1, 7), 60.0, 10.0) <= 1.0
    end

    @testset "wind feature vector + prediction" begin
        X = wind_feature_vector([27.0, 43.2])
        @test X == [1.0, 0.125, 1.0, 7.5, 12.0]   # [1, pcurve.(v), v ./ 3.6]
        @test length(wind_feature_vector(zeros(46))) == 93   # GR pack: 1 + 2·46

        # hand-computed dot product
        wm = Dict("coef" => [10.0, 100.0, 50.0, 2.0, 1.0])
        @test predict_wind_hour(wm, [27.0, 43.2]) ≈ 99.5   # 10+12.5+50+15+12
        # clamp at 0
        wm_neg = Dict("coef" => [-1.0, -1.0, -1.0, -1.0, -1.0])
        @test predict_wind_hour(wm_neg, [27.0, 43.2]) == 0.0
    end

    @testset "solar feature vector + prediction" begin
        t = DateTime(2026, 6, 21, 12)   # hod = 12 UTC
        g = 500.0
        X = solar_feature_vector(g, t, 38.0, 23.7)
        @test length(X) == 39           # 1 + 4 + 17 + 17
        se = sinel(t, 38.0, 23.7)
        @test X[1] == 1.0
        @test X[2] == g
        @test X[3] == se
        @test X[4] == g * se
        @test X[5] == sqrt(g)
        # hod == 12 → k-index 12−3+1 = 10 in both blocks
        @test X[5 + 10] == g                       # 1{hod==12}·g
        @test X[5 + 17 + 10] == 1.0                # 1{hod==12}
        @test count(!iszero, X[6:22]) == 1
        @test count(!iszero, X[23:39]) == 1

        # hod outside 3:19 → both hod blocks all-zero
        X22 = solar_feature_vector(g, DateTime(2026, 6, 21, 22), 38.0, 23.7)
        @test all(iszero, X22[6:39])

        # prediction: coef picks intercept + g only
        coef = zeros(39); coef[1] = 5.0; coef[2] = 0.1
        sm = Dict("coef" => coef, "lat0" => 38.0, "lon0" => 23.7)
        @test predict_solar_hour(sm, 500.0, t) ≈ 55.0
        coef2 = zeros(39); coef2[1] = -10.0
        sm2 = Dict("coef" => coef2, "lat0" => 38.0, "lon0" => 23.7)
        @test predict_solar_hour(sm2, 500.0, t) == 0.0   # clamp ≥ 0
    end

    @testset "multi-model ensemble averaging (nulls ignored)" begin
        hourly = JSON.parse("""
        {"time": ["2026-07-14T00:00", "2026-07-14T01:00", "2026-07-14T02:00"],
         "wind_speed_100m_gfs_seamless":  [10.0, null, null],
         "wind_speed_100m_ecmwf_ifs025":  [20.0, 30.0, null]}
        """)
        v = average_hourly(hourly, "wind_speed_100m")
        @test v[1] == 15.0            # mean of both models
        @test v[2] == 30.0            # gfs null ignored
        @test v[3] === nothing        # all models null → stays nothing

        # single-model plain key (no suffix)
        hourly1 = JSON.parse("""{"time": ["2026-07-14T00:00"], "wind_speed_100m": [12.5]}""")
        @test average_hourly(hourly1, "wind_speed_100m") == [12.5]

        # no matching key at all (the "time" array is never treated as data)
        @test isempty(average_hourly(hourly1, "shortwave_radiation"))
        @test isempty(average_hourly(hourly1, "time"))
    end

    @testset "open-meteo response parsing (object + array shapes)" begin
        # single-location OBJECT shape
        obj = """
        {"latitude": 38.0, "longitude": 23.7,
         "hourly": {"time": ["2026-07-14T00:00", "2026-07-14T01:00"],
                    "wind_speed_100m": [10.0, 20.0],
                    "shortwave_radiation": [0.0, 150.0]}}
        """
        cells1 = [(38.0, 23.7)]
        w1 = parse_openmeteo_response(obj, cells1)
        @test w1[(38.0, 23.7)][DateTime(2026, 7, 14, 0)] == (10.0, 0.0)
        @test w1[(38.0, 23.7)][DateTime(2026, 7, 14, 1)] == (20.0, 150.0)

        # multi-location ARRAY shape, in request order, with multi-model keys
        # and an hour dropped where one variable is null across all models
        arr = """
        [{"hourly": {"time": ["2026-07-14T00:00", "2026-07-14T01:00"],
                     "wind_speed_100m_gfs_seamless": [10.0, null],
                     "wind_speed_100m_ecmwf_ifs025": [20.0, 30.0],
                     "shortwave_radiation_gfs_seamless": [0.0, null],
                     "shortwave_radiation_ecmwf_ifs025": [null, null]}},
         {"hourly": {"time": ["2026-07-14T00:00"],
                     "wind_speed_100m_gfs_seamless": [36.0],
                     "wind_speed_100m_ecmwf_ifs025": [null],
                     "shortwave_radiation_gfs_seamless": [500.0],
                     "shortwave_radiation_ecmwf_ifs025": [300.0]}}]
        """
        cells2 = [(38.0, 23.7), (40.0, 22.0)]
        w2 = parse_openmeteo_response(arr, cells2)
        c1 = w2[(38.0, 23.7)]
        @test c1[DateTime(2026, 7, 14, 0)] == (15.0, 0.0)     # winds averaged; ghi from gfs
        @test !haskey(c1, DateTime(2026, 7, 14, 1))           # ghi null in ALL models → dropped
        c2 = w2[(40.0, 22.0)]
        @test c2[DateTime(2026, 7, 14, 0)] == (36.0, 400.0)   # null model ignored per-var

        # location-count mismatch is an error
        @test_throws Exception parse_openmeteo_response(obj, cells2)
    end

    @testset "predict_res (wind + solar summed; missing components → 0)" begin
        t = DateTime(2026, 7, 14, 12)
        cells = [[38.0, 23.7], [40.0, 22.0]]
        wind = Dict("coef" => [10.0, 100.0, 50.0, 2.0, 1.0])   # 2 cells → 1 + 2·2 = 5
        scoef = zeros(39); scoef[1] = 5.0; scoef[2] = 0.1
        solar = Dict("coef" => scoef, "lat0" => 38.0, "lon0" => 23.7)
        pack = Dict("zones" => Dict(
            "ZZ" => Dict("cells" => cells, "wind" => wind, "solar" => solar),
            "SOLARONLY" => Dict("cells" => cells, "solar" => solar),
        ))
        weather = Dict(
            (38.0, 23.7) => Dict(t => (27.0, 400.0)),
            (40.0, 22.0) => Dict(t => (43.2, 600.0)),
        )
        pred = predict_res(pack, "ZZ", [t], weather)
        # wind: 10 + 100·pcurve(27) + 50·pcurve(43.2) + 2·7.5 + 1·12 = 99.5
        # solar: g = mean(400,600) = 500 → 5 + 0.1·500 = 55
        @test pred[t] ≈ 154.5

        # zone without a wind model → solar component only
        pred2 = predict_res(pack, "SOLARONLY", [t], weather)
        @test pred2[t] ≈ 55.0

        # hour with incomplete weather is skipped (not zero-filled)
        t2 = DateTime(2026, 7, 14, 13)
        pred3 = predict_res(pack, "ZZ", [t, t2], weather)
        @test haskey(pred3, t) && !haskey(pred3, t2)

        # zone absent from the pack → empty prediction (warned)
        @test isempty(predict_res(pack, "NOPE", [t], weather))
    end

    @testset "model pack sanity (bin/res_models_v1.json)" begin
        pack = load_res_models()
        zones = pack["zones"]
        @test length(zones) == 39
        for z in ("GR", "DE_LU", "FR", "IT-NORTH", "NO2")
            @test haskey(zones, z)
        end
        gr = zones["GR"]
        ncells = length(gr["cells"])
        @test length(gr["wind"]["coef"]) == 1 + 2 * ncells   # [1, pcurve., v/3.6]
        @test length(gr["solar"]["coef"]) == 39
        @test 34 <= gr["solar"]["lat0"] <= 42                # Greek centroid
        # zones may legitimately lack a component (physically negligible)
        @test !haskey(zones["NO5"], "wind")
        @test !haskey(zones["NO2"], "solar")
    end

end
