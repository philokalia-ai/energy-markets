# BASELINE for the GR scenario exercises: the plain competitive counterfactual,
# no scenario hooks. Shared by both exercises (its window is the union of the
# data-center and cold-ironing windows).
#
#   julia --project=. docs/experiments/scenario-exercises/baseline.jl
#
# Saves clearing_mode="gr_scn_base", 2024-07-01..2026-06-30 (730 days).

include("common.jl")

run_labeled("gr_scn_base", Date(2024, 7, 1), Date(2026, 6, 30))
