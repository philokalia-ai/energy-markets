# Regression: load a default-warmed package cache with a different runtime PG cap.
# Uses a tiny synthetic read-only DuckDB solely to initialize Euphemia offline.
# Run with a private JULIA_DEPOT_PATH: julia --project=. test/scripts/test_pg_pool_runtime.jl
using Test, DuckDB

const POOL_TEST_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const POOL_TEST_PROBE = raw"""
using Test, Euphemia, SHA
expected = parse(Int, ARGS[1])
@test Euphemia.poolsize == expected
@test Euphemia.Pools.limit(Euphemia.cnxpool) == expected
@test Euphemia.Pools.in_pool(Euphemia.cnxpool) == 0
@test Euphemia.Pools.in_use(Euphemia.cnxpool) == 0
@test Euphemia.DATA_STORE[] == :duckdb
paths = Base.find_all_in_cache_path(Base.PkgId(Euphemia))
@test !isempty(paths)
write(ARGS[2], join(sort([p * " " * bytes2hex(sha256(read(p))) for p in paths]), "\n"))
println("runtime PG pool requested/effective: ", expected, "/", Euphemia.Pools.limit(Euphemia.cnxpool),
        "; compiled-modules mode=", Base.JLOptions().use_compiled_modules)
"""

@testset "Runtime PG capacity with an unchanged warmed cache" begin
    mktempdir() do dir
        path = joinpath(dir, "empty.duckdb")
        db = DuckDB.DB(path)
        close(db)
        env = copy(ENV)
        env["EUPHEMIA_DATA_STORE"] = "duckdb"
        env["EUPHEMIA_DUCKDB_PATH"] = path
        env["EUPHEMIA_DUCKDB_READONLY"] = "true"
        env["ENERGY_CONN_STR"] = ""
        delete!(env, "EUPHEMIA_PG_POOL")
        warm_manifest = joinpath(dir, "warm.txt")
        # Run in the empty temporary directory so DotEnv never loads a user's file.
        warm = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=yes --project=$POOL_TEST_ROOT -e $POOL_TEST_PROBE 5 $warm_manifest`
        run(setenv(Cmd(warm; dir=dir), env))
        manifest = read(warm_manifest, String)
        for (setting, expected) in (("2", 2), (nothing, 5), ("3", 3), ("0", 1))
            setting === nothing ? delete!(env, "EUPHEMIA_PG_POOL") : (env["EUPHEMIA_PG_POOL"] = setting)
            checked = joinpath(dir, "checked.txt")
            # Strict mode fails instead of recompiling or falling back to source.
            probe = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=strict --project=$POOL_TEST_ROOT -e $POOL_TEST_PROBE $expected $checked`
            run(setenv(Cmd(probe; dir=dir), env))
            @test read(checked, String) == manifest
        end
    end
end
