# SCENARIO: a 574 MW always-on data center connects in Greece.
#
#   julia --project=. docs/experiments/scenario-exercises/datacenter_574mw.jl
#
# Saves clearing_mode="gr_scn_dc574", 2025-07-01..2026-06-30 (365 days).
# Compare against the shared baseline (gr_scn_base) with
#   julia --project=. bin/scenario_delta.jl gr_scn_base gr_scn_dc574 GR 2025-07-01 2026-07-01
#
# HOOK CHOICE — `load_modifier`, not `extra_orders`:
# A hyperscale data center is firm, always-on baseload demand that the system
# operator sees in the load forecast. `load_modifier` edits `load_by_time` at
# the source, so the +574 MW propagates into everything derived from load —
# net demand, the scarcity margin (and hence scarcity-priced tranches), and
# hydro water values — exactly as it would if the forecast itself were higher.
# `extra_orders` by contrast is a pure demand-curve addition: the order clears,
# but the book's scarcity/water-value machinery still prices against the
# unmodified load. For a physical always-on load, `load_modifier` is the more
# faithful representation; `extra_orders` at the cap is the cheap sensitivity
# (it brackets how much of the delta comes from the demand curve alone).

include("common.jl")

const DC_MW = 574.0

# (timeslot, load_mw) -> load_mw : constant addition to every timeslot
dc_load = (ts, load_mw) -> load_mw + DC_MW

run_labeled("gr_scn_dc574", Date(2025, 7, 1), Date(2026, 6, 30);
    load_modifier=dc_load)
