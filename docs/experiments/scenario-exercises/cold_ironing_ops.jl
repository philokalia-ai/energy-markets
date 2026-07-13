# SCENARIO: cold ironing (onshore power supply) at the 21 monitored Greek ports —
# every in-scope passenger ship connects to shore power while at berth.
#
#   julia --project=. docs/experiments/scenario-exercises/cold_ironing_ops.jl
#
# Saves clearing_mode="gr_scn_ops", 2024-07-01..2025-06-30 (365 days, matching
# the AIS data's actual coverage — no tiling/extrapolation).
# Compare against the shared baseline with
#   julia --project=. bin/scenario_delta.jl gr_scn_base gr_scn_ops GR 2024-07-01 2025-07-01
#
# This is the real-data incarnation of the documented "ships request power"
# example in docs/scenario-api.md: extra INELASTIC DEMAND orders at the price
# cap, one per timeslot, sized by a measured hourly OPS demand profile instead
# of a flat 200 MW. The profile (ops_hourly_gr_central_2024H2_2025H1.csv, UTC)
# is the CENTRAL scenario, all-21-ports scope, of the ceres ships pipeline's
# 15-min export, averaged to hourly MW — see README.md for provenance.
#
# HOOK CHOICE — `extra_orders`: OPS demand is new price-inelastic demand bid at
# the cap (ships connect regardless of price), i.e. literally a set of demand
# orders. Unlike the data-center case there is no claim that TSO load forecasts
# would carry it, so the pure demand-curve addition is the faithful modelling.

include("common.jl")
using CSV, DataFrames

# Load the hourly OPS profile: UTC hour -> MW (keys "yyyymmdd-HH")
const OPS_MW = let
    df = CSV.read(joinpath(@__DIR__, "ops_hourly_gr_central_2024H2_2025H1.csv"), DataFrame)
    d = Dict{String,Float64}()
    for r in eachrow(df)
        dt = DateTime(string(r.datetime_utc)[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
        d[Dates.format(dt, "yyyymmdd-HH")] = Float64(r.ops_mw)
    end
    d
end

# ctx -> Vector{SimpleOrder}: inelastic demand at the cap, hourly OPS MW.
# Timeslots are "yyyymmdd-HHMM" (UTC); the profile is hourly, so sub-hourly
# slots (if any) inherit their hour's MW. Zero-MW hours add no order.
ops_orders = ctx -> begin
    orders = SimpleOrder[]
    for ts in ctx.timeslots
        mw = get(OPS_MW, ts[1:11], 0.0)
        mw > 0 && push!(orders, SimpleOrder(:demand, 3000.0, mw, Symbol(ctx.zone),
            DateTime(ts, dateformat"yyyymmdd-HHMM"), ctx.resolution_minutes))
    end
    orders
end

run_labeled("gr_scn_ops", Date(2024, 7, 1), Date(2025, 6, 30);
    extra_orders=ops_orders)
