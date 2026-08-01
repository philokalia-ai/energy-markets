#!/usr/bin/env julia
#
# Export a small STATIC unit-reference table for the SPA's Order-book view:
#
#   v1/units.parquet   one row per (zone, generation_unit_code):
#                      code  VARCHAR   ENTSO-E generation_unit_code (the book's
#                                      `owner` tag for unit orders)
#                      display_name VARCHAR  generation_unit_name (human name)
#                      fuel  VARCHAR   canonical ENTSO-E fuel type AFTER the
#                                      same name-inference get_generators applies
#                                      (e.g. "Fossil Gas", "Hydro Water Reservoir",
#                                      BESS-in-name "Other" -> "Energy storage")
#                      firm  VARCHAR   operator/firm from simulations.unit_firms
#                                      (nullable; "unknown" is normalized to null)
#                      zone  VARCHAR   bidding zone (area_map_code)
#
# The book parquet rows carry `owner = generation_unit_code` (or the RES/IMPORT/
# DEMAND/BACKSTOP tags, and AGG-<zone>-<Fuel> fleet-completion aggregates). This
# file lets the SPA join a unit code -> {name, fuel, firm} entirely client-side,
# so the order-book slices can be coloured by FUEL TYPE and labelled with the
# firm + a fuel icon + the readable unit name instead of the raw code.
#
# ADDITIVE v1 contract: a new file at the v1/ root; no existing object changes.
# bin/web_data_push.sh already uploads every v1/*.parquet at the root (additive
# cp, NOT in the destructive `sync --delete` scope), so no push-script change is
# needed. The Cloudflare Worker (workers/api/) re-emits it at /api/v1/units.
#
# The fuel TAXONOMY (icon + colour + family per fuel string) lives in the SPA
# (web/app.js), in one place; this file stays faithful to the registry so the
# display mapping can evolve without a re-export.
#
# Registry source & dedup mirror src/generators/registry.jl get_generators: we
# take COMMISSIONED generation units in BZN / BZN/CTA areas, deduplicated by
# generation_unit_code with DISTINCT ON (most recent valid_from, then largest
# capacity) — the same dedup that resolves ENTSO-E's overlapping validity rows.
# Unlike get_generators this is a per-code static reference (no day / outage /
# capacity), so it covers every unit that can appear as a book owner regardless
# of the delivery day.
#
# Env:
#   WEB_PARQUET_OUT   staging root (default <repo>/data/web); output lands at
#                     $WEB_PARQUET_OUT/v1/units.parquet
#   Data store selected exactly like the rest of the library (Postgres by
#   default; set EUPHEMIA_DATA_STORE=duckdb + EUPHEMIA_DUCKDB_PATH for offline).

using Euphemia, DataFrames, DuckDB   # DuckDB re-exports DBInterface

"""
    export_units_parquet(v1_dir::AbstractString) -> Int

Query the unit registry + firm map and write `<v1_dir>/units.parquet`.
Returns the number of unit rows written. Self-contained (own writer
connection) so it can be `include`d and called non-fatally from
bin/export_web_parquet.jl without clashing with that script's helpers.
"""
function export_units_parquet(v1_dir::AbstractString)
    # Registry: one row per (zone, code), deduped like get_generators.
    units = Euphemia.sql2df_with_retry("""
        SELECT DISTINCT ON (area_map_code, generation_unit_code)
               area_map_code            AS zone,
               generation_unit_code     AS code,
               generation_unit_name     AS name,
               generation_unit_type     AS ftype
        FROM entsoe.production_and_generation_units
        WHERE generation_unit_status = 'COMMISSIONED'
          AND area_type_code IN ('BZN', 'BZN/CTA')
          AND generation_unit_code IS NOT NULL
        ORDER BY area_map_code, generation_unit_code,
                 valid_from DESC, generation_unit_installed_capacity_mw DESC
    """)

    # Firm map (unit_code -> firm), all zones. Missing table -> empty (warn once);
    # "unknown" is an explicit non-firm placeholder -> treated as null.
    firm_of = Dict{Tuple{String,String},String}()
    try
        fdf = Euphemia.sql2df_with_retry("""
            SELECT zone, unit_code, firm
            FROM simulations.unit_firms
            WHERE unit_code IS NOT NULL AND firm IS NOT NULL
        """)
        for r in eachrow(fdf)
            f = strip(String(r.firm))
            (isempty(f) || lowercase(f) == "unknown") && continue
            firm_of[(String(r.zone), String(r.unit_code))] = f
        end
    catch e
        @warn "simulations.unit_firms unavailable; units.parquet will carry no firms" exception = e
    end

    df = DataFrame(code=String[], display_name=Union{Missing,String}[],
                   fuel=String[], firm=Union{Missing,String}[], zone=String[])
    for r in eachrow(units)
        zone = String(r.zone)
        code = String(r.code)
        name = r.name === missing || r.name === nothing ? missing : String(r.name)
        # Same canonicalisation + name-inference get_generators applies, so the
        # fuel string matches the one the book/UC layer classified the unit as
        # (e.g. a BESS-in-name "Other" becomes "Energy storage").
        declared = Euphemia.normalize_fuel_type_name(String(r.ftype))
        inferred = String(Euphemia.infer_fuel_type_from_name(
            name === missing ? "" : name, Symbol(declared)))
        firm = get(firm_of, (zone, code), missing)
        push!(df, (code, name, inferred, firm, zone))
    end
    sort!(df, [:zone, :code])

    path = joinpath(v1_dir, "units.parquet")
    mkpath(dirname(path))
    con = DBInterface.connect(DuckDB.DB, ":memory:")
    try
        DuckDB.register_data_frame(con, df, "units_df")
        DBInterface.execute(con,
            "COPY (SELECT * FROM units_df) TO '$(replace(path, '\'' => "''"))' " *
            "(FORMAT PARQUET, COMPRESSION ZSTD)")
    finally
        DBInterface.close!(con)
    end
    n_firm = count(!ismissing, df.firm)
    println("wrote v1/units.parquet ($(nrow(df)) units, $(n_firm) with a firm, " *
            "$(length(unique(df.zone))) zones)")
    return nrow(df)
end

function main()
    out_root = get(ENV, "WEB_PARQUET_OUT", joinpath(dirname(@__DIR__), "data", "web"))
    v1_dir = joinpath(out_root, "v1")
    println("EXPORT UNITS PARQUET  out=$v1_dir")
    export_units_parquet(v1_dir)
    println("EXPORT COMPLETE")
end

# Run only when executed as a script; stays a no-op define when `include`d.
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
