# coupling_metrics.jl — Iterative-coupling helpers: net imports from flows, price/flow convergence metrics, damping.
# Included by ../MPCC.jl inside `module MPCC` (definition order preserved).

# =============================================================================
# FLOW-TO-NET-IMPORT CONVERSION UTILITIES
# =============================================================================

"""
    compute_net_imports_from_flows(transmission_flows, zones) -> Dict{String, Dict{String, Float64}}

Convert MPCC transmission flows to per-zone net imports for UC demand adjustment.

Net import for zone Z = sum(inflows to Z) - sum(outflows from Z)
- Positive = zone is net importer (reduces UC demand)
- Negative = zone is net exporter (increases UC demand)

# Arguments
- `transmission_flows::Dict{String, Dict{String, Float64}}`: MPCC output with keys like "GR_to_BG"
- `zones::Vector{String}`: List of zone codes to compute net imports for

# Returns
- `Dict{String, Dict{String, Float64}}`: net_imports[zone][period] → MW

# Example
```julia
flows = Dict("GR_to_BG" => Dict("1" => 100.0, "2" => 150.0))
zones = ["GR", "BG"]
net_imports = compute_net_imports_from_flows(flows, zones)
# net_imports["GR"]["1"] == -100.0  (exporting)
# net_imports["BG"]["1"] == 100.0   (importing)
```
"""
function compute_net_imports_from_flows(
    transmission_flows::Dict{String, Dict{String, Float64}},
    zones::Vector{String}
)::Dict{String, Dict{String, Float64}}

    net_imports = Dict{String, Dict{String, Float64}}()

    # Initialize all zones with empty dicts
    for zone in zones
        net_imports[zone] = Dict{String, Float64}()
    end

    # Process each flow
    for (flow_id, period_flows) in transmission_flows
        # Parse "SOURCE_to_SINK" format
        parts = split(flow_id, "_to_")
        if length(parts) != 2
            @warn "Invalid flow_id format: $flow_id, expected SOURCE_to_SINK"
            continue
        end
        source_zone = String(parts[1])
        sink_zone = String(parts[2])

        for (period, flow_mw) in period_flows
            # Sink receives power (positive = import)
            if haskey(net_imports, sink_zone)
                current = get(net_imports[sink_zone], period, 0.0)
                net_imports[sink_zone][period] = current + flow_mw
            end

            # Source sends power (negative = export)
            if haskey(net_imports, source_zone)
                current = get(net_imports[source_zone], period, 0.0)
                net_imports[source_zone][period] = current - flow_mw
            end
        end
    end

    return net_imports
end

"""
    compute_max_price_change(current_prices, previous_prices) -> Float64

Compute maximum absolute change in market prices between iterations (€/MWh).
This is the primary convergence criterion for iterative UC-MPCC.

Price-based convergence is preferred over flow-based because:
- Prices are the economic fixed point of market coupling
- Flows are derived quantities that can oscillate near binding constraints
- UC binaries can cause small flow changes even when prices are stable

# Arguments
- `current_prices::Dict{String, Dict{String, Float64}}`: Prices by zone and period
- `previous_prices::Union{Dict{String, Dict{String, Float64}}, Nothing}`: Previous iteration prices

# Returns
- `Float64`: Maximum absolute price change across all zones and periods (€/MWh)
"""
function compute_max_price_change(
    current_prices::Dict{String, Dict{String, Float64}},
    previous_prices::Union{Dict{String, Dict{String, Float64}}, Nothing}
)::Float64
    if previous_prices === nothing
        return Inf
    end

    max_change = 0.0
    for (zone, periods) in current_prices
        prev_zone = get(previous_prices, zone, Dict{String, Float64}())
        for (period, price) in periods
            prev_price = get(prev_zone, period, price)  # Default to same price if missing
            change = abs(price - prev_price)
            max_change = max(max_change, change)
        end
    end
    return max_change
end

"""
    compute_max_relative_flow_change(current_flows, previous_flows; min_flow::Float64=10.0) -> Float64

Compute maximum relative change in transmission flows between iterations (fraction).
Used as a diagnostic metric alongside price convergence.

# Arguments
- `current_flows::Dict{String, Dict{String, Float64}}`: Flows by corridor and period
- `previous_flows::Union{Dict{String, Dict{String, Float64}}, Nothing}`: Previous iteration flows
- `min_flow::Float64`: Minimum flow magnitude for denominator to avoid division issues (default: 10 MW)

# Returns
- `Float64`: Maximum relative flow change as a fraction (e.g., 0.02 = 2%)
"""
function compute_max_relative_flow_change(
    current_flows::Dict{String, Dict{String, Float64}},
    previous_flows::Union{Dict{String, Dict{String, Float64}}, Nothing};
    min_flow::Float64=10.0
)::Float64
    if previous_flows === nothing
        return Inf
    end

    max_relative_change = 0.0
    for (flow_id, periods) in current_flows
        prev_corridor = get(previous_flows, flow_id, Dict{String, Float64}())
        for (period, flow) in periods
            prev_flow = get(prev_corridor, period, 0.0)
            abs_change = abs(flow - prev_flow)
            # Use max of current and previous flow magnitude for denominator
            denominator = max(abs(flow), abs(prev_flow), min_flow)
            relative_change = abs_change / denominator
            max_relative_change = max(max_relative_change, relative_change)
        end
    end
    return max_relative_change
end

"""
    compute_max_flow_change(current, previous) -> Float64

Compute maximum absolute change in net imports between iterations.
Kept for backward compatibility; prefer `compute_max_price_change` for convergence.

Note: Absolute flow tolerance is problematic for UC-market coupling because:
- Flow magnitudes vary widely (100s to 1000s of MW)
- UC binaries cause discontinuous flow changes
- Flows can oscillate even when prices are stable
"""
function compute_max_flow_change(
    current::Dict{String, Dict{String, Float64}},
    previous::Union{Dict{String, Dict{String, Float64}}, Nothing}
)::Float64
    if previous === nothing
        # First iteration - return infinity to force at least one more iteration
        return Inf
    end

    max_change = 0.0
    for (zone, periods) in current
        prev_zone = get(previous, zone, Dict{String, Float64}())
        for (period, value) in periods
            prev_value = get(prev_zone, period, 0.0)
            change = abs(value - prev_value)
            max_change = max(max_change, change)
        end
    end
    return max_change
end

"""
    apply_damping(current, previous, α) -> Dict{String, Dict{String, Float64}}

Apply damping to net imports: new = α × current + (1-α) × previous
"""
function apply_damping(
    current::Dict{String, Dict{String, Float64}},
    previous::Union{Dict{String, Dict{String, Float64}}, Nothing},
    α::Float64
)::Dict{String, Dict{String, Float64}}
    if previous === nothing || α >= 1.0
        return current
    end

    damped = Dict{String, Dict{String, Float64}}()
    for (zone, periods) in current
        damped[zone] = Dict{String, Float64}()
        prev_zone = get(previous, zone, Dict{String, Float64}())
        for (period, value) in periods
            prev_value = get(prev_zone, period, 0.0)
            damped[zone][period] = α * value + (1 - α) * prev_value
        end
    end
    return damped
end
