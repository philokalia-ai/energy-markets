#!/usr/bin/env julia
#
# Export the bid-methodology object — GENERATED FROM THE RUNNING CODE.
#
# Pillar 5 (docs/pillars/pillar-5-book-methodology-plan.md) teaches HOW a bid is
# built from named ex-ante characteristics. Its hard rule: NEVER hand-author a
# book number the site could compute. So every price, multiplier, SRMC figure
# and constant on the methodology surface is resolved HERE, in-process, from the
# running model's own objects — the cost model (Generators), the form-level
# constants and the description/provenance maps (MeritOrderBook), and the strategy
# taxonomy (book_build.jl). The web layer never transcribes any of them.
#
# This mirrors bin/export_zone_strategies.jl in every respect (§2.2 of the plan):
#   - resolve constants in-process, emit JSON;
#   - write by default OUTSIDE data/web/v1 (to data/calibration/book_methodology.json),
#     so publishing it is an EXPLICIT act, not a side effect of an unrelated
#     web_data_push.sh run (that sync mirrors all of data/web/v1 to the public
#     bucket — same reasoning as export_zone_strategies.jl:19-25);
#   - a sibling guard test (test_book_methodology_export.jl) asserts each section's
#     key set equals the fieldnames/keys of its source object, so adding a fuel or
#     a form constant without describing it fails the build.
#
# The ONE curated-but-cited input is the cv-ledger (docs/pillars/cv-ledger.json):
# measured EXPERIMENT deltas, each citing a committed docs/experiments/ file. It is
# READ here (never regenerated) so the whole surface ships in one payload.
#
# Output: $BOOK_METHODOLOGY_OUT (default <repo>/data/calibration/book_methodology.json).

using Euphemia, JSON, Dates
const MO = Euphemia.MeritOrderBook

const OUT_PATH = get(ENV, "BOOK_METHODOLOGY_OUT",
    joinpath(dirname(@__DIR__), "data", "calibration", "book_methodology.json"))
const CV_LEDGER_PATH =
    joinpath(dirname(@__DIR__), "docs", "pillars", "cv-ledger.json")

_num(x) = x isa Tuple ? collect(x) : x

"""
2a — the SRMC cost model, per fuel type, from the Generators constants. The gas
CCGT constants and, for every fuel in `FUEL_SRMC_BASE`, the non-carbon base and
its electrical emission factor (0 when the fuel carries no carbon). Plus a best-
effort LIVE TTF/EUA close (null offline — the DuckDB extract / no-DB path has no
price feed; the note says so, honestly).
"""
function cost_model()
    fuels = Dict{String,Any}()
    for (fuel, base) in Euphemia.FUEL_SRMC_BASE
        ef = get(Euphemia.FUEL_EMISSION_FACTOR_EL, fuel, 0.0)
        entry = Dict{String,Any}("base_eur" => base, "ef_el" => ef)
        # One honest footnote where €X is NOT a bid (hydro reservoir = O&M only;
        # the water value is applied in the book layer, not the cost model).
        if fuel == "Hydro Water Reservoir"
            entry["note"] = "O&M only — the reservoir water value is applied in the book layer, not the cost model, so this is not a hydro bid."
        elseif fuel == "Fossil Gas"
            entry["note"] = "fallback only — the live TTF path is preferred (see gas.formula)."
        end
        fuels[fuel] = entry
    end
    # Live closes: strictly-pre-today, may be null with no price feed (offline).
    today = Dates.today()
    ttf = try
        get_ttf_price(today)
    catch
        nothing
    end
    eua = try
        eua_price(today)
    catch
        nothing
    end
    return Dict{String,Any}(
        "gas" => Dict{String,Any}(
            "efficiency" => Euphemia.GAS_PLANT_EFFICIENCY,
            "emission_factor_th" => Euphemia.GAS_EMISSION_FACTOR,
            "vom" => Euphemia.GAS_VOM_COST,
            "formula" => "TTF/η + EUA·EF_th/η + VOM",
            "source" => "GAS_PLANT_EFFICIENCY / GAS_EMISSION_FACTOR / GAS_VOM_COST",
        ),
        "fuels" => fuels,
        "live" => Dict{String,Any}(
            "ttf_eur_mwh_th" => ttf,
            "eua_eur_t" => eua,
            "as_of" => string(today),
            "note" => "last close strictly before as_of — no lookahead; null when no price feed is available (offline / DuckDB extract).",
        ),
    )
end

"""
2b — the form-level constants (identical in all 39 zones), resolved by NAME from
the module so a description can never point at a value that no longer exists. The
key set is exactly `keys(CONST_DESCRIPTIONS)`; the guard test ties that to the
constants themselves.
"""
function form_constants()
    values = Dict{String,Any}()
    for name in keys(MO.CONST_DESCRIPTIONS)
        values[name] = _num(getproperty(MO, Symbol(name)))
    end
    return Dict{String,Any}(
        "values" => values,
        "descriptions" => MO.CONST_DESCRIPTIONS,
    )
end

"""
2c — the strategy glossary: `STRATEGY_DESCRIPTIONS` verbatim (the WHY-column
vocabulary). This is the single source of truth the SPA overlays onto its
book-table explanations (§5.1: retires the hand-mirror), so the glossary is
GENERATED, not a third copy.
"""
strategy_glossary() = MO.STRATEGY_DESCRIPTIONS

"""
2d — provenance: the observed/declared wall for every characteristic, from the
`PROVENANCE` map beside the constants and the ZoneProfile fields.
"""
provenance() = MO.PROVENANCE

"""
2e — the cv-ledger of measured changes: READ (not regenerated) from the committed
docs/pillars/cv-ledger.json so it ships in one payload. Each row cites a
docs/experiments/ file and carries the measured deltas from it.
"""
function cv_ledger()
    isfile(CV_LEDGER_PATH) ||
        error("cv-ledger not found at $CV_LEDGER_PATH (docs/pillars/cv-ledger.json)")
    doc = JSON.parsefile(CV_LEDGER_PATH)
    return get(doc, "rows", Any[])
end

function main()
    payload = Dict{String,Any}(
        "generated_utc" => string(Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SS"), "Z"),
        "code_version" => Euphemia.ENERGY_PRICES_CODE_VERSION,
        "generated_from" => "MeritOrderBook + Generators constants, resolved in-process",
        "source_of_truth" => Dict{String,Any}(
            "cost_model" => "src/generators/fuel_costs.jl",
            "form_constants" => "src/merit_order/zone_profiles.jl",
            "strategy_glossary" => "src/merit_order/book_build.jl (STRATEGY_DESCRIPTIONS)",
            "provenance" => "src/merit_order/zone_profiles.jl (PROVENANCE)",
            "cv_ledger" => "docs/pillars/cv-ledger.json (curated, cited)",
        ),
        "cost_model" => cost_model(),
        "form_constants" => form_constants(),
        "strategy_glossary" => strategy_glossary(),
        "provenance" => provenance(),
        "cv_ledger" => cv_ledger(),
    )
    mkpath(dirname(OUT_PATH))
    open(OUT_PATH, "w") do io
        JSON.print(io, payload, 2)
    end
    println("✅ book methodology → $OUT_PATH")
    println("   cost model: $(length(payload["cost_model"]["fuels"])) fuels · " *
            "$(length(MO.CONST_DESCRIPTIONS)) form constants · " *
            "$(length(payload["strategy_glossary"])) strategy terms · " *
            "$(length(payload["provenance"])) provenance rows · " *
            "$(length(payload["cv_ledger"])) cv-ledger rows")
end

main()
