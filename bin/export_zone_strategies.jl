#!/usr/bin/env julia
#
# Export the zone-strategy table — GENERATED FROM THE RUNNING CODE.
#
# The published table at energy.philokalia.ai/about is not a rendering of the
# calibration, it IS the calibration: one row per zone, columns being the discrete
# treatments a zone's bid carries. This script resolves `get_zone_profile` for the
# footprint and emits that table as JSON, so the page can never drift from the
# model. A hand-maintained calibration table was measured to be wrong within one
# iteration (docs/calibration-atlas.md listed RO/RS/HU/SI as plain SEE_PROFILE and
# had no row at all for the import-backed treatment), and a wrong table that is
# also the design spec is worse than no table.
#
# HONESTY: some strategy does NOT live in the profile struct — env-gated rewrites
# inside `get_zone_profile`, the hardcoded continental anchor proxy, and the
# network build's border drops. Those are emitted as their own section rather than
# omitted, so the page is not a partial truth.
#
# Output: $ZONE_STRATEGIES_OUT (default <repo>/data/calibration/zone_strategies.json).
#
# DELIBERATELY NOT under data/web/v1: bin/web_data_push.sh does
# `aws s3 sync --delete $STAGING/v1 -> s3://$BUCKET/v1` over EVERYTHING in that
# tree, so a file staged there publishes itself on the next routine data push.
# Putting the calibration on a public site is a transparency decision; it must
# take an explicit act, not a side effect of an unrelated push.

using Euphemia, JSON, Dates
const MO = Euphemia.MeritOrderBook

const OUT_PATH = get(ENV, "ZONE_STRATEGIES_OUT",
    joinpath(dirname(@__DIR__), "data", "calibration", "zone_strategies.json"))

# The ONE footprint list, not a sixth hand-kept copy — a footprint change (the
# parked 43-zone iteration) would otherwise silently make this "cannot drift"
# table wrong.
include(joinpath(@__DIR__, "forecast_common.jl"))
const FOOTPRINT = FORECAST_FOOTPRINT

# A BoundaryBook is a struct, so emit its fields. Collapsing it to
# "boundary book: GB" made FR's GB_FR_BOOK (UKA carbon, 4-code net exclusion,
# per-cable ATC) and DK1's VIKING_GB_BOOK (EUA, one code) render identically —
# materially different calibrations shown as equal, in a table whose whole claim
# is that it IS the calibration.
_jsonable(v) =
    v isa MO.BoundaryBook ?
        Dict{String,Any}(String(f) => _jsonable(getfield(v, f))
                         for f in fieldnames(MO.BoundaryBook)) :
    v isa Symbol ? String(v) :
    v isa Tuple ? collect(v) :
    v isa Vector{<:Tuple} ? [collect(t) for t in v] :
    v isa AbstractVector ? [_jsonable(x) for x in v] :
    v === nothing ? nothing : v

"Per-zone resolved profile, plus the base profile every row is a delta against."
function zone_rows()
    flds = collect(fieldnames(MO.ZoneProfile))
    base = MO.SEE_PROFILE
    rows = Vector{Any}()
    for z in FOOTPRINT
        p = MO.get_zone_profile(z)
        vals = Dict{String,Any}()
        diffs = String[]
        for f in flds
            v = getfield(p, f)
            vals[String(f)] = _jsonable(v)
            getfield(base, f) == v || push!(diffs, String(f))
        end
        push!(rows, Dict("zone" => z, "values" => vals, "differs_from_base" => diffs))
    end
    return flds, rows
end

"""
Group the zones by identical parameter vector — the real number of treatments.

Grouping is on the RESOLVED PROFILE ITSELF, not on the emitted JSON: grouping by a
stringified projection would silently merge two distinct treatments the day their
other fields converge (the boundary-book collapse above was exactly that hazard).
"""
function treatment_groups(flds, rows)
    groups = Dict{MO.ZoneProfile,Vector{String}}()
    for r in rows
        push!(get!(groups, MO.get_zone_profile(r["zone"]), String[]), r["zone"])
    end
    return [Dict("zones" => sort(zs), "n" => length(zs))
            for (_, zs) in sort(collect(groups); by = x -> (-length(x[2]), first(sort(x[2]))))]
end

"""
Strategy that is NOT a profile field. Emitted so the page does not present a
partial truth: a reader comparing the table with the model must be able to see
these too.
"""
function out_of_struct()
    return [
        Dict("mechanism" => "The table is scoped to the EU-footprint product",
             "where" => "enrich_network && apply_zone_profiles, in multi_zone_books.jl",
             "note" => "Profiles apply ONLY on the coupled 39-zone path. The legacy " *
                       "single-zone and 5-zone SEE products force SEE_PROFILE, so for " *
                       "those the table below does not describe what was cleared."),
        Dict("mechanism" => "FLEET_TRUTH_OVERRIDE (per day, all zones)",
             "where" => "multi_zone_run.jl's robustness fallback",
             "note" => "When a day's coupled clear stays infeasible through the whole " *
                       "retry ladder, EVERY zone's fleet_truth_mode is forced to :p95 " *
                       "for that day and the day ships. So a published day can have " *
                       "been cleared with a different value of a column below."),
        Dict("mechanism" => "Border drops (flow-based)",
             "where" => "the enriched network build, not the profile",
             "note" => "Core-FBMC and other borders whose offered ATC misrepresents " *
                       "the real constraint are dropped per zone pair; two zones can " *
                       "share a profile and still be treated differently because of this."),
        Dict("mechanism" => "Continental anchor proxy",
             "where" => "hardcoded (\"DE_LU\", \"NL\") in compute_opportunity_anchor_refs",
             "note" => "Every :hydro/:nuclear anchored zone with no endogenous neighbour " *
                       "falls back to the DE_LU/NL average — a shared reference no column shows."),
        Dict("mechanism" => "Other zone-name-keyed treatment in the flow layer",
             "where" => "flows_imports.jl (NORDIC_FLOW_ZONES D-7 recency) and the " *
                        "aggregate-border remap",
             "note" => "The ex-ante flow rule treats the Nordic zones differently, and " *
                       "aggregate ENTSO-E border codes are remapped to a representative " *
                       "zone. Neither is a profile field."),
        Dict("mechanism" => "Env-gated version switches",
             "where" => "get_zone_profile (EUPHEMIA_DISABLE_CV21/22/23/FRCAP)",
             "note" => "Set in A/B and byte-identity runs; unset in production. When set " *
                       "they rewrite the profile AFTER the registry, so the table below " *
                       "reflects the environment it was generated in."),
    ]
end

function main()
    flds, rows = zone_rows()
    groups = treatment_groups(flds, rows)
    switches = [k for k in ("EUPHEMIA_DISABLE_CV21", "EUPHEMIA_DISABLE_CV22",
                            "EUPHEMIA_DISABLE_CV23", "EUPHEMIA_DISABLE_FRCAP")
                if !isempty(get(ENV, k, ""))]
    payload = Dict(
        "generated_utc" => string(Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SS"), "Z"),
        "code_version" => Euphemia.ENERGY_PRICES_CODE_VERSION,
        "generated_from" => "get_zone_profile resolved in-process — never hand-maintained",
        "fields" => String.(flds),
        "field_descriptions" => Dict(String(f) => get(MO.FIELD_DESCRIPTIONS, f, "") for f in flds),
        "source_of_truth" => "src/merit_order/zone_profiles.jl",
        "base_profile" => "SEE_PROFILE",  # the row every diff is against
        "n_zones" => length(rows),
        "n_distinct_treatments" => length(groups),
        "kill_switches_set" => switches,
        "treatments" => groups,
        "zones" => rows,
        "strategy_outside_the_profile" => out_of_struct(),
    )
    mkpath(dirname(OUT_PATH))
    out = OUT_PATH
    open(out, "w") do io
        JSON.print(io, payload, 2)
    end
    println("✅ $(length(rows)) zones, $(length(groups)) distinct treatments, " *
            "$(length(flds)) profile fields → $out")
    isempty(switches) || @warn "kill-switches were set — the table reflects a NON-production profile" switches
end

main()
