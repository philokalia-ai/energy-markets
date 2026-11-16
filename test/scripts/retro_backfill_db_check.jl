# DB check of the cv44 ALONGSIDE retro writer (#431 R1; NOT CI). Run against a
# PRIVATE Postgres holding live forecast_prices rows (never production):
#   ENERGY_CONN_STR=<private> EUPHEMIA_DATA_STORE=postgres EUPHEMIA_FORECAST_NO_AUTORUN=1 \
#     julia --project=. test/scripts/retro_backfill_db_check.jl <live_day> <live_cv44_day> [n_days_to_backfill]
# <live_day>: a market day with a LIVE lead-1 weather slice at a cv != 44.
# <live_cv44_day>: a day whose LIVE lead-1 weather slice is cv44 (the writer must refuse).
# With n_days_to_backfill > 0 it then writes that many consecutive days from <live_day>
# (synthetic prices: live x 0.9 + 3) as campaign rows, for the scorer/exporter checks.
ENV["EUPHEMIA_FORECAST_NO_AUTORUN"] = "1"
ENV["INPUT_MODE"] = "weather"
include(joinpath(@__DIR__, "..", "..", "bin", "daily_forecast.jl"))
using Test

const TAG = "cv44-backfill-2026-11"
const DAY = Date(ARGS[1]); const DAY44 = Date(ARGS[2])
const NFILL = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 0
q(sql, args=[]) = Euphemia.sql2df(sql, args)
live_sig(d) = q("""SELECT COUNT(*) AS n, COALESCE(SUM(price_eur_mwh), 0) AS s,
                   MIN(code_version) AS cv0, MAX(code_version) AS cv1
                   FROM simulations.forecast_prices
                   WHERE market_date = \$1 AND lead_days = 1 AND input_mode = 'weather' AND is_retro = false""", [d])[1, :]
retro_n(d) = Int(q("""SELECT COUNT(*) AS n FROM simulations.forecast_prices WHERE market_date = \$1
                     AND lead_days = 1 AND input_mode = 'weather' AND is_retro AND reset_tag = \$2
                     AND code_version = \$3""", [d, TAG, CV]).n[1])
function synth(d)   # zone -> hour -> price, from the live slice (synthetic reconstruction)
    df = q("""SELECT bidding_zone AS z, (date_time_utc AT TIME ZONE 'UTC') AS t, price_eur_mwh AS p
              FROM simulations.forecast_prices WHERE market_date = \$1 AND lead_days = 1
              AND input_mode = 'weather' AND is_retro = false""", [d])
    zh = Dict{String,Dict{DateTime,Float64}}()
    for r in eachrow(df); get!(Dict{DateTime,Float64}, zh, String(r.z))[DateTime(r.t)] = 0.9 * r.p + 3; end
    return zh
end
chosen_cv(d, cte) = q("WITH $cte SELECT code_version FROM chosen WHERE market_date = \$1 AND lead_days = 1 AND input_mode = 'weather'", [d]).code_version[1]
const OLD_CTE = replace(CHOSEN_SLICE_CTE, ",\n                     BOOL_AND(is_retro) AS all_retro" => "", " all_retro," => "")

Euphemia.ensure_forecast_tables()
q("DELETE FROM simulations.forecast_prices WHERE is_retro AND reset_tag = \$1", [TAG])
@testset "alongside retro writer (#431 R1)" begin
    @test CV == 44
    l0 = live_sig(DAY)
    @test l0.n > 0 && l0.cv1 != 44
    zh = synth(DAY); nexp = sum(length, values(zh))
    retro_of = DateTime(DAY - Day(1)) + Hour(6) + Minute(30)
    n = write_forecast!(DAY, 1, now(UTC), zh, "weather"; is_retro=true, reset_tag=TAG,
                        retro_of_utc=retro_of, alongside=true)
    @test n == nexp && retro_n(DAY) == nexp                   # added next to the live slice
    @test live_sig(DAY) == l0                                 # live untouched
    n2 = write_forecast!(DAY, 1, now(UTC), zh, "weather"; is_retro=true, reset_tag=TAG,
                         retro_of_utc=retro_of, alongside=true)
    @test n2 == nexp && retro_n(DAY) == nexp && live_sig(DAY) == l0   # idempotent rerun
    # supersede is impossible in alongside mode (hard error, nothing changes)
    withenv("EUPHEMIA_RETRO_SUPERSEDE" => "1") do
        @test_throws ArgumentError write_forecast!(DAY, 1, now(UTC), zh, "weather"; is_retro=true,
                                                   reset_tag=TAG, retro_of_utc=retro_of, alongside=true)
    end
    @test live_sig(DAY) == l0 && retro_n(DAY) == nexp
    # ... also when the caller OMITS alongside: the campaign tag forces it in the writer
    withenv("EUPHEMIA_RETRO_SUPERSEDE" => "1") do
        @test_throws ArgumentError write_forecast!(DAY, 1, now(UTC), zh, "weather"; is_retro=true,
                                                   reset_tag=TAG, retro_of_utc=retro_of)
        @test_throws ArgumentError write_forecast!(DAY, 1, now(UTC), zh, "weather"; is_retro=true,
                                                   reset_tag=TAG, retro_of_utc=retro_of, alongside=false)
    end
    @test live_sig(DAY) == l0 && retro_n(DAY) == nexp
    # without supersede, omitting alongside still writes alongside (live kept)
    @test write_forecast!(DAY, 1, now(UTC), zh, "weather"; is_retro=true, reset_tag=TAG,
                          retro_of_utc=retro_of) == nexp
    @test live_sig(DAY) == l0 && retro_n(DAY) == nexp
    @test Int(q("SELECT COUNT(*) AS n FROM simulations.forecast_prices_pre_reset WHERE market_date = \$1", [DAY]).n[1]) == 0
    @test_throws ArgumentError write_forecast!(DAY, 1, now(UTC), zh, "weather"; is_retro=false, alongside=true)
    @test_throws ArgumentError write_forecast!(DAY, 1, now(UTC), zh, "weather"; is_retro=true, alongside=true)  # no tag
    # a LIVE cv44 slice is the real record: refused, nothing written, live untouched
    l44 = live_sig(DAY44)
    @test l44.n > 0 && l44.cv1 == 44
    @test write_forecast!(DAY44, 1, now(UTC), synth(DAY44), "weather"; is_retro=true, reset_tag=TAG,
                          retro_of_utc=DateTime(DAY44 - Day(1)) + Hour(6) + Minute(30), alongside=true) == 0
    @test retro_n(DAY44) == 0 && live_sig(DAY44) == l44
    # the legacy (non-alongside) retro path still refuses to touch a live day
    @test write_forecast!(DAY, 1, now(UTC), zh, "weather"; is_retro=true, reset_tag="legacy-check",
                          retro_of_utc=retro_of) == 0
    @test live_sig(DAY) == l0 && retro_n(DAY) == nexp
    # the resume helpers see the campaign rows only
    @test issubset(keys(zh), existing_retro_zones(DAY, 1, "weather", TAG, CV))
    @test isempty(existing_retro_zones(DAY + Day(40), 1, "weather", TAG, CV))
    @test live_slice_has_cv(DAY44, 1, "weather", 44) && !live_slice_has_cv(DAY, 1, "weather", 44)
    # chosen slice: live wins; and stays live even if a retro stamp were EARLIER (hard rule)
    @test chosen_cv(DAY, CHOSEN_SLICE_CTE) == l0.cv1 == chosen_cv(DAY, OLD_CTE)
    q("UPDATE simulations.forecast_prices SET prediction_made_utc = '2026-01-01 00:00+00' WHERE is_retro AND reset_tag = \$1 AND market_date = \$2", [TAG, DAY])
    @test chosen_cv(DAY, CHOSEN_SLICE_CTE) == l0.cv1          # new rule: live
    @test chosen_cv(DAY, OLD_CTE) == 44                       # old rule would have shown the reconstruction
    q("UPDATE simulations.forecast_prices SET prediction_made_utc = now() WHERE is_retro AND reset_tag = \$1 AND market_date = \$2", [TAG, DAY])
end

if NFILL > 0   # campaign-like rows for the scorer/exporter checks
    t0 = time(); nw = 0
    for d in DAY:Day(1):(DAY + Day(NFILL - 1))
        global nw += write_forecast!(d, 1, now(UTC), synth(d), "weather"; is_retro=true, reset_tag=TAG,
                                     retro_of_utc=DateTime(d - Day(1)) + Hour(6) + Minute(30), alongside=true)
    end
    println("backfill fixture: $nw rows over $NFILL day(s) from $DAY in $(round(time() - t0; digits=1)) s")
end
