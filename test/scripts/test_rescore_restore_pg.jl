# Native Postgres test of the rescore-hourly campaign and its rollback (#431 C2 review).
# Creates, uses and stops its OWN throwaway cluster (initdb, Unix socket only); reads no
# external DSN, production configuration or credentials.
#
#   PG_BIN=<dir with initdb/pg_ctl> julia --project=. test/scripts/test_rescore_restore_pg.jl
#
# PG_BIN defaults to the directory of `initdb` on PATH, else the newest
# /usr/lib/postgresql/*/bin. Without one the test prints SKIP and exits 0.
#
# Scenario (the reviewer's repro, end to end through the real scripts):
#   scores for AT and GR at MAE 10 -> snapshot -> rescore AT only, 2026-11-10..11 with the
#   SDAC target (campaign record written) -> later activity: GR and AT 11-11 rescored by
#   someone else -> campaign-scoped restore: only AT 11-10 returns to its snapshot state
#   (incl. scored_at); AT 11-11 (rescored since) and GR (not in the campaign) are left; the
#   campaign-created key is reported, not deleted; q15 columns untouched throughout.
using Dates, Test, CSV, DataFrames, LibPQ

const ROOT = dirname(dirname(@__DIR__))

function pg_bin()
    b = get(ENV, "PG_BIN", "")
    isempty(b) || return b
    w = Sys.which("initdb")
    w === nothing || return dirname(w)
    base = "/usr/lib/postgresql"
    isdir(base) || return ""
    vs = sort(filter(v -> isfile(joinpath(base, v, "bin", "initdb")), readdir(base)), by=v -> parse(Int, v))
    return isempty(vs) ? "" : joinpath(base, vs[end], "bin")
end

function parent()
    bin = pg_bin()
    if isempty(bin)
        println("SKIP: no PostgreSQL binaries (set PG_BIN)")
        return 0
    end
    dir = mktempdir("/tmp"; prefix="rescorepg_")   # short path: Unix socket length limit
    data, sock = joinpath(dir, "data"), joinpath(dir, "sock")
    mkpath(sock)
    port = string(56000 + rand(0:999))
    user = get(ENV, "USER", "postgres")
    run(pipeline(`$(joinpath(bin, "initdb")) -D $data -A trust -U $user`, stdout=devnull))
    run(`$(joinpath(bin, "pg_ctl")) -D $data -l $(joinpath(dir, "pg.log")) -w
         -o "-p $port -k $sock -c listen_addresses=''" start`)
    code = 1
    try
        run(`$(joinpath(bin, "createdb")) -h $sock -p $port -U $user rescore_test`)
        env = copy(ENV)
        for k in ("EUPHEMIA_DUCKDB_PATH", "EUPHEMIA_DUCKDB_READONLY", "EUPHEMIA_DA_TARGET", "EUPHEMIA_DA_INPUT")
            delete!(env, k)
        end
        env["EUPHEMIA_DATA_STORE"] = "postgres"
        env["ENERGY_CONN_STR"] = "host=$sock port=$port dbname=rescore_test user=$user"
        env["EUPHEMIA_PG_POOL"] = "2"
        p = run(ignorestatus(setenv(`$(Base.julia_cmd()) --project=$ROOT $(@__FILE__) --child $dir`, env)))
        code = p.exitcode
    finally
        run(ignorestatus(`$(joinpath(bin, "pg_ctl")) -D $data -m fast -w stop`))
        rm(dir; recursive=true, force=true)
    end
    println(code == 0 ? "PG TEST PASSED" : "PG TEST FAILED (exit $code)")
    return code
end

# ---- child: runs against the throwaway cluster (ENERGY_CONN_STR set by the parent) ----
get(ARGS, 1, "") == "--child" || exit(parent())
const work = ARGS[2]
using Euphemia
include(joinpath(ROOT, "bin", "forecast_scores_snapshot.jl"))   # snapshot/restore (guarded main)
q(sql, args=Any[]) = Euphemia.withdb(c -> DataFrame(LibPQ.execute(c, sql, args)))
Euphemia.ensure_forecast_tables()
q("ALTER TABLE simulations.forecast_scores ADD COLUMN IF NOT EXISTS mae_q15 DOUBLE PRECISION")
q("CREATE SCHEMA IF NOT EXISTS entsoe")
q("""CREATE TABLE entsoe.energy_prices (map_code text, sequence text, resolution_code text,
     date_time_utc timestamptz, price_currency_mwh double precision, update_time_utc timestamptz,
     contract_type text, area_type_code text, currency text)""")
for t in DateTime(2026, 11, 9):Hour(1):DateTime(2026, 11, 11, 23), (z, s, p) in
        (("AT", "1", 80.0), ("AT", "2", 60.0), ("GR", "", 50.0))   # AT: SDAC 80, EXAA 60
    q("""INSERT INTO entsoe.energy_prices VALUES (\$1, \$2, 'PT60M', \$3::timestamp AT TIME ZONE 'UTC',
         \$4, '2026-11-08 12:00+00', 'Day-ahead', 'BZN|$z', 'EUR')""", Any[z, s, t, p])
end
slices = [("AT", Date(2026, 11, 10), "weather"), ("AT", Date(2026, 11, 11), "weather"),
          ("GR", Date(2026, 11, 10), "weather"), ("GR", Date(2026, 11, 11), "weather"),
          ("AT", Date(2026, 11, 11), "entsoe")]      # the last has no score yet
for (z, d, mode) in slices, h in 0:23
    t = DateTime(d - Day(1)) + Hour(22 + h)             # Athens day D = UTC D-1 22:00 .. D 21:00
    q("""INSERT INTO simulations.forecast_prices (market_date, date_time_utc, bidding_zone,
         price_eur_mwh, prediction_made_utc, lead_days, code_version, input_mode)
         VALUES (\$1, \$2::timestamp AT TIME ZONE 'UTC', \$3, 100, '2026-11-08 09:00+00', 1, 44, \$4)""",
      Any[d, t, z, mode])
end
for (z, d, mode) in slices[1:4]
    q("""INSERT INTO simulations.forecast_scores (market_date, bidding_zone, lead_days, code_version,
         input_mode, n_hours, mae, bias, corr, is_retro, scored_at, mae_q15)
         VALUES (\$1, \$2, 1, 44, \$3, 24, 10, 1, 0.5, false, '2026-11-12 00:00:00+00', 7)""", Any[d, z, mode])
end
mae(z, d, mode="weather") = q("""SELECT mae, mae_q15, scored_at::text AS s FROM simulations.forecast_scores
    WHERE bidding_zone = \$1 AND market_date = \$2 AND input_mode = \$3""", Any[z, d, mode])
jl = `$(Base.julia_cmd()) --project=$ROOT`
snap, keys = joinpath(work, "snap.csv"), joinpath(work, "keys.csv")
d10, d11 = Date(2026, 11, 10), Date(2026, 11, 11)

@testset "rescore-hourly campaign + scoped restore (native PG)" begin
    run(`$jl $(joinpath(ROOT, "bin", "forecast_scores_snapshot.jl")) snapshot $snap`)
    orig = mae("AT", d10).s[1]
    run(addenv(`$jl $(joinpath(ROOT, "bin", "score_forecasts.jl"))`,
               "RESCORE" => "true", "HOURLY_ONLY" => "true", "SCORE_LOCK_TIMEOUT" => "5s",
               "EUPHEMIA_DA_TARGET" => "sdac", "RESCORE_ZONES" => "AT",
               "RESCORE_START" => "2026-11-10", "RESCORE_END" => "2026-11-11",
               "RESCORE_KEYS_OUT" => keys))
    k = CSV.read(keys, DataFrame; types=Dict(:campaign_scored_at => String))
    @test nrow(k) == 3 && all(==("AT"), k.bidding_zone)
    @test mae("AT", d10).mae[1] == 20 && mae("AT", d11).mae[1] == 20     # |100 - SDAC 80|
    @test mae("AT", d11, "entsoe").mae[1] == 20                          # created by the campaign
    @test mae("GR", d10).mae[1] == 10                                    # outside the campaign
    @test all(==(7), q("SELECT mae_q15 FROM simulations.forecast_scores WHERE mae_q15 IS NOT NULL").mae_q15)
    @test mae("AT", d10).s[1] == k.campaign_scored_at[k.market_date .== d10 .&& k.input_mode .== "weather"][1]

    # later activity by someone else (daily window, another run)
    q("UPDATE simulations.forecast_scores SET mae = 77, scored_at = now() WHERE bidding_zone = 'GR' AND market_date = \$1", Any[d10])
    q("UPDATE simulations.forecast_scores SET mae = 55, scored_at = now() WHERE bidding_zone = 'AT' AND market_date = \$1 AND input_mode = 'weather'", Any[d11])

    @test_throws ErrorException withenv(() -> restore(snap, keys), "CONFIRM_RESTORE" => nothing)
    r = withenv(() -> restore(snap, keys), "CONFIRM_RESTORE" => "yes")
    @test r == (restored=1, skipped=1, created=1)
    @test mae("AT", d10).mae[1] == 10 && mae("AT", d10).s[1] == orig   # exact pre-campaign state
    @test mae("AT", d11).mae[1] == 55                                  # rescored since: kept
    @test mae("GR", d10).mae[1] == 77 && mae("GR", d11).mae[1] == 10   # not in the campaign
    @test mae("AT", d11, "entsoe").mae[1] == 20                        # created: reported, kept
    @test all(==(7), q("SELECT mae_q15 FROM simulations.forecast_scores WHERE mae_q15 IS NOT NULL").mae_q15)
    r2 = withenv(() -> restore(snap, keys), "CONFIRM_RESTORE" => "yes")
    @test r2 == (restored=0, skipped=2, created=1)                     # idempotent

    # the daily path (no SCORE_LOCK_TIMEOUT, no campaign record, default target) still writes
    run(addenv(`$jl $(joinpath(ROOT, "bin", "score_forecasts.jl"))`, "RESCORE" => "true",
               "RESCORE_ZONES" => "GR", "RESCORE_START" => "2026-11-10", "RESCORE_END" => "2026-11-10"))
    @test mae("GR", d10).mae[1] == 50                                  # |100 - 50|
end
