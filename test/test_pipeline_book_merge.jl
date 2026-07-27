# test_pipeline_book_merge.jl — DB-free unit tests for the pipelined-backfill
# book-capture merge semantics (Deliverable A of the cv23 books work).
#
# Exercises the real code path: synthetic tagged books → per-pass staging
# parquet (`_flush_pipeline_books`) → coordinator merge (`_merge_pipeline_day_books`),
# then reads the merged parquet back and asserts:
#   • pass-2 WINS per zone (anchored zone's rows come from pass 2),
#   • non-anchored zones persist verbatim from pass 1,
#   • the no-pass-2 case (SEE-style, no anchors) yields pass-1 books alone,
#   • staging files are consumed (deleted) by a successful merge,
#   • the cleanup helper removes orphaned staging on a failed day.
#
#   julia --project=. -e 'using Test, Euphemia; include("test/test_pipeline_book_merge.jl")'

using Test, Euphemia, Dates, DataFrames, DuckDB

const _P = Euphemia   # internal helpers live in module Euphemia (PipelinedBackfill.jl)

# Build a tiny tagged book for a zone: two supply tranches tagged by owner.
function _book(zone, day, base_price)
    ts = DateTime(day) + Hour(0)
    [(_P.SimpleOrder(:supply, base_price,       100.0, Symbol(zone), ts, 60), "$(zone)_G1"),
     (_P.SimpleOrder(:supply, base_price + 5.0, 200.0, Symbol(zone), ts, 60), "$(zone)_G2"),
     (_P.SimpleOrder(:demand, 3000.0,          500.0, Symbol(zone), ts, 60), "DEMAND")]
end

_read(path) = DataFrame(DBInterface.execute(DBInterface.connect(DuckDB.DB()),
    "SELECT * FROM read_parquet('$path')"))

@testset "pipeline book merge" begin
    day = Date(2026, 4, 3)

    @testset "pass-2 wins per zone; non-anchored persist from pass-1" begin
        dir = mktempdir()
        lk = ReentrantLock()

        # PASS 1: three zones (GR non-anchored, NO2 + SE1 anchored) all at price 50.
        books = Dict{Tuple{String,Date},Vector{Tuple{_P.SimpleOrder,String}}}()
        for z in ("GR", "NO2", "SE1"); books[(z, day)] = _book(z, day, 50.0); end
        n1 = _P._flush_pipeline_books(books, lk, dir, day, 1)
        @test n1 == 9                       # 3 zones × 3 orders
        @test isempty(books)                # dict cleared after flush
        @test isfile(_P._pipeline_book_staging(dir, day, 1))

        # PASS 2: only the anchored zones rebuild, at a DIFFERENT price (77).
        for z in ("NO2", "SE1"); books[(z, day)] = _book(z, day, 77.0); end
        n2 = _P._flush_pipeline_books(books, lk, dir, day, 2)
        @test n2 == 6

        out = _P._merge_pipeline_day_books(dir, day)
        @test out !== nothing && isfile(out)
        df = _read(out)

        # GR came only from pass 1 (base 50).
        gr = filter(r -> r.zone == "GR" && r.side == "supply", df)
        @test sort(gr.price) == [50.0, 55.0]
        # NO2 / SE1 replaced by pass 2 (base 77) — pass-1 rows gone.
        for z in ("NO2", "SE1")
            zs = filter(r -> r.zone == z && r.side == "supply", df)
            @test sort(zs.price) == [77.0, 82.0]
        end
        # Every zone present exactly once per (side,price); no pass-1 leftovers.
        @test nrow(df) == 9
        @test Set(df.zone) == Set(["GR", "NO2", "SE1"])
        # Staging consumed.
        @test !isfile(_P._pipeline_book_staging(dir, day, 1))
        @test !isfile(_P._pipeline_book_staging(dir, day, 2))
    end

    @testset "no pass-2 (no anchors) → pass-1 books alone" begin
        dir = mktempdir()
        lk = ReentrantLock()
        books = Dict{Tuple{String,Date},Vector{Tuple{_P.SimpleOrder,String}}}()
        for z in ("GR", "BG"); books[(z, day)] = _book(z, day, 40.0); end
        _P._flush_pipeline_books(books, lk, dir, day, 1)
        out = _P._merge_pipeline_day_books(dir, day)
        df = _read(out)
        @test nrow(df) == 6
        @test Set(df.zone) == Set(["GR", "BG"])
        @test Set(names(df)) ==
            Set(["market_date", "zone", "ts", "side", "price", "mw", "owner", "code_version"])
    end

    @testset "cleanup removes orphaned staging" begin
        dir = mktempdir()
        lk = ReentrantLock()
        books = Dict{Tuple{String,Date},Vector{Tuple{_P.SimpleOrder,String}}}()
        books[("GR", day)] = _book("GR", day, 30.0)
        _P._flush_pipeline_books(books, lk, dir, day, 1)
        @test isfile(_P._pipeline_book_staging(dir, day, 1))
        _P._cleanup_pipeline_staging(dir, day)
        @test !isfile(_P._pipeline_book_staging(dir, day, 1))
        @test !isfile(_P._pipeline_book_staging(dir, day, 2))
    end

    @testset "flush of empty day writes nothing" begin
        dir = mktempdir()
        lk = ReentrantLock()
        books = Dict{Tuple{String,Date},Vector{Tuple{_P.SimpleOrder,String}}}()
        @test _P._flush_pipeline_books(books, lk, dir, day, 1) == 0
        @test !isfile(_P._pipeline_book_staging(dir, day, 1))
        @test _P._merge_pipeline_day_books(dir, day) === nothing
    end
end
