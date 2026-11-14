# Experimental RES offer ladder. No database reads or settled-price inputs.
# This deliberately does not infer a supported-fleet share from prices: the
# extract has no contract/cohort register. See collapse-2026-11/README.md.

"""
    RESOfferPolicy(; supported_share=0.0, support_eur_mwh=20.0)

Merchant (or negative-price support-suspended) output offers at zero variable
cost. An explicitly documented share retaining a per-MWh production incentive
can offer at minus that incentive. The share is a generation share, not a
capacity share. It must be fixed from information available before issuance.
Absent contract evidence, the supported share is zero.
"""
struct RESOfferPolicy
    supported_share::Float64
    support_eur_mwh::Float64
    function RESOfferPolicy(; supported_share::Real=0.0,
                            support_eur_mwh::Real=20.0)
        s, v = Float64(supported_share), Float64(support_eur_mwh)
        isfinite(s) && 0 <= s <= 1 ||
            throw(ArgumentError("RES supported share must be finite and in [0, 1]"))
        isfinite(v) && 0 <= v <= 500 ||
            throw(ArgumentError("RES production incentive must be in [0, 500] €/MWh"))
        new(s, v)
    end
end

"Explicit opt-in only; no model-version or production default changes."
res_offer_ladder_enabled() = get(ENV, "EUPHEMIA_RES_OFFER_LADDER", "0") == "1"

function res_offer_policy(zone::AbstractString)
    # No global supported share: a country-level claim must name its zone.
    zk = replace(zone, "-" => "_")
    share = parse(Float64, get(ENV, "EUPHEMIA_RES_SUPPORTED_SHARE_" * zk, "0"))
    value = parse(Float64, get(ENV, "EUPHEMIA_RES_SUPPORT_EUR", "20"))
    return RESOfferPolicy(; supported_share=share, support_eur_mwh=value)
end

"Return (price, MW, strategy) tranches preserving the forecast's total MW."
function res_offer_tranches(quantity::Real, policy::RESOfferPolicy)
    q = Float64(quantity)
    isfinite(q) && q >= 0 || throw(ArgumentError("RES MW must be finite and nonnegative"))
    out = Tuple{Float64,Float64,String}[]
    supported = q * policy.supported_share
    supported > 0 && push!(out, (-policy.support_eur_mwh, supported, "res_supported"))
    merchant = q - supported
    merchant > 0 && push!(out, (0.0, merchant, "res_zero_cost"))
    return out
end
