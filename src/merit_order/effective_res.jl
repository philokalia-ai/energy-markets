# ── The effective-RES component contract (#387, #390 §1) ──────────────────
#
# ONE renewable series per zone/interval, carried per COMPONENT (:solar,
# :wind, :other) together with its provenance, built once in Stage 2 and read
# by everything downstream: the near-zero-price RES supply orders, the
# residual demand that drives scarcity and water value, and the cv31
# solar-regime gate.
#
# The defect this replaces (#387): the regime gate re-derived its own solar
# signal from the RAW 14.1.D rows (`production_type == "Solar"`), while the
# book's supply stack used the EFFECTIVE series — raw rows plus the weather
# fill, the cv32 input corrections and any scenario modifier. On the forecast
# track a RES-short zone therefore had weather solar in the stack and none in
# the gate, so the solar-regime floor could not fire in exactly the zones that
# needed filling. Deriving both from this one object makes that class of drift
# unrepresentable rather than merely fixed.
#
# The component vector is RECONCILED against the authoritative aggregate: the
# aggregate is whatever the existing Stage-2 pipeline produced (unchanged, so
# no price moves from this file alone), and the components are scaled to sum
# to it. `alloc` records how that was achieved, because the honest answer is
# not always "exactly":
#
#   :exact        components already summed to the aggregate (the normal case:
#                 no aggregate-level modifier, or one that cancelled out);
#   :pro_rata     an AGGREGATE modifier (`renewable_modifier`, cv32 input
#                 corrections) moved the total, and its delta was allocated to
#                 the components in proportion to their pre-modifier share.
#                 This is the DECLARED compatibility rule for aggregate hooks —
#                 it is a convention, not a measurement, and a scenario that
#                 needs an exact split must use `res_component_modifier`;
#   :unallocated  the aggregate is non-zero in a slot where every component is
#                 zero (nothing to scale) — the residue is carried in :other so
#                 energy still adds up, and it is NOT counted as solar.

"""
Effective renewable inputs for one zone-day, on the clearing grid.

- `total[ts]`              — MW, the authoritative aggregate (what the book offers);
- `components[c][ts]`      — MW per component, reconciled to sum to `total`;
- `source[c][hour_prefix]` — `:tso`, `:persistence`, `:weather_fill`, `:mixed`
  or `:absent` for that component-hour ("yyyymmdd-HH"), carried from the rows;
- `coverage[c]`            — number of hours with real coverage of `c`;
- `alloc`                  — how aggregate-level edits were split (see above);
- `resolution_minutes`     — the grid the series live on. MW throughout (power,
  never energy), so an interval's value is independent of its length.
"""
struct EffectiveRes
    total::Dict{String,Float64}
    components::Dict{Symbol,Dict{String,Float64}}
    source::Dict{Symbol,Dict{String,Symbol}}
    coverage::Dict{Symbol,Int}
    alloc::Symbol
    resolution_minutes::Int
end

const RES_COMPONENTS = (:solar, :wind, :other)

"Empty effective-RES (a zone-day with no renewable rows at all)."
EffectiveRes(resolution_minutes::Int) = EffectiveRes(
    Dict{String,Float64}(),
    Dict{Symbol,Dict{String,Float64}}(c => Dict{String,Float64}() for c in RES_COMPONENTS),
    Dict{Symbol,Dict{String,Symbol}}(c => Dict{String,Symbol}() for c in RES_COMPONENTS),
    Dict{Symbol,Int}(c => 0 for c in RES_COMPONENTS),
    :exact,
    resolution_minutes,
)

"""
    res_source_map(renewables) -> Dict{Symbol,Dict{String,Symbol}}

Per-component, per-hour ("yyyymmdd-HH") provenance of the renewable rows.
A component-hour with several rows of differing provenance is `:mixed` unless
they agree; a component-hour whose only rows are coalesced zeroes is `:absent`,
which is what makes "the TSO published nothing for solar this hour" distinct
from "the TSO published zero solar this hour" — the distinction the per-type
fill needs, and the reason the fill no longer asks "is ANY RES row present?".
"""
function res_source_map(renewables)
    out =
        Dict{Symbol,Dict{String,Symbol}}(c => Dict{String,Symbol}() for c in RES_COMPONENTS)
    for r in renewables
        length(r.date_time) >= 11 || continue
        c = res_component(r.production_type)
        h = r.date_time[1:11]
        d = out[c]
        prev = get(d, h, nothing)
        d[h] =
            prev === nothing ? r.source :
            prev === r.source ? prev :
            (prev === :absent ? r.source : (r.source === :absent ? prev : :mixed))
    end
    return out
end

"True when `renewables` really covers `component` in the hour of timeslot `ts`."
function res_covered(
    srcmap::Dict{Symbol,Dict{String,Symbol}},
    component::Symbol,
    ts::AbstractString,
)
    length(ts) >= 11 || return false
    s = get(get(srcmap, component, Dict{String,Symbol}()), ts[1:11], :absent)
    return s !== :absent
end

"""
    build_effective_res(total, components, srcmap, resolution_minutes) -> EffectiveRes

Reconcile the per-component series against the authoritative aggregate (see the
header note for what `alloc` records). Components carrying slots the aggregate
does not have are dropped — the aggregate defines the grid.
"""
function build_effective_res(
    total::Dict{String,Float64},
    components::Dict{Symbol,Dict{String,Float64}},
    srcmap::Dict{Symbol,Dict{String,Symbol}},
    resolution_minutes::Int,
)
    comps = Dict{Symbol,Dict{String,Float64}}(
        c => Dict{String,Float64}() for c in RES_COMPONENTS
    )
    alloc = :exact
    for (ts, t) in total
        csum = 0.0
        for c in RES_COMPONENTS
            csum += get(get(components, c, Dict{String,Float64}()), ts, 0.0)
        end
        if isapprox(csum, t; atol = 1e-9, rtol = 1e-12)
            for c in RES_COMPONENTS
                v = get(get(components, c, Dict{String,Float64}()), ts, 0.0)
                v == 0.0 || (comps[c][ts] = v)
            end
        elseif csum > 0.0
            f = t / csum
            for c in RES_COMPONENTS
                v = get(get(components, c, Dict{String,Float64}()), ts, 0.0)
                v == 0.0 || (comps[c][ts] = v * f)
            end
            alloc = alloc === :unallocated ? :unallocated : :pro_rata
        elseif t != 0.0
            comps[:other][ts] = t
            alloc = :unallocated
        end
    end
    coverage = Dict{Symbol,Int}(
        c => count(!=(:absent), values(get(srcmap, c, Dict{String,Symbol}()))) for
        c in RES_COMPONENTS
    )
    return EffectiveRes(total, comps, srcmap, coverage, alloc, resolution_minutes)
end

"The effective MW series of one component (empty dict when it has none)."
component_series(er::EffectiveRes, c::Symbol) =
    get(er.components, c, Dict{String,Float64}())

"""
    solar_share_by_hour(er, load_by_time) -> Dict{Int,Float64}

The cv31 regime axis: EFFECTIVE solar MW ÷ EFFECTIVE load MW, per UTC hour,
both averaged over the slots of the hour (MW is a level, so the mean is the
hour's level). The single definition — the cv31 floor gate and the cv34 T3
pumping gate both call it, and both therefore see the weather fill, the cv32
corrections and any scenario edit.
"""
function solar_share_by_hour(er::EffectiveRes, load_by_time::Dict{String,Float64})
    sol = component_series(er, :solar)
    isempty(sol) && return Dict{Int,Float64}()
    # Slots are visited in TIMESLOT order, not dict order, so the hour's mean is
    # the same float on every run and in every process — "identical inputs and
    # issuance reproduce identical gate states" has to hold at the last bit,
    # because the gate is a threshold comparison.
    sol_hr = Dict{Int,Vector{Float64}}()
    ld_hr = Dict{Int,Vector{Float64}}()
    for ts in sort!(collect(keys(sol)))
        length(ts) >= 11 || continue
        push!(get!(sol_hr, parse(Int, ts[10:11]), Float64[]), sol[ts])
    end
    for ts in sort!(collect(keys(load_by_time)))
        length(ts) >= 11 || continue
        push!(get!(ld_hr, parse(Int, ts[10:11]), Float64[]), load_by_time[ts])
    end
    out = Dict{Int,Float64}()
    for (h, vs) in sol_hr
        lv = haskey(ld_hr, h) ? sum(ld_hr[h]) / length(ld_hr[h]) : 0.0
        out[h] = lv > 0 ? (sum(vs) / length(vs)) / lv : 0.0
    end
    return out
end

"One-line summary of what the effective RES was built from (printed per book)."
function effective_res_summary(er::EffectiveRes)
    parts = String[]
    for c in (:solar, :wind)
        s = component_series(er, c)
        isempty(s) && continue
        push!(
            parts,
            "$(c) $(round(sum(values(s)) / length(s), digits=1)) MW avg " *
            "($(er.coverage[c])h covered)",
        )
    end
    isempty(parts) && (parts = ["no components"])
    return join(parts, ", ") * (er.alloc === :exact ? "" : ", alloc=$(er.alloc)")
end
