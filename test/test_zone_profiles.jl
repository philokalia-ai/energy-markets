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
        # cv17 mechanisms are all inert on the SEE default profile
        @test p.import_backstop == false
        @test p.backstop_scarcity_credit == 0.0
        @test p.anchor_include_dropped == false
        @test p.ref_priced_exports == false
    end

    @testset "registry defaults to SEE for the SEE core and unknowns" begin
        for z in ("GR", "BG")
            @test get_zone_profile(z) === SEE_PROFILE
        end
        @test get_zone_profile("ZZ-not-a-zone") === SEE_PROFILE
        # IBERIA_PROFILE was an alias for SEE_PROFILE and was removed in cv25's
        # subtraction phase — ES/PT now name SEE_PROFILE directly.
        @test get_zone_profile("ES") === SEE_PROFILE
        @test get_zone_profile("PT") === SEE_PROFILE
        @test get_zone_profile("ES") === SEE_PROFILE
        # cv17: RO/RS = exact SEE calibration + the import backstop (EU
        # footprint only — the single-zone/5-zone SEE products never consult
        # the registry and force SEE_PROFILE)
        # ROMANIA/SERBIA/HUNGARY_PROFILE were three identical definitions; cv25's
        # subtraction phase names the one thing they are.
        for (z, p) in (("RO", SEE_IMPORT_BACKED_PROFILE), ("RS", SEE_IMPORT_BACKED_PROFILE),
                       ("HU", SEE_IMPORT_BACKED_PROFILE))
            @test get_zone_profile(z) === p
            @test p.import_backstop == true
            # Full scarcity credit for the demonstrated headroom (the SEE
            # cold-snap cluster's residual markup overshoot — see profile doc)
            @test p.backstop_scarcity_credit == 1.0
            @test with_profile(p; import_backstop=false,
                               backstop_scarcity_credit=0.0) == SEE_PROFILE
        end
    end

    @testset "cv17 profiles (weak-zone import fixes)" begin
        # SI: the Slovakia treatment (the AT–SI drop pairs with the :hydro anchor)
        @test get_zone_profile("SI") === SLOVENIA_PROFILE
        @test SLOVENIA_PROFILE.opportunity_anchor == :hydro
        @test SLOVENIA_PROFILE.scarcity_kappa == CONTINENTAL_PROFILE.scarcity_kappa
        @test SLOVENIA_PROFILE.import_backstop == true
        @test SLOVENIA_PROFILE.ref_priced_exports == true   # SI–HR retained border
        # Denmark: NORDIC + backstop
        @test get_zone_profile("DK1") === DENMARK_PROFILE
        @test get_zone_profile("DK2") === DENMARK_PROFILE
        @test with_profile(DENMARK_PROFILE; import_backstop=false) == NORDIC_PROFILE
        # SE1/SE2/FI stay plain NORDIC (no backstop)
        for z in ("SE1", "SE2", "FI")
            @test get_zone_profile(z) === NORDIC_PROFILE
        end
        # SE3: backstop; the dropped-border anchor ref was measured and
        # gated OUT (bias +13 → −24, corr 0.55 → 0.31 — see SE3_PROFILE)
        @test get_zone_profile("SE3") === SE3_PROFILE
        @test SE3_PROFILE.anchor_include_dropped == false
        @test SE3_PROFILE.import_backstop == true
        @test get_zone_profile("SE4") === SWEDEN_SOUTH_PROFILE
        @test SWEDEN_SOUTH_PROFILE.anchor_include_dropped == false
        # IT-CNORTH: ITALY + backstop; other IT sub-zones unchanged
        @test get_zone_profile("IT-CNORTH") === ITALY_CNORTH_PROFILE
        @test with_profile(ITALY_CNORTH_PROFILE; import_backstop=false) == ITALY_PROFILE
        @test get_zone_profile("IT-NORTH") === ITALY_PROFILE
        @test get_zone_profile("IT-Sardinia") === ITALY_PROFILE
        # cv18's parked levers (unit_srmc_spread / export_absorption_steps) were
        # removed in cv25's subtraction phase — they were default-inert in every
        # zone and never activated. git holds the implementation.
        @test !(:unit_srmc_spread in fieldnames(ZoneProfile))
        @test !(:export_absorption_steps in fieldnames(ZoneProfile))
        # AT/CH/BE gained the backstop, keeping their existing calibration
        # (the scarcity credit stays scoped to the SEE-east zones — measured)
        @test AUSTRIA_PROFILE.import_backstop == true
        @test AUSTRIA_PROFILE.backstop_scarcity_credit == 0.0
        @test AUSTRIA_PROFILE.anchor_share == 1.1
        @test SWISS_PROFILE.import_backstop == true
        @test BELGIUM_PROFILE.import_backstop == true
        @test BELGIUM_PROFILE.ref_priced_exports == true    # BE–GB retained border
        # AT border drops live in flow_based_drop_borders
        drops = Euphemia.flow_based_drop_borders(["AT", "CZ", "DE_LU", "SI", "GR"])
        @test ("AT", "CZ") in drops
        @test ("AT", "DE_LU") in drops
        @test ("AT", "SI") in drops
        # ... and never fire on a footprint without AT (the SEE 5-zone set —
        # HU–AT/HU–SK need AT/SK in the footprint too)
        @test isempty(Euphemia.flow_based_drop_borders(["GR", "BG", "RO", "RS", "HU"]))
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
        # NO4 (far north): reservoir-opportunity, no anchor, but the seasonal
        # drawdown is OFF (iter6) — its price is set by export congestion, not
        # the winter water value, so it uses a dedicated NO4_PROFILE.
        @test get_zone_profile("NO4") === Euphemia.MeritOrderBook.NO4_PROFILE
        @test get_zone_profile("NO4").opportunity_anchor == :none
        @test get_zone_profile("NO4").hydro_model == :reservoir_opportunity
        @test get_zone_profile("NO4").seasonal_drawdown == false
        @test NORDIC_PROFILE.seasonal_drawdown == true   # SE1/SE2/FI keep it
        @test NORDIC_PROFILE.opportunity_anchor == :none
        @test SWISS_PROFILE.opportunity_anchor == :hydro
        @test SWISS_PROFILE.hydro_model == :reservoir_opportunity
        # iter4: CH and AT rolled out TOGETHER on the alpine reservoir-opportunity
        # :hydro anchor (the AT–CH border is anchored consistently, fixing the
        # cal10 AT shape regression). See docs/eu-calibration-iter4.md.
        @test get_zone_profile("CH") === SWISS_PROFILE
        # iter5: AT keeps the alpine anchor but with its own share (1.1) for
        # the Core-FBMC premium over its coupled ref (CH sits AT its ref).
        @test get_zone_profile("AT") === AUSTRIA_PROFILE
        @test AUSTRIA_PROFILE.opportunity_anchor == :hydro
        @test AUSTRIA_PROFILE.anchor_share == 1.1
        @test SWISS_PROFILE.anchor_share == 0.9
        # iter5: SE3/SE4 anchored after the SE2–SE3/SE3–SE4 flow-based border
        # drop (the €1 observed-import block must not be price-setting — the
        # NO1 iteration-2 lesson). SE1/SE2 stay plain NORDIC.
        @test SWEDEN_SOUTH_PROFILE.opportunity_anchor == :hydro
        # cv17: SE3 moved to SE3_PROFILE (SWEDEN_SOUTH + backstop + dropped-
        # border anchor ref) — see the cv17 testset; SE4 stays.
        @test get_zone_profile("SE4") === SWEDEN_SOUTH_PROFILE
        @test get_zone_profile("SE1") === NORDIC_PROFILE
        @test get_zone_profile("SE2") === NORDIC_PROFILE
        # iter5: BE's dropped Core borders need the anchor's import pricing
        # (thermal zone, continental params otherwise).
        @test get_zone_profile("BE") === BELGIUM_PROFILE
        @test BELGIUM_PROFILE.opportunity_anchor == :hydro
        @test BELGIUM_PROFILE.hydro_model == :gas_anchored
        # iter6: SK's dropped Core import borders (CZ-SK/PL-SK) need the anchor's
        # import pricing, like BE — continental params otherwise.
        @test get_zone_profile("SK") === Euphemia.MeritOrderBook.SLOVAKIA_PROFILE
        @test get_zone_profile("SK").opportunity_anchor == :hydro
        @test get_zone_profile("SK").scarcity_kappa == CONTINENTAL_PROFILE.scarcity_kappa
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
