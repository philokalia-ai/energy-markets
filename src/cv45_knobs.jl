# cv45 knobs (docs/code-version-ledger.md, v45; reviews/fable-nov-bias.md §5).
#
# One env var per change; each takes "on" or "off". Unset ⇒ a shipped knob
# (CV45_SHIPPED) follows the master switch EUPHEMIA_CV45 (default "on"). So env unset = the adopted cv45 set (GAS_HHV, GB_HHV,
# AVAIL, AVAIL_INMERIT; reports/analyst-cv45.md §0c). EUPHEMIA_CV45=off ⇒ every
# knob off ⇒ the cv44 book, byte-identical. An individually set knob wins over
# the master, so a single-change arm is
#     EUPHEMIA_CV45=off EUPHEMIA_CV45_<NAME>=on
#
#   EUPHEMIA_CV45_AVAIL      oil and "Other" capped at demonstrated capability
#   EUPHEMIA_CV45_AVAIL_INMERIT  apply AVAIL only to fuels cheaper than gas at both window ends
#   EUPHEMIA_CV45_GAS_HHV    gas fuel term on the TTF's gross (HHV) basis
#   EUPHEMIA_CV45_GB_HHV     corresponding TTF units for the GB boundary CCGT
#
# The four deferred knobs (PUMP, RESERVOIR, HYDRO_CAP, ELASTIC) were deleted in v46
# (docs/code-version-ledger.md); git history holds them.
const CV45_KNOBS = ("EUPHEMIA_CV45_AVAIL", "EUPHEMIA_CV45_GAS_HHV",
                    "EUPHEMIA_CV45_AVAIL_INMERIT", "EUPHEMIA_CV45_GB_HHV")
# Knobs the master switch turns on: all of them since v46.
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
