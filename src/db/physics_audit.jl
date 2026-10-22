# ============================================================================
# Physics-consistency audit of the ingested ENTSO-E data
# ============================================================================
#
# Every data-corruption incident in the ledger so far — the 13 GW-times-1000
# IT-CSOUTH registry row (cv24), the FR 2026-01-08 mixed 15/60-min RES rows
# and the dropped RS RES NULLs (cv33), the SI/BE days missing D-1 load-forecast
# hours that collapsed the coupled intersection for all 39 zones (cv25), the
# intraday-contaminated phantom ATC (cv26) — was found REACTIVELY, after it had
# already fed order books, and each got its own point defense in the reading
# code. This module is the proactive counterpart: a set of checks, each a
# physical invariant the ingested data cannot violate if it is right, run
# against the data store (live Postgres or a DuckDB extract) over a date
# window. It READS ONLY and never mutates anything; findings are returned as a
# DataFrame and optionally written as a JSON report (bin/physics_audit.jl, and
# a post-refresh step in .github/workflows/refresh-extract.yml).
#
# The checks (severity: :error = physically impossible and feeds the model,
# :warn = implausible / needs a look, :info = context):
#
#   solar_night          solar D-1 forecast while the sun is below the horizon
#                        at the zone centroid (catches timestamp/timezone
#                        shifts — e.g. PT 2025-06-01/02, the whole solar bell
#                        displaced into the night)
#   solar_day_missing    no/zero solar forecast across a day's sun-high hours
#                        in a zone-month where solar is normally large (the
#                        other half of a shifted or dropped day; ES 2026-06-11)
#   load_bounds          D-1 load forecast outside the zone's physical envelope
#                        (near-zero or far above the historical peak)
#   load_day_incomplete  a D-1 load-forecast day carrying fewer than 24 UTC
#                        hours (the cv25 "one-hour zone collapses all 39" defect)
#   resolution_mix       more than one native resolution per (zone, type, day)
#                        in the RES or load forecast (FR 2026-01-08 was
#                        quartered/doubled by this)
#   registry_bounds      unit installed capacity <= 0 or > MAX_PLAUSIBLE_UNIT_MW
#   registry_overlap     overlapping validity windows with different capacities
#                        for the same unit (the loader dedups; the count is a
#                        source-quality signal)
#   unit_output_above_capacity  per-unit actual output above installed capacity
#                        (unit mix-ups and stale registry capacities)
#   reservoir_anomaly    weekly reservoir storage negative, above historical
#                        max, or swinging faster than a reservoir physically
#                        can (the SI zero-glitch weeks)
#   flow_spike           physical flow far above the border's own p99 — a unit-
#                        error detector; genuinely extreme regimes also land
#                        here, which is why it is :warn, a review queue
#   price_caps           settled day-ahead price outside the harmonized
#                        EUPHEMIA caps (validation data only, :info)
#
# Baselines (quantiles, historical maxima, climatologies) are computed from
# the store over the audit window plus `lookback_days` (default 400, the
# repo's standard seasonal lookback). They are data-quality screens, not model
# inputs, so the ex-ante rule does not apply to them — the audit never feeds
# the clearing path.

using Statistics: median, quantile

# Zone centroids (lat, lon) for sun-elevation geometry, derived once from
# bin/input_models/geom.json (mean over each zone's RES cells, cities where a
# zone has no cells). RES-cell means can sit off the geographic center (NL's
# offshore wind pulls it into the Channel); the -5 degree night margin below
# absorbs that. Keep in sync with geom.json if zones are added.
const AUDIT_ZONE_CENTROIDS = Dict{String,Tuple{Float64,Float64}}(
    "AT" => (47.981, 16.066),
    "BE" => (50.969, 4.267),
    "BG" => (43.103, 26.984),
    "CH" => (47.083, 8.197),
    "CZ" => (50.136, 15.357),
    "DE_LU" => (52.065, 9.840),
    "DK1" => (56.101, 9.219),
    "DK2" => (55.329, 12.089),
    "EE" => (58.968, 24.947),
    "ES" => (40.190, -4.447),
    "FI" => (63.528, 24.596),
    "FR" => (44.149, 7.077),
    "GR" => (38.124, 23.881),
    "HU" => (47.556, 18.383),
    "IT-CNORTH" => (43.810, 10.871),
    "IT-CSOUTH" => (42.257, 13.024),
    "IT-Calabria" => (39.050, 16.727),
    "IT-NORTH" => (45.478, 10.179),
    "IT-SOUTH" => (41.090, 15.529),
    "IT-Sardinia" => (40.131, 8.887),
    "IT-Sicily" => (37.660, 13.860),
    "LT" => (55.458, 22.894),
    "LV" => (56.919, 22.666),
    "NL" => (50.446, 1.591),
    "NO1" => (60.792, 11.232),
    "NO2" => (58.667, 6.158),
    "NO3" => (63.911, 10.000),
    "NO4" => (69.267, 21.011),
    "NO5" => (61.478, 5.251),
    "PL" => (52.458, 18.743),
    "PT" => (39.905, -8.907),
    "RO" => (45.062, 27.608),
    "RS" => (44.931, 20.990),
    "SE1" => (66.621, 21.478),
    "SE2" => (63.701, 17.622),
    "SE3" => (59.163, 14.589),
    "SE4" => (56.422, 14.563),
    "SI" => (46.185, 14.447),
    "SK" => (48.944, 19.540),
)

# sin(solar elevation), same declination/hour-angle formula as
# bin/weather_res.jl `sinel` but UNCLAMPED — the audit needs the sign of the
# elevation (below-horizon detection), not a feature value. Change together.
function audit_sun_sin(t::DateTime, lat0::Real, lon0::Real)
    doy = dayofyear(t)
    dec = 0.409 * sin(2π * (doy + 284) / 365)
    H = (hour(t) + minute(t) / 60 + lon0 / 15 - 12) * 15π / 180
    return sind(lat0) * sin(dec) + cosd(lat0) * cos(dec) * cos(H)
end

# --- Thresholds (named so the experiment doc and the tests speak the same
# --- language; see docs/experiments/physics-audit/README.md for calibration) --
const SOLAR_NIGHT_SIN = -0.087          # sin(-5°): clearly below the horizon,
# absorbing centroid error + twilight
const SOLAR_NIGHT_TOL_MW = 50.0         # absolute floor under the relative rule
const SOLAR_NIGHT_FRAC = 0.02           # night tolerance: 2% of the zone's daytime
# p95 (TSO forecast-model floors publish
# small nonzero night values; those are
# noise, not corruption)
const SOLAR_NIGHT_ERROR_FRAC = 0.05     # above 5% of daytime p95 it corrupts the
# book materially -> :error, else :warn
# Zones with concentrated solar power (CSP) + storage genuinely generate
# "Solar" MW at night; ES carries ~2.3 GW of CSP. Audit only above its fleet.
const SOLAR_NIGHT_CSP_TOL_MW = Dict{String,Float64}("ES" => 2500.0)
const SOLAR_DAY_SIN = 0.3               # "sun high" hours for the missing-day check
const SOLAR_DAY_MIN_CLIM_MW = 200.0     # only zones-months where solar matters
const LOAD_LOW_FRAC = 0.15              # load below 15% of p50 is not a real system
const LOAD_HIGH_FRAC = 1.5              # load above 1.5x p99 is not a real system
const RESERVOIR_MAX_WEEKLY_SWING = 0.30 # |Δ| per week as a share of historical max
const FLOW_SPIKE_FACTOR = 3.0           # flow above 3x the border's own p99
const FLOW_SPIKE_MIN_P99_MW = 50.0      # ignore trickle borders
const UNIT_OVER_CAP_FACTOR = 1.2        # output above 1.2x installed capacity
const UNIT_OVER_CAP_ERROR_RATIO = 2.0   # above 2x it is :error, not :warn
const PRICE_CAP_LOW = -500.0            # EUPHEMIA harmonized floor
const PRICE_CAP_HIGH = 4100.0           # harmonized cap (4,000) + headroom

const AUDIT_FINDING_COLS = [:check, :severity, :zone, :period, :n, :value, :bound, :detail]

_audit_empty() = DataFrame(
    check = String[],
    severity = String[],
    zone = String[],
    period = String[],
    n = Int[],
    value = Float64[],
    bound = Float64[],
    detail = String[],
)

function _audit_row!(df::DataFrame; check, severity, zone, period, n, value, bound, detail)
    push!(
        df,
        (
            check = String(check),
            severity = String(severity),
            zone = String(zone),
            period = String(period),
            n = Int(n),
            value = Float64(value),
            bound = Float64(bound),
            detail = String(detail),
        ),
    )
    return df
end

_zone_filter_sql(zones, col) = zones === nothing ? "" : " AND $col = ANY(\$Z)"

# Substitute the zone placeholder and build the arg vector: SQL here uses $1,
# $2, ... for window args and the literal \$Z for the optional zone list.
function _audit_sql(sql::String, args::Vector{Any}, zones)
    if zones === nothing
        @assert !occursin("\$Z", sql)
        return (sql, args)
    end
    n = length(args) + 1
    return (replace(sql, "\$Z" => "\$$n"), vcat(args, Any[collect(zones)]))
end

# ----------------------------------------------------------------------------
# Pure check functions (DataFrame in -> findings out; unit-tested on synthetic
# frames in test/test_physics_audit.jl)
# ----------------------------------------------------------------------------

"""
    check_solar_night(solar::DataFrame) -> findings

`solar` columns: `zone, ts::DateTime, fc` (hourly-mean D-1 solar forecast MW).
Flags zone-days with forecast above the night tolerance while the sun is below
-5° at the zone centroid. The tolerance is RELATIVE — max($(SOLAR_NIGHT_TOL_MW)
MW, $(SOLAR_NIGHT_FRAC)·(zone daytime p95), the CSP fleet where one exists) —
because several TSO forecast models publish small nonzero night values
(noise), while a night value at fleet scale is a displaced or corrupt day.
Above $(SOLAR_NIGHT_ERROR_FRAC)·p95 it is :error, else :warn. Zones without a
centroid are skipped.
"""
function check_solar_night(solar::DataFrame)
    out = _audit_empty()
    isempty(solar) && return out
    # Daytime p95 per zone, from the same frame (sun-high hours).
    dayvals = Dict{String,Vector{Float64}}()
    for r in eachrow(solar)
        c = get(AUDIT_ZONE_CENTROIDS, r.zone, nothing)
        c === nothing && continue
        audit_sun_sin(r.ts, c[1], c[2]) > SOLAR_DAY_SIN || continue
        push!(get!(dayvals, r.zone, Float64[]), Float64(r.fc))
    end
    p95 = Dict(z => quantile(v, 0.95) for (z, v) in dayvals if !isempty(v))
    tol(z) = max(
        SOLAR_NIGHT_TOL_MW,
        SOLAR_NIGHT_FRAC * get(p95, z, 0.0),
        get(SOLAR_NIGHT_CSP_TOL_MW, z, 0.0),
    )
    bad = Dict{Tuple{String,Date},Tuple{Int,Float64}}()
    for r in eachrow(solar)
        c = get(AUDIT_ZONE_CENTROIDS, r.zone, nothing)
        c === nothing && continue
        (r.fc > tol(r.zone) && audit_sun_sin(r.ts, c[1], c[2]) < SOLAR_NIGHT_SIN) ||
            continue
        k = (r.zone, Date(r.ts))
        (n, mx) = get(bad, k, (0, 0.0))
        bad[k] = (n + 1, max(mx, Float64(r.fc)))
    end
    for ((z, d), (n, mx)) in sort!(collect(bad); by = first)
        material =
            mx > max(
                SOLAR_NIGHT_ERROR_FRAC * get(p95, z, 0.0),
                get(SOLAR_NIGHT_CSP_TOL_MW, z, 0.0),
                SOLAR_NIGHT_TOL_MW,
            )
        _audit_row!(
            out;
            check = "solar_night",
            severity = material ? "error" : "warn",
            zone = z,
            period = string(d),
            n = n,
            value = mx,
            bound = tol(z),
            detail = "$n night hour(s) with solar forecast up to $(round(mx, digits=1)) MW " *
                     "while the sun is below -5° — timestamp shift or corrupt rows",
        )
    end
    return out
end

"""
    check_solar_day_missing(solar::DataFrame) -> findings

Same input frame as `check_solar_night`. A zone-day whose maximum forecast over
sun-high hours (sin elevation > $(SOLAR_DAY_SIN)) is <= 1 MW, in a zone-month
whose median such maximum is >= $(SOLAR_DAY_MIN_CLIM_MW) MW, has physically
lost its solar (dropped rows, NULLed values, or a shifted bell).
"""
function check_solar_day_missing(solar::DataFrame)
    out = _audit_empty()
    isempty(solar) && return out
    daymax = Dict{Tuple{String,Date},Float64}()
    for r in eachrow(solar)
        c = get(AUDIT_ZONE_CENTROIDS, r.zone, nothing)
        c === nothing && continue
        audit_sun_sin(r.ts, c[1], c[2]) > SOLAR_DAY_SIN || continue
        k = (r.zone, Date(r.ts))
        daymax[k] = max(get(daymax, k, 0.0), Float64(r.fc))
    end
    clim = Dict{Tuple{String,Int},Vector{Float64}}()
    for ((z, d), mx) in daymax
        push!(get!(clim, (z, month(d)), Float64[]), mx)
    end
    # A day the zone carries NO solar rows at all is the worst case of the same
    # defect (the ES 2026-06-11 "cleared with no RES" class): enumerate every
    # date between the zone's first and last carried day and treat absent days
    # as a daily max of 0 — they are judged against the same climatology.
    span = Dict{String,Tuple{Date,Date}}()
    for (z, d) in keys(daymax)
        (lo, hi) = get(span, z, (d, d))
        span[z] = (min(lo, d), max(hi, d))
    end
    # Only days whose solar-NOON elevation clears the sun-high threshold can
    # be judged: at 50°N+ a late-autumn day never reaches sin(el) > SOLAR_DAY_SIN
    # at all, and enumerating it would misread deep winter as "missing".
    noon_sin(z, d) = begin
        c = AUDIT_ZONE_CENTROIDS[z]
        dec = 0.409 * sin(2π * (dayofyear(d) + 284) / 365)
        sind(c[1]) * sin(dec) + cosd(c[1]) * cos(dec)
    end
    full = Dict{Tuple{String,Date},Float64}()
    for (z, (lo, hi)) in span, d = lo:Day(1):hi
        noon_sin(z, d) > SOLAR_DAY_SIN || continue
        full[(z, d)] = get(daymax, (z, d), 0.0)
    end
    for ((z, d), mx) in sort!(collect(full); by = first)
        mx <= 1.0 || continue
        vals = get(clim, (z, month(d)), Float64[])
        isempty(vals) && continue
        med = median(vals)
        med >= SOLAR_DAY_MIN_CLIM_MW || continue
        absent = !haskey(daymax, (z, d))
        _audit_row!(
            out;
            check = "solar_day_missing",
            severity = "error",
            zone = z,
            period = string(d),
            n = 1,
            value = mx,
            bound = med,
            detail = (
                         absent ? "no usable solar forecast (rows absent or all-NULL)" :
                         "no solar across the day's sun-high hours"
                     ) *
                     " (zone-month median daily max $(round(med, digits=0)) MW) — " *
                     "dropped/NULLed/shifted day",
        )
    end
    return out
end

"""
    check_load_bounds(load::DataFrame, stats::DataFrame) -> findings

`load`: `zone, ts, mw` (hourly D-1 load forecast). `stats`: per-zone `zone,
p50, p99` over window + lookback. Flags hours below
$(LOAD_LOW_FRAC)·p50 (a bidding zone's demand never physically collapses to
near zero) or above $(LOAD_HIGH_FRAC)·p99, grouped per zone-day.
"""
function check_load_bounds(load::DataFrame, stats::DataFrame)
    out = _audit_empty()
    (isempty(load) || isempty(stats)) && return out
    st = Dict(r.zone => (Float64(r.p50), Float64(r.p99)) for r in eachrow(stats))
    bad = Dict{Tuple{String,Date,Symbol},Tuple{Int,Float64}}()
    for r in eachrow(load)
        s = get(st, r.zone, nothing)
        s === nothing && continue
        (p50, p99) = s
        kind =
            r.mw < LOAD_LOW_FRAC * p50 ? :low : (r.mw > LOAD_HIGH_FRAC * p99 ? :high : :ok)
        kind == :ok && continue
        k = (r.zone, Date(r.ts), kind)
        (n, ext) = get(bad, k, (0, kind == :low ? Inf : -Inf))
        bad[k] = (n + 1, kind == :low ? min(ext, Float64(r.mw)) : max(ext, Float64(r.mw)))
    end
    for ((z, d, kind), (n, ext)) in sort!(collect(bad); by = first)
        (p50, p99) = st[z]
        bound = kind == :low ? LOAD_LOW_FRAC * p50 : LOAD_HIGH_FRAC * p99
        _audit_row!(
            out;
            check = "load_bounds",
            severity = "error",
            zone = z,
            period = string(d),
            n = n,
            value = ext,
            bound = bound,
            detail = kind == :low ?
                     "$n hour(s) with load forecast down to $(round(ext, digits=1)) MW " *
                     "(< 15% of the zone's p50 $(round(p50, digits=0))) — demand book collapses" :
                     "$n hour(s) with load forecast up to $(round(ext, digits=1)) MW " *
                     "(> 1.5x the zone's p99 $(round(p99, digits=0)))",
        )
    end
    return out
end

"""
    check_load_day_incomplete(load::DataFrame) -> findings

A D-1 load-forecast UTC day must carry 24 distinct hours (UTC days have no DST
seams). Interior zone-days with fewer are the cv25 defect class: a one-hour
zone collapses the coupled 39-zone intersection. The first and last day each
zone carries are edge days (partial by construction) and are skipped.
"""
function check_load_day_incomplete(load::DataFrame)
    out = _audit_empty()
    isempty(load) && return out
    hours = Dict{Tuple{String,Date},Set{Int}}()
    for r in eachrow(load)
        push!(get!(hours, (r.zone, Date(r.ts)), Set{Int}()), hour(r.ts))
    end
    edges = Dict{String,Tuple{Date,Date}}()
    for (z, d) in keys(hours)
        (lo, hi) = get(edges, z, (d, d))
        edges[z] = (min(lo, d), max(hi, d))
    end
    for ((z, d), hs) in sort!(collect(hours); by = first)
        (d == edges[z][1] || d == edges[z][2]) && continue
        length(hs) < 24 || continue
        _audit_row!(
            out;
            check = "load_day_incomplete",
            severity = "error",
            zone = z,
            period = string(d),
            n = 24 - length(hs),
            value = Float64(length(hs)),
            bound = 24.0,
            detail = "D-1 load forecast carries only $(length(hs))/24 UTC hours — " *
                     "collapses the coupled intersection for every zone in the clear",
        )
    end
    return out
end

"""
    check_resolution_mix(mix::DataFrame) -> findings

`mix`: `zone, series, day, n_res` — rows where a (zone, series, UTC day)
carries more than one native `resolution_code`. One physical quantity has one
market-time-unit per day; a mix is an ingestion seam (FR 2026-01-08 was
quartered/doubled by exactly this before cv33 defended the reader).
"""
function check_resolution_mix(mix::DataFrame)
    out = _audit_empty()
    for r in eachrow(mix)
        _audit_row!(
            out;
            check = "resolution_mix",
            severity = "warn",
            zone = r.zone,
            period = string(r.day),
            n = r.n_res,
            value = Float64(r.n_res),
            bound = 1.0,
            detail = "$(r.series) carries $(r.n_res) native resolutions on one day",
        )
    end
    return out
end

"""
    check_registry(reg::DataFrame) -> findings

`reg`: `zone, unit, cap, valid_from, valid_to` (one row per registry validity
period). Capacity bounds use `MAX_PLAUSIBLE_UNIT_MW` (the cv24 constant — the
largest real European plant is ~6 GW); overlapping validity windows with
different capacities are the loader-dedup class, reported as :warn.
"""
function check_registry(reg::DataFrame)
    out = _audit_empty()
    isempty(reg) && return out
    for r in eachrow(reg)
        ismissing(r.cap) && continue
        if r.cap > MAX_PLAUSIBLE_UNIT_MW || r.cap <= 0
            # A >25 GW row poisons fleet-truthing denominators (:error, the
            # cv24 incident); a 0-MW row is registry noise the loaders already
            # skip (:warn, a source-quality signal).
            _audit_row!(
                out;
                check = "registry_bounds",
                severity = r.cap > MAX_PLAUSIBLE_UNIT_MW ? "error" : "warn",
                zone = r.zone,
                period = string(coalesce(r.valid_from, "")),
                n = 1,
                value = Float64(r.cap),
                bound = MAX_PLAUSIBLE_UNIT_MW,
                detail = "unit $(r.unit) installed capacity $(r.cap) MW is not a real plant",
            )
        end
    end
    far = Date(2099, 1, 1)
    for sub in groupby(DataFrame(reg), :unit)
        nrow(sub) > 1 || continue
        rows = sort(collect(eachrow(sub)); by = r -> coalesce(r.valid_from, Date(1900)))
        n_overlap = 0
        for i = 1:(length(rows)-1), j = (i+1):length(rows)
            (a, b) = (rows[i], rows[j])
            (ismissing(a.cap) || ismissing(b.cap) || a.cap == b.cap) && continue
            # NB: coalesce, not something — registry validity columns carry
            # `missing`, which `something` does not skip.
            a_to = coalesce(a.valid_to, far)
            b_from = coalesce(b.valid_from, Date(1900))
            b_from < a_to && (n_overlap += 1)
        end
        n_overlap == 0 && continue
        r1 = rows[1]
        _audit_row!(
            out;
            check = "registry_overlap",
            severity = "warn",
            zone = r1.zone,
            period = "",
            n = n_overlap,
            value = Float64(n_overlap),
            bound = 0.0,
            detail = "unit $(r1.unit): $n_overlap overlapping validity window pair(s) " *
                     "with different capacities (loader dedups; source-quality signal)",
        )
    end
    return out
end

"""
    check_unit_output(over::DataFrame) -> findings

`over`: per unit `zone, unit, cap, n_over, max_mw` — hours of actual output
above $(UNIT_OVER_CAP_FACTOR)x installed capacity, pre-aggregated in SQL. A
ratio >= $(UNIT_OVER_CAP_ERROR_RATIO)x is :error (unit mix-up / unit-of-measure
slip); below that :warn (uprates, stale registry capacity).
"""
function check_unit_output(over::DataFrame)
    out = _audit_empty()
    for r in eachrow(over)
        ratio = r.max_mw / r.cap
        _audit_row!(
            out;
            check = "unit_output_above_capacity",
            severity = ratio >= UNIT_OVER_CAP_ERROR_RATIO ? "error" : "warn",
            zone = r.zone,
            period = "",
            n = r.n_over,
            value = Float64(r.max_mw),
            bound = UNIT_OVER_CAP_FACTOR * r.cap,
            detail = "unit $(r.unit): $(r.n_over) hour(s) above " *
                     "$(UNIT_OVER_CAP_FACTOR)x installed $(r.cap) MW, " *
                     "max $(round(r.max_mw, digits=1)) MW ($(round(ratio, digits=2))x)",
        )
    end
    return out
end

"""
    check_reservoir(res::DataFrame) -> findings

`res`: weekly `zone, year, week, e` (stored energy MWh, zone-level). Flags
negative storage, storage above 1.05x the zone's historical max, and
week-over-week swings above $(RESERVOIR_MAX_WEEKLY_SWING) of the historical
max — a seasonal reservoir system cannot physically cycle that fast (the SI
zero-glitch weeks drop to 0 and recover, which `get_reservoir_dryness`
otherwise consumes as truth).
"""
function check_reservoir(res::DataFrame)
    out = _audit_empty()
    isempty(res) && return out
    for sub in groupby(sort(DataFrame(res), [:zone, :year, :week]), :zone)
        mxe = maximum(skipmissing(sub.e); init = 0.0)
        mxe > 0 || continue
        prev = missing
        for r in eachrow(sub)
            ismissing(r.e) && continue
            period = "$(r.year)-W$(lpad(r.week, 2, '0'))"
            if r.e < 0 || r.e > 1.05 * mxe
                _audit_row!(
                    out;
                    check = "reservoir_anomaly",
                    severity = "error",
                    zone = r.zone,
                    period = period,
                    n = 1,
                    value = Float64(r.e),
                    bound = 1.05 * mxe,
                    detail = "weekly stored energy $(round(r.e, digits=0)) MWh outside [0, 1.05x historical max]",
                )
            elseif !ismissing(prev) && abs(r.e - prev) > RESERVOIR_MAX_WEEKLY_SWING * mxe
                _audit_row!(
                    out;
                    check = "reservoir_anomaly",
                    severity = "error",
                    zone = r.zone,
                    period = period,
                    n = 1,
                    value = Float64(r.e - prev),
                    bound = RESERVOIR_MAX_WEEKLY_SWING * mxe,
                    detail = "weekly swing $(round(r.e - prev, digits=0)) MWh exceeds " *
                             "$(Int(RESERVOIR_MAX_WEEKLY_SWING * 100))% of the historical max " *
                             "$(round(mxe, digits=0)) — reservoirs cannot cycle that fast",
                )
            end
            prev = r.e
        end
    end
    return out
end

"""
    check_flow_spikes(spikes::DataFrame) -> findings

`spikes`: per directed border `o, i, n, max_mw, p99` — hours with physical flow
above $(FLOW_SPIKE_FACTOR)x the border's own p99 (borders with p99 >=
$(FLOW_SPIKE_MIN_P99_MW) MW), pre-aggregated in SQL. :warn — a review queue:
unit-of-measure errors land here, and so do genuinely extreme regimes (the
SE4->SE3 Dec-2023 storm hours), which only a human can separate.
"""
function check_flow_spikes(spikes::DataFrame)
    out = _audit_empty()
    for r in eachrow(spikes)
        _audit_row!(
            out;
            check = "flow_spike",
            severity = "warn",
            zone = "$(r.o)->$(r.i)",
            period = "",
            n = r.n,
            value = Float64(r.max_mw),
            bound = FLOW_SPIKE_FACTOR * r.p99,
            detail = "$(r.n) hour(s) above $(FLOW_SPIKE_FACTOR)x the border p99 " *
                     "($(round(r.p99, digits=0)) MW), max $(round(r.max_mw, digits=0)) MW",
        )
    end
    return out
end

"""
    check_price_caps(prices::DataFrame) -> findings

`prices`: per zone `zone, n, mn, mx` of settled day-ahead prices outside
[$(PRICE_CAP_LOW), $(PRICE_CAP_HIGH)] €/MWh (the harmonized EUPHEMIA caps;
EUR rows only — out-of-area zones priced in local currency, e.g. UA_IPS in
UAH, are not bound by them). Validation data only — :info.
"""
function check_price_caps(prices::DataFrame)
    out = _audit_empty()
    for r in eachrow(prices)
        _audit_row!(
            out;
            check = "price_caps",
            severity = "info",
            zone = r.zone,
            period = "",
            n = r.n,
            value = Float64(r.mx),
            bound = PRICE_CAP_HIGH,
            detail = "$(r.n) settled price(s) outside [$(PRICE_CAP_LOW), $(PRICE_CAP_HIGH)] " *
                     "€/MWh (min $(round(r.mn, digits=1)), max $(round(r.mx, digits=1)))",
        )
    end
    return out
end

# ----------------------------------------------------------------------------
# Fetchers — one store round-trip per check family; Postgres-dialect SQL, the
# DuckDB rewrite in sql2df handles the extract backend.
# ----------------------------------------------------------------------------

function _fetch_solar(d0::Date, d1::Date, zones)
    (sql, args) = _audit_sql(
        """
        SELECT area_map_code AS zone,
               date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS ts,
               AVG(day_ahead_generation_forecast_mw) AS fc
        FROM entsoe.generation_forecasts_for_wind_and_solar
        WHERE production_type = 'Solar' AND area_map_code IS NOT NULL
          AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND day_ahead_generation_forecast_mw IS NOT NULL""" *
        _zone_filter_sql(zones, "area_map_code") *
        "\nGROUP BY 1, 2",
        Any[d0, d1],
        zones,
    )
    df = sql2df_with_retry(sql, args)
    isempty(df) && return DataFrame(zone = String[], ts = DateTime[], fc = Float64[])
    return DataFrame(zone = String.(df.zone), ts = DateTime.(df.ts), fc = Float64.(df.fc))
end

function _fetch_load(d0::Date, d1::Date, zones)
    (sql, args) = _audit_sql(
        """
        SELECT area_map_code AS zone,
               date_trunc('hour', date_time_utc AT TIME ZONE 'UTC') AS ts,
               AVG(total_load_mw) AS mw
        FROM entsoe.day_ahead_total_load_forecast
        WHERE area_type_code LIKE 'BZN%' AND area_map_code IS NOT NULL
          AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND total_load_mw IS NOT NULL""" *
        _zone_filter_sql(zones, "area_map_code") *
        "\nGROUP BY 1, 2",
        Any[d0, d1],
        zones,
    )
    df = sql2df_with_retry(sql, args)
    isempty(df) && return DataFrame(zone = String[], ts = DateTime[], mw = Float64[])
    return DataFrame(zone = String.(df.zone), ts = DateTime.(df.ts), mw = Float64.(df.mw))
end

function _fetch_load_stats(d0::Date, d1::Date, zones)
    (sql, args) = _audit_sql(
        """
        SELECT area_map_code AS zone,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY total_load_mw) AS p50,
               percentile_cont(0.99) WITHIN GROUP (ORDER BY total_load_mw) AS p99
        FROM entsoe.day_ahead_total_load_forecast
        WHERE area_type_code LIKE 'BZN%'
          AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND total_load_mw IS NOT NULL AND total_load_mw > 0""" *
        _zone_filter_sql(zones, "area_map_code") *
        "\nGROUP BY 1",
        Any[d0, d1],
        zones,
    )
    return sql2df_with_retry(sql, args)
end

function _fetch_resolution_mix(d0::Date, d1::Date, zones)
    out = DataFrame(zone = String[], series = String[], day = Date[], n_res = Int[])
    for (table, series, type_expr) in [
        (
            "entsoe.generation_forecasts_for_wind_and_solar",
            "RES forecast",
            ", production_type",
        ),
        ("entsoe.day_ahead_total_load_forecast", "load forecast", ""),
    ]
        (sql, args) = _audit_sql(
            """
            SELECT area_map_code AS zone,
                   (date_time_utc AT TIME ZONE 'UTC')::date AS day,
                   COUNT(DISTINCT resolution_code) AS n_res
            FROM $table
            WHERE date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$2::date::timestamp AT TIME ZONE 'UTC')""" *
            _zone_filter_sql(zones, "area_map_code") *
            "\nGROUP BY 1, 2$type_expr\nHAVING COUNT(DISTINCT resolution_code) > 1",
            Any[d0, d1],
            zones,
        )
        df = sql2df_with_retry(sql, args)
        for r in eachrow(df)
            push!(
                out,
                (
                    zone = String(r.zone),
                    series = series,
                    day = Date(r.day),
                    n_res = Int(r.n_res),
                ),
            )
        end
    end
    return out
end

function _fetch_registry(zones)
    (sql, args) = _audit_sql(
        """
        SELECT area_map_code AS zone, generation_unit_code AS unit,
               generation_unit_installed_capacity_mw AS cap,
               valid_from, valid_to
        FROM entsoe.production_and_generation_units
        WHERE generation_unit_code IS NOT NULL""" *
        _zone_filter_sql(zones, "area_map_code"),
        Any[],
        zones,
    )
    df = sql2df_with_retry(sql, args)
    isempty(df) && return DataFrame(
        zone = String[],
        unit = String[],
        cap = Union{Missing,Float64}[],
        valid_from = Union{Missing,Date}[],
        valid_to = Union{Missing,Date}[],
    )
    return DataFrame(
        zone = String.(coalesce.(df.zone, "?")),
        unit = String.(df.unit),
        cap = [ismissing(c) ? missing : Float64(c) for c in df.cap],
        valid_from = [ismissing(v) ? missing : Date(v) for v in df.valid_from],
        valid_to = [ismissing(v) ? missing : Date(v) for v in df.valid_to],
    )
end

function _fetch_unit_over_cap(d0::Date, d1::Date, zones)
    (sql, args) = _audit_sql(
        """
        WITH reg AS (
            SELECT generation_unit_code AS unit, MAX(area_map_code) AS zone,
                   MAX(generation_unit_installed_capacity_mw) AS cap
            FROM entsoe.production_and_generation_units
            WHERE generation_unit_installed_capacity_mw > 0
              AND generation_unit_installed_capacity_mw <= $(MAX_PLAUSIBLE_UNIT_MW)""" *
        _zone_filter_sql(zones, "area_map_code") *
        """
            GROUP BY 1)
        SELECT reg.zone, reg.unit, reg.cap,
               COUNT(*) AS n_over, MAX(g.actual_generation_output_mw) AS max_mw
        FROM entsoe.actual_generation_output_per_generation_unit g
        JOIN reg ON g.generation_unit_code = reg.unit
        WHERE g.date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND g.date_time_utc < (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND g.actual_generation_output_mw > $(UNIT_OVER_CAP_FACTOR) * reg.cap
        GROUP BY 1, 2, 3
        """,
        Any[d0, d1],
        zones,
    )
    return sql2df_with_retry(sql, args)
end

function _fetch_reservoir(zones)
    (sql, args) = _audit_sql(
        """
        SELECT area_map_code AS zone, year, week, AVG(stored_energy_mwh) AS e
        FROM entsoe.aggregated_hydro_storage_filling_rate
        WHERE area_type_code LIKE 'BZN%'""" *
        _zone_filter_sql(zones, "area_map_code") *
        "\nGROUP BY 1, 2, 3",
        Any[],
        zones,
    )
    return sql2df_with_retry(sql, args)
end

function _fetch_flow_spikes(start_date::Date, end_date::Date, base0::Date, zones)
    # Border p99 over window + lookback ([base0, end)) is computed in the same
    # statement; the spike join scans only the audited window and returns only
    # violating hours, so the frame stays tiny.
    zf =
        zones === nothing ? "" :
        " AND (out_area_map_code = ANY(\$Z) OR in_area_map_code = ANY(\$Z))"
    (sql, args) = _audit_sql(
        """
        WITH p AS (
            SELECT out_area_map_code AS o, in_area_map_code AS i,
                   percentile_cont(0.99) WITHIN GROUP (ORDER BY flow_mw) AS p99
            FROM entsoe.physical_flows
            WHERE in_area_type_code LIKE 'BZN%' AND out_area_type_code LIKE 'BZN%'
              AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < (\$2::date::timestamp AT TIME ZONE 'UTC')$zf
            GROUP BY 1, 2)
        SELECT f.out_area_map_code AS o, f.in_area_map_code AS i,
               COUNT(*) AS n, MAX(f.flow_mw) AS max_mw, MAX(p.p99) AS p99
        FROM entsoe.physical_flows f
        JOIN p ON f.out_area_map_code = p.o AND f.in_area_map_code = p.i
        WHERE p.p99 >= $(FLOW_SPIKE_MIN_P99_MW)
          AND f.date_time_utc >= (\$3::date::timestamp AT TIME ZONE 'UTC')
          AND f.date_time_utc < (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND f.flow_mw > $(FLOW_SPIKE_FACTOR) * p.p99
        GROUP BY 1, 2
        """,
        Any[base0, end_date, start_date],
        zones,
    )
    return sql2df_with_retry(sql, args)
end

function _fetch_price_caps(d0::Date, d1::Date, zones)
    (sql, args) = _audit_sql(
        """
        SELECT map_code AS zone, COUNT(*) AS n,
               MIN(price_currency_mwh) AS mn, MAX(price_currency_mwh) AS mx
        FROM entsoe.energy_prices
        WHERE contract_type = 'Day-ahead' AND currency = 'EUR'
          AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND (price_currency_mwh < $(PRICE_CAP_LOW) OR price_currency_mwh > $(PRICE_CAP_HIGH))""" *
        _zone_filter_sql(zones, "map_code") *
        "\nGROUP BY 1",
        Any[d0, d1],
        zones,
    )
    return sql2df_with_retry(sql, args)
end

# ----------------------------------------------------------------------------
# Orchestration
# ----------------------------------------------------------------------------

const AUDIT_CHECKS = [
    :solar_night,
    :solar_day_missing,
    :load_bounds,
    :load_day_incomplete,
    :resolution_mix,
    :registry,
    :unit_output,
    :reservoir,
    :flow_spike,
    :price_caps,
]

"""
    run_physics_audit(start_date, end_date; zones=nothing, checks=AUDIT_CHECKS,
                      lookback_days=400, verbose=true) -> DataFrame

Run the physics-consistency checks against the configured data store over
`[start_date, end_date)` (delivery timestamps, UTC). `zones` limits the scan
(default: every zone in the store); `checks` selects a subset by name.
Baseline statistics (quantiles, climatologies) use the window extended
`lookback_days` back, so a short daily-CI window is still judged against a
seasonal baseline. Read-only: issues only SELECTs through `sql2df_with_retry`.

Returns one row per finding: $(join(string.(AUDIT_FINDING_COLS), ", ")).
Registry and reservoir checks are windowless (small, full-history tables) and
run whenever selected.
"""
function run_physics_audit(
    start_date::Date,
    end_date::Date;
    zones::Union{Nothing,Vector{String}} = nothing,
    checks::Vector{Symbol} = AUDIT_CHECKS,
    lookback_days::Int = 400,
    verbose::Bool = true,
)
    end_date > start_date || error("run_physics_audit: end_date must be after start_date")
    base0 = start_date - Day(lookback_days)
    findings = _audit_empty()
    log(msg) = verbose && println("  [physics_audit] " * msg)

    if :solar_night in checks || :solar_day_missing in checks
        solar = _fetch_solar(base0, end_date, zones)
        # Night/zero findings only inside the audited window; the lookback rows
        # only feed the zone-month climatology of the missing-day check.
        window = solar[solar.ts .>= DateTime(start_date), :]
        if :solar_night in checks
            f = check_solar_night(window)
            log("solar_night: $(nrow(f)) finding(s)")
            append!(findings, f)
        end
        if :solar_day_missing in checks
            f = check_solar_day_missing(solar)
            f = f[f.period .>= string(start_date), :]
            log("solar_day_missing: $(nrow(f)) finding(s)")
            append!(findings, f)
        end
    end

    if :load_bounds in checks || :load_day_incomplete in checks
        load = _fetch_load(start_date, end_date, zones)
        if :load_bounds in checks
            stats = _fetch_load_stats(base0, end_date, zones)
            f = check_load_bounds(load, stats)
            log("load_bounds: $(nrow(f)) finding(s)")
            append!(findings, f)
        end
        if :load_day_incomplete in checks
            f = check_load_day_incomplete(load)
            log("load_day_incomplete: $(nrow(f)) finding(s)")
            append!(findings, f)
        end
    end

    if :resolution_mix in checks
        f = check_resolution_mix(_fetch_resolution_mix(start_date, end_date, zones))
        log("resolution_mix: $(nrow(f)) finding(s)")
        append!(findings, f)
    end

    if :registry in checks
        f = check_registry(_fetch_registry(zones))
        log("registry: $(nrow(f)) finding(s)")
        append!(findings, f)
    end

    if :unit_output in checks
        f = check_unit_output(_fetch_unit_over_cap(start_date, end_date, zones))
        log("unit_output_above_capacity: $(nrow(f)) finding(s)")
        append!(findings, f)
    end

    if :reservoir in checks
        f = check_reservoir(_fetch_reservoir(zones))
        log("reservoir_anomaly: $(nrow(f)) finding(s)")
        append!(findings, f)
    end

    if :flow_spike in checks
        f = check_flow_spikes(_fetch_flow_spikes(start_date, end_date, base0, zones))
        log("flow_spike: $(nrow(f)) finding(s)")
        append!(findings, f)
    end

    if :price_caps in checks
        f = check_price_caps(_fetch_price_caps(start_date, end_date, zones))
        log("price_caps: $(nrow(f)) finding(s)")
        append!(findings, f)
    end

    return findings
end

"""
    audit_summary(findings::DataFrame) -> DataFrame

Per (check, severity): finding count, affected zones, total flagged units/hours.
"""
function audit_summary(findings::DataFrame)
    isempty(findings) && return DataFrame(
        check = String[],
        severity = String[],
        findings = Int[],
        zones = Int[],
        total_n = Int[],
    )
    g = groupby(findings, [:check, :severity])
    return combine(
        g,
        nrow => :findings,
        :zone => (z -> length(unique(z))) => :zones,
        :n => sum => :total_n,
    )
end

"""
    write_audit_json(findings, path; meta...) -> path

Write the findings plus a summary as a JSON report (the shape the
refresh-extract workflow uploads next to its manifest). `meta` key-values land
in the header (window, store, code revision, ...).
"""
function write_audit_json(findings::DataFrame, path::AbstractString; meta...)
    esc(s) = replace(String(s), "\\" => "\\\\", "\"" => "\\\"")
    io = IOBuffer()
    println(io, "{")
    for (k, v) in pairs(meta)
        println(io, "  \"$(esc(string(k)))\": \"$(esc(string(v)))\",")
    end
    s = audit_summary(findings)
    println(io, "  \"summary\": [")
    for (i, r) in enumerate(eachrow(s))
        println(
            io,
            "    {\"check\": \"$(esc(r.check))\", \"severity\": \"$(esc(r.severity))\", " *
            "\"findings\": $(r.findings), \"zones\": $(r.zones), \"total_n\": $(r.total_n)}" *
            (i == nrow(s) ? "" : ","),
        )
    end
    println(io, "  ],")
    println(io, "  \"findings\": [")
    for (i, r) in enumerate(eachrow(findings))
        println(
            io,
            "    {\"check\": \"$(esc(r.check))\", \"severity\": \"$(esc(r.severity))\", " *
            "\"zone\": \"$(esc(r.zone))\", \"period\": \"$(esc(r.period))\", " *
            "\"n\": $(r.n), \"value\": $(r.value), \"bound\": $(r.bound), " *
            "\"detail\": \"$(esc(r.detail))\"}" *
            (i == nrow(findings) ? "" : ","),
        )
    end
    println(io, "  ]")
    println(io, "}")
    write(path, take!(io))
    return path
end
