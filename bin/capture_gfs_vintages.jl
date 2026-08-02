# NIGHTLY GFS-VINTAGE ARCHIVE — the durable, in-our-control safety-net for the
# open-meteo `previous_dayN` history the models depend on.
#
# WHY THIS EXISTS. The ex-ante forecast trains and serves on the run issued
# D-lead ("previous_day{lead}") weather. That history lives ONLY on the public
# `previous-runs-api.open-meteo.com`, which is rate-limited (HTTP 429 "Daily API
# request limit exceeded") and can age old runs out of its window. The
# self-hosted open-meteo mirror CANNOT serve previous_dayN (it holds no
# previous-run chunks — see the infra repo `manifests/weather/PREVIOUS_RUNS.md`),
# so we cannot lean on it. This job captures the day's `previous_day1..7`
# vintages to `data/gfs_vintages/` while they are still on the public API, so our
# archive — not a rate-limited external endpoint — becomes the source of truth
# over time. It runs AFTER the 06:30 UTC pre-gate forecast, ~07:30 UTC.
#
# WHAT IT CAPTURES. For each recent delivery day D and each lead n in 1..7, the
# per-timestamp `_previous_day{n}` vintage (the run issued D's-hour − n) for the
# variables the serve-time fetchers consume — wind_speed_100m, shortwave_radiation
# (fetch_weather) and temperature_2m (fetch_load_weather) — over the UNION of all
# 39 zones' RES cells + load cities. Reuses the EXACT fetch machinery (so the
# archive is byte-consistent with what the models see) incl. the local-instance-
# first / public-fallback path added alongside this script.
#
# CONTRACT (matches the ask): idempotent, additive, non-fatal.
#   • additive     one parquet per delivery day, data/gfs_vintages/<D>.parquet
#                  (git-ignored — data/ is in .gitignore). New days only.
#   • idempotent   a delivery-day file that already exists is SKIPPED (re-runs are
#                  cheap; EUPHEMIA_VINTAGE_FORCE=true recomputes it).
#   • non-fatal    per-day failures are caught + warned; the process ALWAYS exits
#                  0 so it can never break the CI job that chains after the
#                  forecast. Partial progress (per-day files) is preserved.
#
# WARM-UP. Deep leads for a just-completed day may sit at the edge of the public
# API's ~7-day previous-runs window and come back null → those rows are simply
# absent (dropped like any null). The archive fills what is available each night;
# the full 1..7 ladder for a day accrues as its runs land. Coverage is honest,
# never fabricated.
#
# Env:
#   EUPHEMIA_VINTAGE_DIR         output dir (default <repo>/data/gfs_vintages)
#   EUPHEMIA_VINTAGE_CAPTURE_DAYS  how many recent delivery days to (re)consider
#                                back from yesterday (default 2 — a missed night
#                                self-heals the next run)
#   EUPHEMIA_VINTAGE_FORCE       'true' to recompute existing day files
#   EUPHEMIA_VINTAGE_MAX_CELLS   cap distinct cells (0 = all; for smoke tests)
#   EUPHEMIA_OPENMETEO_PREVRUNS_URL  tried FIRST per batch; null/error → public
#   EUPHEMIA_OPENMETEO_MODELS    weather model(s), default gfs_seamless
#
# Standalone:
#   julia --project=. bin/capture_gfs_vintages.jl                 # recent window
#   julia --project=. bin/capture_gfs_vintages.jl 2026-07-30      # one day
#   EUPHEMIA_VINTAGE_MAX_CELLS=20 julia --project=. bin/capture_gfs_vintages.jl 2026-07-30

using Dates, DataFrames, DuckDB
DBInterface = DuckDB.DBInterface

include(joinpath(@__DIR__, "weather_res.jl"))    # fetch_weather, load_res_models, default_res_models_path
include(joinpath(@__DIR__, "weather_load.jl"))   # fetch_load_weather, load_load_models, default_load_models_path

const VINTAGE_DIR = get(ENV, "EUPHEMIA_VINTAGE_DIR",
                        joinpath(dirname(@__DIR__), "data", "gfs_vintages"))
const VINTAGE_LEADS = 1:7

# One in-memory DuckDB connection for the parquet writes (same pattern as
# bin/export_web_parquet.jl).
const _VINTAGE_DUCK = DBInterface.connect(DuckDB.DB, ":memory:")

"Write `df` to a zstd parquet at `path` (atomic via a .tmp rename)."
function _write_vintage_parquet(df::DataFrame, path::String)
    mkpath(dirname(path))
    tmp = path * ".tmp"
    DuckDB.register_data_frame(_VINTAGE_DUCK, df, "vintage_staging")
    try
        DBInterface.execute(_VINTAGE_DUCK,
            "COPY (SELECT * FROM vintage_staging) TO '$(replace(tmp, '\'' => "''"))' " *
            "(FORMAT PARQUET, COMPRESSION ZSTD)")
    finally
        DBInterface.execute(_VINTAGE_DUCK, "DROP VIEW IF EXISTS vintage_staging")
    end
    Base.Filesystem.mv(tmp, path; force=true)
    return nrow(df)
end

"""
    all_footprint_cells() -> Vector{Tuple{Float64,Float64}}

Distinct (lat, lon) union of every 39-zone RES pack cell + load pack city — the
full set the serve-time fetchers touch. `EUPHEMIA_VINTAGE_MAX_CELLS` caps it
(0 = all) for smoke tests.
"""
function all_footprint_cells()
    seen = Set{Tuple{Float64,Float64}}()
    cells = Tuple{Float64,Float64}[]
    add(lat, lon) = let t = (Float64(lat), Float64(lon))
        (t in seen) || (push!(seen, t); push!(cells, t))
    end
    res = load_res_models()
    for (_, zm) in res["zones"], c in zm["cells"]
        add(c[1], c[2])
    end
    load = load_load_models()
    if load !== nothing
        for (_, zm) in load["zones"], c in get(zm, "cities", [])
            add(c[1], c[2])
        end
    end
    cap = parse(Int, get(ENV, "EUPHEMIA_VINTAGE_MAX_CELLS", "0"))
    (cap > 0 && length(cells) > cap) && (cells = cells[1:cap])
    return cells
end

"""
    capture_delivery_day(day, cells) -> DataFrame

Fetch the previous_day1..7 vintages for delivery `day` across `cells` and return
the long-form rows (delivery_date, valid_time_utc, lead_days, lat, lon, variable,
value). Nulls are dropped (the fetchers already drop them); a lead beyond the
public API's window contributes no rows.
"""
function capture_delivery_day(day::Date, cells::Vector{Tuple{Float64,Float64}})
    delivery = Date[]; valid = DateTime[]; lead = Int[]
    lat = Float64[]; lon = Float64[]; var = String[]; val = Float64[]
    push_row!(t, n, c, v, x) = begin
        push!(delivery, day); push!(valid, t); push!(lead, n)
        push!(lat, c[1]); push!(lon, c[2]); push!(var, v); push!(val, x)
    end
    for n in VINTAGE_LEADS
        # wind_speed_100m + shortwave_radiation (RES fetch machinery)
        wx = fetch_weather(cells, [day]; vintage_lag=n)
        for (c, hourmap) in wx, (t, (v100, ghi)) in hourmap
            push_row!(t, n, c, "wind_speed_100m", v100)
            push_row!(t, n, c, "shortwave_radiation", ghi)
        end
        # temperature_2m (load fetch machinery; its GHI duplicates wx's — skip it)
        lw = fetch_load_weather(cells, [day]; vintage_lag=n)
        for (c, hourmap) in lw, (t, (temp, _ghi)) in hourmap
            push_row!(t, n, c, "temperature_2m", temp)
        end
    end
    return DataFrame(delivery_date=delivery, valid_time_utc=valid, lead_days=lead,
                     lat=lat, lon=lon, variable=var, value=val)
end

"""
    run_capture(; days=nothing) -> Int

Capture the recent window (or the explicit `days`) into `VINTAGE_DIR`. Per-day
files are skipped when present (unless `EUPHEMIA_VINTAGE_FORCE`). Non-fatal:
per-day errors are warned and skipped. Returns the number of day-files written.
"""
function run_capture(; days::Union{Nothing,Vector{Date}}=nothing)
    force = get(ENV, "EUPHEMIA_VINTAGE_FORCE", "false") == "true"
    cells = all_footprint_cells()
    if isempty(cells)
        @warn "capture_gfs_vintages: no cells resolved from the model packs — nothing to do"
        return 0
    end
    if days === nothing
        back = parse(Int, get(ENV, "EUPHEMIA_VINTAGE_CAPTURE_DAYS", "2"))
        today = Date(now(UTC))
        days = [today - Day(k) for k in back:-1:1]        # oldest-first, up to yesterday
    end
    println("🗂️  gfs-vintage capture: $(length(days)) delivery day(s) × leads $(first(VINTAGE_LEADS))..$(last(VINTAGE_LEADS)), " *
            "$(length(cells)) cells → $(VINTAGE_DIR)")
    written = 0
    for day in days
        path = joinpath(VINTAGE_DIR, "$(day).parquet")
        if isfile(path) && !force
            println("  ⏭️  $(day): already captured (skip; EUPHEMIA_VINTAGE_FORCE=true to redo)")
            continue
        end
        try
            df = capture_delivery_day(day, cells)
            if nrow(df) == 0
                @warn "capture_gfs_vintages: $(day) returned no data (all leads null / beyond coverage) — no file written"
                continue
            end
            n = _write_vintage_parquet(df, path)
            leads = sort(unique(df.lead_days))
            println("  ✅ $(day): $(n) rows, leads present $(leads) → $(basename(path))")
            written += 1
        catch e
            @warn "capture_gfs_vintages: $(day) failed — skipping (non-fatal)" exception=(e, catch_backtrace())
        end
    end
    println("🗂️  gfs-vintage capture done: $(written) day-file(s) written")
    return written
end

if abspath(PROGRAM_FILE) == @__FILE__
    # ALWAYS exit 0 — this archive job must never break the chained CI pipeline.
    try
        days = isempty(ARGS) ? nothing : [Date(a) for a in ARGS]
        run_capture(; days=days)
    catch e
        @warn "capture_gfs_vintages: top-level failure (non-fatal, exiting 0)" exception=(e, catch_backtrace())
    end
end
