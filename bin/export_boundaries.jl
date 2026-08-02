#!/usr/bin/env julia
#
# Export the boundary-zones object — the ELASTIC structural fields GENERATED FROM
# THE RUNNING CODE, merged with the ONE curated-but-cited input file.
#
# Pillar 6 (docs/pillars/pillar-6-boundaries-plan.md) teaches how the model treats
# the world OUTSIDE the 39-zone footprint: two things, made legible and honest.
#   - ELASTIC counterparty books (GB on two borders, UA on four): promoted to
#     bidding participants with their own ladder, anchored on their OWN fundamental
#     cost, sized by the border's demonstrated capability.
#   - FIXED injections (TR/AL/MK + the unnamed rest): price-taker observed
#     schedules, lagged ex-ante, that do not respond to price.
#
# This mirrors bin/export_zone_strategies.jl / bin/export_book_methodology.jl in
# every respect:
#   - the elastic section is WALKED from ZONE_PROFILES's `BoundaryBook` structs
#     (never hand-kept — a boundary-book change is reflected automatically);
#   - the FROZEN measured confirm numbers, the FIXED-neighbour list (TR/AL/MK carry
#     no struct — they are simply never in the footprint), and the flow-rule
#     descriptor are READ from the committed, cited docs/pillars/boundary-effects.json
#     (historical experiment OUTCOMES, the one admissible hand-entry, exactly like
#     docs/pillars/cv-ledger.json for pillar 5);
#   - it writes by default OUTSIDE data/web/v1 (to data/calibration/boundaries.json),
#     so publishing it is an EXPLICIT act, not a side effect of an unrelated
#     web_data_push.sh run;
#   - a sibling guard test (test_boundaries_export.jl) asserts every effect key is
#     realised by a struct and every cited cv is within the code version.
#
# Output: $BOUNDARIES_OUT (default <repo>/data/calibration/boundaries.json).

using Euphemia, JSON, Dates
const MO = Euphemia.MeritOrderBook

const OUT_PATH = get(ENV, "BOUNDARIES_OUT",
    joinpath(dirname(@__DIR__), "data", "calibration", "boundaries.json"))
const EFFECTS_PATH =
    joinpath(dirname(@__DIR__), "docs", "pillars", "boundary-effects.json")

# The ONE footprint list, not a sixth hand-kept copy (same reasoning as
# export_zone_strategies.jl).
include(joinpath(@__DIR__, "forecast_common.jl"))
const FOOTPRINT = FORECAST_FOOTPRINT

_pairs(v) = [collect(t) for t in v]   # Vector{Tuple} -> [[mult, share], ...]

# Resolve a BoundaryBook object back to its const NAME, so effects (keyed by name)
# attach unambiguously and FR's GB_FR_BOOK never collapses into DK1's VIKING_GB_BOOK
# (materially different calibrations — UKA vs EUA carbon, 4-code net exclusion,
# per-cable ATC). Identity is by struct value equality against the module consts.
function book_name(b::MO.BoundaryBook)
    b == MO.VIKING_GB_BOOK && return "VIKING_GB_BOOK"
    b == MO.GB_FR_BOOK && return "GB_FR_BOOK"
    (b == MO.UA_BOOK_DEFAULT || b == MO.UA_BOOK_PL) && return "UA_BOOK"
    return "UNKNOWN_BOOK"   # a new book without a name mapping — the guard test fails
end

"""
Walk ZONE_PROFILES for every non-`nothing` boundary book, group the border zones
by book, and emit one GENERATED structural record per distinct book. Every field
is read off the struct — no boundary number is transcribed here.
"""
function elastic_books(effects)
    # book object -> sorted border zones it is carried on
    borders = Dict{MO.BoundaryBook,Vector{String}}()
    for z in FOOTPRINT
        p = MO.get_zone_profile(z)
        b = p.boundary_book
        b === nothing && continue
        push!(get!(borders, b, String[]), z)
    end

    recs = Vector{Any}()
    for (b, zs) in borders
        name = book_name(b)
        rec = Dict{String,Any}(
            "book" => name,
            "counterparty" => b.counterparty,
            "borders" => sort(zs),
            "flow_codes" => b.flow_codes,
            "net_exclude_codes" => MO.boundary_net_exclude(b),
            "atc_codes" => MO.boundary_atc_codes(b),
            "anchor" => String(b.anchor),
            "carbon_source" => String(b.carbon_source),
            "anchor_mult" => b.anchor_mult,
            "efficiency" => MO.GB_CCGT_EFFICIENCY,
            "capability_mode" => String(b.capability_mode),
            "imp_ladder" => _pairs(b.imp_ladder),
            "exp_ladder" => _pairs(b.exp_ladder),
            "firm_slice" => b.firm_slice,
            "firm_price" => b.firm_price,
            "firm_window_days" => b.firm_window_days,
            "firm_quantile" => b.firm_quantile,
            "disable_env" => b.disable_env,
            # The double-count-fix flag is a structural property of the book: it
            # excludes MORE codes than it sizes ATC on (FR's four vs one).
            "double_count_fix" => length(MO.boundary_net_exclude(b)) > length(b.flow_codes),
            # KIND is the load-bearing pillar-6 distinction, stated on every record.
            "kind" => "elastic",
            "anchor_declared" =>
                b.anchor === :gb_ccgt_srmc ? "defensible (GB CCGT SRMC from TTF + UK/EU carbon)" :
                b.anchor === :zone_gas_srmc ? "generic — no counterparty feed; the firm slice carries the book" :
                String(b.anchor),
        )
        rec["effect"] = get(effects, name, nothing)
        push!(recs, rec)
    end
    # Stable order: elastic-by-counterparty then book name.
    sort!(recs; by = r -> (r["counterparty"], r["book"]))
    return recs
end

"""
The FIXED out-of-footprint neighbours (TR/AL/MK ...). They carry NO struct in
ZONE_PROFILES (a fixed injection is data, not a model), so the list is READ from
the cited file — but each entry is cross-checked against the real network
neighbour set in the guard test, so it cannot drift into fiction.
"""
function fixed_neighbours(doc)
    fixed = get(doc, "fixed", Any[])
    for f in fixed
        f["kind"] = "fixed"
        f["anchor"] = nothing            # the blank IS the point
        f["capability_mode"] = nothing
    end
    return fixed
end

function main()
    isfile(EFFECTS_PATH) ||
        error("boundary-effects.json not found at $EFFECTS_PATH")
    doc = JSON.parsefile(EFFECTS_PATH)
    effects = get(doc, "effects", Dict{String,Any}())

    elastic = elastic_books(effects)
    fixed = fixed_neighbours(doc)

    # D4 (plan open decision): the neighbour count is COMPUTED here, never typed on
    # the surface. Named counterparties = distinct elastic + fixed counterparties.
    named = Set{String}()
    for r in elastic
        push!(named, r["counterparty"])
    end
    for f in fixed
        push!(named, f["counterparty"])
    end

    payload = Dict{String,Any}(
        "generated_utc" => string(Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SS"), "Z"),
        "code_version" => Euphemia.ENERGY_PRICES_CODE_VERSION,
        "generated_from" => "ZONE_PROFILES BoundaryBook structs, resolved in-process; measured effects + fixed list read from docs/pillars/boundary-effects.json (cited)",
        "source_of_truth" => Dict{String,Any}(
            "elastic_structure" => "src/merit_order/zone_profiles.jl (BoundaryBook + the book consts)",
            "ladders_capability" => "src/merit_order/boundary.jl",
            "flows" => "src/merit_order/flows_imports.jl (get_net_imports, :v3)",
            "how_it_enters" => "src/merit_order/book_build.jl (Stage 7b)",
            "effects_and_fixed_list" => "docs/pillars/boundary-effects.json (curated, cited)",
        ),
        "n_named_neighbours" => length(named),
        "n_elastic_books" => length(elastic),
        "n_fixed_neighbours" => length(fixed),
        "flow_rule" => get(doc, "flow_rule", nothing),
        "elastic" => elastic,
        "fixed" => fixed,
    )

    mkpath(dirname(OUT_PATH))
    open(OUT_PATH, "w") do io
        JSON.print(io, payload, 2)
    end
    println("✅ boundaries → $OUT_PATH")
    println("   $(length(elastic)) elastic books · $(length(fixed)) fixed neighbours · " *
            "$(length(named)) named counterparties · flow default " *
            "$(get(get(doc, "flow_rule", Dict()), "footprint_default", "?"))")
end

main()
