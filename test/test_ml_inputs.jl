# DB-free / network-free unit tests for the pure-Julia ML input scorer + feature
# port (bin/ml_inputs.jl). The heavy end-to-end equivalence vs python LightGBM is
# test/scripts/ml_inputs_equivalence.jl (needs the extract + GFS parquets); these
# tests lock the tree-evaluation semantics, the feature math, and the deliberate
# train/serve holiday imperfection so a refactor can't silently drift them.

using Test, Dates, JSON

const _BIN = joinpath(dirname(@__DIR__), "bin")
isdefined(Main, :predict_solar_hour) || include(joinpath(_BIN, "weather_res.jl"))
isdefined(Main, :easter_gregorian) || include(joinpath(_BIN, "weather_load.jl"))
isdefined(Main, :parse_lgb_model) || include(joinpath(_BIN, "ml_inputs.jl"))

@testset "ML inputs — LightGBM scorer" begin
    # Hand-built 3-node tree: root splits feature 0 at 5.0; decision_type encodes
    # missing-type=NaN (bits 2-3 = 2 -> value 8) + default-left (bit1 -> +2) = 10.
    # left child is leaf 0 (value 1.0), right child leaf 1 (value 2.0).
    t = LGBTree([0], [5.0], [10], [-1], [-2], [1.0, 2.0])
    m = LGBModel([t], ["f"])
    @test lgb_predict(m, [4.0]) == 1.0          # 4 <= 5 -> left leaf
    @test lgb_predict(m, [6.0]) == 2.0          # 6 > 5  -> right leaf
    @test lgb_predict(m, [NaN]) == 1.0          # NaN, missing=NaN, default-left -> left

    # default-RIGHT on NaN: decision_type 8 (missing NaN, default-left bit clear)
    t2 = LGBTree([0], [5.0], [8], [-1], [-2], [1.0, 2.0])
    @test lgb_predict(LGBModel([t2], ["f"]), [NaN]) == 2.0

    # zero-split via kZeroThreshold threshold (like the hod==0 splits): threshold
    # ~1e-35, decision_type 2 (missing None). 0 <= thr -> left; 1 > thr -> right.
    t3 = LGBTree([0], [1.0000000180025095e-35], [2], [-1], [-2], [10.0, 20.0])
    @test lgb_predict(LGBModel([t3], ["f"]), [0.0]) == 10.0
    @test lgb_predict(LGBModel([t3], ["f"]), [1.0]) == 20.0

    # multi-tree sum
    @test lgb_predict(LGBModel([t, t2], ["f"]), [6.0]) == 4.0
end

@testset "ML inputs — parse committed model + determinism" begin
    gm = parse_lgb_model(joinpath(_BIN, "input_models", "GR_load.txt"))
    @test gm.feature_names == JSON.parsefile(joinpath(_BIN, "input_models", "meta.json"))["GR_load"]["feat_cols"]
    @test length(gm.trees) >= 1
    x = zeros(length(gm.feature_names))
    p1 = lgb_predict(gm, x); p2 = lgb_predict(gm, x)
    @test p1 == p2 && isfinite(p1)         # deterministic, finite
    # num_cat assertion holds (no categorical dumps in the pipeline)
    for z in ML_PILOT_ZONES, tgt in ("solar", "wind", "load")
        @test length(parse_lgb_model(joinpath(_BIN, "input_models", "$(z)_$(tgt).txt")).trees) >= 1
    end
end

@testset "ML inputs — feature math" begin
    # sinel matches the RES-pack sinel (same formula, float doy)
    t = DateTime(2026, 7, 24, 12)
    @test ml_sinel(12.0, Float64(dayofyear(t)), 39.0, 22.0) ≈ sinel(t, 39.0, 22.0)

    # degree-hours hard-coded 21/16.5 (as trained, not the pack bases)
    fl = ml_load_features(t, 39.0, 22.0, 30.0, 500.0, 28.0, 8000.0, 8100.0, 0.0)
    @test fl["cdh"] ≈ 9.0 && fl["hdh"] ≈ 0.0
    @test fl["cdh2"] ≈ 81.0 / 10 && fl["dow"] == 4.0     # 2026-07-24 is Friday (py dow 4)
    @test fl["is_hol"] == 0.0

    fr = ml_res_features(t, 39.0, 22.0, 800.0, 30.0, 950.0, 18.0, 7000.0, 2800.0)
    @test fr["clearness"] ≈ clamp(800.0 / max(1361.0 * fr["se"], 1.0), 0.0, 1.3)
    @test fr["cap95_solar"] == 7000.0 && fr["hod"] == 12.0

    # numpy-linear percentile
    @test _np_percentile95([0.0, 10.0]) ≈ 9.5
    @test _np_percentile95([5.0]) == 5.0
end

@testset "ML inputs — holidays (deliberate train/serve imperfection)" begin
    # GR uses the WESTERN Gregorian Easter approximation (NOT Orthodox computus):
    # 2026 Western Easter = Apr 5 -> Good Friday Apr 3 must be in the GR set.
    gr = ml_holidays("GR", 2026:2026)
    @test Date(2026, 4, 3) in gr           # western Good Friday (approx)
    @test Date(2026, 3, 25) in gr          # fixed GR national day
    # NL (and any non-GR/ES/DE/SE country) carries NO holidays in features.py.
    @test isempty(ml_holidays("NL", 2024:2027))
    @test isempty(ml_holidays("PL", 2026:2026))
end

@testset "ML inputs — ship config" begin
    @test ML_USE_NEW[("GR", :load)] && ML_USE_NEW[("GR", :solar)] && !ML_USE_NEW[("GR", :wind)]
    @test !ML_USE_NEW[("ES", :solar)]                       # ES keeps the pack solar ridge
    @test ML_USE_NEW[("NL", :wind)] && !ML_USE_NEW[("SE2", :wind)]   # NEW wind only offshore NL
    @test all(ML_USE_NEW[(z, :load)] for z in ML_PILOT_ZONES)
end
