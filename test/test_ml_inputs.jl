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
    # num_cat assertion holds (no categorical dumps in the pipeline). Only WINNER
    # models are committed — iterate the per-model meta entries (a Dict with
    # feat_cols), skipping the meta-driven wiring keys (pilot_zones / winners).
    meta = JSON.parsefile(joinpath(_BIN, "input_models", "meta.json"))
    for (key, entry) in meta
        (entry isa AbstractDict && haskey(entry, "feat_cols")) || continue
        @test length(parse_lgb_model(joinpath(_BIN, "input_models", "$(key).txt")).trees) >= 1
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

    # fit-iteration 3, re-fit at iteration 4: per-zone affine LOAD bias correction
    # (b=1 level debias). IT-NORTH + NO3 ship; FR dropped (retrain removed its bias).
    @test ml_load_bias_correct("IT-NORTH", 4000.0) ≈ 4000.0 - 177.08
    @test ml_load_bias_correct("NO3", 1000.0) ≈ 1000.0 - 48.56
    @test ml_load_bias_correct("FR", 5000.0) == 5000.0           # dropped at iter4 -> identity
    @test ml_load_bias_correct("GR", 5000.0) == 5000.0           # absent zone -> identity
    @test ml_load_bias_correct("HU", 3000.0) == 3000.0           # holdout gate failed -> not here
    @test ml_load_bias_correct("NO3", 10.0) == 0.0               # clamped at 0 (10-48.56<0)
end

@testset "ML inputs — holidays (rollout-39 Orthodox amendment, train/serve lockstep)" begin
    # GR/BG/RO/RS anchor movable feasts on the ORTHODOX (Julian/Meeus) Easter.
    # 2026 Orthodox Easter = Apr 12 -> Good Friday Apr 10 in the set; the Western
    # Good Friday (Apr 3) must NOT be (the pilot approximation was fixed here + in
    # features.py in lockstep).
    gr = ml_holidays("GR", 2026:2026)
    @test Date(2026, 4, 10) in gr          # orthodox Good Friday
    @test !(Date(2026, 4, 3) in gr)        # western Good Friday no longer present
    @test Date(2026, 3, 25) in gr          # fixed GR national day
    @test ml_orthodox_easter(2026) == Date(2026, 4, 12)
    # the other Orthodox zones carry their fixed + orthodox-movable maps
    @test Date(2026, 4, 12) in ml_holidays("BG", 2026:2026)   # orthodox Easter Sunday
    @test Date(2026, 3, 3)  in ml_holidays("BG", 2026:2026)   # BG Liberation Day
    @test Date(2026, 1, 7)  in ml_holidays("RS", 2026:2026)   # RS Orthodox Christmas
    @test Date(2026, 12, 1) in ml_holidays("RO", 2026:2026)   # RO National Day
    # ES/DE/SE keep the Western Easter.
    @test Date(2026, 4, 3) in ml_holidays("ES", 2026:2026)    # western Good Friday

    # fit-iteration 2: the remaining footprint countries now carry national maps
    # (all Western-Easter; 2026 Western Easter Sunday = Apr 5, Good Friday = Apr 3,
    # Easter Monday = Apr 6). These lock the serve side; a python↔Julia byte-identity
    # sweep over 2024-2027 for all 25 countries is docs/experiments/input-upgrade
    # cmp_holidays.py (LOCKSTEP_OK). Only a few anchor dates are asserted here.
    fr = ml_holidays("FR", 2026:2026)
    @test Date(2026, 7, 14) in fr && Date(2026, 4, 6) in fr && !(Date(2026, 4, 3) in fr)  # Bastille + Easter Mon; no Good Fri in FR
    pl = ml_holidays("PL", 2026:2026)
    @test Date(2026, 5, 3) in pl && Date(2026, 4, 5) in pl                     # Constitution Day + Easter Sunday
    nl = ml_holidays("NL", 2026:2026)
    @test Date(2026, 4, 27) in nl && Date(2026, 4, 3) in nl                    # King's Day + Good Friday
    @test Date(2026, 8, 15) in ml_holidays("IT", 2026:2026)                    # Ferragosto
    @test Date(2026, 5, 17) in ml_holidays("NO", 2026:2026)                    # Norway Constitution Day
    # a country outside the footprint map still returns an empty set
    @test isempty(ml_holidays("XX", 2024:2027))
end

@testset "ML inputs — DE_LU load enrichment (iter6, train/serve lockstep)" begin
    # ml_de_school_holiday: mirrors features.py de_school_holiday byte-for-byte
    # (cmp_dnload_iter6.py LOCKSTEP_OK: 364/364 days match, windchill max|Δ|=7e-15).
    @test ml_de_school_holiday(DateTime(2026, 7, 20))   # summer envelope
    @test ml_de_school_holiday(DateTime(2026, 12, 25))  # Christmas window
    @test ml_de_school_holiday(DateTime(2026, 10, 25))  # autumn window
    @test ml_de_school_holiday(DateTime(2026, 4, 5))    # Western Easter 2026 (Apr 5)
    @test !ml_de_school_holiday(DateTime(2026, 11, 15)) # ordinary day
    @test !ml_de_school_holiday(DateTime(2026, 6, 10))  # before the summer window
    @test !ml_de_school_holiday(DateTime(2026, 3, 20))  # >7d before Easter
    # ml_windchill: Environment Canada JAG/TI on the 100m-wind proxy; NaN wind -> NaN
    @test ml_windchill(0.0, 5.0) ≈ 13.12 - 11.37 * (18.0)^0.16 atol = 1e-9
    @test isnan(ml_windchill(5.0, NaN))
    # the committed DE_LU load model carries the two enrichment features
    dm = parse_lgb_model(joinpath(_BIN, "input_models", "DE_LU_load.txt"))
    @test "school_hol" in dm.feature_names && "windchill" in dm.feature_names
    # inert elsewhere: the load dict always exposes both, but only DE_LU's feat_cols use them
    lf = ml_load_features(DateTime(2026, 7, 20), 50.0, 9.0, 25.0, 200.0, 24.0, 6e4, 6e4, 0.0, 4.0)
    @test lf["school_hol"] == 1.0 && !isnan(lf["windchill"])
    @test isnan(ml_load_features(DateTime(2026, 1, 15), 50.0, 9.0, 5.0, 0.0, 4.0, 6e4, 6e4, 0.0)["windchill"])  # v100m default NaN
end

@testset "ML inputs — ship config (rollout-39)" begin
    # structural invariants: every ML zone × target has an explicit entry, and every
    # ML zone ships at least one NEW target (else it would not be in the overlay).
    for z in ML_PILOT_ZONES, t in (:load, :solar, :wind)
        @test haskey(ML_USE_NEW, (z, t))
    end
    @test all(any(ML_USE_NEW[(z, t)] for t in (:load, :solar, :wind)) for z in ML_PILOT_ZONES)
    # every committed model corresponds to a NEW winner, and vice-versa
    meta = JSON.parsefile(joinpath(_BIN, "input_models", "meta.json"))
    for z in ML_PILOT_ZONES, t in (:load, :solar, :wind)
        @test ML_USE_NEW[(z, t)] == haskey(meta, "$(z)_$(t)")
    end
    # stable pilot decisions (unchanged by the retrain; GR wind + ES solar lose to the pack)
    @test ML_USE_NEW[("GR", :load)] && ML_USE_NEW[("GR", :solar)] && !ML_USE_NEW[("GR", :wind)]
    @test !ML_USE_NEW[("ES", :solar)] && ML_USE_NEW[("ES", :load)]
    @test ML_USE_NEW[("NL", :wind)] && !ML_USE_NEW[("SE2", :wind)]
    @test ML_USE_NEW[("DE_LU", :solar)] && !ML_USE_NEW[("DE_LU", :wind)]

    # meta-driven runtime resolution (#280): the 39-zone rollout ships pilot_zones +
    # winners THROUGH meta.json — the surface production actually reads.
    if haskey(meta, "pilot_zones")
        mp = ml_pilot_zones()
        @test issubset(ML_PILOT_ZONES, mp)          # pilots stay covered
        @test "PL" in mp                            # a headline new zone joined
        @test ml_use_new("PL", :load; meta=meta)    # PL load ships NEW
        @test ml_use_new("GR", :solar; meta=meta) && !ml_use_new("GR", :wind; meta=meta)
        # every committed model entry ⇔ a meta winner; and each pilot_zone ships ≥1 NEW
        for (key, entry) in meta
            (entry isa AbstractDict && haskey(entry, "feat_cols")) || continue
            @test meta["winners"][key] == true
        end
        @test all(any(ml_use_new(z, t; meta=meta) for t in (:load, :solar, :wind)) for z in mp)
    end
end
