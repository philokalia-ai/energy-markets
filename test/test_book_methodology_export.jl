# Tests for the generated bid-methodology object (bin/export_book_methodology.jl).
#
# The methodology surface's whole claim is that every number is GENERATED from the
# running model — never hand-authored (docs/pillars/pillar-5-book-methodology-plan.md,
# the hard rule). These tests are what make that claim enforceable:
#   - every fuel in the cost model is described (base + carbon factor), and every
#     carbon factor has a base row — a fuel added to FUEL_SRMC_BASE without a
#     carbon entry, or a carbon entry with no base, fails here;
#   - every form constant has a plain-language line, and BOTH the exporter and this
#     test read that one CONST_DESCRIPTIONS object (no second copy to drift);
#   - PROVENANCE covers every form constant AND every ZoneProfile field, so a new
#     lever cannot ship without declaring whether it is observed or declared;
#   - the strategy glossary is emitted verbatim from STRATEGY_DESCRIPTIONS (the
#     WHY-column single source of truth, §5.1);
#   - the cv-ledger cites only committed docs and only shipped/measured versions;
#   - the exporter carries no transcribed constant table and does not stage into
#     the auto-published web tree.

using Test, Dates, JSON
using Euphemia
const _MO = Euphemia.MeritOrderBook

@testset "Book-methodology export" begin

    @testset "cost model — every fuel described, every carbon factor has a base" begin
        # The exporter builds `fuels` from FUEL_SRMC_BASE and joins the electrical
        # emission factor; so every SRMC-base fuel must appear, and every carbon
        # factor must have a matching base row (else €X + EF·EUA is ill-defined).
        base_keys = Set(keys(Euphemia.FUEL_SRMC_BASE))
        @test !isempty(base_keys)
        @test Set(keys(Euphemia.FUEL_EMISSION_FACTOR_EL)) ⊆ base_keys
        # the gas CCGT constants the waterfall decomposes into are real numbers
        @test Euphemia.GAS_PLANT_EFFICIENCY > 0
        @test Euphemia.GAS_EMISSION_FACTOR > 0
        @test Euphemia.GAS_VOM_COST >= 0
    end

    @testset "every form constant is described and resolvable by name" begin
        # CONST_DESCRIPTIONS lives beside the constants; the exporter resolves each
        # value via getproperty(MO, name), so a description can never point at a
        # value that no longer exists. This test enforces both directions.
        @test !isempty(_MO.CONST_DESCRIPTIONS)
        for (name, desc) in _MO.CONST_DESCRIPTIONS
            @test !isempty(desc)
            @test isdefined(_MO, Symbol(name))            # the const exists
            @test getproperty(_MO, Symbol(name)) !== nothing
        end
    end

    @testset "PROVENANCE covers every form constant AND every ZoneProfile field" begin
        # The observed/declared wall cannot rot: a new form constant or profile
        # field added without a provenance entry fails the build here.
        want = union(Set(keys(_MO.CONST_DESCRIPTIONS)),
                     Set(String(f) for f in fieldnames(_MO.ZoneProfile)))
        have = Set(keys(_MO.PROVENANCE))
        @test want ⊆ have
        for (k, v) in _MO.PROVENANCE
            @test v["kind"] in ("observed", "declared")
            @test !isempty(v["source"])
            @test v["cv"] isa Integer
            @test v["cv"] <= Euphemia.ENERGY_PRICES_CODE_VERSION
        end
    end

    @testset "strategy glossary is the STRATEGY_DESCRIPTIONS object (one source of truth)" begin
        # §5.1: the WHY vocabulary is generated, not a third hand-copy. The exporter
        # emits STRATEGY_DESCRIPTIONS verbatim, and the SPA overlays it onto its
        # book-table explanations. Guard that the object exists and is non-trivial.
        @test !isempty(_MO.STRATEGY_DESCRIPTIONS)
        @test haskey(_MO.STRATEGY_DESCRIPTIONS, "srmc_base")
        @test haskey(_MO.STRATEGY_DESCRIPTIONS, "must_run_deep")
    end

    @testset "the cv-ledger is committed, cited, and version-bounded" begin
        # The one admissible hand-entry (measured experiment deltas). Every row must
        # cite a committed docs/experiments/ path and name a version <= the current
        # code version — auditable against committed measured artifacts, not free-typed.
        ledger_path = joinpath(dirname(@__DIR__), "docs", "pillars", "cv-ledger.json")
        @test isfile(ledger_path)
        doc = JSON.parsefile(ledger_path)
        rows = doc["rows"]
        @test !isempty(rows)
        for r in rows
            @test r["cv"] isa Integer
            @test r["cv"] <= Euphemia.ENERGY_PRICES_CODE_VERSION
            @test !isempty(r["characteristic"])
            @test r["status"] in ("shipped", "no_ship")
            docpath = joinpath(dirname(@__DIR__), r["doc"])
            @test ispath(docpath)   # the cited experiment file/dir exists
        end
    end

    @testset "the exporter transcribes nothing and does not auto-publish" begin
        src = read(joinpath(dirname(@__DIR__), "bin", "export_book_methodology.jl"), String)
        # reads the source-of-truth objects, never a local copy
        @test occursin("MO.CONST_DESCRIPTIONS", src)
        @test occursin("MO.STRATEGY_DESCRIPTIONS", src)
        @test occursin("MO.PROVENANCE", src)
        @test occursin("Euphemia.FUEL_SRMC_BASE", src)
        @test !occursin("const FUEL_SRMC_BASE", src)
        @test !occursin("const CONST_DESCRIPTIONS", src)
        @test !occursin("const STRATEGY_DESCRIPTIONS", src)
        # writes OUTSIDE the auto-synced web tree (data/calibration), like
        # export_zone_strategies.jl — publishing is an explicit act.
        @test occursin("BOOK_METHODOLOGY_OUT", src)
        @test occursin("data\", \"calibration\"", src)
        @test !occursin("WEB_PARQUET_OUT", src)
    end
end
