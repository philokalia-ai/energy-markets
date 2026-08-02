#!/usr/bin/env julia
#
# Export the Predictions-page MODEL-CARD + SKILL data plane — the two ADDITIVE
# artifacts pillars 2-4 (docs/pillars/pillars-2-4-predictions-plan.md §7) add on
# top of the existing v1/inputs/ contract:
#
#   v1/inputs/scorecard.json  per-(zone,target) VALID scores the model cards read
#   v1/inputs/skill.json      per-lead (D-1..D-7) input skill the skill strip reads
#
# Unlike bin/export_prediction_inputs.jl this exporter is PURE FILE work — no DB,
# no open-meteo, no Euphemia load — so it is cheap and safe to run non-fatally in
# CI right after the inputs export. It reads only COMMITTED artifacts:
#
#   bin/input_models/meta.json                          — the winners map (TRUTH)
#   docs/experiments/input-upgrade/rollout-39.md        — the 39-zone VALID table
#   docs/experiments/input-upgrade/scorecard.csv        — the 5-pilot VALID scores
#
# WINNER RECONCILIATION. The rollout-39 table's `ship` column was frozen BEFORE
# the corr-guard demotions (fit iteration 1, the six-pillars fits). meta.json's
# `winners` map is the post-guard TRUTH — four NEW winners were demoted to their
# pack on a corr regression (NL_solar, NO2_wind, FR_wind, HU_load). This exporter
# takes the WINNER strictly from meta.json and the measured VALID scores from the
# rollout/pilot tables (the scores are the same numbers either way — the guard
# changed which model SHIPS, not what each scored). So the model card can tell the
# honest "ML beaten by pack on corr — pack ships" story (NL_solar et al.).
#
# COLLAPSE. The solar card wants first-class collapse hit/false-alarm metrics
# (SCIENTIST.md §4). collapse_metrics.py classifies at the PRICE level and needs a
# DB run; no per-(zone) collapse artifact is committed, so `collapse` is emitted
# NULL on solar rows with a top-level `collapse_status:"pending"` — the card
# renders a pending state rather than a fabricated number (plan open-question 2).
#
# SKILL. Per-lead skill needs the archived GFS previous_dayN vintages
# (data/gfs_vintages/, git-ignored) scored against the ENTSO-E reference. Nothing
# per-lead is computable from committed artifacts yet, so skill.json ships in a
# "warming_up" state (empty skill[]) — the strip renders "warming up" and the
# leads fill as the archive accumulates (plan open-question 3). NO fabricated
# deep-lead rows.
#
# Env:
#   WEB_PARQUET_OUT   staging root (default <repo>/data/web); files under $/v1/inputs
#   CODE_VERSION      code_version stamp (default: reads the freshly written
#                     v1/inputs/manifest.json if present, else 31)
#   UPDATED_AT        updated_at override (ISO8601; default now UTC)

using JSON, Dates

const REPO = dirname(@__DIR__)
const OUT_ROOT = get(ENV, "WEB_PARQUET_OUT", joinpath(REPO, "data", "web"))
const INPUTS_DIR = joinpath(OUT_ROOT, "v1", "inputs")
const META_PATH = joinpath(REPO, "bin", "input_models", "meta.json")
const ROLLOUT_PATH = joinpath(REPO, "docs", "experiments", "input-upgrade", "rollout-39.md")
const PILOT_CSV = joinpath(REPO, "docs", "experiments", "input-upgrade", "scorecard.csv")

# The frozen VALID window (rollout-39 protocol.md; committed, not fitted).
const VALID_FIRST = Date(2026, 5, 1)
const VALID_LAST = Date(2026, 7, 22)

const TARGETS = ("load", "solar", "wind")

"Parse a rollout cell: '–' / '' -> nothing, else the Float64."
function num_or_nothing(s::AbstractString)
    t = strip(s)
    (t == "" || t == "–" || t == "-" || t == "—") && return nothing
    v = tryparse(Float64, t)
    return v
end

"""
    read_rollout(path) -> Dict{(zone,target) => NamedTuple}

Parse the 39-zone VALID table in rollout-39.md (`| zone | target | ship | NEW MAE
| pack MAE | NEW corr | pack corr | NEW bias |`). `ship` carries "NEW", "pack" or
"skip (no resource)"; the numbers are the measured VALID scores (nothing where
the row shows '–' — the 5 pilots defer to scorecard.csv).
"""
function read_rollout(path::String)
    out = Dict{Tuple{String,String},NamedTuple}()
    for line in eachline(path)
        startswith(strip(line), "|") || continue
        cells = strip.(split(line, "|"))
        # split gives a leading + trailing empty cell around the pipes
        cells = cells[2:end-1]
        length(cells) == 8 || continue
        zone = cells[1]
        target = cells[2]
        target in TARGETS || continue
        ship_raw = replace(cells[3], "**" => "")
        skip = occursin("skip", lowercase(ship_raw))
        out[(zone, target)] = (
            skip = skip,
            mae_new = num_or_nothing(cells[4]),
            mae_base = num_or_nothing(cells[5]),
            corr_new = num_or_nothing(cells[6]),
            corr_base = num_or_nothing(cells[7]),
            bias_new = num_or_nothing(cells[8]),
        )
    end
    return out
end

"""
    read_pilot_csv(path) -> Dict{(zone,target) => NamedTuple}

The 5-pilot precise VALID scores (zone,target,model∈{NEW,baseline},n,mae,bias,
corr,nmae). Collapses the NEW + baseline rows into one record per (zone,target),
carrying the row count `n` the rollout table omits.
"""
function read_pilot_csv(path::String)
    isfile(path) || return Dict{Tuple{String,String},NamedTuple}()
    lines = readlines(path)
    header = split(lines[1], ",")
    idx = Dict(strip(h) => i for (i, h) in enumerate(header))
    acc = Dict{Tuple{String,String},Dict{String,Any}}()
    for ln in lines[2:end]
        strip(ln) == "" && continue
        f = split(ln, ",")
        zone = strip(f[idx["zone"]]); target = strip(f[idx["target"]])
        model = strip(f[idx["model"]])
        rec = get!(acc, (zone, target), Dict{String,Any}())
        rec["n"] = tryparse(Int, strip(f[idx["n"]]))
        pre = model == "NEW" ? "new" : "base"
        rec["mae_$pre"] = tryparse(Float64, strip(f[idx["mae"]]))
        rec["corr_$pre"] = tryparse(Float64, strip(f[idx["corr"]]))
        model == "NEW" && (rec["bias_new"] = tryparse(Float64, strip(f[idx["bias"]])))
    end
    out = Dict{Tuple{String,String},NamedTuple}()
    for (k, r) in acc
        out[k] = (
            n = get(r, "n", nothing),
            mae_new = get(r, "mae_new", nothing), mae_base = get(r, "mae_base", nothing),
            corr_new = get(r, "corr_new", nothing), corr_base = get(r, "corr_base", nothing),
            bias_new = get(r, "bias_new", nothing),
        )
    end
    return out
end

rnd(x, d) = x === nothing ? nothing : round(x; digits=d)

function code_version()
    haskey(ENV, "CODE_VERSION") && return parse(Int, ENV["CODE_VERSION"])
    mpath = joinpath(INPUTS_DIR, "manifest.json")
    if isfile(mpath)
        try
            m = JSON.parsefile(mpath)
            haskey(m, "code_version") && return Int(m["code_version"])
        catch
        end
    end
    return 31
end

function main()
    println("=" ^ 70)
    println("EXPORT PREDICTION SCORECARD + SKILL  out=$INPUTS_DIR")
    println("=" ^ 70)
    mkpath(INPUTS_DIR)

    meta = JSON.parsefile(META_PATH)
    winners = meta["winners"]                       # {"<zone>_<target>": Bool} — TRUTH
    rollout = read_rollout(ROLLOUT_PATH)
    pilots = read_pilot_csv(PILOT_CSV)

    # Zone universe = every zone named in the winners map (39-zone footprint).
    # Strip the "_<target>" suffix (NOT the last underscore — DE_LU / IT-* keep it).
    zones = String[]
    for k in keys(winners), t in TARGETS
        endswith(k, "_" * t) && push!(zones, k[1:end-length(t)-1])
    end
    zones = sort(unique(zones))

    cv = code_version()
    updated_at = get(ENV, "UPDATED_AT", Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SS") * "Z")

    scores = Vector{Dict{String,Any}}()
    nwin = Dict("ml" => 0, "pack" => 0, "skip" => 0)
    for z in zones, t in TARGETS
        key = "$(z)_$(t)"
        haskey(winners, key) || continue
        ro = get(rollout, (z, t), nothing)
        pc = get(pilots, (z, t), nothing)
        skip = ro !== nothing && ro.skip
        # winner is the corr-guard-reconciled TRUTH from meta.json; a no-resource
        # RES skip is its own state (the pack passthrough is not a "loss").
        winner = skip ? "skip" : (winners[key] === true ? "ml" : "pack")
        nwin[winner] += 1

        # Prefer the rollout number when present (it carries the SHIPPED model,
        # incl. GR's Orthodox retrain); fall back to the pilot csv (DE_LU/ES/NL/
        # SE2 defer to it — rollout shows '–').
        pick(field) = begin
            rv = ro === nothing ? nothing : getfield(ro, field)
            rv !== nothing && return rv
            pc === nothing ? nothing : getfield(pc, field)
        end
        n_valid = pc === nothing ? nothing : pc.n

        entry = Dict{String,Any}(
            "zone" => z, "target" => t, "winner" => winner,
            "mae_new" => rnd(pick(:mae_new), 1), "mae_base" => rnd(pick(:mae_base), 1),
            "corr_new" => rnd(pick(:corr_new), 3), "corr_base" => rnd(pick(:corr_base), 3),
            "bias_new" => rnd(pick(:bias_new), 1),
            "n_valid" => n_valid,
        )
        # collapse metrics are a SOLAR-only, first-class card element; no per-zone
        # collapse artifact is committed yet → null (pending), never fabricated.
        t == "solar" && (entry["collapse"] = nothing)
        push!(scores, entry)
    end
    # deterministic order: GR pinned, then alpha zone, then load/solar/wind.
    torder = Dict("load" => 1, "solar" => 2, "wind" => 3)
    sort!(scores, by = e -> (e["zone"] == "GR" ? "" : e["zone"], torder[e["target"]]))

    scorecard = Dict{String,Any}(
        "schema" => "v1", "code_version" => cv, "updated_at" => updated_at,
        "valid_window" => Dict("first" => string(VALID_FIRST), "last" => string(VALID_LAST),
                               "n_days" => (VALID_LAST - VALID_FIRST).value + 1),
        "collapse_status" => "pending",
        "collapse_note" => "Per-zone collapse hit/false-alarm metrics are computed at " *
            "the price level (docs/experiments/input-upgrade/collapse_metrics.py) and " *
            "need a settled-price run; they fill in a later pass. The hub map's midday " *
            "RES-coverage flag is the live input-level collapse signal.",
        "winner_counts" => nwin,
        "scores" => scores,
    )
    open(joinpath(INPUTS_DIR, "scorecard.json"), "w") do io
        JSON.print(io, scorecard)
    end
    println("wrote inputs/scorecard.json ($(length(scores)) zone-targets; " *
            "ml=$(nwin["ml"]) pack=$(nwin["pack"]) skip=$(nwin["skip"]))")

    # ---- skill.json (per-lead input skill) — warming up ----
    skill = Dict{String,Any}(
        "schema" => "v1", "code_version" => cv, "updated_at" => updated_at,
        "status" => "warming_up",
        "note" => "Per-lead (D-1..D-7) input skill is scored from the archived GFS " *
            "previous_dayN vintages (bin/capture_gfs_vintages.jl -> data/gfs_vintages/). " *
            "The archive is still accumulating enough days for a non-noisy deep-lead " *
            "score, so this surface renders a warming-up state and fills lead by lead " *
            "as the vintages land — no fabricated deep-lead rows.",
        "leads" => collect(1:7),
        "skill" => Vector{Dict{String,Any}}(),   # {zone,target,lead_days,mae,corr,bias,n_days}
    )
    open(joinpath(INPUTS_DIR, "skill.json"), "w") do io
        JSON.print(io, skill)
    end
    println("wrote inputs/skill.json (status=warming_up, 0 lead rows)")
    println("EXPORT COMPLETE")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
