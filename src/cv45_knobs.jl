# cv45 knobs (docs/code-version-ledger.md, v45; reviews/fable-nov-bias.md §5).
#
# One env var per change; each takes "on" or "off". Unset ⇒ a shipped knob
# (CV45_SHIPPED) follows the master switch EUPHEMIA_CV45 (default "on"); a
# deferred knob is off. So env unset = the adopted cv45 set (GAS_HHV, GB_HHV,
# AVAIL, AVAIL_INMERIT; reports/analyst-cv45.md §0c). EUPHEMIA_CV45=off ⇒ every
# knob off ⇒ the cv44 book, byte-identical. An individually set knob wins over
# the master, so a single-change arm is
#     EUPHEMIA_CV45=off EUPHEMIA_CV45_<NAME>=on
# and a deferred knob is tried with EUPHEMIA_CV45_<NAME>=on.
#
#   EUPHEMIA_CV45_PUMP       (deferred) pumping demand added to load (ex-ante, per zone)
#   EUPHEMIA_CV45_RESERVOIR  (deferred) reservoir hydro as an energy-limited complex family
#   EUPHEMIA_CV45_AVAIL      oil and "Other" capped at demonstrated capability
#   EUPHEMIA_CV45_AVAIL_INMERIT  apply AVAIL only to fuels cheaper than gas at both window ends
#   EUPHEMIA_CV45_GAS_HHV    gas fuel term on the TTF's gross (HHV) basis
#   EUPHEMIA_CV45_GB_HHV     corresponding TTF units for the GB boundary CCGT
#   EUPHEMIA_CV45_HYDRO_CAP  (deferred) anchored water-value clamp at TRANCHES' top multiplier
#   EUPHEMIA_CV45_ELASTIC    (deferred) elastic-demand price max(250, BACKSTOP_PRICE_MULT × gas SRMC)
const CV45_KNOBS = ("EUPHEMIA_CV45_PUMP", "EUPHEMIA_CV45_RESERVOIR", "EUPHEMIA_CV45_AVAIL",
                    "EUPHEMIA_CV45_GAS_HHV", "EUPHEMIA_CV45_HYDRO_CAP", "EUPHEMIA_CV45_ELASTIC",
                    "EUPHEMIA_CV45_AVAIL_INMERIT", "EUPHEMIA_CV45_GB_HHV")
# Knobs the master switch turns on. The rest failed or showed no gain in the
# 2-year singles backtest (reports/analyst-cv45.md §0b-§0c) and stay opt-in.
const CV45_SHIPPED = ("EUPHEMIA_CV45_GAS_HHV", "EUPHEMIA_CV45_GB_HHV",
                      "EUPHEMIA_CV45_AVAIL", "EUPHEMIA_CV45_AVAIL_INMERIT")

function _cv45_switch(name::String)
    v = lowercase(strip(get(ENV, name, "")))
    v in ("on", "off", "") || error("$name must be on or off (got \"$v\")")
    return v
end

"True when the cv45 change behind env knob `name` is active."
function cv45_on(name::String)
    v = _cv45_switch(name)
    isempty(v) || return v == "on"
    m = _cv45_switch("EUPHEMIA_CV45")
    return m != "off" && name in CV45_SHIPPED
end
