# DuckDB postgres-extension helper (src/db/pg_attach.jl): the only Julia -> Postgres path.
# No network, no database: the extension itself is exercised by the fill/transfer tests on the
# throwaway test-bed cluster, not here.
using Test, Euphemia

@testset "pg_attach helper (no network, no DB)" begin
    withenv("EUPHEMIA_DUCKDB_EXT_DIR" => "/tmp/x-ext") do
        @test Euphemia.duckdb_ext_dir() == "/tmp/x-ext"
    end
    withenv("EUPHEMIA_DUCKDB_EXT_DIR" => nothing) do
        @test Euphemia.duckdb_ext_dir() == joinpath(first(DEPOT_PATH), "duckdb-ext")
    end
    @test Euphemia._sql_quote("host=a password='x'") == "host=a password=''x''"
    @test_throws ErrorException Euphemia.attach_postgres!(nothing, "x"; alias="pg; DROP")
end
