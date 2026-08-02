# Equivalence harness: pure-Julia ML input scorer/port vs the python
# predict_inputs.py pipeline (docs/experiments/input-upgrade), on IDENTICAL
# inputs. Validation A of the ML-inputs wiring task.
#
# PART 1 (scorer, no store): feed the reference feature vectors (dumped by
#   dump_eval.py, in each model's feat_cols order) into the Julia GBDT evaluator
#   and post-processing; compare to python's post-processed NEW outputs. Isolates
#   the parser + tree math + ratio/clamp.
# PART 2 (feature port, store + GFS parquets): rebuild every feature in Julia from
#   the SAME GFS previous_day1 parquets + the SAME DuckDB extract used to train,
#   compare feature-by-feature to the reference, then predict and compare NEW
#   outputs. Isolates the feature construction (weather aggregation, sinel,
#   clearness, degree-hours, holidays, cap95 p95, AR lags).
#
# Run (offline, read-only extract):
#   EUPHEMIA_DATA_STORE=duckdb \
#   EUPHEMIA_DUCKDB_PATH=data/extracts/euphemia-live.duckdb \
#     julia --project=. test/scripts/ml_inputs_equivalence.jl
#
# Precondition: docs/experiments/input-upgrade/dump_eval39.py has written
# <SP>/eval_ref.json (spot set: a few pilots + a few new rollout-39 zones, dumped
# from the COMMITTED bin/input_models) and the GFS parquets exist under <SP>/gfs.
# The test reads whatever zones the ref names and compares only committed targets.

const SP = "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
const EXTRACT = "/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"

get(ENV, "EUPHEMIA_DATA_STORE", "") == "duckdb" || (ENV["EUPHEMIA_DATA_STORE"] = "duckdb")
get(ENV, "EUPHEMIA_DUCKDB_PATH", "") == "" && (ENV["EUPHEMIA_DUCKDB_PATH"] = EXTRACT)

using Euphemia, Dates, JSON, Statistics, Printf, DuckDB, DataFrames

const BIN = joinpath(dirname(dirname(@__DIR__)), "bin")
include(joinpath(BIN, "weather_res.jl"))
include(joinpath(BIN, "weather_load.jl"))
include(joinpath(BIN, "ml_inputs.jl"))

# rollout-39: the reference file names whichever zones the dumper emitted (a few
# pilots + a few new zones as spot-checks). Only committed (winner) models are
# compared — a target absent from a zone's meta shipped the pack, so the ref never
# carries a `new_<t>` for it and the port never dereferences a missing model.
ref = JSON.parsefile(joinpath(SP, "eval_ref.json"))
const PILOTS = sort(collect(keys(ref)))
models = load_ml_models(PILOTS)
has_model(t, z) = (t == "solar" ? haskey(models.solar, z) :
                   t == "wind" ? haskey(models.wind, z) : haskey(models.load, z))
geom = ml_geom()
_num(x) = x === nothing ? NaN : Float64(x)

# ── running max abs / rel diff accumulator ────────────────────────────────────
mutable struct DiffAcc; maxabs::Float64; maxrel::Float64; n::Int; nbig::Int; worst::String; end
DiffAcc() = DiffAcc(0.0, 0.0, 0, 0, "")
function upd!(a::DiffAcc, jl::Float64, py::Float64, tag::String="")
    (isnan(jl) && isnan(py)) && return
    d = abs(jl - py)
    d > a.maxabs && (a.worst = tag)
    a.maxabs = max(a.maxabs, d)
    a.maxrel = max(a.maxrel, d / max(abs(py), 1.0)); a.n += 1
    d > 0.5 && (a.nbig += 1)   # hours whose end-to-end prediction visibly flipped
end

println("="^72)
println("PART 1 — SCORER on identical (reference) feature vectors")
println("="^72)
p1 = Dict(t => DiffAcc() for t in ("solar", "wind", "load"))
for z in PILOTS
    for (key, rec) in ref[z]
        if has_model("solar", z) && haskey(rec, "feats_solar")
            fs = models.meta["$(z)_solar"]["feat_cols"]
            feats_s = Dict{String,Float64}(fs[i] => _num(rec["feats_solar"][i]) for i in eachindex(fs))
            upd!(p1["solar"], ml_predict_solar(models, z, feats_s), _num(rec["new_solar"]))
        end
        if has_model("wind", z) && haskey(rec, "feats_wind")
            fw = models.meta["$(z)_wind"]["feat_cols"]
            feats_w = Dict{String,Float64}(fw[i] => _num(rec["feats_wind"][i]) for i in eachindex(fw))
            upd!(p1["wind"], ml_predict_wind(models, z, feats_w), _num(rec["new_wind"]))
        end
        if has_model("load", z) && haskey(rec, "feats_load")
            fl = models.meta["$(z)_load"]["feat_cols"]
            feats_l = Dict{String,Float64}(fl[i] => _num(rec["feats_load"][i]) for i in eachindex(fl))
            upd!(p1["load"], ml_predict_load(models, z, feats_l), _num(rec["new_load"]))
        end
    end
end
for t in ("load", "solar", "wind")
    @printf("  %-6s  n=%-5d  max|Δ|=%.3e  max relΔ=%.3e\n", t, p1[t].n, p1[t].maxabs, p1[t].maxrel)
end

println("\n" * "="^72)
println("PART 2 — FEATURE PORT + full predict from GFS parquets + extract")
println("="^72)

# ---- read the GFS parquets (identical weather to python) ----
con = DuckDB.DB()
resfiles = filter(f -> startswith(basename(f), "res_") && endswith(f, ".parquet"),
                  readdir(joinpath(SP, "gfs"), join=true))
loadfiles = filter(f -> startswith(basename(f), "load_") && endswith(f, ".parquet"),
                   readdir(joinpath(SP, "gfs"), join=true))
plist(fs) = "[" * join(("'" * f * "'" for f in fs), ",") * "]"
resdf = DataFrame(DuckDB.query(con, "SELECT loc_id, zone, h, wind_speed_100m, shortwave_radiation, cloud_cover, surface_pressure FROM read_parquet($(plist(resfiles)))"))
loaddf = DataFrame(DuckDB.query(con, "SELECT loc_id, zone, h, temperature_2m, shortwave_radiation FROM read_parquet($(plist(loadfiles)))"))

# per-zone cell/city weather dicts keyed by geom coordinate
function res_weather_for(z)
    cells = [(Float64(c[1]), Float64(c[2])) for c in geom[z]["cells"]]
    w = Dict{Tuple{Float64,Float64},Dict{DateTime,NTuple{4,Float64}}}()
    sub = resdf[resdf.zone .== z, :]
    for r in eachrow(sub)
        ci = parse(Int, split(String(r.loc_id), "#c")[2])
        cell = cells[ci + 1]
        h = DateTime(r.h)
        d = get!(w, cell, Dict{DateTime,NTuple{4,Float64}}())
        d[h] = (_num(r.wind_speed_100m), _num(r.shortwave_radiation),
                _num(r.cloud_cover), _num(r.surface_pressure))
    end
    return cells, w
end
function load_weather_for(z)
    cities = [(Float64(c[1]), Float64(c[2]), Float64(c[3])) for c in geom[z]["cities"]]
    w = Dict{Tuple{Float64,Float64},Dict{DateTime,Tuple{Float64,Float64}}}()
    sub = loaddf[loaddf.zone .== z, :]
    for r in eachrow(sub)
        li = parse(Int, split(String(r.loc_id), "#l")[2])
        city = (cities[li + 1][1], cities[li + 1][2])
        h = DateTime(r.h)
        d = get!(w, city, Dict{DateTime,Tuple{Float64,Float64}}())
        d[h] = (_num(r.temperature_2m), _num(r.shortwave_radiation))
    end
    return cities, w
end

# target days present in the reference
allkeys = sort(collect(keys(ref["GR"])))
days = sort(unique(Date(DateTime(k, dateformat"yyyymmdd-HHMM")) for k in allkeys))
cap = ml_capacity_p95(PILOTS, days)
allhours = [DateTime(k, dateformat"yyyymmdd-HHMM") for k in allkeys]
ar = ml_ar_load_lags(PILOTS, allhours)

feat_acc = DiffAcc()               # every scalar feature value
pred_acc = Dict(t => DiffAcc() for t in ("solar", "wind", "load"))
base_acc = Dict(t => DiffAcc() for t in ("solar", "wind", "load"))
worst_feat = ("", "", 0.0)

for z in PILOTS
    lat0, lon0 = ml_zone_centroid(geom, z)
    cells, rw = res_weather_for(z)
    cities, lw = load_weather_for(z)
    ragg = ml_res_agg(cells, rw)
    lagg = ml_load_agg(cities, lw)
    Tseries = Dict{DateTime,Float64}(h => v[1] for (h, v) in lagg)
    holset = ml_holidays(String(load_load_models()["zones"][z]["holiday_country"]), 2024:2027)
    zpack = load_res_models()["zones"][z]
    for (key, rec) in ref[z]
        h = DateTime(key, dateformat"yyyymmdd-HHMM"); D = Date(h)
        ra = get(ragg, h, nothing); ra === nothing && continue
        ghi, cloud, pres, v100m = ra
        c95s = get(cap[(z, :solar)], D, NaN); c95w = get(cap[(z, :wind)], D, NaN)
        feats_s = ml_res_features(h, lat0, lon0, ghi, cloud, pres, v100m, c95s, c95w)
        # SOLAR (only where a NEW model shipped for this zone)
        if has_model("solar", z) && haskey(rec, "feats_solar")
            fs = models.meta["$(z)_solar"]["feat_cols"]
            for (i, n) in enumerate(fs)
                jl = feats_s[n]; py = _num(rec["feats_solar"][i]); upd!(feat_acc, jl, py)
                d = abs(jl - py); d > worst_feat[3] && !isnan(d) && (global worst_feat = (z * ":" * n, key, d))
            end
            upd!(pred_acc["solar"], ml_predict_solar(models, z, feats_s), _num(rec["new_solar"]), "$z@$key")
        end
        # WIND (only where a NEW model shipped for this zone)
        if has_model("wind", z) && haskey(rec, "feats_wind")
            fw = models.meta["$(z)_wind"]["feat_cols"]
            for (i, n) in enumerate(fw)
                upd!(feat_acc, feats_s[n], _num(rec["feats_wind"][i]))
            end
            upd!(pred_acc["wind"], ml_predict_wind(models, z, feats_s), _num(rec["new_wind"]), "$z@$key")
        end
        # baseline components (pack) — validate the reuse path where the ref carries it
        if haskey(rec, "base_solar")
            bs = haskey(zpack, "solar") ? predict_solar_hour(zpack["solar"], ghi, h) : 0.0
            upd!(base_acc["solar"], bs, _num(rec["base_solar"]))
        end
        if haskey(rec, "base_wind")
            vv = Float64[get(get(rw, cell, Dict{DateTime,NTuple{4,Float64}}()), h, (NaN,NaN,NaN,NaN))[1] for cell in cells]
            bw = (haskey(zpack, "wind") && !any(isnan, vv)) ? max(predict_wind_hour(zpack["wind"], vv), 0.0) : 0.0
            upd!(base_acc["wind"], bw, _num(rec["base_wind"]))
        end
        # LOAD (only where a NEW load model shipped for this zone)
        if has_model("load", z) && haskey(rec, "feats_load")
            fl = models.meta["$(z)_load"]["feat_cols"]
            la = get(lagg, h, nothing)
            if la !== nothing && !isnan(la[1])
                T, ghiL = la; Tma = ml_trailing_ma48(Tseries, h)
                ar1 = get(ar[z], h - Day(1), NaN); ar7 = get(ar[z], h - Day(7), NaN)
                is_hol = (Date(h) in holset) ? 1.0 : 0.0
                feats_l = ml_load_features(h, lat0, lon0, T, ghiL, Tma, ar1, ar7, is_hol, v100m)
                for (i, n) in enumerate(fl)
                    jl = feats_l[n]; py = _num(rec["feats_load"][i]); upd!(feat_acc, jl, py)
                    d = abs(jl - py); d > worst_feat[3] && !isnan(d) && (global worst_feat = (z * ":" * n, key, d))
                end
                upd!(pred_acc["load"], ml_predict_load(models, z, feats_l), _num(rec["new_load"]))
            end
        end
    end
end

@printf("\n  ALL FEATURES        n=%-6d  max|Δ|=%.3e  max relΔ=%.3e   (worst: %s @ %s = %.3e)\n",
        feat_acc.n, feat_acc.maxabs, feat_acc.maxrel, worst_feat[1], worst_feat[2], worst_feat[3])
println("\n  NEW model predictions (Julia port vs python), identical GFS+extract inputs:")
for t in ("load", "solar", "wind")
    @printf("    %-6s  n=%-5d  max|Δ|=%.3e MW  max relΔ=%.3e  |Δ|>0.5MW: %d hrs  (worst %s)\n",
            t, pred_acc[t].n, pred_acc[t].maxabs, pred_acc[t].maxrel, pred_acc[t].nbig, pred_acc[t].worst)
end
println("\n  Baseline pack components (weather_res.jl reuse vs python baseline.py):")
for t in ("solar", "wind")
    @printf("    %-6s  n=%-5d  max|Δ|=%.3e MW  max relΔ=%.3e\n", t, base_acc[t].n, base_acc[t].maxabs, base_acc[t].maxrel)
end

# ── PASS/FAIL gate ────────────────────────────────────────────────────────────
# Equivalence criteria (see docs/experiments/input-upgrade/wiring.md):
#  (1) the SCORER is bit-identical to python LightGBM on identical feature vectors;
#  (2) the FEATURE PORT reproduces every feature to floating-point precision
#      (rel < 1e-9 — the residual is cell-mean/percentile summation-order noise);
#  (3) end-to-end NEW predictions are therefore bit-identical EXCEPT where a
#      feature sits within ~1e-13 of a tree split threshold and the discrete split
#      flips — the documented last-ULP mechanism (Postgres↔DuckDB parity note),
#      not a port bug. This applies to LOAD as well as RES (the same LightGBM
#      evaluator; the pilot happened to see zero load flips, not a guarantee).
#      We bound total flips across all three targets at ≤1% of predictions.
scorer_ok = p1["load"].maxabs == 0 && p1["solar"].maxabs == 0 && p1["wind"].maxabs == 0
feats_ok = feat_acc.maxrel < 1e-9
flips = pred_acc["load"].nbig + pred_acc["solar"].nbig + pred_acc["wind"].nbig
tot_n = pred_acc["load"].n + pred_acc["solar"].n + pred_acc["wind"].n
flips_ok = flips <= max(cld(tot_n, 100), 1)   # ≤1% of hours may flip a near-threshold split
ok = scorer_ok && feats_ok && flips_ok
@printf("\n  scorer bit-identical: %s | features rel<1e-9: %s | split-flips: %d/%d (≤1%% ok: %s)\n",
        scorer_ok, feats_ok, flips, tot_n, flips_ok)
println("\n", ok ? "EQUIVALENCE PASS ✅" : "EQUIVALENCE FAIL ❌")
println("ML_EQUIV_DONE")
