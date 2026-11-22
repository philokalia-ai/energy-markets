# cv46 P1 — Nordic water value (EUPHEMIA_CV46_NORDIC_WV; src/cv46_physics.jl).
#
# Sources: reviews/fable-physics-cv46.md §2 source 2 + §3 F1 (export-headroom floor),
# reviews/astra-physics-cv46.md "Experiments" priority 1 (unavoidable vs storable
# split, storable water at reachable displaced supply). Design note and the
# cp-orch revision: cv46-physics/cp-nordic/STATUS.md.
#
# Scope: zones on the `:reservoir_opportunity` hydro model whose profile has NO
# opportunity anchor (NO4, SE1, SE2, FI; DK1/DK2 match but carry no water-value
# units). Anchored zones (NO1/2/3/5, SE3/4, CH, AT) are untouched in both passes.
#
# Per zone-day, with gas = gas SRMC, shape = water_value_base + span·norm_demand,
# m = max(dryness, eff_seasonal) (all unchanged), p_s = profile.spill_gate_price:
#
#   cap = gas·shape
#   B   = clamp(h·X + (1 − h)·p_s, p_s, cap)
#   wv  = B + m·(cap − B)                       (storable water)
#
# The pre-cv46 value is exactly B + m·(cap − B) with B = 0.35·gas·shape. Pass 1
# has no reference: X = 0.35·gas·shape (Fable F1: the 0.35 export term scaled by
# the headroom probability h, falling to the spill price). Pass 2: X = the
# reachable displaced supply, a weighted mean of PASS-1 MODEL prices (own zone
# weighted by D-1 forecast residual load; each export counterparty by its
# outage-capped demonstrated export capability). No settled price enters.
#
# Unavoidable release U (reservoir units only) is offered at p_s; the rest of the
# non-spill MW is storable.
#
# As-of rules (D = delivery day, gate 12:00 CET on D-1):
# - entsoe.physical_flows: complete UTC days up to D-2 (≤ D-2 23:00 UTC).
# - entsoe.unavailability_in_the_transmission_grid: `Network.tx_outage_caps(D)`,
#   its gate-vintage rule (from 2025-10-01 only versions published before
#   D-1 10:00 UTC).
# - entsoe.aggregated_hydro_storage_filling_rate: ISO weeks ≤ w−2 (w = ISO week of
#   D). Week w−1 is published around Wednesday of week w, possibly after the gate;
#   w−2 is always out before D-1.
# - entsoe.aggregated_generation_per_type: complete UTC days D-8..D-2 (inside a
#   ForecastContext the `_storage_cutoff_day` latency rule).
# - dropped-border exports: `get_dropped_border_exports`, the same flow as-of as the
#   book's own import injection.
# - load / RES forecasts: the D-1 forecasts the book already uses.

# ── constants (each with its source) ────────────────────────────────────────
"Export-term share of gas SRMC in the pre-cv46 floor (book_build.jl :reservoir_opportunity, 0.35 + 0.65·m)."
const NWV_EXPORT_SHARE = 0.35
"Headroom sample: trailing complete UTC days D-15..D-2 (Fable §3 F1, 'trailing-14-day hours')."
const NWV_SAMPLE_DAYS = 14
"Capability window: trailing complete UTC days D-365..D-2 — one seasonal cycle (design note)."
const NWV_CAPABILITY_DAYS = 364
"Capability quantile: the trailing p95 of net export (Fable §3 F1)."
const NWV_CAPABILITY_Q = 0.95
"Below this net-export capability (MW) the zone is a net importer: water always displaces imports ⇒ h = 1 (numerical guard)."
const NWV_IMPORTER_MW = 50.0
"Lagged-output window for inflow and the release lower envelope: complete UTC days D-8..D-2."
const NWV_OUTPUT_DAYS = 7
"Release lower envelope: 5th percentile of hourly reservoir output (mirror of the p95 capability tail)."
const NWV_RMIN_Q = 0.05
"Hours per week: the weekly reservoir data resolution (inflow balance and overflow horizon)."
const NWV_WEEK_H = 168.0
"Strategy label of the unavoidable-release order."
const NWV_UNAVOIDABLE = "water_value_unavoidable"

# ── pure functions (DB-free; test/test_cv46_nordic_wv.jl) ────────────────────

"""
    nwv_in_scope(profile) -> Bool

P1 acts on reservoir-opportunity zones without an opportunity anchor.
"""
nwv_in_scope(profile) =
    profile.hydro_model == :reservoir_opportunity && profile.opportunity_anchor == :none

"""
    nwv_headroom(nx_sample, C, dC) -> Float64

Ex-ante probability that the export corridor has headroom: the share of sample
hours whose net export is below the outage-cut capability `max(0, C − dC)`.
`C ≤ NWV_IMPORTER_MW` or an empty sample ⇒ 1.0.
"""
function nwv_headroom(nx_sample::AbstractVector{Float64}, C::Float64, dC::Float64)
    (isempty(nx_sample) || !(C > NWV_IMPORTER_MW)) && return 1.0
    cd = max(0.0, C - max(dC, 0.0))
    return count(x -> x < cd, nx_sample) / length(nx_sample)
end

"""
    nwv_capability_cut(Eb, ntc) -> Float64

Day-D cut of the export capability by transmission outages: Σ_b max(0, E_b − ntc_b)
over borders with an outage cap (`ntc` keyed like `Eb`; missing ⇒ no cap).
"""
function nwv_capability_cut(Eb::AbstractDict{String,Float64}, ntc::AbstractDict{String,Float64})
    s = 0.0
    for cp in sort(collect(keys(Eb)))
        haskey(ntc, cp) || continue
        s += max(0.0, Eb[cp] - ntc[cp])
    end
    return s
end

"""
    nwv_unavoidable_base(; S_now, S_prev, S_cap, G, R_min) -> Float64

Zone-level unavoidable release (MW) before the per-hour caps:
`max(R_min, U_ovf)` with inflow `I = max(0, G + (S_now − S_prev)/168)` and the
overflow release `U_ovf = max(0, I − max(0, S_cap − S_now)/168)`.
"""
function nwv_unavoidable_base(; S_now::Float64, S_prev::Float64, S_cap::Float64,
                              G::Float64, R_min::Float64)
    inflow = max(0.0, G + (S_now - S_prev) / NWV_WEEK_H)
    u_ovf = max(0.0, inflow - max(0.0, S_cap - S_now) / NWV_WEEK_H)
    return max(max(R_min, 0.0), u_ovf)
end

"""
    nwv_unavoidable_hour(u_base, Q, spill, xdrop) -> Float64

Per-hour unavoidable MW on the non-spill reservoir quantity: `min(Q, u_base)`
less the #366 spill MW already at the spill price and the observed dropped-border
export (that water is import supply in the downstream book already).
"""
nwv_unavoidable_hour(u_base::Float64, Q::Float64, spill::Float64, xdrop::Float64) =
    max(0.0, min(Q, u_base) - spill - max(xdrop, 0.0))

"""
    nwv_storable_parts(gas, shape, m, h, X, p_s) -> (wv, B, cap)

`wv = B + m·(cap − B)` with `cap = gas·shape`, `B = clamp(h·X + (1 − h)·p_s, p_s, cap)`
(cp-orch revision of the design note: the pre-cv46 value is exactly this form with
B = 0.35·gas·shape). `X === nothing` (pass 1) ⇒ X = 0.35·gas·shape; then at h == 1
the pre-cv46 expression is returned verbatim (bit-identical value). Never above
cap; → cap as m → 1 whatever h.
"""
function nwv_storable_parts(gas::Float64, shape::Float64, m::Float64, h::Float64,
                            X::Union{Nothing,Float64}, p_s::Float64)
    cap = gas * shape
    if X === nothing && h == 1.0
        return (gas * (NWV_EXPORT_SHARE + (1.0 - NWV_EXPORT_SHARE) * m) * shape,
                NWV_EXPORT_SHARE * gas * shape, cap)
    end
    x = X === nothing ? NWV_EXPORT_SHARE * gas * shape : X
    B = clamp(h * x + (1.0 - h) * p_s, min(p_s, cap), cap)
    return (min(B + m * (cap - B), cap), B, cap)   # min: no 1-ulp overshoot at m = 1
end

"Storable water value (first element of `nwv_storable_parts`)."
nwv_storable_value(gas, shape, m, h, X, p_s) = nwv_storable_parts(gas, shape, m, h, X, p_s)[1]

"""
    nwv_reference(own_price, own_weight, cp_prices, cp_weights) -> Union{Nothing,Float64}

Reachable displaced supply: the weighted mean of pass-1 prices over the own zone
(weight = forecast residual load) and the export counterparties (weight =
outage-capped export capability). Only counterparties with a price count.
`nothing` when no positive weight remains.
"""
function nwv_reference(own_price::Union{Nothing,Float64}, own_weight::Float64,
                       cp_prices::AbstractDict{String,Float64},
                       cp_weights::AbstractDict{String,Float64})
    num = 0.0; den = 0.0
    if own_price !== nothing && own_weight > 0.0
        num += own_weight * own_price; den += own_weight
    end
    for cp in sort(collect(keys(cp_weights)))
        w = cp_weights[cp]
        (w > 0.0 && haskey(cp_prices, cp)) || continue
        num += w * cp_prices[cp]; den += w
    end
    return den > 0.0 ? num / den : nothing
end

# ── DB readers (cached per zone-day; never cached on error) ──────────────────

const _NWV_STATE_CACHE = Dict{Tuple{String,Date,Union{Nothing,DateTime}},Any}()
const _NWV_LOCK = ReentrantLock()

_nwv_strip_ips(s::AbstractString) = replace(String(s), r"_IPS$" => "")

"""
    _nwv_flow_stats(zone, day) -> (C, Eb, nx_sample)

Hourly net export of `zone` over complete UTC days [D-365, D-1) from
entsoe.physical_flows (quarter-hours averaged per hour; `_IPS` aliases deduped by
the larger flow, as `_zone_border_hourly`). C = p95 of net export over the whole
window, Eb[cp] = p95 of the export flow zone→cp, nx_sample = net export of the
hours in [D-15, D-1).
"""
function _nwv_flow_stats(zone::String, day::Date)
    lo = day - Day(1 + NWV_CAPABILITY_DAYS)
    hi = day - Day(1)
    df = sql2df_with_retry(
        """
        SELECT FLOOR(EXTRACT(EPOCH FROM date_time_utc) / 3600)::BIGINT AS th,
               in_area_map_code AS in_code, out_area_map_code AS out_code,
               AVG(flow_mw) AS f
        FROM entsoe.physical_flows
        WHERE in_area_type_code LIKE 'BZN%' AND out_area_type_code LIKE 'BZN%'
          AND (in_area_map_code = \$1 OR out_area_map_code = \$1)
          AND flow_mw IS NOT NULL
          AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')
        GROUP BY 1, 2, 3
        """, Any[zone, lo, hi])
    # (t, cp, dir) => flow, dedup by max; dir = +1 export, -1 import
    best = Dict{Tuple{Int,String,Int},Float64}()
    for r in eachrow(df)
        ismissing(r.f) && continue
        t = Int(r.th)                    # UTC epoch hour
        if String(r.out_code) == zone
            key = (t, _nwv_strip_ips(r.in_code), 1)
        elseif String(r.in_code) == zone
            key = (t, _nwv_strip_ips(r.out_code), -1)
        else
            continue
        end
        v = Float64(r.f)
        (!haskey(best, key) || v > best[key]) && (best[key] = v)
    end
    nx = Dict{Int,Float64}()
    expf = Dict{String,Vector{Float64}}()
    for k in sort(collect(keys(best)))
        (t, cp, dir) = k
        v = best[k]
        nx[t] = get(nx, t, 0.0) + dir * v
        dir == 1 && push!(get!(expf, cp, Float64[]), max(v, 0.0))
    end
    isempty(nx) && return (C=0.0, Eb=Dict{String,Float64}(), nx_sample=Float64[])
    ts = sort(collect(keys(nx)))
    C = quantile([nx[t] for t in ts], NWV_CAPABILITY_Q)
    Eb = Dict{String,Float64}(cp => quantile(v, NWV_CAPABILITY_Q) for (cp, v) in expf)
    s0 = Int(Dates.value(DateTime(day - Day(1 + NWV_SAMPLE_DAYS)) - DateTime(1970)) ÷ 3_600_000)
    sample = Float64[nx[t] for t in ts if t >= s0]
    return (C=C, Eb=Eb, nx_sample=sample)
end

"""
    _nwv_reservoir_weeks(zone, day) -> Union{Nothing,NamedTuple}

Stored energy of the latest weekly reading with ISO week ≤ w−2 (S_now), the
reading one week earlier (S_prev; a missing week is bridged linearly from the
previous available reading) and the maximum over all readings ≤ w−2 (S_cap).
`nothing` if fewer than two readings.
"""
function _nwv_reservoir_weeks(zone::String, day::Date)
    ref = day - Day(14)                 # any day of ISO week w−2
    y = _reservoir_iso_year(ref)
    w = Int(Dates.week(ref))
    df = sql2df_with_retry(
        """
        SELECT year, week, stored_energy_mwh
        FROM entsoe.aggregated_hydro_storage_filling_rate
        WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
          AND stored_energy_mwh IS NOT NULL
          AND (year < \$2 OR (year = \$2 AND week <= \$3))
        ORDER BY year DESC, week DESC
        """, Any[zone, y, w])
    size(df, 1) >= 2 || return nothing
    s = Float64.(df.stored_energy_mwh)
    # weeks between the two readings (1 unless a week is missing); ΔS is per week
    gap = max(1, 52 * (Int(df.year[1]) - Int(df.year[2])) + Int(df.week[1]) - Int(df.week[2]))
    return (S_now=s[1], S_prev=s[1] - (s[1] - s[2]) / gap, S_cap=maximum(s))
end

"""
    _nwv_lagged_output(zone, day) -> Union{Nothing,NamedTuple}

Mean (G) and 5th percentile (R_min) of hourly "Hydro Water Reservoir" generation
over the 7 complete UTC days before `_storage_cutoff_day(day)` (legacy D-8..D-2).
`nothing` with fewer than 4 days of hours.
"""
function _nwv_lagged_output(zone::String, day::Date)
    cutoff = _storage_cutoff_day(day)
    df = sql2df_with_retry(
        """
        SELECT date_trunc('hour', date_time_utc) AS h,
               AVG(actual_generation_output_mw) AS mw
        FROM entsoe.aggregated_generation_per_type
        WHERE area_map_code = \$1 AND area_type_code LIKE 'BZN%'
          AND production_type = 'Hydro Water Reservoir'
          AND actual_generation_output_mw IS NOT NULL
          AND date_time_utc >= (\$2::date::timestamp AT TIME ZONE 'UTC')
          AND date_time_utc < (\$3::date::timestamp AT TIME ZONE 'UTC')
        GROUP BY 1
        """, Any[zone, cutoff - Day(NWV_OUTPUT_DAYS), cutoff])
    v = Float64[Float64(x) for x in df.mw if !ismissing(x)]
    length(v) >= 4 * 24 || return nothing
    sort!(v)
    return (G=sum(v) / length(v), R_min=quantile(v, NWV_RMIN_Q))
end

"""
    nwv_day_state(zone, day) -> NamedTuple

Per zone-day P1 inputs: `h[hr]` (hr = 0..23 UTC), outage-capped export capability
`ecap[hr][cp]`, the zone-level unavoidable base `u_base` (MW; 0 when an input is
missing) and the raw inputs for the log. Cached per (zone, day, issuance).
"""
function nwv_day_state(zone::String, day::Date)
    c = current_context()
    key = (zone, day, c === nothing ? nothing : c.as_of_utc)
    hit = lock(_NWV_LOCK) do
        get(_NWV_STATE_CACHE, key, nothing)
    end
    hit !== nothing && return hit
    fs = _nwv_flow_stats(zone, day)
    caps = tx_outage_atc_enabled() ? tx_outage_caps(day) : Dict{Tuple{String,String,Int},Float64}()
    h = Dict{Int,Float64}()
    ecap = Dict{Int,Dict{String,Float64}}()
    for hr in 0:23
        ntc = Dict{String,Float64}()
        for cp in keys(fs.Eb)
            v = get(caps, (zone, cp, hr + 1), nothing)
            v === nothing || (ntc[cp] = v)
        end
        h[hr] = nwv_headroom(fs.nx_sample, fs.C, nwv_capability_cut(fs.Eb, ntc))
        ecap[hr] = Dict{String,Float64}(cp => min(e, get(ntc, cp, Inf)) for (cp, e) in fs.Eb)
    end
    rw = _nwv_reservoir_weeks(zone, day)
    lo = _nwv_lagged_output(zone, day)
    u_base = (rw === nothing || lo === nothing) ? 0.0 :
        nwv_unavoidable_base(; S_now=rw.S_now, S_prev=rw.S_prev, S_cap=rw.S_cap,
                             G=lo.G, R_min=lo.R_min)
    st = (h=h, ecap=ecap, u_base=u_base, C=fs.C, n_sample=length(fs.nx_sample),
          res=rw, out=lo)
    lock(_NWV_LOCK) do
        _NWV_STATE_CACHE[key] = st
    end
    return st
end

function clear_nwv_cache!()
    lock(_NWV_LOCK) do
        empty!(_NWV_STATE_CACHE)
    end
    return nothing
end

# ── book-build helpers (book_build.jl hooks) ─────────────────────────────────

"Per zone-day P1 state inside one book build (switch on, zone in scope)."
mutable struct NwvZone
    zone::String
    st::Any                                   # nwv_day_state
    U::Dict{Int,Float64}                      # unavoidable MW per UTC hour (zone total)
    Q::Float64                                # offered reservoir MW (zone total)
    p1::Union{Nothing,Dict{String,Dict{String,Float64}}}   # pass-1 prices (pass 2 only)
    slot_wv::Dict{String,Float64}             # storable value per slot (one per slot)
    n_bcap::Int; n_wvcap::Int; n_bspill::Int; n_ref::Int
end

function _nwv_zone_setup(zone::String, day::Date, generators, offered_pmax,
                         spill_share::Float64, import_only::Vector{String},
                         p1::Union{Nothing,Dict{String,Dict{String,Float64}}})
    st = nwv_day_state(zone, day)
    Q = sum((offered_pmax(g) for g in generators
             if g.fuel_type == Symbol("Hydro Water Reservoir")); init=0.0)
    xdrop = isempty(import_only) ? Dict{Int,Float64}() :
            get_dropped_border_exports(zone, day, import_only)
    U = Dict{Int,Float64}(hr => nwv_unavoidable_hour(st.u_base, Q, spill_share * Q,
                                                     get(xdrop, hr, 0.0)) for hr in 0:23)
    p1z = (p1 !== nothing && haskey(p1, zone)) ? p1 : nothing
    hv = [st.h[hr] for hr in 0:23]
    uv = [U[hr] for hr in 0:23]
    println("  💧 cv46 P1 $zone: h min/mean/max $(round(minimum(hv), digits=3))/" *
            "$(round(sum(hv) / 24, digits=3))/$(round(maximum(hv), digits=3)) " *
            "(C=$(round(Int, st.C)) MW, n=$(st.n_sample)); u_base $(round(Int, st.u_base)) MW " *
            "(res=$(st.res === nothing ? "none" : "ok"), out=$(st.out === nothing ? "none" :
                "G $(round(Int, st.out.G)) p05 $(round(Int, st.out.R_min))")); " *
            "Q $(round(Int, Q)) MW; xdrop mean $(round(Int, sum(get(xdrop, h, 0.0) for h in 0:23) / 24)) MW; " *
            "U mean/max $(round(Int, sum(uv) / 24))/$(round(Int, maximum(uv))) MW; " *
            "pass $(p1z === nothing ? 1 : 2)")
    return NwvZone(zone, st, U, Q, p1z, Dict{String,Float64}(), 0, 0, 0, 0)
end

"Storable water value of slot `ts` (computed once per slot; counters for the log)."
function _nwv_storable!(z::NwvZone, ts::String, hr::Int, gas::Float64, shape::Float64,
                        m::Float64, p_s::Float64, resid_load::Float64)
    haskey(z.slot_wv, ts) && return z.slot_wv[ts]
    h = z.st.h[hr]
    X = nothing
    if z.p1 !== nothing
        own = get(z.p1[z.zone], ts, nothing)
        cpp = Dict{String,Float64}()
        for cp in keys(z.st.ecap[hr])
            haskey(z.p1, cp) && haskey(z.p1[cp], ts) && (cpp[cp] = z.p1[cp][ts])
        end
        X = nwv_reference(own, max(resid_load, 0.0), cpp, z.st.ecap[hr])
        X === nothing || (z.n_ref += 1)
    end
    wv, B, cap = nwv_storable_parts(gas, shape, m, h, X, p_s)
    B >= cap && (z.n_bcap += 1)
    wv >= cap && (z.n_wvcap += 1)
    B <= p_s && (z.n_bspill += 1)
    z.slot_wv[ts] = wv
    return wv
end

"Unit share of the hour's unavoidable release (pro rata to offered MW)."
_nwv_unit_unavoidable(z::NwvZone, hr::Int, pmax::Float64) =
    (z.Q > 0.0 && pmax > 0.0) ? get(z.U, hr, 0.0) * pmax / z.Q : 0.0

"One summary line per zone book (called after the order loop)."
function _nwv_report(z::NwvZone)
    n = length(z.slot_wv)
    println("  💧 cv46 P1 $(z.zone) slots=$n ref=$(z.n_ref) B@cap=$(z.n_bcap) " *
            "wv@cap=$(z.n_wvcap) B@spill=$(z.n_bspill)")
    return nothing
end

# ── pass-2 packing (multi_zone_books.jl hook) ────────────────────────────────

"Key prefix in the pass-2 refs dict carrying a zone's pass-1 prices for P1."
const NWV_P1_KEY = "@p1:"

"""
    nwv_pack_refs!(refs, nodes, market_prices) -> refs

Switch on only. For every P1 zone priced in pass 1: `refs[z] = own pass-1 prices`
(puts it in the pass-2 rebuild set; its profile has no anchor, so the anchor
stays inactive), and `refs["@p1:<zone>"]` = every priced zone's pass-1 prices.
"""
function nwv_pack_refs!(refs::Dict{String,Dict{String,Float64}}, nodes,
                        market_prices::Dict{String,Dict{String,Float64}})
    p1 = [z for z in nodes if haskey(market_prices, z) && nwv_in_scope(get_zone_profile(z))]
    isempty(p1) && return refs
    for z in nodes
        haskey(market_prices, z) && (refs[NWV_P1_KEY * z] = market_prices[z])
    end
    for z in p1
        haskey(refs, z) || (refs[z] = market_prices[z])
    end
    return refs
end

"""
    nwv_unpack_prices(refs) -> Union{Nothing,Dict{String,Dict{String,Float64}}}

The pass-1 price table packed by `nwv_pack_refs!` (`nothing` when absent).
"""
function nwv_unpack_prices(refs::Dict{String,Dict{String,Float64}})
    out = Dict{String,Dict{String,Float64}}()
    for (k, v) in refs
        startswith(k, NWV_P1_KEY) && (out[k[length(NWV_P1_KEY)+1:end]] = v)
    end
    return isempty(out) ? nothing : out
end
