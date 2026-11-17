# Run only against the disposable Unix-socket cluster made by test_input_snapshot_pg.sh.
using Test, Euphemia, LibPQ, DataFrames, Dates
socket = ENV["RETRO_TEST_PG_SOCKET"]
startswith(socket, "/tmp/retro-input-pg.") || error("requires disposable fixture socket")
connstr = "host=$socket port=55464 dbname=postgres user=snapshot_test"
ENV["ENERGY_CONN_STR"] = connstr
ENV["EUPHEMIA_FORECAST_NO_AUTORUN"] = "1"
ENV["EUPHEMIA_RETRO_ALONGSIDE"] = "1"
ENV["EUPHEMIA_RETRO_SUPERSEDE"] = "false"
include(joinpath(@__DIR__, "..", "..", "bin", "daily_forecast.jl"))
Euphemia.DATA_STORE[] = :postgres
connect() = LibPQ.Connection(connstr)
admin = connect()
LibPQ.execute(admin, "CREATE SCHEMA entsoe")
LibPQ.execute(admin, "CREATE TABLE entsoe.snapshot_probe(id int, value int)")
LibPQ.execute(admin, "INSERT INTO entsoe.snapshot_probe VALUES (1,10)")
LibPQ.execute(admin, "CREATE TABLE entsoe.production_and_generation_units(area_map_code text, generation_unit_code text)")
LibPQ.execute(admin, "CREATE TABLE entsoe.actual_generation_output_per_generation_unit(generation_unit_code text, date_time_utc timestamp, actual_generation_output_mw double precision)")
LibPQ.execute(admin, "INSERT INTO entsoe.production_and_generation_units VALUES ('GR','a'),('GR','a'),('BG','a'),('BG','b'),('RO','empty')")
LibPQ.execute(admin, "INSERT INTO entsoe.actual_generation_output_per_generation_unit VALUES ('a','2026-06-01',20),('a','2026-09-16',30),('b','2026-09-12',0),('b','2026-09-13',40)")
Euphemia.ensure_forecast_tables()

@testset "Real PG MVCC input view with independent live state/writes" begin
    s = Euphemia.open_pg_input_snapshot(["GR","BG","RO"]; connect=connect)
    @test startswith(s.revision, "pg:")
    @test !isempty(s.captured_at)
    try
        Euphemia.with_input_snapshot(s) do
            @test Euphemia.sql2df("SELECT value FROM entsoe.snapshot_probe").value == [10]
            LibPQ.execute(admin, "UPDATE entsoe.snapshot_probe SET value=20")
            @test Euphemia.sql2df("SELECT value FROM entsoe.snapshot_probe").value == [10]
            # Misses on both imported read connections must see the original view.
            @test Euphemia.sql2df("SELECT value+0 AS value FROM entsoe.snapshot_probe").value == [10]
            @test Euphemia.sql2df("SELECT value*1 AS value FROM entsoe.snapshot_probe").value == [10]
            @test Euphemia.sql2df_live_with_retry("SELECT value FROM entsoe.snapshot_probe").value == [20]
            @test_throws LibPQ.Errors.UndefinedTable Euphemia.sql2df_optional_input("SELECT price_eur FROM carbon.uka_price", [])
            @test s.failure === nothing
            # Savepoint recovery retains both read transactions and their revision.
            @test Euphemia.sql2df("SELECT value+1 AS value FROM entsoe.snapshot_probe").value == [11]
            @test Euphemia.sql2df("SELECT value+2 AS value FROM entsoe.snapshot_probe").value == [12]
            for z in ["GR","BG","RO"]
                bound=DateTime(2026,9,14)
                reference=DataFrame(LibPQ.execute(admin,"""
                    SELECT MAX(date_time_utc) AS last_obs
                    FROM entsoe.actual_generation_output_per_generation_unit
                    WHERE generation_unit_code IN (
                      SELECT DISTINCT generation_unit_code FROM entsoe.production_and_generation_units WHERE area_map_code=\$1)
                      AND date_time_utc < \$2 AND actual_generation_output_mw>0
                    """,Any[z,bound])).last_obs[1]
                @test isequal(Euphemia.snapshot_feed_anchor(s,z,bound), ismissing(reference) ? nothing : reference)
            end
            # The actual production writer and actual discovery helpers remain live,
            # even when called defensively from inside the input read scope.
            day=Date(2026,9,14)
            @test isempty(existing_retro_zones(day,1,"weather","snapshot-fixture",CV))
            rows=Dict("GR"=>Dict(DateTime(day)=>123.0))
            @test write_forecast!(day,1,DateTime(2026,11,17),rows,"weather";
                is_retro=true,reset_tag="snapshot-fixture",retro_of_utc=DateTime(day-Day(1)),alongside=true)==1
            @test existing_retro_zones(day,1,"weather","snapshot-fixture",CV)==Set(["GR"])
            @test existing_forecast_zones(day,1,"weather")==Set(["GR"])
            @test !live_slice_has_cv(day,1,"weather",CV)
            LibPQ.execute(admin,"""
                INSERT INTO simulations.forecast_prices
                (market_date,date_time_utc,bidding_zone,price_eur_mwh,prediction_made_utc,lead_days,code_version,input_mode,is_retro)
                VALUES ('2026-09-14','2026-09-14 01:00+00','BG',50,'2026-09-13',1,\$1,'weather',false)
                """,[CV])
            @test live_slice_has_cv(day,1,"weather",CV)
            @test write_forecast!(day,1,DateTime(2026,11,17),rows,"weather";
                is_retro=true,reset_tag="snapshot-fixture",retro_of_utc=DateTime(day-Day(1)),alongside=true)==0
            @test DataFrame(LibPQ.execute(admin,"SELECT count(*) AS n FROM simulations.forecast_prices")).n[1]==2
        end
    finally
        Euphemia.close_input_snapshot!(s)
    end
    fresh=Euphemia.open_pg_input_snapshot(["GR"];connect=connect)
    try
        @test Euphemia.with_input_snapshot(()->Euphemia.sql2df("SELECT value FROM entsoe.snapshot_probe").value,fresh)==[20]
        @test fresh.revision != s.revision
        @test_throws Exception Euphemia.with_input_snapshot(fresh) do
            try Euphemia.sql2df("UPDATE entsoe.snapshot_probe SET value=99") catch end
        end
        @test DataFrame(LibPQ.execute(admin,"SELECT value FROM entsoe.snapshot_probe")).value==[20]
    finally
        Euphemia.close_input_snapshot!(fresh)
    end
    @test DataFrame(LibPQ.execute(admin,"SELECT count(*) AS n FROM pg_stat_activity WHERE backend_xmin IS NOT NULL AND pid<>pg_backend_pid()")).n[1]==0
end
close(admin)
