# cv46 P3a — Italian unit gas efficiency (EUPHEMIA_CV46_IT_EFF; tasks/cv46-physics.md, reviews/astra-physics-cv46.md
# priority 2).
#
# Today every gas unit's SRMC is built with ONE fleet heat rate (GAS_PLANT_EFFICIENCY = 0.55, LHV), so Italy's gas base
# bids bunch at a single price. With the switch on, the fuel and carbon terms of Italian gas units that have a
# DOCUMENTED electrical efficiency are rebuilt with that unit's efficiency:
#     mc_u = _gas_fuel_cost(TTF, η_u, GAS_HHV) + GAS_EMISSION_FACTOR / η_u × EUA + GAS_VOM_COST
# which is get_marginal_cost's own formula with η_u in place of 0.55 (same TTF / EUA closes, same cv45 GAS_HHV basis,
# same float-op order, so η_u = 0.55 reproduces the fleet cost exactly). Held fixed: MW (p_max/p_min), every other
# unit, the fleet-completion AGG units (the unclassified fallback is added later in _true_up_fleet at the fleet cost),
# the zone's gas_srmc reference used for hydro water values / import anchors (book_build computes it separately from
# get_marginal_cost), and Italy's thermal_srmc_multiplier (applied after this, to the repriced cost as to any other).
#
# Data: data/cv46_it_gas_efficiency_ppm_v0.9.1.csv, built by bin/cv46_it_gas_efficiency.py from PyPSA
# powerplantmatching v0.9.1 `powerplants.csv` (tag 2026-10-07; https://github.com/PyPSA/powerplantmatching,
# sha256 ceccce02…29ce4f3d78). PPM codes (its EIC set and projectID ENTSOE ids) are matched to every production-unit and
# generation-unit EIC an ENTSO-E unit ever had. Only rows with status == "use" are applied: PPM Set == PP (CHP excluded:
# a cogeneration unit's electrical efficiency depends on the heat credit — "exclude ambiguous CHP"), efficiency present
# and inside a physical plausibility band per technology (CCGT 0.45–0.64 net LHV; IEA-ETSAP E02 2010, upper end = best
# demonstrated CCGT), commissioning and retrofit years <= 2024. Everything else keeps the fleet heat rate.
# Coverage: 9 units, 4,387 MW = 8.3 % of the Italian gas MW active in 2025-07..2026-11 (6.5 % of registry MW); the
# efficiencies are 0.46–0.57, so most repriced units move by a few percent. P3a is close to inert by data, not by design.
#
# As-of / vintage rule: a documented plant efficiency is a static engineering characteristic (not price-informed), so a
# release after the window is acceptable when it carries no post-gate information about the unit; enforced by the
# commissioning/retrofit year rule (<= 2024, strictly before the first decision day 2025-07-03). v0.8.1 (2026-02-11)
# gives the identical 9 units and values; v0.7.1 (2025-02-01, before the window) gives 5 (its Rizziconi/Sparanise values
# 0.19/0.38 fail the band). TTF and EUA are the closes the fleet cost already uses (strictly before the market day,
# src/generators/fuel_costs.jl). Nothing is fitted to prices.

const CV46_IT_EFF_FILE = joinpath(@__DIR__, "..", "..", "data", "cv46_it_gas_efficiency_ppm_v0.9.1.csv")
const _CV46_IT_EFF = Ref{Union{Nothing,Dict{String,Float64}}}(nothing)
const _CV46_IT_EFF_LOCK = ReentrantLock()

"""
    cv46_it_eff_load(path) -> Dict{String,Float64}

generation_unit_code => documented electrical efficiency (LHV) for the crosswalk rows with status "use". Plain CSV
without quoting; any malformed row is an error (the file is generated, never hand-edited).
"""
function cv46_it_eff_load(path::AbstractString=CV46_IT_EFF_FILE)
    lines = readlines(path)
    hdr = split(lines[1], ',')
    ic, ie, is = (findfirst(==(c), hdr) for c in ("generation_unit_code", "ppm_efficiency", "status"))
    (ic === nothing || ie === nothing || is === nothing) && error("cv46 IT_EFF: bad header in $path")
    out = Dict{String,Float64}()
    for (n, l) in enumerate(lines[2:end])
        isempty(l) && continue
        f = split(l, ',')
        (length(f) == length(hdr) && !occursin('"', l)) || error("cv46 IT_EFF: malformed row $(n + 1) in $path")
        f[is] == "use" || continue
        eff = parse(Float64, f[ie])
        0.0 < eff < 1.0 || error("cv46 IT_EFF: efficiency $eff out of (0,1) in row $(n + 1)")
        haskey(out, f[ic]) && error("cv46 IT_EFF: duplicate unit $(f[ic])")
        out[String(f[ic])] = eff
    end
    return out
end

"The crosswalk, loaded once per process."
function cv46_it_eff_table()
    lock(_CV46_IT_EFF_LOCK) do
        _CV46_IT_EFF[] === nothing && (_CV46_IT_EFF[] = cv46_it_eff_load())
        return _CV46_IT_EFF[]
    end
end

"get_marginal_cost's gas formula at electrical efficiency `eff` (same operation order)."
cv46_gas_mc_at_efficiency(ttf::Float64, eua::Float64, eff::Float64, hhv::Bool) =
    _gas_fuel_cost(ttf, eff, hhv) + GAS_EMISSION_FACTOR / eff * eua + GAS_VOM_COST

"""
    cv46_it_eff_reprice(generators, bidding_zone, day; table, ttf, eua, hhv) -> Vector{Generator}

Italian zones only (`IT-*`): each Fossil Gas unit found in `table` gets a new Generator with the marginal cost at its
documented efficiency; everything else is returned as is (same objects — the registry memo is never mutated). With no
TTF close (fallback costs) nothing is repriced.
"""
function cv46_it_eff_reprice(generators::Vector{Generator}, bidding_zone::AbstractString, day::Date;
                             table::Dict{String,Float64}=cv46_it_eff_table(),
                             ttf::Union{Nothing,Float64}=get_ttf_price(day),
                             eua::Float64=eua_price(day),
                             hhv::Bool=cv45_on("EUPHEMIA_CV45_GAS_HHV"),
                             verbose::Bool=true)
    startswith(bidding_zone, "IT-") || return generators
    ttf === nothing && return generators
    n = 0; mw = 0.0; lo = Inf; hi = -Inf
    out = Vector{Generator}(undef, length(generators))
    for (i, g) in enumerate(generators)
        eff = g.fuel_type == Symbol("Fossil Gas") ? get(table, g.code, 0.0) : 0.0
        if eff > 0.0
            mc = cv46_gas_mc_at_efficiency(ttf, eua, eff, hhv)
            n += 1; mw += g.p_max; lo = min(lo, mc); hi = max(hi, mc)
            out[i] = Generator(g.code, g.name, g.fuel_type, g.location, g.p_max, g.p_min, g.bidding_zone, mc,
                               g.ramp_up, g.ramp_down, g.min_uptime, g.min_downtime)
        else
            out[i] = g
        end
    end
    if verbose && n > 0
        fleet = cv46_gas_mc_at_efficiency(ttf, eua, GAS_PLANT_EFFICIENCY, hhv)
        println("  🔥 cv46 IT_EFF: $bidding_zone repriced $n gas unit(s), $(round(Int, mw)) MW, " *
                "SRMC €$(round(lo, digits=1))–$(round(hi, digits=1)) vs fleet €$(round(fleet, digits=1))/MWh")
    end
    return out
end
