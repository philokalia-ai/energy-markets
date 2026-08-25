# book_build.jl — create_merit_order_book: builds one zone-day merit-order
# book from generators, load, RES, flows and the zone profile.
# Included by ../MeritOrderBook.jl inside `module MeritOrderBook`.
#
# The build runs in nine stages (banners mark each in the main function;
# stages 1/2/4/5 are the named helpers defined below):
#   1. _true_up_fleet     — fleet completion / truthing derate / SRMC pricing
#   2. _demand_series     — load & RES series on the clearing grid
#   3. inline             — net imports, demand state, gas anchor, backstop
#   4. _hydro_state       — hydro offer scale, dryness, seasonal drawdown
#   5. _committed_set     — UC-lite must-run selection
#   6. inline             — the supply order loop (RES, imports, hydro, thermal)
#   7. inline             — demand orders
#   8. inline             — scenario hooks (extra_orders, strategist)
#   9. inline             — merge identical blocks + assemble the MPCC book


# =============================================================================
# Strategy taxonomy — WHY each block is where it is on the ladder
# =============================================================================
# Every pushed order carries, ALONGSIDE its owner tag, a STRATEGY label naming
# the bidding decision that placed it (must-run, SRMC base, peak tranche, water
# value, import, backstop, boundary, demand, …). This is the honest source-side
# "decision trace": the label is written by the code that makes the decision,
# never guessed downstream. The strategy travels in a PARALLEL vector to the
# `tagged` tuples (see `create_merit_order_book`) so the existing
# `(order, owner_tag)` contract the strategist hook + firm_of map depend on is
# untouched; it is carried to `BOOK_SINK` for the parquet `strategy` column.
#
# STRUCTS-AS-TABLES (styleguide): the taxonomy is ONE const table of
# name → human description. The SPA keeps a mirror of these exact names in its
# STRATEGY_LABELS map (web/app.js) — keep the two in sync; the names are the
# contract between them. Parametric peak tranches are labelled `peak_tranche_<k>`
# (k = tranche index 2,3,…); `strategy_description` strips the numeric suffix so
# the single `peak_tranche` row covers them all.
const STRATEGY_DESCRIPTIONS = Dict{String,String}(
    "must_run_deep"          => "must-run deepest block: technical minimum offered near €0 (5% of SRMC) — shutting down and restarting costs more than running below cost",
    "must_run_rest"          => "must-run remainder: the rest of minimum load bid below SRMC (start-up cost amortised over the committed hours)",
    "srmc_base"              => "base tranche at short-run marginal cost: fuel/efficiency + CO₂ + O&M, no scarcity markup",
    "peak_tranche"           => "peak tranche: upper capacity priced above cost for scarcity margin + peak-hour strategic bidding",
    "water_value_gas_anchored" => "hydro water value: reservoir opportunity cost anchored to gas SRMC (premium at peak, boosted when dry)",
    "water_value_reservoir"  => "hydro water value: shadow price of stored water — near-free when reservoirs are full, rising to the thermal alternative as they empty",
    "water_value_anchored"   => "hydro water value: export opportunity cost = the coupled reference price (two-pass anchor)",
    "res_forecast"           => "renewable forecast offered as price-taker (support schemes make output price-insensitive; floored negative in a solar-surplus regime)",
    "import_fixed"           => "net scheduled imports injected as price-taking supply",
    "ref_priced_export"      => "net export re-priced at the coupled reference so the exporter curtails under domestic stress",
    "export_demand"          => "net scheduled exports taken as firm demand at the price cap",
    "import_backstop"        => "ex-ante elastic import headroom beyond the endogenous ATC, priced above every domestic tranche (binds only near the cap)",
    "boundary_import"        => "out-of-footprint neighbour import supply, laddered on the neighbour's own fundamental SRMC over the border's demonstrated capability",
    "boundary_export"        => "out-of-footprint neighbour export demand over the border's demonstrated capability (firm base slice + elastic tail)",
    "demand_firm"            => "inelastic demand at the price cap (must-serve load)",
    "demand_elastic"         => "price-sensitive demand tail (curtails above the elastic bid price)",
    "extra"                  => "scenario order added via the extra_orders hook",
    "strategist"             => "order produced by the strategist hook (replaces the source ladder)",
    "valley_continuation"    => "overnight-committed MW repriced to the floor through the surplus valley (GRSQ lever 2 — the hourly projection of a valley block order)",
    "pump_absorption"        => "surplus pumping demand at η × pass-1 evening value up to demonstrated pumping capability (cv34 T3)",
)

"""
    strategy_description(s::AbstractString) -> String

Human-readable description for a strategy label, resolving parametric
`peak_tranche_<k>` labels to the single `peak_tranche` row. Empty string for an
unknown label (never throws — this is a display helper).
"""
function strategy_description(s::AbstractString)
    haskey(STRATEGY_DESCRIPTIONS, s) && return STRATEGY_DESCRIPTIONS[s]
    base = replace(s, r"_\d+$" => "")
    return get(STRATEGY_DESCRIPTIONS, base, "")
end


# =============================================================================
# Stage helpers for create_merit_order_book
# =============================================================================
# Each helper is one stage of the book build, extracted verbatim from the
# original single-function body (operation order unchanged — the book is
# bit-identical). State flows explicitly: a helper takes what the stage read
# and returns what later stages use.

"""Hydro-family test shared by the offer-scale, capacity and water-value logic."""
_is_hydro(g::Generator) = g.fuel_type in WATER_VALUE_FUEL_TYPES ||
                          g.fuel_type == Symbol("Hydro Run-of-river and pondage")

"""
Stage 1 — true the offered fleet to the zone's demonstrated capability and
price it: fleet completion (aggregate small units up to the p95/installed
truth target), fleet-truthing derate of baseload types, the thermal SRMC
premium / nuclear bid floor.
Returns the trued-up `generators`.
"""
function _true_up_fleet(generators::Vector{Generator}, bidding_zone::String,
    day::Date, profile::ZoneProfile;
    fleet_completion::Bool, fleet_truthing::Bool, derate_headroom::Float64,
    thermal_srmc_multiplier::Float64, nuclear_srmc_floor::Float64,
    anchor_active::Bool, opportunity_anchor::Symbol)
    # Fleet completion: ENTSO-E's unit-level table only lists larger
    # units, so for some zones (RO, BG, RS) the fleet is structurally
    # undersized and the book clears at spurious shortage-cap prices.
    # When the zone's recent per-type actual output (p95, trailing 30
    # days — strictly historical) exceeds the unit-level capacity of
    # that type, the missing capacity demonstrably exists and produces:
    # add it as one aggregate generator per fuel type. Wind/solar are
    # excluded (netted via the RES forecast). Harmless for zones with
    # good unit coverage — the gap is ~0 there (verified on GR).
    # Shared by fleet completion (upward) and fleet-truthing derate
    # (downward); keys normalized once to canonical fuel names
    type_p95_raw = (fleet_completion || fleet_truthing) ?
                   get_type_output_p95(bidding_zone, day) : Dict{String,Float64}()
    type_p95 = Dict{String,Float64}(
        normalize_fuel_type_name(k) => v for (k, v) in type_p95_raw)
    # Fleet-truth mode (iter7, gated — see the ZoneProfile field docstring).
    # `fleet_truth_target` holds the per-type truth target of MARKET-ACTIVE
    # types only (trailing-30d p95 > 100 MW): those types complete UP to it
    # and are never derated below it. Types with no recent output (phantom
    # post-closure capacity with stale COMMISSIONED status) never enter —
    # that is the activity gate that replaces get_generators' validity
    # filter for this purpose. Empty for :p95 (the default) — byte-identical
    # v10/iter6 behaviour.
    fleet_truth_target = Dict{String,Float64}()
    fleet_truth_mode = _effective_fleet_truth_mode(profile)
    if fleet_completion && fleet_truth_mode != :p95
        src = fleet_truth_mode == :installed ?
              get_installed_capacity_by_type(bidding_zone, day) :
              Dict{String,Float64}(normalize_fuel_type_name(k) => v
                  for (k, v) in get_type_output_p95(bidding_zone, day;
                                                    lookback_days=365))
        for (t, cap) in src
            get(type_p95, t, 0.0) > 100.0 && (fleet_truth_target[t] = cap)
        end
    end
    # Capacity the outage filter removed today, per type (bug sweep 2026-08-25):
    # the completion target (trailing-30d p95 or installed) was measured with
    # those units RUNNING, so a fresh >100 MW outage used to be re-added as an
    # AGG unit at SRMC until it had persisted ~30 days — the outage filter was
    # silently undone. An outage that explains the gap is not a gap.
    removed_by_outage = Dict{String,Float64}()
    if fleet_completion
        unfiltered = get_generators(bidding_zone, day; exclude_unavailable=false)
        for (ptype, _) in type_p95
            f_all = sum((g.p_max for g in unfiltered if g.fuel_type == Symbol(ptype)); init=0.0)
            f_avail = sum((g.p_max for g in generators if g.fuel_type == Symbol(ptype)); init=0.0)
            removed_by_outage[ptype] = max(0.0, f_all - f_avail)
        end
    end
    if fleet_completion
        for (ptype, p95) in type_p95
            ptype in ("Wind Onshore", "Wind Offshore", "Solar") && continue
            fleet = sum((g.p_max for g in generators
                         if g.fuel_type == Symbol(ptype)); init=0.0)
            target = max(p95, get(fleet_truth_target, ptype, 0.0))
            outaged = get(removed_by_outage, ptype, 0.0)
            gap = target - fleet - outaged
            if outaged > 0.0 && target - fleet > 100.0 && gap <= 100.0
                # Outage-response tranche (2026-08-25, owner-directed after the
                # cv34 evaluation): the gap the outage explains is NOT re-added
                # at SRMC (pre-#343 behaviour, which hid the outage) and NOT
                # refused outright (#343, which put BE 2026-01-14 17:00 at the
                # 3000 cap while the market settled at 172 — the market found
                # ~800 MW at a premium: imports beyond the demonstrated
                # headroom, demand response, unfiled units). It is offered as
                # capacity of the same type at the import-backstop price
                # (BACKSTOP_PRICE_MULT × gas SRMC): above every domestic tranche,
                # so it binds only when the outage actually makes the hour
                # tight, and then at a premium instead of the cap.
                # EUPHEMIA_DISABLE_OUTAGE_TRANCHE restores the #343 refusal.
                if isempty(get(ENV, "EUPHEMIA_DISABLE_OUTAGE_TRANCHE", ""))
                    tranche = min(outaged, target - fleet)
                    push!(generators, Generator(
                        "OUT-$(bidding_zone)-$(replace(ptype, " " => "_"))",
                        "Outage-response tranche: $ptype",
                        Symbol(ptype),
                        bidding_zone,
                        tranche,
                        0.0,
                        bidding_zone,
                        BACKSTOP_PRICE_MULT * get_marginal_cost(day, "Fossil Gas", bidding_zone)))
                    println("  ⏸  Fleet completion: $ptype gap $(round(Int, target - fleet)) MW " *
                            "explained by $(round(Int, outaged)) MW on outage — offered as a " *
                            "$(round(Int, tranche)) MW tranche at $(BACKSTOP_PRICE_MULT)× gas SRMC")
                else
                    println("  ⏸  Fleet completion: $ptype gap $(round(Int, target - fleet)) MW " *
                            "explained by $(round(Int, outaged)) MW on outage — not re-added")
                end
            end
            gap > 100.0 || continue
            push!(generators, Generator(
                "AGG-$(bidding_zone)-$(replace(ptype, " " => "_"))",
                "Aggregate small units: $ptype",
                Symbol(ptype),
                bidding_zone,
                gap,
                0.0,
                bidding_zone,
                get_marginal_cost(day, ptype, bidding_zone)))
            src = target > p95 ? "installed $(round(Int, target))" :
                                 "recent p95 $(round(Int, p95))"
            println("  ➕ Fleet completion: +$(round(Int, gap)) MW $ptype " *
                    "($src MW vs $(round(Int, fleet)) MW unit-level)")
        end
    end

    # Fleet-truthing derate — the symmetric case of fleet completion.
    # When the unit-level fleet (after outage filtering) far exceeds
    # what the type has recently delivered, the excess is phantom
    # capacity: unfiled long-term derates, fuel-supply constraints, or
    # stale unit records. 2022 GR lignite is the canonical case — the
    # book offered ~2.2 GW at lignite SRMC while the real fleet's p95
    # was ~1.2 GW, so cheap phantom lignite displaced gas from the
    # margin and the whole crisis year cleared ~140 €/MWh low. Thermal
    # types only: hydro availability is handled by the water-value
    # offer scale, and RES never enters the thermal stack. The signal
    # (trailing 30-day p95, strictly historical) is ex-ante; 15%
    # headroom above p95 leaves room for genuinely tight days to call
    # on more of the fleet than it recently ran.
    #
    # Baseload/fuel-constrained types ONLY. For a fuel whose SRMC sits
    # below the market price, running under its capacity means it
    # genuinely could not run (mining limits, fuel supply, unfiled
    # derates) — it would have been dispatched otherwise. Mid-merit
    # and peaking fuels (gas, oil) run below capacity simply because
    # of their merit-order position; their capacity IS available at
    # its SRMC, and derating them manufactures phantom scarcity.
    derate_types = ("Fossil Brown coal/Lignite", "Fossil Hard coal",
                    "Fossil Oil shale", "Fossil Coal-derived gas",
                    "Fossil Peat", "Nuclear")
    # One scale per fuel type, applied in a single pass. Iterates the
    # FLEET's types (not type_p95's keys): a derate-listed type with a
    # p95 of zero is a fully offline fleet and derates all the way
    # down, while a type entirely absent from the aggregate table is
    # ambiguous (never-reporting type vs ETL gap) and is skipped
    # loudly rather than silently zeroed. Thermal orders offer raw
    # p_max (availability_factor only shapes the scarcity margin), so
    # the target compares against the raw fleet sum. p_min scales
    # proportionally with p_max — clamping instead would balloon the
    # must-run fraction of every derated unit.
    derate_scale = Dict{Symbol,Float64}()
    if fleet_truthing
        for ptype in derate_types
            fsym = Symbol(ptype)
            fleet_raw = sum((g.p_max for g in generators if g.fuel_type == fsym); init=0.0)
            fleet_raw > 0 || continue
            if !haskey(type_p95, ptype)
                println("  ⚠️  Fleet-truthing: no recent output data for $ptype " *
                        "($(round(Int, fleet_raw)) MW fleet) — derate skipped")
                continue
            end
            # Fleet-truth mode: a market-active type never derates below
            # its truth target (the completion above just trued it to
            # exactly that — derating it back to 1.15×30d-p95 would cancel
            # the mechanism for precisely the baseload derate-types it
            # targets). :p95 zones (GR/SEE) have fleet_truth_target empty —
            # byte-identical v10 behaviour.
            target = max(derate_headroom * type_p95[ptype],
                         get(fleet_truth_target, ptype, 0.0))
            fleet_raw > target + 100.0 || continue
            derate_scale[fsym] = target / fleet_raw
            println("  ➖ Fleet-truthing derate: $ptype ×$(round(target / fleet_raw, digits=2)) " *
                    "(fleet $(round(Int, fleet_raw)) MW vs recent p95 $(round(Int, type_p95[ptype])) MW)")
        end
    end
    # Thermal SRMC premium (ITALY_PROFILE): scale the marginal cost of
    # thermal fuels only — hydro/storage price at water value, not fuel
    # cost, and RES never enters the thermal stack. gas_srmc (the hydro
    # anchor) is computed separately and is unaffected. Default multiplier
    # 1.0 leaves every cost untouched (byte-identical for SEE).
    srmc_exempt_fuels = Set{Symbol}(vcat(WATER_VALUE_FUEL_TYPES,
        [Symbol("Hydro Run-of-river and pondage"), Symbol("Energy storage")]))
    apply_srmc_premium = thermal_srmc_multiplier != 1.0
    # Nuclear bid-position floor (FRANCE_PROFILE): raise the nuclear bid
    # base to at least this level — nuclear-dominated exporters price their
    # modulating fleet at opportunity cost, not fuel SRMC. Default 0.0 is a
    # no-op (byte-identical for SEE).
    # When the :nuclear anchor is ACTIVE the static floor is replaced by the
    # per-slot anchor floor in the order loop (a static floor would hold the
    # price up in exactly the RES-surplus hours where the coupled price —
    # and EDF's opportunity cost — collapses: 2026-04 weekends, FR actual
    # €9 vs the €55 floor).
    apply_nuclear_floor = nuclear_srmc_floor > 0.0 &&
                          !(anchor_active && opportunity_anchor == :nuclear)
    if !isempty(derate_scale) || apply_srmc_premium || apply_nuclear_floor
        generators = [begin
            s = get(derate_scale, g.fuel_type, 1.0)
            m = (apply_srmc_premium && !(g.fuel_type in srmc_exempt_fuels)) ?
                thermal_srmc_multiplier : 1.0
            mc = g.marginal_cost * m
            if apply_nuclear_floor && g.fuel_type == Symbol("Nuclear")
                mc = max(mc, nuclear_srmc_floor)
            end
            (s < 1.0 || mc != g.marginal_cost) ?
                Generator(g.code, g.name, g.fuel_type, g.location,
                          g.p_max * s, g.p_min * s,
                          g.bidding_zone, mc,
                          g.ramp_up, g.ramp_down, g.min_uptime, g.min_downtime) :
                g
        end for g in generators]
    end
    return generators
end

"""
Stage 2 — turn raw load/RES rows into per-timeslot MW dictionaries on the
clearing grid: temporal disaggregation, down-aggregation to hourly or
piecewise-constant upsampling to the shared finer grid, then the scenario
load/renewable modifiers. Returns
`(target_timeslots, load_by_time, renewable_by_time, resolution_minutes)`.
"""
# cv32: per-(zone, day) winner-input deltas — hour-prefix ("yyyymmdd-HH") →
# (corrected − raw ENTSO-E fc) MW for the corrected target type(s). One small
# query per zone-day (corrections join per-type fc, both dialects), cached
# like the other day-level inputs; NEVER cached on error, warn-once fail-soft
# (a missing table — e.g. an extract built before cv32 — degrades to the raw
# forecast, not to a crash).
const _CV32_DELTA_CACHE = Dict{Tuple{String,Date},Dict{String,Float64}}()
const _CV32_DELTA_LOCK = ReentrantLock()
const _CV32_WARNED = Ref{Bool}(false)

function _input_correction_deltas(zone::String, day::Date)
    lock(_CV32_DELTA_LOCK) do
        haskey(_CV32_DELTA_CACHE, (zone, day)) && return _CV32_DELTA_CACHE[(zone, day)]
        out = Dict{String,Float64}()
        try
            df = sql2df_with_retry("""
                SELECT c.target AS tgt, c.date_time_utc AS h,
                       c.corrected_mw - f.mw AS delta
                FROM simulations.input_corrections c
                JOIN (
                    -- hourly mean PER production type, then SUM over the types
                    -- of the target: the emitter's corrected_mw is the SUM over
                    -- Wind Onshore + Offshore, so an AVG across them here added
                    -- ~half the total wind as a phantom delta (bug sweep
                    -- 2026-08-25; latent until DK1's package is enabled).
                    SELECT tgt, h, SUM(mw) AS mw
                    FROM (
                        SELECT CASE WHEN production_type LIKE 'Solar%' THEN 'solar'
                                    ELSE 'wind' END AS tgt,
                               production_type,
                               date_trunc('hour', date_time_utc) AS h,
                               AVG(day_ahead_generation_forecast_mw) AS mw
                        FROM entsoe.generation_forecasts_for_wind_and_solar
                        WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
                          AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
                          AND date_time_utc < ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
                        GROUP BY 1, 2, 3
                    ) t
                    GROUP BY 1, 2
                ) f ON f.tgt = c.target AND f.h = c.date_time_utc
                WHERE c.bidding_zone = \$1
                  AND c.date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
                  AND c.date_time_utc < ((\$2::date + 1)::timestamp AT TIME ZONE 'UTC')
                """, Any[zone, day])
            for r in eachrow(df)
                (ismissing(r.delta)) && continue
                k = Dates.format(r.h, "yyyymmdd-HH")
                out[k] = get(out, k, 0.0) + Float64(r.delta)
            end
        catch e
            if !_CV32_WARNED[]
                _CV32_WARNED[] = true
                @warn "cv32 input-corrections unavailable — raw forecasts kept" zone day error = sprint(showerror, e)
            end
            return out   # fail-soft, NOT cached
        end
        _CV32_DELTA_CACHE[(zone, day)] = out
        return out
    end
end

"Clear the cv32 winner-input delta cache (tests / long processes)."
clear_input_correction_cache!() = (lock(_CV32_DELTA_LOCK) do; empty!(_CV32_DELTA_CACHE); end; nothing)

# ── GR surplus-quantity lever 2: overnight-runner commitments ─────────────
# (prereg docs/experiments/gr-surplus-quantity/prereg-2026-08.md, opt-in via
# EUPHEMIA_ENABLE_GRSQ_T2 — NOT shipped until the package's gates pass.)
const _GRSQ_COMMIT_CACHE = Dict{Tuple{String,Date},Dict{String,Float64}}()
const _GRSQ_COMMIT_LOCK = ReentrantLock()

"""
Valley-continuation commitments: unit_code → demonstrated committed MW.
A thermal unit qualifies as an overnight runner if its per-day mean 00–04 UTC
output exceeded 10% of p_max on ≥60% of the trailing-28-day window (2-day
lag — ex-ante). Committed MW = p25 of those daily overnight means, capped at
p_max. Missing days count against the 60% (fail-soft: the ~3-week per-unit
feed tail lag simply leaves the lever inert on recent days, live and
offline alike). Cached per (zone, day); never cached on DB error.
"""
function _valley_continuation_commits(zone::String, day::Date,
                                      generators::Vector{Generator})
    lock(_GRSQ_COMMIT_LOCK) do
        haskey(_GRSQ_COMMIT_CACHE, (zone, day)) &&
            return _GRSQ_COMMIT_CACHE[(zone, day)]
    end
    pmax = Dict{String,Float64}(g.code => g.p_max for g in generators
                                if !(g.fuel_type in FLEXIBLE_FUEL_TYPES) &&
                                   g.p_max > 0)
    isempty(pmax) && return Dict{String,Float64}()
    df = sql2df_with_retry("""
        SELECT generation_unit_code AS code, CAST(date_time_utc AS date) AS d,
               AVG(actual_generation_output_mw) AS mw
        FROM entsoe.actual_generation_output_per_generation_unit
        WHERE generation_unit_code = ANY(\$1)
          AND EXTRACT(HOUR FROM date_time_utc) < 4
          AND actual_generation_output_mw IS NOT NULL
          AND date_time_utc >= ((\$2::date - 29)::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < ((\$2::date - 1)::timestamp AT TIME ZONE 'UTC')
        GROUP BY 1, 2
    """, Any[collect(keys(pmax)), day])
    byu = Dict{String,Vector{Float64}}()
    for r in eachrow(df)
        ismissing(r.mw) && continue
        push!(get!(byu, String(r.code), Float64[]), Float64(r.mw))
    end
    out = Dict{String,Float64}()
    for (code, vals) in byu
        pm = pmax[code]
        count(v -> v > 0.10 * pm, vals) >= 0.6 * 28 || continue
        out[code] = min(quantile(vals, 0.25), pm)
    end
    lock(_GRSQ_COMMIT_LOCK) do
        _GRSQ_COMMIT_CACHE[(zone, day)] = out
    end
    return out
end

"Clear the valley-continuation commitment cache (tests / long processes)."
clear_valley_commit_cache!() = (lock(_GRSQ_COMMIT_LOCK) do; empty!(_GRSQ_COMMIT_CACHE); end; nothing)

# ── cv34 T3: demonstrated pumping capability ──────────────────────────────
const _PUMP_CAP_CACHE = Dict{Tuple{String,Date},Dict{Int,Float64}}()
const _PUMP_CAP_LOCK = ReentrantLock()

"""
Trailing-30d (2-day lag) p95 of the zone's hourly pumped-storage CONSUMPTION
(`actual_consumption_mw`, per-type aggregate) — the demonstrated surplus-
absorption capability behind the cv34 T3 pumping-demand order. Ex-ante by
construction; NaN when the zone reports no pumping (the CH data gap).
Cached per (zone, day); never cached on DB error.
"""
function _pump_capability(zone::String, day::Date)
    lock(_PUMP_CAP_LOCK) do
        haskey(_PUMP_CAP_CACHE, (zone, day)) && return _PUMP_CAP_CACHE[(zone, day)]
    end
    # Round-2 INCREMENTAL basis (the round-1 double-count lesson): the ENTSO-E
    # load fc already embeds expected pumping, so the order quantity is the
    # HEADROOM = trailing p95 (all hours) − trailing MEAN for that hour-of-day.
    df = sql2df_with_retry("""
        WITH hourly AS (
            SELECT date_trunc('hour', date_time_utc) AS h,
                   AVG(actual_consumption_mw) AS mw
            FROM entsoe.aggregated_generation_per_type
            WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
              AND production_type = 'Hydro Pumped Storage'
              AND actual_consumption_mw IS NOT NULL
              AND date_time_utc >= ((\$2::date - 32)::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < ((\$2::date - 2)::timestamp AT TIME ZONE 'UTC')
            GROUP BY 1)
        SELECT EXTRACT(HOUR FROM h)::int AS hh, AVG(mw) AS hmean,
               (SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY mw) FROM hourly) AS p95
        FROM hourly GROUP BY 1""", Any[zone, day])
    head = Dict{Int,Float64}()
    for r in eachrow(df)
        (ismissing(r.hmean) || ismissing(r.p95)) && continue
        head[Int(r.hh)] = max(Float64(r.p95) - Float64(r.hmean), 0.0)
    end
    lock(_PUMP_CAP_LOCK) do
        _PUMP_CAP_CACHE[(zone, day)] = head
    end
    return head
end

"Clear the cv34 pumping-capability cache (tests / long processes)."
clear_pump_capability_cache!() = (lock(_PUMP_CAP_LOCK) do; empty!(_PUMP_CAP_CACHE); end; nothing)

function _demand_series(loads, renewables,
    target_resolution_minutes::Union{Int,Nothing},
    load_modifier::Union{Nothing,Function},
    renewable_modifier::Union{Nothing,Function})
    target_timeslots, load_by_time, renewable_by_time, resolution_minutes =
        disaggregate_temporal_data(loads, renewables)

    # Resolution harmonization for multi-zone books: zones publish at
    # different resolutions (e.g. RO/HU 15-min, GR/BG hourly) and a
    # combined book with mixed timeslots isolates the hourly zones in
    # sub-hour slots. Aggregate MW values to the coarser target by
    # averaging sub-slots (MW is power — averaging preserves energy).
    if target_resolution_minutes !== nothing && resolution_minutes < target_resolution_minutes
        target_resolution_minutes == 60 ||
            error("Only hourly (60) target resolution is supported for down-aggregation, got $target_resolution_minutes")
        hour_key(ts) = ts[1:11] * "00"
        function aggregate_to_hours(d::Dict{String,Float64})
            sums = Dict{String,Tuple{Float64,Int}}()
            for (ts, v) in d
                k = hour_key(ts)
                s, n = get(sums, k, (0.0, 0))
                sums[k] = (s + v, n + 1)
            end
            return Dict{String,Float64}(k => s / n for (k, (s, n)) in sums)
        end
        load_by_time = aggregate_to_hours(load_by_time)
        renewable_by_time = aggregate_to_hours(renewable_by_time)
        target_timeslots = sort(collect(keys(load_by_time)))
        println("  🕐 Aggregated $(resolution_minutes)-min data to hourly ($(length(target_timeslots)) slots)")
        resolution_minutes = target_resolution_minutes
    elseif target_resolution_minutes !== nothing && resolution_minutes > target_resolution_minutes
        # UPSAMPLE (piecewise-constant REPLICATION) to a finer target grid.
        # A zone whose native data is coarser than the shared clearing grid
        # (e.g. an hourly PT60M zone in a 15-min clear) has each native
        # slot's MW LEVEL copied into every finer sub-slot it spans.
        # Load and generation are power levels (MW), NOT energy (MWh): a
        # plant offering 500 MW offers 500 MW in each quarter — the energy
        # divides naturally because the period is shorter, but the level is
        # unchanged. DIVIDING by the sub-slot count would quarter both
        # demand and supply and misprice everything. Downstream per-slot
        # computations (scarcity margin, water value, demand orders, net
        # imports which are hour-keyed) then run on the shared finer grid
        # exactly as they would for a natively-fine zone.
        target_resolution_minutes in (15, 30) ||
            error("Only 15 or 30-min target resolution is supported for up-replication, got $target_resolution_minutes")
        load_by_time = replicate_to_finer_resolution(load_by_time, resolution_minutes, target_resolution_minutes)
        renewable_by_time = replicate_to_finer_resolution(renewable_by_time, resolution_minutes, target_resolution_minutes)
        target_timeslots = sort(collect(keys(load_by_time)))
        println("  🕐 Upsampled $(resolution_minutes)-min data to $(target_resolution_minutes)-min " *
                "($(length(target_timeslots)) slots) by piecewise-constant replication")
        resolution_minutes = target_resolution_minutes
    end

    # Scenario demand/supply modifiers, applied at the SOURCE dictionaries
    # (after disaggregation and any hourly aggregation) so the change
    # propagates to net demand, scarcity margin, water value and demand
    # orders. No-op when the hooks are nothing.
    if load_modifier !== nothing
        for ts in keys(load_by_time)
            load_by_time[ts] = load_modifier(ts, load_by_time[ts])
        end
    end
    if renewable_modifier !== nothing
        for ts in keys(renewable_by_time)
            renewable_by_time[ts] = renewable_modifier(ts, renewable_by_time[ts])
        end
    end
    return target_timeslots, load_by_time, renewable_by_time, resolution_minutes
end

"""
Stage 4 — hydro fleet state: offered-quantity scale (recent-output cap or,
for `:reservoir_opportunity` zones, reservoir fullness), dryness (reservoir
levels vs seasonal norm, output-based fallback) and the seasonal drawdown
signal. Returns `(hydro_pmax, hydro_scale, hydro_dryness, reservoir_drawdown)`.
"""
function _hydro_state(generators::Vector{Generator}, bidding_zone::String,
    day::Date, hydro_model::Symbol, seasonal_drawdown::Bool)
    hydro_pmax = sum((g.p_max for g in generators if _is_hydro(g)); init=0.0)
    hydro_scale = 1.0   # offered-quantity cap (fraction of nameplate)
    hydro_dryness = 0.0 # 0 = normal water conditions, →1 = severe drought
    reservoir_drawdown = 0.0 # 0 = reservoir at seasonal peak, →1 = drawn down
    if hydro_pmax > 1.0
        hydro_avail = get_hydro_availability(bidding_zone, day)
        if hydro_avail !== nothing
            hydro_scale = clamp(hydro_avail / hydro_pmax, 0.2, 1.0)
        end
        # Dryness: prefer reservoir filling levels vs seasonal norm
        # (measures the water itself); fall back to recent-vs-1y output
        # when filling data is unavailable for the zone. Output-based
        # dryness is confounded by dispatch incentive: hydro running
        # hard because prices are high looks "wet" while reservoirs
        # are actually draining.
        reservoir_dryness = get_reservoir_dryness(bidding_zone, day)
        if reservoir_dryness !== nothing
            hydro_dryness = reservoir_dryness
        elseif hydro_avail !== nothing
            # Fallback only when no reservoir filling data: the 365-day
            # output norm is an expensive near-full scan of the per-type
            # table, so compute it lazily here rather than unconditionally.
            hydro_norm = get_hydro_availability(bidding_zone, day; lookback_days=365)
            if hydro_norm !== nothing && hydro_norm > 1.0
                hydro_dryness = clamp(1.0 - hydro_avail / hydro_norm, 0.0, 1.0)
            end
        end
        # Reservoir-opportunity zones (Nordic) govern offered hydro QUANTITY
        # by reservoir level, not by recent output. The p95-output cap above
        # is a gas-world energy-limited heuristic; in a hydro-dominated,
        # capacity-rich system it spuriously starves the book (e.g. NO1's
        # standalone supply/demand ratio ≈ 0.95 → phantom shortage at the
        # cap) even when reservoirs are full. Tie the offered fraction to
        # reservoir fullness instead: full → near-nameplate, severe drought
        # → half (inflow-only). Scarcity here is priced through the water
        # value, not rationed through quantity.
        if hydro_model == :reservoir_opportunity
            hydro_scale = clamp(1.0 - hydro_dryness, 0.5, 1.0)
            # Seasonal water-value signal: the absolute reservoir drawdown
            # (vs the trailing-52-week peak) prices the water as scarcer
            # through winter even when the prior-year-relative dryness reads
            # ~0. Affects the PRICE (wv_frac below), never the offered
            # quantity. Only the non-anchored reservoir zones
            # (SE1/SE2/FI/DK1/DK2/NO4) reach the wv_frac branch — the
            # Norway/alpine :hydro-anchored zones price off the anchor.
            if seasonal_drawdown
                dd = get_reservoir_drawdown(bidding_zone, day)
                dd !== nothing && (reservoir_drawdown = dd)
            end
        end
        println("  💧 Hydro: offer scale $(round(hydro_scale, digits=2)), " *
                "dryness $(round(hydro_dryness, digits=2))" *
                (reservoir_dryness !== nothing ? " (reservoir levels)" : " (output-based fallback)") *
                (hydro_model == :reservoir_opportunity ? " [reservoir-opportunity]" : ""))
    end
    return hydro_pmax, hydro_scale, hydro_dryness, reservoir_drawdown
end

"""
Stage 5 — UC-lite committed set: the cheapest eligible thermal units whose
derated capacity covers the day's peak residual demand. Only these units
self-schedule their minimum load in the order loop.
"""
function _committed_set(generators::Vector{Generator}, peak_residual::Float64,
    gas_srmc::Float64, must_run_srmc_threshold::Float64,
    availability_factor::Float64)
    committed = Set{String}()
    eligible = sort(
        [g for g in generators
         if !(g.fuel_type in WATER_VALUE_FUEL_TYPES) &&
            g.marginal_cost <= must_run_srmc_threshold * gas_srmc &&
            g.p_min > 0.1],
        by=g -> g.marginal_cost)
    cum_capacity = 0.0
    for g in eligible
        cum_capacity >= 1.05 * peak_residual && break
        push!(committed, g.code)
        cum_capacity += availability_factor * g.p_max
    end
    return committed
end

"""
    _nuclear_avail_frac(bidding_zone, day) -> Union{Nothing,Float64}

Ex-ante nuclear availability fraction for the cv23 availability-scaled nuclear
opportunity cost (`docs/experiments/cv23-fr-nuclear.md`): trailing-30d nuclear
output p95 ÷ installed nuclear capacity — both strictly historical (no lookahead,
no price input). Reuses the exact `get_type_output_p95` (day-cached) and
`get_installed_capacity_by_type` (process-cached) queries fleet-truthing already
runs, so it is free. `nothing` when either input is missing (the caller falls
back to the fixed `anchor_share`).
"""
function _nuclear_avail_frac(bidding_zone::String, day::Date)
    p95 = get(get_type_output_p95(bidding_zone, day), "Nuclear", 0.0)
    inst = get(get_installed_capacity_by_type(bidding_zone, day), "Nuclear", 0.0)
    (p95 > 0.0 && inst > 0.0) || return nothing
    return clamp(p95 / inst, 0.0, 1.0)
end

"""
    _effective_nuclear_share(profile, anchor_active, opportunity_anchor,
                             anchor_share, bidding_zone, day) -> Float64

The `:nuclear` opportunity-anchor share for this zone-day. When the profile opts
into the availability scaling (`nuclear_avail_share_hi > 0`) AND the `:nuclear`
anchor is active, the fixed `anchor_share` is replaced by a share that rises as
the ex-ante nuclear energy budget tightens (low availability = summer maintenance
/ river-temperature de-rating / the 2023 crisis) — the reservoir/water-value
analogy for the energy-constrained EDF fleet. Otherwise returns `anchor_share`
unchanged (byte-identical). See the `ZoneProfile` field docstring + the cv23 doc.
"""
function _effective_nuclear_share(profile::ZoneProfile, anchor_active::Bool,
    opportunity_anchor::Symbol, anchor_share::Float64,
    bidding_zone::String, day::Date)
    (anchor_active && opportunity_anchor == :nuclear &&
     profile.nuclear_avail_share_hi > 0.0) || return anchor_share
    a = _nuclear_avail_frac(bidding_zone, day)
    a === nothing && return anchor_share
    tight = clamp(
        (NUCLEAR_AVAIL_REF - a) /
        max(NUCLEAR_AVAIL_REF - NUCLEAR_AVAIL_FLOOR, 1e-6),
        0.0, 1.0)
    share = profile.nuclear_avail_share_lo +
            (profile.nuclear_avail_share_hi - profile.nuclear_avail_share_lo) * tight
    println("  ⚛️  Nuclear availability $(round(a, digits=2)) → opportunity share " *
            "$(round(share, digits=2)) (tightness $(round(tight, digits=2)))")
    return share
end

"""
    create_merit_order_book(bidding_zone::String, day::Date; kwargs...)

Create a deterministic merit-order-based order book for MPCC clearing.

# Keyword arguments (bidding strategy parameters)

Only parameters that actually DIFFER between zones are overridable. Everything
that held the same value in all 39 zones is a module constant — `TRANCHES`,
`PRICE_CAP`, `DEMAND_ELASTIC_SHARE`/`_PRICE`, `FLEET_COMPLETION`,
`FLEET_TRUTHING`, `DERATE_HEADROOM`, `MUST_RUN_*`, `AVAILABILITY_FACTOR`,
`PEAK_EXPONENT`, `WATER_VALUE_DRY_BOOST`, `BACKSTOP_*`, `NUCLEAR_AVAIL_*` —
and is no longer a keyword argument.

- `profile`: the zone's `ZoneProfile`; the normal way to vary anything below
- `scarcity_threshold`: capacity margin below which scarcity markup kicks in
- `scarcity_kappa` / `peak_kappa`: scarcity and peak markup coefficients
- `water_value_base` / `water_value_span`: hydro opportunity cost as a
  multiple of gas SRMC, scaled across the day's demand range
- `thermal_srmc_multiplier`, `hydro_model`, `nuclear_srmc_floor`,
  `opportunity_anchor`, `anchor_share`: the remaining per-zone levers

# Scenario hooks (all default `nothing`; when all are `nothing` the code path
# is byte-identical to the no-kwargs call)
- `load_modifier::Union{Nothing,Function}`: `f(timeslot::String, load_mw::Float64) -> Float64`,
  applied to every entry of `load_by_time` at the source (after temporal
  disaggregation and any hourly aggregation), so the change propagates to net
  demand, scarcity margin, water value and demand orders.
- `renewable_modifier::Union{Nothing,Function}`: same signature, applied to
  `renewable_by_time` at the same point (e.g. `(ts, v) -> v + 300` during
  daylight slots models +300 MW of solar).
- `extra_orders::Union{Nothing,Function}`: `f(ctx) -> Vector{SimpleOrder}`,
  called after all standard orders are built and BEFORE merging. `ctx` is a
  NamedTuple `(zone, day, timeslots, resolution_minutes, load_by_time,
  renewable_by_time)`. Returned orders (`:supply` or `:demand`) are appended
  (tagged `"EXTRA"`). Models "ships request more power" (cap-priced demand) or
  "a new plant" (supply).
- `strategist::Union{Nothing,Function}`: `f(ctx) -> Vector{Tuple{SimpleOrder,String}}`
  (a plain `Vector{SimpleOrder}` is also accepted and re-tagged `"STRATEGIST"`),
  called after `extra_orders` and before merging. `ctx` is a NamedTuple
  `(tagged_orders, zone, day, timeslots, load_by_time, renewable_by_time,
  firm_of)` where `firm_of` is a `Dict{String,String}` unit_code→firm from
  `simulations.unit_firms`. The returned set REPLACES the tagged order list.

  Example — "what if the incumbent PPC marked up its peakers' top tranches 20%?":
  ```julia
  strat = ctx -> [ (firm_of_ppc(ctx, o, tag) ? bump(o) : o, tag)
                   for (o, tag) in ctx.tagged_orders ]
  ```
  A strategist that finds all orders whose `firm_of[tag] == "PPC"` and
  multiplies their two top tranche prices by 1.2, returning everything else
  unchanged.
- `fleet_modifier::Union{Nothing,Function}`: `f(zone::String, gens::Vector{Generator}) -> Vector{Generator}`,
  a first-class capacity primitive — add, remove or derate physical units as
  DATA (not orders). Called AFTER fleet completion and fleet-truthing, so a
  removed unit is not re-added by the `:installed`/p95 truth-up and the offered
  fleet is exactly what the modifier returns (scenario edits are physical
  reality changes; truthing runs on the pre-scenario registry). Returning an
  empty vector fails the build gracefully.
- `load_fill::Union{Nothing,Function}`: `f(zone::String, day::Date) ->
  Union{Nothing,Dict{String,Float64}}` (timeslot `"yyyymmdd-HHMM"` → MW). MERGES
  model load for the hours the TSO day-ahead load for this zone/day did NOT
  publish — the daily-forecast eligibility fill (`bin/daily_forecast.jl`). A
  present TSO hour is never overridden (hour-granularity merge); `nothing` or an
  empty dict leaves the DB load untouched (byte-identical). Unlike
  `load_modifier`, which only reshapes existing entries, this provides load for a
  zone the TSO never published. The merged load flows through the SAME
  `_demand_series` stage (temporal grid, `load_modifier` if also present, demand
  orders, net demand, scarcity) as DB load.
- `res_fill::Union{Nothing,Function}`: the RES twin of `load_fill` (same
  signature). MERGES weather-model wind+solar MW for the hours the TSO 14.1.D
  wind/solar forecast did NOT publish, into the renewable forecast (as hourly
  "WeatherFill" rows) before `_demand_series` — so it propagates to
  `renewable_by_time`, the near-zero-price RES supply orders, and the net-demand
  residual exactly like DB RES. A present TSO RES hour is never overridden;
  `nothing`/empty is byte-identical.

Both the single-zone (`:merit_order`) `generate_energy_prices` path and the
multi-zone `run_multi_zone_market_clearing(...; scenario=...)` path thread these
hooks (the latter via `ZoneScenario`). When every hook is `nothing` the built
book is byte-identical to the no-hook book.
"""
function create_merit_order_book(
    bidding_zone::String,
    day::Date;
    profile::ZoneProfile=SEE_PROFILE,
    scarcity_threshold::Union{Nothing,Float64}=nothing,
    scarcity_kappa::Union{Nothing,Float64}=nothing,
    peak_kappa::Union{Nothing,Float64}=nothing,
    water_value_base::Union{Nothing,Float64}=nothing,
    water_value_span::Union{Nothing,Float64}=nothing,
    include_net_imports::Bool=true,
    net_import_exclude::Vector{String}=String[],
    net_import_import_only::Vector{String}=String[],
    target_resolution_minutes::Union{Int,Nothing}=nothing,
    thermal_srmc_multiplier::Union{Nothing,Float64}=nothing,
    hydro_model::Union{Nothing,Symbol}=nothing,
    nuclear_srmc_floor::Union{Nothing,Float64}=nothing,
    opportunity_anchor::Union{Nothing,Symbol}=nothing,
    anchor_share::Union{Nothing,Float64}=nothing,
    anchor_prices::Union{Nothing,Dict{String,Float64}}=nothing,
    pass1_prices::Union{Nothing,Dict{String,Float64}}=nothing,
    anchor_export_mw::Dict{Int,Float64}=Dict{Int,Float64}(),
    res_coalesce_missing::Bool=false,
    load_modifier::Union{Nothing,Function}=nothing,
    renewable_modifier::Union{Nothing,Function}=nothing,
    extra_orders::Union{Nothing,Function}=nothing,
    strategist::Union{Nothing,Function}=nothing,
    fleet_modifier::Union{Nothing,Function}=nothing,
    load_fill::Union{Nothing,Function}=nothing,
    res_fill::Union{Nothing,Function}=nothing
)
    # Resolve every bid parameter from the profile, letting an explicit keyword
    # override its profile field. With no overrides and the default SEE_PROFILE
    # this reproduces the pre-abstraction defaults exactly (byte-identical).
    tranches = TRANCHES
    must_run_price_factor = MUST_RUN_PRICE_FACTOR
    must_run_srmc_threshold = MUST_RUN_SRMC_THRESHOLD
    availability_factor = AVAILABILITY_FACTOR
    scarcity_threshold = scarcity_threshold === nothing ? profile.scarcity_threshold : scarcity_threshold
    scarcity_kappa = scarcity_kappa === nothing ? profile.scarcity_kappa : scarcity_kappa
    peak_kappa = peak_kappa === nothing ? profile.peak_kappa : peak_kappa
    peak_exponent = PEAK_EXPONENT
    water_value_base = water_value_base === nothing ? profile.water_value_base : water_value_base
    water_value_dry_boost = WATER_VALUE_DRY_BOOST
    water_value_span = water_value_span === nothing ? profile.water_value_span : water_value_span
    demand_elastic_share = DEMAND_ELASTIC_SHARE
    demand_elastic_price = DEMAND_ELASTIC_PRICE
    price_cap = PRICE_CAP
    fleet_completion = FLEET_COMPLETION
    fleet_truthing = FLEET_TRUTHING
    derate_headroom = DERATE_HEADROOM
    thermal_srmc_multiplier = thermal_srmc_multiplier === nothing ? profile.thermal_srmc_multiplier : thermal_srmc_multiplier
    hydro_model = hydro_model === nothing ? profile.hydro_model : hydro_model
    nuclear_srmc_floor = nuclear_srmc_floor === nothing ? profile.nuclear_srmc_floor : nuclear_srmc_floor
    opportunity_anchor = opportunity_anchor === nothing ? profile.opportunity_anchor : opportunity_anchor
    anchor_share = anchor_share === nothing ? profile.anchor_share : anchor_share
    # The opportunity anchor is active only when BOTH the profile opts in AND
    # pass-1 reference prices were supplied (two-pass clearing, pass 2). With
    # either missing the whole mechanism is dead code — pass 1 and every
    # single-pass path (incl. SEE) are unchanged.
    anchor_active = opportunity_anchor != :none && anchor_prices !== nothing

    try
        println("📊 Creating merit-order order book for $bidding_zone on $day")

        generators = get_generators(bidding_zone, day)

        # ── Stage 1: true up + price the offered fleet ──────────────────
        generators = _true_up_fleet(generators, bidding_zone, day, profile;
                fleet_completion, fleet_truthing, derate_headroom,
                thermal_srmc_multiplier, nuclear_srmc_floor,
                anchor_active, opportunity_anchor)

        # Scenario fleet_modifier — add / remove / derate physical units as
        # DATA. Applied AFTER fleet completion and fleet-truthing (above) on
        # purpose: those two mechanisms true the registry to the zone's
        # recently-observed capability, and they must run on the PRE-scenario
        # registry. If the modifier ran first, removing a 500 MW unit would
        # enlarge the completion gap and the `:installed`/p95 truth-up would
        # silently re-add the same aggregate MW — nullifying the edit. Running
        # it last makes scenario edits genuine "physical reality changes": the
        # offered fleet reflects exactly what the modifier returns. No-op when
        # the hook is nothing (byte-identical).
        if fleet_modifier !== nothing
            generators = collect(fleet_modifier(bidding_zone, generators))
            eltype(generators) <: Generator ||
                error("fleet_modifier must return a Vector{Generator}, got eltype $(eltype(generators))")
            isempty(generators) &&
                return AdjustedOrderBookResult(false,
                    "fleet_modifier removed all generators", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end
        loads = get_loads(bidding_zone, day)
        # Load-fill (daily-forecast eligibility fill): when the TSO day-ahead
        # load for this zone/day is missing/short, add model load for the hours
        # the TSO did NOT publish. MERGE, never replace: a present TSO hour
        # always wins (no-override — checked at HOUR granularity so a native
        # sub-hourly TSO hour is never split by an hourly fill slot). `nothing`
        # or an empty return is a no-op (byte-identical). The caller
        # (bin/daily_forecast.jl) only attaches this hook to short zones, so on a
        # fully-published zone `filled` covers only already-present hours and
        # nothing is added. Filled slots are hourly ("60").
        if load_fill !== nothing
            filled = load_fill(bidding_zone, day)
            if filled !== nothing && !isempty(filled)
                covered = Set(l.timeslot[1:11] for l in loads)   # "yyyymmdd-HH" present in TSO
                added = 0
                for (ts, mw) in filled
                    ts[1:11] in covered && continue              # TSO already covers this hour
                    push!(loads, Load(ts, "60", bidding_zone, mw))
                    added += 1
                end
                added > 0 && println("  🩹 load-fill: $bidding_zone added $added model hour(s) " *
                                     "(TSO published $(length(covered))h; missing hours filled)")
            end
        end
        renewables = get_generation_forecast_for_wind_and_solar(bidding_zone, day;
            coalesce_missing=res_coalesce_missing)
        # RES-fill (daily-forecast RES eligibility fill) — the twin of load-fill.
        # When the TSO 14.1.D wind/solar forecast for this zone/day is
        # missing/short, add weather-model RES for the hours the TSO did NOT
        # publish. MERGE, never replace: an hour with ANY published TSO RES row
        # (even a coalesced 0) is never overridden (hour-granularity check).
        # `nothing`/empty is a no-op (byte-identical). Filled rows are hourly
        # ("60") and tagged production_type "WeatherFill". The caller only
        # attaches this hook to RES-short zones.
        if res_fill !== nothing
            rfilled = res_fill(bidding_zone, day)
            if rfilled !== nothing && !isempty(rfilled)
                rcovered = Set(r.date_time[1:11] for r in renewables)  # "yyyymmdd-HH" present in TSO
                radded = 0
                for (ts, mw) in rfilled
                    ts[1:11] in rcovered && continue                   # TSO already covers this hour
                    push!(renewables, RenewablesGenerationForecast(ts, "60", bidding_zone,
                                                                    "WeatherFill", mw))
                    radded += 1
                end
                radded > 0 && println("  🩹 res-fill: $bidding_zone added $radded model hour(s) " *
                                      "(TSO published $(length(rcovered))h; missing hours filled)")
            end
        end

        if isempty(generators)
            return AdjustedOrderBookResult(false, "No generators found", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end
        if isempty(loads)
            return AdjustedOrderBookResult(false, "No load data found", nothing, 0, 0, 0, 0.0, 0.0, 0.0)
        end

        # ── Stage 2: load/RES series on the clearing grid ───────────────
        # cv32 winner-input corrections (owner-ratified adoption, docs/
        # experiments/recal/): when the profile carries `input_corrections`,
        # the RES series takes the per-hour delta between the winner input
        # (`simulations.input_corrections` — actuals-target ML solar or
        # trailing-debiased fc wind, all D-1-legal) and the raw ENTSO-E
        # forecast, applied BEFORE any scenario modifier so it propagates to
        # net demand / scarcity / water values exactly like the base input.
        # Fail-soft: no rows or a query error ⇒ empty deltas ⇒ byte-identical.
        eff_renewable_modifier = renewable_modifier
        if profile.input_corrections
            cv32_deltas = _input_correction_deltas(bidding_zone, day)
            if !isempty(cv32_deltas)
                base_rm = renewable_modifier
                eff_renewable_modifier = (ts, v) -> begin
                    v2 = max(v + get(cv32_deltas, ts[1:11], 0.0), 0.0)
                    base_rm === nothing ? v2 : base_rm(ts, v2)
                end
                println("  🛠️  cv32 input corrections: $(length(cv32_deltas)) corrected hour(s)")
            end
        end
        target_timeslots, load_by_time, renewable_by_time, resolution_minutes =
            _demand_series(loads, renewables, target_resolution_minutes,
                load_modifier, eff_renewable_modifier)

        # ── Stage 3: net imports, demand state, gas anchor, backstop ────
        # Residual demand per slot (load minus renewables) drives water value
        # and scarcity. Renewables themselves are offered as near-zero-price
        # supply below, NOT netted from demand — this lets prices collapse
        # toward zero in renewable-surplus hours, as they do in reality.
        # Net physical imports as fixed injections: observed cross-border
        # schedules (positive = import). A single zone cleared in isolation
        # systematically overprices import hours and underprices export
        # hours; using the observed schedule is the standard single-zone
        # backtesting treatment. Set include_net_imports=false for a pure
        # isolated-zone simulation (or when forecasting without flow data).
        # cv21 boundary book (profile-gated; nothing everywhere but DK1 ⇒ the
        # code below is inert and the book byte-identical). The counterparty's
        # fixed flow injection is REMOVED here — the elastic ladder (Stage 6b)
        # replaces it — and its backstop headroom is removed just below.
        boundary_book = profile.boundary_book
        # The counterparty's map codes stripped from the fixed net-import
        # injection + backstop headroom (the elastic ladder replaces both). For
        # FR↔GB this is all four codes (aggregate GB + the three cables) so the
        # ≈2× double-count is removed, not just the aggregate — see GB_FR_BOOK.
        boundary_exclude = boundary_book === nothing ? String[] :
                           boundary_net_exclude(boundary_book)
        net_imports = include_net_imports ?
                      get_net_imports(bidding_zone, day;
                          exclude_counterparties=vcat(net_import_exclude, boundary_exclude),
                          import_only_counterparties=net_import_import_only) :
                      Dict{Int,Float64}()
        slot_import(ts) = get(net_imports, Dates.hour(parse_timeslot_to_datetime(ts, day)), 0.0)

        gross_demand = Dict{String,Float64}()
        net_demand = Dict{String,Float64}()
        for ts in target_timeslots
            load_value = get(load_by_time, ts, 0.0)
            renewable_gen = get(renewable_by_time, ts, 0.0)
            gross_demand[ts] = max(10.0, load_value)
            # Residual demand on domestic thermal: load - RES - net imports
            net_demand[ts] = max(10.0, load_value - renewable_gen - slot_import(ts))
        end
        nd_values = [net_demand[ts] for ts in target_timeslots]
        nd_min, nd_max = minimum(nd_values), maximum(nd_values)
        nd_span = max(nd_max - nd_min, 1.0)

        # Gas SRMC anchors hydro water value (TTF-based when data exists)
        gas_srmc = get_marginal_cost(day, "Fossil Gas", bidding_zone)

        # cv23 availability-scaled nuclear opportunity-cost share (FR). Computed
        # once per zone-day from ex-ante nuclear availability; used in place of
        # the fixed `anchor_share` in the `:nuclear` anchor branch below. Equals
        # `anchor_share` for every zone that does not opt in (byte-identical).
        eff_nuclear_share = _effective_nuclear_share(profile, anchor_active,
            opportunity_anchor, anchor_share, bidding_zone, day)

        # Ex-ante elastic import backstop (cv17, profile-gated — see the
        # `import_backstop` field docstring). Computed next to the :v2 flow
        # climatology off the same cached day relations; the offered ATC of
        # the ENDOGENOUS borders (net_import_exclude — kept-ATC neighbors plus
        # shadowed aggregate codes, whose aggregate-coded ATC the remap already
        # carries endogenously) is subtracted so MPCC-deliverable capacity is
        # never double-counted. Empty Dict for every non-backstop profile —
        # byte-identical books.
        backstop_by_hour = (profile.import_backstop && include_net_imports) ?
            get_import_backstop(bidding_zone, day;
                weeks=BACKSTOP_WEEKS,
                endogenous_counterparties=net_import_exclude,
                exclude_counterparties=boundary_exclude) :
            Dict{Int,Float64}()
        backstop_price = BACKSTOP_PRICE_MULT * gas_srmc
        isempty(backstop_by_hour) ||
            println("  🛟 Import backstop: peak $(round(Int, maximum(values(backstop_by_hour)))) MW " *
                    "@ €$(round(backstop_price, digits=1))/MWh " *
                    "($(length(backstop_by_hour)) hours, $(BACKSTOP_WEEKS)-week window)")

        # ── Stage 4: hydro fleet state (offer scale, dryness, drawdown) ──
        hydro_pmax, hydro_scale, hydro_dryness, reservoir_drawdown =
            _hydro_state(generators, bidding_zone, day, hydro_model,
                profile.seasonal_drawdown)
        offered_pmax(g) = _is_hydro(g) ? g.p_max * hydro_scale : g.p_max

        # Dispatchable capacity for the scarcity margin, derated for the
        # realistic availability of the fleet (unreported outages) and for
        # the hydro energy limit — nameplate capacity never looks scarce.
        dispatchable_capacity =
            availability_factor * sum((g.p_max for g in generators if !_is_hydro(g)); init=0.0) +
            hydro_scale * hydro_pmax

        # Available import capacity per UTC hour, credited into the scarcity
        # margin when the profile opts in (thermal import/export zones). 0 = off.
        import_atc_by_hour = profile.scarcity_import_credit > 0.0 ?
            get_import_atc_capacity(bidding_zone, day) : Dict{Int,Float64}()

        # ── Stage 5: UC-lite committed set (peak-covering cheap thermal) ─
        committed = _committed_set(generators, nd_max, gas_srmc,
            must_run_srmc_threshold, availability_factor)

        # ── Stage 6: the supply order loop (RES, imports, hydro, thermal) ─
        # Every order is tagged with an owner (Feature 5, strategist hook):
        # the generator code for unit orders, "RES" for the renewable
        # forecast, "IMPORT" for net-import injections, "DEMAND" for demand
        # orders, "EXTRA" for extra_orders, "STRATEGIST" for strategist
        # replacements. Tags never affect the SimpleOrder values, so with no
        # hooks the merged book is byte-identical to before.
        tagged = Tuple{SimpleOrder,String}[]
        # PARALLEL to `tagged`: strategies[i] is the STRATEGY label of tagged[i]
        # (the WHY of that block — see STRATEGY_DESCRIPTIONS). Kept in lockstep by
        # `push_tagged!`; the `(order, owner_tag)` tuples the strategist hook +
        # firm_of map consume are unchanged. Carried to BOOK_SINK for the parquet
        # `strategy` column; NEVER passed into the strategist ctx.
        strategies = String[]
        push_tagged!(o::SimpleOrder, owner::String, strat::String) = begin
            push!(tagged, (o, owner)); push!(strategies, strat)
        end
        supply_orders_count = 0
        demand_orders_count = 0
        total_demand_quantity = 0.0
        total_supply_capacity = 0.0

        # ── Solar-regime price-taker floor (cv31, default-ON) ───────────
        # Regime-gated revival of the cv28/cv29 price-taker floor. The gate is
        # an EX-ANTE per-zone-hour regime axis — the day-ahead SOLAR share of
        # forecast load (solar_fc/load_fc) — NOT the cv29 domestic surplus
        # signal. Phase-1 cartography (docs/experiments/solar-regime) shows the
        # continental-solar group (DE_LU/FR/PL/BE/CZ/CH) systematically
        # OVERPRICES by +15..+18 €/MWh in high-solar hours where the settled
        # market crashes to ≤0 (28..50% of those hours) while the model reaches
        # ≤5 only 10..24% of the time. In regime hours the RES block, run-of-
        # river and the deepest must-run block (BLOCKS=full) price at the
        # declared negative floor so the clear can genuinely fall below zero.
        #
        # cv31 ACTIVATION (#251 measured accepted arm — Set A −1.50 within-regime
        # dMAE / phantom 0 / 0 new caps; Set B confirmed): the SHIPPED default is
        # ON with θ=0.4, BLOCKS=full, ZONES=DE_LU,FR,PL,BE,CZ,CH. Kill-switch
        # EUPHEMIA_DISABLE_CV31 set ⇒ fully inert (byte-identical to pre-cv31
        # main). Explicit EUPHEMIA_SOLAR_REGIME* env vars still WIN over the
        # scoped default (house convention, the FLOW_ASOF precedent):
        # EUPHEMIA_SOLAR_REGIME=0 forces the mechanism off, and THETA/BLOCKS/
        # ZONES override the shipped values for A/Bs. One declared parameter: θ.
        sr_disabled = !isempty(get(ENV, "EUPHEMIA_DISABLE_CV31", ""))
        solar_regime = !sr_disabled &&
            (haskey(ENV, "EUPHEMIA_SOLAR_REGIME") ?
                !(isempty(ENV["EUPHEMIA_SOLAR_REGIME"]) ||
                  ENV["EUPHEMIA_SOLAR_REGIME"] == "0") :
                true)
        sr_zones = Set(strip.(split(get(ENV, "EUPHEMIA_SOLAR_REGIME_ZONES",
            "DE_LU,FR,PL,BE,CZ,CH"), ",")))
        solar_regime_on = solar_regime && (bidding_zone in sr_zones)
        sr_theta = parse(Float64, get(ENV, "EUPHEMIA_SOLAR_REGIME_THETA", "0.4"))
        # cv34 T1 (prereg docs/experiments/continental-collapse/): a ZONAL θ
        # override — EUPHEMIA_SOLAR_REGIME_THETA_<ZONE> (zone name with "-"
        # mapped to "_") wins over the group θ for that zone only. Unset ⇒
        # byte-identical to the group gate.
        let zk = "EUPHEMIA_SOLAR_REGIME_THETA_" * replace(bidding_zone, "-" => "_")
            haskey(ENV, zk) && (sr_theta = parse(Float64, ENV[zk]))
        end
        sr_full = solar_regime_on &&
                  get(ENV, "EUPHEMIA_SOLAR_REGIME_BLOCKS", "full") == "full"
        # cv34 T2: deep-tier floor — when the hour's solar share ALSO clears
        # θ2 (EUPHEMIA_SOLAR_REGIME_THETA2), the regime floor deepens to
        # EUPHEMIA_SOLAR_REGIME_FLOOR2 (default −80). θ2 unset ⇒ tier 2
        # disabled entirely (single −20 floor, byte-identical to cv31).
        sr_theta2 = haskey(ENV, "EUPHEMIA_SOLAR_REGIME_THETA2") ?
            parse(Float64, ENV["EUPHEMIA_SOLAR_REGIME_THETA2"]) : Inf
        sr_floor2 = parse(Float64, get(ENV, "EUPHEMIA_SOLAR_REGIME_FLOOR2", "-80"))
        solar_share_hr = Dict{Int,Float64}()
        if solar_regime_on
            sol_hr = Dict{Int,Vector{Float64}}()
            ld_hr = Dict{Int,Vector{Float64}}()
            for r in renewables
                r.production_type == "Solar" || continue
                length(r.date_time) >= 11 || continue
                push!(get!(sol_hr, parse(Int, r.date_time[10:11]), Float64[]),
                      r.aggregated_generation_forecast)
            end
            for (ts, v) in load_by_time
                length(ts) >= 11 || continue
                push!(get!(ld_hr, parse(Int, ts[10:11]), Float64[]), v)
            end
            for (h, vs) in sol_hr
                lv = haskey(ld_hr, h) ? sum(ld_hr[h]) / length(ld_hr[h]) : 0.0
                solar_share_hr[h] = lv > 0 ? (sum(vs) / length(vs)) / lv : 0.0
            end
        end
        sr_active(hr) = solar_regime_on && get(solar_share_hr, hr, 0.0) >= sr_theta
        # cv34 T2: the floor for an ACTIVE regime hour (tier 2 if share >= θ2)
        sr_floor(hr) = get(solar_share_hr, hr, 0.0) >= sr_theta2 ? sr_floor2 :
                       DEEP_SURPLUS_FLOOR_EUR

        # ── cv34 T4: thermal valley wall, pass-1-gated (prereg
        # docs/experiments/continental-collapse/prereg-draft-2026-08.md) ──
        # The valley-continuation mechanism (GR archive) re-gated with the GR
        # selectivity lesson: the continuation tranche fires ONLY in slots
        # where the zone's own PASS-1 coupled price <= 5 € (the model's own
        # surplus signal — phantom control by construction). Needs
        # pass1_prices (pass-2 rebuilds only); EUPHEMIA_CV34_T4_ZONES empty
        # or unset ⇒ fully inert.
        t4_zones = strip.(split(get(ENV, "EUPHEMIA_CV34_T4_ZONES", ""), ","))
        grsq2_on = bidding_zone in t4_zones && pass1_prices !== nothing
        grsq2_commits = Dict{String,Float64}()
        if grsq2_on
            grsq2_commits = try
                _valley_continuation_commits(bidding_zone, day, generators)
            catch e
                @warn "cv34 T4: commitment query failed — lever inert for $bidding_zone $day" exception=e
                Dict{String,Float64}()
            end
        end
        grsq2_slot(dt) = grsq2_on &&
            get(pass1_prices, Dates.format(dt, "yyyymmdd-HHMM"), Inf) <= 5.0

        for ts in target_timeslots
            date_time = parse_timeslot_to_datetime(ts, day)
            hr = Dates.hour(date_time)   # UTC hour key for all hour-keyed lookups

            # Renewable forecast offered at near-zero price (RES bids as
            # price-taker; support schemes make it insensitive to price)
            res_qty = get(renewable_by_time, ts, 0.0)
            if res_qty > 0.1
                push_tagged!(SimpleOrder(:supply,
                    sr_active(hr) ? sr_floor(hr) : 1.0, res_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes),
                    "RES", "res_forecast")
                supply_orders_count += 1
                total_supply_capacity += res_qty
            end

            # Net imports as price-taking supply (imports) or firm extra
            # demand (exports) — scheduled flows are committed either way
            ni = get(net_imports, hr, 0.0)
            if ni > 0.1
                # :hydro-anchored zones (pass 2): observed imports arrive at
                # the BORDER price, not free — pricing them near zero lets the
                # import block set near-zero clearing prices in every
                # import-covered hour (NO1's flat undershoot: sim ≈ €3 at
                # night vs actual ≈ €88 tracking its neighbors). Priced at the
                # anchor level the import-marginal hours clear at the coupled
                # reference, as they do in reality. Everywhere else imports
                # stay price-taking at €1 (unchanged).
                import_price = (anchor_active && opportunity_anchor == :hydro &&
                                haskey(anchor_prices, ts)) ?
                               clamp(anchor_share * anchor_prices[ts], 1.0, gas_srmc) : 1.0
                push_tagged!(SimpleOrder(:supply, import_price, ni,
                    Symbol(bidding_zone), date_time, resolution_minutes),
                    "IMPORT", "import_fixed")
                supply_orders_count += 1
                total_supply_capacity += ni
            elseif ni < -0.1
                # cv17 ref-priced retained-border exports (profile-gated,
                # pass 2 only): a net export over RETAINED borders (SI–HR,
                # BE–GB) enters as demand at the coupled/anchor reference
                # instead of firm at the cap, so the exporter curtails under
                # domestic stress like a real one — the demand-side mirror of
                # the dropped-border anchor_export_mw treatment. Everywhere
                # else (and in pass 1) the export stays cap-priced firm demand.
                ref_priced = profile.ref_priced_exports && anchor_active &&
                             haskey(anchor_prices, ts)
                export_price = ref_priced ? max(anchor_prices[ts], 1.0) : price_cap
                push_tagged!(SimpleOrder(:demand, export_price, -ni,
                    Symbol(bidding_zone), date_time, resolution_minutes),
                    "IMPORT", ref_priced ? "ref_priced_export" : "export_demand")
                demand_orders_count += 1
                total_demand_quantity += -ni
            end

            # cv17 import-backstop supply block (profile-gated; empty Dict
            # otherwise). Priced above every domestic tranche multiplier, so
            # it binds only when the book would otherwise jump to the cap.
            backstop_qty = get(backstop_by_hour, hr, 0.0)
            if backstop_qty > 1.0
                push_tagged!(SimpleOrder(:supply, backstop_price, backstop_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes),
                    "BACKSTOP", "import_backstop")
                supply_orders_count += 1
                total_supply_capacity += backstop_qty
            end

            # :hydro-anchored zones (pass 2): the export volume observed over
            # the DROPPED flow-based borders re-enters as demand priced at the
            # coupled reference — NOT the cap. NO5 is the measured case: a
            # structural exporter whose import-only clamp removed the export
            # outlet entirely, collapsing its surplus onto a tiny local load
            # (sim €36 vs actual €104). Ref-priced demand clears only when the
            # zone's price is at/below the coupled price, so it cannot
            # manufacture cap scarcity; and it is SEPARATE from the clamped
            # import supply, so it cannot net away import energy either
            # (measured failure mode of netting: NO1 −23 → +134).
            if anchor_active && opportunity_anchor == :hydro &&
               haskey(anchor_prices, ts) && !isempty(anchor_export_mw)
                ex_mw = get(anchor_export_mw, hr, 0.0)
                if ex_mw > 0.1
                    push_tagged!(SimpleOrder(:demand, max(anchor_prices[ts], 1.0),
                        ex_mw, Symbol(bidding_zone), date_time, resolution_minutes),
                        "IMPORT", "ref_priced_export")
                    demand_orders_count += 1
                    total_demand_quantity += ex_mw
                end
            end

            # Normalized within-day demand position (0 = trough, 1 = peak)
            norm_demand = (net_demand[ts] - nd_min) / nd_span

            # Markup on upper supply tranches: absolute scarcity (capacity
            # margin below threshold) plus peak-hour strategic bidding —
            # participants know when the daily peak is and price their last
            # tranches accordingly, even when capacity is formally adequate.
            # The high exponent concentrates the markup in the true peak
            # hours: at norm_demand 0.5 (e.g. summer nights, where residual
            # demand is mid-range) the markup is ~6% of peak_kappa, not 25%.
            # Credit available import capacity (gated): a zone that can import
            # GWs is not domestically scarce. Only the scarcity term is relieved;
            # the peak strategic-bidding term is left intact.
            import_credit = profile.scarcity_import_credit > 0.0 ?
                profile.scarcity_import_credit *
                get(import_atc_by_hour, hr, 0.0) : 0.0
            # cv17: gated scarcity credit for the backstop quantity (the
            # scarcity MARKUP cannot otherwise see the backstop supply, so
            # restored-import days can keep a residual markup overshoot).
            # 0 (default) = off everywhere.
            backstop_credit = profile.backstop_scarcity_credit > 0.0 ?
                profile.backstop_scarcity_credit *
                get(backstop_by_hour, hr, 0.0) : 0.0
            margin = (dispatchable_capacity + import_credit + backstop_credit) / net_demand[ts]
            scarcity = 1.0 +
                       scarcity_kappa * max(0.0, scarcity_threshold - margin)^2 +
                       peak_kappa * norm_demand^peak_exponent

            for g in generators
                if g.fuel_type in WATER_VALUE_FUEL_TYPES
                    # Hydro water value. Two models:
                    #
                    # :gas_anchored (SEE default) — opportunity cost tied to gas
                    # SRMC: cheap relative to gas off-peak, premium over gas at
                    # the peak, boosted in dry periods. Correct where hydro
                    # competes against a gas-set margin.
                    #
                    # :reservoir_opportunity (Nordic) — in a hydro-dominated
                    # zone the price is the shadow value of stored water, NOT a
                    # gas anchor: near-free when reservoirs are full, rising
                    # toward the continental thermal alternative (gas SRMC as a
                    # proxy for the export-market price) as they empty. This
                    # stops full Nordic reservoirs from slamming into scarcity/
                    # cap prices.
                    # :hydro opportunity anchor (two-pass, pass 2): stored
                    # water prices at the export opportunity — the pass-1
                    # coupled reference price (level AND hourly shape) — times
                    # a share slightly below 1 when reservoirs are full
                    # (willing to undercut the continent to export), rising
                    # with dryness. Clamped to [2, gas SRMC].
                    # Strategy label mirrors the water-value branch taken below.
                    wv_strategy = (anchor_active && opportunity_anchor == :hydro &&
                                   haskey(anchor_prices, ts)) ? "water_value_anchored" :
                                  hydro_model == :reservoir_opportunity ?
                                      "water_value_reservoir" : "water_value_gas_anchored"
                    water_value = if anchor_active && opportunity_anchor == :hydro &&
                                     haskey(anchor_prices, ts)
                        # cv34 T5 (round-2 prereg): in regime hours the anchored
                        # water value may yield to the declared floor — the 2.0
                        # lower clamp is the measured CH wall (census step 3).
                        # EUPHEMIA_CV34_T5_ZONES empty/unset ⇒ inert.
                        wv_lo = (bidding_zone in
                                     strip.(split(get(ENV, "EUPHEMIA_CV34_T5_ZONES", ""), ",")) &&
                                 sr_active(hr)) ? sr_floor(hr) : 2.0
                        clamp(anchor_prices[ts] *
                              (anchor_share + water_value_dry_boost * hydro_dryness),
                              wv_lo, gas_srmc)
                    elseif hydro_model == :reservoir_opportunity
                        # Stored water is worth a FRACTION of the continental
                        # thermal price (gas SRMC proxy): an export-opportunity
                        # floor (~0.35×) when reservoirs are full, rising to the
                        # full thermal alternative (1.0×) as they empty. Then
                        # shaped by within-day demand. NOT gas-anchored at parity
                        # — full Nordic reservoirs price well below gas, which is
                        # what stops the scarcity/cap blow-up.
                        # Floor rises with EITHER prior-year dryness OR the
                        # absolute seasonal drawdown (winter reservoir depletion
                        # raises the shadow value of stored water — SE1/SE2 draw
                        # to 55–60% of the annual peak by February at dryness 0).
                        wv_frac = 0.35 + 0.65 * max(hydro_dryness, reservoir_drawdown)
                        gas_srmc * wv_frac * (water_value_base + water_value_span * norm_demand)
                    else
                        gas_srmc * (1.0 + water_value_dry_boost * hydro_dryness) *
                        (water_value_base + water_value_span * norm_demand)
                    end
                    # cv27 T2 (spill-risk, prereg-frozen): in surplus regimes
                    # (reservoirs full per the profile gate) stored water faces
                    # spill risk and sellers chase the within-day net-demand
                    # valley instead of holding the level — the offer scales
                    # with the demand position below the day's midpoint,
                    # toward 0 at the trough. Never negative here (T3's job).
                    # NOT shipped with cv27 (measured mild-positive but not part of
                    # the shipped border combo): explicit opt-in only.
                    if profile.spill_surplus_dryness > 0.0 &&
                       hydro_dryness < profile.spill_surplus_dryness &&
                       norm_demand < 0.5 &&
                       !isempty(get(ENV, "EUPHEMIA_ENABLE_CV27_T2", ""))
                        water_value *= norm_demand / 0.5
                    end
                    # Solar-regime full-blocks: run-of-river joins the floor in
                    # regime hours (price-taker, curtailment-avoidance economics).
                    if sr_full && sr_active(hr) &&
                       g.fuel_type == Symbol("Hydro Run-of-river and pondage")
                        water_value = sr_floor(hr)
                    end
                    push_tagged!(SimpleOrder(:supply, water_value, offered_pmax(g),
                        Symbol(bidding_zone), date_time, resolution_minutes),
                        g.code, wv_strategy)
                    supply_orders_count += 1
                    total_supply_capacity += offered_pmax(g)
                else
                    # :nuclear opportunity anchor (two-pass, pass 2): nuclear's
                    # effective bid base per slot is the export opportunity —
                    # anchor_share × the pass-1 coupled reference price —
                    # floored at fuel SRMC. It rises with the coupled price on
                    # weekday nights and COLLAPSES with it in RES-surplus hours
                    # (weekends/midday), which a static floor cannot do.
                    # Everywhere else gmc ≡ g.marginal_cost.
                    gmc = (anchor_active && opportunity_anchor == :nuclear &&
                           g.fuel_type == Symbol("Nuclear") &&
                           haskey(anchor_prices, ts)) ?
                          max(g.marginal_cost, eff_nuclear_share * anchor_prices[ts]) :
                          g.marginal_cost
                    # cv23 FR-cap ceiling: bound anchor-lifted nuclear supply
                    # prices (must-run second block + tranches, after the
                    # scarcity/peak markup) to a modest markup over the coupled
                    # reference, so the upper-tranche markup cannot amplify the
                    # anchor base into the footprint-wide cap on crisis-tight
                    # winter days. Inf (no clamp) unless the profile opts in AND
                    # this is anchor-lifted nuclear (docs/experiments/cv23-fr-cap.md).
                    nuc_ceil = (profile.nuclear_bid_ref_ceiling > 0.0 && anchor_active &&
                                opportunity_anchor == :nuclear &&
                                g.fuel_type == Symbol("Nuclear") &&
                                haskey(anchor_prices, ts)) ?
                               profile.nuclear_bid_ref_ceiling * anchor_prices[ts] : Inf
                    # Must-run self-scheduling: baseload-ish units (SRMC not
                    # far above gas) bid their minimum-load block near zero —
                    # shutting down and restarting costs more than running a
                    # few hours below cost. This is what lets midday prices
                    # collapse below thermal SRMC in renewable-surplus hours.
                    must_run_qty = 0.0
                    if g.code in committed
                        must_run_qty = min(g.p_min, offered_pmax(g))
                        # Graduated self-scheduling: the deepest block is
                        # near-free (never shut down), the rest bids below
                        # cost — real curves are convex, not a cliff. The
                        # below-cost discount is ABSOLUTE (startup-cost
                        # amortization is €/MWh over the p_min hours, not a
                        # fraction of fuel cost): a proportional 0.5×SRMC
                        # discount is benign at gas ≈ 90 (−45) but capped
                        # crisis evenings at half the real gas cost
                        # (−212 at TTF 218, 2022) and sank the whole year.
                        deep_qty = must_run_qty * 0.6
                        # cv27 T3 (prereg-frozen): the deepest block prices at
                        # the declared negative floor — curtailment-avoidance /
                        # support-scheme economics let midday surplus clear
                        # below zero, which the >= 0 near-free price never can.
                        # NOT shipped with cv27 (cv28/cv29 measured the floor family
                        # NO-SHIP): explicit opt-in only.
                        deep_price = (!isempty(get(ENV, "EUPHEMIA_ENABLE_CV27_T3", "")) ||
                                      (sr_full && sr_active(hr))) ?
                            (sr_active(hr) ? sr_floor(hr) : DEEP_SURPLUS_FLOOR_EUR) :
                            gmc * must_run_price_factor
                        push_tagged!(SimpleOrder(:supply,
                            deep_price, deep_qty,
                            Symbol(bidding_zone), date_time, resolution_minutes),
                            g.code, "must_run_deep")
                        push_tagged!(SimpleOrder(:supply,
                            min(max(gmc * 0.5, gmc - 40.0), nuc_ceil),
                            must_run_qty - deep_qty,
                            Symbol(bidding_zone), date_time, resolution_minutes),
                            g.code, "must_run_rest")
                        supply_orders_count += 2
                        total_supply_capacity += must_run_qty
                    end

                    # Remaining capacity: tranche ladder on SRMC, scarcity
                    # markup on the upper tranches (first tranche stays at
                    # cost so mid-merit keeps clearing)
                    flexible_capacity = max(offered_pmax(g) - must_run_qty, 0.0)
                    for (i, (share, mult)) in enumerate(tranches)
                        price = min(gmc * mult * (i == 1 ? 1.0 : scarcity), nuc_ceil)
                        qty = flexible_capacity * share
                        qty < 0.1 && continue
                        push_tagged!(SimpleOrder(:supply, price, qty,
                            Symbol(bidding_zone), date_time, resolution_minutes),
                            g.code, i == 1 ? "srmc_base" : "peak_tranche_$i")
                        supply_orders_count += 1
                        total_supply_capacity += qty
                    end
                end
            end
        end

        # ── Stage 6c: valley-continuation re-pricing (GRSQ lever 2) ─────
        # For each qualifying (unit, valley hour): the unit's cheapest
        # committed MW move to the declared floor, replacing their SRMC/
        # discount price for that quantity ONLY (MW conserved — re-pricing,
        # never new capacity). Orders partially covered are split; the floor
        # part carries strategy "valley_continuation".
        if grsq2_on && !isempty(grsq2_commits)
            byunit = Dict{Tuple{String,DateTime},Vector{Int}}()
            for (i, (o, tag)) in enumerate(tagged)
                o.type == :supply || continue
                haskey(grsq2_commits, tag) || continue
                grsq2_slot(o.date_time) || continue
                push!(get!(byunit, (tag, o.date_time), Int[]), i)
            end
            n_repriced = 0
            for ((code, dt), idxs) in byunit
                want = grsq2_commits[code]
                sort!(idxs, by=i -> tagged[i][1].price)
                for i in idxs
                    want <= 1e-9 && break
                    o, tag = tagged[i]
                    if o.price <= DEEP_SURPLUS_FLOOR_EUR
                        want -= o.quantity
                        continue
                    end
                    take = min(want, o.quantity)
                    if take >= o.quantity - 1e-9
                        tagged[i] = (SimpleOrder(o.type, DEEP_SURPLUS_FLOOR_EUR,
                                                 o.quantity, o.zone, o.date_time,
                                                 o.resolution_code), tag)
                        strategies[i] = "valley_continuation"
                    else
                        tagged[i] = (SimpleOrder(o.type, o.price, o.quantity - take,
                                                 o.zone, o.date_time,
                                                 o.resolution_code), tag)
                        push!(tagged, (SimpleOrder(o.type, DEEP_SURPLUS_FLOOR_EUR,
                                                   take, o.zone, o.date_time,
                                                   o.resolution_code), tag))
                        push!(strategies, "valley_continuation")
                        supply_orders_count += 1
                    end
                    want -= take
                    n_repriced += 1
                end
            end
            n_repriced > 0 &&
                println("   🌅 GRSQ T2: $n_repriced valley tranche(s) repriced to the floor " *
                        "($(length(grsq2_commits)) overnight runner(s))")
        end

        # ── Stage 7-pre: cv34 T3 — surplus pumping demand (opt-in) ──────
        # Prereg: elastic DEMAND up to the zone's demonstrated pumping
        # capability in regime hours (share >= zone θ), priced at
        # η × (pass-1 estimate of the same day's evening value) — the owner's
        # mechanism. Needs pass1_prices (pass-2 only); EUPHEMIA_CV34_PUMP_ZONES
        # empty/unset ⇒ fully inert. η via EUPHEMIA_CV34_PUMP_ETA (0.7).
        t3_pump_zones = strip.(split(get(ENV, "EUPHEMIA_CV34_PUMP_ZONES", ""), ","))
        if bidding_zone in t3_pump_zones && pass1_prices !== nothing &&
           !isempty(pass1_prices)
            pump_head = try
                _pump_capability(bidding_zone, day)
            catch e
                @warn "cv34 T3: capability query failed — inert for $bidding_zone $day" exception=e
                Dict{Int,Float64}()
            end
            if !isempty(pump_head) && maximum(values(pump_head)) > 10.0
                eta = parse(Float64, get(ENV, "EUPHEMIA_CV34_PUMP_ETA", "0.7"))
                pump_price = max(eta * maximum(values(pass1_prices)), 0.0)
                # regime share per hour (same construction as the cv31 gate,
                # computed here because pump zones need not be floor zones)
                psol = Dict{Int,Vector{Float64}}(); pld = Dict{Int,Vector{Float64}}()
                for r in renewables
                    r.production_type == "Solar" || continue
                    length(r.date_time) >= 11 || continue
                    push!(get!(psol, parse(Int, r.date_time[10:11]), Float64[]),
                          r.aggregated_generation_forecast)
                end
                for (ts, v) in load_by_time
                    length(ts) >= 11 || continue
                    push!(get!(pld, parse(Int, ts[10:11]), Float64[]), v)
                end
                n_pump = 0
                for ts in target_timeslots
                    hr = parse(Int, ts[10:11])
                    sv = get(psol, hr, Float64[]); lv = get(pld, hr, Float64[])
                    (isempty(sv) || isempty(lv)) && continue
                    share = (sum(sv) / length(sv)) / max(sum(lv) / length(lv), 1.0)
                    share >= sr_theta || continue
                    pmw = get(pump_head, hr, 0.0)
                    pmw > 10.0 || continue
                    dtp = parse_timeslot_to_datetime(ts, day)
                    push_tagged!(SimpleOrder(:demand, pump_price, pmw,
                        Symbol(bidding_zone), dtp, resolution_minutes),
                        "PUMP", "pump_absorption")
                    demand_orders_count += 1
                    total_demand_quantity += pmw
                    n_pump += 1
                end
                n_pump > 0 &&
                    println("   ⛲ cv34 T3: $n_pump incremental pumping slot(s) at " *
                            "$(round(pump_price, digits=1)) €/MWh (headroom basis)")
            end
        end

        # ── Stage 7: demand orders ──────────────────────────────────────
        # Demand: inelastic tranche at the cap + small price-sensitive tail
        for ts in target_timeslots
            date_time = parse_timeslot_to_datetime(ts, day)
            gd = gross_demand[ts]

            inelastic_qty = gd * (1.0 - demand_elastic_share)
            push_tagged!(SimpleOrder(:demand, price_cap, inelastic_qty,
                Symbol(bidding_zone), date_time, resolution_minutes),
                "DEMAND", "demand_firm")
            demand_orders_count += 1

            elastic_qty = gd * demand_elastic_share
            if elastic_qty > 0.1
                push_tagged!(SimpleOrder(:demand, demand_elastic_price, elastic_qty,
                    Symbol(bidding_zone), date_time, resolution_minutes),
                    "DEMAND", "demand_elastic")
                demand_orders_count += 1
            end
            total_demand_quantity += gd
        end

        # ── Stage 7b: cv21 boundary counterparty ladder ─────────────────
        # The elastic out-of-footprint neighbor on one border (DK1↔GB Viking
        # Link) — import supply + export demand anchored on the NEIGHBOR's own
        # fundamental SRMC over the border's demonstrated capability. Replaces
        # the fixed GB flow injection (removed from net imports above) and its
        # backstop headroom. Inert (nothing) for every zone but DK1 ⇒ the book
        # is byte-identical. Requires flow injections (include_net_imports) —
        # the ladder is the injection's elastic replacement.
        if boundary_book !== nothing && include_net_imports
            b_orders = get_boundary_orders(boundary_book, bidding_zone, day,
                target_timeslots, resolution_minutes, price_cap)
            btag = "BOUNDARY:" * boundary_book.counterparty
            for o in b_orders
                if o.type == :supply
                    push_tagged!(o, btag, "boundary_import")
                    supply_orders_count += 1
                    total_supply_capacity += o.quantity
                else
                    push_tagged!(o, btag, "boundary_export")
                    demand_orders_count += 1
                    total_demand_quantity += o.quantity
                end
            end
            isempty(b_orders) ||
                println("  🌐 Boundary book ($(boundary_book.counterparty)): " *
                        "$(length(b_orders)) orders over $(length(target_timeslots)) slots")
        end

        # ── Stage 8: scenario hooks (extra_orders, strategist) ──────────
        # Feature 3/4: extra scenario orders appended after all standard
        # orders and BEFORE merging. Both :supply and :demand are allowed.
        if extra_orders !== nothing
            ctx = (zone=bidding_zone, day=day, timeslots=target_timeslots,
                   resolution_minutes=resolution_minutes,
                   load_by_time=load_by_time, renewable_by_time=renewable_by_time)
            for o in extra_orders(ctx)
                push_tagged!(o, "EXTRA", "extra")
                if o.type == :supply
                    supply_orders_count += 1
                    total_supply_capacity += o.quantity
                else
                    demand_orders_count += 1
                    total_demand_quantity += o.quantity
                end
            end
        end

        # Feature 5: strategist hook, called after extra_orders and before
        # merging. It receives the full tagged order list plus a unit→firm
        # map and RETURNS the replacement tagged list.
        if strategist !== nothing
            firm_of = get_firm_of(bidding_zone)
            sctx = (tagged_orders=tagged, zone=bidding_zone, day=day,
                    timeslots=target_timeslots, load_by_time=load_by_time,
                    renewable_by_time=renewable_by_time, firm_of=firm_of)
            result = strategist(sctx)
            # Accept either Vector{Tuple{SimpleOrder,String}} or a plain
            # Vector{SimpleOrder} (re-tagged "STRATEGIST").
            tagged = Tuple{SimpleOrder,String}[
                x isa Tuple ? (x[1], x[2]) : (x, "STRATEGIST") for x in result]
            # The strategist REPLACES the ladder, so the source strategy labels no
            # longer map; the whole replacement set is labelled "strategist"
            # (scenario path — not the capture/backfill path).
            strategies = fill("strategist", length(tagged))
            # Recount from the replacement set so summary stats stay accurate
            supply_orders_count = count(t -> t[1].type == :supply, tagged)
            demand_orders_count = count(t -> t[1].type == :demand, tagged)
            total_supply_capacity = sum((t[1].quantity for t in tagged if t[1].type == :supply); init=0.0)
            total_demand_quantity = sum((t[1].quantity for t in tagged if t[1].type == :demand); init=0.0)
        end

        # Optional book sink (default nothing = byte-identical no-op): a
        # callback receiving the FULL tagged order list right before merging —
        # the same view the strategist hook gets. Used by the book-export
        # feature to persist per-owner bid ladders for analysis/transparency;
        # in two-pass clears the harness overwrites per (zone, day), so the
        # final (pass-2) book wins. Errors in the sink must never break a
        # clear — swallowed with a warning.
        if BOOK_SINK[] !== nothing
            try
                # 5th positional arg = the PARALLEL strategy labels (strategies[i]
                # is tagged[i]'s WHY). Sinks are updated in lockstep; a legacy
                # 4-arg sink would error here and be caught below (book still
                # clears) — so capture degrades safely, never a broken clear.
                BOOK_SINK[](bidding_zone, day, tagged, resolution_minutes, strategies)
            catch e
                @warn "BOOK_SINK failed (book still cleared)" zone = bidding_zone day error = sprint(showerror, e)
            end
        end

        orders = SimpleOrder[t[1] for t in tagged]

        # ── Stage 9: merge identical blocks + assemble the MPCC book ────
        # Merge orders with identical (type, price, timeslot): all units of a
        # fuel type bid the same SRMC-derived tranche prices, so a zone-day
        # book collapses ~6x with market-equivalent clearing (partial
        # acceptance of a merged block ≡ distributing it among the
        # identically-priced originals). This directly cuts the MPCC binary
        # count, which is what limits multi-zone solve times.
        merged = Dict{Tuple{Symbol,Float64,DateTime},Float64}()
        for o in orders
            key = (o.type, round(o.price, digits=2), o.date_time)
            merged[key] = get(merged, key, 0.0) + o.quantity
        end
        pre_merge_count = length(orders)
        orders = [SimpleOrder(t, p, q, Symbol(bidding_zone), dt, resolution_minutes)
                  for ((t, p, dt), q) in merged]
        println("  🔗 Merged $(pre_merge_count) orders into $(length(orders)) price-distinct blocks")

        nodes = [bidding_zone]
        # EU day-ahead floor is -500; ceiling is the demand cap so shortage
        # hours can price exactly at the cap
        price_limits = (-500.0, price_cap)
        order_book = MPCCOrderBook(orders, nodes, target_timeslots, price_limits, nothing)

        supply_per_slot = total_supply_capacity / length(target_timeslots)
        demand_per_slot = total_demand_quantity / length(target_timeslots)
        ratio = demand_per_slot > 0 ? supply_per_slot / demand_per_slot : 0.0

        println("  ✅ Merit-order book: $supply_orders_count supply / $demand_orders_count demand orders")
        println("     ⚖️  Supply/Demand ratio: $(round(ratio, digits=2))  (gas SRMC €$(round(gas_srmc, digits=1))/MWh)")

        return AdjustedOrderBookResult(
            true, "Merit-order book created successfully", order_book,
            length(generators), demand_orders_count, supply_orders_count,
            total_demand_quantity, total_supply_capacity, ratio)

    catch e
        e isa InterruptException && rethrow()
        error_msg = "Error creating merit-order book: $(sprint(showerror, e))"
        println("  ❌ $error_msg")
        return AdjustedOrderBookResult(false, error_msg, nothing, 0, 0, 0, 0.0, 0.0, 0.0)
    end
end
