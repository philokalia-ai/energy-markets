# DB-dependent: both exporters carry the TSFM overlay fields (JSON zone files +
# zone parquets). Needs a Postgres (EUPHEMIA_DATA_STORE=postgres,
# ENERGY_CONN_STR) holding simulations.forecast_prices / forecast_scores /
# model_lines / overlay_probabilities and entsoe.energy_prices for one market
# day OVERLAY_TEST_DATE, after `bin/emit_tsfm_overlay.py --write` ran for it.
# Writes only to temp dirs. Usage:
#   OVERLAY_TEST_DATE=2026-11-14 OVERLAY_TEST_ZONE=GR julia --project=. test/manual/test_tsfm_overlay_export.jl
using Test, Dates, JSON, DataFrames, DuckDB
const D = Date(get(ENV, "OVERLAY_TEST_DATE", "2026-11-14"))
const ZONE = get(ENV, "OVERLAY_TEST_ZONE", "GR")
tmp = get(ENV, "OVERLAY_TEST_OUT", "") == "" ? mktempdir() : mkpath(ENV["OVERLAY_TEST_OUT"])
ENV["WEB_PARQUET_OUT"] = joinpath(tmp, "web")
src(f) = replace(read(joinpath(@__DIR__, "..", "..", "bin", f), String), r"\nmain\(\)\s*$" => "\n")
# JSON exporter into a temp OUT_DIR (its const points at web/data)
include_string(Main, replace(src("export_forecast_json.jl"),
    "const OUT_DIR = joinpath(dirname(@__DIR__), \"web\", \"data\")" => "const OUT_DIR = $(repr(joinpath(tmp, "json")))"),
    joinpath(@__DIR__, "..", "..", "bin", "export_forecast_json.jl"))
export_zone_files()
@testset "zone JSON carries the TSFM overlay ($ZONE $D)" begin
    days = JSON.parsefile(joinpath(tmp, "json", "zones", "$ZONE.json"))["days"]
    e = only(filter(x -> x["date"] == string(D) && x["lead_days"] == 1, days))
    n = length(e["hours"])
    @test length(e["tsfm"]) == n && all(!isnothing, e["tsfm"])
    @test all(e["tsfm_q10"] .<= e["tsfm"] .<= e["tsfm_q90"])
    @test length(e["p_le0"]) == n && all(p -> 0 <= p <= 1, e["p_le0"])
    @test 0 <= e["p_any_le0"] <= 1
    @test e["p_any_le0"] >= maximum(e["p_le0"]) - 0.5   # blend of max-hour TSFM and the day logistic
    @test e["tsfm_input_mode"] in ("pregate0630", "postsim")
    @test startswith(e["tsfm_arm"], "timestral") || e["tsfm_arm"] == "chronos2"
    @test haskey(e, "gbm") && haskey(e, "stats")          # existing fields untouched
end
module P end   # parquet exporter in its own module (it redefines MAX_DAYS etc.)
Base.include_string(P, "using Euphemia, Dates, DataFrames\n" * src("export_web_parquet.jl"),
                    joinpath(@__DIR__, "..", "..", "bin", "export_web_parquet.jl"))
Base.invokelatest(P.export_zone_parquets)
@testset "zone parquet carries the TSFM overlay columns ($ZONE $D)" begin
    f = joinpath(tmp, "web", "v1", "zones", "$ZONE.parquet")
    db = DuckDB.DB(); df = DataFrame(DuckDB.execute(db, "SELECT * FROM '$f'"))
    for c in ("tsfm", "tsfm_q10", "tsfm_q90", "p_le0", "p_any_le0", "tsfm_input_mode", "tsfm_issue_utc", "tsfm_arm")
        @test c in names(df)
    end
    sub = df[(df.market_date .== D) .& (df.lead_days .== 1), :]
    @test nrow(sub) > 0 && all(!ismissing, sub.tsfm) && length(unique(sub.p_any_le0)) == 1
    old = df[df.market_date .< D, :]
    @test nrow(old) == 0 || all(ismissing, old.p_any_le0)   # days without an overlay stay null
end
