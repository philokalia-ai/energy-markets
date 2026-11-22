# cv46 physics components (tasks/cv46-physics.md; reviews/{fable,astra}-physics-cv46.md).
#
# One research env switch per component, each "on" or "off"; unset ⇒ off. With
# every switch unset the book is byte-identical to main. There is no master
# switch. The existing cv45 deferred knobs (PUMP, RESERVOIR, HYDRO_CAP,
# ELASTIC) keep their own EUPHEMIA_CV45_<NAME> switches (src/cv45_knobs.jl).
#
#   EUPHEMIA_CV46_NORDIC_WV   P1  Nordic water value: export-headroom-scaled floor
#                                 + unavoidable/storable split of non-spill water
#   EUPHEMIA_CV46_SEE_LIMIT   P2  west → south-east transfer limit at trailing
#                                 demonstrated physical flow; no gas-SRMC clamp
#                                 on anchored imports
#   EUPHEMIA_CV46_IT_EFF      P3a Italian unit gas efficiency (documented units)
#   EUPHEMIA_CV46_IT_LIMITS   P3b Italian internal transfer limits floored at
#                                 trailing demonstrated flow
#
# Every EUPHEMIA_CV46_* variable travels to the pipelined-backfill workers
# (src/PipelinedBackfill.jl forwards the whole prefix).
const CV46_PHYSICS_SWITCHES = ("EUPHEMIA_CV46_NORDIC_WV", "EUPHEMIA_CV46_SEE_LIMIT",
                               "EUPHEMIA_CV46_IT_EFF", "EUPHEMIA_CV46_IT_LIMITS")

"True when the cv46 physics component behind env switch `name` is on."
function cv46_on(name::String)
    name in CV46_PHYSICS_SWITCHES || error("unknown cv46 physics switch $name")
    v = lowercase(strip(get(ENV, name, "")))
    v in ("on", "off", "") || error("$name must be on or off (got \"$v\")")
    return v == "on"
end
