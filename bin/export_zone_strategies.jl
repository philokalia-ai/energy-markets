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
# Output: $WEB_PARQUET_OUT/v1/zone_strategies.json (default <repo>/data/web/v1),
# i.e. the same staging root bin/web_data_push.sh uploads.

using Euphemia, JSON, Dates
const MO = Euphemia.MeritOrderBook

const OUT_ROOT = get(ENV, "WEB_PARQUET_OUT", joinpath(dirname(@__DIR__), "data", "web"))
const V1_DIR = joinpath(OUT_ROOT, "v1")

const FOOTPRINT = ["AT","BE","BG","CZ","DE_LU","DK1","DK2","EE","ES","FI","FR","GR","HU",
                   "LT","LV","NL","NO1","NO2","NO3","NO4","NO5","PL","PT","RO","RS",
                   "SE1","SE2","SE3","SE4","SI","SK","IT-NORTH","IT-CNORTH","IT-CSOUTH",
                   "IT-SOUTH","IT-Calabria","IT-Sicily","IT-Sardinia","CH"]

_jsonable(v) = v isa MO.BoundaryBook ? "boundary book: $(v.counterparty)" :
               v isa Symbol ? String(v) :
               v isa Tuple ? collect(v) :
               v isa Vector{<:Tuple} ? [collect(t) for t in v] :
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

"Group the zones by identical parameter vector — the real number of treatments."
function treatment_groups(flds, rows)
    sig(r) = [string(r["values"][String(f)]) for f in flds]
    groups = Dict{Vector{String},Vector{String}}()
    for r in rows
        push!(get!(groups, sig(r), String[]), r["zone"])
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
        Dict("mechanism" => "Border drops (flow-based)",
             "where" => "the enriched network build, not the profile",
             "note" => "Core-FBMC and other borders whose offered ATC misrepresents " *
                       "the real constraint are dropped per zone pair; two zones can " *
                       "share a profile and still be treated differently because of this."),
        Dict("mechanism" => "Continental anchor proxy",
             "where" => "hardcoded (\"DE_LU\", \"NL\") in compute_opportunity_anchor_refs",
             "note" => "Every :hydro/:nuclear anchored zone with no endogenous neighbour " *
                       "falls back to the DE_LU/NL average — a shared reference no column shows."),
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
        "base_profile" => "SEE_PROFILE",
        "n_zones" => length(rows),
        "n_distinct_treatments" => length(groups),
        "kill_switches_set" => switches,
        "treatments" => groups,
        "zones" => rows,
        "strategy_outside_the_profile" => out_of_struct(),
    )
    mkpath(V1_DIR)
    out = joinpath(V1_DIR, "zone_strategies.json")
    open(out, "w") do io
        JSON.print(io, payload, 2)
    end
    println("✅ $(length(rows)) zones, $(length(groups)) distinct treatments, " *
            "$(length(flds)) profile fields → $out")
    isempty(switches) || @warn "kill-switches were set — the table reflects a NON-production profile" switches
end

main()
