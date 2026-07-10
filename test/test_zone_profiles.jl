# Tests for the per-zone ZoneProfile abstraction (Phase 2 of EU calibration).
#
# The paramount guard: SEE_PROFILE must hold the exact v10 defaults, so a GR
# book built with SEE_PROFILE is byte-identical to one built with the explicit
# legacy default kwargs — the SEE core (GR/BG/RO/RS/HU) cannot regress.
#
# Uses Date(2026, 1, 26) — a benchmark day with complete GR data.

using Test
using Euphemia
using Dates

const ZP_ZONE = "GR"
const ZP_DAY = Date(2026, 1, 26)

# Sorted, tag-independent fingerprint of an order book for identity checks.
zp_fingerprint(ob) = sort([(round(o.price, digits=6), round(o.quantity, digits=6),
                            o.type, o.date_time) for o in ob.orders])

# The exact v10 defaults, spelled out independently of the ZoneProfile struct.
const V10_TRANCHES = [(0.55, 0.95), (0.20, 1.05), (0.15, 1.25), (0.10, 1.60)]

@testset "ZoneProfile abstraction" begin

    @testset "SEE_PROFILE holds the exact v10 defaults" begin
        p = SEE_PROFILE
        @test p.tranches == V10_TRANCHES
        @test p.must_run_price_factor == 0.05
        @test p.must_run_srmc_threshold == 1.15
        @test p.availability_factor == 0.80
        @test p.scarcity_threshold == 1.4
        @test p.scarcity_kappa == 3.0
        @test p.peak_kappa == 1.2
        @test p.peak_exponent == 4.0
        @test p.water_value_base == 0.85
        @test p.water_value_dry_boost == 1.0
        @test p.water_value_span == 0.9
        @test p.demand_elastic_share == 0.02
        @test p.demand_elastic_price == 250.0
        @test p.price_cap == 3000.0
        @test p.fleet_completion == true
        @test p.fleet_truthing == true
        @test p.derate_headroom == 1.15
        @test p.thermal_srmc_multiplier == 1.0       # no premium
        @test p.hydro_model == :gas_anchored         # SEE hydro model
        @test p.nuclear_srmc_floor == 0.0            # no nuclear position floor
        @test p.opportunity_anchor == :none          # no two-pass anchor
    end

    @testset "registry defaults to SEE for the SEE core and unknowns" begin
        for z in ("GR", "BG", "RO", "RS", "HU")
            @test get_zone_profile(z) === SEE_PROFILE
        end
        @test get_zone_profile("ZZ-not-a-zone") === SEE_PROFILE
        @test IBERIA_PROFILE === SEE_PROFILE          # Iberia == SEE (verified)
        @test get_zone_profile("ES") === SEE_PROFILE
    end

    @testset "region profiles are the intended thin deltas" begin
        @test ITALY_PROFILE.thermal_srmc_multiplier == 1.20
        @test ITALY_PROFILE.hydro_model == :gas_anchored
        @test NORDIC_PROFILE.hydro_model == :reservoir_opportunity
        @test NORDIC_PROFILE.scarcity_kappa < SEE_PROFILE.scarcity_kappa
        @test CONTINENTAL_PROFILE.scarcity_kappa < SEE_PROFILE.scarcity_kappa
        @test get_zone_profile("IT-SOUTH") === ITALY_PROFILE
        @test get_zone_profile("NO1") === NORWAY_PROFILE  # iter2: southern Norway
        @test get_zone_profile("EE") === BALTIC_PROFILE
        @test get_zone_profile("DE_LU") === CONTINENTAL_PROFILE
        @test FRANCE_PROFILE.nuclear_srmc_floor == 55.0
        @test FRANCE_PROFILE.thermal_srmc_multiplier == 1.0
        @test FRANCE_PROFILE.opportunity_anchor == :nuclear
        @test get_zone_profile("FR") === FRANCE_PROFILE
        @test NORWAY_PROFILE.opportunity_anchor == :hydro
        @test NORWAY_PROFILE.hydro_model == :reservoir_opportunity
        for z in ("NO1", "NO2", "NO3", "NO5")
            @test get_zone_profile(z) === NORWAY_PROFILE
        end
        @test get_zone_profile("NO4") === NORDIC_PROFILE  # far north: no anchor
        @test NORDIC_PROFILE.opportunity_anchor == :none
        @test SWISS_PROFILE.opportunity_anchor == :hydro   # iter3: defined,
        @test SWISS_PROFILE.hydro_model == :reservoir_opportunity  # measured,
        # ... and GATED: cal10 fixed CH (MAE 40→27) but regressed AT corr
        # 0.77→0.57 through the AT-CH border — CH stays CONTINENTAL until an
        # AT-aware rollout (see docs/eu-calibration-iter3.md).
        @test get_zone_profile("CH") === CONTINENTAL_PROFILE
    end

    @testset "opportunity anchor is a no-op without profile opt-in" begin
        # anchor_prices supplied but SEE profile has opportunity_anchor=:none
        # -> the anchor machinery must be completely inert (byte-identical).
        fake_refs = Dict{String,Float64}(
            Dates.format(DateTime(ZP_DAY) + Hour(h), "yyyymmdd-HHMM") => 80.0
            for h in 0:23)
        base = create_merit_order_book(ZP_ZONE, ZP_DAY)
        withref = create_merit_order_book(ZP_ZONE, ZP_DAY; anchor_prices=fake_refs)
        @test base.success && withref.success
        @test zp_fingerprint(withref.order_book) == zp_fingerprint(base.order_book)

        # ... and with an anchored profile the same refs DO change the book.
        anchored = create_merit_order_book(ZP_ZONE, ZP_DAY;
            profile=NORWAY_PROFILE, anchor_prices=fake_refs)
        plain = create_merit_order_book(ZP_ZONE, ZP_DAY; profile=NORWAY_PROFILE)
        @test anchored.success && plain.success
        @test zp_fingerprint(anchored.order_book) != zp_fingerprint(plain.order_book)
    end

    # ---- The regression guard: SEE byte-identical -----------------------------
    @testset "GR book: SEE_PROFILE == explicit legacy defaults (byte-identical)" begin
        # No profile kwarg -> defaults to SEE_PROFILE internally.
        book_default = create_merit_order_book(ZP_ZONE, ZP_DAY)
        @test book_default.success

        # Explicit SEE_PROFILE.
        book_profile = create_merit_order_book(ZP_ZONE, ZP_DAY; profile=SEE_PROFILE)
        @test book_profile.success

        # Every bid parameter passed explicitly as its legacy v10 default value.
        book_explicit = create_merit_order_book(ZP_ZONE, ZP_DAY;
            tranches=V10_TRANCHES,
            must_run_price_factor=0.05,
            must_run_srmc_threshold=1.15,
            availability_factor=0.80,
            scarcity_threshold=1.4,
            scarcity_kappa=3.0,
            peak_kappa=1.2,
            peak_exponent=4.0,
            water_value_base=0.85,
            water_value_dry_boost=1.0,
            water_value_span=0.9,
            demand_elastic_share=0.02,
            demand_elastic_price=250.0,
            price_cap=3000.0,
            fleet_completion=true,
            fleet_truthing=true,
            derate_headroom=1.15,
            thermal_srmc_multiplier=1.0,
            hydro_model=:gas_anchored,
            nuclear_srmc_floor=0.0)
        @test book_explicit.success

        fp_default = zp_fingerprint(book_default.order_book)
        @test zp_fingerprint(book_profile.order_book) == fp_default
        @test zp_fingerprint(book_explicit.order_book) == fp_default
    end

    @testset "ITALY_PROFILE raises the thermal stack vs SEE" begin
        # A GR book under ITALY_PROFILE differs from SEE (thermal SRMC premium);
        # sanity check that the profile actually changes the offers.
        see = create_merit_order_book(ZP_ZONE, ZP_DAY; profile=SEE_PROFILE)
        ita = create_merit_order_book(ZP_ZONE, ZP_DAY; profile=ITALY_PROFILE)
        @test see.success && ita.success
        @test zp_fingerprint(ita.order_book) != zp_fingerprint(see.order_book)
    end
end
