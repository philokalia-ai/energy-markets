# Postgres check of bin/transfer_results_to_postgres.jl's run linkage (#472 review #3; NOT CI). PRIVATE throwaway Postgres
# only. Phases, each in its own process:
#   ENERGY_CONN_STR=<private> julia --project=. test/scripts/record_transfer_runid_check.jl setup DIR
#   julia --project=. test/scripts/record_transfer_runid_check.jl write DIR [partial]
#   ENERGY_CONN_STR=<private> julia --project=. bin/transfer_results_to_postgres.jl --clearing-mode multi_zone \
#       --start 2026-11-12 --end 2026-11-12 [--written-since 2026-11-23T00:00:00] --results-db DIR/results.duckdb
#   ENERGY_CONN_STR=<private> julia --project=. test/scripts/record_transfer_runid_check.jl check DIR fixed|unchanged
# The Postgres slice (day D, multi_zone, current cv) holds GR, BG, RO under run R_pg. The results DB is what a :record
# fill + run leaves: RO seeded (a copy of the Postgres row, Postgres run id, old update_time), GR and BG re-cleared by
# this run (new prices, local run id 1, new update_time). `partial`: also a seeded GR row in a re-cleared group.
using Dates, Test
const PHASE, DIR = ARGS[1], ARGS[2]
const D = Date(2026, 11, 12); const OLD = DateTime(2026, 11, 13, 1); const NEW = DateTime(2026, 11, 23, 10)
hours = [DateTime(D) + Hour(h) for h in 0:23]

if PHASE in ("setup", "check")
    ENV["EUPHEMIA_DATA_STORE"] = "postgres"; ENV["EUPHEMIA_PG_POOL"] = "2"
    using Euphemia, LibPQ, DataFrames
    pg(sql, args=Any[]) = Euphemia.withdb(c -> DataFrame(LibPQ.execute(c, sql, args)))
end
CV() = Euphemia.ENERGY_PRICES_CODE_VERSION

if PHASE == "setup"
    Euphemia.ensure_energy_prices_table(); Euphemia.ensure_transmission_flows_table()
    for t in ("energy_prices", "transmission_flows", "optimization_runs"); pg("DELETE FROM simulations.$t"); end
    rid = pg("""INSERT INTO simulations.optimization_runs (bidding_zone, optimization_date, order_method, model_type,
                optimizer, status, objective_value, code_version, created_at)
                VALUES ('MULTI_ZONE', \$1, 'merit_order', 'mpcc', 'highs', 'optimal', 1.0, \$2, \$3) RETURNING id""",
             Any[D, CV(), Dates.format(OLD, "yyyy-mm-dd HH:MM:SS") * "+00"]).id[1]
    for (z, p) in (("GR", 100.0), ("BG", 90.0), ("RO", 80.0)), h in hours
        pg("""INSERT INTO simulations.energy_prices (date_time_utc, resolution_code, bidding_zone, contract_type, price_eur_mwh,
              currency, order_method, clearing_mode, optimization_run_id, code_version, update_time_utc)
              VALUES (\$1, '60M', \$2, 'Day-Ahead', \$3, 'EUR', 'merit_order', 'multi_zone', \$4, \$5, \$6)""",
           Any[Dates.format(h, "yyyy-mm-dd HH:MM:SS") * "+00", z, p, rid, CV(), Dates.format(OLD, "yyyy-mm-dd HH:MM:SS") * "+00"])
    end
    write(joinpath(mkpath(DIR), "pg_run_id"), string(rid)); write(joinpath(DIR, "cv"), string(CV()))
    println("setup: Postgres slice GR/BG/RO x 24 under run $rid")
end

if PHASE == "write"
    using DuckDB
    rid = parse(Int, read(joinpath(DIR, "pg_run_id"), String))
    res = joinpath(DIR, "results.duckdb"); isfile(res) && rm(res)
    c = DBInterface.connect(DuckDB.DB, res)
    x(s, a=Any[]) = DBInterface.execute(c, s, a)
    x("CREATE SCHEMA simulations")
    x("""CREATE TABLE simulations.energy_prices (date_time_utc TIMESTAMP, resolution_code VARCHAR, bidding_zone VARCHAR,
         contract_type VARCHAR, price_eur_mwh DOUBLE, currency VARCHAR, order_method VARCHAR, clearing_mode VARCHAR,
         optimization_run_id BIGINT, code_version INTEGER, update_time_utc TIMESTAMP)""")
    x("""CREATE TABLE simulations.optimization_runs (id BIGINT, bidding_zone VARCHAR, optimization_date DATE, order_method VARCHAR,
         model_type VARCHAR, optimizer VARCHAR, status VARCHAR, objective_value DOUBLE, solve_time_seconds DOUBLE,
         num_orders INTEGER, num_price_periods INTEGER, error_message VARCHAR, code_version INTEGER, created_at TIMESTAMP,
         is_iterative BOOLEAN, total_time_seconds DOUBLE, iterations INTEGER, converged BOOLEAN, final_price_change DOUBLE,
         final_flow_change_pct DOUBLE)""")
    x("""CREATE TABLE simulations.transmission_flows (date_time_utc TIMESTAMP, source_zone VARCHAR, sink_zone VARCHAR,
         flow_mw DOUBLE, clearing_mode VARCHAR DEFAULT 'multi_zone', code_version INTEGER, update_time_utc TIMESTAMP)""")
    cv = parse(Int, read(joinpath(DIR, "cv"), String))   # written by setup (Euphemia's current code version)
    x("""INSERT INTO simulations.optimization_runs (id, bidding_zone, optimization_date, order_method, model_type, optimizer,
         status, objective_value, code_version, created_at) VALUES (1, 'MULTI_ZONE', ?, 'merit_order', 'mpcc', 'highs', 'optimal', 2.0, ?, ?)""",
      Any[D, cv, NEW])
    ins(z, h, p, run, ut) = x("""INSERT INTO simulations.energy_prices VALUES (?, '60M', ?, 'Day-Ahead', ?, 'EUR', 'merit_order',
                                 'multi_zone', ?, ?, ?)""", Any[h, z, p, run, cv, ut])
    for h in hours; ins("RO", h, 80.0, rid, OLD); end                          # seeded by the fill (Postgres run id)
    for (z, p) in (("GR", 111.0), ("BG", 99.0)), h in hours; ins(z, h, p, 1, NEW); end   # re-cleared by this run
    length(ARGS) >= 3 && ARGS[3] == "partial" &&
        ins("GR", DateTime(D) + Hour(23) + Minute(30), 100.0, rid, OLD)         # a seeded row inside a re-cleared group
    DBInterface.close!(c)
    println("write: results DB with RO seeded (run $rid) + GR/BG produced (local run 1)$(length(ARGS) >= 3 ? " + partial" : "")")
end

if PHASE == "check"
    rid = parse(Int, read(joinpath(DIR, "pg_run_id"), String))
    e = pg("""SELECT bidding_zone AS z, COUNT(*) AS n, MIN(price_eur_mwh)::float8 AS p, COUNT(optimization_run_id) AS nrun,
              MIN(optimization_run_id) AS run, MAX(optimization_run_id) AS run2 FROM simulations.energy_prices GROUP BY 1 ORDER BY 1""")
    byz = Dict(String(r.z) => r for r in eachrow(e))
    @testset "record transfer run linkage ($(ARGS[3]))" begin
        @test sort(collect(keys(byz))) == ["BG", "GR", "RO"] && all(byz[z].n == 24 for z in keys(byz))
        @test all(byz[z].nrun == 24 for z in keys(byz))                         # no NULL run id anywhere
        @test byz["RO"].p == 80.0 && byz["RO"].run == rid == byz["RO"].run2      # the seeded zone: untouched, original run
        if ARGS[3] == "fixed"
            new = pg("SELECT id FROM simulations.optimization_runs WHERE objective_value = 2.0").id
            @test length(new) == 1
            @test byz["GR"].p == 111.0 && byz["BG"].p == 99.0
            @test byz["GR"].run == byz["GR"].run2 == byz["BG"].run == new[1]     # re-cleared zones: this run's Postgres id
        else   # refused: Postgres exactly as set up
            @test byz["GR"].p == 100.0 && byz["BG"].p == 90.0 && byz["GR"].run == rid
        end
        @test pg("SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_name LIKE '\\_p96r\\_%'").n[1] == 0
    end
end
