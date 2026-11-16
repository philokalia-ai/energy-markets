# Day-ahead target policy (#431 PR C): `canonical_hourly_actuals` (pure) and both SQL paths
# (`resolution_aware_actuals` = highest_seq, `sdac_hourly_actuals`) on a temp DuckDB built
# from the shared fixtures test/fixtures/da_target_cases.json (also read by
# test/test_da_target.py). No Postgres, no extract.
#
# Standalone:  julia --project=. test/test_da_target.jl

using Test, Euphemia, Dates, DataFrames, JSON, DuckDB
import DuckDB.DBInterface as DBInterface
isdefined(@__MODULE__, :canonical_hourly_actuals) ||
    include(joinpath(@__DIR__, "scripts", "eu_eval_metrics.jl"))

const DA_FIX = JSON.parsefile(joinpath(@__DIR__, "fixtures", "da_target_cases.json"))

_jstr(x) = x === nothing ? missing : String(x)
function _raw(rows)
    DataFrame(z=[String(r[1]) for r in rows], seq=[_jstr(r[2]) for r in rows],
              res=[String(r[3]) for r in rows], t=[DateTime(r[4]) for r in rows],
              p=[Float64(r[5]) for r in rows], u=[DateTime(r[6]) for r in rows])
end
_expect(lst) = Dict((String(x[1]), DateTime(x[2])) => (x[3] === nothing ? nothing : Float64(x[3])) for x in lst)
_got(df) = Dict((String(r.z), DateTime(r.t)) => Float64(r.act) for r in eachrow(df))
function _same(got, want)
    keys(got) == keys(want) || return false
    all(v === nothing || isapprox(got[k], v; atol=1e-9) for (k, v) in want)
end

@testset "DA target policy (#431)" begin
    @testset "map and switch" begin
        @test SDAC_SEQUENCE == Dict(String(k) => String(v) for (k, v) in DA_FIX["sdac_sequence"])
        for (z, q) in Q15_NON_SDAC_SEQUENCE
            @test SDAC_SEQUENCE[z] != q
        end
        withenv("EUPHEMIA_DA_TARGET" => nothing) do
            @test da_target_policy() === :highest_seq
        end
        withenv("EUPHEMIA_DA_TARGET" => "") do
            @test da_target_policy() === :highest_seq
        end
        withenv("EUPHEMIA_DA_TARGET" => " SDAC ") do
            @test da_target_policy() === :sdac
        end
        withenv("EUPHEMIA_DA_TARGET" => "exaa") do
            @test_throws ErrorException da_target_policy()
        end
    end

    @testset "fixtures, pure: $(c["name"])" for c in DA_FIX["cases"]
        r = canonical_hourly_actuals(_raw(c["rows"]))
        @test _same(_got(r.act), _expect(c["sdac"]))
        @test sort(r.smap.z[r.smap.how .== "ambiguous"]) == String.(c["ambiguous"])
        amb = r.excluded[in.(r.excluded.z, Ref(Set(String.(c["ambiguous"])))), :]
        @test all(==("ambiguous auction"), amb.reason)
    end

    @testset "exclusion ledger" begin
        rows = reduce(vcat, [c["rows"] for c in DA_FIX["cases"]])
        ex = canonical_hourly_actuals(_raw(rows)).excluded
        zs(reason) = sort(unique(ex.z[ex.reason .== reason]))
        @test zs("other auction") == ["AT", "DE_LU", "DK1"]
        @test zs("superseded revision") == ["GR"]
        @test zs("incomplete hour") == ["FR"]
        @test zs("resolution not chosen for the hour") == ["ES", "PT"]
        @test zs("ambiguous auction") == ["HU"]
        @test zs("misaligned interval") == ["SE3"]
    end

    @testset "SQL paths on a temp DuckDB store" begin
        tmp = mktempdir()
        extract = joinpath(tmp, "extract.duckdb")
        rows = reduce(vcat, [c["rows"] for c in DA_FIX["cases"]])
        let db = DuckDB.DB(extract), con = DBInterface.connect(db)
            DBInterface.execute(con, "CREATE SCHEMA entsoe")
            DBInterface.execute(con, "CREATE SCHEMA simulations")
            DBInterface.execute(con, """CREATE TABLE entsoe.energy_prices(instance_code VARCHAR,
                date_time_utc TIMESTAMP, resolution_code VARCHAR, area_code VARCHAR,
                area_display_name VARCHAR, area_type_code VARCHAR, map_code VARCHAR,
                contract_type VARCHAR, sequence VARCHAR, price_currency_mwh DOUBLE,
                currency VARCHAR, update_time_utc TIMESTAMP, source VARCHAR)""")
            for (i, r) in enumerate(rows)
                DBInterface.execute(con, """INSERT INTO entsoe.energy_prices VALUES
                    (?, ?, ?, ?, ?, 'BZN', ?, 'Day-ahead', ?, ?, 'EUR', ?, 'fx')""",
                    ["i$i", DateTime(r[4]), r[3], r[1], r[1], r[1], _jstr(r[2]), Float64(r[5]),
                     DateTime(r[6])])
            end
            DBInterface.close!(con); close(db)
        end
        prev, prev_path, prev_ro = Euphemia.DATA_STORE[], Euphemia.DUCKDB_PATH[], Euphemia.DUCKDB_READ_ONLY[]
        try
            Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=extract, read_only=true)
            d = Date(2026, 11, 10)
            want_s = _expect(reduce(vcat, [c["sdac"] for c in DA_FIX["cases"]]))
            want_l = _expect(reduce(vcat, [c["legacy"] for c in DA_FIX["cases"]]))
            @test _same(_got(sdac_hourly_actuals(d, d)), want_s)
            @test _same(_got(resolution_aware_actuals(d, d)), want_l)
            withenv("EUPHEMIA_DA_TARGET" => nothing) do
                @test _got(da_target_actuals(d, d)) == _got(resolution_aware_actuals(d, d))
            end
            withenv("EUPHEMIA_DA_TARGET" => "sdac") do
                @test _same(_got(da_target_actuals(d, d)), want_s)
            end
            # the raw reader returns the column types the pure function expects
            raw = da_raw_rows(d, d)
            @test nrow(raw) == length(rows)
            @test sort(unique(raw.seq)) == ["", "1", "2"]
        finally
            if prev == :postgres
                try; Euphemia.configure_data_store!(backend=:postgres); catch; end
            elseif !isempty(prev_path)
                try; Euphemia.configure_data_store!(backend=:duckdb, duckdb_path=prev_path,
                                                    read_only=prev_ro); catch; end
            end
            try; rm(tmp, recursive=true, force=true); catch; end
        end
    end
end
